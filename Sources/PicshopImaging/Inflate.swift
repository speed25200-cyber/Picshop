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

    /// Streaming raw-DEFLATE decode straight to a file (bounded memory for multi-GB weights).
    static func decompressToFile(_ input: Data, expectedSize: Int, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>.allocate(capacity: 0), dst_size: 0, src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw PicshopError.modelUnavailable("inflate init")
        }
        defer { compression_stream_destroy(&stream) }
        let chunk = 1 << 20
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.src_ptr = base
            stream.src_size = raw.count
            var status = COMPRESSION_STATUS_OK
            repeat {
                stream.dst_ptr = buffer
                stream.dst_size = chunk
                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.dst_size
                if produced > 0 { try handle.write(contentsOf: Data(bytes: buffer, count: produced)) }
                if status == COMPRESSION_STATUS_ERROR { throw PicshopError.modelUnavailable("corrupt archive entry") }
            } while status == COMPRESSION_STATUS_OK
        }
    }
}
#endif
