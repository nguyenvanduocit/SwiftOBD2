//
//  mockManager.swift
//
//
//  Created by kemo konteh on 3/16/24.
//

import Foundation

import CoreBluetooth

enum CommandAction {
    case setHeaderOn
    case setHeaderOff
    case echoOn
    case echoOff
}

struct MockECUSettings {
    var headerOn = true
    var echo = false
    var vinNumber = ""
}

class MOCKComm: CommProtocol {

    @Published var connectionState: ConnectionState = .disconnected
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    var obdDelegate: OBDServiceDelegate?

    var ecuSettings: MockECUSettings = .init()

    // State for smooth mock values (random walk instead of pure random)
    // Protected by lock — sendCommand is async and can be called concurrently
    private var lastValues: [String: Double] = [:]
    private let lastValuesLock = NSLock()

    func sendCommand(_ command: String, retries: Int = 3) async throws -> [String] {
        obdDebug("Mock sending command: \(command)", category: .communication)

        let prefix = String(command.prefix(2))
        if prefix == "01" || prefix == "06" || prefix == "09" {
            // Collect response bytes for all PIDs in the batch
            var responseBytes: [UInt8] = []

            for i in stride(from: 2, to: command.count, by: 2) {
                let index = command.index(command.startIndex, offsetBy: i)
                let nextIndex = command.index(command.startIndex, offsetBy: i + 2)
                let subCommand = prefix + String(command[index..<nextIndex])
                guard let hexStr = mockResponse(forCommand: subCommand) else {
                    return ["No Data"]
                }
                let bytes = hexStr.trimmingCharacters(in: .whitespaces)
                    .split(separator: " ")
                    .compactMap { UInt8($0, radix: 16) }
                responseBytes.append(contentsOf: bytes)
            }

            guard var mode = Int(command.prefix(2)) else { return [""] }
            mode += 40

            let header = ecuSettings.headerOn ? "7E8" : ""
            let payload = [UInt8(mode)] + responseBytes

            var frames = buildISOTPFrames(payload: payload, header: header)
            if ecuSettings.echo {
                frames.insert(" \(command)", at: 0)
            }
            return frames

        } else if command.hasPrefix("AT") {
            let action = String(command.dropFirst(2))
            var response: [String] = {
                // Handle ATSH with any header (e.g., "SH7E0", "SH726", " SH 7E0")
                let trimmed = action.replacingOccurrences(of: " ", with: "")
                if trimmed.hasPrefix("SH") {
                    return ["OK"]
                }
                switch action {
                case "D", "L0", "AT1", "SP0", "SP6", "STFF", "S0", "CAF1":
                    return ["OK"]
                case "Z":
                    return ["ELM327 v1.5"]
                case "H1":
                    ecuSettings.headerOn = true
                    return ["OK"]
                case "H0":
                    ecuSettings.headerOn = false
                    return ["OK"]
                case "E1":
                    ecuSettings.echo = true
                    return ["OK"]
                case "E0":
                    ecuSettings.echo = false
                    return ["OK"]
                case "DPN":
                    return ["06"]
                case "RV":
                    let v = smoothed("battVoltage", min: 12.4, max: 14.2, step: 0.05)
                    return [String(format: "%.1f", v)]
                default:
                    return ["NO DATA"]
                }
            }()
            if ecuSettings.echo {
                response.insert(command, at: 0)
            }
            return response

        } else if command == "03" {
            // 03 is a request for DTCs
            let dtcs = ["P0104", "U0207"]
            var response = ""
            // convert to hex
            for dtc in dtcs {
                var hexString = String(dtc.suffix(4))
                // 2 by 2
                hexString = hexString.chunked(by: 2).joined(separator: " ")
                response +=  hexString
                obdDebug("Generated DTC hex: \(hexString)", category: .communication)
            }
            var header = ""
            if ecuSettings.headerOn {
                header = "7E8"
            }
            let mode = "43"
            response = mode + " " + response
            let length = String(format: "%02X", response.count / 3 + 1)
            response = header + " " + length + " " + response
            while response.count < 26 {
                response.append(" 00")
            }
            return [response]
        } else if command.hasPrefix("22") {
            // Mode 22 (enhanced/manufacturer-specific) mock response
            var header = ""
            if ecuSettings.headerOn {
                header = "7E8"
            }
            // Generate mock response: 62 + PID echo + smooth data bytes
            let pidEcho = String(command.dropFirst(2)) // e.g., "1E1C"
            let key = "enh_\(pidEcho)"
            let b0 = Int(smoothed(key + "_0", min: 50, max: 200, step: 5))
            let b1 = Int(smoothed(key + "_1", min: 50, max: 200, step: 5))
            let dataBytes = String(format: "%02X %02X", b0, b1)
            var response = "62 \(pidEcho.chunked(by: 2).joined(separator: " ")) \(dataBytes)"
            let length = String(format: "%02X", response.replacingOccurrences(of: " ", with: "").count / 2)
            response = header + " " + length + " " + response
            while response.count < 28 {
                response.append(" 00")
            }
            return [response]
        } else {
            guard var response = mockResponse(forCommand: command) else {
                return ["No Data"]
            }
            response = command + response  + "\r\n\r\n>"
            var lines = response
                    .components(separatedBy: .newlines)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            lines.removeLast()
            return lines
        }
    }

