//
//  ParserTests.swift
//  SwiftOBD2Tests
//
//  Comprehensive tests for the CAN frame parser (parser.swift).
//  Covers Frame, Message, and CANParser types across 11-bit and 29-bit CAN.
//

@testable import SwiftOBD2
import XCTest

final class ParserTests: XCTestCase {

    // MARK: - Frame Type Detection

    func testSingleFrameType11Bit() throws {
        // "7E8 06 41 00 BE 3F A8 13" with spaces stripped
        // After "00000" padding → 11 hex byte pairs → data starts at byte 4
        // data[0] = 0x06, type = 0x06 & 0xF0 = 0x00 → .singleFrame
        let raw = stripSpaces("7E8 06 41 00 BE 3F A8 13")
        let frame = try Frame(raw: raw, idBits: 11)
        XCTAssertEqual(frame.type, .singleFrame)
    }

    func testFirstFrameType11Bit() throws {
        // First frame of a multi-frame response (VIN)
        // PCI byte 0x10 → type = 0x10 & 0xF0 = 0x10 → .firstFrame
        let raw = stripSpaces("7E8 10 14 49 02 01 31 4E 34")
        let frame = try Frame(raw: raw, idBits: 11)
        XCTAssertEqual(frame.type, .firstFrame)
    }

    func testConsecutiveFrameType11Bit() throws {
        // Consecutive frame (sequence index 1)
        // PCI byte 0x21 → type = 0x21 & 0xF0 = 0x20 → .consecutiveFrame
        let raw = stripSpaces("7E8 21 41 4C 33 41 50 37 44")
        let frame = try Frame(raw: raw, idBits: 11)
        XCTAssertEqual(frame.type, .consecutiveFrame)
        XCTAssertEqual(frame.seqIndex, 1)
    }

    func testConsecutiveFrameSequenceIndex() throws {
        // Sequence index 2
        let raw = stripSpaces("7E8 22 43 31 39 39 35 38 33")
        let frame = try Frame(raw: raw, idBits: 11)
        XCTAssertEqual(frame.type, .consecutiveFrame)
        XCTAssertEqual(frame.seqIndex, 2)
    }

    // MARK: - Frame Data Length

    func testSingleFrameDataLength() throws {
        // PCI byte 0x06 → dataLen = 0x06 & 0x0F = 6
        let raw = stripSpaces("7E8 06 41 00 BE 3F A8 13")
        let frame = try Frame(raw: raw, idBits: 11)
        XCTAssertEqual(frame.dataLen, 6)
    }

    func testSingleFrameDataLengthShort() throws {
        // PCI byte 0x04 → dataLen = 4 (RPM response, only 4 data bytes)
        let raw = stripSpaces("7E8 04 41 0C 0F A0 00 00")
        let frame = try Frame(raw: raw, idBits: 11)
        XCTAssertEqual(frame.dataLen, 4)
    }

    func testFirstFrameDataLength() throws {
        // First frame: dataLen = (data[0] & 0x0F) << 8 + data[1]
        // PCI bytes: 0x10, 0x14 → dataLen = (0x00 << 8) + 0x14 = 20
        let raw = stripSpaces("7E8 10 14 49 02 01 31 4E 34")
        let frame = try Frame(raw: raw, idBits: 11)
        XCTAssertEqual(frame.dataLen, 20)
    }

    func testFirstFrameDataLengthLarger() throws {
        // PCI bytes: 0x10, 0x3E → dataLen = (0x00 << 8) + 0x3E = 62
        let raw = stripSpaces("7E8 10 3E 00 00 00 00 00 00")
        let frame = try Frame(raw: raw, idBits: 11)
        XCTAssertEqual(frame.dataLen, 62)
    }

    // MARK: - Frame ECU Identification

    func testEngineECU() throws {
        // 7E8: after padding, dataBytes[3] = 0xE8, txID = 0xE8 & 0x07 = 0x00 → .engine
        let raw = stripSpaces("7E8 06 41 00 BE 3F A8 13")
        let frame = try Frame(raw: raw, idBits: 11)
        XCTAssertEqual(frame.txID, .engine)
    }

    func testTransmissionECU() throws {
        // 7E9: after padding, dataBytes[3] = 0xE9, txID = 0xE9 & 0x07 = 0x01 → .transmission
        let raw = stripSpaces("7E9 06 41 00 80 18 80 10")
        let frame = try Frame(raw: raw, idBits: 11)
        XCTAssertEqual(frame.txID, .transmission)
    }

