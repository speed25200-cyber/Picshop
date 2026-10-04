import Foundation

/// Apple's PackBits RLE, as PSD channel rows use it (compression 1): a header byte n, then n + 1 literal bytes
/// (0…127) or one byte repeated 1 − n times (−127…−1); −128 is skipped. The encoder keeps a pair of equal bytes inside
/// a literal (a run there would cost more) and starts a run at 3, or at 2 where a block begins, so a row never takes
/// more than n + ⌈n / 128⌉ bytes (the 1.02 of `PSDWriter.estimatedBytes`).
public enum PackBits {
    public static func encode(_ row: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(row.count + row.count / 128 + 1)
        row.withUnsafeBufferPointer { bytes in
            let count = bytes.count
            var index = 0
            while index < count {
                // A run of at least 2 equal bytes (up to 128) where a block begins: never longer than the literal.
                let value = bytes[index]
                var run = 1
                while index + run < count, run < 128, bytes[index + run] == value { run += 1 }
                if run >= 2 {
                    output.append(UInt8(bitPattern: Int8(1 - run)))
                    output.append(value)
                    index += run
                    continue
                }
                // Literals until the next run of 3 (up to 128).
                let start = index
                while index < count, index - start < 128 {
                    if index + 2 < count, bytes[index] == bytes[index + 1], bytes[index] == bytes[index + 2] { break }
                    index += 1
                }
                output.append(UInt8(index - start - 1))
                output.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[start..<index]))
            }
        }
        return output
    }

    /// Decodes exactly `expectedCount` bytes; throws PSDError.badRow when the data ends early or overflows.
    public static func decode(_ data: [UInt8], expectedCount: Int) throws -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(max(0, expectedCount))
        var index = 0
        while output.count < expectedCount {
            guard index < data.count else { throw PSDError.badRow("PackBits: truncated") }
            let header = Int(Int8(bitPattern: data[index]))
            index += 1
            if header >= 0 {
                let count = header + 1
                guard index + count <= data.count else { throw PSDError.badRow("PackBits: truncated") }
                output.append(contentsOf: data[index..<(index + count)])
                index += count
            } else if header != -128 {
                guard index < data.count else { throw PSDError.badRow("PackBits: truncated") }
                output.append(contentsOf: repeatElement(data[index], count: 1 - header))
                index += 1
            }
            if output.count > expectedCount { throw PSDError.badRow("PackBits: overflow") }
        }
        return output
    }
}
