# Android OBD-II Libraries Deep-Dive

Source code analysis of 3 Android/Kotlin OBD-II libraries with actionable insights for ODBInsight's SwiftOBD2 fork.

## 1. AndrOBD (fr3ts0n/AndrOBD) - 1,900 stars

The most mature open-source OBD-II Android app. Java-based, GPL-2.0 licensed. Supports BLE, Bluetooth Classic, WiFi, and USB connections.

### Architecture Overview

AndrOBD uses a clean 2-layer architecture:

**Library layer** (`library/`) - Pure Java, no Android dependencies:
- `ecu/prot/obd/` - Protocol handlers (ElmProt, ObdProt, CanProt)
- `ecu/` - Data model (EcuDataItem, EcuDataPv, Conversions)
- `prot/` - Stream handling (StreamHandler, TelegramListener)
- `pvs/` - Process variable system (PvList, PvChangeListener)

**App layer** (`androbd/`) - Android-specific:
- `CommService` abstract class + BtCommService, NetworkCommService, UsbCommService
- `DashBoardActivity` + ObdGaugeAdapter for gauge rendering
- `ChartActivity` for time-series charts
- `ExportTask` for CSV export
- `ObdBackgroundService` for foreground service
- `PluginDataAdapter` for plugin-provided data

### Protocol State Machine (ElmProt)

ElmProt implements a sophisticated state machine with these states:

```
UNDEFINED -> INITIALIZING -> INITIALIZED -> ECU_DETECT -> ECU_DETECTED -> CONNECTED
                                                                      -> NODATA
                                                                      -> BUSERROR
                                                                      -> DATAERROR
                                                                      -> ERROR
                                                                      -> DISCONNECTED
```

Key design patterns:
- **Command queue** (`cmdQueue: Vector<String>`) - AT commands and OBD requests are queued and sent sequentially on each `>` prompt
- **Prompt-driven flow** - All processing triggers on receiving `>` prompt from ELM327
- **Response classification** - RSP_ID enum classifies every ELM response (OK, NODATA, ERROR, SEARCHING, CANERROR, BUSBUSY, etc.)
- **Automatic retry** - On bus errors, re-queues last command, closes protocol, sets preferred protocol, reinitializes adaptive timing

### ELM327 Initialization Sequence

```
ATZ (reset) -> ELM model detected ->
  ATE0 (echo off) -> ATS0 (spaces off) -> ATL0 (linefeeds off) ->
  ATSP{n} (set protocol) -> ATAT{n} (adaptive timing) -> ATST{n} (timeout) ->
  [custom init commands] ->
  INITIALIZED ->
  ATH1 (headers on) -> 0100 (query supported PIDs) -> ATH0 (headers off) ->
  ECU_DETECTED
```

### Adaptive Timing (unique feature)

AndrOBD implements software-based adaptive timing that optimizes ELM message timeout at runtime:

- Starts at 200ms timeout
- On NODATA: increases timeout by 4ms (adapter responding too slowly)
- On successful response: decreases timeout by 4ms toward learned minimum
- Learns minimum timeout per session (never goes below what caused NODATA)
- Range: configurable minimum (default 12ms) to 1000ms max
- Three modes: OFF, ELM_AT1 (hardware), ELM_AT2 (hardware), SOFTWARE

### Multi-ECU Support

ECU detection works by:
1. Enabling headers (`ATH1`)
2. Sending `0100` (query supported PIDs from ALL ECUs)
3. Each ECU responds with its address prefix before the data
4. Parsing addresses from response headers (handles 11-bit CAN, 29-bit CAN, and ISO9141 formats)
5. Storing addresses in `TreeSet<Integer> ecuAddresses`
6. Allowing user to filter to specific ECU via `ATCRA` (CAN RX filter)

### PID Management - CSV-Driven Data Model

PIDs are defined in `pids.csv` with these fields:
```
SVC | PID | OFS | LEN | BIT_OFS | BIT_LEN | BIT_MASK | FORMULA | FORMAT | MIN | MAX | UPDATE_MIN | MNEMONIC | LABEL | DESCRIPTION
```

