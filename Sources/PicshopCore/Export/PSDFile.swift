import Foundation

/// The PSD parser, for the round-trip tests and the CI check (not an import feature): header, image resources, the
/// layer records with their tagged blocks (luni, lsct, iOpa, lspf, lyid, clbl; the 16-bit layer info in Lr16), the
/// channel data raw and PackBits, and the merged image. 16-bit samples stay big-endian byte pairs.
public struct PSDFile {
    public struct LayerRecord {
        /// luni when present, else the Pascal name.
        public var name: String
        public var rect: PSDRect
        public var blendKey: String
        public var opacity: UInt8
        public var fillOpacity: UInt8?
        public var clipped: Bool
        public var visible: Bool
        /// lsct.
        public var sectionType: Int?
        public var lockFlags: UInt32?
        public var layerID: UInt32?
        /// Decoded planar samples per channel id.
        public var channels: [Int16: [UInt8]]
        public var maskRect: PSDRect?
        public var maskDefaultColor: UInt8?
        public var maskDisabled: Bool?
        /// The group's blend key from lsct's long form, when present.
        public var sectionBlendKey: String?
        /// The raw flags byte (bit 0 transparency protected, bit 1 hidden, bit 4 pixel data irrelevant).
        public var flags: UInt8
    }

    public var width: Int, height: Int, depth: Int, channelCount: Int
    /// Bottom → top.
    public var layers: [LayerRecord]
    /// Planar, channel index → samples.
    public var composite: [Int: [UInt8]]
    public var resources: [UInt16: Data]

    public init(data: Data) throws {
        var reader = Reader(bytes: [UInt8](data))
        guard try reader.string(4) == "8BPS", try reader.uint16() == 1 else { throw PSDError.io("not a PSD") }
        try reader.skip(6)
        channelCount = Int(try reader.uint16())
        height = Int(try reader.uint32())
        width = Int(try reader.uint32())
        depth = Int(try reader.uint16())
        guard try reader.uint16() == 3 else { throw PSDError.io("not RGB") }
        guard depth == 8 || depth == 16 else { throw PSDError.unsupportedDepth }
        // Colour mode data.
        try reader.skip(Int(try reader.uint32()))
        // Image resources.
        var resources: [UInt16: Data] = [:]
        let resourcesEnd = Int(try reader.uint32()) + reader.offset
        while reader.offset < resourcesEnd {
            guard try reader.string(4) == "8BIM" else { throw PSDError.io("bad resource") }
            let id = try reader.uint16()
            let nameLength = Int(try reader.uint8())
            try reader.skip(nameLength + ((nameLength + 1) % 2))
            let size = Int(try reader.uint32())
            resources[id] = Data(try reader.bytes(size))
            if size % 2 == 1 { try reader.skip(1) }
        }
        reader.offset = resourcesEnd
        self.resources = resources
        // Layer and mask information.
        let sectionLength = Int(try reader.uint32())
        let sectionEnd = reader.offset + sectionLength
        var layers: [LayerRecord] = []
        let bytesPerSample = depth / 8
        if sectionLength > 0 {
            let layerInfoLength = Int(try reader.uint32())
            let layerInfoEnd = reader.offset + layerInfoLength
            if layerInfoLength > 0 {
                var sub = reader
                layers = try Self.layerInfo(&sub, bytesPerSample: bytesPerSample)
            }
            reader.offset = layerInfoEnd
            if reader.offset + 4 <= sectionEnd {
                try reader.skip(Int(try reader.uint32()))
            }
            // Tagged blocks: the 16-bit layer info.
            while reader.offset + 12 <= sectionEnd {
                let signature = try reader.string(4)
                guard signature == "8BIM" || signature == "8B64" else { break }
                let key = try reader.string(4)
                let length = Int(try reader.uint32())
                let blockEnd = reader.offset + length
                if key == "Lr16" || key == "Lr32", layers.isEmpty, length > 0 {
                    var sub = reader
                    layers = try Self.layerInfo(&sub, bytesPerSample: bytesPerSample)
                }
                reader.offset = blockEnd + (length % 2 == 1 ? 1 : 0)
            }
            reader.offset = sectionEnd
        }
        self.layers = layers
        // The merged image.
        var composite: [Int: [UInt8]] = [:]
        let compression = try reader.uint16()
        let rowBytes = width * bytesPerSample
        if compression == 1 {
            var counts: [Int] = []
            for _ in 0..<(channelCount * height) { counts.append(Int(try reader.uint16())) }
            for channel in 0..<channelCount {
                var plane: [UInt8] = []
                plane.reserveCapacity(rowBytes * height)
                for row in 0..<height {
                    plane += try PackBits.decode(try reader.bytes(counts[channel * height + row]), expectedCount: rowBytes)
                }
                composite[channel] = plane
            }
        } else if compression == 0 {
            for channel in 0..<channelCount { composite[channel] = try reader.bytes(rowBytes * height) }
        } else {
            throw PSDError.io("merged image compression \(compression)")
        }
        self.composite = composite
    }

