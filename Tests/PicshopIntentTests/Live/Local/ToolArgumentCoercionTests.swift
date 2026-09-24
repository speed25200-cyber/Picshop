import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// The coercer repairs how a small model writes its arguments, never what they
/// mean; ToolInputValidator stays the judge. Every fixture goes model arguments →
/// coercer → strict JSON → validator.
final class ToolArgumentCoercionTests: XCTestCase {
    struct Fixture {
        var label: String
        var name: String
        var arguments: JSONValue
        /// The strict input expected after coercion.
        var coerced: JSONValue
        var tool: LiveToolName
        var valid = true
        var mode: EditorMode = .photo
    }

    static func steps(_ steps: JSONValue) -> JSONValue { ["steps": steps] }

    static let fixtures: [Fixture] = [
        // apply_edits
        Fixture(label: "strict", name: "apply_edits",
                arguments: steps([["action": "adjust", "parameter": "temperature", "amountMode": "relative", "amount": 15]]),
                coerced: steps([["action": "adjust", "parameter": "temperature", "amountMode": "relative", "amount": 15]]), tool: .applyEdits),
        Fixture(label: "steps as a JSON string", name: "apply_edits",
                arguments: ["steps": "[{\"action\": \"adjust\", \"parameter\": \"contrast\", \"amount\": 20}]"],
                coerced: steps([["action": "adjust", "parameter": "contrast", "amount": 20]]), tool: .applyEdits),
        Fixture(label: "single quotes and a trailing comma", name: "apply_edits",
                arguments: ["steps": "[{'action': 'adjust', 'parameter': 'contrast', 'amount': 20},]"],
                coerced: steps([["action": "adjust", "parameter": "contrast", "amount": 20]]), tool: .applyEdits),
        Fixture(label: "one step as the arguments", name: "apply_edits",
                arguments: ["action": "adjust", "parameter": "exposure", "amount": "10"],
                coerced: steps([["action": "adjust", "parameter": "exposure", "amount": 10]]), tool: .applyEdits),
        Fixture(label: "percent string", name: "apply_edits",
                arguments: steps([["action": "adjust", "parameter": "saturation", "amount": "+15 %"]]),
                coerced: steps([["action": "adjust", "parameter": "saturation", "amount": 15]]), tool: .applyEdits),
        Fixture(label: "French decimal comma", name: "apply_edits",
                arguments: steps([["action": "adjust", "parameter": "contrast", "amount": "-12,5"]]),
                coerced: steps([["action": "adjust", "parameter": "contrast", "amount": -12.5]]), tool: .applyEdits),
        Fixture(label: "enum case", name: "apply_edits",
                arguments: steps([["action": "Adjust", "parameter": "Temperature", "amount": 10]]),
                coerced: steps([["action": "adjust", "parameter": "temperature", "amount": 10]]), tool: .applyEdits),
        Fixture(label: "snake case action and spaced look", name: "apply_edits",
                arguments: steps([["action": "apply_look", "look": "Golden Hour", "amount": "60"]]),
                coerced: steps([["action": "applyLook", "look": "goldenHour", "amount": 60]]), tool: .applyEdits),
        Fixture(label: "point on the 0-1000 grid, as strings", name: "apply_edits",
                arguments: steps([["action": "removeObject", "target": "trash", "point": ["x": "640", "y": "410"]]]),
                coerced: steps([["action": "removeObject", "target": "trash", "point": ["x": 0.64, "y": 0.41]]]), tool: .applyEdits),
        Fixture(label: "point as an array", name: "apply_edits",
                arguments: steps([["action": "removeObject", "target": "pole", "point": [500, 250]]]),
                coerced: steps([["action": "removeObject", "target": "pole", "point": ["x": 0.5, "y": 0.25]]]), tool: .applyEdits),
        Fixture(label: "point as text", name: "apply_edits",
                arguments: steps([["action": "removeObject", "target": "sign", "point": "250, 750"]]),
                coerced: steps([["action": "removeObject", "target": "sign", "point": ["x": 0.25, "y": 0.75]]]), tool: .applyEdits),
        Fixture(label: "a box becomes its centre", name: "apply_edits",
                arguments: steps([["action": "removeObject", "target": "sign", "bbox_2d": [100, 200, 300, 400]]]),
                coerced: steps([["action": "removeObject", "target": "sign", "point": ["x": 0.2, "y": 0.3]]]), tool: .applyEdits),
        Fixture(label: "a point already in 0-1", name: "apply_edits",
                arguments: steps([["action": "removeObject", "target": "car", "point": ["x": 0.3, "y": 0.6]]]),
                coerced: steps([["action": "removeObject", "target": "car", "point": ["x": 0.3, "y": 0.6]]]), tool: .applyEdits),
        Fixture(label: "nulls dropped", name: "apply_edits",
                arguments: ["steps": [["action": "adjust", "parameter": "contrast", "amount": 20, "target": nil, "point": nil]], "note": nil],
                coerced: steps([["action": "adjust", "parameter": "contrast", "amount": 20]]), tool: .applyEdits),
        Fixture(label: "aspect 16:9", name: "apply_edits",
                arguments: steps([["action": "setAspect", "aspect": "16:9"]]),
                coerced: steps([["action": "setAspect", "aspect": "ratio16x9"]]), tool: .applyEdits),
        Fixture(label: "aspect carré", name: "apply_edits",
                arguments: steps([["action": "crop", "aspect": "carré"]]),
                coerced: steps([["action": "crop", "aspect": "square"]]), tool: .applyEdits),
        Fixture(label: "attributes as text", name: "apply_edits",
                arguments: steps([["action": "removeObject", "target": "person", "attributes": "red, blue shirt"]]),
                coerced: steps([["action": "removeObject", "target": "person", "attributes": ["red", "blue shirt"]]]), tool: .applyEdits),
        Fixture(label: "degrees as text", name: "apply_edits",
                arguments: steps([["action": "rotate", "degrees": "-90°"]]),
                coerced: steps([["action": "rotate", "degrees": -90]]), tool: .applyEdits),
        Fixture(label: "steps as one object", name: "apply_edits",
                arguments: ["steps": ["action": "autoEnhance"]],
                coerced: steps([["action": "autoEnhance"]]), tool: .applyEdits),
        Fixture(label: "arguments as a JSON string", name: "apply_edits",
                arguments: "{\"steps\": [{\"action\": \"adjust\", \"parameter\": \"shadows\", \"amount\": 20}]}",
                coerced: steps([["action": "adjust", "parameter": "shadows", "amount": 20]]), tool: .applyEdits),
        Fixture(label: "arguments as the step list", name: "applyEdits",
                arguments: [["action": "adjust", "parameter": "highlights", "amount": -20]],
                coerced: steps([["action": "adjust", "parameter": "highlights", "amount": -20]]), tool: .applyEdits),
        Fixture(label: "aliases param and value", name: "apply_edits",
                arguments: steps([["action": "adjust", "param": "contrast", "value": "15"]]),
                coerced: steps([["action": "adjust", "parameter": "contrast", "amount": 15]]), tool: .applyEdits),
        Fixture(label: "a number as text", name: "apply_edits",
                arguments: steps([["action": "addText", "text": 2026, "placement": "Bottom"]]),
                coerced: steps([["action": "addText", "text": "2026", "placement": "bottom"]]), tool: .applyEdits),
        Fixture(label: "video fields", name: "apply_edits",
                arguments: steps([["action": "deleteRange", "startSeconds": "0", "endSeconds": "3 s"], ["action": "setSpeed", "speed": "0,5"]]),
                coerced: steps([["action": "deleteRange", "startSeconds": 0, "endSeconds": 3], ["action": "setSpeed", "speed": 0.5]]), tool: .applyEdits, mode: .video),
        // undo
        Fixture(label: "undo with nothing", name: "undo", arguments: [:], coerced: [:], tool: .undo),
        Fixture(label: "undo count as text", name: "undo", arguments: ["count": "2"], coerced: ["count": 2], tool: .undo),
        Fixture(label: "Python True", name: "undo", arguments: ["to_original": "True"], coerced: ["to_original": true], tool: .undo),
        Fixture(label: "redo as a tool", name: "redo", arguments: [:], coerced: ["direction": "redo"], tool: .undo),
        Fixture(label: "direction case and a whole float", name: "undo", arguments: ["direction": "Redo", "count": 2.0], coerced: ["direction": "redo", "count": 2], tool: .undo),
        Fixture(label: "undo arguments null", name: "undo", arguments: nil, coerced: [:], tool: .undo),
        // compare_before_after
        Fixture(label: "seconds as text", name: "compare_before_after", arguments: ["seconds": "3"], coerced: ["seconds": 3], tool: .compareBeforeAfter),
        Fixture(label: "compare alias", name: "compare", arguments: [:], coerced: [:], tool: .compareBeforeAfter),
        Fixture(label: "seconds with a unit", name: "compare_before_after", arguments: ["seconds": "2,5 s"], coerced: ["seconds": 2.5], tool: .compareBeforeAfter),
        // propose_ideas
        Fixture(label: "ideas and steps as strings", name: "propose_ideas",
                arguments: ["ideas": "[{\"title\": \"Plus chaud\", \"why\": \"Ambiance dorée.\", \"steps\": \"[{\\\"action\\\": \\\"adjust\\\", \\\"parameter\\\": \\\"temperature\\\", \\\"amount\\\": 20}]\"}]"],
                coerced: ["ideas": [["title": "Plus chaud", "why": "Ambiance dorée.", "steps": [["action": "adjust", "parameter": "temperature", "amount": 20]]]]],
                tool: .proposeIdeas),
        Fixture(label: "one idea as the arguments", name: "propose_ideas",
                arguments: ["title": "Noir et blanc", "why": "Lumière contrastée.", "symbol": nil, "steps": [["action": "applyLook", "look": "Mono", "amount": "100"]]],
                coerced: ["ideas": [["title": "Noir et blanc", "why": "Lumière contrastée.", "steps": [["action": "applyLook", "look": "mono", "amount": 100]]]]],
                tool: .proposeIdeas),
        Fixture(label: "ideas as the list", name: "proposeIdeas",
                arguments: [["title": "Ciel dense", "why": "Le ciel est pâle.", "symbol": "cloud.sun", "steps": [["action": "selectiveAdjust", "target": "sky", "parameter": "saturation", "amount": 25]]]],
                coerced: ["ideas": [["title": "Ciel dense", "why": "Le ciel est pâle.", "symbol": "cloud.sun",
                                     "steps": [["action": "selectiveAdjust", "target": "sky", "parameter": "saturation", "amount": 25]]]]],
                tool: .proposeIdeas),
        // Still refused: the coercer does not guess meaning.
        Fixture(label: "a French parameter", name: "apply_edits", arguments: steps([["action": "adjust", "parameter": "chaleur", "amount": 10]]),
                coerced: steps([["action": "adjust", "parameter": "chaleur", "amount": 10]]), tool: .applyEdits, valid: false),
        Fixture(label: "steps that are not JSON", name: "apply_edits", arguments: ["steps": "warmer please"],
                coerced: ["steps": "warmer please"], tool: .applyEdits, valid: false),
        Fixture(label: "a point far off the grid", name: "apply_edits",
                arguments: steps([["action": "removeObject", "target": "car", "point": ["x": 5_000, "y": 5_000]]]),
                coerced: steps([["action": "removeObject", "target": "car", "point": ["x": 5, "y": 5]]]), tool: .applyEdits, valid: false),
        Fixture(label: "an unknown field", name: "undo", arguments: ["steps": 2], coerced: ["steps": 2], tool: .undo, valid: false),
        Fixture(label: "a count that is not whole", name: "undo", arguments: ["count": "1.5"], coerced: ["count": 1.5], tool: .undo, valid: false),
    ]