    func testUnknownECU() throws {
        // 7EA: after padding, dataBytes[3] = 0xEA, txID = 0xEA & 0x07 = 0x02 → .unknown
        let raw = stripSpaces("7EA 06 41 00 00 00 00 00")
        let frame = try Frame(raw: raw, idBits: 11)
        XCTAssertEqual(frame.txID, .unknown)
    }

    // MARK: - Frame Header Fields

    func testFramePriorityAndAddrMode() throws {
        // After padding "00000" + "7E80641...":
        // dataBytes[2] = 0x07, priority = 0x07 & 0x0F = 0x07
        // dataBytes[3] = 0xE8, addrMode = 0xE8 & 0xF0 = 0xE0
        // rxID = dataBytes[2] = 0x07
        let raw = stripSpaces("7E8 06 41 00 BE 3F A8 13")
        let frame = try Frame(raw: raw, idBits: 11)
        XCTAssertEqual(frame.priority, 0x07)
        XCTAssertEqual(frame.addrMode, 0xE0)
        XCTAssertEqual(frame.rxID, 0x07)
    }

    // MARK: - Frame Validation Errors

    func testFrameTooShort() {
        // "7E8 01" → 5 hex chars after strip → padded = 10 chars → 5 bytes → < 6 minimum
        let raw = stripSpaces("7E8 01")
        XCTAssertThrowsError(try Frame(raw: raw, idBits: 11)) { error in
            if case ParserError.error(let msg) = error {
                XCTAssertEqual(msg, "Invalid frame size")
            } else {
                XCTFail("Expected ParserError.error, got \(error)")
            }
        }
    }

    func testFrameTooLong() {
        // 29-bit raw: no padding applied, hexBytes parses pairs directly.
        // 28 hex chars = 14 pairs = 14 bytes → exceeds 12-byte maximum.
        let raw = "18DAF1100641000BE3FA81300FF"
        XCTAssertThrowsError(try Frame(raw: raw, idBits: 29)) { error in
            if case ParserError.error(let msg) = error {
                XCTAssertEqual(msg, "Invalid frame size")
            } else {
                XCTFail("Expected ParserError.error, got \(error)")
            }
        }
    }

    func testFrameInvalidType() {
        // Construct a raw string where data[0] & 0xF0 yields an invalid FrameType
        // Valid types: 0x00, 0x10, 0x20. Let's make data[0] = 0x30
        // For 11-bit: "7E8" + "30" + padding → "7E830..." = need enough bytes
        let raw = stripSpaces("7E8 30 00 00 00 00 00 00")
        XCTAssertThrowsError(try Frame(raw: raw, idBits: 11)) { error in
            if case ParserError.error(let msg) = error {
                XCTAssertEqual(msg, "Invalid frame type")
            } else {
                XCTFail("Expected ParserError.error, got \(error)")
            }
        }
    }

    // MARK: - Frame Raw String Preservation

    func testFramePreservesRawString() throws {
        let raw = stripSpaces("7E8 06 41 00 BE 3F A8 13")
        let frame = try Frame(raw: raw, idBits: 11)
        XCTAssertEqual(frame.raw, raw)
    }

    // MARK: - CANParser: Single Frame, Single ECU

    func testCANParserSingleFrame11Bit() throws {
        let parser = try CANParser(["7E8 06 41 00 BE 3F A8 13"], idBits: 11)
        XCTAssertEqual(parser.frames.count, 1)
        XCTAssertEqual(parser.messages.count, 1)
        XCTAssertEqual(parser.frames[0].type, .singleFrame)
        XCTAssertEqual(parser.frames[0].dataLen, 6)
    }

    func testCANParserSingleFrameMessageData() throws {
        // Mode 01 PID 00: response bytes are 41 00 BE 3F A8 13
        // Message data = frame.data.dropFirst(2) → drops PCI (06) and mode (41)
        // Remaining: [0x00, 0xBE, 0x3F, 0xA8, 0x13]
        let parser = try CANParser(["7E8 06 41 00 BE 3F A8 13"], idBits: 11)
        let data = try XCTUnwrap(parser.messages[0].data)
        XCTAssertEqual(data.count, 5)
        XCTAssertEqual(Array(data), [0x00, 0xBE, 0x3F, 0xA8, 0x13])
    }

    func testCANParserSingleFrameECU() throws {
        let parser = try CANParser(["7E8 06 41 00 BE 3F A8 13"], idBits: 11)
        XCTAssertEqual(parser.messages[0].ecu, .engine)
    }

