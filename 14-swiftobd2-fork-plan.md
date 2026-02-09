# SwiftOBD2 Fork Plan

Research về các thư viện OBD-II trên các nền tảng, các vấn đề cần fix, và gợi ý kiến trúc khi fork SwiftOBD2.

## Tại sao phải fork

SwiftOBD2 là **thư viện Swift duy nhất khả thi** cho BLE OBD-II trên iOS. Không có alternative nào:

| Library | Stars | Vấn đề |
|---------|-------|--------|
| LTSupportAutomotive | 244 | Objective-C, bugfix-only từ 2023, không async/await |
| obd2-swift-lib | 159 | Abandoned 2019, **không có BLE** |
| OBD2Kit | 227 | Obj-C, dormant 2021, chỉ 5 commits |
| OBD2_BLE | 12 | Archived 2019, minimal |
| SwiftELM327 | 26 | 18 commits, no docs |

SwiftOBD2 (121 stars, MIT, last commit Dec 2024) là lựa chọn duy nhất nhưng có nhiều bugs cần fix.

## Các thư viện tham khảo

### Swift/iOS BLE Wrappers

**AsyncBluetooth** (github.com/manolofdez/AsyncBluetooth)
- 195 stars, MIT, active Jan 2026
- Wraps CoreBluetooth với async/await
- Command queueing, type-safe data, thread safety
- Candidate để thay thế raw CBCentralManager trong fork

**AsyncCoreBluetooth** (github.com/meech-ward/AsyncCoreBluetooth)
- 23 stars, Apache 2.0, Jan 2025
- Swift 6 concurrency wrapper
- AsyncStream-based state monitoring

### Kotlin/Android

**kotlin-obd-api** (github.com/eltonvs/kotlin-obd-api) - 224 stars
- Transport-agnostic: `ObdDeviceConnection` nhận InputStream/OutputStream
- BLE, WiFi, USB đều plug in mà không sửa core code
- Command pattern: `ObdCommand` base class với tag, name, mode, pid, handler
- Response objects: `ObdResponse` (parsed + units) và `ObdRawResponse` (hex + timing)
- **Kiến trúc cleanest trong tất cả các library đã khảo sát**

**AndrOBD** (github.com/fr3ts0n/AndrOBD) - 1,900 stars
- Feature-complete nhất: BLE + WiFi + USB + Bluetooth Classic
- Plugin architecture (MQTT, GPS, accelerometer)
- Demo mode, chart visualization, HUD, CSV export
- 1,835 commits, 62 releases

**AndroidOBD** (github.com/barnhill/AndroidOBD) - 77 stars
- Active (Nov 2025), Kotlin 100%
- Auto PID formula calculations

### Other Languages (Architecture Reference)

**python-OBD** (github.com/brendan-w/python-OBD) - 1,200 stars
- Layered: Main API → OBDCommand → elm327 → decoders → protocol → pyserial
- Unit-aware responses via Pint library (`response.value.to("mph")`)
- Auto-discovery supported PIDs từ vehicle

**ObdMetrics** (github.com/tzebrowski/ObdMetrics) - Java, 24 stars
- **JSON-defined PIDs** - không cần code changes khi thêm PID mới
- JavaScript formulas cho decode: `"parseFloat((A*256+B).toFixed(3))"`
- PID categories: `livedata` (poll liên tục), `metadata` (đọc 1 lần), `routine` (on-demand)
- Multi-ECU, CAN 11-bit và 29-bit header support
- Runtime diagnostics: min/max/mean statistics per PID

**ELMduino** (github.com/PowerBroker2/ELMduino) - C++, 848 stars
- State machine pattern cho non-blocking polling
- Poll `nb_rx_state` thay vì blocking - phù hợp cho 10Hz gauge updates

**ecu_diagnostics** (github.com/rnd-ash/ecu_diagnostics) - Rust, 216 stars
- Unified diagnostic server cho OBD-2, KWP2000, UDS
- Type-safe request/response preventing invalid ECU commands
- Auto ECU disconnect detection và recovery

## Bugs cần fix (ưu tiên cao → thấp)

### P0: BLE Race Condition khi app launch

**File:** `bleManager.swift` → `centralManagerDidPowerOn()`

```swift
// HIỆN TẠI: Auto-scan khi BLE power on, race với connectAsync()
func centralManagerDidPowerOn() {
    guard let device = peripheralManager.connectedPeripheral else {
        startScanning(BLEPeripheralScanner.supportedServices)  // ← orphan scan
        return
    }
    connect(to: device)
}
```