    func testFixturesRoundTripThroughTheValidator() throws {
        XCTAssertGreaterThanOrEqual(Self.fixtures.count, 30)
        XCTAssertEqual(Set(Self.fixtures.filter(\.valid).map(\.tool)), Set(LiveToolName.allCases), "all 4 tools")
        // A picture of the canvas's shape: the points are kept and checked.
        let grounding = ToolInputValidator.Grounding(imageAspect: 4.0 / 3.0, canvasAspect: 4.0 / 3.0)
        for fixture in Self.fixtures {
            let use = ToolArgumentCoercer.rawToolUse(id: "call_1", name: fixture.name, arguments: fixture.arguments)
            XCTAssertEqual(use.name, fixture.tool.rawValue, fixture.label)
            XCTAssertEqual(use.id, "call_1")
            let input = try JSONValue.parse(use.rawInput)
            XCTAssertEqual(input, fixture.coerced, fixture.label)
            XCTAssertEqual(use.rawInput, input.serialized(), "strict, canonical JSON: \(fixture.label)")
            var context = IntentContext(mode: fixture.mode)
            context.timelineDuration = 60
            context.clipCount = 3
            let result = ToolInputValidator(mode: fixture.mode).validate(use, context: context, grounding: grounding)
            switch (result, fixture.valid) {
            case (.success(let call), true):
                XCTAssertEqual(Self.name(of: call.tool), fixture.tool, fixture.label)
                if case .proposeIdeas(let ideas) = call.tool {
                    XCTAssertTrue(ideas.allSatisfy { !$0.steps.isEmpty && $0.source == .model }, fixture.label)
                }
            case (.failure, false):
                break
            case (.success(let call), false):
                XCTFail("\(fixture.label): accepted \(call.tool)")
            case (.failure(let error), true):
                XCTFail("\(fixture.label): refused \(error)")
            }
        }
    }