    // MARK: - CANParser: RPM Response

    func testCANParserRPMResponse() throws {
        // Mode 01 PID 0C (RPM): "7E8 04 41 0C 0F A0 00 00"
        // dataLen = 4, message data drops PCI (04) and mode (41)
        // Remaining: [0x0C, 0x0F, 0xA0, 0x00, 0x00]
        let parser = try CANParser(["7E8 04 41 0C 0F A0 00 00"], idBits: 11)
        let data = try XCTUnwrap(parser.messages[0].data)
        XCTAssertEqual(data[data.startIndex], 0x0C)     // PID echo byte
        XCTAssertEqual(data[data.startIndex + 1], 0x0F)  // Data byte A
        XCTAssertEqual(data[data.startIndex + 2], 0xA0)  // Data byte B
    }

    // MARK: - CANParser: Coolant Temperature Response

    func testCANParserCoolantTempResponse() throws {
        // Mode 01 PID 05 (coolant temp): "7E8 03 41 05 7B 00 00 00"
        // dataLen = 3, message data: [0x05, 0x7B, 0x00, 0x00, 0x00]
        let parser = try CANParser(["7E8 03 41 05 7B 00 00 00"], idBits: 11)
        let data = try XCTUnwrap(parser.messages[0].data)
        XCTAssertEqual(data[data.startIndex], 0x05) // PID echo
        XCTAssertEqual(data[data.startIndex + 1], 0x7B) // 123 decimal → 123-40 = 83C
    }

    // MARK: - CANParser: Multi-Frame (VIN)

    func testCANParserMultiFrameVIN() throws {
        // Typical VIN response: Mode 09 PID 02 (17-char VIN + overhead = 20 bytes)
        let lines = [
            "7E8 10 14 49 02 01 31 4E 34",  // First frame: dataLen=20
            "7E8 21 41 4C 33 41 50 37 44",  // Consecutive frame seq=1
            "7E8 22 43 31 39 39 35 38 33",  // Consecutive frame seq=2
        ]
        let parser = try CANParser(lines, idBits: 11)

        XCTAssertEqual(parser.frames.count, 3)
        XCTAssertEqual(parser.messages.count, 1)

        // Verify frame types
        XCTAssertEqual(parser.frames[0].type, .firstFrame)
        XCTAssertEqual(parser.frames[1].type, .consecutiveFrame)
        XCTAssertEqual(parser.frames[2].type, .consecutiveFrame)

        // Verify sequence indices
        XCTAssertEqual(parser.frames[1].seqIndex, 1)
        XCTAssertEqual(parser.frames[2].seqIndex, 2)

        // Verify assembled data is present
        let data = try XCTUnwrap(parser.messages[0].data)

        // Multi-frame extraction starts at byte 3 of assembled data:
        // Assembled data = first frame data + consecutive frame payloads
        // First frame data: [10, 14, 49, 02, 01, 31, 4E, 34]
        // + CF1 payload: [41, 4C, 33, 41, 50, 37, 44]
        // + CF2 payload: [43, 31, 39, 39, 35, 38, 33]
        // extractDataFromFrame(startIndex: 3) → data[3..<22]
        // = [02, 01, 31, 4E, 34, 41, 4C, 33, 41, 50, 37, 44, 43, 31, 39, 39, 35, 38, 33]
        // = 19 bytes

        XCTAssertEqual(data.count, 19)

        // Verify VIN ASCII content: starts at offset 2 in the extracted data
        // data[0]=0x02 (PID echo), data[1]=0x01 (count), data[2...]=VIN ASCII
        let vinBytes = Array(data.dropFirst(2))
        let vin = String(bytes: vinBytes, encoding: .ascii)
        XCTAssertEqual(vin, "1N4AL3AP7DC199583")
    }

    func testCANParserMultiFrameECU() throws {
        let lines = [
            "7E8 10 14 49 02 01 31 4E 34",
            "7E8 21 41 4C 33 41 50 37 44",
            "7E8 22 43 31 39 39 35 38 33",
        ]
        let parser = try CANParser(lines, idBits: 11)
        XCTAssertEqual(parser.messages[0].ecu, .engine)
    }

    // MARK: - CANParser: Multiple ECU Responses