    // MARK: - ISO-TP Frame Builder (byte-based, replaces buggy string-chunking)

    private func buildISOTPFrames(payload: [UInt8], header: String) -> [String] {
        func formatFrame(_ bytes: [UInt8]) -> String {
            let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            return header.isEmpty ? hex : header + " " + hex
        }

        if payload.count <= 7 {
            // Single frame: PCI byte (0x0N where N = length) + payload + padding
            var frame: [UInt8] = [UInt8(payload.count)] + payload
            while frame.count < 8 { frame.append(0x00) }
            return [formatFrame(frame)]
        }

        // Multi-frame ISO-TP
        var remaining = Array(payload)
        var frames: [String] = []

        // First frame: [1X, XX] (total length in 12 bits) + up to 6 data bytes
        let totalLen = payload.count
        var ff: [UInt8] = [
            0x10 | UInt8((totalLen >> 8) & 0x0F),
            UInt8(totalLen & 0xFF)
        ]
        let ffCount = min(6, remaining.count)
        ff.append(contentsOf: remaining.prefix(ffCount))
        remaining.removeFirst(ffCount)
        while ff.count < 8 { ff.append(0x00) }
        frames.append(formatFrame(ff))

        // Consecutive frames: [2X] (sequence 0-F) + up to 7 data bytes
        var seq: UInt8 = 1
        while !remaining.isEmpty {
            var cf: [UInt8] = [0x20 | (seq & 0x0F)]
            let cfCount = min(7, remaining.count)
            cf.append(contentsOf: remaining.prefix(cfCount))
            remaining.removeFirst(cfCount)
            while cf.count < 8 { cf.append(0x00) }
            frames.append(formatFrame(cf))
            seq += 1
        }

        return frames
    }

    // MARK: - Smooth Value Generation

    private func smoothed(_ key: String, min: Double, max: Double, step: Double) -> Double {
        lastValuesLock.lock()
        defer { lastValuesLock.unlock() }
        let prev = lastValues[key] ?? Double.random(in: min...max)
        let delta = Double.random(in: -step...step)
        let next = Swift.min(max, Swift.max(min, prev + delta))
        lastValues[key] = next
        return next
    }

    // MARK: - Mock PID Responses

