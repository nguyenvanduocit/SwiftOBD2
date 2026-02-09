import Combine
import CoreBluetooth
import Foundation

/// Focused component responsible for BLE device discovery and peripheral management
actor BLEPeripheralScanner {
    private var foundPeripherals: [CBPeripheral] = []

    nonisolated let peripheralSubject = PassthroughSubject<CBPeripheral, Never>()

    nonisolated var peripheralPublisher: AnyPublisher<CBPeripheral, Never> {
        peripheralSubject.eraseToAnyPublisher()
    }

    nonisolated static let supportedServices = [
        CBUUID(string: "FFE0"),
        CBUUID(string: "FFF0"),
        CBUUID(string: "18F0"), // e.g. VGate iCar Pro
    ]

    private var foundPeripheralCompletion: ((CBPeripheral?, Error?) -> Void)?

    func addDiscoveredPeripheral(_ peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        guard rssi.intValue < 0 else { return }

        DispatchQueue.main.async { [self] in
            if let index = foundPeripherals.firstIndex(where: { $0.identifier == peripheral.identifier }) {
                foundPeripherals[index] = peripheral
            } else {
                foundPeripherals.append(peripheral)
                peripheralSubject.send(peripheral)
                obdInfo("Found new peripheral: \(peripheral.name ?? "Unnamed") - RSSI: \(rssi)", category: .bluetooth)
            }

            let completion = foundPeripheralCompletion
            foundPeripheralCompletion = nil
            completion?(peripheral, nil)
        }
    }

    func waitForFirstPeripheral(timeout: TimeInterval) async throws -> CBPeripheral {
        if let first = foundPeripherals.first {
            return first
        }

        return try await withTimeout(seconds: timeout, timeoutError: BLEScannerError.scanTimeout) {
            try await withCheckedThrowingContinuation { continuation in
                self.assumeIsolated { isolatedSelf in
                    isolatedSelf.foundPeripheralCompletion = { peripheral, error in
                        if let peripheral = peripheral {
                            continuation.resume(returning: peripheral)
                        } else if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(throwing: BLEScannerError.peripheralNotFound)
                        }
                    }
                }
            }
        }
    }

    func reset() {
        foundPeripherals.removeAll()
        foundPeripheralCompletion = nil
    }
}

// MARK: - Error Types

enum BLEScannerError: Error, LocalizedError {
    case centralManagerNotAvailable
    case bluetoothNotPoweredOn
    case scanTimeout
    case peripheralNotFound

    var errorDescription: String? {
        switch self {
        case .centralManagerNotAvailable:
            return "Bluetooth Central Manager is not available"
        case .bluetoothNotPoweredOn:
            return "Bluetooth is not powered on"
        case .scanTimeout:
            return "BLE scanning timed out"
        case .peripheralNotFound:
            return "No compatible BLE peripheral found"
        }
    }
}

/// Cancels the current operation and throws a timeout error.
func withTimeout<R>(
    seconds: TimeInterval,
    timeoutError: Error = BLEManagerError.timeout,
    onTimeout: (() -> Void)? = nil,
    operation: @escaping @Sendable () async throws -> R
) async throws -> R {
    try await withThrowingTaskGroup(of: R.self) { group in
        group.addTask {
            let result = try await operation()
            try Task.checkCancellation()
            return result
        }

        group.addTask {
            if seconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            try Task.checkCancellation()

            // Call cleanup handler if provided
            onTimeout?()
            throw timeoutError
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
