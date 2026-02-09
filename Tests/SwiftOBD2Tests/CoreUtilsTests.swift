//
//  CoreUtilsTests.swift
//
//  Tests for critical utility functions and UAS decoder in SwiftOBD2.
//

@testable import SwiftOBD2
import XCTest

final class CoreUtilsTests: XCTestCase {

    // MARK: - bytesToInt

    func testBytesToInt_singleByteZero() {
        XCTAssertEqual(bytesToInt(Data([0x00])), 0)
    }

    func testBytesToInt_singleByteMax() {
        XCTAssertEqual(bytesToInt(Data([0xFF])), 255)
    }

    func testBytesToInt_singleByteMidpoint() {
        XCTAssertEqual(bytesToInt(Data([0x80])), 128)
    }

    func testBytesToInt_twoBytesBigEndian256() {
        XCTAssertEqual(bytesToInt(Data([0x01, 0x00])), 256)
    }

    func testBytesToInt_twoBytes4000() {
        XCTAssertEqual(bytesToInt(Data([0x0F, 0xA0])), 4000)
    }

    func testBytesToInt_twoBytesMax() {
        XCTAssertEqual(bytesToInt(Data([0xFF, 0xFF])), 65535)
    }

    func testBytesToInt_threeBytes() {
        XCTAssertEqual(bytesToInt(Data([0x01, 0x00, 0x00])), 65536)
    }

    func testBytesToInt_emptyData() {
        XCTAssertEqual(bytesToInt(Data()), 0)
    }

    // MARK: - twosComp

    func testTwosComp_8bitPositiveMax() {
        // 0x7F = 127, stays positive in 8-bit two's complement
        XCTAssertEqual(twosComp(127, length: 8), 127)
    }

    func testTwosComp_8bitNegative128() {
        // 0x80 = 128 unsigned, -128 in 8-bit two's complement
        XCTAssertEqual(twosComp(128, length: 8), -128)
    }

    func testTwosComp_8bitNegativeOne() {
        // 0xFF = 255 unsigned, -1 in 8-bit two's complement
        XCTAssertEqual(twosComp(255, length: 8), -1)
    }

    func testTwosComp_8bitZero() {
        XCTAssertEqual(twosComp(0, length: 8), 0)
    }

    func testTwosComp_16bitPositiveMax() {
        // 0x7FFF = 32767, stays positive in 16-bit two's complement
        XCTAssertEqual(twosComp(32767, length: 16), 32767)
    }

    func testTwosComp_16bitNegativeMin() {
        // 0x8000 = 32768 unsigned, -32768 in 16-bit two's complement
        XCTAssertEqual(twosComp(32768, length: 16), -32768)
    }

    func testTwosComp_16bitNegativeOne() {
        // 0xFFFF = 65535 unsigned, -1 in 16-bit two's complement
        XCTAssertEqual(twosComp(65535, length: 16), -1)
    }

    func testTwosComp_16bitPositiveSmall() {
        // 1000 is well below 32768, stays positive
        XCTAssertEqual(twosComp(1000, length: 16), 1000)
    }

    // MARK: - BitArray

    func testBitArray_allOnes() {
        let bits = BitArray(data: Data([0xFF]))
        XCTAssertEqual(bits.binaryArray, [1, 1, 1, 1, 1, 1, 1, 1])
    }

    func testBitArray_allZeros() {
        let bits = BitArray(data: Data([0x00]))
        XCTAssertEqual(bits.binaryArray, [0, 0, 0, 0, 0, 0, 0, 0])
    }

    func testBitArray_0xA5() {
        // 0xA5 = 10100101 in binary
        let bits = BitArray(data: Data([0xA5]))
        XCTAssertEqual(bits.binaryArray, [1, 0, 1, 0, 0, 1, 0, 1])
    }

    func testBitArray_highBitOnly() {
        // 0x80 = 10000000
        let bits = BitArray(data: Data([0x80]))
        XCTAssertEqual(bits.binaryArray, [1, 0, 0, 0, 0, 0, 0, 0])
    }

    func testBitArray_twoBytes() {
        // 0xFF, 0x00 = 8 ones followed by 8 zeros
        let bits = BitArray(data: Data([0xFF, 0x00]))
        XCTAssertEqual(bits.binaryArray.count, 16)
        XCTAssertEqual(Array(bits.binaryArray[0..<8]), [1, 1, 1, 1, 1, 1, 1, 1])
        XCTAssertEqual(Array(bits.binaryArray[8..<16]), [0, 0, 0, 0, 0, 0, 0, 0])
    }

    func testBitArray_valueAtRange() {
        // 0xA5 = 10100101
        let bits = BitArray(data: Data([0xA5]))
        // bits 0..<4 = 1010 = 10
        XCTAssertEqual(bits.value(at: 0..<4), 10)
        // bits 4..<8 = 0101 = 5
        XCTAssertEqual(bits.value(at: 4..<8), 5)
    }

    func testBitArray_valueAtRange_fullByte() {
        let bits = BitArray(data: Data([0xFF]))
        XCTAssertEqual(bits.value(at: 0..<8), 255)
    }

