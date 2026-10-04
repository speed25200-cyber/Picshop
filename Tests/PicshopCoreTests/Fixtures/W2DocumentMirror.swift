import Foundation
@testable import PicshopCore

/// The photo document schema of the W2 build (e043f81), frozen (D3): the synthesized `Layer.Content` with its 5 cases,
/// `LayerTransform` with its 5 keys, the W2 `PhotoDocument` keys, `BlendMode`'s 27 raw values and `LayerGroup.Kind`'s 2.
/// The value types W3 did not change (assets, text, shapes, adjustments, edits, masks, selections, table memory) are
/// the Core ones. Every v1 projection must decode through it: this is the "an older build still opens v1" gate.
enum W2Mirror {
    struct Document: Codable, Equatable {
        var id: UUID
        var formatVersion: Int
        var title: String
        var canvasSize: PSSize
        var backgroundColor: PSColor
        var layers: [Layer]
        var selectedLayerID: UUID?
        var createdAt: Date
        var modifiedAt: Date
        var tableMemory: TableMemory?
        var selection: PhotoSelection?
    }

    struct Layer: Codable, Equatable {
        enum Content: Codable, Equatable {
            case image(MediaAsset)
            case text(TextElement)
            case shape(ShapeElement)
            case adjustment(Adjustments)
            case fill(PSColor)
        }

        var id: UUID
        var name: String
        var content: Content
        var transform: Transform
        var opacity: Double
        var blendMode: BlendMode
        var isVisible: Bool
        var isLocked: Bool
        var mask: MaskReference?
        var edits: EditStack
        var group: Group?
    }

    struct Transform: Codable, Equatable {
        var center: PSPoint
        var scale: Double
        var rotation: Double
        var isFlippedHorizontally: Bool
        var isFlippedVertically: Bool
    }

    enum BlendMode: String, Codable, CaseIterable {
        case normal, multiply, screen, overlay, softLight, hardLight, darken, lighten, difference, luminosity, color, hue
        case colorBurn, colorDodge, linearBurn, linearDodge, linearLight, vividLight, pinLight, hardMix
        case exclusion, subtract, divide, saturation, darkerColor, lighterColor, dissolve
    }

    struct Group: Codable, Equatable {
        enum Kind: String, Codable { case tableCells, tableHighlight }
        var id: UUID
        var kind: Kind
        var row: Int?
        var column: Int?
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// What a W2 build reads from these bytes (throws when it cannot).
    static func decode(_ data: Data) throws -> Document {
        try decoder().decode(Document.self, from: data)
    }
}

extension W2Mirror {
    /// The W2 project.json wrapper (photo projects only).
    struct Project: Codable, Equatable {
        enum Content: Codable, Equatable {
            case photo(Document)
        }

        var id: UUID
        var content: Content
        var createdAt: Date
        var modifiedAt: Date

        var document: Document {
            get {
                switch content {
                case .photo(let document): return document
                }
            }
            set { content = .photo(newValue) }
        }
    }
}
