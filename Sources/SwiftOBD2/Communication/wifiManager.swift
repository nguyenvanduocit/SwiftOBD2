//
//  wifiManager.swift
//
//
//  Created by kemo konteh on 2/26/24.
//

import CoreBluetooth
import Foundation
import Network
import os

protocol CommProtocol {
    func sendCommand(_ command: String, retries: Int) async throws -> [String]
    func disconnectPeripheral()
    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral?) async throws
    func scanForPeripherals() async throws
    var connectionStatePublisher: Published<ConnectionState>.Publisher { get }
    var obdDelegate: OBDServiceDelegate? { get set }
}

enum CommunicationError: Error {
    case invalidData
    case errorOccurred(Error)
}

class WifiManager: CommProtocol {
    @Published var connectionState: ConnectionState = .disconnected

    var obdDelegate: OBDServiceDelegate?

    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }

    var tcp: NWConnection?

    func connectAsync(timeout _: TimeInterval, peripheral _: CBPeripheral? = nil) async throws {
        let host = NWEndpoint.Host("192.168.0.10")
        guard let port = NWEndpoint.Port("35000") else {
            throw CommunicationError.invalidData
        }
        tcp = NWConnection(host: host, port: port, using: .tcp)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let hasResumed = OSAllocatedUnfairLock(initialState: false)
            tcp?.stateUpdateHandler = { [weak self] newState in
                guard let self else { return }
                switch newState {
                case .ready:
                    guard hasResumed.withLock({ let old = $0; $0 = true; return !old }) else { return }
                    self.connectionState = .connectedToAdapter
                    obdInfo("Connected to \(host.debugDescription):\(port.debugDescription)", category: .wifi)
                    continuation.resume(returning: ())
                case let .waiting(error):
                    obdWarning("Connection waiting: \(error.localizedDescription)", category: .wifi)
                case let .failed(error):
                    guard hasResumed.withLock({ let old = $0; $0 = true; return !old }) else { return }
                    self.connectionState = .disconnected
                    obdError("Connection failed: \(error.localizedDescription)", category: .wifi)
                    continuation.resume(throwing: CommunicationError.errorOccurred(error))
                case .cancelled:
                    guard hasResumed.withLock({ let old = $0; $0 = true; return !old }) else { return }
                    self.connectionState = .disconnected
                    obdInfo("Connection cancelled", category: .wifi)
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            tcp?.start(queue: .main)
        }
    }

    func sendCommand(_ command: String, retries: Int) async throws -> [String] {
        guard let data = "\(command)\r".data(using: .ascii) else {
            throw CommunicationError.invalidData
        }
        obdInfo("Sending: \(command)", category: .wifi)
        return try await sendCommandInternal(data: data, retries: retries)
    }

    private func sendCommandInternal(data: Data, retries: Int) async throws -> [String] {
        for attempt in 1 ... retries {
            do {
                let response = try await sendAndReceiveData(data)
                if let lines = processResponse(response) {
                    return lines
                } else if attempt < retries {
                    obdInfo("No data received, retrying attempt \(attempt + 1) of \(retries)...", category: .wifi)
                    try await Task.sleep(nanoseconds: 100_000_000) // 0.5 seconds delay
                }
            } catch {
                if attempt == retries {
                    throw error
                }
                obdWarning("Attempt \(attempt) failed, retrying: \(error.localizedDescription)", category: .wifi)
            }
        }
        throw CommunicationError.invalidData
    }

    private func sendAndReceiveData(_ data: Data) async throws -> String {
        guard let tcpConnection = tcp else {
             throw CommunicationError.invalidData
         }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            tcpConnection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    obdError("Error sending data: \(error.localizedDescription)", category: .wifi)
                    continuation.resume(throwing: CommunicationError.errorOccurred(error))
                    return
                }

                tcpConnection.receive(minimumIncompleteLength: 1, maximumLength: 500) { data, _, _, error in
                    if let error = error {
                        obdError("Error receiving data: \(error.localizedDescription)", category: .wifi)
                        continuation.resume(throwing: CommunicationError.errorOccurred(error))
                        return
                    }

                    guard let response = data, let responseString = String(data: response, encoding: .utf8) else {
                        obdWarning("Received invalid or empty data", category: .wifi)
                        continuation.resume(throwing: CommunicationError.invalidData)
                        return
                    }

                    continuation.resume(returning: responseString)
                }
            })
        }
    }

    private func processResponse(_ response: String) -> [String]? {
        obdInfo("Processing response: \(response)", category: .wifi)
        var lines = response.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard !lines.isEmpty else {
            obdWarning("Empty response lines", category: .wifi)
            return nil
        }

        if lines.last?.contains(">") == true {
            lines.removeLast()
        }

        if lines.first?.lowercased() == "no data" {
            return nil
        }

        return lines
    }

    func disconnectPeripheral() {
        tcp?.cancel()
    }

    func scanForPeripherals() async throws {}
}
