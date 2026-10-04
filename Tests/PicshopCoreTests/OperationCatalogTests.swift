import XCTest
@testable import PicshopCore

/// The operation types, the catalog's lookups, and the invariants over the real entries that
/// Core alone can check (ids, lowering, I2 examples, params, docs). The ones that need the
/// validator, the cards or the routers (I3–I6) are in PicshopIntentTests/Operations.
final class OperationCatalogTests: XCTestCase {
    private func spec(_ id: OpID, domains: Set<OpDomain>, coreIn: Set<OpDomain> = [], lowering: OpLowering) -> OperationSpec {
        OperationSpec(id: id, domains: domains, coreIn: coreIn, category: .light, phase: .tone,
                      title: Bilingual(en: "Title \(id)", fr: "Titre \(id)"), summary: Bilingual(en: "Does \(id)", fr: "Fait \(id)"),
                      lowering: lowering)
    }

    func testOpIDIsALiteralAndCodesAsABareString() throws {
        let id: OpID = "curves"
        XCTAssertEqual(id, OpID("curves"))
        XCTAssertEqual(id.description, "curves")
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(id), as: UTF8.self), "\"curves\"")
        XCTAssertEqual(try JSONDecoder().decode(OpID.self, from: Data("\"levels\"".utf8)), "levels")
    }

    func testValuesAndBilingualText() {
        XCTAssertEqual(OpValue.number(0.3).double, 0.3)
        XCTAssertNil(OpValue.number(0.3).string)
        XCTAssertEqual(OpValue.string("sCurve").string, "sCurve")
        XCTAssertEqual(OpValue.bool(true).bool, true)
        XCTAssertNil(OpValue.list([.number(1)]).double)
        let title = Bilingual(en: "Curves", fr: "Courbes")
        XCTAssertEqual(title(.en), "Curves")
        XCTAssertEqual(title(.fr), "Courbes")
    }

    func testPhasesAreOrderedAndRefPrefixesAreDistinct() {
        XCTAssertLessThan(OpPhase.refDependent, .geometry)
        XCTAssertLessThan(OpPhase.tone, .color)
        XCTAssertLessThan(OpPhase.text, .output)
        XCTAssertEqual(Set(RefKind.allCases.map(\.prefix)).count, RefKind.allCases.count)
        XCTAssertEqual(RefKind.printedText.prefix, "t")
        XCTAssertEqual(RefKind.textLayer.prefix, "l")
        XCTAssertEqual(RefKind.textHit.prefix, "w")
    }

    func testOperationCallRoundTrips() throws {
        let call = OperationCall("curves", args: ["preset": .string("sCurve"), "amount": .number(30), "points": .list([.point(PSPoint(x: 250, y: 300))])],
                                 source: .planner)
        let decoded = try JSONDecoder().decode(OperationCall.self, from: try JSONEncoder().encode(call))
        XCTAssertEqual(decoded, call)
    }

    func testTheSharedCatalogHasEveryEntryOnce() {
        let catalog = OperationCatalog.shared
        XCTAssertGreaterThanOrEqual(catalog.specs.count, 100)
        XCTAssertEqual(Set(catalog.specs.map(\.id)).count, catalog.specs.count, "ids are unique")
        let lowered = catalog.specs.compactMap { spec -> IntentAction? in
            if case .intent(let action) = spec.lowering { return action }
            return nil
        }
        XCTAssertEqual(Set(lowered).count, lowered.count, "one spec per IntentAction")
        XCTAssertFalse(lowered.contains(.operation), "the generic action is never an entry")
        for spec in catalog.specs {
            XCTAssertEqual(catalog.spec(spec.id), spec)
            XCTAssertFalse(spec.domains.isEmpty, "\(spec.id)")
            XCTAssertTrue(spec.coreIn.isSubset(of: spec.domains), "\(spec.id): core only where it exists")
        }
    }

    /// The 13 W1 operations: handlers, unknown to the grammar, off the fast lane, never core, and
    /// never an IntentAction name. W2 adds the six mask and selection operations (keywordsOnly: the grammar owns
    /// only their signature phrases; maskAdjust takes selectiveAdjust's place in the photo core set).
    func testTheThirteenNewOperations() throws {
        let ids: [OpID] = ["curves", "levels", "autoTone", "hsl", "colorGrade", "lutIntensity", "removeLUT", "perspective", "lensFocus",
                           "layerOpacity", "layerBlend", "layerVisibility", "layerOrder"]
        let raw = Set(IntentAction.allCases.map(\.rawValue))
        for id in ids {
            let spec = try XCTUnwrap(OperationCatalog.shared.spec(id), "\(id)")
            XCTAssertEqual(spec.lowering, .handler, "\(id)")
            XCTAssertEqual(spec.grammar, .none, "\(id)")
            XCTAssertFalse(spec.fastLane, "\(id)")
            XCTAssertTrue(spec.coreIn.isEmpty, "\(id)")
            XCTAssertEqual(spec.domains, [.photo], "\(id)")
            XCTAssertFalse(raw.contains(id.raw), "\(id) must not collide with an IntentAction")
        }
        let masks: [OpID] = ["maskAdjust", "maskEdit", "maskDelete", "select", "selectionModify", "selectionApply"]
        for id in masks {
            let spec = try XCTUnwrap(OperationCatalog.shared.spec(id), "\(id)")
            XCTAssertEqual(spec.lowering, .handler, "\(id)")
            XCTAssertEqual(spec.grammar, .keywordsOnly, "\(id)")
            XCTAssertFalse(spec.fastLane, "\(id)")
            XCTAssertEqual(spec.coreIn, id == "maskAdjust" ? [.photo] : [], "\(id)")
            XCTAssertEqual(spec.domains, [.photo], "\(id)")
            XCTAssertFalse(raw.contains(id.raw), "\(id) must not collide with an IntentAction")
        }
        // W3 (§8.1): twelve photo layer operations and the recipe (photo and video), all keywordsOnly, never on the fast lane.
        let layers: [OpID] = ["addImageLayer", "layerVia", "addFillLayer", "fillLayer", "addAdjustmentLayer", "layerMask", "layerClip", "groupLayers",
                              "mergeLayers", "layerTransform", "layerProperties", "exportPhoto"]
        for id in layers + ["recipe"] {
            let spec = try XCTUnwrap(OperationCatalog.shared.spec(id), "\(id)")
            XCTAssertEqual(spec.lowering, .handler, "\(id)")
            XCTAssertEqual(spec.grammar, .keywordsOnly, "\(id)")
            XCTAssertFalse(spec.fastLane, "\(id)")
            XCTAssertEqual(spec.coreIn, [], "\(id)")
            XCTAssertEqual(spec.domains, id == "recipe" ? [.photo, .video] : [.photo], "\(id)")
            XCTAssertEqual(spec.uiTool, id == "exportPhoto" ? "export" : (id == "recipe" ? "magic" : "layers"), "\(id)")
            XCTAssertFalse(raw.contains(id.raw), "\(id) must not collide with an IntentAction")
        }
        let handlers = OperationCatalog.shared.specs.filter { $0.lowering == .handler }.map(\.id)
        XCTAssertEqual(Set(handlers), Set(ids + masks + layers + ["recipe"]), "W1, W2 and W3 have exactly these handler operations")
        // An existing action keeps its raw value as id.
        for spec in OperationCatalog.shared.specs {
            if case .intent(let action) = spec.lowering { XCTAssertEqual(spec.id.raw, action.rawValue) }
        }
    }

    func testCoreSetsPerDomain() {
        func core(_ domain: OpDomain) -> Set<String> { Set(OperationCatalog.shared.core(for: domain).map(\.id.raw)) }
        XCTAssertEqual(core(.photo), ["adjust", "applyLook", "autoEnhance", "crop", "rotate", "removeObject", "maskAdjust", "removeBackground",
                                      "blurBackground", "addText", "editText", "fillCells"])
        XCTAssertEqual(core(.video), ["trim", "deleteRange", "split", "setSpeed", "addText", "addTransition", "addMusic", "setVolume", "autoCaptions",
                                      "adjust", "applyLook", "crop"])
        XCTAssertEqual(core(.pdf), ["goToPage", "deletePage", "rotatePage", "movePage", "insertBlankPage", "highlightText", "replaceText", "redactText",
                                    "addText", "addSignature", "addPageNumbers", "extractPage"])
    }

    /// I2 at the W1 level: at least 2 French and 1 English positive examples per operation.
    func testEveryOperationHasExamplesInBothLanguages() {
        for spec in OperationCatalog.shared.specs {
            let positive = spec.examples.filter { $0.role == .positive }
            XCTAssertGreaterThanOrEqual(positive.filter { $0.language == .fr }.count, 2, "\(spec.id): French examples")
            XCTAssertGreaterThanOrEqual(positive.filter { $0.language == .en }.count, 1, "\(spec.id): English examples")
            XCTAssertEqual(Set(spec.examples.map(\.say)).count, spec.examples.count, "\(spec.id): examples are distinct")
        }
        // The new operations also teach a near miss or a paraphrase.
        for spec in OperationCatalog.shared.specs where spec.lowering == .handler {
            XCTAssertTrue(spec.examples.contains { $0.role != .positive }, "\(spec.id)")
        }
    }

    /// I2 at the W2 level, for every operation: at least 3 French and 2 English positive or paraphrase examples,
    /// and a near miss that names where it should go (the R and S lanes check them).
    func testEveryOperationMeetsTheW2ExampleLevel() {
        var short: [String] = []
        for spec in OperationCatalog.shared.specs {
            let said = spec.examples.filter { !Self.isNegative($0) }
            let french = said.filter { $0.language == .fr }.count, english = said.filter { $0.language == .en }.count
            let negatives = spec.examples.filter(Self.isNegative).count
            if french < 3 || english < 2 || negatives < 1 { short.append("\(spec.id): fr \(french), en \(english), near \(negatives)") }
        }
        XCTAssertTrue(short.isEmpty, "\(short.count) operations below the W2 level:\n" + short.joined(separator: "\n"))
    }

    static func isNegative(_ example: OpExample) -> Bool {
        if case .negative = example.role { return true }
        return false
    }

    /// The six W2 operations go deeper (§8.10): French and English positives and paraphrases.
    func testTheW2OperationsHaveTheirExamples() throws {
        let minimums: [OpID: (Int, Int)] = ["maskAdjust": (12, 6), "select": (10, 5), "maskEdit": (8, 4), "selectionModify": (8, 4),
                                            "selectionApply": (8, 4), "maskDelete": (3, 2)]
        for (id, minimum) in minimums {
            let spec = try XCTUnwrap(OperationCatalog.shared.spec(id))
            let said = spec.examples.filter { !Self.isNegative($0) }
            XCTAssertGreaterThanOrEqual(said.filter { $0.language == .fr }.count, minimum.0, "\(id) French")
            XCTAssertGreaterThanOrEqual(said.filter { $0.language == .en }.count, minimum.1, "\(id) English")
            XCTAssertTrue(spec.examples.contains(where: Self.isNegative), "\(id) near miss")
        }
        // selectionApply: one example per use.
        let apply = try XCTUnwrap(OperationCatalog.shared.spec("selectionApply"))
        let uses = Set(apply.examples.compactMap { $0.args["use"]?.string })
        XCTAssertEqual(uses, Set(CatalogPhotoMasks.useValues))
        // The enumerations come from the Core enums.
        let where_ = try XCTUnwrap(OperationCatalog.shared.spec("maskAdjust")?.params.first { $0.key == "where" })
        XCTAssertEqual(where_.kind, .enumeration(MaskRegion.allCases.map(\.rawValue)))
        let what = try XCTUnwrap(OperationCatalog.shared.spec("select")?.params.first { $0.key == "what" })
        XCTAssertEqual(what.kind, .enumeration(MaskRegion.allCases.map(\.rawValue) + ["all", "wand"]))
        let combine = try XCTUnwrap(OperationCatalog.shared.spec("maskEdit")?.params.first { $0.key == "combine" })
        XCTAssertEqual(combine.kind, .enumeration(CombineMode.allCases.map(\.rawValue)))
        for alias in where_.valueAliases.values { XCTAssertNotNil(MaskRegion(rawValue: alias), alias) }
    }

    func testTextsTriggersAndChecksAreFilledIn() {
        for spec in OperationCatalog.shared.specs {
            for text in [spec.title.en, spec.title.fr, spec.summary.en, spec.summary.fr] {
                XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty, "\(spec.id)")
            }
            XCTAssertLessThanOrEqual(spec.summary.en.count, 48, "\(spec.id): summaries stay short for the cards")
            XCTAssertFalse((spec.triggers[.fr] ?? []).isEmpty, "\(spec.id): French triggers")
            XCTAssertFalse((spec.triggers[.en] ?? []).isEmpty, "\(spec.id): English triggers")
            XCTAssertFalse(spec.verify.isEmpty, "\(spec.id): a postcondition or an explicit unverifiable")
            XCTAssertNotNil(spec.uiTool, "\(spec.id): the panel that edits it")
            for param in spec.params {
                XCTAssertLessThanOrEqual(param.doc.count, 40, "\(spec.id).\(param.key): doc fits the card")
                XCTAssertFalse(param.doc.isEmpty, "\(spec.id).\(param.key)")
                for alias in param.valueAliases.keys {
                    XCTAssertEqual(alias, alias.lowercased().folding(options: [.diacriticInsensitive], locale: nil), "\(spec.id): aliases are folded")
                }
            }
            XCTAssertEqual(Set(spec.params.map(\.key)).count, spec.params.count, "\(spec.id): one param per key")
        }
    }

    /// Examples only use the operation's own keys, and every required param.
    func testExamplesUseTheParams() {
        for spec in OperationCatalog.shared.specs {
            let keys = Set(spec.params.map(\.key))
            let required = spec.params.filter { $0.presence == .required }.map(\.key)
            for example in spec.examples {
                if case .negative = example.role { continue }
                XCTAssertTrue(Set(example.args.keys).isSubset(of: keys), "\(spec.id): « \(example.say) » \(example.args.keys.sorted())")
                for key in required { XCTAssertNotNil(example.args[key], "\(spec.id): « \(example.say) » needs \(key)") }
            }
            for group in spec.exclusiveGroups {
                XCTAssertTrue(spec.params.contains { $0.presence == .oneOf(group: group) }, "\(spec.id): \(group) is a group")
            }
        }
    }

    /// The editors' panel ids (PhotoEditorSession.Tool, VideoEditorSession.Tool, PDFEditorSession.Tool raw values;
    /// the UI module does not build on Linux, so they are listed here).
    static let panels: [OpDomain: Set<String>] = [
        .photo: ["magic", "focus", "adjust", "looks", "color", "erase", "precise", "cutout", "crop", "text", "shapes", "layers", "curves", "levels",
                 "masks", "select", "export"],
        .video: ["magic", "transcript", "cut", "speed", "motion", "audio", "looks", "adjust", "color", "text", "overlay", "transitions", "frame"],
        .pdf: ["pages", "draw", "highlight", "redact", "text", "signature", "image"],
    ]

    /// I1 (W1 level): every operation names a panel of its editors, and every photo panel W1 touches
    /// (curves, levels, layers, colour, crop, focus) is reachable from the catalog.
    func testOperationsNameTheirPanels() throws {
        for spec in OperationCatalog.shared.specs {
            let tool = try XCTUnwrap(spec.uiTool, "\(spec.id)")
            let known = spec.domains.reduce(into: Set<String>()) { $0.formUnion(Self.panels[$1] ?? []) }
            XCTAssertTrue(known.contains(tool), "\(spec.id): \(tool)")
        }
        let photo = Set(OperationCatalog.shared.specs(in: .photo).compactMap(\.uiTool))
        for panel in ["curves", "levels", "layers", "color", "crop", "focus", "adjust", "looks", "text", "erase", "cutout", "masks", "select"] {
            XCTAssertTrue(photo.contains(panel), panel)
        }
    }

    /// Enumerations come from the Core enums, never retyped.
    func testEnumerationsAreGeneratedFromAllCases() throws {
        func values(_ id: OpID, _ key: String) throws -> [String] {
            let param = try XCTUnwrap(OperationCatalog.shared.spec(id)?.params.first { $0.key == key }, "\(id).\(key)")
            guard case .enumeration(let values) = param.kind else { throw XCTSkip("\(id).\(key) is not an enumeration") }
            return values
        }
        XCTAssertEqual(try values("adjust", "parameter"), AdjustmentParameter.allCases.map(\.rawValue))
        XCTAssertEqual(try values("applyLook", "look"), FilterPreset.allCases.map(\.rawValue))
        XCTAssertEqual(try values("crop", "aspect"), AspectPreset.allCases.map(\.rawValue))
        XCTAssertEqual(try values("addTransition", "transition"), TransitionKind.allCases.map(\.rawValue))
        XCTAssertEqual(try values("addText", "placement"), TextElement.Placement.allCases.map(\.rawValue))
        XCTAssertEqual(try values("layerBlend", "mode"), BlendMode.allCases.map(\.rawValue))
        XCTAssertEqual(try values("layerBlend", "mode").count, 27)
        XCTAssertEqual(try values("hsl", "band"), ColorMixer.Band.allCases.map { $0.englishName.lowercased() })
        XCTAssertEqual(try values("curves", "channel"), ToneCurve.Channel.allCases.map(\.rawValue))
        XCTAssertEqual(try values("colorGrade", "range"), ColorGrade.Range.allCases.map(\.rawValue))
        XCTAssertEqual(try values("autoCaptions", "text"), CaptionStyle.allCases.map(\.rawValue))
        // The plan's French blend words reach the modes.
        let mode = try XCTUnwrap(OperationCatalog.shared.spec("layerBlend")?.params.first { $0.key == "mode" })
        XCTAssertEqual(mode.valueAliases["produit"], "multiply")
        XCTAssertEqual(mode.valueAliases["lumiere tamisee"], "softLight")
        XCTAssertEqual(mode.valueAliases["densite lineaire moins"], "linearBurn")
        for target in mode.valueAliases.values { XCTAssertNotNil(BlendMode(rawValue: target), target) }
    }

    func testLookups() {
        let catalog = OperationCatalog(specs: [
            spec("adjust", domains: [.photo, .video], coreIn: [.photo], lowering: .intent(.adjust)),
            spec("curves", domains: [.photo], lowering: .handler),
            spec("deletePage", domains: [.pdf], coreIn: [.pdf], lowering: .intent(.deletePage)),
            spec("curves", domains: [.video], lowering: .handler),
        ])
        XCTAssertEqual(catalog.spec("curves")?.domains, [.photo], "the first spec with an id wins")
        XCTAssertNil(catalog.spec("levels"))
        XCTAssertEqual(catalog.specs(in: .photo).map(\.id), ["adjust", "curves"])
        XCTAssertEqual(catalog.core(for: .photo).map(\.id), ["adjust"])
        XCTAssertEqual(catalog.core(for: .pdf).map(\.id), ["deletePage"])
        XCTAssertEqual(catalog.spec(lowering: .adjust)?.id, "adjust")
        XCTAssertNil(catalog.spec(lowering: .crop))
    }

    func testOperationActionIsNeverMetaNorTiedToAMode() {
        XCTAssertFalse(IntentAction.operation.isMeta)
        XCTAssertFalse(IntentAction.operation.isPhotoOnly)
        XCTAssertFalse(IntentAction.operation.isVideoOnly)
        XCTAssertFalse(IntentAction.operation.isPDFOnly)
    }

    func testEditIntentCarriesTheCall() throws {
        let intent = EditIntent(action: .operation, operation: OperationCall("curves", args: ["preset": .string("sCurve")]))
        XCTAssertEqual(intent.summary, "Curves", "the spec's English title")
        XCTAssertEqual(intent.operationDomains, [.photo])
        let unknown = EditIntent(action: .operation, operation: OperationCall("warpDrive"))
        XCTAssertEqual(unknown.summary, "warpDrive", "unknown to the catalog: the id")
        XCTAssertEqual(unknown.operationDomains, [], "not in the catalog: allowed nowhere")
        XCTAssertNil(EditIntent(action: .crop).operationDomains)
        XCTAssertEqual(EditIntent(action: .operation).summary, "Operation")
        let decoded = try JSONDecoder().decode(EditIntent.self, from: try JSONEncoder().encode(intent))
        XCTAssertEqual(decoded, intent)
    }

    func testIntentsSavedBeforeW1StillDecode() throws {
        // An EditIntent without the `operation` key (every build before W1).
        let encoded = try JSONEncoder().encode(EditIntent(action: .rotate, degrees: 90))
        let object = try JSONSerialization.jsonObject(with: encoded)
        var json = try XCTUnwrap(object as? [String: Any])
        json.removeValue(forKey: "operation")
        let decoded = try JSONDecoder().decode(EditIntent.self, from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.action, .rotate)
        XCTAssertNil(decoded.operation)
    }

    func testBlendModesKeepTheirOrderAndRawValues() {
        XCTAssertEqual(BlendMode.allCases.count, 27)
        XCTAssertEqual(Array(BlendMode.allCases.prefix(12)), [.normal, .multiply, .screen, .overlay, .softLight, .hardLight, .darken, .lighten,
                                                               .difference, .luminosity, .color, .hue])
        XCTAssertEqual(Set(BlendMode.allCases.map(\.rawValue)).count, 27)
        XCTAssertEqual(BlendMode(rawValue: "linearDodge"), .linearDodge)
        XCTAssertEqual(Set(BlendMode.allCases.map(\.displayName)).count, 27)
    }
}
