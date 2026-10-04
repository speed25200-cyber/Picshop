import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// Generated validation and coercion (OperationArguments), and the catalog invariants that need
/// the validator: I3 (every example validates), I5 (every Live step action has its spec) and the
/// parity of the existing actions' params with ToolInputValidator and the AmountUnit table.
final class OperationArgumentsTests: XCTestCase {
    private let catalog = OperationCatalog.shared

    private func validate(_ id: OpID, _ object: [String: JSONValue], _ domain: OpDomain = .photo) -> (OperationCall?, [String]) {
        var problems: [String] = []
        let call = OperationArguments.validate(id, object, domain: domain, path: "steps[0]", problems: &problems)
        return (call, problems)
    }

    // MARK: Invariants

    /// I3 (W1): every example's arguments, written as the model would, validate in one of the
    /// operation's domains, and come back as the same call.
    func testEveryExampleValidates() {
        var checked = 0
        for spec in catalog.specs {
            for example in spec.examples {
                if case .negative = example.role { continue }
                guard case .object(var object) = OperationArguments.json(OperationCall(spec.id, args: example.args)) else { return XCTFail() }
                object["action"] = nil
                var problems: [String] = []
                var calls: [OperationCall] = []
                for domain in spec.domains.sorted(by: { $0.rawValue < $1.rawValue }) {
                    if let call = OperationArguments.validate(spec.id, object, domain: domain, path: "step", problems: &problems) { calls.append(call) }
                }
                guard let call = calls.first else {
                    XCTFail("\(spec.id): « \(example.say) » \(problems)")
                    continue
                }
                for (key, value) in example.args { XCTAssertEqual(call.args[key], value, "\(spec.id): « \(example.say) » \(key)") }
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 350)
    }

    /// I5: every IntentAction allowed as a Live step in some mode (neither meta nor excluded) has
    /// exactly one spec lowering to it.
    func testEveryLiveStepActionHasOneSpec() {
        var actions: Set<IntentAction> = []
        for mode in [EditorMode.photo, .video, .pdf] { actions.formUnion(LiveToolSchema.allowedActions(for: mode).filter { !$0.isMeta }) }
        XCTAssertGreaterThan(actions.count, 90)
        for action in actions {
            let specs = catalog.specs.filter { $0.lowering == .intent(action) }
            XCTAssertEqual(specs.count, 1, "\(action)")
        }
    }

    /// A spec offers an action only where the validator allows it, and everywhere it allows it but
    /// for the documented gaps (selectiveAdjust is refused in video; seek is a timeline move).
    func testSpecDomainsFollowTheModes() {
        let gaps: Set<String> = ["selectiveAdjust/video", "seek/pdf"]
        for spec in catalog.specs {
            guard case .intent(let action) = spec.lowering else { continue }
            for mode in [EditorMode.photo, .video, .pdf] {
                let allowed = LiveToolSchema.allowedActions(for: mode).contains(action)
                let offered = spec.domains.contains(mode.opDomain)
                if offered { XCTAssertTrue(allowed, "\(action) is offered in \(mode) but the validator refuses it") }
                if allowed, !offered { XCTAssertTrue(gaps.contains("\(action.rawValue)/\(mode.rawValue)"), "\(action) is allowed in \(mode) but not offered") }
            }
        }
    }

    /// The existing actions' params are the apply_edits step fields the validator reads.
    func testStepFieldsMatchTheValidator() {
        XCTAssertEqual(OperationArguments.photoKeys, LiveToolSchema.photoFields)
        XCTAssertEqual(OperationArguments.timelineKeys, LiveToolSchema.videoFields)
        let known = ToolInputValidator.stepKeys.union(LiveToolSchema.photoFields).union(LiveToolSchema.videoFields).union(["replacement"])
        for spec in catalog.specs {
            guard case .intent = spec.lowering else { continue }
            for param in spec.params { XCTAssertTrue(known.contains(param.key), "\(spec.id).\(param.key)") }
        }
    }

    /// The amount ranges mirror AmountUnit (what IntentNormalizer converts).
    func testAmountRangesMirrorTheAmountUnitTable() {
        for spec in catalog.specs {
            guard case .intent(let action) = spec.lowering, let unit = AmountUnit.for(action),
                  let amount = spec.params.first(where: { $0.key == "amount" }) else { continue }
            guard case .number(let range, let declared) = amount.kind else { return XCTFail("\(spec.id).amount") }
            XCTAssertEqual(range, unit.range, "\(spec.id)")
            switch unit {
            case .percent: XCTAssertTrue([.percent, .signedPercent].contains(declared), "\(spec.id)")
            case .fraction: XCTAssertEqual(declared, .fraction, "\(spec.id)")
            case .seconds: XCTAssertEqual(declared, .seconds, "\(spec.id)")
            case .multiplier: XCTAssertEqual(declared, .multiplier, "\(spec.id)")
            }
        }
    }

    /// I4, validator side: the enums of the existing actions are exactly the step schema's.
    func testLegacyEnumsAreTheStepSchemaEnums() throws {
        for spec in catalog.specs {
            guard case .intent = spec.lowering else { continue }
            for domain in spec.domains {
                guard let mode = EditorMode(rawValue: domain.rawValue), domain != .pdf else { continue }
                let schema = LiveToolSchema.stepSchema(for: mode)
                for param in OperationArguments.params(spec, in: domain) {
                    guard case .enumeration(let values) = param.kind, let property = schema["properties"]?[param.key],
                          let accepted = property["enum"]?.array?.compactMap(\.string) else { continue }
                    if param.key == "scope" {
                        XCTAssertTrue(Set(values).isSubset(of: Set(accepted)), "\(spec.id).scope")
                    } else {
                        XCTAssertEqual(values, accepted, "\(spec.id).\(param.key) in \(mode)")
                    }
                }
            }
        }
    }

    // MARK: Validate

    func testAWellFormedCallValidates() throws {
        let (call, problems) = validate("curves", ["preset": "sCurve", "amount": 30])
        XCTAssertEqual(problems, [])
        let unwrapped = try XCTUnwrap(call)
        XCTAssertEqual(unwrapped.id, "curves")
        XCTAssertEqual(unwrapped.args["preset"], "sCurve")
        XCTAssertEqual(unwrapped.args["amount"], 30)
        XCTAssertEqual(unwrapped.args["channel"], "rgb", "a new operation's call carries its defaults")
        XCTAssertEqual(unwrapped.source, .model)
    }

    func testUnknownOperationsListTheNearestOnes() {
        let (call, problems) = validate("blendMode", ["mode": "multiply"])
        XCTAssertNil(call)
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].hasPrefix("steps[0].action: 'blendMode' is not an operation; nearest: layerBlend"), problems[0])
        let (_, elsewhere) = validate("curves", ["preset": "sCurve"], .video)
        XCTAssertTrue(elsewhere[0].contains("curves is not available for a video"), elsewhere[0])
    }

    func testStrictValuesAndRanges() {
        XCTAssertEqual(validate("curves", ["preset": "S", "amount": 30]).1,
                       ["steps[0].preset: 'S' is not one of sCurve, strongS, matte, fade, invert, brighten, darken, linear"])
        XCTAssertEqual(validate("layerOpacity", ["opacity": 150]).1, ["steps[0].opacity: 150 is outside 0...100"])
        XCTAssertEqual(validate("layerOpacity", ["opacity": "50"]).1, ["steps[0].opacity: must be a number"])
        XCTAssertEqual(validate("layerOpacity", ["opacity": 50, "alpha": 1]).1, ["steps[0].alpha: unknown field for layerOpacity; fields: ref, opacity"])
        XCTAssertEqual(validate("layerOpacity", ["ref": "o1", "opacity": 50]).1, ["steps[0].ref: 'o1' is not an id such as l1, s1, i1, j1, g1"])
        XCTAssertEqual(validate("layerVisibility", ["visible": "no"]).1, ["steps[0].visible: must be true or false"])
        XCTAssertEqual(validate("colorGrade", ["range": "shadows", "color": "blurple"]).1, ["steps[0].color: 'blurple' is not a colour name or #RRGGBB"])
        XCTAssertEqual(validate("levels", ["black": 200, "white": 100]).1, ["steps[0].white: must be greater than black"])
        XCTAssertEqual(validate("levels", ["gamma": 12]).1, ["steps[0].gamma: 12 is outside 0.1...9.99"])
    }

    func testRequiredParamsAndGroups() {
        XCTAssertEqual(validate("layerOpacity", [:]).1, ["steps[0]: layerOpacity needs opacity"])
        XCTAssertEqual(validate("hsl", ["band": "blue"]).1, ["steps[0]: hsl needs one of hue, saturation, luminance"])
        XCTAssertEqual(validate("curves", ["preset": "sCurve", "points": [[0, 0], [1_000, 1_000]]]).1,
                       ["steps[0]: curves takes one of preset, points, not several"])
        XCTAssertNotNil(validate("hsl", ["band": "blue", "saturation": -40, "luminance": 10]).0, "several values of a non-exclusive group")
        XCTAssertEqual(validate("removeLUT", [:]).1, [])
        XCTAssertEqual(validate("removeLUT", ["amount": 1]).1, ["steps[0].amount: unknown field for removeLUT; fields: layer"])
    }

    func testPointsAndBoxesAreIn0To1000() throws {
        let (call, _) = validate("lensFocus", ["point": [500, 250], "aperture": 80])
        XCTAssertEqual(try XCTUnwrap(call).args["point"], .point(PSPoint(x: 500, y: 250)))
        let (fraction, _) = validate("lensFocus", ["point": ["x": 0.5, "y": 0.25]])
        XCTAssertEqual(try XCTUnwrap(fraction).args["point"], .point(PSPoint(x: 500, y: 250)), "0…1 is read too")
        XCTAssertEqual(validate("lensFocus", ["point": [1_500, 20]]).1, ["steps[0].point: x and y must be within 0...1000"])
        XCTAssertEqual(validate("lensFocus", ["ref": "o1", "point": [1, 1]]).1, ["steps[0]: lensFocus takes one of ref, point, not several"])
        let (curve, _) = validate("curves", ["points": [[0, 0], [500, 620], [1_000, 1_000]]])
        XCTAssertEqual(try XCTUnwrap(curve).args["points"], .list([.point(PSPoint(x: 0, y: 0)), .point(PSPoint(x: 500, y: 620)), .point(PSPoint(x: 1_000, y: 1_000))]))
        let seventeen = JSONValue.array((0...16).map { .array([.number(Double($0) * 60), .number(Double($0) * 60)]) })
        XCTAssertEqual(validate("curves", ["points": seventeen]).1, ["steps[0].points: 17 items, expected 1...16"])
        let (erase, _) = validate("eraseRegion", ["box": [100, 200, 400, 300]])
        XCTAssertEqual(try XCTUnwrap(erase).args["box"], .box(PSRect(x: 100, y: 200, width: 300, height: 100)))
        XCTAssertEqual(validate("eraseRegion", ["box": [400, 200, 100, 300]]).1, ["steps[0].box: x2 and y2 must be greater than x1 and y1"])
    }

    /// Existing actions read their amount the way AmountUnit does (relative percentages both ways).
    func testExistingActionsKeepTheirReading() {
        XCTAssertEqual(validate("applyLook", ["look": "mono", "amount": -20]).1, [], "relative by default: -100…100")
        XCTAssertEqual(validate("applyLook", ["look": "mono", "amountMode": "absolute", "amount": -20]).1, ["steps[0].amount: -20 is outside 0...100"])
        XCTAssertEqual(validate("punchIns", ["amount": 0], .video).1, [], "0 takes the zoom cuts off")
        XCTAssertEqual(validate("adjust", ["parameter": "brightness", "amount": 20, "ref": "t1"]).1,
                       ["steps[0].ref: unknown field for adjust; fields: parameter, amount, amountMode, layer"])
        XCTAssertEqual(validate("addText", ["text": "Hello", "ref": "f1"], .video).1.first, "steps[0].ref: unknown field for addText; fields: text, placement, color")
        XCTAssertEqual(validate("replaceText", ["text": "brouillon", "replacement": ""], .pdf).1, [], "an empty replacement erases")
        XCTAssertNotNil(validate("movePage", ["clipNumber": 2, "choiceIndex": -1], .pdf).0)
        XCTAssertEqual(validate("trim", ["startSeconds": 8, "endSeconds": 2], .video).1, ["steps[0].endSeconds: must be after startSeconds"])
    }

    // MARK: Coerce

    func testCoerceRepairsTheForm() {
        let coerced = OperationArguments.coerce(["blend": "Produit", "layer": "L2", "extra": 1], for: "layerBlend")
        XCTAssertEqual(coerced, ["mode": "multiply", "ref": "l2", "extra": 1], "aliases, case and refs; unknown keys stay")
        XCTAssertEqual(OperationArguments.coerce(["Opacity": "50 %"], for: "layerOpacity"), ["opacity": 50])
        XCTAssertEqual(OperationArguments.coerce(["visible": "non"], for: "layerVisibility"), ["visible": false])
        XCTAssertEqual(OperationArguments.coerce(["band": "Bleus", "saturation": "-40"], for: "hsl"), ["band": "blue", "saturation": -40])
        XCTAssertEqual(OperationArguments.coerce(["preset": "courbe en S", "amount": nil], for: "curves"), ["preset": "sCurve"])
        XCTAssertEqual(OperationArguments.coerce(["point": "500, 400"], for: "lensFocus"), ["point": [500, 400]])
        XCTAssertEqual(OperationArguments.coerce(["point": ["x": 0.5, "y": 0.4]], for: "lensFocus"), ["point": [500, 400]])
        XCTAssertEqual(OperationArguments.coerce(["points": "[[0,0],[500,600],[1000,1000]]"], for: "curves"),
                       ["points": [[0, 0], [500, 600], [1_000, 1_000]]])
        XCTAssertEqual(OperationArguments.coerce(["points": [500, 600]], for: "curves"), ["points": [[500, 600]]], "one point is a list of one")
        XCTAssertEqual(OperationArguments.coerce(["range": "hautes lumières", "colour": "orange"], for: "colorGrade"),
                       ["range": "highlights", "color": "orange"])
        XCTAssertEqual(OperationArguments.coerce(["mode": "lumière tamisée"], for: "layerBlend"), ["mode": "softLight"])
        XCTAssertEqual(OperationArguments.coerce(["a": 1], for: "warpDrive"), ["a": 1], "unknown operation: unchanged")
    }

    func testCoercedThenValidatedCallsRoundTrip() throws {
        for spec in catalog.specs where spec.lowering == .handler {
            for example in spec.examples where example.role == .positive {
                guard case .object(var object) = OperationArguments.json(OperationCall(spec.id, args: example.args)) else { return XCTFail() }
                object["action"] = nil
                let (call, problems) = validate(spec.id, OperationArguments.coerce(object, for: spec.id))
                XCTAssertEqual(problems, [], "\(spec.id): « \(example.say) »")
                let again = try XCTUnwrap(call)
                guard case .object(var second) = OperationArguments.json(again) else { return XCTFail() }
                second["action"] = nil
                XCTAssertEqual(validate(spec.id, second).0, again, "json → validate is stable")
            }
        }
    }

    func testJSONWritesPointsAndBoxesAsArrays() {
        XCTAssertEqual(OperationArguments.json(OperationCall("lensFocus", args: ["point": .point(PSPoint(x: 500, y: 400)), "aperture": 60])),
                       ["action": "lensFocus", "point": [500, 400], "aperture": 60])
        XCTAssertEqual(OperationArguments.json(OperationCall("eraseRegion", args: ["box": .box(PSRect(x: 100, y: 200, width: 300, height: 100))])),
                       ["action": "eraseRegion", "box": [100, 200, 400, 300]])
    }

    // MARK: Nearest

    func testNearestOperations() {
        XCTAssertEqual(OperationArguments.nearest(to: "blendMode", domain: .photo).first, "layerBlend")
        XCTAssertEqual(OperationArguments.nearest(to: "setOpacity", domain: .photo).first, "layerOpacity")
        XCTAssertTrue(OperationArguments.nearest(to: "toneCurve", domain: .photo, limit: 2).contains("curves"))
        XCTAssertTrue(OperationArguments.nearest(to: "hueSaturation", domain: .photo, limit: 3).contains("hsl"))
        XCTAssertEqual(OperationArguments.nearest(to: "deletePages", domain: .pdf).first, "deletePage")
        XCTAssertEqual(OperationArguments.nearest(to: "cutClip", domain: .video, limit: 5).count, 5)
        let pdf = OperationArguments.nearest(to: "curves", domain: .pdf, limit: 5)
        XCTAssertTrue(pdf.allSatisfy { OperationCatalog.shared.spec($0)?.domains.contains(.pdf) ?? false }, "only the domain's operations")
        XCTAssertEqual(OperationArguments.nearest(to: "anything", domain: .photo, limit: 0), [])
    }

    func testAllowedKeysIncludeAliases() {
        XCTAssertEqual(OperationArguments.allowedKeys("layerOpacity", domain: .photo), ["action", "ref", "layer", "opacity", "amount", "value"])
        XCTAssertEqual(OperationArguments.allowedKeys("warpDrive", domain: .photo), ["action"])
    }
}
