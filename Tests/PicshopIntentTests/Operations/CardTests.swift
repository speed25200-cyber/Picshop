import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// The prompt cards (OperationCards): sizes, the exact values they print (I4), the core and
/// per-turn blocks, and docs/OPERATIONS.md, which is generated from the catalog.
final class CardTests: XCTestCase {
    private let catalog = OperationCatalog.shared

    func testEveryCardFitsOnOneShortLine() {
        var lengths: [Int] = []
        for spec in catalog.specs {
            for language in OpLanguage.allCases {
                let card = OperationCards.card(spec, language: language)
                XCTAssertLessThanOrEqual(card.count, 160, card)
                XCTAssertFalse(card.contains("\n"), card)
                XCTAssertTrue(card.hasPrefix(spec.id.raw + ":"), card)
                XCTAssertFalse(card.hasSuffix("…"), "cut: \(card)")
                lengths.append(card.count)
            }
            let unavailable = OperationCards.card(spec, language: .fr, unavailable: "no LUT imported")
            XCTAssertLessThanOrEqual(unavailable.count, 160)
            XCTAssertTrue(unavailable.hasSuffix("(unavailable: no LUT imported)"), unavailable)
        }
        let mean = Double(lengths.reduce(0, +)) / Double(lengths.count)
        XCTAssertLessThanOrEqual(mean, 120, "mean card length")
    }

    func testCardFormat() {
        XCTAssertEqual(OperationCards.card(catalog.spec("layerOpacity")!, language: .en),
                       "layerOpacity: ref:l1|s1|i1, opacity* 0..100 — How see-through a layer is « set the layer opacity to 50 »")
        XCTAssertEqual(OperationCards.card(catalog.spec("curves")!, language: .fr),
                       "curves: channel:rgb|red|green|blue=rgb, {preset:… / points:[[x,y]…] 0-1000 ≤16}*, amount 0..100=50 — Courbe de tons par canal",
                       "the example gives way to the 160 characters")
        XCTAssertEqual(OperationCards.card(catalog.spec("removeLUT")!, language: .en, unavailable: "no LUT imported"),
                       "removeLUT: — Takes the imported LUT off « remove the LUT » (unavailable: no LUT imported)")
    }

    func testCoreBlocksFitTheStablePrefix() {
        for domain in OpDomain.allCases {
            let core = Set(catalog.core(for: domain).map(\.id.raw))
            for size in [LocalPromptSize.full, .compact] {
                let block = OperationCards.coreBlock(for: domain, size: size)
                XCTAssertLessThanOrEqual(block.count, 1_400, "\(domain) \(size)")
                XCTAssertEqual(block, OperationCards.coreBlock(for: domain, size: size), "byte-stable")
                let lines = block.split(separator: "\n").map(String.init)
                XCTAssertEqual(lines.first, OperationCards.coreHeader)
                let cards = lines.dropFirst().compactMap { line -> String? in
                    guard let colon = line.firstIndex(of: ":") else { return nil }
                    let id = String(line[..<colon])
                    let rest = line[line.index(after: colon)...]
                    // A card is "id: …", or a bare "id:" for an operation without params (removeBackground).
                    return (rest.hasPrefix(" ") || rest.isEmpty) && core.contains(id) ? id : nil
                }
                XCTAssertEqual(Set(cards), core, "\(domain) \(size): every core card, nothing else")
                if size == .compact { XCTAssertFalse(block.contains("«"), "the 2B core block has no examples") }
            }
        }
        // PDF never sees the photo vocabulary.
        let pdf = OperationCards.coreBlock(for: .pdf, size: .full)
        for word in ["parameter:", "look:", "aspect:", "removeObject", "fillCells"] { XCTAssertFalse(pdf.contains(word), word) }
    }

