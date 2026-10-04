import Foundation

// D16a: the layered PSD writer, pure Swift so it is Linux-tested with a parser round trip (PSDFile) and checked by
// psd-tools on CI. Big-endian, layer and mask information section, PackBits rows, two streaming passes. L2's
// PSDExport feeds it rows from the strip renderer.

public struct PSDRect: Hashable, Sendable {
    public var top: Int32, left: Int32, bottom: Int32, right: Int32

    public init(top: Int32, left: Int32, bottom: Int32, right: Int32) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let empty = PSDRect(top: 0, left: 0, bottom: 0, right: 0)

    public var width: Int { max(0, Int(right) - Int(left)) }
    public var height: Int { max(0, Int(bottom) - Int(top)) }
}

/// Pulls one row at a time (y = 0 is the rect's top row): `channels` interleaved samples per pixel, 1 byte each at depth 8,
/// 2 bytes big-endian each at depth 16.
public protocol PSDRowSource: AnyObject {
    var channels: Int { get }
    func row(_ y: Int) throws -> [UInt8]
}

/// Rows held in memory (tests and small layers).
public final class PSDMemoryRows: PSDRowSource {
    public let width: Int
    public let height: Int
    public let channels: Int
    public let depth: Int
    private let bytes: [UInt8]

    public init(width: Int, height: Int, channels: Int, depth: Int, bytes: [UInt8]) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.channels = max(1, channels)
        self.depth = depth == 16 ? 16 : 8
        self.bytes = bytes
    }

    private var rowBytes: Int { width * channels * (depth / 8) }

    public func row(_ y: Int) throws -> [UInt8] {
        let start = y * rowBytes, end = start + rowBytes
        guard y >= 0, y < height, end <= bytes.count else { throw PSDError.badRow("row \(y) of \(height)") }
        return Array(bytes[start..<end])
    }
}

public struct PSDLayerMask {
    public var rect: PSDRect
    /// 0 or 255 outside the rect.
    public var defaultColor: UInt8
    public var disabled: Bool
    /// 1 channel.
    public var rows: any PSDRowSource

    public init(rect: PSDRect, defaultColor: UInt8, disabled: Bool, rows: any PSDRowSource) {
        self.rect = rect
        self.defaultColor = defaultColor
        self.disabled = disabled
        self.rows = rows
    }
}

public struct PSDLayer {
    /// A raster layer, or a group's opening record and its closing divider (D16c).
    public enum Kind: Hashable, Sendable { case pixels, groupOpen(collapsed: Bool), groupEnd }

    public var kind: Kind
    public var name: String
    public var rect: PSDRect
    public var blendKey: String
    public var opacity: UInt8
    public var fillOpacity: UInt8
    public var clipped: Bool
    public var visible: Bool
    public var lockFlags: UInt32
    public var layerID: UInt32
    /// RGBA over rect; nil for markers and empty layers.
    public var pixels: (any PSDRowSource)?
    public var mask: PSDLayerMask?

    public init(kind: Kind = .pixels, name: String, rect: PSDRect, blendKey: String = "norm", opacity: UInt8 = 255,
                fillOpacity: UInt8 = 255, clipped: Bool = false, visible: Bool = true, lockFlags: UInt32 = 0,
                layerID: UInt32, pixels: (any PSDRowSource)?, mask: PSDLayerMask? = nil) {
        self.kind = kind
        self.name = name
        self.rect = rect
        self.blendKey = blendKey
        self.opacity = opacity
        self.fillOpacity = fillOpacity
        self.clipped = clipped
        self.visible = visible
        self.lockFlags = lockFlags
        self.layerID = layerID
        self.pixels = pixels
        self.mask = mask
    }
}

public struct PSDDocumentSpec {
    public var width: Int
    public var height: Int
    /// 8 (must) or 16 ("should").
    public var depth: Int
    /// ppi.
    public var resolution: Double
    public var iccProfile: Data?
    /// Bottom → top, group markers included (D16c).
    public var layers: [PSDLayer]
    /// RGBA rows of the whole canvas.
    public var composite: any PSDRowSource

    public init(width: Int, height: Int, depth: Int = 8, resolution: Double = 300, iccProfile: Data? = nil,
                layers: [PSDLayer], composite: any PSDRowSource) {
        self.width = width
        self.height = height
        self.depth = depth
        self.resolution = resolution
        self.iccProfile = iccProfile
        self.layers = layers
        self.composite = composite
    }
}