**Vấn đề:** `centralManagerDidPowerOn()` gọi `startScanning()` mà không ai consume kết quả. Khi `connectAsync()` gọi `startScanning()` lần 2, CoreBluetooth với `allowDuplicates: false` không report peripheral lại → `waitForFirstPeripheral()` timeout.

**Fix:** Xóa auto-scan. Chỉ scan khi explicitly gọi qua `connectAsync()`.

```swift
func centralManagerDidPowerOn() {
    guard let device = peripheralManager.connectedPeripheral else {
        // Không auto-scan. Để connectAsync() quản lý scan lifecycle.
        return
    }
    connect(to: device)
}
```

### P0: BLE Reconnection Failures (Issue #41)

**5 defects trong BLEManager:**

1. **Silent connection failure** - `cancelPeripheralConnection` là async nhưng code xử lý như sync. Disconnect chưa xong đã connect lại → fail
2. **foundPeripherals never cleared** - Array chỉ append, không bao giờ reset → peripheral cũ (đã disconnect) vẫn được return
3. **Data buffer not cleared** - `BLEMessageProcessor` buffer không reset khi disconnect → response corruption
4. **Dangling completion handlers** - `foundPeripheralCompletion` trong `BLEPeripheralScanner` không cleanup → continuation leak
5. **Thread safety** - `foundPeripherals` và `foundPeripheralCompletion` accessed từ cả bleQueue và async context mà không sync

**Fix cần thiết cho `resetConfigure()`:**

```swift
private func resetConfigure() {
    characteristicHandler.reset()
    peripheralScanner.foundPeripherals.removeAll()     // Clear stale peripherals
    peripheralScanner.foundPeripheralCompletion = nil   // Clear dangling completion
    messageProcessor.reset()                            // Clear data buffer

    let oldState = connectionState
    connectionState = .disconnected
    if oldState != connectionState {
        OBDLogger.shared.logConnectionChange(from: oldState, to: connectionState)
        DispatchQueue.main.async {
            self.obdDelegate?.connectionStateChanged(state: .disconnected)
        }
    }
}
```

### P0: Batch PID Response Parsing — Silent Data Corruption

**File:** `obd2service.swift` → `requestPIDs()`, `elm327.swift` → `BatchedResponse`

`requestPIDs` gom nhiều PIDs vào 1 command (`"010C0D05"`) rồi parse response **tuần tự theo thứ tự request**. Nhưng OBD-II spec (ISO 15765) **không đảm bảo** ECU trả PIDs theo thứ tự request. Khi ECU reorder → `BatchedResponse.extractValue()` gán sai bytes cho sai PIDs → tất cả giá trị sai, giống random.

**Cách reproduce:** Request 6+ PIDs batch, quan sát dashboard — giá trị nhảy lung tung giữa các lần poll.

**Tại sao legacy protocols không bị:** `protocol_legacy.swift` có sort frames theo order byte (`frame.data[2]`). CAN protocol (`protocol_can.swift`) **không có xử lý tương đương**.

**`BatchedResponse` hiện tại (có bug):**

```swift
mutating func extractValue(_ cmd: OBDCommand) -> MeasurementResult? {
    let size = cmd.properties.bytes
    let valueData = response.prefix(size)   // ← Giả sử bytes đầu = PID này
    response.removeFirst(size)              // ← Consume tuần tự, không validate
    return cmd.properties.decode(data: valueData, unit: unit)
}
```

**Fix:** Match PID echo byte trong response thay vì assume thứ tự:

```swift
mutating func extractValue(_ cmd: OBDCommand) -> MeasurementResult? {
    let pidByte = UInt8(cmd.properties.command.dropFirst(2), radix: 16)!
    let size = cmd.properties.bytes

    // Tìm PID echo byte trong response thay vì assume position
    guard let offset = response.firstIndex(of: pidByte) else { return nil }

    let start = response.index(response.startIndex, offsetBy: response.distance(from: response.startIndex, to: offset))
    guard response.distance(from: start, to: response.endIndex) >= size else { return nil }

    let valueData = response[start..<response.index(start, offsetBy: size)]
    response.removeSubrange(start..<response.index(start, offsetBy: size))
    return cmd.properties.decode(data: Data(valueData), unit: unit)
}
```

**Workaround hiện tại trong ODBInsight:** Request từng PID riêng lẻ (`requestPIDs([singlePid])`) để tránh reorder. Chậm hơn nhưng data đúng.

### P1: Thread Safety trong BLEPeripheralScanner

`addDiscoveredPeripheral` chạy trên bleQueue. `waitForFirstPeripheral` chạy trên async executor. Cả hai access `foundPeripherals` và `foundPeripheralCompletion` mà không sync.

**Fix:** Dùng actor hoặc dispatch queue cho scanner state.