Conversions are defined in `conversions.csv`:
```
NAME | TYPE | VARIANT | SYSTEM | FACTOR | DIVIDER | OFFSET | PHOFFSET | UNITS | DESCRIPTION | PARAMETERS
```

Conversion types: LINEAR, HASH, BITMAP, CODELIST, PCODELIST, VAG, INTEGER, ASCII

This means:
- PIDs and conversions are **data-driven, not code-driven**
- Adding new PIDs = adding CSV rows, no code changes
- Supports metric AND imperial in same conversion set (separate rows for each system)
- Custom PIDs can be loaded from external CSV files at runtime
- Dynamic conversion factors (one PID's value can be the conversion factor for another)

### Data Flow Architecture

```
ELM327 bytes -> StreamHandler (line-by-line) -> ElmProt.handleTelegram()
  -> classifies response (RSP_ID)
  -> on data: ObdProt.handleTelegram()
    -> extracts service + PID from hex
    -> EcuDataItems.updateDataItems(service, pid, buffer)
      -> for each EcuDataItem matching that PID:
        -> EcuDataItem.updatePvFomBuffer(buffer)
          -> physFromBuffer(): extract bytes, apply bit offset/mask, run Conversion
          -> updates EcuDataPv (process variable)
            -> fires PvChangeEvent
              -> UI listeners update gauges/charts
```

### Gauge System

Uses third-party `SpeedViewLib` (AwesomeSpeedometer). ObdGaugeAdapter:
- ArrayAdapter<EcuDataPv> with ViewHolder pattern
- Each gauge gets: min/max from PID definition, units, format, PID-specific color
- GridView layout with auto-column calculation based on screen density
- Dashboard supports selecting specific PIDs to display
- **PID locking**: When dashboard is open, only selected PIDs are polled (faster updates)

### Demo Mode

ElmProt implements `Runnable` with a `run()` method that simulates:
- ELM model response
- ECU detection with multiple addresses (7E8, 7E9, 7EA, ISO9141 format)
- Data cycling (incrementing byte values for all supported PIDs)
- DTC responses (both single-line and multiline)
- VIN multiline response
- Service-not-supported NRC responses

### CSV Export

ExportTask (AsyncTask) exports chart data:
- Configurable field/record delimiters
- Optional text quoting
- Timestamps with millisecond precision
- Uses highest-resolution channel for time base
- Optional auto-send after export (share intent)

### Connection Abstraction

```java
abstract class CommService {
    enum MEDIUM { BLUETOOTH, USB, NETWORK }
    enum STATE { NONE, LISTEN, CONNECTING, CONNECTED, OFFLINE }

    static ElmProt elm = new ElmProt();  // single shared protocol instance

    abstract void start();
    abstract void stop();
    abstract void write(byte[] out);
    abstract void connect(Object device, boolean secure);
}
```

All connection types share the same ElmProt instance. The StreamHandler bridges between I/O streams and the telegram-based protocol.

BtCommService uses SPP UUID (`00001101-...`). Has fallback via reflection to `createRfcommSocket(1)` when standard connection fails. 500ms delay after socket connect before starting worker thread (fix for issue #233).

NetworkCommService connects via TCP socket. ConnectThread runs on background thread to avoid NetworkOnMainThreadException.

### NRC (Negative Response Code) Handling

Comprehensive enum with display classification and reaction strategy:

```java
enum NRC {
    GR(0x10, "General reject", DISP.ERROR, REACT.RESET),
    SNS(0x11, "Service not supported", DISP.ERROR, REACT.CANCEL),
    SFNS(0x12, "Sub-Function not supported", DISP.NOTIFY, REACT.SKIP),
    BRR(0x21, "Busy repeat request", DISP.NOTIFY, REACT.REPEAT),
    RCRRP(0x78, "Response pending", DISP.NOTIFY, REACT.IGNORE),
    // ... 20+ more
}
```

Each NRC has:
- **DISP** (display class): HIDE, NOTIFY, WARN, ERROR
- **REACT** (protocol reaction): IGNORE, SKIP, REPEAT, CANCEL, RESET

### Error Resilience

EcuDataItem tracks consecutive conversion errors (`currErrorCount`). After 3 consecutive failures, the item is disabled (stops updating). This prevents a single bad PID from breaking the entire polling loop.

### Background Service

ObdBackgroundService uses Android Foreground Service pattern:
- Notification channel for ongoing notification
- START_STICKY for auto-restart
- ServiceStateListener interface for callbacks
- Notification text updates based on connection state

## 2. kotlin-obd-api (eltonvs/kotlin-obd-api) - 224 stars

Clean, modern Kotlin library. Transport-agnostic (pure InputStream/OutputStream). Coroutine-based. MIT licensed.

### Architecture

Minimal and focused:
```
connection/
  ObdDeviceConnection.kt     -- Transport layer
command/
  ObdCommand.kt              -- Abstract command base
  ATCommand.kt               -- AT command base (mode="AT", skipDigitCheck=true)
  Response.kt                -- ObdRawResponse + ObdResponse
  Enums.kt                   -- ObdProtocols, AdaptiveTimingMode, Monitors
  Exceptions.kt              -- Error hierarchy
  ParserFunctions.kt         -- bytesToInt, calculatePercentage
  RegexUtils.kt              -- Response cleaning patterns
  at/Actions.kt              -- Reset, WarmStart, LowPower, ProtocolClose, etc.
  at/Info.kt                 -- Device info commands
  at/Mutations.kt            -- Protocol setting, echo, headers, etc.
  control/                   -- DTC, MIL, available commands, monitors
  engine/                    -- RPM, Speed, Load, Throttle, MAF, Runtime
  fuel/                      -- FuelLevel, FuelType, FuelTrim, ConsumptionRate
  temperature/               -- Coolant, IntakeAir, AmbientAir, OilTemp
  pressure/                  -- BarometricPressure, FuelPressure, IntakeManifold
  egr/                       -- EGR
```

### Transport Layer (ObdDeviceConnection)

```kotlin
class ObdDeviceConnection(
    private val inputStream: InputStream,
    private val outputStream: OutputStream
) {
    private val responseCache = mutableMapOf<ObdCommand, ObdRawResponse>()

    suspend fun run(
        command: ObdCommand,
        useCache: Boolean = false,
        delayTime: Long = 0,
        maxRetries: Int = 5,
    ): ObdResponse
}
```

Key design decisions:
- Takes raw InputStream/OutputStream (completely transport-agnostic)
- Coroutine-based (`suspend fun run`)
- Built-in response caching per command
- Configurable delay between send and read
- Retry mechanism: polls `inputStream.available()` with 500ms delays up to maxRetries
- Reads until `>` prompt character
- Strips "SEARCHING..." from responses

### Command Pattern

```kotlin
abstract class ObdCommand {
    abstract val tag: String
    abstract val name: String
    abstract val mode: String
    abstract val pid: String

    open val defaultUnit: String = ""
    open val skipDigitCheck: Boolean = false
    open val handler: (ObdRawResponse) -> String = { it.value }

    val rawCommand: String get() = "$mode $pid"

    fun handleResponse(rawResponse: ObdRawResponse): ObdResponse
}
```

Each command defines its own **handler lambda** for parsing. Example:

```kotlin
class RPMCommand : ObdCommand() {
    override val tag = "ENGINE_RPM"
    override val name = "Engine RPM"
    override val mode = "01"
    override val pid = "0C"
    override val defaultUnit = "RPM"
    override val handler = { it: ObdRawResponse ->
        (bytesToInt(it.bufferedValue) / 4).toString()
    }
}
```

### Response Processing Pipeline

ObdRawResponse has a lazy processing pipeline:
1. Remove whitespace
2. Remove "INIT BUS..." text
3. Remove colons (multiline separators)

`processedValue` - cleaned string
`bufferedValue` - IntArray of hex bytes (lazy, chunked by 2 chars)

### Error Handling

Exception hierarchy based on ELM327 response patterns:
- `BusInitException` - "BUS INIT: ERROR"
- `MisunderstoodCommandException` - "?"
- `NoDataException` - "NO DATA"
- `StoppedException` - "STOPPED"
- `UnableToConnectException` - "UNABLE TO CONNECT"
- `UnknownErrorException` - "ERROR"
- `UnSupportedCommandException` - "7F" responses
- `NonNumericResponseException` - unexpected characters

Every response goes through `BadResponseException.checkForExceptions()` before the handler runs.

### DTC Parsing

BaseTroubleCodesCommand handles three DTC response formats:
1. **CAN single frame**: `43yy[codes]` (length <= 16 chars, divisible by 4)
2. **CAN multiframe**: `xxx43yy[codes]` (contains `:`)
3. **ISO/KWP**: stripped by carriageNumberPattern

DTC code parsing: first 2 bits map to P/C/B/U prefix, next 2 bits are second char, remaining 3 chars are hex.

### What's Missing

- No ELM327 initialization sequence (caller must handle)
- No adaptive timing
- No multi-ECU support
- No PID support detection (0100, 0120, etc.)
- No demo/simulation mode
- No data logging
- No background operation

## 3. AndroidOBD (barnhill/AndroidOBD) - 77 stars

Kotlin library with JSON-driven PID definitions. Apache-2.0 licensed.

### Architecture

```
commands/
  BaseObdCommand.kt    -- Base class with run/send/read cycle
  OBDCommand.kt        -- Generic command using PID model + expression evaluator
models/
  PID.kt               -- Data model for PID definitions
  PIDS.kt              -- Collection wrapper
  DTC.kt, DTCS.kt      -- DTC models
statics/
  ObdInitSequence.kt   -- Initialization sequence
  ObdLibrary.kt        -- Library initialization
  PIDUtils.kt          -- PID lookup
  DTCUtils.kt          -- DTC utilities
  Translations.kt      -- Special PID translations
  PersistentStorage.kt -- Cached results
  FileUtils.kt         -- JSON file loading
enums/
  ObdModes.kt          -- OBD mode enumeration
  ObdProtocols.kt      -- Protocol enumeration
```

### JSON-Driven PID Definitions

PIDs are defined in JSON:
```kotlin
@Serializable
data class PID(
    var mode: String = "01",
    var PID: String = "01",
    var bytes: String = "",
    var description: String = "",
    var min: String? = null,
    var max: String? = null,
    var units: String? = null,
    var formula: String? = null,
    var imperialFormula: String? = null,
    var imperialUnits: String? = null
)
```

### Expression-Based Conversion (unique approach)

Instead of hardcoded formulas, uses **EvalEx expression evaluator**:
```kotlin
val expression = Expression(exprText, expressionConfig)
expression.with("A", data[2])  // byte A
expression.with("B", data[3])  // byte B
expression.with("C", data[4])  // byte C
expression.with("D", data[5])  // byte D
mPid.calculatedResult = expression.evaluate().numberValue.toFloat()
```

PID formulas in JSON look like: `"A*100/255"` or `"((A*256)+B)/4"`. This is very flexible.

### Persistent Storage

Unique feature: caches PID results that don't change often (VIN, fuel type, etc.):
```kotlin
if (mPid.isPersistent && PersistentStorage.containsPid(mPid)) {
    readPersistent()  // skip sending command
} else {
    sendCommand(out)
    readResult(inputStream)
}
```

### Initialization Sequence

Procedural, straightforward:
```
ATD (defaults) -> ATZ (reset) -> ATE0 (echo off) -> ATL0 (linefeeds off) ->
ATS0 (spaces off) -> ATH0 (headers off) -> ATSP0 (auto protocol) ->
ATST19 (timeout 25*4=100ms) -> 0100 (test query)
```

### Special PID Translations

Handles PIDs that need enumeration rather than formula:
- PID 0x00: supported PIDs bitmask
- PID 0x01: DTC count + MIL status (bitfield)
- PID 0x51: fuel type (lookup table)

### What's Missing

- No async/coroutine support (synchronous blocking I/O)
- No multi-ECU support
- No adaptive timing
- No demo mode
- No data logging
- No background operation
- Tight coupling to BluetoothSocket in init sequence

## Comparison Matrix

| Feature | AndrOBD | kotlin-obd-api | AndroidOBD |
|---------|---------|----------------|------------|
| Language | Java | Kotlin | Kotlin |
| Architecture | Library + App | Library only | Library only |
| Transport | BT/BLE/WiFi/USB | InputStream/OutputStream | BluetoothSocket |
| Async | Threads | Coroutines | Synchronous |
| PID definitions | CSV (data-driven) | Code (class per command) | JSON (data-driven) |
| Conversion | CSV-driven (LINEAR, HASH, BITMAP, etc.) | Handler lambdas | Expression evaluator (EvalEx) |
| Metric/Imperial | Built into conversion system | Not built-in | Dual formula support |
| Multi-ECU | Yes (header parsing) | No | No |
| Adaptive timing | Software + ELM hardware | No | No |
| NRC handling | Comprehensive (20+ codes) | Basic (8 exception types) | No |
| Demo mode | Full simulation | No | No |
| DTC parsing | Multiline + single line | CAN + ISO/KWP | JSON lookup |
| Error resilience | Per-item error counter | Exception hierarchy | Basic try/catch |
| Caching | No | Per-command cache | Persistent storage |
| Custom PIDs | Runtime CSV loading | New class required | JSON modification |
| Background | Foreground service | N/A (library) | N/A (library) |
| PID support detect | Yes (0100-01E0 bitmask) | Manual | Bitmask translation |

## Actionable Insights for ODBInsight

### 1. ADOPT: Data-Driven PID Definitions

**From AndrOBD's CSV approach + AndroidOBD's expression evaluator:**

Define PIDs in a structured format (JSON or Plist for Swift) rather than hardcoding each PID as a class:

```swift
struct OBDPIDDefinition: Codable {
    let service: Int
    let pid: Int
    let byteOffset: Int
    let byteLength: Int
    let bitOffset: Int
    let bitLength: Int
    let bitMask: UInt32
    let formula: String       // e.g., "((A*256)+B)/4"
    let format: String        // e.g., "%.0f"
    let minValue: Float?
    let maxValue: Float?
    let unit: String
    let imperialUnit: String?
    let imperialFormula: String?
    let mnemonic: String      // unique ID like "ENGINE_RPM"
    let label: String
    let updateInterval: Int   // minimum ms between updates
}
```

Benefits:
- Add custom/manufacturer PIDs without code changes
- Users can import PID definition files
- Cleaner separation of protocol knowledge from code

### 2. ADOPT: Adaptive Timing

**From AndrOBD:**

Implement software adaptive timing for the polling loop:

```swift
class AdaptiveTiming {
    private var currentTimeout: Int = 200  // ms
    private var learnedMinimum: Int = 12   // ms
    private let resolution: Int = 4        // ms step
    private let maximum: Int = 1000        // ms

    func onNoData() {
        // Vehicle is slower than expected
        currentTimeout = min(currentTimeout + resolution, maximum)
        learnedMinimum = currentTimeout
    }

    func onSuccess() {
        // Can go faster
        currentTimeout = max(currentTimeout - resolution, learnedMinimum)
    }
}
```

This directly impacts dashboard refresh rate. Without it, either timeout is too high (slow updates) or too low (frequent NODATA responses).

### 3. ADOPT: Transport Abstraction

**From kotlin-obd-api's InputStream/OutputStream approach:**

SwiftOBD2 fork should define a transport protocol:

```swift
protocol OBDTransport: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    var connectionState: AsyncStream<ConnectionState> { get }
}
```

Then BLE, WiFi (future), and demo/simulator all conform to this protocol. This is cleaner than AndrOBD's approach of passing Android Handler objects.

### 4. ADOPT: Comprehensive NRC Handling

**From AndrOBD:**

Map every NRC to a display class and automatic reaction:

```swift
enum NRCReaction {
    case ignore    // e.g., "response pending" (0x78)
    case skip      // e.g., "sub-function not supported" - try next PID
    case repeat    // e.g., "busy repeat request" (0x21)
    case cancel    // e.g., "service not supported" - stop service loop
    case reset     // e.g., "general reject" - reset adapter
}
```

This prevents the polling loop from hanging or crashing on unexpected vehicle responses.

### 5. ADOPT: Per-Item Error Tracking

**From AndrOBD's `currErrorCount` / `MAX_ERROR_COUNT`:**

If a PID consistently fails to parse (3+ times in a row), disable it temporarily rather than crashing the whole polling loop. This handles vehicles that advertise PID support but return garbage for certain PIDs.

### 6. ADOPT: Demo/Simulation Mode

**From AndrOBD:**

Essential for development and testing. Implement at the transport layer:

```swift
class SimulatorTransport: OBDTransport {
    // Respond to AT commands with "OK"
    // Respond to 0100 with supported PIDs bitmask
    // Generate cycling data for data requests
    // Simulate multiline DTC responses
    // Simulate ECU detection with multiple addresses
}
```

AndrOBD's demo simulates the full ELM327 conversation including multi-ECU detection and multiline responses.

### 7. ADOPT: PID Locking for Dashboard

**From AndrOBD's `setFixedPid()`:**

When the user opens a dashboard with 6 gauges, only poll those 6 PIDs instead of all supported PIDs. This dramatically increases update rate (from maybe 1Hz cycling through 30+ PIDs to 5-10Hz for 6 PIDs).

```swift
class OBDPollingManager {
    var fixedPIDs: Set<Int>?  // nil = poll all, non-nil = poll only these

    func nextPID() -> Int {
        let pool = fixedPIDs ?? allSupportedPIDs
        // round-robin through pool
    }
}
```

### 8. ADOPT: Command Queue Pattern

**From AndrOBD's `cmdQueue`:**

Queue AT commands and OBD requests. Process on each `>` prompt. This is much cleaner than trying to manage concurrent writes to the ELM327 (which doesn't support concurrent requests).

```swift
actor OBDCommandQueue {
    private var queue: [String] = []

    func enqueue(_ command: String)
    func dequeueNext() -> String?
}
```

### 9. CONSIDER: Expression Evaluator for Formulas

**From AndroidOBD's EvalEx approach:**

Instead of writing Swift code for each PID formula, evaluate string expressions like `"((A*256)+B)/4"`. Swift doesn't have a built-in expression evaluator, but NSExpression or a lightweight library could work. Trade-off: slightly more overhead per calculation vs. massive reduction in per-PID code.

### 10. ADOPT: Multi-ECU Detection

**From AndrOBD:**

Enable headers, send 0100, parse ECU addresses from response headers. Essential for vehicles with multiple ECUs (engine + transmission + body). Without this, responses from multiple ECUs get mixed together.

### 11. DO NOT ADOPT

- AndrOBD's Java-style Observer pattern (PvChangeEvent/PvChangeListener) - Use Swift's @Observable instead
- AndrOBD's static mutable state (`static ElmProt elm`, `static PvList PidPvs`) - Use actor isolation
- kotlin-obd-api's `runBlocking` inside suspend functions - Use proper async/await
- AndroidOBD's `synchronized(BaseObdCommand::class.java)` - Use Swift actors
- AndrOBD's CSV format - Use JSON/Plist for iOS (better tooling, type safety)
- AndroidOBD's tight coupling to BluetoothSocket in init sequence

### 12. Priority Implementation Order for SwiftOBD2 Fork

1. **Transport abstraction** (protocol + BLE + Simulator implementations)
2. **Command queue** (prompt-driven, sequential processing)
3. **Data-driven PID definitions** (JSON/Plist, not hardcoded classes)
4. **NRC handling** (with reaction strategy)
5. **Multi-ECU detection** (essential for real vehicles)
6. **Adaptive timing** (significant UX improvement)
7. **PID locking** (dashboard performance)
8. **Per-item error tracking** (resilience)
9. **Demo mode** (development velocity)
10. **Expression evaluator for formulas** (extensibility)