public enum PSDError: Error, Equatable { case tooLarge, tooHeavy, unsupportedDepth, badRow(String), io(String) }

public enum PSDWriter {
    /// Larger sides need PSB (out of scope): « Trop grand pour un PSD ».
    public static let maxSide = 30_000
    /// D16a: Photoshop's 2 GB PSD limit; the estimate or the running total above it throws .tooHeavy.
    public static let maxBytes = 2_000_000_000

    /// D16a, two passes, streaming:
    /// 1. every channel of every layer (and of the merged image) is pulled row by row from its source, PackBits-
    ///    compressed and appended to its own file under `temporaryDirectory/psd-<uuid>/`, with each row's byte count;
    /// 2. the file is assembled with every length known: header, resources (0x03ED resolution, 0x040F ICC), the layer
    ///    and mask information (at 16 bits inside an `Lr16` block), the merged image; the temporaries are deleted.
    /// Peak memory is one row, its compressed bytes and a 1 MB write buffer. Throws `.unsupportedDepth` (not 8 or 16),
    /// `.tooLarge` (a side over 30,000), `.tooHeavy` before writing when the estimate passes `maxBytes` and while
    /// compressing when the running total does, `.badRow` for a short or failing row, `.io` for the file system.
    public static func write(_ spec: PSDDocumentSpec, to url: URL, temporaryDirectory: URL,
                             progress: ((Double) -> Void)? = nil) throws {
        guard spec.depth == 8 || spec.depth == 16 else { throw PSDError.unsupportedDepth }
        guard spec.width > 0, spec.height > 0, spec.width <= maxSide, spec.height <= maxSide else { throw PSDError.tooLarge }
        for layer in spec.layers {
            guard layer.rect.width <= maxSide, layer.rect.height <= maxSide, (layer.mask?.rect.width ?? 0) <= maxSide,
                  (layer.mask?.rect.height ?? 0) <= maxSide else { throw PSDError.tooLarge }
        }
        guard estimatedBytes(spec) <= maxBytes else { throw PSDError.tooHeavy }

        let fm = FileManager.default
        let work = temporaryDirectory.appendingPathComponent("psd-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            throw PSDError.io("temporary directory: \(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: work) }

        // Pass 1.
        let bytesPerSample = spec.depth / 8
        let totalRows = Double(max(1, spec.height + spec.layers.reduce(0) { $0 + $1.rect.height + ($1.mask?.rect.height ?? 0) }))
        var rowsDone = 0.0
        var runningTotal = 64 + (spec.iccProfile?.count ?? 0)
        func tick(_ rows: Int) {
            rowsDone += Double(rows)
            progress?(min(0.9, 0.9 * rowsDone / totalRows))
        }
        var compressed: [CompressedLayer] = []
        for (index, layer) in spec.layers.enumerated() {
            let channels = try compress(layer, index: index, bytesPerSample: bytesPerSample, in: work, tick: tick)
            runningTotal += channels.reduce(0) { $0 + $1.recordLength } + 512 + 2 * layer.name.utf16.count
            guard runningTotal <= maxBytes else { throw PSDError.tooHeavy }
            compressed.append(CompressedLayer(layer: layer, channels: channels))
        }
        let composite = try compressComposite(spec, bytesPerSample: bytesPerSample, in: work, tick: tick)
        runningTotal += composite.reduce(0) { $0 + $1.rowCounts.count * 2 + $1.dataLength }
        guard runningTotal <= maxBytes else { throw PSDError.tooHeavy }

        // Pass 2.
        let records = compressed.map { record(for: $0.layer, channels: $0.channels) }
        var layerInfo = Data()
        layerInfo.appendInt16(Int16(clamping: -records.count))
        for record in records { layerInfo.append(record) }
        let channelBytes = compressed.reduce(0) { $0 + $1.channels.reduce(0) { $0 + $1.recordLength } }
        let layerInfoLength = padded(layerInfo.count + channelBytes, to: 4)
        let resources = imageResources(resolution: spec.resolution, icc: spec.iccProfile)

        guard fm.createFile(atPath: url.path, contents: nil) else { throw PSDError.io("cannot create \(url.lastPathComponent)") }
        do {
            let output = try BufferedFile(url: url)
            defer { output.close() }
            // 1. Header.
            var header = Data()
            header.append(contentsOf: Array("8BPS".utf8))
            header.appendUInt16(1)
            header.append(contentsOf: [UInt8](repeating: 0, count: 6))
            header.appendUInt16(4)
            header.appendUInt32(UInt32(spec.height))
            header.appendUInt32(UInt32(spec.width))
            header.appendUInt16(UInt16(spec.depth))
            header.appendUInt16(3)
            // 2. Colour mode data: none.
            header.appendUInt32(0)
            // 3. Image resources.
            header.appendUInt32(UInt32(resources.count))
            header.append(resources)
            try output.write(header)
            // 4. Layer and mask information.
            var section = Data()
            if spec.depth == 16 {
                // Layer info empty here, the real one in an Lr16 block after the global layer mask info.
                section.appendUInt32(UInt32(4 + 4 + 12 + layerInfoLength))
                section.appendUInt32(0)
                section.appendUInt32(0)
                section.append(contentsOf: Array("8BIMLr16".utf8))
                section.appendUInt32(UInt32(layerInfoLength))
            } else {
                section.appendUInt32(UInt32(4 + layerInfoLength + 4))
                section.appendUInt32(UInt32(layerInfoLength))
            }
            section.append(layerInfo)
            try output.write(section)
            for layer in compressed {
                for channel in layer.channels { try output.writeChannel(channel) }
            }
            try output.write(Data(repeating: 0, count: layerInfoLength - layerInfo.count - channelBytes))
            if spec.depth == 8 { try output.write(Data(count: 4)) }
            // 5. The merged image: RLE, every row count of every channel, then the rows.
            var image = Data()
            image.appendUInt16(1)
            for channel in composite { for count in channel.rowCounts { image.appendUInt16(count) } }
            try output.write(image)
            for (index, channel) in composite.enumerated() {
                try output.copy(from: channel.file, length: channel.dataLength)
                progress?(0.9 + 0.1 * Double(index + 1) / Double(composite.count))
            }
            try output.flush()
        } catch let error as PSDError {
            try? fm.removeItem(at: url)
            throw error
        } catch {
            try? fm.removeItem(at: url)
            throw PSDError.io(error.localizedDescription)
        }
        progress?(1)
    }

