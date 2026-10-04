import XCTest
@testable import PicshopCore

/// D18: inspector rows from ParamSpec: the layer ops' rows (the W3 specs written here with the contract's params, as
/// L4's catalog gives them), adjust expanded per parameter (18 rows, no vignette, AdjustPanel order), no rows for the
/// creation ops, the control of every kind, the bespoke overrides, the formats and the track fractions.
final class InspectorModelTests: XCTestCase {
    private let layerRefs: Set<RefKind> = [.textLayer, .shape, .imageLayer, .adjustmentLayer]

    private func spec(_ id: OpID, _ params: [ParamSpec]) -> OperationSpec {
        op(id, .handler, in: [.photo], .layers, .composition, title: t(id.raw, id.raw), summary: t("", "")) { $0.params = params }
    }

    private var layerProperties: OperationSpec {
        spec("layerProperties", [
            percent("fill", doc: "fill opacity"),
            enumParam("lock", ["all", "position", "pixels", "transparency", "none"], doc: "lock"),
            text("name", max: 40, doc: "name"),
            boolean("passThrough", doc: "pass-through").offCard,
            boolean("maskLinked", doc: "mask linked").offCard,
            ref("ref", layerRefs, doc: "layer"),
        ])
    }

    private var fillLayer: OperationSpec {
        spec("fillLayer", [
            ref("ref", [.adjustmentLayer], doc: "fill layer"),
            Step.color(doc: "colour"),
            ParamSpec("color2", .color, doc: "second colour"),
            ParamSpec("stops", .list(.text(maxLength: 20), max: 8), doc: "colour@location").offCard,
            enumParam("style", ["linear", "radial", "reflected"], doc: "style"),
            number("angle", -180...180, .degrees, doc: "angle"),
            percent("scale", 10...150, doc: "scale"),
            ParamSpec("center", .point, doc: "centre").offCard,
            boolean("reverse", doc: "reverse"),
            boolean("dither", doc: "dither").offCard,
        ])
    }

    private var layerTransform: OperationSpec {
        spec("layerTransform", [
            ref("ref", layerRefs, doc: "layer"),
            ParamSpec("refs", .list(.ref(layerRefs), max: 16), doc: "layers").offCard,
            ParamSpec("center", .point, doc: "centre").offCard,
            number("x", 0...1000, .none, doc: "x").offCard,
            number("y", 0...1000, .none, doc: "y").offCard,
            number("dx", -1000...1000, .none, doc: "dx").offCard,
            number("dy", -1000...1000, .none, doc: "dy").offCard,
            percent("scale", 1...1000, doc: "scale"),
            percent("scaleBy", 10...1000, doc: "scale by").offCard,
            percent("scaleX", 1...1000, doc: "scale x").offCard,
            percent("scaleY", 1...1000, doc: "scale y").offCard,
            number("rotation", -360...360, .degrees, doc: "rotation"),
            boolean("relative", doc: "relative").offCard,
            number("skewX", -60...60, .degrees, doc: "skew x").offCard,
            number("skewY", -60...60, .degrees, doc: "skew y").offCard,
            ParamSpec("corners", .list(.point, max: 4), doc: "corners").offCard,
            enumParam("mode", ["free", "skew", "distort", "perspective"], doc: "mode").offCard,
            enumParam("flip", ["horizontal", "vertical"], doc: "flip").offCard,
            enumParam("fit", ["fit", "fill", "reset"], doc: "fit").offCard,
            enumParam("align", ["left", "centerH", "right", "top", "centerV", "bottom", "center", "distributeH", "distributeV"], doc: "align").offCard,
        ])
    }

    private func kinds(_ rows: [InspectorRowModel]) -> [String] {
        rows.map { row in
            switch row.control {
            case .slider: return "\(row.param):slider"
            case .stepper: return "\(row.param):stepper"
            case .segmented: return "\(row.param):segmented"
            case .menu: return "\(row.param):menu"
            case .toggle: return "\(row.param):toggle"
            case .color: return "\(row.param):color"
            case .custom(let id): return "\(row.param):\(id)"
            }
        }
    }

    func testTheLayerOpsRows() throws {
        let opacity = try XCTUnwrap(OperationCatalog.shared.spec("layerOpacity"))
        let rows = InspectorModel.rows(for: opacity)
        XCTAssertEqual(kinds(rows), ["opacity:slider"])
        XCTAssertEqual(rows.first?.id, "layerOpacity.opacity")
        XCTAssertEqual(rows.first?.control, .slider(range: 0...100, step: 1, neutral: 0, unit: .percent))

        XCTAssertEqual(kinds(InspectorModel.rows(for: layerProperties)), ["fill:slider", "lock:menu", "passThrough:toggle", "maskLinked:toggle"])
        XCTAssertEqual(kinds(InspectorModel.rows(for: fillLayer)),
                       ["color:color", "color2:color", "stops:gradientStops", "style:segmented", "angle:slider", "scale:slider", "reverse:toggle",
                        "dither:toggle"])
        XCTAssertEqual(kinds(InspectorModel.rows(for: layerTransform)),
                       ["x:slider", "y:slider", "dx:slider", "dy:slider", "scale:slider", "scaleBy:slider", "scaleX:slider", "scaleY:slider",
                        "rotation:slider", "relative:toggle", "skewX:slider", "skewY:slider", "corners:transformQuad", "mode:segmented",
                        "flip:segmented", "fit:segmented", "align:menu"])
        // Excluded keys and `inspector: false` params give none.
        XCTAssertEqual(kinds(InspectorModel.rows(for: layerTransform, excluding: ["x", "y", "dx", "dy", "corners"])).count, 12)
        var hidden = layerProperties
        hidden.params[0].inspector = false
        XCTAssertFalse(kinds(InspectorModel.rows(for: hidden)).contains("fill:slider"))
    }

