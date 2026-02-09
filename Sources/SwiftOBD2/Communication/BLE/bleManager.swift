/// BLE communication manager for OBD-II adapters via CoreBluetooth.

import Combine
import CoreBluetooth
import Foundation

public enum ConnectionState: Sendable {
    case disconnected
    case connecting
    case connectedToAdapter
    case connectedToVehicle
    case error

    public var description: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connectedToAdapter: return "Connected to Adapter"
        case .connectedToVehicle: return "Connected to Vehicle"
        case .error: return "Error"
        }
    }

    public var isConnected: Bool {
        switch self {
        case .connectedToAdapter, .connectedToVehicle:
            return true
        default:
            return false
        }
    }
}

// MARK: - Constants
enum BLEConstants {
    static let defaultTimeout: TimeInterval = 3.0
    static let scanDuration: TimeInterval = 10.0
    static let connectionTimeout: TimeInterval = 10.0
    static let retryDelay: TimeInterval = 0.5
    static let maxBufferSize = 1024
    static let bluetoothPowerOnTimeout: TimeInterval = 30.0
    static let pollingInterval: UInt64 = 100_000_000 // 100ms in nanoseconds
}

class BLEManager: NSObject, CommProtocol, BLEPeripheralManagerDelegate {
    static let RestoreIdentifierKey: String = "OBD2Adapter"

    // MARK: Properties