    // MARK: - String.hexBytes

    func testHexBytes_singleByte() {
        XCTAssertEqual("FF".hexBytes, [0xFF])
    }

    func testHexBytes_twoBytes() {
        XCTAssertEqual("0100".hexBytes, [0x01, 0x00])
    }

    func testHexBytes_fourBytes() {
        XCTAssertEqual("7E806410".hexBytes, [0x7E, 0x80, 0x64, 0x10])
    }

    func testHexBytes_emptyString() {
        XCTAssertEqual("".hexBytes, [])
    }

    func testHexBytes_oddLengthDropsLastChar() {
        // Odd-length strings: count/2 rounds down, last nibble is ignored
        let result = "ABC".hexBytes
        XCTAssertEqual(result, [0xAB])
    }

    func testHexBytes_lowercase() {
        XCTAssertEqual("ff".hexBytes, [0xFF])
    }

    func testHexBytes_mixedCase() {
        XCTAssertEqual("aB01".hexBytes, [0xAB, 0x01])
    }

    // MARK: - String.isHex

    func testIsHex_validShort() {
        XCTAssertTrue("7E8".isHex)
    }

    func testIsHex_validLong() {
        XCTAssertTrue("FF00".isHex)
    }

    func testIsHex_validAllLetters() {
        XCTAssertTrue("ABCDEF".isHex)
    }

    func testIsHex_emptyString() {
        XCTAssertFalse("".isHex)
    }

    func testIsHex_containsSpace() {
        XCTAssertFalse("7E8 06".isHex)
    }

    func testIsHex_nonHexLetters() {
        XCTAssertFalse("GHIJ".isHex)
    }

    func testIsHex_noDataString() {
        XCTAssertFalse("NO DATA".isHex)
    }

    func testIsHex_lowercaseValid() {
        XCTAssertTrue("abcdef".isHex)
    }

    // MARK: - UAS decode (basic)

    func testUAS_unsignedScaleOne() {
        // Data([0x00, 0x64]) = 100, scale 1.0, no offset
        let uas = UAS(signed: false, scale: 1.0, unit: Unit.count)
        let result = uas.decode(bytes: Data([0x00, 0x64]))
        XCTAssertEqual(result.value, 100.0, accuracy: 0.001)
        XCTAssertEqual(result.unit, Unit.count)
    }

    func testUAS_unsignedWithScale() {
        // Data([0x03, 0xE8]) = 1000, scale 0.1 -> 100.0
        let uas = UAS(signed: false, scale: 0.1, unit: Unit.count)
        let result = uas.decode(bytes: Data([0x03, 0xE8]))
        XCTAssertEqual(result.value, 100.0, accuracy: 0.001)
        XCTAssertEqual(result.unit, Unit.count)
    }

    func testUAS_signedNegative() {
        // Data([0xFF]) = 255 unsigned, twosComp -> -1, scale 1.0
        let uas = UAS(signed: true, scale: 1.0, unit: Unit.count)
        let result = uas.decode(bytes: Data([0xFF]))
        XCTAssertEqual(result.value, -1.0, accuracy: 0.001)
        XCTAssertEqual(result.unit, Unit.count)
    }

    func testUAS_signedPositive() {
        // Data([0x7F]) = 127 unsigned, stays 127 in 8-bit two's complement
        let uas = UAS(signed: true, scale: 1.0, unit: Unit.count)
        let result = uas.decode(bytes: Data([0x7F]))
        XCTAssertEqual(result.value, 127.0, accuracy: 0.001)
    }

    func testUAS_unsignedWithOffset() {
        // UAS ID 0x16 pattern: scale 0.1, offset -40, celsius
        // Data([0x01, 0x90]) = 400 -> 400 * 0.1 + (-40) = 0.0
        let uas = UAS(signed: false, scale: 0.1, unit: UnitTemperature.celsius, offset: -40.0)
        let result = uas.decode(bytes: Data([0x01, 0x90]))
        XCTAssertEqual(result.value, 0.0, accuracy: 0.001)
        XCTAssertEqual(result.unit, UnitTemperature.celsius)
    }

    func testUAS_unsignedZeroBytes() {
        let uas = UAS(signed: false, scale: 1.0, unit: Unit.count)
        let result = uas.decode(bytes: Data([0x00, 0x00]))
        XCTAssertEqual(result.value, 0.0, accuracy: 0.001)
    }

    // MARK: - UAS imperial conversions

    func testUAS_celsiusToFahrenheit() {
        // 100 C -> (100 * 1.8) + 32 = 212 F
        let uas = UAS(signed: false, scale: 1.0, unit: UnitTemperature.celsius)
        let result = uas.decode(bytes: Data([0x00, 0x64]), .imperial)
        XCTAssertEqual(result.value, 212.0, accuracy: 0.01)
        XCTAssertEqual(result.unit, UnitTemperature.fahrenheit)
    }