    /// I4: every enum value printed (inline, or on its `key:` line) is exactly the set the validator
    /// accepts and the Core enum's allCases.
    func testCardsPrintExactlyTheAcceptedValues() throws {
        let allCases: [String: [String]] = [
            "parameter": AdjustmentParameter.allCases.map(\.rawValue), "look": FilterPreset.allCases.map(\.rawValue),
            "aspect": AspectPreset.allCases.map(\.rawValue), "transition": TransitionKind.allCases.map(\.rawValue),
            "placement": TextElement.Placement.allCases.map(\.rawValue), "flipAxis": FlipAxis.allCases.map(\.rawValue),
            "layerBlend.mode": BlendMode.allCases.map(\.rawValue), "channel": ToneCurve.Channel.allCases.map(\.rawValue),
            "select.mode": ["new"] + CombineMode.allCases.map(\.rawValue), "combine": CombineMode.allCases.map(\.rawValue),
            "where": MaskRegion.allCases.map(\.rawValue), "what": MaskRegion.allCases.map(\.rawValue) + ["all", "wand"],
            "range": ColorGrade.Range.allCases.map(\.rawValue), "weight": TableGrid.FontWeight.allCases.map(\.rawValue),
            "font": TableGrid.FontDesign.allCases.map(\.rawValue), "band": ColorMixer.Band.allCases.map { $0.englishName.lowercased() },
        ]
        var checked = 0
        for spec in catalog.specs {
            for domain in spec.domains {
                let card = OperationCards.card(spec, language: .en, unavailable: nil, domain: domain, detail: .full)
                let lines = OperationCards.enumLines([spec], domain: domain)
                for param in OperationArguments.params(spec, in: domain) where param.onCard {
                    guard case .enumeration(let values) = param.kind else { continue }
                    let printed = try XCTUnwrap(Self.printedValues(param.key, card: card, lines: lines), "\(spec.id).\(param.key): \(card)")
                    XCTAssertEqual(printed, values, "\(spec.id).\(param.key)")
                    for value in printed {
                        var problems: [String] = []
                        XCTAssertNotNil(OperationArguments.check(.string(value), param: param, spec: spec, object: [:], path: "p", problems: &problems), value)
                    }
                    var problems: [String] = []
                    XCTAssertNil(OperationArguments.check(.string("notAValue"), param: param, spec: spec, object: [:], path: "p", problems: &problems))
                    if let expected = allCases["\(spec.id.raw).\(param.key)"] ?? allCases[param.key] { XCTAssertEqual(printed, expected, "\(spec.id).\(param.key)") }
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 50)
        // A long enum's line is the same wherever it is printed.
        var seen: [String: [String]] = [:]
        for spec in catalog.specs {
            for entry in OperationCards.longEnums(spec, domain: nil) {
                if let previous = seen[entry.key] { XCTAssertEqual(previous, entry.values, entry.key) }
                seen[entry.key] = entry.values
            }
        }
    }

    /// The values printed for `key` on the card, or on its `key:` line when the card says `key:…`.
    static func printedValues(_ key: String, card: String, lines: [String]) -> [String]? {
        for marker in [" \(key):", " \(key)*:", "{\(key):", "{\(key)*:"] {
            guard let range = card.range(of: marker) else { continue }
            let rest = card[range.upperBound...]
            let end = rest.firstIndex { ",} =".contains($0) } ?? rest.endIndex
            var printed = String(rest[..<end])
            // A group's only member on the card is printed `key:…*` (one of the group must be given).
            if printed.hasSuffix("*") { printed.removeLast() }
            if printed == "…" {
                guard let line = lines.first(where: { $0.hasPrefix(key + ": ") }) else { return nil }
                return line.dropFirst(key.count + 2).split(separator: "|").map(String.init)
            }
            return printed.split(separator: "|").map(String.init)
        }
        return nil
    }

    func testTurnBlock() {
        XCTAssertEqual(OperationCards.turnBlock([], language: .fr, budget: 1_000), "")
        XCTAssertEqual(OperationCards.turnBlock([RetrievedOperation(id: "warpDrive", score: 9)], language: .fr, budget: 1_000), "")
        let ops = ["curves", "levels", "layerBlend", "hsl", "colorGrade", "perspective", "lensFocus", "layerOpacity"].map { RetrievedOperation(id: OpID($0), score: 5) }
        for budget in [600, 1_000] {
            let block = OperationCards.turnBlock(ops, language: .fr, budget: budget)
            XCTAssertLessThanOrEqual(block.count, budget)
            XCTAssertTrue(block.hasPrefix("<ops>\ncurves: "), block)
            XCTAssertTrue(block.hasSuffix("\n</ops>"))
            XCTAssertEqual(block.components(separatedBy: "\npreset: ").count, 2, "the presets once")
        }
        let full = OperationCards.turnBlock(ops, language: .en, budget: 2_000)
        XCTAssertTrue(full.contains("\nmode: normal|multiply|screen|overlay|"), full)
        XCTAssertTrue(full.contains("« add an S curve »"), "the turn's language")
        XCTAssertEqual(OperationCards.turnBlock(ops, language: .fr, budget: 40), "", "nothing fits")
        let unavailable = OperationCards.turnBlock([RetrievedOperation(id: "lutIntensity", score: 2, unavailable: "no LUT imported")], language: .fr, budget: 600)
        XCTAssertTrue(unavailable.contains("(unavailable: no LUT imported)"), unavailable)
        // With the domain: that editor's fields, and no repeat of the core block's enums.
        let video = OperationCards.turnBlock([RetrievedOperation(id: "matchColor", score: 4)], language: .fr, budget: 600, domain: .video)
        let photo = OperationCards.turnBlock([RetrievedOperation(id: "matchColor", score: 4)], language: .fr, budget: 600, domain: .photo)
        XCTAssertTrue(video.contains("clipNumber"), video)
        XCTAssertFalse(photo.contains("clipNumber"), photo)
        let aspect = OperationCards.turnBlock([RetrievedOperation(id: "setAspect", score: 4)], language: .fr, budget: 600, domain: .photo)
        XCTAssertTrue(aspect.contains("setAspect: aspect*:…"), aspect)
        XCTAssertFalse(aspect.contains("\naspect: "), "the photo core block already lists the aspects")
        XCTAssertTrue(OperationCards.turnBlock([RetrievedOperation(id: "setAspect", score: 4)], language: .fr, budget: 600).contains("\naspect: original|"))
    }

    // MARK: docs/OPERATIONS.md

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// docs/OPERATIONS.md is the catalog, rendered. After changing an entry:
    /// `PICSHOP_WRITE_OPERATIONS_DOC=1 swift test --filter CardTests/testOperationsDocIsUpToDate`.
    func testOperationsDocIsUpToDate() throws {
        let url = Self.repositoryRoot.appendingPathComponent("docs/OPERATIONS.md")
        let rendered = OperationsDocument.render(catalog)
        if ProcessInfo.processInfo.environment["PICSHOP_WRITE_OPERATIONS_DOC"] != nil {
            try rendered.write(to: url, atomically: true, encoding: .utf8)
        }
        let current = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(current == rendered, "docs/OPERATIONS.md is stale: run PICSHOP_WRITE_OPERATIONS_DOC=1 swift test --filter CardTests/testOperationsDocIsUpToDate")
    }
}

/// docs/OPERATIONS.md, rendered from the catalog.
enum OperationsDocument {
    static func render(_ catalog: OperationCatalog) -> String {
        var out: [String] = []
        let handlers = catalog.specs.filter { $0.lowering == .handler }
        out.append("# Operations")
        out.append("")
        out.append("Generated from the Operation Catalog (`Sources/PicshopCore/Operations`); do not edit by hand. After changing an entry, run")
        out.append("`PICSHOP_WRITE_OPERATIONS_DOC=1 swift test --filter CardTests/testOperationsDocIsUpToDate`; CI fails while this file is stale.")
        out.append("")
        out.append("\(catalog.specs.count) operations: \(catalog.specs(in: .photo).count) photo, \(catalog.specs(in: .video).count) video, "
            + "\(catalog.specs(in: .pdf).count) PDF. \(handlers.count) run through a handler table (`IntentAction.operation`); the others lower to "
            + "the IntentAction of the same name.")
        out.append("")
        out.append("A step is `{\"action\": id, …params}`. Points are `[x, y]` and boxes `[x1, y1, x2, y2]`, 0–1000 with a top-left origin. "
            + "On a card, `*` is required, `{a / b}` is a one-of group, and `key:…` lists its values on a `key:` line.")
        for domain in OpDomain.allCases {
            out.append("")
            out.append("## \(title(domain))")
            out.append("")
            out.append("| Operation | Title | Category | Core | Grammar | Fast lane | Panel |")
            out.append("|---|---|---|---|---|---|---|")
            for spec in catalog.specs(in: domain) {
                out.append("| [`\(spec.id.raw)`](#\(spec.id.raw.lowercased())) | \(spec.title.en) / \(spec.title.fr) | \(spec.category.rawValue) | "
                    + "\(spec.coreIn.contains(domain) ? "yes" : "") | \(spec.grammar.rawValue) | \(spec.fastLane ? "yes" : "") | \(spec.uiTool ?? "") |")
            }
        }
        out.append("")
        out.append("## Entries")
        for spec in catalog.specs {
            out.append("")
            out.append("### \(spec.id.raw)")
            out.append("")
            out.append("\(spec.title.en) / \(spec.title.fr). \(spec.summary.en). *\(spec.summary.fr).*")
            out.append("")
            let lowering: String
            switch spec.lowering {
            case .intent(let action): lowering = "IntentAction.\(action.rawValue)"
            case .handler: lowering = "handler (IntentAction.operation)"
            }
            out.append("- Domains: \(spec.domains.map(\.rawValue).sorted().joined(separator: ", ")); core in: "
                + "\(spec.coreIn.isEmpty ? "none" : spec.coreIn.map(\.rawValue).sorted().joined(separator: ", ")); category \(spec.category.rawValue); "
                + "phase \(phase(spec.phase)); runs as \(lowering).")
            let requirements = requirementsText(spec.requires)
            if !requirements.isEmpty { out.append("- Needs: \(requirements).") }
            out.append("- Card: `\(OperationCards.card(spec, language: .en))`")
            for line in OperationCards.enumLines([spec], domain: nil) { out.append("  - `\(line)`") }
            if !spec.params.isEmpty {
                out.append("- Params:")
                for param in spec.params { out.append("  - `\(param.key)` \(kindText(param.kind)), \(presenceText(param.presence)): \(param.doc)"
                    + (param.keyAliases.isEmpty ? "" : " (also `\(param.keyAliases.joined(separator: "`, `"))`)") + (param.onCard ? "" : "; off the card")) }
            }
            for language in OpLanguage.allCases {
                out.append("- Triggers (\(language.rawValue)): " + (spec.triggers[language] ?? []).map { "« \($0) »" }.joined(separator: ", "))
            }
            out.append("- Examples:")
            for example in spec.examples {
                let call = OperationArguments.json(OperationCall(spec.id, args: example.args)).serialized()
                switch example.role {
                case .positive: out.append("  - « \(example.say) » → `\(call)`")
                case .paraphrase: out.append("  - « \(example.say) » (paraphrase) → `\(call)`")
                case .negative(let expected): out.append("  - « \(example.say) » is not this: \(expected.map { "`\($0.raw)`" } ?? "no operation yet")")
                }
            }
            out.append("- Check: " + spec.verify.map(postconditionText).joined(separator: "; ") + ".")
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func title(_ domain: OpDomain) -> String {
        switch domain {
        case .photo: return "Photo"
        case .video: return "Video"
        case .pdf: return "PDF"
        }
    }

    static func phase(_ phase: OpPhase) -> String {
        ["refDependent", "geometry", "cleanup", "tone", "color", "effects", "composition", "text", "output"][phase.rawValue]
    }

    static func kindText(_ kind: ParamKind) -> String {
        switch kind {
        case .enumeration(let values): return "one of " + values.map { "`\($0)`" }.joined(separator: ", ")
        case .number(let range, let unit): return "number \(OperationCards.number(range.lowerBound))…\(OperationCards.number(range.upperBound)) (\(unit.rawValue))"
        case .integer(let range): return "integer \(range.lowerBound)…\(range.upperBound)"
        case .boolean: return "true or false"
        case .color: return "colour name or #RRGGBB"
        case .point: return "point [x, y] 0–1000"
        case .box: return "box [x1, y1, x2, y2] 0–1000"
        case .text(let limit): return "text ≤ \(limit)"
        case .ref(let kinds): return "id " + RefKind.allCases.filter(kinds.contains).map { "\($0.prefix)n" }.joined(separator: "/")
        case .list(let item, let max): return "list of ≤ \(max): " + kindText(item)
        }
    }

    static func presenceText(_ presence: Presence) -> String {
        switch presence {
        case .required: return "required"
        case .optional(let value?): return "default \(OperationCards.valueText(value))"
        case .optional(nil): return "optional"
        case .oneOf(let group): return "one of group `\(group)`"
        }
    }

    static func requirementsText(_ requires: OpRequirements) -> String {
        var parts: [String] = []
        if requires.subject { parts.append("a subject") }
        if requires.selection { parts.append("a selection") }
        if requires.table { parts.append("a table") }
        if requires.captions { parts.append("captions") }
        if requires.generativeEngine { parts.append("the generative engine") }
        if requires.importedLUT { parts.append("an imported LUT") }
        if requires.nonBaseLayer { parts.append("a layer above the photo") }
        if let asset = requires.referenceAsset { parts.append("a \(asset.rawValue) the user picks") }
        if requires.cost != .instant { parts.append("\(requires.cost.rawValue) to run") }
        if requires.geometryChange { parts.append("changes the geometry") }
        if requires.destructive { parts.append("destructive") }
        return parts.joined(separator: ", ")
    }

    static func postconditionText(_ postcondition: Postcondition) -> String {
        switch postcondition {
        case .structural(let probe, let expectation): return "\(probeText(probe)) \(expectationText(expectation))"
        case .pixels(let probe, let expectation): return "pixels \(probe) \(expectationText(expectation)) (from W2)"
        case .unverifiable(let reason): return "unverifiable: \(reason)"
        }
    }

    static func probeText(_ probe: StateProbe) -> String {
        if case .adjustment(let name) = probe { return "adjustment(\(name))" }
        return String(describing: probe)
    }

    static func expectationText(_ expectation: Expectation) -> String {
        switch expectation {
        case .increased: return "increased"
        case .decreased: return "decreased"
        case .changed: return "changed"
        case .unchanged: return "unchanged"
        case .equalsParam(let key): return "equals `\(key)`"
        case .delta(let delta): return "changes by \(OperationCards.number(delta))"
        }
    }
}