    @Published var connectionState: ConnectionState = .disconnected

    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }


    public weak var obdDelegate: OBDServiceDelegate?

    // Focused components
    private var centralManager: CBCentralManager!
    private let messageProcessor: BLEMessageProcessor
    private let characteristicHandler: BLECharacteristicHandler
    private let peripheralManager: BLEPeripheralManager
    private let peripheralScanner: BLEPeripheralScanner

    private var cancellables = Set<AnyCancellable>()
    private var centralManagerInitialized = false

    deinit {
        disconnectPeripheral()
        obdDebug("BLEManager deinitialized", category: .bluetooth)
    }

    // MARK: - Initialization

    override init() {
        messageProcessor = BLEMessageProcessor()
        characteristicHandler = BLECharacteristicHandler(messageProcessor: messageProcessor)
        peripheralManager = BLEPeripheralManager(characteristicHandler: characteristicHandler)
        peripheralScanner = BLEPeripheralScanner()
        super.init()
        peripheralManager.delegate = self
    }

    /// Creates CBCentralManager on first use. This is deferred from init() because
    /// CBCentralManager with state restoration can block the calling thread for seconds,
    /// and init() runs on the main thread during app launch.
    private func ensureCentralManager() {
        guard !centralManagerInitialized else { return }
        centralManagerInitialized = true

        let bleQueue = DispatchQueue(label: "com.swiftobd2.ble", qos: .userInitiated)
        centralManager = CBCentralManager(
            delegate: self,
            queue: bleQueue,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: true,
                CBCentralManagerOptionRestoreIdentifierKey: BLEManager.RestoreIdentifierKey,
            ]
        )
    }

    // MARK: - Central Manager Control Methods

    func startScanning(_ serviceUUIDs: [CBUUID]?) {
        ensureCentralManager()
        guard centralManager.state == .poweredOn else {
            obdWarning("Cannot start scanning - Bluetooth not powered on", category: .bluetooth)
            return
        }

        obdDebug("Starting BLE scan for services: \(serviceUUIDs?.map { $0.uuidString } ?? ["All"])", category: .bluetooth)

        // Use allowDuplicates: false for better performance - we don't need duplicate discovery events
        let scanOptions = [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        centralManager.scanForPeripherals(withServices: serviceUUIDs, options: scanOptions)
    }

    func stopScan() {
        guard centralManagerInitialized else { return }
        if centralManager.isScanning {
            obdDebug("Stopping BLE scan", category: .bluetooth)
            centralManager.stopScan()
        }
    }

    func disconnectPeripheral() {
        guard centralManagerInitialized,
              let peripheral = peripheralManager.connectedPeripheral else { return }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    // MARK: - Central Manager Delegate Methods

    func didUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            centralManagerDidPowerOn()
        case .poweredOff:
            obdWarning("Bluetooth powered off", category: .bluetooth)
            peripheralManager.connectedPeripheral = nil
            let oldState = connectionState
            connectionState = .disconnected
            OBDLogger.shared.logConnectionChange(from: oldState, to: connectionState)
            DispatchQueue.main.async {
                self.obdDelegate?.connectionStateChanged(state: .disconnected)
            }
        case .unsupported:
            obdError("Device does not support Bluetooth Low Energy", category: .bluetooth)
        case .unauthorized:
            obdError("App not authorized to use Bluetooth Low Energy", category: .bluetooth)
        case .resetting:
            obdWarning("Bluetooth is resetting", category: .bluetooth)
        default:
            obdError("Bluetooth in unexpected state: \(central.state.rawValue)", category: .bluetooth)
            connectionState = .error
            DispatchQueue.main.async {
                self.obdDelegate?.connectionStateChanged(state: .error)
            }
        }
    }

    func centralManagerDidPowerOn() {
        guard let device = peripheralManager.connectedPeripheral else {
            obdDebug("Bluetooth powered on, waiting for connectAsync()", category: .bluetooth)
            return
        }
        // Restored peripheral that's still connected: discover services directly
        // Restored peripheral that disconnected: re-establish connection
        if device.state == .connected {
            peripheralManager.setPeripheral(device)
        } else {
            connect(to: device)
        }
    }

    func didDiscover(_: CBCentralManager, peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        Task {
            await peripheralScanner.addDiscoveredPeripheral(peripheral, advertisementData: advertisementData, rssi: rssi)
        }
    }

    func connect(to peripheral: CBPeripheral) {
        ensureCentralManager()
        let peripheralName = peripheral.name ?? "Unnamed"
        obdInfo("Attempting connection to peripheral: \(peripheralName)", category: .bluetooth)

        let oldState = connectionState
        connectionState = .connecting
        OBDLogger.shared.logConnectionChange(from: oldState, to: connectionState)

        DispatchQueue.main.async {
            self.obdDelegate?.connectionStateChanged(state: .connecting)
        }

        centralManager.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        if centralManager.isScanning {
            centralManager.stopScan()
        }
    }

    func didConnect(_: CBCentralManager, peripheral: CBPeripheral) {
        obdInfo("Connected to peripheral: \(peripheral.name ?? "Unnamed")", category: .bluetooth)
        peripheralManager.setPeripheral(peripheral)
        // Note: connectionState will be set to .connectedToAdapter in peripheralManager delegate
    }

    func didFailToConnect(_: CBCentralManager, peripheral: CBPeripheral, error: Error?) {
        let peripheralName = peripheral.name ?? "Unnamed"
        let errorMsg = error?.localizedDescription ?? "Unknown error"
        obdError("Connection failed to peripheral: \(peripheralName) - \(errorMsg)", category: .bluetooth)

        let oldState = connectionState
        connectionState = .error
        OBDLogger.shared.logConnectionChange(from: oldState, to: connectionState)

        DispatchQueue.main.async {
            self.obdDelegate?.connectionStateChanged(state: .error)
        }
    }

    func didDisconnect(_: CBCentralManager, peripheral: CBPeripheral, error: Error?) {
        let peripheralName = peripheral.name ?? "Unnamed"
        if let error = error {
            obdWarning("Unexpected disconnection from \(peripheralName): \(error.localizedDescription)", category: .bluetooth)
        } else {
            obdInfo("Disconnected from peripheral: \(peripheralName)", category: .bluetooth)
        }
        resetConfigure()
    }

    func willRestoreState(_: CBCentralManager, dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let peripheral = peripherals.first {
            obdDebug("Restoring peripheral: \(peripheral.name ?? "Unnamed")", category: .bluetooth)
            // Store only - do NOT trigger discovery until centralManager is .poweredOn
            peripheralManager.storePeripheral(peripheral)
        }
    }

    func connectionEventDidOccur(_: CBCentralManager, event: CBConnectionEvent, peripheral _: CBPeripheral) {
        obdError("Unexpected connection event: \(event.rawValue)", category: .bluetooth)
    }

    // MARK: - Async Methods

    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral? = nil) async throws {
        ensureCentralManager()
        try await waitForPoweredOn()

        if connectionState.isConnected {
            obdInfo("Already connected to peripheral", category: .bluetooth)
            return
        }

        let targetPeripheral: CBPeripheral
        if let peripheral = peripheral {
            targetPeripheral = peripheral
        } else {
            startScanning(BLEPeripheralScanner.supportedServices)
            targetPeripheral = try await peripheralScanner.waitForFirstPeripheral(timeout: timeout)
        }

        connect(to: targetPeripheral)

        try await peripheralManager.waitForCharacteristicsSetup(timeout: timeout)
    }

    func peripheralManager(_ manager: BLEPeripheralManager, didSetupCharacteristics peripheral: CBPeripheral) {
        let oldState = connectionState
        connectionState = .connectedToAdapter
        OBDLogger.shared.logConnectionChange(from: oldState, to: connectionState)

        // Dispatch delegate call to main queue since it might update UI
        DispatchQueue.main.async {
            self.obdDelegate?.connectionStateChanged(state: .connectedToAdapter)
        }

        obdInfo("Characteristics setup complete, connected to adapter", category: .bluetooth)
    }

    func waitForPoweredOn() async throws {
        let maxWaitTime = BLEConstants.bluetoothPowerOnTimeout
        let startTime = CFAbsoluteTimeGetCurrent()

        while centralManager.state != .poweredOn {
            // Check for timeout
            if CFAbsoluteTimeGetCurrent() - startTime > maxWaitTime {
                obdError("Bluetooth failed to power on within \(maxWaitTime) seconds", category: .bluetooth)
                throw BLEManagerError.timeout
            }

            // Check for terminal states
            switch centralManager.state {
            case .unsupported:
                throw BLEManagerError.unsupported
            case .unauthorized:
                throw BLEManagerError.unauthorized
            case .poweredOff:
                obdWarning("Bluetooth is powered off - waiting...", category: .bluetooth)
            case .resetting:
                obdDebug("Bluetooth is resetting - waiting...", category: .bluetooth)
            default:
                break
            }

            try await Task.sleep(nanoseconds: BLEConstants.pollingInterval)
        }

        obdDebug("Bluetooth powered on successfully", category: .bluetooth)
    }


    /// Sends a message to the connected peripheral and returns the response.
    /// - Parameters:
    ///   - command: The command to send.
    ///   - retries: Number of retries (currently unused, reserved for future implementation).
    /// - Returns: The response from the peripheral.
    func sendCommand(_ command: String, retries: Int = 3) async throws -> [String] {
        guard let peripheral = peripheralManager.connectedPeripheral else {
            obdError("Missing peripheral or ECU characteristic", category: .bluetooth)
            throw BLEManagerError.missingPeripheralOrCharacteristic
        }

        obdDebug("Sending command: \(command)", category: .communication)

        do {
            try characteristicHandler.writeCommand(command, to: peripheral)
            let response = try await messageProcessor.waitForResponse(timeout: BLEConstants.defaultTimeout)
            obdDebug("Command response: \(response.joined(separator: " | "))", category: .communication)
            return response
        } catch {
            obdError("Command failed: \(command) - \(error.localizedDescription)", category: .communication)
            throw error
        }
    }


    func scanForPeripherals() async throws {
        startScanning(nil)
        try await Task.sleep(nanoseconds: UInt64(BLEConstants.scanDuration * 1_000_000_000))
        stopScan()
    }

    private func resetConfigure() {
        if centralManagerInitialized { stopScan() }
        characteristicHandler.reset()
        peripheralManager.reset()

        Task {
            await peripheralScanner.reset()
            await messageProcessor.reset()
        }

        let oldState = connectionState
        connectionState = .disconnected
        if oldState != connectionState {
            OBDLogger.shared.logConnectionChange(from: oldState, to: connectionState)

            DispatchQueue.main.async {
                self.obdDelegate?.connectionStateChanged(state: .disconnected)
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate, CBPeripheralDelegate

/// Extension to conform to CBCentralManagerDelegate and CBPeripheralDelegate
/// and handle the delegate methods.
extension BLEManager: CBCentralManagerDelegate {

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        didDiscover(central, peripheral: peripheral, advertisementData: advertisementData, rssi: RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        didConnect(central, peripheral: peripheral)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        didUpdateState(central)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        didFailToConnect(central, peripheral: peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        didDisconnect(central, peripheral: peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        willRestoreState(central, dict: dict)
    }
}

enum BLEManagerError: Error, CustomStringConvertible {
    case missingPeripheralOrCharacteristic
    case noData
    case peripheralNotConnected
    case sendingMessagesInProgress
    case timeout
    case peripheralNotFound
    case unknownError
    case unsupported
    case unauthorized

    public var description: String {
        switch self {
        case .missingPeripheralOrCharacteristic:
            return "Error: Device not connected. Make sure the device is correctly connected."
        case .noData:
            return "Error: No Data"
        case .peripheralNotConnected:
            return "Error: Peripheral not connected"
        case .sendingMessagesInProgress:
            return "Error: Sending messages in progress"
        case .timeout:
            return "Error: Timeout"
        case .peripheralNotFound:
            return "Error: Peripheral not found"
        case .unknownError:
            return "Unknown Error"
        case .unsupported:
            return "Error: Device does not support Bluetooth Low Energy"
        case .unauthorized:
            return "Error: App not authorized to use Bluetooth Low Energy"
        }
    }
}