    /// Layer count, records, channel data.
    static func layerInfo(_ reader: inout Reader, bytesPerSample: Int) throws -> [LayerRecord] {
        let count = Int(abs(Int32(try reader.int16())))
        var records: [LayerRecord] = []
        var channelInfo: [[(id: Int16, length: Int)]] = []
        for _ in 0..<count {
            let rect = PSDRect(top: try reader.int32(), left: try reader.int32(), bottom: try reader.int32(), right: try reader.int32())
            let channelCount = Int(try reader.uint16())
            var channels: [(id: Int16, length: Int)] = []
            for _ in 0..<channelCount { channels.append((try reader.int16(), Int(try reader.uint32()))) }
            guard try reader.string(4) == "8BIM" else { throw PSDError.io("bad layer record") }
            let blendKey = try reader.string(4)
            let opacity = try reader.uint8()
            let clipping = try reader.uint8()
            let flags = try reader.uint8()
            try reader.skip(1)
            let extraLength = Int(try reader.uint32())
            let extraEnd = reader.offset + extraLength
            var record = LayerRecord(name: "", rect: rect, blendKey: blendKey, opacity: opacity, fillOpacity: nil, clipped: clipping == 1,
                                     visible: flags & 2 == 0, sectionType: nil, lockFlags: nil, layerID: nil, channels: [:], maskRect: nil,
                                     maskDefaultColor: nil, maskDisabled: nil, sectionBlendKey: nil, flags: flags)
            // Layer mask data.
            let maskLength = Int(try reader.uint32())
            let maskEnd = reader.offset + maskLength
            if maskLength >= 18 {
                record.maskRect = PSDRect(top: try reader.int32(), left: try reader.int32(), bottom: try reader.int32(), right: try reader.int32())
                record.maskDefaultColor = try reader.uint8()
                record.maskDisabled = try reader.uint8() & 2 != 0
            }
            reader.offset = maskEnd
            // Blending ranges.
            try reader.skip(Int(try reader.uint32()))
            // Pascal name, padded to 4.
            let nameLength = Int(try reader.uint8())
            let nameBytes = try reader.bytes(nameLength)
            record.name = String(data: Data(nameBytes), encoding: .macOSRoman) ?? String(decoding: nameBytes, as: UTF8.self)
            let consumed = 1 + nameLength
            try reader.skip((4 - consumed % 4) % 4)
            // Tagged blocks.
            while reader.offset + 12 <= extraEnd {
                let signature = try reader.string(4)
                guard signature == "8BIM" || signature == "8B64" else { break }
                let key = try reader.string(4)
                let length = Int(try reader.uint32())
                let blockEnd = reader.offset + length
                switch key {
                case "luni":
                    let units = Int(try reader.uint32())
                    var utf16: [UInt16] = []
                    for _ in 0..<units { utf16.append(try reader.uint16()) }
                    record.name = String(decoding: utf16, as: UTF16.self)
                case "lyid": record.layerID = try reader.uint32()
                case "iOpa": record.fillOpacity = try reader.uint8()
                case "lspf": record.lockFlags = try reader.uint32()
                case "lsct":
                    record.sectionType = Int(try reader.uint32())
                    if length >= 12, try reader.string(4) == "8BIM" { record.sectionBlendKey = try reader.string(4) }
                default: break
                }
                reader.offset = blockEnd + (length % 2 == 1 ? 1 : 0)
            }
            reader.offset = extraEnd
            records.append(record)
            channelInfo.append(channels)
        }
        // Channel image data, per record, per channel.
        for index in records.indices {
            for channel in channelInfo[index] {
                let start = reader.offset
                let compression = try reader.uint16()
                let rect = channel.id == -2 ? (records[index].maskRect ?? .empty) : records[index].rect
                let rows = rect.height, rowBytes = rect.width * bytesPerSample
                if channel.length > 2, rows > 0, rowBytes > 0 {
                    switch compression {
                    case 0:
                        records[index].channels[channel.id] = try reader.bytes(rows * rowBytes)
                    case 1:
                        var counts: [Int] = []
                        for _ in 0..<rows { counts.append(Int(try reader.uint16())) }
                        var plane: [UInt8] = []
                        plane.reserveCapacity(rows * rowBytes)
                        for row in 0..<rows { plane += try PackBits.decode(try reader.bytes(counts[row]), expectedCount: rowBytes) }
                        records[index].channels[channel.id] = plane
                    default:
                        throw PSDError.io("channel compression \(compression)")
                    }
                } else {
                    records[index].channels[channel.id] = []
                }
                reader.offset = start + channel.length
            }
        }
        return records
    }

    /// Big-endian reading over bytes.
    struct Reader {
        let storage: [UInt8]
        var offset = 0

        init(bytes: [UInt8]) {
            storage = bytes
        }

        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0, offset + count <= storage.count else { throw PSDError.io("truncated at \(offset)") }
            defer { offset += count }
            return Array(storage[offset..<(offset + count)])
        }

        mutating func skip(_ count: Int) throws {
            guard count >= 0, offset + count <= storage.count else { throw PSDError.io("truncated at \(offset)") }
            offset += count
        }

        mutating func uint8() throws -> UInt8 { try bytes(1)[0] }

        mutating func uint16() throws -> UInt16 {
            let b = try bytes(2)
            return UInt16(b[0]) << 8 | UInt16(b[1])
        }

        mutating func int16() throws -> Int16 { Int16(bitPattern: try uint16()) }

        mutating func uint32() throws -> UInt32 {
            let b = try bytes(4)
            return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        }

        mutating func int32() throws -> Int32 { Int32(bitPattern: try uint32()) }

        mutating func string(_ count: Int) throws -> String {
            String(decoding: try bytes(count), as: UTF8.self)
        }
    }
}