    func testCANParserMultipleECUs() throws {
        // Engine (7E8) and Transmission (7E9) both respond to Mode 01 PID 00
        let lines = [
            "7E8 06 41 00 BE 3F A8 13",
            "7E9 06 41 00 80 18 80 10",
        ]
        let parser = try CANParser(lines, idBits: 11)
        XCTAssertEqual(parser.frames.count, 2)
        XCTAssertEqual(parser.messages.count, 2)

        // Both messages should have valid data
        let ecus = Set(parser.messages.map(\.ecu))
        XCTAssertTrue(ecus.contains(.engine))
        XCTAssertTrue(ecus.contains(.transmission))
    }

    func testCANParserMultipleECUDataIndependence() throws {
        let lines = [
            "7E8 06 41 00 BE 3F A8 13",
            "7E9 06 41 00 80 18 80 10",
        ]
        let parser = try CANParser(lines, idBits: 11)

        let engineMsg = parser.messages.first(where: { $0.ecu == .engine })
        let transMsg = parser.messages.first(where: { $0.ecu == .transmission })

        let engineData = try XCTUnwrap(engineMsg?.data)
        let transData = try XCTUnwrap(transMsg?.data)

        // Engine: [0x00, 0xBE, 0x3F, 0xA8, 0x13]
        XCTAssertEqual(Array(engineData), [0x00, 0xBE, 0x3F, 0xA8, 0x13])

        // Transmission: [0x00, 0x80, 0x18, 0x80, 0x10]
        XCTAssertEqual(Array(transData), [0x00, 0x80, 0x18, 0x80, 0x10])
    }

    // MARK: - CANParser: Filtering Non-Hex Lines

    func testCANParserFiltersNonHexLines() throws {
        let lines = [
            "7E8 06 41 00 BE 3F A8 13",
            "NO DATA",
            ">",
            "SEARCHING...",
        ]
        let parser = try CANParser(lines, idBits: 11)
        XCTAssertEqual(parser.frames.count, 1)
        XCTAssertEqual(parser.messages.count, 1)
    }

    func testCANParserFiltersPromptCharacter() throws {
        // The ">" prompt character is not hex
        let lines = [">", "7E8 06 41 00 BE 3F A8 13"]
        let parser = try CANParser(lines, idBits: 11)
        XCTAssertEqual(parser.frames.count, 1)
    }

    func testCANParserFiltersELMResponses() throws {
        // ELM327 may echo back AT commands or error messages
        let lines = [
            "ATZ",
            "ELM327 v1.5",
            "7E8 06 41 00 BE 3F A8 13",
            "OK",
        ]
        let parser = try CANParser(lines, idBits: 11)
        XCTAssertEqual(parser.frames.count, 1)
        XCTAssertEqual(parser.messages.count, 1)
    }

    // MARK: - CANParser: Empty and Edge Cases

    func testCANParserEmptyInput() throws {
        let parser = try CANParser([], idBits: 11)
        XCTAssertEqual(parser.frames.count, 0)
        XCTAssertEqual(parser.messages.count, 0)
    }

    func testCANParserAllNonHex() throws {
        let parser = try CANParser(["NO DATA", "SEARCHING..."], idBits: 11)
        XCTAssertEqual(parser.frames.count, 0)
        XCTAssertEqual(parser.messages.count, 0)
    }

    func testCANParserSpaceStripping() throws {
        // Extra spaces should not matter — the parser strips all spaces
        let parser = try CANParser(["7E8  06  41  00  BE  3F  A8  13"], idBits: 11)
        XCTAssertEqual(parser.frames.count, 1)
        XCTAssertEqual(parser.messages.count, 1)
    }

    // MARK: - CANParser: DTC Response

    func testCANParserDTCResponse() throws {
        // Mode 03 response (DTC scan): service byte = 0x43
        // "7E8 06 43 01 04 80 03 00" → 2 DTCs encoded
        let parser = try CANParser(["7E8 06 43 01 04 80 03 00"], idBits: 11)
        XCTAssertEqual(parser.messages.count, 1)
        let data = try XCTUnwrap(parser.messages[0].data)
        // After dropping PCI (06) and mode (43): [0x01, 0x04, 0x80, 0x03, 0x00]
        XCTAssertEqual(data.count, 5)
    }

    // MARK: - CANParser: Minimum Valid Single Frame

    func testCANParserMinimumValidFrame() throws {
        // "7E8 01 41" → 7 chars after strip → padded 12 chars → 6 bytes (minimum)
        // dataLen = 1, message data = data.dropFirst(2) → may be empty
        let parser = try CANParser(["7E8 01 41"], idBits: 11)
        XCTAssertEqual(parser.frames.count, 1)
        XCTAssertEqual(parser.frames[0].dataLen, 1)
    }