    func testUAS_kphToMph() {
        // 100 km/h -> 62.1371 mph
        let uas = UAS(signed: false, scale: 1.0, unit: UnitSpeed.kilometersPerHour)
        let result = uas.decode(bytes: Data([0x00, 0x64]), .imperial)
        XCTAssertEqual(result.value, 62.1371, accuracy: 0.01)
        XCTAssertEqual(result.unit, UnitSpeed.milesPerHour)
    }

    func testUAS_kpaToPS() {
        // 100 kPa -> 14.5038 PSI
        let uas = UAS(signed: false, scale: 1.0, unit: UnitPressure.kilopascals)
        let result = uas.decode(bytes: Data([0x00, 0x64]), .imperial)
        XCTAssertEqual(result.value, 14.5038, accuracy: 0.01)
        XCTAssertEqual(result.unit, UnitPressure.poundsForcePerSquareInch)
    }

    func testUAS_kmToMiles() {
        // 100 km -> 62.1371 miles
        let uas = UAS(signed: false, scale: 1.0, unit: UnitLength.kilometers)
        let result = uas.decode(bytes: Data([0x00, 0x64]), .imperial)
        XCTAssertEqual(result.value, 62.1371, accuracy: 0.01)
        XCTAssertEqual(result.unit, UnitLength.miles)
    }

    func testUAS_barToPSI() {
        // 1 bar -> 14.5038 PSI
        let uas = UAS(signed: false, scale: 1.0, unit: Unit.bar)
        let result = uas.decode(bytes: Data([0x00, 0x01]), .imperial)
        XCTAssertEqual(result.value, 14.5038, accuracy: 0.01)
        XCTAssertEqual(result.unit, UnitPressure.poundsForcePerSquareInch)
    }

    func testUAS_gramsPerSecondConversion() {
        // 10 g/s -> 10 * 0.00220462
        let uas = UAS(signed: false, scale: 1.0, unit: Unit.gramsPerSecond)
        let result = uas.decode(bytes: Data([0x00, 0x0A]), .imperial)
        XCTAssertEqual(result.value, 10.0 * 0.00220462, accuracy: 0.0001)
        // g/s unit stays the same (no named imperial equivalent)
        XCTAssertEqual(result.unit, Unit.gramsPerSecond)
    }

    func testUAS_nonConvertibleUnit_rpm() {
        // RPM has no imperial conversion, stays the same
        let uas = UAS(signed: false, scale: 1.0, unit: Unit.rpm)
        let result = uas.decode(bytes: Data([0x0B, 0xB8]), .imperial) // 3000
        XCTAssertEqual(result.value, 3000.0, accuracy: 0.01)
        XCTAssertEqual(result.unit, Unit.rpm)
    }

    // MARK: - UAS unit immutability (regression test)

    func testUAS_unitImmutabilityAcrossDecodes() {
        // Calling decode with .imperial should NOT mutate the UAS unit.
        // A subsequent .metric call must still return the original metric unit.
        let uas = UAS(signed: false, scale: 1.0, unit: UnitTemperature.celsius)

        // First call: imperial
        let imperialResult = uas.decode(bytes: Data([0x00, 0x64]), .imperial)
        XCTAssertEqual(imperialResult.value, 212.0, accuracy: 0.01)
        XCTAssertEqual(imperialResult.unit, UnitTemperature.fahrenheit)

        // Second call: metric -- must still give celsius, not fahrenheit
        let metricResult = uas.decode(bytes: Data([0x00, 0x64]), .metric)
        XCTAssertEqual(metricResult.value, 100.0, accuracy: 0.01)
        XCTAssertEqual(metricResult.unit, UnitTemperature.celsius)

        // Third call: imperial again to be thorough
        let imperialAgain = uas.decode(bytes: Data([0x00, 0x64]), .imperial)
        XCTAssertEqual(imperialAgain.value, 212.0, accuracy: 0.01)
        XCTAssertEqual(imperialAgain.unit, UnitTemperature.fahrenheit)
    }

    func testUAS_unitImmutability_kpa() {
        let uas = UAS(signed: false, scale: 1.0, unit: UnitPressure.kilopascals)

        // Imperial first
        let psi = uas.decode(bytes: Data([0x00, 0x64]), .imperial)
        XCTAssertEqual(psi.unit, UnitPressure.poundsForcePerSquareInch)

        // Metric after imperial must still be kPa
        let kpa = uas.decode(bytes: Data([0x00, 0x64]), .metric)
        XCTAssertEqual(kpa.value, 100.0, accuracy: 0.01)
        XCTAssertEqual(kpa.unit, UnitPressure.kilopascals)
    }

    func testUAS_unitImmutability_speed() {
        let uas = UAS(signed: false, scale: 1.0, unit: UnitSpeed.kilometersPerHour)

        let mph = uas.decode(bytes: Data([0x00, 0x64]), .imperial)
        XCTAssertEqual(mph.unit, UnitSpeed.milesPerHour)

        let kph = uas.decode(bytes: Data([0x00, 0x64]), .metric)
        XCTAssertEqual(kph.value, 100.0, accuracy: 0.01)
        XCTAssertEqual(kph.unit, UnitSpeed.kilometersPerHour)
    }
}
