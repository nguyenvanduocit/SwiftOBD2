//
//  ELM327IntegrationTests.swift
//  SwiftOBD2Tests
//
//  Comprehensive integration tests for ELM327 class and OBDCommand
//  using the MOCKComm mock transport.
//

@testable import SwiftOBD2
import XCTest

final class ELM327IntegrationTests: XCTestCase {

    // MARK: - setupVehicle Tests

    func testSetupVehicleDetectsProtocol6() async throws {
        let elm = ELM327(comm: MOCKComm())
        let info = try await elm.setupVehicle(preferredProtocol: nil)
        XCTAssertEqual(info.obdProtocol, .protocol6)
    }

    func testSetupVehicleReturnsVIN() async throws {
        let elm = ELM327(comm: MOCKComm())
        let info = try await elm.setupVehicle(preferredProtocol: nil)
        XCTAssertNotNil(info.vin)
        XCTAssertEqual(info.vin, "1N4AL3AP7DC199583")
    }

    func testSetupVehicleReturnsSupportedPIDs() async throws {
        let elm = ELM327(comm: MOCKComm())
        let info = try await elm.setupVehicle(preferredProtocol: nil)
        XCTAssertNotNil(info.supportedPIDs)
        XCTAssertFalse(info.supportedPIDs!.isEmpty)
    }

    func testSetupVehicleReturnsECUMap() async throws {
        let elm = ELM327(comm: MOCKComm())
        let info = try await elm.setupVehicle(preferredProtocol: nil)
        XCTAssertNotNil(info.ecuMap)
    }

    func testSetupVehicleWithPreferredProtocol() async throws {
        let elm = ELM327(comm: MOCKComm())
        let info = try await elm.setupVehicle(preferredProtocol: .protocol6)
        XCTAssertEqual(info.obdProtocol, .protocol6)
    }

    // MARK: - getSupportedPIDs Tests

    func testGetSupportedPIDs() async throws {
        let elm = ELM327(comm: MOCKComm())
        _ = try await elm.setupVehicle(preferredProtocol: nil)
        let pids = await elm.getSupportedPIDs()
        XCTAssertFalse(pids.isEmpty)

        // Based on mock's pidsA response "00 BE 3F A8 13 00":
        // Byte BE = 10111110 -> PIDs 01,03,04,05,06,07 supported
        // Byte 3F = 00111111 -> PIDs 0B,0C,0D,0E,0F,10 supported
        // Byte A8 = 10101000 -> PIDs 11,13,15 supported
        // Byte 13 = 00010011 -> PIDs 1C,1F,20 supported
        // Verify some known PIDs from the pidsA bitmask are present
        let pidCommands = pids.map { $0.properties.command }
        // RPM (010C) should be supported based on byte 3F bit pattern
        XCTAssertTrue(pidCommands.contains("010C"), "RPM should be a supported PID")
        // Speed (010D) should be supported
        XCTAssertTrue(pidCommands.contains("010D"), "Speed should be a supported PID")
        // Coolant temp (0105) should be supported
        XCTAssertTrue(pidCommands.contains("0105"), "Coolant temp should be a supported PID")
    }

    // MARK: - extractSupportedPIDs Tests

    func testExtractSupportedPIDsAllOnes() {
        let elm = ELM327(comm: MOCKComm())
        let allOnes = [Int](repeating: 1, count: 32)
        let pids = elm.extractSupportedPIDs(allOnes)
        XCTAssertEqual(pids.count, 32)
        XCTAssertTrue(pids.contains("01"))
        XCTAssertTrue(pids.contains("20"))
        XCTAssertTrue(pids.contains("10"))
    }

    func testExtractSupportedPIDsAllZeros() {
        let elm = ELM327(comm: MOCKComm())
        let allZeros = [Int](repeating: 0, count: 32)
        let noPids = elm.extractSupportedPIDs(allZeros)
        XCTAssertTrue(noPids.isEmpty)
    }

