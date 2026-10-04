import Foundation
@testable import PicshopCore

/// Documents as W1 and W2 builds wrote them (sorted keys, ISO 8601 dates): the seam fixtures, real output of those
/// builds, plus a few v1-only documents built here with W2's features only (no v2 key is ever set).
enum W2Documents {
    /// The W1 fixture (W2 seam) and the W2 fixture (e043f81, W3 seam).
    static var json: [String] { [W2SeamTests.w1Document, W3SeamTests.w2Document] }

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

    static func decoded() throws -> [PhotoDocument] {
        try json.map { try decoder().decode(PhotoDocument.self, from: Data($0.utf8)) }
    }

    /// v1-only documents: a photo with texts, shapes, a fill, an adjustment layer and an image layer; a table fill of
    /// 12 cells; a locked text-behind Subject layer.
    static func built() -> [PhotoDocument] {
        let asset = MediaAsset(id: W3Documents.id(900), kind: .image, relativePath: "media/v1.heic", pixelSize: PSSize(width: 3000, height: 2000))
        var plain = PhotoDocument(title: "v1", baseImage: asset)
        plain.id = W3Documents.id(901)
        plain.layers[0].id = W3Documents.id(902)
        plain.layers += [
            Layer(id: W3Documents.id(903), name: "Titre", content: .text(TextElement(text: "Titre", center: PSPoint(x: 0.3, y: 0.2)))),
            Layer(id: W3Documents.id(904), name: "Forme", content: .shape(ShapeElement(kind: .ellipse)), opacity: 0.7, blendMode: .screen),
            Layer(id: W3Documents.id(905), name: "Voile", content: .fill(.black), opacity: 0.2, isVisible: false),
            Layer(id: W3Documents.id(906), name: "Réglage", content: .adjustment(Adjustments([.exposure: 0.2]))),
            Layer(id: W3Documents.id(907), name: "Logo", content: .image(MediaAsset(id: W3Documents.id(908), kind: .image, relativePath: "media/logo.png",
                                                                                    pixelSize: PSSize(width: 600, height: 300))),
                  transform: LayerTransform(center: PSPoint(x: 0.8, y: 0.8), scale: 0.4, rotation: 10)),
        ]
        plain.selectedLayerID = W3Documents.id(902)
        var table = PhotoDocument(title: "table", baseImage: asset)
        table.id = W3Documents.id(910)
        table.layers[0].id = W3Documents.id(911)
        let bundle = W3Documents.id(912)
        for cell in 0..<12 {
            table.layers.append(Layer(id: W3Documents.id(920 + cell), name: "\(cell)", content: .text(TextElement(text: "\(cell)")),
                                      group: LayerGroup(id: bundle, kind: .tableCells, row: cell / 3 + 1, column: cell % 3 + 1)))
        }
        table.selectedLayerID = W3Documents.id(911)
        var subject = PhotoDocument(title: "subject", baseImage: asset)
        subject.id = W3Documents.id(950)
        subject.layers[0].id = W3Documents.id(951)
        subject.layers += [
            Layer(id: W3Documents.id(952), name: "PARIS", content: .text(TextElement(text: "PARIS"))),
            Layer(id: W3Documents.id(953), name: PhotoDocument.subjectLayerName, content: .image(asset), isLocked: true),
        ]
        subject.selectedLayerID = W3Documents.id(952)
        return [plain, table, subject].map { document in
            var fixed = document
            fixed.createdAt = Date(timeIntervalSince1970: 1_790_000_000)
            fixed.modifiedAt = Date(timeIntervalSince1970: 1_790_000_000)
            fixed.formatVersion = 1
            return fixed
        }
    }
}
