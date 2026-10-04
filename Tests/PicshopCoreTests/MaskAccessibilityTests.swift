import XCTest
@testable import PicshopCore

/// Mask names and VoiceOver labels (W2, M3), and the control inventory every Masques and Sélection control is
/// listed in (its shape; M4's PanelInventoryTests checks it against the catalog).
final class MaskAccessibilityTests: XCTestCase {
    private func sky(_ dials: [AdjustmentParameter: Double], visible: Bool = true) -> LocalAdjustment {
        var adjustments = Adjustments.neutral
        for (parameter, value) in dials { adjustments[parameter] = value }
        return LocalAdjustment(region: .sky, stack: MaskStack(), adjustments: adjustments, isVisible: visible)
    }

    // MARK: VoiceOver

    func testTheContractLabelInFrenchAndEnglish() {
        let adjustment = sky([.exposure: 0.3])
        XCTAssertEqual(MaskAccessibility.label(for: adjustment, language: .fr), "Ciel, masque, visible, exposition plus 0,3")
        XCTAssertEqual(MaskAccessibility.label(for: adjustment, language: .en), "Sky, mask, visible, exposure plus 0.3")
    }

    func testTheFirstTwoDialsInThePanelsOrder() {
        let adjustment = sky([.saturation: 0.1, .contrast: -0.25, .exposure: 0.3])
        XCTAssertEqual(MaskAccessibility.label(for: adjustment, language: .fr), "Ciel, masque, visible, exposition plus 0,3, contraste moins 0,25")
        XCTAssertEqual(MaskAccessibility.label(for: adjustment, language: .en), "Sky, mask, visible, exposure plus 0.3, contrast minus 0.25")
    }

    func testHiddenAmountAndNoDial() {
        var adjustment = sky([:], visible: false)
        XCTAssertEqual(MaskAccessibility.label(for: adjustment, language: .fr), "Ciel, masque, caché, aucun réglage")
        adjustment.curve = ToneCurve(rgb: [ToneCurve.Point(0, 0.1), ToneCurve.Point(1, 1)])
        adjustment.amount = 0.5
        XCTAssertEqual(MaskAccessibility.label(for: adjustment, language: .en), "Sky, mask, hidden, curve, amount 50%")
        XCTAssertEqual(MaskAccessibility.label(for: adjustment, language: .fr), "Ciel, masque, caché, courbe, quantité 50 %")
    }

    func testNumbers() {
        XCTAssertEqual(MaskAccessibility.number(0.3, language: .fr), "0,3")
        XCTAssertEqual(MaskAccessibility.number(0.25, language: .fr), "0,25")
        XCTAssertEqual(MaskAccessibility.number(0.05, language: .en), "0.05")
        XCTAssertEqual(MaskAccessibility.number(1, language: .fr), "1")
        XCTAssertEqual(MaskAccessibility.number(-0.3, language: .en), "-0.3")
        XCTAssertEqual(MaskAccessibility.number(-1.25, language: .fr), "-1,25")
        XCTAssertEqual(MaskAccessibility.number(.nan, language: .fr), "0")
    }

    // MARK: Names

    func testNamesFromRegionsLabelsAndComponents() {
        func name(_ region: MaskRegion?, _ label: String? = nil, components: [MaskComponent] = [], named: String? = nil) -> (String, String) {
            let adjustment = LocalAdjustment(name: named, region: region, label: label, stack: MaskStack(components: components))
            return (MaskAccessibility.displayName(for: adjustment, language: .fr), MaskAccessibility.displayName(for: adjustment, language: .en))
        }
        XCTAssertTrue(name(.sky) == ("Ciel", "Sky"))
        XCTAssertTrue(name(.bottom) == ("Bas", "Bottom"))
        XCTAssertTrue(name(.subject) == ("Sujet", "Subject"))
        XCTAssertTrue(name(.person, "2") == ("Personne 2", "Person 2"))
        XCTAssertTrue(name(.object, "cup") == ("Tasse", "Cup"))
        XCTAssertTrue(name(.object, "teapot") == ("Teapot", "Teapot"))
        XCTAssertTrue(name(.teeth, "teeth:2") == ("Dents (2)", "Teeth (2)"))
        XCTAssertTrue(name(.teeth) == ("Dents", "Teeth"))
        XCTAssertTrue(name(.selection) == ("Sélection", "Selection"))
        XCTAssertTrue(name(nil, components: [MaskComponent(.brush(BrushSpec()))]) == ("Pinceau", "Brush"))
        XCTAssertTrue(name(nil, components: [MaskComponent(.linear(LinearGradientSpec(start: .zero, end: PSPoint(x: 0, y: 1))))]) == ("Dégradé linéaire", "Linear gradient"))
        XCTAssertTrue(name(nil) == ("Masque", "Mask"))
        // The person's own name wins, trimmed; blank is no name.
        XCTAssertTrue(name(.sky, named: "  Mon ciel ") == ("Mon ciel", "Mon ciel"))
        XCTAssertTrue(name(.sky, named: "   ") == ("Ciel", "Sky"))
    }