    /// An upper bound of the file's size (D16a): the merged image and every layer's and mask's bounds, raw, × 1.02 for
    /// PackBits' worst case, plus the records.
    public static func estimatedBytes(_ spec: PSDDocumentSpec) -> Int {
        let bytes = Double(max(1, spec.depth / 8))
        var samples = Double(spec.width) * Double(spec.height) * 4
        for layer in spec.layers {
            if layer.pixels != nil { samples += Double(layer.rect.width) * Double(layer.rect.height) * Double(max(3, min(4, layer.pixels?.channels ?? 4))) }
            if let mask = layer.mask { samples += Double(mask.rect.width) * Double(mask.rect.height) }
        }
        let total = samples * bytes * 1.02 + Double(spec.layers.count) * 512 + Double(spec.iccProfile?.count ?? 0) + 1024
        return total >= Double(Int.max) ? Int.max : Int(total.rounded(.up))
    }

    // MARK: Pass 1

    struct CompressedChannel {
        var id: Int16
        /// 0 raw (an empty channel) or 1 PackBits.
        var compression: UInt16
        var rowCounts: [UInt16]
        var file: URL?
        var dataLength: Int

        /// The channel's length in its layer record: the compression field, the row counts and the rows.
        var recordLength: Int { 2 + rowCounts.count * 2 + dataLength }

        static func empty(_ id: Int16) -> CompressedChannel {
            CompressedChannel(id: id, compression: 0, rowCounts: [], file: nil, dataLength: 0)
        }
    }

    struct CompressedLayer {
        var layer: PSDLayer
        var channels: [CompressedChannel]
    }

    /// RGBA (or RGB) rows of a layer and its mask into per-channel PackBits files; markers and empty layers get four
    /// empty channels.
    static func compress(_ layer: PSDLayer, index: Int, bytesPerSample: Int, in directory: URL, tick: (Int) -> Void) throws -> [CompressedChannel] {
        var channels: [CompressedChannel]
        if case .pixels = layer.kind, let source = layer.pixels, layer.rect.width > 0, layer.rect.height > 0 {
            let order: [Int16]
            switch source.channels {
            case 4: order = [0, 1, 2, -1]
            case 3: order = [0, 1, 2]
            default: throw PSDError.badRow("layer \(index): \(source.channels) channels")
            }
            let compressed = try compressRows(source, rows: layer.rect.height, width: layer.rect.width, ids: order, bytesPerSample: bytesPerSample,
                                              directory: directory, prefix: "layer\(index)", tick: tick)
            // Records list the transparency first, as Photoshop does.
            channels = compressed.sorted { ($0.id == -1 ? -10 : Int($0.id)) < ($1.id == -1 ? -10 : Int($1.id)) }
        } else {
            channels = [-1, 0, 1, 2].map(CompressedChannel.empty)
        }
        if let mask = layer.mask {
            if mask.rect.width > 0, mask.rect.height > 0 {
                guard mask.rows.channels == 1 else { throw PSDError.badRow("layer \(index) mask: \(mask.rows.channels) channels") }
                channels += try compressRows(mask.rows, rows: mask.rect.height, width: mask.rect.width, ids: [-2], bytesPerSample: bytesPerSample,
                                             directory: directory, prefix: "mask\(index)", tick: tick)
            } else {
                channels.append(.empty(-2))
            }
        }
        return channels
    }