    // MARK: - CANParser: 8-Byte Data Field (Padded Frame)

    func testCANParserPaddedFrame() throws {
        // Some ELM327 adapters send 8 data bytes (padded with 00)
        // "7E8 06 41 00 BE 3F A8 13 00" → 19 chars → padded 24 chars → 12 bytes (maximum)
        let parser = try CANParser(["7E8 06 41 00 BE 3F A8 13 00"], idBits: 11)
        XCTAssertEqual(parser.frames.count, 1)
        let data = try XCTUnwrap(parser.messages[0].data)
        // Data extraction is the same regardless of padding
        XCTAssertEqual(Array(data), [0x00, 0xBE, 0x3F, 0xA8, 0x13, 0x00])
    }

    // MARK: - Message: Single Frame Validation

    func testMessageSingleFrameRequiresSingleFrame() throws {
        // A single frame with type != .singleFrame should fail
        let firstFrameRaw = stripSpaces("7E8 10 14 49 02 01 31 4E 34")
        let frame = try Frame(raw: firstFrameRaw, idBits: 11)
        XCTAssertEqual(frame.type, .firstFrame)

        // Passing a single firstFrame to Message should throw
        // because parseSingleFrameMessage checks frame.type == .singleFrame
        XCTAssertThrowsError(try Message(frames: [frame]))
    }

    func testMessageZeroFramesThrows() {
        XCTAssertThrowsError(try Message(frames: [])) { error in
            if case ParserError.error(let msg) = error {
                XCTAssertEqual(msg, "Invalid frame count")
            } else {
                XCTFail("Expected ParserError.error, got \(error)")
            }
        }
    }

    // MARK: - Message: Multi-Frame Requires First Frame

    func testMessageMultiFrameWithoutFirstFrameThrows() throws {
        // Two consecutive frames without a first frame
        let cf1Raw = stripSpaces("7E8 21 41 4C 33 41 50 37 44")
        let cf2Raw = stripSpaces("7E8 22 43 31 39 39 35 38 33")
        let cf1 = try Frame(raw: cf1Raw, idBits: 11)
        let cf2 = try Frame(raw: cf2Raw, idBits: 11)

        XCTAssertThrowsError(try Message(frames: [cf1, cf2])) { error in
            if case ParserError.error(let msg) = error {
                XCTAssertEqual(msg, "Failed to parse multi frame message")
            } else {
                XCTFail("Expected ParserError.error, got \(error)")
            }
        }
    }

    // MARK: - Protocol Parser Integration

    func testISO15765_11bit500k() throws {
        let proto = ISO_15765_4_11bit_500k()
        let messages = try proto.parse(["7E8 06 41 00 BE 3F A8 13"])
        XCTAssertEqual(messages.count, 1)
        let data = try XCTUnwrap(messages[0].data)
        XCTAssertEqual(Array(data), [0x00, 0xBE, 0x3F, 0xA8, 0x13])
    }

    func testISO15765_11bit250k() throws {
        let proto = ISO_15765_4_11bit_250K()
        let messages = try proto.parse(["7E8 06 41 00 BE 3F A8 13"])
        XCTAssertEqual(messages.count, 1)
        let data = try XCTUnwrap(messages[0].data)
        XCTAssertEqual(Array(data), [0x00, 0xBE, 0x3F, 0xA8, 0x13])
    }

    func testProtocolParserMultiFrame() throws {
        let proto = ISO_15765_4_11bit_500k()
        let messages = try proto.parse([
            "7E8 10 14 49 02 01 31 4E 34",
            "7E8 21 41 4C 33 41 50 37 44",
            "7E8 22 43 31 39 39 35 38 33",
        ])
        XCTAssertEqual(messages.count, 1)
        XCTAssertNotNil(messages[0].data)
    }

    // MARK: - Supported PIDs Bitmap

    func testSupportedPIDsBitmapResponse() throws {
        // PID 00 response: BE 3F A8 13
        // Binary: 10111110 00111111 10101000 00010011
        // This bitmap indicates which PIDs 01-20 are supported
        let parser = try CANParser(["7E8 06 41 00 BE 3F A8 13"], idBits: 11)
        let data = try XCTUnwrap(parser.messages[0].data)

        // data[0] = 0x00 (PID echo)
        // data[1..4] = supported PIDs bitmap
        XCTAssertEqual(data[data.startIndex], 0x00)
        XCTAssertEqual(data[data.startIndex + 1], 0xBE)
        XCTAssertEqual(data[data.startIndex + 2], 0x3F)
        XCTAssertEqual(data[data.startIndex + 3], 0xA8)
        XCTAssertEqual(data[data.startIndex + 4], 0x13)
    }

