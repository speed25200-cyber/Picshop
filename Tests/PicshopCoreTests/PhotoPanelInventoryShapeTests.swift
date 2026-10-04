import XCTest
@testable import PicshopCore

/// The shape of PhotoPanelInventory (W3 §7.11): every control of every photo tool but Masques and Sélection, once,
/// on a known tool, with an operation when the voice reaches it. L4's PanelInventoryTests checks every operation
/// control against the catalog (op, param and value) and every gesture control against the grammar.
final class PhotoPanelInventoryShapeTests: XCTestCase {
    /// PhotoEditorSession.Tool's raw values but masks and select (MaskPanelInventory), plus the export sheet and the
    /// canvas.
    static let tools: Set<String> = ["magic", "focus", "adjust", "looks", "color", "erase", "precise", "cutout", "crop", "text", "shapes",
                                     "layers", "curves", "levels", "export", "canvas"]

    /// The operations W3 adds (L4, §8.1): until the catalog has them, a control may name them.
    static let w3Operations: Set<String> = ["addImageLayer", "layerVia", "addFillLayer", "fillLayer", "addAdjustmentLayer", "layerMask", "layerClip",
                                            "groupLayers", "mergeLayers", "layerTransform", "layerProperties", "recipe", "exportPhoto"]

    func testIDsAreUniqueAndDistinctFromTheMaskInventory() {
        let ids = PhotoPanelInventory.controls.map(\.id)
        let repeated = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        XCTAssertEqual(repeated, [])
        let maskIDs = Set(MaskPanelInventory.controls.map(\.id))
        XCTAssertTrue(maskIDs.isDisjoint(with: ids))
        XCTAssertGreaterThan(ids.count, 250)
        for id in ids {
            XCTAssertEqual(PhotoPanelInventory.control(id)?.id, id)
        }
        XCTAssertNil(PhotoPanelInventory.control("layers.nothing"))
    }

    func testEveryToolIsAPhotoToolTheExportSheetOrTheCanvas() {
        for control in PhotoPanelInventory.controls {
            XCTAssertTrue(Self.tools.contains(control.uiTool), "\(control.id): \(control.uiTool)")
            XCTAssertTrue(control.id.hasPrefix(control.uiTool + "."), control.id)
        }
        // Every tool of the inventory's scope has at least one control.
        XCTAssertEqual(Set(PhotoPanelInventory.controls.map(\.uiTool)), Self.tools)
    }

    func testOperationControlsNameAnOperationAndViewsNone() {
        let catalog = OperationCatalog.shared
        for control in PhotoPanelInventory.controls {
            switch control.reach {
            case .operation:
                guard let op = control.op else { XCTFail("\(control.id) has no operation"); continue }
                XCTAssertTrue(catalog.spec(op) != nil || Self.w3Operations.contains(op.raw), "\(control.id): unknown operation \(op.raw)")
            case .viewOnly:
                XCTAssertNil(control.op, control.id)
                XCTAssertNil(control.param, control.id)
            case .gestureOnly:
                if let op = control.op {
                    XCTAssertTrue(catalog.spec(op) != nil || Self.w3Operations.contains(op.raw), "\(control.id): unknown operation \(op.raw)")
                }
            }
        }
    }

    /// Where the catalog already has the operation and the parameter, an enumeration or boolean value is one it
    /// accepts (the full check, with the W3 operations, is L4's PanelInventoryTests).
    func testValuesTheCatalogAlreadyKnowsAreValid() {
        let catalog = OperationCatalog.shared
        var problems: [String] = []
        for control in PhotoPanelInventory.controls where control.reach == .operation {
            guard let op = control.op, let spec = catalog.spec(op), let key = control.paramKey,
                  let param = spec.params.first(where: { $0.key == key }), let value = control.paramValue else { continue }
            switch param.kind {
            case .enumeration(let values):
                if !values.contains(value) { problems.append("\(control.id): \(op.raw).\(key) has no value \(value)") }
            case .boolean:
                if !["true", "false"].contains(value) { problems.append("\(control.id): \(value) is not a boolean") }
            default:
                break
            }
        }
        XCTAssertEqual(problems, [])
    }

    func testTheSharedListsCoverTheirEnums() {
        XCTAssertEqual(Set(PhotoPanelInventory.exportFormats), Set(ExportFileFormat.allCases))
        XCTAssertEqual(Set(PhotoPanelInventory.transformModes.map(\.mode)), Set(TransformMode.allCases))
        XCTAssertEqual(PhotoPanelInventory.lockChoices.map(\.value), ["none", "position", "pixels", "transparency", "all"])
        XCTAssertEqual(Set(PhotoPanelInventory.photoRecipes.map { RecipeBook.domain(of: $0) }), [.photo])
        let ids = Set(PhotoPanelInventory.controls.map(\.id))
        for kind in AdjustmentLayerKind.allCases { XCTAssertTrue(ids.contains("layers.add.adjustment.\(kind.rawValue)"), kind.rawValue) }
        for alignment in LayerAlignment.allCases { XCTAssertTrue(ids.contains("layers.align.\(alignment.rawValue)"), alignment.rawValue) }
        for mode in BlendMode.allCases { XCTAssertTrue(ids.contains("layers.props.blend.\(mode.rawValue)"), mode.rawValue) }
        for style in GradientFill.Style.allCases { XCTAssertTrue(ids.contains("layers.fill.style.\(style.rawValue)"), style.rawValue) }
        for format in ExportFileFormat.allCases { XCTAssertTrue(ids.contains("export.format.\(format.rawValue)"), format.rawValue) }
        // The contract's examples (§7.11).
        for id in ["layers.add.fill.gradient", "layers.row.opacity", "layers.transform.handles", "layers.column.reorder", "layers.mask.paint",
                   "export.format.psd", "layers.guides.show", "layers.fill.angle", "layers.select.many", "layers.align.left", "canvas.layer.pick",
                   "canvas.layer.drag", "canvas.transparency", "magic.recipe.instagram"] {
            XCTAssertNotNil(PhotoPanelInventory.control(id), id)
        }
        XCTAssertEqual(PhotoPanelInventory.control("layers.transform.handles")?.reach, .gestureOnly)
        XCTAssertEqual(PhotoPanelInventory.control("layers.guides.show")?.reach, .viewOnly)
        XCTAssertEqual(PhotoPanelInventory.control("layers.add.fill.gradient")?.param, "fill=gradient")
        XCTAssertEqual(PhotoPanelInventory.control("export.format.psd")?.op, "exportPhoto")
    }

    /// The adjustment-layer and fill-layer panels name edit operations, never creation ones (a slider tick must never
    /// add a layer, D18).
    func testLayerPanelsNameEditOperations() {
        for control in PhotoPanelInventory.controls where control.id.hasPrefix("layers.adjustment.") || control.id.hasPrefix("layers.fill.") {
            guard let op = control.op else { continue }
            XCTAssertFalse(InspectorModel.creationOps.contains(op.raw), control.id)
        }
    }

    func testLockValues() {
        XCTAssertEqual(PhotoPanelInventory.lockValue([]), "none")
        XCTAssertEqual(PhotoPanelInventory.lockValue(.all), "all")
        XCTAssertEqual(PhotoPanelInventory.lockValue([.position]), "position")
        XCTAssertEqual(PhotoPanelInventory.lockValue([.transparency]), "transparency")
        XCTAssertEqual(PhotoPanelInventory.lockValue([.pixels, .position]), "pixels")
        for choice in PhotoPanelInventory.lockChoices {
            XCTAssertEqual(PhotoPanelInventory.lockValue(choice.lock), choice.value)
        }
    }
}