    /// The merged image's R, G, B and A channels (A opaque when the source has 3 channels).
    static func compressComposite(_ spec: PSDDocumentSpec, bytesPerSample: Int, in directory: URL, tick: (Int) -> Void) throws -> [CompressedChannel] {
        switch spec.composite.channels {
        case 4:
            return try compressRows(spec.composite, rows: spec.height, width: spec.width, ids: [0, 1, 2, -1], bytesPerSample: bytesPerSample,
                                    directory: directory, prefix: "merged", tick: tick)
        case 3:
            let rgb = try compressRows(spec.composite, rows: spec.height, width: spec.width, ids: [0, 1, 2], bytesPerSample: bytesPerSample,
                                       directory: directory, prefix: "merged", tick: tick)
            let opaque = OpaqueRows(width: spec.width, height: spec.height, bytesPerSample: bytesPerSample)
            return rgb + (try compressRows(opaque, rows: spec.height, width: spec.width, ids: [-1], bytesPerSample: bytesPerSample,
                                           directory: directory, prefix: "merged-alpha", tick: { _ in }))
        default:
            throw PSDError.badRow("merged image: \(spec.composite.channels) channels")
        }
    }

    /// Pulls `rows` interleaved rows once each, in order, and writes every channel's PackBits rows to its own file.
    static func compressRows(_ source: any PSDRowSource, rows: Int, width: Int, ids: [Int16], bytesPerSample: Int,
                             directory: URL, prefix: String, tick: (Int) -> Void) throws -> [CompressedChannel] {
        let channelCount = ids.count
        let rowBytes = width * bytesPerSample
        var sinks: [BufferedFile] = []
        var channels: [CompressedChannel] = []
        for id in ids {
            let file = directory.appendingPathComponent("\(prefix)-\(id < 0 ? "m\(-id)" : "\(id)").rle")
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw PSDError.io("temporary file") }
            sinks.append(try BufferedFile(url: file))
            channels.append(CompressedChannel(id: id, compression: 1, rowCounts: [], file: file, dataLength: 0))
        }
        defer { sinks.forEach { $0.close() } }
        for index in channels.indices { channels[index].rowCounts.reserveCapacity(rows) }
        var planes = [[UInt8]](repeating: [UInt8](repeating: 0, count: rowBytes), count: channelCount)
        for y in 0..<rows {
            let row: [UInt8]
            do {
                row = try source.row(y)
            } catch let error as PSDError {
                throw error
            } catch {
                throw PSDError.badRow("\(prefix) row \(y): \(error)")
            }
            guard row.count >= width * channelCount * bytesPerSample else { throw PSDError.badRow("\(prefix) row \(y): \(row.count) bytes") }
            // Deinterleave.
            row.withUnsafeBufferPointer { source in
                let stride = channelCount * bytesPerSample
                for c in 0..<channelCount {
                    planes[c].withUnsafeMutableBufferPointer { plane in
                        var from = c * bytesPerSample, to = 0
                        if bytesPerSample == 2 {
                            for _ in 0..<width {
                                plane[to] = source[from]
                                plane[to + 1] = source[from + 1]
                                from += stride
                                to += 2
                            }
                        } else {
                            for _ in 0..<width {
                                plane[to] = source[from]
                                from += stride
                                to += 1
                            }
                        }
                    }
                }
            }
            for c in 0..<channelCount {
                let packed = PackBits.encode(planes[c])
                guard packed.count <= Int(UInt16.max) else { throw PSDError.tooLarge }
                channels[c].rowCounts.append(UInt16(packed.count))
                channels[c].dataLength += packed.count
                try sinks[c].write(packed)
            }
            tick(1)
        }
        for sink in sinks { try sink.flush() }
        return channels
    }

    // MARK: Pass 2

    /// One layer record (D16a), without its channel data.
    static func record(for layer: PSDLayer, channels: [CompressedChannel]) -> Data {
        var data = Data()
        let rect: PSDRect
        switch layer.kind {
        case .pixels: rect = layer.pixels == nil ? PSDRect.empty : layer.rect
        case .groupOpen, .groupEnd: rect = .empty
        }
        data.appendInt32(rect.top)
        data.appendInt32(rect.left)
        data.appendInt32(rect.bottom)
        data.appendInt32(rect.right)
        data.appendUInt16(UInt16(channels.count))
        for channel in channels {
            data.appendInt16(channel.id)
            data.appendUInt32(UInt32(channel.recordLength))
        }
        data.append(contentsOf: Array("8BIM".utf8))
        data.append(contentsOf: blendKeyBytes(layer.blendKey))
        data.append(layer.opacity)
        data.append(layer.clipped ? 1 : 0)
        var flags: UInt8 = 8
        if layer.lockFlags & 1 != 0 || layer.lockFlags & 0x8000_0000 != 0 { flags |= 1 }
        if !layer.visible { flags |= 2 }
        if case .pixels = layer.kind {} else { flags |= 16 }
        data.append(flags)
        data.append(0)
        var extra = Data()
        if let mask = layer.mask {
            extra.appendUInt32(20)
            extra.appendInt32(mask.rect.top)
            extra.appendInt32(mask.rect.left)
            extra.appendInt32(mask.rect.bottom)
            extra.appendInt32(mask.rect.right)
            extra.append(mask.defaultColor)
            extra.append(mask.disabled ? 2 : 0)
            extra.append(contentsOf: [0, 0])
        } else {
            extra.appendUInt32(0)
        }
        extra.appendUInt32(0)
        let name: String
        switch layer.kind {
        case .groupEnd: name = "</Layer group>"
        case .pixels, .groupOpen: name = layer.name
        }
        extra.append(pascalName(name))
        // Tagged blocks.
        var unicode = Data()
        let units = Array(name.utf16)
        unicode.appendUInt32(UInt32(units.count))
        for unit in units { unicode.appendUInt16(unit) }
        extra.append(taggedBlock("luni", unicode))
        var id = Data()
        id.appendUInt32(layer.layerID)
        extra.append(taggedBlock("lyid", id))
        extra.append(taggedBlock("iOpa", Data([layer.fillOpacity, 0, 0, 0])))
        var lock = Data()
        lock.appendUInt32(layer.lockFlags)
        extra.append(taggedBlock("lspf", lock))
        switch layer.kind {
        case .groupOpen(let collapsed):
            var section = Data()
            section.appendUInt32(collapsed ? 2 : 1)
            section.append(contentsOf: Array("8BIM".utf8))
            section.append(contentsOf: blendKeyBytes(layer.blendKey))
            extra.append(taggedBlock("lsct", section))
        case .groupEnd:
            var section = Data()
            section.appendUInt32(3)
            extra.append(taggedBlock("lsct", section))
        case .pixels:
            break
        }
        extra.append(taggedBlock("clbl", Data([1, 0, 0, 0])))
        data.appendUInt32(UInt32(extra.count))
        data.append(extra)
        return data
    }

    /// 0x03ED resolution (fixed 16.16 pixels per inch, sizes in inches) and 0x040F ICC.
    static func imageResources(resolution: Double, icc: Data?) -> Data {
        var data = Data()
        var info = Data()
        let fixed = UInt32((resolution.isFinite && resolution > 0 ? min(resolution, 30_000) : 300) * 65536)
        info.appendUInt32(fixed)
        info.appendUInt16(1)
        info.appendUInt16(1)
        info.appendUInt32(fixed)
        info.appendUInt16(1)
        info.appendUInt16(1)
        data.append(resourceBlock(0x03ED, info))
        if let icc, !icc.isEmpty { data.append(resourceBlock(0x040F, icc)) }
        return data
    }

    static func resourceBlock(_ id: UInt16, _ payload: Data) -> Data {
        var data = Data()
        data.append(contentsOf: Array("8BIM".utf8))
        data.appendUInt16(id)
        // An empty Pascal name, padded to even.
        data.append(contentsOf: [0, 0])
        data.appendUInt32(UInt32(payload.count))
        data.append(payload)
        if payload.count % 2 == 1 { data.append(0) }
        return data
    }

    /// "8BIM" + key + length + data, the length and data padded to even.
    static func taggedBlock(_ key: String, _ payload: Data) -> Data {
        var data = Data()
        data.append(contentsOf: Array("8BIM".utf8))
        data.append(contentsOf: Array(key.utf8.prefix(4)))
        let length = padded(payload.count, to: 2)
        data.appendUInt32(UInt32(length))
        data.append(payload)
        if length > payload.count { data.append(Data(count: length - payload.count)) }
        return data
    }

    /// MacRoman (lossy), at most 255 bytes, padded with the length byte to a multiple of 4.
    static func pascalName(_ name: String) -> Data {
        var bytes = Array((name.data(using: .macOSRoman, allowLossyConversion: true) ?? Data(name.utf8.map { $0 < 128 ? $0 : 63 })).prefix(255))
        if bytes.isEmpty, !name.isEmpty { bytes = [63] }
        var data = Data([UInt8(bytes.count)])
        data.append(contentsOf: bytes)
        let total = padded(data.count, to: 4)
        if total > data.count { data.append(Data(count: total - data.count)) }
        return data
    }

    static func blendKeyBytes(_ key: String) -> [UInt8] {
        var bytes = Array(key.utf8.prefix(4))
        while bytes.count < 4 { bytes.append(32) }
        return bytes
    }

    static func padded(_ count: Int, to multiple: Int) -> Int {
        (count + multiple - 1) / multiple * multiple
    }

    /// Opaque alpha rows (a merged image given as RGB).
    final class OpaqueRows: PSDRowSource {
        let width: Int, height: Int, bytesPerSample: Int
        var channels: Int { 1 }

        init(width: Int, height: Int, bytesPerSample: Int) {
            self.width = width
            self.height = height
            self.bytesPerSample = bytesPerSample
        }

        func row(_ y: Int) throws -> [UInt8] {
            [UInt8](repeating: 255, count: width * bytesPerSample)
        }
    }

    /// A file written through a 1 MB buffer.
    final class BufferedFile {
        private let handle: FileHandle
        private var buffer = Data()
        private let capacity = 1 << 20
        private var isClosed = false

        init(url: URL) throws {
            do {
                handle = try FileHandle(forWritingTo: url)
            } catch {
                throw PSDError.io("cannot open \(url.lastPathComponent)")
            }
            buffer.reserveCapacity(capacity)
        }

        func write(_ bytes: [UInt8]) throws {
            buffer.append(contentsOf: bytes)
            if buffer.count >= capacity { try flush() }
        }

        func write(_ data: Data) throws {
            buffer.append(data)
            if buffer.count >= capacity { try flush() }
        }

        func flush() throws {
            guard !buffer.isEmpty else { return }
            do {
                try handle.write(contentsOf: buffer)
            } catch {
                throw PSDError.io("write failed: \(error.localizedDescription)")
            }
            buffer.removeAll(keepingCapacity: true)
        }

        /// A layer channel as its record says: compression, row counts, rows.
        func writeChannel(_ channel: CompressedChannel) throws {
            var head = Data()
            head.appendUInt16(channel.compression)
            for count in channel.rowCounts { head.appendUInt16(count) }
            try write(head)
            if let file = channel.file { try copy(from: file, length: channel.dataLength) }
        }

        func copy(from file: URL?, length: Int) throws {
            guard let file, length > 0 else { return }
            try flush()
            let reader: FileHandle
            do {
                reader = try FileHandle(forReadingFrom: file)
            } catch {
                throw PSDError.io("cannot read a temporary file")
            }
            defer { try? reader.close() }
            var remaining = length
            while remaining > 0 {
                let chunk: Data
                do {
                    chunk = try reader.read(upToCount: min(remaining, capacity)) ?? Data()
                } catch {
                    throw PSDError.io("read failed: \(error.localizedDescription)")
                }
                guard !chunk.isEmpty else { throw PSDError.io("a temporary file is short") }
                do {
                    try handle.write(contentsOf: chunk)
                } catch {
                    throw PSDError.io("write failed: \(error.localizedDescription)")
                }
                remaining -= chunk.count
            }
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            try? flush()
            try? handle.close()
        }
    }
}

// MARK: - Big-endian helpers

extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendInt16(_ value: Int16) {
        appendUInt16(UInt16(bitPattern: value))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value >> 24))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendInt32(_ value: Int32) {
        appendUInt32(UInt32(bitPattern: value))
    }
}
