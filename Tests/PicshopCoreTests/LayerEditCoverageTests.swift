import XCTest
@testable import PicshopCore

/// W3 (§8.7, I1): every layer edit and structure edit the UI can trigger has a catalog operation and parameter that
/// reach it by voice or a model. The switches are exhaustive: a new case without an operation does not compile.
final class LayerEditCoverageTests: XCTestCase {
    /// The operation and parameter that reach a layer edit; nil parameter: the operation itself.
    static func reach(_ edit: LayerEdit) -> (op: OpID, param: String?) {
        switch edit {
        case .opacity: return ("layerOpacity", "opacity")
        case .fillOpacity: return ("layerProperties", "fill")
        case .blendMode: return ("layerBlend", "mode")
        case .visible: return ("layerVisibility", "visible")
        case .lock, .lockAll: return ("layerProperties", "lock")
        case .clipped: return ("layerClip", "clip")
        case .rename: return ("layerProperties", "name")
        case .transform: return ("layerTransform", "scale")
        case .maskStack: return ("layerMask", "do")
        case .maskEdit: return ("layerMask", "feather")
        case .maskEnabled: return ("layerMask", "do")
        case .maskLinked: return ("layerProperties", "maskLinked")
        case .solidFill: return ("fillLayer", "color")
        case .gradient: return ("fillLayer", "style")
        case .adjustments: return ("adjust", "layer")
        case .folder: return ("groupLayers", "collapse")
        case .recipeKind: return ("addAdjustmentLayer", "kind")
        }
    }

    static func reach(_ edit: LayerStructureEdit) -> (op: OpID, param: String?) {
        switch edit {
        case .add: return ("addFillLayer", "fill")
        case .remove: return ("deleteLayer", "ref")
        case .duplicate: return ("duplicateLayer", "ref")
        case .move: return ("layerOrder", nil)
        case .group: return ("groupLayers", "refs")
        case .ungroup: return ("groupLayers", "ungroup")
        case .viaCopy, .viaCut: return ("layerVia", "mode")
        case .mergeDown, .mergeVisible, .flatten, .stamp, .mergeLayers: return ("mergeLayers", "mode")
        case .addImage: return ("addImageLayer", nil)
        case .applyMask: return ("layerMask", "do")
        }
    }

    static let asset = MediaAsset(kind: .image, relativePath: "media/x.png", pixelSize: PSSize(width: 10, height: 10))

    /// One value of every case (the switches above are what keep this list honest).
    static let edits: [LayerEdit] = [
        .opacity(0.5), .fillOpacity(0.5), .blendMode(.multiply), .visible(false), .lock([.position]), .lockAll(true), .clipped(true), .rename("A"),
        .transform(.identity), .maskStack(nil), .maskEdit(.setStack(feather: 0.2, expand: nil, density: nil, isInverted: nil)), .maskEnabled(false),
        .maskLinked(false), .solidFill(.white), .gradient(.blackToTransparent), .adjustments(.neutral), .folder(LayerFolder()), .recipeKind(.curves),
    ]

    static let structureEdits: [LayerStructureEdit] = [
        .add(Layer(name: "A", content: .fill(.white)), placement: .top), .remove(UUID()), .duplicate(UUID()), .move(UUID(), to: .top),
        .group([UUID()], name: nil), .ungroup(UUID()), .viaCopy(source: UUID(), region: MaskStack(), name: nil),
        .viaCut(source: UUID(), region: MaskStack(), name: nil), .mergeDown(UUID(), raster: asset), .mergeVisible(raster: asset), .flatten(raster: asset),
        .stamp(raster: asset, name: "S"), .addImage(asset, name: "I", fit: .fit, placement: .top), .applyMask(UUID(), raster: asset),
        .mergeLayers([UUID()], raster: asset),
    ]

    func testEveryLayerEditHasAnOperationAndParameter() throws {
        let catalog = OperationCatalog.shared
        for edit in Self.edits {
            let (op, param) = Self.reach(edit)
            let spec = try XCTUnwrap(catalog.spec(op), "\(edit) → \(op)")
            XCTAssertTrue(spec.domains.contains(.photo), "\(op)")
            if let param { XCTAssertTrue(spec.params.contains { $0.key == param }, "\(edit) → \(op).\(param)") }
        }
    }

    func testEveryStructureEditHasAnOperation() throws {
        let catalog = OperationCatalog.shared
        for edit in Self.structureEdits {
            let (op, param) = Self.reach(edit)
            let spec = try XCTUnwrap(catalog.spec(op), "\(edit) → \(op)")
            if let param { XCTAssertTrue(spec.params.contains { $0.key == param }, "\(op).\(param)") }
        }
    }

    /// The merge modes and the mask actions each have a value the operation accepts.
    func testMergeModesAndMaskActionsAreValues() throws {
        let merge = try XCTUnwrap(OperationCatalog.shared.spec("mergeLayers")?.params.first { $0.key == "mode" })
        guard case .enumeration(let modes) = merge.kind else { return XCTFail() }
        XCTAssertEqual(Set(modes), ["down", "visible", "flatten", "stamp", "selected"])
        let mask = try XCTUnwrap(OperationCatalog.shared.spec("layerMask")?.params.first { $0.key == "do" })
        guard case .enumeration(let actions) = mask.kind else { return XCTFail() }
        XCTAssertEqual(Set(actions), ["add", "edit", "invert", "enable", "disable", "delete", "apply", "paint"])
    }
}