    func testRasterComponentNamesFollowTheirOrigin() {
        let teeth = RasterRef(path: "masks/a.png", origin: .facePart, pixelWidth: 10, pixelHeight: 10, label: "teeth:2")
        XCTAssertEqual(MaskAccessibility.componentName(.raster(teeth), language: .fr), "Dents (2)")
        let hair = RasterRef(path: "masks/b.png", origin: .matte, pixelWidth: 10, pixelHeight: 10, label: "hair")
        XCTAssertEqual(MaskAccessibility.componentName(.raster(hair), language: .fr), "Cheveux")
        let cup = RasterRef(path: "masks/c.png", origin: .object, pixelWidth: 10, pixelHeight: 10, label: "cup")
        XCTAssertEqual(MaskAccessibility.componentName(.raster(cup), language: .fr), "Tasse")
        XCTAssertEqual(MaskAccessibility.componentName(.unsupported("{}"), language: .en), "Item from a newer version")
    }

    func testRepeatedNamesAreNumbered() {
        let names = MaskAccessibility.displayNames(for: [sky([:]), LocalAdjustment(region: .bottom, stack: MaskStack()), sky([:]), sky([:])], language: .fr)
        XCTAssertEqual(names, ["Ciel", "Bas", "Ciel 2", "Ciel 3"])
    }

    func testDialOrderIsThePanelsWithoutVignette() {
        XCTAssertEqual(Set(MaskAccessibility.dialOrder), Set(AdjustmentParameter.allCases).subtracting([.vignette]))
        XCTAssertEqual(MaskAccessibility.dialOrder.count, 18)
        XCTAssertEqual(MaskAccessibility.dialOrder.first, .exposure)
    }

    // MARK: The control inventory (shape only)

    func testInventoryIdsAreUniqueAndWellFormed() {
        let controls = MaskPanelInventory.controls
        XCTAssertGreaterThan(controls.count, 150)
        XCTAssertEqual(Set(controls.map(\.id)).count, controls.count, "duplicate ids")
        let ops: Set<String> = ["maskAdjust", "maskEdit", "maskDelete", "select", "selectionModify", "selectionApply"]
        for control in controls {
            XCTAssertTrue(control.uiTool == "masks" || control.uiTool == "select", control.id)
            XCTAssertTrue(control.id.hasPrefix(control.uiTool + "."), control.id)
            switch control.reach {
            case .operation:
                XCTAssertNotNil(control.op, control.id)
                XCTAssertNotNil(control.param, control.id)
                XCTAssertTrue(ops.contains(control.op?.raw ?? ""), control.id)
            case .gestureOnly:
                XCTAssertNotNil(control.op, control.id)
                XCTAssertNil(control.param, control.id)
            case .viewOnly:
                XCTAssertNil(control.op, control.id)
                XCTAssertTrue(control.id.contains(".overlay.") || control.id.contains(".preview.") || control.id.contains(".view."), control.id)
            }
            XCTAssertEqual(MaskPanelInventory.control(control.id), control)
        }
        XCTAssertNil(MaskPanelInventory.control("masks.nothing"))
    }

    func testInventoryValuesAreTheCatalogsEnumerations() {
        let regions = Set(MaskRegion.allCases.map(\.rawValue))
        for control in MaskPanelInventory.controls {
            guard let key = control.paramKey, let value = control.paramValue else { continue }
            switch key {
            case "where": XCTAssertTrue(regions.contains(value), control.id)
            case "what": XCTAssertTrue(regions.contains(value) || value == "all" || value == "wand", control.id)
            case "parameter":
                XCTAssertNotNil(AdjustmentParameter(rawValue: value), control.id)
                XCTAssertNotEqual(value, "vignette", control.id)
            case "combine", "componentMode": XCTAssertNotNil(CombineMode(rawValue: value), control.id)
            case "mode": XCTAssertTrue(["new", "add", "subtract", "intersect"].contains(value), control.id)
            case "use": XCTAssertTrue(["adjust", "mask", "erase", "fill", "recolor", "blur", "cutout", "generate"].contains(value), control.id)
            case "curve": XCTAssertNotNil(ToneCurve.Preset(rawValue: value), control.id)
            case "band": XCTAssertTrue(ColorMixer.Band.allCases.map { $0.englishName.lowercased() }.contains(value), control.id)
            default: XCTFail("unexpected enumeration parameter \(key) in \(control.id)")
            }
        }
    }

    func testEveryMaskSourceAndSelectionUseIsListed() {
        for source in MaskPanelInventory.maskSources {
            XCTAssertEqual(MaskPanelInventory.control("masks.new.\(source.id)")?.param, "where=\(source.region.rawValue)")
            XCTAssertNotNil(MaskPanelInventory.control("masks.component.source.\(source.id)"))
        }
        for use in MaskPanelInventory.selectionUses {
            XCTAssertEqual(MaskPanelInventory.control("select.use.\(use)")?.param, "use=\(use)")
        }
        for parameter in MaskAccessibility.dialOrder {
            XCTAssertEqual(MaskPanelInventory.control("masks.dial.\(parameter.rawValue)")?.op, "maskAdjust")
        }
        // The overlay menu is every MaskOverlayStyle plus « Aucune »; the brush is reached by gesture.
        XCTAssertEqual(MaskPanelInventory.overlayStyles.count, 7)
        XCTAssertEqual(MaskPanelInventory.control("masks.brush.paint")?.reach, .gestureOnly)
        XCTAssertEqual(MaskPanelInventory.control("masks.overlay.rubylith")?.reach, .viewOnly)
        XCTAssertEqual(MaskPanelInventory.control("masks.range.low")?.param, "low")
        XCTAssertEqual(MaskPanelInventory.control("select.use.generate")?.op, "selectionApply")
    }
}