    func testTypedValues() throws {
        let redo = ToolArgumentCoercer.rawToolUse(id: "c", name: "undo", arguments: ["direction": "refaire", "to_original": "non"])
        XCTAssertEqual(try JSONValue.parse(redo.rawInput), ["direction": "redo", "to_original": false])
        let call = try ToolInputValidator(mode: .photo).validate(redo, context: .photo).get()
        XCTAssertEqual(call.tool, .undo(count: 1, redo: true, toOriginal: false))
        let seconds = ToolArgumentCoercer.rawToolUse(id: "c", name: "compare_before_after", arguments: ["seconds": "3"])
        XCTAssertEqual(try ToolInputValidator(mode: .photo).validate(seconds, context: .photo).get().tool, .compare(seconds: 3))
        XCTAssertEqual(ToolArgumentCoercer.rawToolUse(id: "c", name: " make_coffee ", arguments: [:]).name, "make_coffee", "unknown tools pass for the validator to name")
        if case .failure(.unknownTool) = ToolInputValidator(mode: .photo).validate(ToolArgumentCoercer.rawToolUse(id: "c", name: "make_coffee", arguments: [:]), context: .photo) {} else {
            XCTFail("unknown tool accepted")
        }
    }

    func testPointScaling() {
        XCTAssertEqual(ToolArgumentCoercer.point(["x": 1000, "y": 0]), ["x": 1, "y": 0])
        XCTAssertEqual(ToolArgumentCoercer.point(["x": 1003, "y": 500]), ["x": 1, "y": 0.5], "a hair outside is rounding")
        XCTAssertEqual(ToolArgumentCoercer.point("[333, 667]"), ["x": 0.333, "y": 0.667])
        XCTAssertNil(ToolArgumentCoercer.point("à gauche"))
        XCTAssertEqual(ToolArgumentCoercer.boxCenter("[0.1, 0.2, 0.3, 0.4]"), ["x": 0.2, "y": 0.3])
    }

