import Foundation
import CoreBluetooth
import Combine

protocol BLEPeripheralManagerDelegate: AnyObject {
    func peripheralManager(_ manager: BLEPeripheralManager, didSetupCharacteristics peripheral: CBPeripheral)
}

class BLEPeripheralManager: NSObject, ObservableObject {
    @Published var connectedPeripheral: CBPeripheral?
    private let characteristicHandler: BLECharacteristicHandler

    weak var delegate: BLEPeripheralManagerDelegate?
    private var connectionCompletion: ((CBPeripheral?, Error?) -> Void)?

    init(characteristicHandler: BLECharacteristicHandler) {
        self.characteristicHandler = characteristicHandler
        super.init()
    }

    /// Store a peripheral reference and set its delegate, without triggering service discovery.
    /// Use during state restoration when the central manager may not be powered on yet.
    func storePeripheral(_ peripheral: CBPeripheral) {
        connectedPeripheral?.delegate = nil
        connectedPeripheral = peripheral
        connectedPeripheral?.delegate = self
    }

    /// Store a peripheral and immediately trigger service discovery.
    /// Only call this when the central manager is confirmed `.poweredOn`.
    func setPeripheral(_ peripheral: CBPeripheral?) {
        if let peripheral = peripheral {
            storePeripheral(peripheral)
            peripheral.discoverServices(BLEPeripheralScanner.supportedServices)
        } else {
            connectedPeripheral?.delegate = nil
            connectedPeripheral = nil
        }
    }

    func reset() {
        connectedPeripheral?.delegate = nil
        connectedPeripheral = nil
        connectionCompletion = nil
    }

    func waitForCharacteristicsSetup(timeout: TimeInterval) async throws {
        try await withTimeout(seconds: timeout) { [self] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.connectionCompletion = { peripheral, error in
                    if peripheral != nil {
                        continuation.resume()
                    } else if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: BLEManagerError.unknownError)
                    }
                }
            }
        }
    }

    func didDiscoverServices(_ peripheral: CBPeripheral, error: Error?) {
        for service in peripheral.services ?? [] {
            obdInfo("Discovered service: \(service.uuid.uuidString)", category: .bluetooth)
            characteristicHandler.discoverCharacteristics(for: service, on: peripheral)
        }
    }

    func didDiscoverCharacteristics(_ peripheral: CBPeripheral, service: CBService, error: Error?) {
        if let error = error {
            obdError("Error discovering characteristics: \(error.localizedDescription)", category: .bluetooth)
            connectionCompletion?(nil, error)
            connectionCompletion = nil
            return
        }

        guard let characteristics = service.characteristics else { return }

        characteristicHandler.setupCharacteristics(characteristics, on: peripheral)

        if characteristicHandler.isReady {
            connectionCompletion?(peripheral, nil)
            connectionCompletion = nil
            delegate?.peripheralManager(self, didSetupCharacteristics: peripheral)
        } else {
            let error = BLEManagerError.missingPeripheralOrCharacteristic
            obdError("Required characteristics not found for service \(service.uuid.uuidString)", category: .bluetooth)
            connectionCompletion?(nil, error)
            connectionCompletion = nil
        }
    }

    func didUpdateValue(_: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            obdError("Error reading characteristic value: \(error.localizedDescription)", category: .bluetooth)
            return
        }

        guard let data = characteristic.value else { return }
        characteristicHandler.handleUpdatedValue(data, from: characteristic)
    }
}

extension BLEPeripheralManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        didDiscoverServices(peripheral, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        didDiscoverCharacteristics(peripheral, service: service, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        didUpdateValue(peripheral, characteristic: characteristic, error: error)
    }
}