    func testAdjustExpandsToEighteenRowsInAdjustPanelOrder() throws {
        let adjust = try XCTUnwrap(OperationCatalog.shared.spec("adjust"))
        let rows = InspectorModel.rows(for: adjust, expanding: "parameter")
        XCTAssertEqual(rows.count, 18)
        let order = rows.compactMap { $0.fixedArgs["parameter"]?.string }
        XCTAssertEqual(order, InspectorModel.adjustOrder.filter { $0 != .vignette }.map(\.rawValue))
        XCTAssertFalse(order.contains(AdjustmentParameter.vignette.rawValue))
        XCTAssertTrue(rows.allSatisfy { $0.param == "amount" && $0.fixedArgs["amountMode"] == .string("absolute") })
        XCTAssertEqual(rows.first?.id, "adjust.amount=exposure")
        XCTAssertEqual(rows.first?.label.fr, AdjustmentParameter.exposure.frenchName)
        XCTAssertEqual(rows.first?.group?.fr, "Lumière")
        XCTAssertEqual(rows.first { $0.fixedArgs["parameter"] == .string("saturation") }?.group?.fr, "Couleur")
        XCTAssertEqual(rows.first { $0.fixedArgs["parameter"] == .string("clarity") }?.group?.fr, "Détail")
        XCTAssertEqual(rows.first?.control, .slider(range: -100...100, step: 1, neutral: 0, unit: .signedPercent))
        // Unexpanded, adjust gives its enumeration as a menu and the amount as a slider.
        XCTAssertEqual(kinds(InspectorModel.rows(for: adjust)), ["parameter:menu", "amount:slider", "amountMode:segmented"])
    }

    func testCreationOpsGiveNoRows() {
        let addFill = spec("addFillLayer", [enumParam("fill", ["solid", "gradient"], .required, doc: "fill"), Step.color(doc: "colour"),
                                            percent("opacity", doc: "opacity")])
        let addAdjustment = spec("addAdjustmentLayer", [enumParam("kind", AdjustmentLayerKind.self, .required, doc: "kind"),
                                                        signedPercent("amount", doc: "amount")])
        XCTAssertEqual(InspectorModel.rows(for: addFill), [])
        XCTAssertEqual(InspectorModel.rows(for: addAdjustment), [])
        XCTAssertEqual(InspectorModel.rows(for: addAdjustment, expanding: "kind"), [])
        for id in ["addImageLayer", "layerVia", "mergeLayers", "groupLayers", "duplicateLayer", "deleteLayer", "recipe", "exportPhoto"] {
            XCTAssertEqual(InspectorModel.rows(for: spec(OpID(id), [percent("amount", doc: "x")])), [], id)
        }
    }

    func testControlsPerKindAndOverrides() {
        let mixed = spec("mixed", [
            integer("count", 1...9, doc: "count"),
            number("speed", 0.25...4, .multiplier, doc: "speed"),
            number("amount", 0...1, .fraction, doc: "amount"),
            number("time", 0...10, .seconds, doc: "time"),
            ParamSpec("points", .list(.point, max: 16), doc: "curve points"),
            ParamSpec("quad", .list(.point, max: 4), doc: "quad"),
            ParamSpec("box", .box, doc: "crop"),
            ParamSpec("where", .point, doc: "a point"),
            text("label", max: 20, doc: "label"),
            ref("ref", layerRefs, doc: "layer"),
            enumParam("two", ["a", "b"], doc: "two"),
            enumParam("five", ["a", "b", "c", "d", "e"], doc: "five"),
        ])
        let rows = InspectorModel.rows(for: mixed)
        XCTAssertEqual(kinds(rows), ["count:stepper", "speed:slider", "amount:slider", "time:slider", "points:curves", "quad:transformQuad",
                                     "box:crop", "two:segmented", "five:menu"])
        XCTAssertEqual(rows[0].control, .stepper(range: 1...9))
        XCTAssertEqual(rows[1].control, .slider(range: 0.25...4, step: 0.05, neutral: 1, unit: .multiplier))
        XCTAssertEqual(rows[2].control, .slider(range: 0...1, step: 0.01, neutral: 0.5, unit: .fraction))
        XCTAssertEqual(rows[3].control, .slider(range: 0...10, step: 0.1, neutral: 0, unit: .seconds))
        // colorGrade's colour and hue share one wheels control.
        let grade = spec("colorGrade", [Step.color(doc: "colour"), number("hue", 0...360, .degrees, doc: "hue"), signedPercent("amount", doc: "amount")])
        XCTAssertEqual(kinds(InspectorModel.rows(for: grade)), ["color:colorWheels", "amount:slider"])
        // A label from the spec wins; else an enum value's French name; else the key.
        var labelled = layerProperties
        labelled.params[0].label = Bilingual(en: "Fill", fr: "Fond")
        XCTAssertEqual(InspectorModel.rows(for: labelled).first?.label.fr, "Fond")
        XCTAssertEqual(InspectorModel.rows(for: layerProperties).first?.label.fr, "fill")
        XCTAssertEqual(InspectorModel.optionLabel("multiply").fr, BlendMode.multiply.frenchName)
        XCTAssertEqual(InspectorModel.optionLabel("reflected").fr, "Reflété")
    }