    func testLenientJSON() {
        XCTAssertEqual(ToolArgumentCoercer.lenientJSON("{\"a\": [1, 2,],}"), ["a": [1, 2]])
        XCTAssertEqual(ToolArgumentCoercer.lenientJSON("{“a”: None}"), ["a": nil])
        XCTAssertEqual(ToolArgumentCoercer.lenientJSON("{'a': 'b'}"), ["a": "b"])
        XCTAssertNil(ToolArgumentCoercer.lenientJSON("plus chaud"))
        XCTAssertNil(ToolArgumentCoercer.lenientJSON("{broken"))
    }

    /// The filter, the coercer and the validator together, on what Qwen3.5 writes.
    func testRecordedOutputsReachTheEditor() throws {
        for (index, sample) in RecordedQwenOutputs.all.enumerated() {
            let mode: EditorMode = sample.text.contains("setSpeed") ? .video : .photo
            let output = FilteredOutput.run([sample.text])
            for case .toolCall(let name, let arguments) in output.calls {
                let use = ToolArgumentCoercer.rawToolUse(id: "call_\(index)", name: name, arguments: arguments)
                var context = IntentContext(mode: mode)
                context.timelineDuration = 60
                context.clipCount = 2
                let result = ToolInputValidator(mode: mode).validate(use, context: context)
                XCTAssertNoThrow(try result.get(), "sample \(index): \(use.rawInput)")
            }
        }
    }

    static func name(of tool: LiveTool) -> LiveToolName {
        switch tool {
        case .applyEdits: return .applyEdits
        case .undo: return .undo
        case .compare: return .compareBeforeAfter
        case .proposeIdeas: return .proposeIdeas
        }
    }
}