    func testExtractSupportedPIDsSpecificPattern() {
        let elm = ELM327(comm: MOCKComm())
        // bit 0=1, bit 1=0, bit 2=1 -> PIDs "01" and "03"
        let specific = [1, 0, 1, 0, 0, 0, 0, 0]
        let specificPids = elm.extractSupportedPIDs(specific)
        XCTAssertEqual(specificPids, Set(["01", "03"]))
    }

    func testExtractSupportedPIDsSingleBit() {
        let elm = ELM327(comm: MOCKComm())
        // Only bit at index 4 is set -> PID "05"
        var data = [Int](repeating: 0, count: 32)
        data[4] = 1
        let pids = elm.extractSupportedPIDs(data)
        XCTAssertEqual(pids.count, 1)
        XCTAssertTrue(pids.contains("05"))
    }

    func testExtractSupportedPIDsEmpty() {
        let elm = ELM327(comm: MOCKComm())
        let pids = elm.extractSupportedPIDs([])
        XCTAssertTrue(pids.isEmpty)
    }

    // MARK: - scanForTroubleCodes Tests

    func testScanForTroubleCodes() async throws {
        let elm = ELM327(comm: MOCKComm())
        _ = try await elm.setupVehicle(preferredProtocol: nil)
        let dtcs = try await elm.scanForTroubleCodes()
        XCTAssertFalse(dtcs.isEmpty)
        let allCodes = dtcs.values.flatMap { $0 }.map { $0.code }
        XCTAssertGreaterThan(allCodes.count, 0, "Should have decoded DTCs, got: \(allCodes)")
        // MOCKComm generates DTCs from ["P0104", "U0207"] but only encodes the
        // last 4 hex digits as raw bytes. The parseDTC function then decodes the
        // type prefix from the high bits of the first byte. Verify we get codes back.
        for code in allCodes {
            // All DTC codes should be 5 characters: letter + 4 hex digits
            XCTAssertEqual(code.count, 5, "DTC code '\(code)' should be 5 characters")
            let prefix = code.prefix(1)
            XCTAssertTrue(["P", "C", "B", "U"].contains(prefix), "DTC '\(code)' should start with P/C/B/U")
        }
    }

    // MARK: - sendCommand Tests

    func testSendATZCommand() async throws {
        let elm = ELM327(comm: MOCKComm())
        let response = try await elm.sendCommand("ATZ")
        XCTAssertTrue(response.contains("ELM327 v1.5"))
    }

    func testSendATDPNCommand() async throws {
        let elm = ELM327(comm: MOCKComm())
        let response = try await elm.sendCommand("ATDPN")
        XCTAssertTrue(response.contains("06"))
    }

    func testSendATH1Command() async throws {
        let elm = ELM327(comm: MOCKComm())
        let response = try await elm.sendCommand("ATH1")
        XCTAssertTrue(response.contains("OK"))
    }

    func testSendATH0Command() async throws {
        let elm = ELM327(comm: MOCKComm())
        let response = try await elm.sendCommand("ATH0")
        XCTAssertTrue(response.contains("OK"))
    }

    func testSendATE0Command() async throws {
        let elm = ELM327(comm: MOCKComm())
        let response = try await elm.sendCommand("ATE0")
        XCTAssertTrue(response.contains("OK"))
    }

    func testSendATSP0Command() async throws {
        let elm = ELM327(comm: MOCKComm())
        let response = try await elm.sendCommand("ATSP0")
        XCTAssertTrue(response.contains("OK"))
    }

    func testSendMode01CommandAfterSetup() async throws {
        let elm = ELM327(comm: MOCKComm())
        _ = try await elm.setupVehicle(preferredProtocol: nil)
        let response = try await elm.sendCommand("0100")
        XCTAssertFalse(response.isEmpty)
        // Should contain "41 00" (response to 0100) somewhere in the data
        let joined = response.joined(separator: " ")
        XCTAssertTrue(joined.contains("41"), "Mode 01 PID 00 response should contain mode echo 41")
    }

