import XCTest
@testable import PicshopCore

/// D16a PackBits: random rows round-trip, the all-equal and all-distinct rows, the 128-byte limits of runs and
/// literals, the encoder never writes the −128 header, and a short or overlong stream is refused.
final class PackBitsTests: XCTestCase {
    /// The header bytes of an encoded stream, walked as a decoder does.
    private func headers(_ encoded: [UInt8]) -> [Int8] {
        var result: [Int8] = []
        var index = 0
        while index < encoded.count {
            let header = Int8(bitPattern: encoded[index])
            result.append(header)
            index += header >= 0 ? Int(header) + 2 : 2
        }
        return result
    }

    func testTenThousandRandomRowsRoundTrip() throws {
        var random = MaskTestRandom(seed: 16)
        for _ in 0..<10_000 {
            let count = Int(random.next() % 700)
            var row: [UInt8] = []
            row.reserveCapacity(count)
            while row.count < count {
                // Runs and noise mixed, as photographs and masks give.
                let value = UInt8(truncatingIfNeeded: random.next())
                let length = random.next() % 3 == 0 ? Int(random.next() % 300) + 1 : 1
                row += [UInt8](repeating: value, count: min(length, count - row.count))
            }
            let encoded = PackBits.encode(row)
            XCTAssertEqual(try PackBits.decode(encoded, expectedCount: row.count), row)
            XCTAssertFalse(headers(encoded).contains(-128))
            XCTAssertLessThanOrEqual(encoded.count, row.count + (row.count + 127) / 128)
        }
    }

    func testAllEqualAndAllDistinctRows() throws {
        let equal = [UInt8](repeating: 7, count: 1000)
        let packed = PackBits.encode(equal)
        // Seven runs of 128 and one of 104, two bytes each.
        XCTAssertEqual(packed.count, 16)
        XCTAssertEqual(headers(packed), [Int8](repeating: -127, count: 7) + [-103])
        XCTAssertEqual(try PackBits.decode(packed, expectedCount: 1000), equal)

        let distinct = (0..<1000).map { UInt8($0 % 251) }
        let literal = PackBits.encode(distinct)
        // Literal blocks of 128: n + ⌈n / 128⌉ bytes.
        XCTAssertEqual(literal.count, 1000 + 8)
        XCTAssertEqual(headers(literal), [Int8](repeating: 127, count: 7) + [103])
        XCTAssertEqual(try PackBits.decode(literal, expectedCount: 1000), distinct)
        XCTAssertEqual(PackBits.encode([]), [])
        XCTAssertEqual(try PackBits.decode([], expectedCount: 0), [])
    }

    func testThe128ByteLimits() throws {
        XCTAssertEqual(PackBits.encode([9]), [0, 9])
        XCTAssertEqual(PackBits.encode([9, 9]), [0xFF, 9])
        XCTAssertEqual(PackBits.encode([UInt8](repeating: 9, count: 128)), [0x81, 9])
        XCTAssertEqual(PackBits.encode([UInt8](repeating: 9, count: 129)), [0x81, 9, 0, 9])
        XCTAssertEqual(PackBits.encode([UInt8](repeating: 9, count: 130)), [0x81, 9, 0xFF, 9])
        let literals = (0..<128).map { UInt8($0) }
        XCTAssertEqual(PackBits.encode(literals), [127] + literals)
        XCTAssertEqual(PackBits.encode(literals + [200]), [127] + literals + [0, 200])
        // A literal stops before a run of three and keeps a pair (a run there would cost more).
        XCTAssertEqual(PackBits.encode([1, 2, 3, 3, 3]), [1, 1, 2, 0xFE, 3])
        XCTAssertEqual(PackBits.encode([1, 2, 2, 3]), [3, 1, 2, 2, 3])
        // The worst case: pairs between singles stay n + ⌈n / 128⌉.
        let pairs: [UInt8] = (0..<300).flatMap { i -> [UInt8] in [UInt8(i % 100), 250, 250] }
        XCTAssertLessThanOrEqual(PackBits.encode(pairs).count, pairs.count + (pairs.count + 127) / 128)
        XCTAssertEqual(try PackBits.decode(PackBits.encode(pairs), expectedCount: pairs.count), pairs)
    }

    func testTheDecoderRefusesBadStreamsAndSkipsTheNoOpHeader() throws {
        XCTAssertThrowsError(try PackBits.decode([2, 1, 2], expectedCount: 3), "a literal cut short")
        XCTAssertThrowsError(try PackBits.decode([0xFE], expectedCount: 3), "a run without its byte")
        XCTAssertThrowsError(try PackBits.decode([0xFC, 1], expectedCount: 3), "a run past the row")
        XCTAssertThrowsError(try PackBits.decode([0, 1], expectedCount: 3), "the stream ends early")
        XCTAssertEqual(try PackBits.decode([0x80, 0xFE, 4], expectedCount: 3), [4, 4, 4], "−128 is a no-op")
    }
}