    private func mockResponse(forCommand command: String) -> String? {
        guard let obd2Command = OBDCommand.from(command: command) else {
            obdWarning("Invalid mock command: \(command)", category: .communication)
            return "Invalid command"
        }

        switch obd2Command {
        case .mode1(let command):
            switch command {
            case .pidsA:
                return "00 BE 3F A8 13 00"
            case .status:
                return "01 12 34 56 78 00"
            case .pidsB:
                return "20 90 07 E0 11 00"
            case .pidsC:
                return "40 FA DC 80 00 00"
            case .rpm:
                let rpm = Int(smoothed("rpm", min: 800, max: 3500, step: 80))
                let encoded = rpm * 4
                return String(format: "0C %02X %02X", encoded >> 8, encoded & 0xFF)
            case .speed:
                let speed = Int(smoothed("speed", min: 0, max: 120, step: 3))
                return String(format: "0D %02X", speed)
            case .coolantTemp:
                let temp = Int(smoothed("coolant", min: 70, max: 105, step: 1))
                return String(format: "05 %02X", temp + 40)
            case .maf:
                let maf = Int(smoothed("maf", min: 5, max: 250, step: 10))
                let encoded = maf * 100
                return String(format: "10 %02X %02X", encoded >> 8, encoded & 0xFF)
            case .engineLoad:
                let load = smoothed("load", min: 15, max: 85, step: 5)
                return String(format: "04 %02X", Int(load * 2.55))
            case .throttlePos:
                let pos = smoothed("throttle", min: 10, max: 75, step: 4)
                return String(format: "11 %02X", Int(pos * 2.55))
            case .fuelLevel:
                let level = smoothed("fuel", min: 30, max: 80, step: 0.2)
                return String(format: "2F %02X", Int(level * 2.55))
            case .fuelPressure:
                let pressure = Int(smoothed("fuelPressure", min: 200, max: 400, step: 5))
                return String(format: "0A %02X", pressure / 3)
            case .intakeTemp:
                let temp = Int(smoothed("intakeTemp", min: 20, max: 60, step: 1))
                return String(format: "0F %02X", temp + 40)
            case .timingAdvance:
                let advance = smoothed("timing", min: 5, max: 40, step: 2)
                return String(format: "0E %02X", Int((advance + 64) * 2))
            case .intakePressure:
                let pressure = Int(smoothed("intakePressure", min: 20, max: 100, step: 3))
                return String(format: "0B %02X", pressure)
            case .barometricPressure:
                let pressure = Int(smoothed("barometric", min: 95, max: 105, step: 0.5))
                return String(format: "33 %02X", pressure)
            case .fuelType:
                return "51 01"
            case .fuelRailPressureDirect:
                let raw = Int(smoothed("fuelRailDirect", min: 2000, max: 5000, step: 50))
                return String(format: "23 %02X %02X", raw >> 8, raw & 0xFF)
            case .ethanoPercent:
                let pct = Int(smoothed("ethanol", min: 0, max: 15, step: 0.5))
                return String(format: "52 %02X", pct)
            case .engineOilTemp:
                let temp = Int(smoothed("oilTemp", min: 80, max: 120, step: 1))
                return String(format: "5C %02X", temp + 40)
            case .fuelInjectionTiming:
                let raw = Int(smoothed("injTiming", min: 5000, max: 35000, step: 500))
                return String(format: "5D %02X %02X", raw >> 8, raw & 0xFF)
            case .fuelRate:
                let rate = Int(smoothed("fuelRate", min: 3, max: 60, step: 2))
                return String(format: "5E %02X %02X", rate >> 8, rate & 0xFF)
            case .emissionsReq:
                return "01 01"
            case .runTime:
                // Run time increases monotonically (engine has been running)
                lastValuesLock.lock()
                let prev = lastValues["runTime"] ?? 300
                let next = prev + Double.random(in: 0.8...1.2)
                lastValues["runTime"] = next
                lastValuesLock.unlock()
                let t = Int(next)
                return String(format: "1F %02X %02X", t >> 8, t & 0xFF)
            case .distanceSinceDTCCleared:
                let dist = Int(smoothed("distDTC", min: 500, max: 6550, step: 1))
                return String(format: "31 %02X %02X", dist >> 8, dist & 0xFF)
            case .distanceWMIL:
                let dist = Int(smoothed("distMIL", min: 100, max: 6550, step: 1))
                return String(format: "21 %02X %02X", dist >> 8, dist & 0xFF)
            case .warmUpsSinceDTCCleared:
                let warmUp = Int(smoothed("warmups", min: 5, max: 40, step: 0.1))
                return String(format: "30 %02X", warmUp)
            case .hybridBatteryLife:
                let life = Int(smoothed("hybridBat", min: 5000, max: 60000, step: 50))
                return String(format: "5B %02X %02X", life >> 8, life & 0xFF)
            default:
                return nil
            }
        case .mode6(let command):
            switch command {
                case .MIDS_A:
                    return "00 C0 00 00 01 00"
                case .MIDS_B:
                    return "02 C0 00 00 01 00"
                case .MIDS_C:
                    return "04 C0 00 00 01 00"
                case .MIDS_D:
                    return "06 C0 00 00 01 00"
                case .MIDS_E:
                    return "08 C0 00 00 01 00"
                case .MIDS_F:
                    return "0A C0 00 00 01 00"
                default:
                    return nil
            }
        case .mode9(let command):
            switch command {
            case .PIDS_9A:
                    return "00 55 40 00 00 00"
            case .VIN:
                return "02 01 31 4E 34 41 4C 33 41 50 37 44 43 31 39 39 35 38 33"
            default:
                return nil
            }
        default:
            obdDebug("No mock response for command: \(command)", category: .communication)
            return nil
        }
    }

    func disconnectPeripheral() {
        connectionState = .disconnected
        obdDelegate?.connectionStateChanged(state: .disconnected)
    }

    func connectAsync(timeout: TimeInterval, peripheral: CBPeripheral? = nil) async throws {
        connectionState = .connectedToAdapter
        obdDelegate?.connectionStateChanged(state: .connectedToAdapter)
    }

    func scanForPeripherals() async throws {

    }
}

extension String {
    func chunked(by chunkSize: Int) -> Array<String> {
        return stride(from: 0, to: self.count, by: chunkSize).map {
            String(self[self.index(self.startIndex, offsetBy: $0)..<self.index(self.startIndex, offsetBy: min($0 + chunkSize, self.count))])
        }
    }
}
