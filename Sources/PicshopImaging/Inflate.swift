#if canImport(Compression)
import Foundation
import Compression
import PicshopCore

/// Raw DEFLATE decompression through Apple's Compression framework.
enum Inflate {
    static func decompress(_ input: Data, expectedSize: Int) throws -> Data {
        let capacity = max(expectedSize, 1 << 16)
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written: Int = input.withUnsafeBytes { raw -> Int in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(destination, capacity, source, input.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { throw PicshopError.modelUnavailable("corrupt archive entry") }
        return Data(bytes: destination, count: written)
    }
}
#endif