    // MARK: - Multiple Messages from Same ECU (Multi-Frame)

    func testMultiFrameGroupedByECU() throws {
        // When engine sends multi-frame and transmission sends single frame
        let lines = [
            "7E8 10 14 49 02 01 31 4E 34",  // Engine first frame
            "7E8 21 41 4C 33 41 50 37 44",  // Engine consecutive 1
            "7E8 22 43 31 39 39 35 38 33",  // Engine consecutive 2
            "7E9 06 41 00 80 18 80 10",      // Transmission single frame
        ]
        let parser = try CANParser(lines, idBits: 11)

        // Should produce 2 messages: one multi-frame (engine), one single-frame (transmission)
        XCTAssertEqual(parser.messages.count, 2)
        XCTAssertEqual(parser.frames.count, 4)

        let engineMsg = parser.messages.first(where: { $0.ecu == .engine })
        let transMsg = parser.messages.first(where: { $0.ecu == .transmission })

        XCTAssertNotNil(engineMsg)
        XCTAssertNotNil(transMsg)

        // Engine message should have assembled multi-frame data (VIN)
        let engineData = try XCTUnwrap(engineMsg?.data)
        XCTAssertEqual(engineData.count, 19)

        // Transmission message should have single-frame data
        let transData = try XCTUnwrap(transMsg?.data)
        XCTAssertEqual(Array(transData), [0x00, 0x80, 0x18, 0x80, 0x10])
    }

    // MARK: - All-Zeros Response

    func testCANParserAllZerosData() throws {
        // Some PIDs respond with all zeros
        let parser = try CANParser(["7E8 06 41 00 00 00 00 00"], idBits: 11)
        let data = try XCTUnwrap(parser.messages[0].data)
        XCTAssertEqual(Array(data), [0x00, 0x00, 0x00, 0x00, 0x00])
    }

    // MARK: - All-FF Response

    func testCANParserAllFFData() throws {
        // PID 00 with all supported: FF FF FF FF
        let parser = try CANParser(["7E8 06 41 00 FF FF FF FF"], idBits: 11)
        let data = try XCTUnwrap(parser.messages[0].data)
        XCTAssertEqual(Array(data), [0x00, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    // MARK: - Existing parcerTest Compatibility

    func testBackwardCompatibilityWithExistingTestData() throws {
        // Replicate the test data from the original parcerTest.swift
        // Single frame with 8 data bytes (padded)
        let parser1 = try CANParser(["7E8 06 41 00 BE 3F A8 13 00"], idBits: 11)
        XCTAssertNotNil(parser1.messages.first?.data)

        // All-FF single frame
        let parser2 = try CANParser(["7E8 06 41 00 FF 00 00 00 00"], idBits: 11)
        XCTAssertNotNil(parser2.messages.first?.data)

        // Multi-frame VIN response (with trailing spaces — parser handles them)
        let parser3 = try CANParser([
            "7E8 10 14 49 02 01 31 4E 34 ",
            "7E8 21 41 4C 33 41 50 37 44 ",
            "7E8 22 43 31 39 39 35 38 33 ",
        ], idBits: 11)
        XCTAssertNotNil(parser3.messages.first?.data)
    }

    // MARK: - Existing test_protocol_can Compatibility

    func testExistingProtocolCANData() throws {
        // Mirrors test_single_frame from test_protocol_can.swift
        for proto in [ISO_15765_4_11bit_500k(), ISO_15765_4_11bit_250K()] as [CANProtocol] {
            let data = try proto.parse(["7E8 06 41 00 00 01 02 03"]).first?.data
            XCTAssertNotNil(data)
            XCTAssertEqual(data, Data([0x00, 0x00, 0x01, 0x02, 0x03]))

            // Minimum valid length
            let data2 = try proto.parse(["7E8 01 41"]).first?.data
            XCTAssertNotNil(data2)

            // Too short → should fail (returns nil via try?)
            let data3 = try? proto.parse(["7E8 01"]).first?.data
            XCTAssertNil(data3)
        }
    }

    // MARK: - Helpers

    /// Strips spaces from a raw OBD-II response string, matching CANParser's internal behavior.
    private func stripSpaces(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "")
    }
}
