import XCTest
@testable import PicshopCore

/// D21: each recipe's steps equal the table (ids, args, order) for three argument sets; vlogCleanup's conditional
/// steps; the wrong domain gives nothing; the expansion is deterministic.
final class RecipeBookTests: XCTestCase {
    /// A step as one comparable line: catalog ops with their sorted arguments, legacy actions with their fields.
    private func describe(_ step: EditIntent) -> String {
        if step.action == .operation, let call = step.operation {
            let args = call.args.keys.sorted().map { key -> String in
                switch call.args[key]! {
                case .number(let value): return "\(key)=\(value)"
                case .string(let value): return "\(key)=\(value)"
                case .bool(let value): return "\(key)=\(value)"
                default: return "\(key)=?"
                }
            }
            XCTAssertEqual(call.source, .planner)
            return "\(call.id.raw)(\(args.joined(separator: ", ")))"
        }
        var parts = [step.action.rawValue]
        if let aspect = step.aspect { parts.append("aspect=\(aspect.rawValue)") }
        if let amount = step.amount { parts.append(amount.mode == .absolute ? "amount=\(amount.value)" : "amount=\(amount.mode.rawValue):\(amount.value)") }
        if step.scope == .all { parts.append("scope=all") }
        return parts.joined(separator: " ")
    }

    private func expand(_ recipe: RecipeName, _ args: [String: OpValue] = [:], domain: OpDomain? = nil, music: Bool = false,
                        captions: Bool = false) -> [String] {
        let context = RecipeContext(domain: domain ?? RecipeBook.domain(of: recipe), hasMusic: music, hasCaptions: captions)
        return RecipeBook.expand(recipe, args: args, context: context).map(describe)
    }

    func testInstagramPost() {
        let tail = ["autoTone(amount=60.0)", "adjust(amount=12.0, amountMode=relative, parameter=vibrance)",
                    "adjust(amount=8.0, amountMode=relative, parameter=clarity)", "sharpen amount=0.25", "exportPhoto(preset=instagram)"]
        XCTAssertEqual(expand(.instagramPost), ["setAspect aspect=\(AspectPreset.ratio4x5.rawValue)"] + tail)
        XCTAssertEqual(expand(.instagramPost, ["format": "square"]), ["setAspect aspect=\(AspectPreset.square.rawValue)"] + tail)
        XCTAssertEqual(expand(.instagramPost, ["format": "story9x16"]), ["setAspect aspect=\(AspectPreset.ratio9x16.rawValue)"] + tail)
    }

    func testProductPhoto() {
        func steps(_ colour: String) -> [String] {
            ["setAspect aspect=\(AspectPreset.square.rawValue)", "layerVia(mode=copy, name=Produit, where=subject)",
             "addFillLayer(color=\(colour), fill=solid, position=below)", "autoTone(amount=50.0)"]
        }
        XCTAssertEqual(expand(.productPhoto), steps("white"))
        XCTAssertEqual(expand(.productPhoto, ["background": "#FF8800"]), steps("#FF8800"))
        XCTAssertEqual(expand(.productPhoto, ["background": "  noir "]), steps("noir"))
        XCTAssertEqual(expand(.productPhoto, ["background": "  "]), steps("white"))
    }

    func testPortraitRetouch() {
        for (strength, expected) in [(0.0, (-15.0, 5.0, 8.0, 6.0)), (50, (-30, 10, 14, 11)), (100, (-45, 15, 20, 16))] {
            let args: [String: OpValue] = strength == 50 ? [:] : ["strength": .number(strength)]
            XCTAssertEqual(expand(.portraitRetouch, args), [
                "maskAdjust(amount=\(expected.0), amountMode=absolute, parameter=clarity, where=faceSkin)",
                "maskAdjust(amount=\(expected.1), parameter=skinTone, where=faceSkin)",
                "maskAdjust(amount=\(expected.2), parameter=exposure, where=eyes)",
                "maskAdjust(amount=\(expected.3), parameter=exposure, where=teeth)",
                "maskAdjust(amount=5.0, parameter=exposure, where=subject)",
                "adjust(amount=5.0, amountMode=relative, parameter=vibrance)",
            ], "strength \(strength)")
        }
        // Out of range clamps.
        XCTAssertEqual(expand(.portraitRetouch, ["strength": 250]), expand(.portraitRetouch, ["strength": 100]))
    }

    func testVlogCleanup() {
        let base = ["enhanceVoice scope=all", "removeFillers", "removeSilences"]
        XCTAssertEqual(expand(.vlogCleanup), base + ["autoCaptions"])
        XCTAssertEqual(expand(.vlogCleanup, music: true), base + ["autoCaptions", "autoDuck amount=0.6"])
        XCTAssertEqual(expand(.vlogCleanup, captions: true), base, "captions already there: none added")
        XCTAssertEqual(expand(.vlogCleanup, ["captions": false], music: true), base + ["autoDuck amount=0.6"])
    }

    func testTheWrongDomainGivesNothing() {
        XCTAssertEqual(expand(.instagramPost, domain: .video), [])
        XCTAssertEqual(expand(.productPhoto, domain: .pdf), [])
        XCTAssertEqual(expand(.vlogCleanup, domain: .photo), [])
        XCTAssertEqual(RecipeBook.domain(of: .portraitRetouch), .photo)
        XCTAssertEqual(RecipeBook.title(of: .vlogCleanup).fr, "Nettoyage vlog")
    }

    func testTheExpansionIsDeterministic() {
        var allIDs: Set<UUID> = []
        for recipe in RecipeName.allCases {
            let context = RecipeContext(domain: RecipeBook.domain(of: recipe), hasMusic: true)
            let first = RecipeBook.expand(recipe, args: [:], context: context)
            let second = RecipeBook.expand(recipe, args: [:], context: context)
            XCTAssertEqual(first, second, recipe.rawValue)
            XCTAssertFalse(first.isEmpty)
            let ids = first.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "\(recipe.rawValue): one id per step")
            XCTAssertTrue(allIDs.isDisjoint(with: ids), "\(recipe.rawValue): ids differ between recipes")
            allIDs.formUnion(ids)
            XCTAssertTrue(ids.allSatisfy { $0.uuidString.dropFirst(14).first == "4" }, "version 4 layout")
        }
    }
}