    // MARK: - requestVin Tests

    func testRequestVinAfterSetup() async throws {
        let elm = ELM327(comm: MOCKComm())
        _ = try await elm.setupVehicle(preferredProtocol: nil)
        let vin = await elm.requestVin()
        XCTAssertNotNil(vin)
        XCTAssertEqual(vin, "1N4AL3AP7DC199583")
    }

    // MARK: - getStatus Tests

    func testGetStatusAfterSetup() async throws {
        let elm = ELM327(comm: MOCKComm())
        _ = try await elm.setupVehicle(preferredProtocol: nil)
        let result = try await elm.getStatus()
        switch result {
        case .success(let decoded):
            XCTAssertNotNil(decoded.statusResult)
        case .failure(let error):
            XCTFail("getStatus decode failed: \(error)")
        }
    }

    // MARK: - OBDCommand.from() Tests

    func testOBDCommandFromRPM() {
        let cmd = OBDCommand.from(command: "010C")
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd, .mode1(.rpm))
    }

    func testOBDCommandFromSpeed() {
        let cmd = OBDCommand.from(command: "010D")
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd, .mode1(.speed))
    }

    func testOBDCommandFromCoolantTemp() {
        let cmd = OBDCommand.from(command: "0105")
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd, .mode1(.coolantTemp))
    }

    func testOBDCommandFromPidsA() {
        let cmd = OBDCommand.from(command: "0100")
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd, .mode1(.pidsA))
    }

    func testOBDCommandFromVIN() {
        let cmd = OBDCommand.from(command: "0902")
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd, .mode9(.VIN))
    }

    func testOBDCommandFromDTC() {
        let cmd = OBDCommand.from(command: "03")
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd, .mode3(.GET_DTC))
    }

    func testOBDCommandFromInvalidCommand() {
        let cmd = OBDCommand.from(command: "ZZZZ")
        XCTAssertNil(cmd)
    }

    func testOBDCommandFromEmptyString() {
        let cmd = OBDCommand.from(command: "")
        XCTAssertNil(cmd)
    }

    // MARK: - OBDCommand Properties Tests

    func testRPMCommandProperties() {
        let rpm = OBDCommand.mode1(.rpm)
        XCTAssertEqual(rpm.properties.command, "010C")
        XCTAssertEqual(rpm.properties.bytes, 3)
        XCTAssertTrue(rpm.properties.live)
        XCTAssertEqual(rpm.properties.maxValue, 8000)
    }

    func testSpeedCommandProperties() {
        let speed = OBDCommand.mode1(.speed)
        XCTAssertEqual(speed.properties.command, "010D")
        XCTAssertEqual(speed.properties.bytes, 2)
        XCTAssertTrue(speed.properties.live)
        XCTAssertEqual(speed.properties.maxValue, 280)
    }

    func testCoolantTempCommandProperties() {
        let temp = OBDCommand.mode1(.coolantTemp)
        XCTAssertEqual(temp.properties.command, "0105")
        XCTAssertEqual(temp.properties.bytes, 2)
        XCTAssertTrue(temp.properties.live)
        XCTAssertEqual(temp.properties.maxValue, 215)
        XCTAssertEqual(temp.properties.minValue, -40)
    }

    func testThrottlePosCommandProperties() {
        let throttle = OBDCommand.mode1(.throttlePos)
        XCTAssertEqual(throttle.properties.command, "0111")
        XCTAssertEqual(throttle.properties.bytes, 2)
        XCTAssertTrue(throttle.properties.live)
    }

    func testVINCommandProperties() {
        let vin = OBDCommand.mode9(.VIN)
        XCTAssertEqual(vin.properties.command, "0902")
        XCTAssertEqual(vin.properties.bytes, 22)
    }

    func testDTCCommandProperties() {
        let dtc = OBDCommand.mode3(.GET_DTC)
        XCTAssertEqual(dtc.properties.command, "03")
        XCTAssertEqual(dtc.properties.bytes, 0)
    }

    // MARK: - CommandProperties.decode Tests

    func testDecodeRPM() {
        let rpmCmd = OBDCommand.mode1(.rpm)
        // RPM uses UAS 0x07: scale=0.25, unit=rpm
        // Data: PID echo (0C) + A (0F) + B (A0)
        // After dropFirst: [0x0F, 0xA0]
        // bytesToInt = 0x0FA0 = 4000
        // 4000 * 0.25 = 1000 RPM
        let result = rpmCmd.properties.decode(data: Data([0x0C, 0x0F, 0xA0]))
        switch result {
        case .success(let decoded):
            XCTAssertNotNil(decoded.measurementResult)
            XCTAssertEqual(decoded.measurementResult!.value, 1000, accuracy: 0.01)
            XCTAssertEqual(decoded.measurementResult!.unit, Unit.rpm)
        case .failure(let error):
            XCTFail("RPM decode failed: \(error)")
        }
    }

    func testDecodeRPMZero() {
        let rpmCmd = OBDCommand.mode1(.rpm)
        // Data: PID echo (0C) + 00 + 00 -> 0 RPM
        let result = rpmCmd.properties.decode(data: Data([0x0C, 0x00, 0x00]))
        switch result {
        case .success(let decoded):
            XCTAssertNotNil(decoded.measurementResult)
            XCTAssertEqual(decoded.measurementResult!.value, 0, accuracy: 0.01)
        case .failure(let error):
            XCTFail("RPM decode failed: \(error)")
        }
    }

    func testDecodeRPMMax() {
        let rpmCmd = OBDCommand.mode1(.rpm)
        // Data: PID echo (0C) + FF + FF
        // bytesToInt = 65535, * 0.25 = 16383.75
        let result = rpmCmd.properties.decode(data: Data([0x0C, 0xFF, 0xFF]))
        switch result {
        case .success(let decoded):
            XCTAssertNotNil(decoded.measurementResult)
            XCTAssertEqual(decoded.measurementResult!.value, 16383.75, accuracy: 0.01)
        case .failure(let error):
            XCTFail("RPM max decode failed: \(error)")
        }
    }

    func testDecodeSpeed() {
        let speedCmd = OBDCommand.mode1(.speed)
        // Speed uses UAS 0x09: scale=1, unit=km/h
        // Data: PID echo (0D) + value (64 = 100)
        // After dropFirst: [0x64]
        // bytesToInt = 100, * 1 = 100 km/h
        let result = speedCmd.properties.decode(data: Data([0x0D, 0x64]))
        switch result {
        case .success(let decoded):
            XCTAssertNotNil(decoded.measurementResult)
            XCTAssertEqual(decoded.measurementResult!.value, 100, accuracy: 0.01)
            XCTAssertEqual(decoded.measurementResult!.unit, UnitSpeed.kilometersPerHour)
        case .failure(let error):
            XCTFail("Speed decode failed: \(error)")
        }
    }

    func testDecodeSpeedZero() {
        let speedCmd = OBDCommand.mode1(.speed)
        let result = speedCmd.properties.decode(data: Data([0x0D, 0x00]))
        switch result {
        case .success(let decoded):
            XCTAssertNotNil(decoded.measurementResult)
            XCTAssertEqual(decoded.measurementResult!.value, 0, accuracy: 0.01)
        case .failure(let error):
            XCTFail("Speed decode failed: \(error)")
        }
    }

    func testDecodeSpeedImperial() {
        let speedCmd = OBDCommand.mode1(.speed)
        // 100 km/h * 0.621371 = 62.1371 mph
        let result = speedCmd.properties.decode(data: Data([0x0D, 0x64]), unit: .imperial)
        switch result {
        case .success(let decoded):
            XCTAssertNotNil(decoded.measurementResult)
            XCTAssertEqual(decoded.measurementResult!.value, 62.1371, accuracy: 0.01)
            XCTAssertEqual(decoded.measurementResult!.unit, UnitSpeed.milesPerHour)
        case .failure(let error):
            XCTFail("Speed imperial decode failed: \(error)")
        }
    }

    func testDecodeCoolantTemp() {
        let tempCmd = OBDCommand.mode1(.coolantTemp)
        // Temp decoder: bytesToInt(data) - 40
        // Data: PID echo (05) + value (6E = 110)
        // After dropFirst: [0x6E]
        // 110 - 40 = 70 degrees C
        let result = tempCmd.properties.decode(data: Data([0x05, 0x6E]))
        switch result {
        case .success(let decoded):
            XCTAssertNotNil(decoded.measurementResult)
            XCTAssertEqual(decoded.measurementResult!.value, 70, accuracy: 0.01)
            XCTAssertEqual(decoded.measurementResult!.unit, UnitTemperature.celsius)
        case .failure(let error):
            XCTFail("Coolant temp decode failed: \(error)")
        }
    }

    func testDecodeCoolantTempMinimum() {
        let tempCmd = OBDCommand.mode1(.coolantTemp)
        // Data: PID echo (05) + 00 -> 0 - 40 = -40
        let result = tempCmd.properties.decode(data: Data([0x05, 0x00]))
        switch result {
        case .success(let decoded):
            XCTAssertNotNil(decoded.measurementResult)
            XCTAssertEqual(decoded.measurementResult!.value, -40, accuracy: 0.01)
        case .failure(let error):
            XCTFail("Coolant temp min decode failed: \(error)")
        }
    }

    func testDecodeCoolantTempMaximum() {
        let tempCmd = OBDCommand.mode1(.coolantTemp)
        // Data: PID echo (05) + FF = 255 -> 255 - 40 = 215
        let result = tempCmd.properties.decode(data: Data([0x05, 0xFF]))
        switch result {
        case .success(let decoded):
            XCTAssertNotNil(decoded.measurementResult)
            XCTAssertEqual(decoded.measurementResult!.value, 215, accuracy: 0.01)
        case .failure(let error):
            XCTFail("Coolant temp max decode failed: \(error)")
        }
    }

    func testDecodeEngineLoad() {
        let loadCmd = OBDCommand.mode1(.engineLoad)
        // Percent decoder: value * 100.0 / 255.0
        // Data: PID echo (04) + value (80 = 128)
        // After dropFirst: [0x80]
        // 128 * 100 / 255 = 50.196...
        let result = loadCmd.properties.decode(data: Data([0x04, 0x80]))
        switch result {
        case .success(let decoded):
            XCTAssertNotNil(decoded.measurementResult)
            XCTAssertEqual(decoded.measurementResult!.value, 50.196, accuracy: 0.01)
            XCTAssertEqual(decoded.measurementResult!.unit, Unit.percent)
        case .failure(let error):
            XCTFail("Engine load decode failed: \(error)")
        }
    }

    func testDecodeIntakeTemp() {
        let intakeTempCmd = OBDCommand.mode1(.intakeTemp)
        // Temp decoder: bytesToInt(data) - 40
        // Data: PID echo (0F) + value (46 = 70)
        // 70 - 40 = 30 degrees C
        let result = intakeTempCmd.properties.decode(data: Data([0x0F, 0x46]))
        switch result {
        case .success(let decoded):
            XCTAssertNotNil(decoded.measurementResult)
            XCTAssertEqual(decoded.measurementResult!.value, 30, accuracy: 0.01)
            XCTAssertEqual(decoded.measurementResult!.unit, UnitTemperature.celsius)
        case .failure(let error):
            XCTFail("Intake temp decode failed: \(error)")
        }
    }

    // MARK: - PROTOCOL Enum Tests

    func testProtocolIdBits() {
        XCTAssertEqual(PROTOCOL.protocol6.idBits, 11)
        XCTAssertEqual(PROTOCOL.protocol7.idBits, 29)
        XCTAssertEqual(PROTOCOL.protocol8.idBits, 11)
        XCTAssertEqual(PROTOCOL.protocol9.idBits, 29)
        XCTAssertEqual(PROTOCOL.protocolB.idBits, 11)
        XCTAssertEqual(PROTOCOL.protocolA.idBits, 29)
    }

    func testProtocolNextProtocol() {
        XCTAssertEqual(PROTOCOL.protocol6.nextProtocol(), .protocol5)
        XCTAssertEqual(PROTOCOL.protocol1.nextProtocol(), .NONE)
        XCTAssertEqual(PROTOCOL.protocol9.nextProtocol(), .protocol8)
        XCTAssertEqual(PROTOCOL.protocolC.nextProtocol(), .protocolB)
        XCTAssertEqual(PROTOCOL.protocolB.nextProtocol(), .protocolA)
    }

    func testProtocolCmd() {
        XCTAssertEqual(PROTOCOL.protocol6.cmd, "ATSP6")
        XCTAssertEqual(PROTOCOL.protocol9.cmd, "ATSP9")
        XCTAssertEqual(PROTOCOL.protocol1.cmd, "ATSP1")
        XCTAssertEqual(PROTOCOL.protocolA.cmd, "ATSPA")
    }

    func testProtocolDescription() {
        XCTAssertTrue(PROTOCOL.protocol6.description.contains("CAN"))
        XCTAssertTrue(PROTOCOL.protocol6.description.contains("11 bit"))
        XCTAssertTrue(PROTOCOL.protocol6.description.contains("500"))
        XCTAssertEqual(PROTOCOL.NONE.description, "None")
    }

    func testProtocolRawValues() {
        XCTAssertEqual(PROTOCOL.protocol6.rawValue, "6")
        XCTAssertEqual(PROTOCOL.protocol9.rawValue, "9")
        XCTAssertEqual(PROTOCOL.protocolA.rawValue, "A")
    }

    func testProtocolNoneNextProtocol() {
        // NONE is not in the protocolMap, so it should return .NONE
        XCTAssertEqual(PROTOCOL.NONE.nextProtocol(), .NONE)
    }

    // MARK: - OBDCommand.allCommands Tests

    func testAllCommandsNotEmpty() {
        XCTAssertFalse(OBDCommand.allCommands.isEmpty)
    }

    func testAllCommandsContainsKnownCommands() {
        let allCommands = OBDCommand.allCommands
        XCTAssertTrue(allCommands.contains(.mode1(.rpm)))
        XCTAssertTrue(allCommands.contains(.mode1(.speed)))
        XCTAssertTrue(allCommands.contains(.mode1(.coolantTemp)))
        XCTAssertTrue(allCommands.contains(.mode1(.pidsA)))
        XCTAssertTrue(allCommands.contains(.mode9(.VIN)))
        XCTAssertTrue(allCommands.contains(.mode3(.GET_DTC)))
    }

    // MARK: - OBDCommand.pidGetters Tests

    func testPidGettersNotEmpty() {
        XCTAssertFalse(OBDCommand.pidGetters.isEmpty)
    }

    func testPidGettersContainsPidsA() {
        XCTAssertTrue(OBDCommand.pidGetters.contains(.mode1(.pidsA)))
    }

    func testPidGettersContainsPidsB() {
        XCTAssertTrue(OBDCommand.pidGetters.contains(.mode1(.pidsB)))
    }

    func testPidGettersContainsPidsC() {
        XCTAssertTrue(OBDCommand.pidGetters.contains(.mode1(.pidsC)))
    }

    func testPidGettersDoNotContainLiveCommands() {
        // Live data PIDs like RPM, speed should not be in pidGetters
        XCTAssertFalse(OBDCommand.pidGetters.contains(.mode1(.rpm)))
        XCTAssertFalse(OBDCommand.pidGetters.contains(.mode1(.speed)))
        XCTAssertFalse(OBDCommand.pidGetters.contains(.mode1(.coolantTemp)))
    }

    // MARK: - OBDInfo Tests

    func testOBDInfoCodable() throws {
        let info = OBDInfo(
            vin: "1N4AL3AP7DC199583",
            supportedPIDs: [.mode1(.rpm), .mode1(.speed)],
            obdProtocol: .protocol6,
            ecuMap: [0x00: .engine]
        )
        let encoded = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(OBDInfo.self, from: encoded)
        XCTAssertEqual(decoded.vin, info.vin)
        XCTAssertEqual(decoded.obdProtocol, info.obdProtocol)
        XCTAssertEqual(decoded.supportedPIDs, info.supportedPIDs)
        XCTAssertEqual(decoded.ecuMap, info.ecuMap)
    }

    // MARK: - MOCKComm Connection State Tests

    func testMOCKCommInitialState() {
        let mock = MOCKComm()
        XCTAssertEqual(mock.connectionState, .disconnected)
    }

    func testMOCKCommConnectAsync() async throws {
        let mock = MOCKComm()
        try await mock.connectAsync(timeout: 5)
        XCTAssertEqual(mock.connectionState, .connectedToAdapter)
    }

    func testMOCKCommDisconnect() async throws {
        let mock = MOCKComm()
        try await mock.connectAsync(timeout: 5)
        mock.disconnectPeripheral()
        XCTAssertEqual(mock.connectionState, .disconnected)
    }

    // MARK: - MOCKComm Echo Behavior Tests

    func testMOCKCommEchoOff() async throws {
        let mock = MOCKComm()
        _ = try await mock.sendCommand("ATE0")
        let response = try await mock.sendCommand("ATZ")
        // With echo off, the command itself should not be in the response
        XCTAssertFalse(response.contains("ATZ"))
        XCTAssertTrue(response.contains("ELM327 v1.5"))
    }

    func testMOCKCommEchoOn() async throws {
        let mock = MOCKComm()
        _ = try await mock.sendCommand("ATE1")
        let response = try await mock.sendCommand("ATZ")
        // With echo on, the command should appear in the response
        XCTAssertTrue(response.contains("ATZ"))
    }

    // MARK: - MOCKComm Header Behavior Tests

    func testMOCKCommHeaderOn() async throws {
        let mock = MOCKComm()
        _ = try await mock.sendCommand("ATH1")
        let response = try await mock.sendCommand("0100")
        let joined = response.joined(separator: " ")
        // With headers on, response should contain "7E8"
        XCTAssertTrue(joined.contains("7E8"), "Response with headers on should contain ECU header 7E8")
    }

    func testMOCKCommHeaderOff() async throws {
        let mock = MOCKComm()
        _ = try await mock.sendCommand("ATH0")
        let response = try await mock.sendCommand("0100")
        let joined = response.joined(separator: " ")
        // With headers off, response should not contain "7E8"
        XCTAssertFalse(joined.contains("7E8"), "Response with headers off should not contain ECU header 7E8")
    }

    // MARK: - MOCKComm Mode 03 DTC Tests

    func testMOCKCommMode03Response() async throws {
        let mock = MOCKComm()
        let response = try await mock.sendCommand("03")
        let joined = response.joined(separator: " ")
        // Should contain mode response 43
        XCTAssertTrue(joined.contains("43"), "Mode 03 response should contain response mode 43")
    }

    // MARK: - MOCKComm AT Voltage Tests

    func testMOCKCommATRVReturnsVoltage() async throws {
        let mock = MOCKComm()
        let response = try await mock.sendCommand("ATRV")
        XCTAssertFalse(response.isEmpty)
        // ATRV returns a random voltage between 12.0 and 14.0
        if let voltageStr = response.first, let voltage = Double(voltageStr) {
            XCTAssertGreaterThanOrEqual(voltage, 12.0)
            XCTAssertLessThanOrEqual(voltage, 14.0)
        }
    }
}