### P1: WiFi IP hardcoded

`WifiManager` hardcode `192.168.0.10:35000`. Cần configurable.

### P2: Low test coverage

Chỉ 7 test files, basic tests. Cần unit tests cho:
- ELM327 command parsing
- Protocol detection
- PID decoding
- BLE state machine transitions

## Gợi ý kiến trúc khi fork

### 1. Transport Abstraction (học từ kotlin-obd-api)

Hiện tại SwiftOBD2 couple BLE/WiFi/Mock thành separate manager classes. Nên abstract thành protocol:

```swift
protocol OBDTransport: Sendable {
    var connectionState: AsyncStream<ConnectionState> { get }
    func connect(timeout: TimeInterval) async throws
    func disconnect()
    func send(_ data: Data) async throws
    func receive() -> AsyncStream<Data>
}

// Implementations
final class BLETransport: OBDTransport { ... }
final class WiFiTransport: OBDTransport { ... }
final class MockTransport: OBDTransport { ... }
```

Lợi ích: Thêm transport mới (USB, Bluetooth Classic cho Android) mà không sửa core logic.

### 2. AsyncBluetooth thay raw CBCentralManager

CBCentralManager delegate-based API là nguồn gốc của race conditions. AsyncBluetooth (github.com/manolofdez/AsyncBluetooth) wrap nó thành async/await clean:

```swift
// Thay vì delegate callbacks + completions
let peripheral = try await centralManager.scanForPeripherals(withServices: services)
try await centralManager.connect(peripheral)
let services = try await peripheral.discoverServices(serviceUUIDs)
```

Loại bỏ hoàn toàn class `BLEPeripheralScanner`, `BLEPeripheralManager`, và phần lớn delegate code.

### 3. PID Categories (học từ ObdMetrics)

Phân loại PID theo tần suất đọc:

```swift
enum PIDCategory {
    case livedata    // RPM, speed, throttle - poll liên tục 10Hz
    case metadata    // VIN, supported PIDs - đọc 1 lần khi connect
    case routine     // DTC read/clear - on-demand
}
```

Tối ưu polling: không waste bandwidth đọc VIN mỗi 100ms.

### 4. Background BLE State Restoration (học từ OBD2_BLE)

SwiftOBD2 đã có `CBCentralManagerOptionRestoreIdentifierKey` nhưng `willRestoreState` chỉ set peripheral mà không trigger reconnect. Cần:

```swift
func willRestoreState(_ central: CBCentralManager, dict: [String: Any]) {
    if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
       let peripheral = peripherals.first {
        peripheralManager.setPeripheral(peripheral)
        // Trigger reconnect khi centralManagerDidPowerOn() fires
    }
}
```

### 5. Swift 6 Concurrency

SwiftOBD2 dùng `@Published` + Combine + DispatchQueue mix. Khi fork, migrate sang:
- `@Observable` thay `ObservableObject`
- `AsyncStream` thay `@Published` publishers
- Actor isolation thay DispatchQueue synchronization
- Strict concurrency checking

### 6. Non-blocking State Machine cho Polling (học từ ELMduino)

Thay vì sequential await cho mỗi PID:

```swift
// Hiện tại: sequential, blocking
for pid in pids {
    let result = try await sendCommand(pid)  // Đợi response trước khi gửi tiếp
}

// Tốt hơn: batched request (đã có trong SwiftOBD2 nhưng cần optimize)
// Gom nhiều PID vào 1 request: "01" + "0C0D05" thay vì 3 requests riêng
```

SwiftOBD2 đã có batched PID request nhưng **batch parsing bị bug** (xem P0: Batch PID Response Parsing). Phải fix PID echo matching trước khi dùng batch cho production.

## Phân pha fork

### Phase 1: Fix critical bugs (trước MVP)
- [ ] Fix P0: Xóa orphan scan trong `centralManagerDidPowerOn()`
- [ ] Fix P0: BLE reconnection (Issue #41) - reset state properly
- [ ] Fix P0: Batch PID response parsing — match PID echo bytes thay vì assume order
- [ ] Fix P1: Thread safety trong BLEPeripheralScanner
- [ ] Thêm unit tests cho ELM327 parsing

### Phase 2: Architecture improvements (sau MVP)
- [ ] Transport abstraction protocol
- [ ] Cân nhắc AsyncBluetooth integration
- [ ] PID categories
- [ ] Swift 6 strict concurrency

### Phase 3: Feature additions (post-launch)
- [ ] JSON-defined custom PIDs (cho Ford Mode 22)
- [ ] Configurable WiFi endpoint
- [ ] Connection quality monitoring
- [ ] Retry logic với exponential backoff