    private func slider(_ range: ClosedRange<Double>, _ unit: OpUnit) -> InspectorRowModel {
        InspectorRowModel(id: "x.v", op: "x", param: "v", label: t("v", "v"),
                          control: .slider(range: range, step: 1, neutral: InspectorModel.neutral(for: unit, range: range), unit: unit))
    }

    func testFormats() {
        XCTAssertEqual(InspectorModel.format(.number(0.35), row: slider(-1...1, .none), language: .fr), "+0,35")
        XCTAssertEqual(InspectorModel.format(.number(0.35), row: slider(-1...1, .none), language: .en), "+0.35")
        XCTAssertEqual(InspectorModel.format(.number(50), row: slider(0...100, .percent), language: .fr), "50 %")
        XCTAssertEqual(InspectorModel.format(.number(-12), row: slider(-180...180, .degrees), language: .fr), "\u{2212}12°")
        XCTAssertEqual(InspectorModel.format(.number(12.5), row: slider(-180...180, .degrees), language: .fr), "12,5°")
        XCTAssertEqual(InspectorModel.format(.number(20), row: slider(-100...100, .signedPercent), language: .fr), "+20 %")
        XCTAssertEqual(InspectorModel.format(.number(-20), row: slider(-100...100, .signedPercent), language: .fr), "\u{2212}20 %")
        XCTAssertEqual(InspectorModel.format(.number(0), row: slider(-100...100, .signedPercent), language: .fr), "0 %")
        XCTAssertEqual(InspectorModel.format(.number(1.5), row: slider(0.25...4, .multiplier), language: .fr), "×1,5")
        XCTAssertEqual(InspectorModel.format(.number(2.25), row: slider(0...10, .seconds), language: .fr), "2,25 s")
        let options = InspectorRowModel(id: "x.mode", op: "x", param: "mode", label: t("m", "m"),
                                        control: .menu([InspectorOption(value: "multiply", label: InspectorModel.optionLabel("multiply"))]))
        XCTAssertEqual(InspectorModel.format(.string("multiply"), row: options, language: .fr), BlendMode.multiply.frenchName)
        XCTAssertEqual(InspectorModel.format(.string("other"), row: options, language: .fr), "other")
        XCTAssertEqual(InspectorModel.format(.bool(true), row: options, language: .fr), "oui")
        XCTAssertEqual(InspectorModel.format(.bool(false), row: options, language: .en), "off")
        XCTAssertEqual(InspectorModel.format(.number(.nan), row: slider(0...1, .fraction), language: .fr), "–")
    }

    func testFractionsAndNeutrals() {
        var placed = InspectorModel.fraction(50, row: slider(-100...100, .signedPercent))
        XCTAssertEqual(placed.fraction, 0.75, accuracy: 1e-12)
        XCTAssertEqual(placed.neutral, 0.5, accuracy: 1e-12)
        placed = InspectorModel.fraction(25, row: slider(0...100, .percent))
        XCTAssertEqual(placed.fraction, 0.25, accuracy: 1e-12)
        XCTAssertEqual(placed.neutral, 0)
        placed = InspectorModel.fraction(0.2, row: slider(0...1, .fraction))
        XCTAssertEqual(placed.neutral, 0.5, accuracy: 1e-12)
        placed = InspectorModel.fraction(2, row: slider(0.5...4.5, .multiplier))
        XCTAssertEqual(placed.fraction, 0.375, accuracy: 1e-12)
        XCTAssertEqual(placed.neutral, 0.125, accuracy: 1e-12)
        XCTAssertEqual(InspectorModel.fraction(500, row: slider(0...100, .percent)).fraction, 1, "clamped")
        XCTAssertEqual(InspectorModel.fraction(.nan, row: slider(0...100, .percent)).fraction, 0)
        let toggle = InspectorRowModel(id: "x.t", op: "x", param: "t", label: t("t", "t"), control: .toggle)
        XCTAssertEqual(InspectorModel.fraction(1, row: toggle).fraction, 0)
        XCTAssertEqual(InspectorModel.fraction(1, row: toggle).neutral, 0)
    }
}
