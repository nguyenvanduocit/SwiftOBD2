# SwiftOBD2 (Fork)

Forked from [kkonteh97/SwiftOBD2](https://github.com/kkonteh97/SwiftOBD2). Swift Package for BLE/WiFi OBD-II communication via ELM327 adapters.

Used as the OBD-II foundation for the **ODBInsight** iOS app.

## Tech Stack

| Component | Choice |
|-----------|--------|
| Language | Swift (swift-tools-version 5.7.1) |
| Platforms | iOS 14+, macOS 12+ |
| BLE | CoreBluetooth (raw delegates) |
| Concurrency | Mix of Combine (@Published), DispatchQueue, async/await |
| License | MIT |

## Project Structure

```
Sources/SwiftOBD2/
├── Communication/       # BLE + WiFi managers, message processing
├── protocols/           # OBD-II protocol parsers (CAN, ISO, J1850, KWP)
├── Logging/             # OBD logger
├── Resources/           # Assets
├── elm327.swift         # ELM327 command layer, batch response parsing
├── obd2service.swift    # High-level OBD2 service (connect, requestPIDs, DTC)
├── commands.swift       # OBDCommand enum (all standard PIDs)
├── decoders.swift       # PID response decoders (bytes → values)
├── codes.swift          # DTC code definitions
├── parser.swift         # Response frame parsing
├── garage.swift         # Vehicle storage
└── Utils.swift          # Utilities
Tests/SwiftOBD2Tests/    # Unit tests (minimal coverage)
```

## Critical Bugs to Fix (Priority Order)

Detailed analysis in `14-swiftobd2-fork-plan.md`.

### P0: BLE Race Condition on App Launch
- **File:** `Communication/bleManager.swift` → `centralManagerDidPowerOn()`
- Orphan scan starts before `connectAsync()`, causing timeout
- **Fix:** Remove auto-scan, let `connectAsync()` manage scan lifecycle

### P0: BLE Reconnection Failures (Issue #41)
- **File:** `Communication/bleManager.swift`
- 5 defects: silent connection failure, stale peripherals, buffer corruption, dangling completions, thread safety
- **Fix:** Proper state reset in `resetConfigure()`

### P0: Batch PID Response Parsing — Silent Data Corruption
- **Files:** `obd2service.swift` → `requestPIDs()`, `elm327.swift` → `BatchedResponse`
- Assumes ECU returns PIDs in request order (not guaranteed by spec)
- **Fix:** Match PID echo bytes in response instead of sequential extraction

### P1: Thread Safety in BLEPeripheralScanner
- `foundPeripherals` and completion handlers accessed from multiple threads without synchronization
- **Fix:** Actor isolation or dedicated dispatch queue

### P1: WiFi IP Hardcoded
- `WifiManager` hardcodes `192.168.0.10:35000`
- **Fix:** Make configurable

## Fork Phases

### Phase 1: Fix critical bugs (before ODBInsight MVP)
- Fix P0 bugs (orphan scan, reconnection, batch parsing)
- Fix P1 thread safety
- Add unit tests for ELM327 parsing

### Phase 2: Architecture improvements (after MVP)
- Transport abstraction protocol
- Consider AsyncBluetooth integration
- PID categories (livedata/metadata/routine)
- Swift 6 strict concurrency migration

### Phase 3: Feature additions (post-launch)
- JSON-defined custom PIDs (Ford Mode 22)
- Configurable WiFi endpoint
- Connection quality monitoring
- Retry logic with exponential backoff

## Key Files for Common Tasks

| Task | File(s) |
|------|---------|
| BLE connection | `Communication/bleManager.swift` |
| WiFi connection | `Communication/` (WiFi manager) |
| ELM327 init & commands | `elm327.swift` |
| PID request/response | `obd2service.swift`, `commands.swift` |
| Response decoding | `decoders.swift`, `parser.swift` |
| Protocol detection | `protocols/` |
| DTC codes | `codes.swift` |
