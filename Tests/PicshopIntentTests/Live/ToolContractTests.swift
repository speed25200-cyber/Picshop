import Foundation
import XCTest
@testable import PicshopIntent
@testable import PicshopCore

final class RequestBuilderTests: XCTestCase {
    private let tools = [
        ClaudeToolDefinition(name: "b", description: "B", inputSchema: ["type": "object"]),
        ClaudeToolDefinition(name: "a", description: "A", inputSchema: ["type": "object"]),
    ]
    private let messages = [
        ClaudeMessage(role: .user, content: [.text("plus chaud")]),
        ClaudeMessage.system("<editor_state v=1>"),
    ]

    func testGoldenBodyAndHeaders() {
        let request = ClaudeRequestBuilder(options: .init()).streamingRequest(apiKey: "sk-ant-key", system: "SYS", tools: tools, messages: messages)
        let body = String(decoding: request.body!, as: UTF8.self)
        XCTAssertEqual(body, #"{"cache_control":{"ttl":"1h","type":"ephemeral"},"fallbacks":"default","max_tokens":2048,"messages":[{"content":[{"text":"plus chaud","type":"text"}],"role":"user"},{"content":"<editor_state v=1>","role":"system"}],"model":"claude-opus-5","output_config":{"effort":"low"},"stream":true,"system":[{"cache_control":{"ttl":"1h","type":"ephemeral"},"text":"SYS","type":"text"}],"thinking":{"type":"adaptive"},"tools":[{"description":"A","eager_input_streaming":true,"input_schema":{"type":"object"},"name":"a"},{"description":"B","eager_input_streaming":true,"input_schema":{"type":"object"},"name":"b"}]}"#)
        XCTAssertEqual(request.url, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.timeout, 30)
        XCTAssertEqual(request.headers, [
            "content-type": "application/json", "accept": "text/event-stream", "x-api-key": "sk-ant-key", "anthropic-version": "2023-06-01",
            "anthropic-beta": "server-side-fallback-2026-07-01",
        ])
        XCTAssertFalse(request.carriesImage)
    }

    func testRealBodyHasEverythingRequiredAndNothingForbidden() throws {
        let request = ClaudeRequestBuilder(options: .init()).streamingRequest(apiKey: "k", system: LivePrompt.system(mode: .photo), tools: LiveToolSchema.tools(for: .photo), messages: messages)
        let body = try JSONValue.parse(String(decoding: request.body!, as: UTF8.self))
        XCTAssertEqual(body["model"], "claude-opus-5")
        XCTAssertEqual(body["stream"], true)
        XCTAssertEqual(body["thinking"], ["type": "adaptive"])
        XCTAssertEqual(body["output_config"], ["effort": "low"])
        XCTAssertEqual(body["fallbacks"], "default")
        XCTAssertEqual(body["cache_control"], ["type": "ephemeral", "ttl": "1h"])
        XCTAssertEqual(body["system"]?.array?.first?["cache_control"], ["type": "ephemeral", "ttl": "1h"])
        let names = body["tools"]?.array?.compactMap { $0["name"]?.string }
        XCTAssertEqual(names, ["apply_edits", "compare_before_after", "propose_ideas", "undo"])
        XCTAssertTrue(body["tools"]?.array?.allSatisfy { $0["eager_input_streaming"] == true } ?? false)
        for forbidden in ["temperature", "top_p", "top_k", "tool_choice", "speed"] { XCTAssertNil(body[forbidden], forbidden) }
        XCTAssertNil(body["thinking"]?["display"])
        XCTAssertNotEqual(body["messages"]?.array?.last?["role"], "assistant", "never a prefilled assistant turn")
    }

    func testNoBetaHeaderWithoutFallbacks() throws {
        var options = ClaudeRequestOptions()
        options.useServerFallbacks = false
        let request = ClaudeRequestBuilder(options: options).streamingRequest(apiKey: "k", system: "S", tools: tools, messages: messages)
        XCTAssertNil(request.headers["anthropic-beta"])
        let body = try JSONValue.parse(String(decoding: request.body!, as: UTF8.self))
        XCTAssertNil(body["fallbacks"])
    }

    func testCarriesImageFollowsTheLastUserMessage() {
        let image = ClaudeMessage(role: .user, content: [.image(.base64(mediaType: "image/jpeg", data: "AA==")), .text("et là ?")])
        let builder = ClaudeRequestBuilder(options: .init())
        XCTAssertTrue(builder.streamingRequest(apiKey: "k", system: "S", tools: [], messages: [image, .system("s")]).carriesImage)
        let later = [image, ClaudeMessage(role: .assistant, content: [.text("Ok.")]), ClaudeMessage(role: .user, content: [.text("merci")])]
        XCTAssertFalse(builder.streamingRequest(apiKey: "k", system: "S", tools: [], messages: later).carriesImage)
    }

    func testWarmUpShape() throws {
        let request = ClaudeRequestBuilder(options: .init()).warmUpRequest(apiKey: "k", system: "SYS", tools: tools)
        let body = String(decoding: request.body!, as: UTF8.self)
        XCTAssertEqual(body, #"{"max_tokens":0,"messages":[{"content":"warmup","role":"user"}],"model":"claude-opus-5","output_config":{"effort":"low"},"system":[{"cache_control":{"ttl":"1h","type":"ephemeral"},"text":"SYS","type":"text"}],"thinking":{"type":"adaptive"},"tools":[{"description":"A","eager_input_streaming":true,"input_schema":{"type":"object"},"name":"a"},{"description":"B","eager_input_streaming":true,"input_schema":{"type":"object"},"name":"b"}]}"#)
        XCTAssertNil(request.headers["anthropic-beta"])
        XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(request.method, "POST")
    }

    func testKeyCheckRequest() {
        let request = ClaudeRequestBuilder.keyCheckRequest(apiKey: "sk-ant-x")
        XCTAssertEqual(request.url, "https://api.anthropic.com/v1/models/claude-opus-5")
        XCTAssertEqual(request.method, "GET")
        XCTAssertNil(request.body)
        XCTAssertEqual(request.headers["x-api-key"], "sk-ant-x")
        XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
    }

    func testCostEstimate() {
        var usage = ClaudeUsage()
        usage.inputTokens = 1_000_000
        usage.outputTokens = 1_000_000
        usage.cacheReadInputTokens = 1_000_000
        usage.cacheCreationInputTokens = 1_000_000
        XCTAssertEqual(LiveCostEstimator.dollars(usage), 5 + 25 + 0.5 + 10, accuracy: 1e-9)
    }
}

final class LiveToolSchemaTests: XCTestCase {
    func testActionEnumEqualsAllowedActions() {
        for mode in [EditorMode.photo, .video] {
            let step = LiveToolSchema.stepSchema(for: mode)
            let actions = step["properties"]?["action"]?["enum"]?.array?.compactMap(\.string)
            XCTAssertEqual(actions, LiveToolSchema.allowedActions(for: mode).map(\.rawValue))
            for meta in [IntentAction.undo, .redo, .revert, .compare, .help, .export, .share, .chooseCandidate, .unknown, .describe] {
                XCTAssertFalse(actions?.contains(meta.rawValue) ?? true, "\(meta)")
            }
        }
        XCTAssertFalse(LiveToolSchema.allowedActions(for: .photo).contains(.split))
        XCTAssertFalse(LiveToolSchema.allowedActions(for: .video).contains(.moveObject))
    }

    func testVideoFieldsOnlyInTheVideoSchema() {
        let photo = LiveToolSchema.stepSchema(for: .photo)["properties"]?.object?.keys.sorted() ?? []
        let video = LiveToolSchema.stepSchema(for: .video)["properties"]?.object?.keys.sorted() ?? []
        for field in LiveToolSchema.videoFields {
            XCTAssertFalse(photo.contains(field), field)
            XCTAssertTrue(video.contains(field), field)
        }
        XCTAssertTrue(photo.contains("point"))
        XCTAssertTrue(photo.contains("attributes"))
    }

    func testToolsAreSortedEagerAndDeterministic() {
        let tools = LiveToolSchema.tools(for: .photo)
        XCTAssertEqual(tools.map(\.name), ["apply_edits", "compare_before_after", "propose_ideas", "undo"])
        XCTAssertTrue(tools.allSatisfy(\.eagerInputStreaming))
        XCTAssertEqual(tools.map { $0.json.serialized() }, LiveToolSchema.tools(for: .photo).map { $0.json.serialized() })
        for tool in tools {
            XCTAssertEqual(tool.inputSchema["additionalProperties"], false, tool.name)
            XCTAssertNoThrow(try JSONValue.parse(tool.json.serialized()))
        }
        XCTAssertTrue(tools[0].description.contains("point (x and y from 0 to 1"))
        XCTAssertTrue(tools[3].description.contains("c'est trop"))
        XCTAssertEqual(tools[2].inputSchema["properties"]?["ideas"]?["maxItems"], 3)
    }

    /// Every enum value in the schema survives the normalizer.
    func testEveryEnumValueNormalizes() {
        let photo = IntentContext.photo
        let video = IntentContext(mode: .video, clipCount: 3, timelineDuration: 30)
        for action in LiveToolSchema.allowedActions(for: .photo) {
            XCTAssertNotNil(IntentNormalizer.normalize(Self.minimalStep(action), context: photo), "photo \(action)")
        }
        for action in LiveToolSchema.allowedActions(for: .video) {
            XCTAssertNotNil(IntentNormalizer.normalize(Self.minimalStep(action), context: video), "video \(action)")
        }
        for hint in SpatialHint.allCases {
            XCTAssertEqual(IntentNormalizer.normalize(RawIntentStep(action: "removeObject", target: "dog", spatialHint: hint.rawValue), context: photo)?.target?.spatialHint, hint)
        }
        for parameter in AdjustmentParameter.allCases {
            XCTAssertEqual(IntentNormalizer.normalize(RawIntentStep(action: "adjust", parameter: parameter.rawValue, amount: 10), context: photo)?.parameter, parameter)
        }
        for look in FilterPreset.allCases {
            XCTAssertEqual(IntentNormalizer.normalize(RawIntentStep(action: "applyLook", look: look.rawValue), context: photo)?.look, look)
        }
        for aspect in AspectPreset.allCases {
            XCTAssertEqual(IntentNormalizer.normalize(RawIntentStep(action: "crop", aspect: aspect.rawValue), context: photo)?.aspect, aspect)
        }
        for placement in TextElement.Placement.allCases {
            XCTAssertEqual(IntentNormalizer.normalize(RawIntentStep(action: "addText", text: "Hi", placement: placement.rawValue), context: photo)?.placement, placement)
        }
        for transition in TransitionKind.allCases {
            XCTAssertEqual(IntentNormalizer.normalize(RawIntentStep(action: "addTransition", transition: transition.rawValue), context: video)?.transition, transition)
        }
        for axis in ["horizontal", "vertical"] {
            XCTAssertEqual(IntentNormalizer.normalize(RawIntentStep(action: "flip", flipAxis: axis), context: photo)?.flipAxis?.rawValue, axis)
        }
        for scope in ["current", "all", "selection"] {
            XCTAssertEqual(IntentNormalizer.normalize(RawIntentStep(action: "mute", scope: scope), context: video)?.scope.rawValue, scope)
        }
    }

    /// The smallest step the validator accepts for an action.
    static func minimalStep(_ action: IntentAction) -> RawIntentStep {
        var step = RawIntentStep(action: action.rawValue)
        switch action {
        case .removeObject, .moveObject: step.target = "dog"
        case .recolor: step.target = "car"; step.color = "red"
        case .selectiveAdjust: step.target = "sky"; step.parameter = "saturation"
        case .adjust: step.parameter = "brightness"
        case .applyLook: step.look = "mono"
        case .addText, .textBehind: step.text = "Été"
        case .trim, .deleteRange: step.startSeconds = 1; step.endSeconds = 2
        case .seek: step.seconds = 2
        case .setSpeed: step.speed = 2
        case .addTransition: step.transition = "crossDissolve"
        case .translateCaptions: step.text = "en"
        default: break
        }
        return step
    }
}

final class ToolInputValidatorTests: XCTestCase {
    private let photo = ToolInputValidator(mode: .photo)
    private let video = ToolInputValidator(mode: .video)
    private let videoContext = IntentContext(mode: .video, clipCount: 3, playheadSeconds: 2, timelineDuration: 10)

    private func edits(_ steps: String, validator: ToolInputValidator? = nil, context: IntentContext = .photo,
                       grounding: ToolInputValidator.Grounding = .init()) -> Result<LiveToolCall, ToolValidationError> {
        (validator ?? photo).validate(RawToolUse(id: "t", name: "apply_edits", rawInput: #"{"steps":["# + steps + "]}", blockIndex: 0), context: context, grounding: grounding)
    }

    private func problems(_ result: Result<LiveToolCall, ToolValidationError>) -> [String] {
        if case .failure(.problems(let problems)) = result { return problems }
        return []
    }

    private func intents(_ result: Result<LiveToolCall, ToolValidationError>) -> [EditIntent] {
        if case .success(let call) = result, case .applyEdits(let intents) = call.tool { return intents }
        return []
    }

    func testValidInputMapsToIntents() {
        let result = edits(#"{"action":"adjust","parameter":"temperature","amountMode":"relative","amount":15},{"action":"removeObject","target":"dog","spatialHint":"left"}"#)
        let mapped = intents(result)
        XCTAssertEqual(mapped.map(\.action), [.adjust, .removeObject])
        XCTAssertEqual(mapped[0].amount, .relative(0.15))
        XCTAssertEqual(mapped[1].target?.label, "dog")
        XCTAssertEqual(mapped[1].target?.spatialHint, .left)
    }

    func testStrictJSONAndItsEscapedWrapper() throws {
        let raw = #"{"steps":[{"action":"adj"#
        let result = photo.validate(RawToolUse(id: "t", name: "apply_edits", rawInput: raw, blockIndex: 0), context: .photo)
        XCTAssertEqual(result, .failure(.invalidJSON(raw: raw)))
        let encoded = ToolResultEncoder.invalid(.invalidJSON(raw: raw))
        XCTAssertTrue(encoded.isError)
        XCTAssertEqual(encoded.payload.serialized(), #"{"INVALID_JSON":"{\"steps\":[{\"action\":\"adj"}"#)
        XCTAssertEqual(try JSONValue.parse(encoded.payload.serialized())["INVALID_JSON"]?.string, raw)
        XCTAssertEqual(photo.validate(RawToolUse(id: "t", name: "apply_edits", rawInput: "{\"steps\":[],}", blockIndex: 0), context: .photo),
                       .failure(.invalidJSON(raw: "{\"steps\":[],}")))
    }

    func testTopLevelAndToolName() {
        XCTAssertEqual(photo.validate(RawToolUse(id: "t", name: "apply_edits", rawInput: "[1]", blockIndex: 0), context: .photo), .failure(.notAnObject))
        XCTAssertEqual(photo.validate(RawToolUse(id: "t", name: "inspect_image", rawInput: "{}", blockIndex: 0), context: .photo), .failure(.unknownTool("inspect_image")))
        XCTAssertEqual(problems(photo.validate(RawToolUse(id: "t", name: "apply_edits", rawInput: #"{"steps":[{"action":"autoEnhance"}],"why":"x"}"#, blockIndex: 0), context: .photo)),
                       ["input.why: unknown field"])
    }

    func testUnknownKeysAtEveryLevel() {
        XCTAssertEqual(problems(edits(#"{"action":"autoEnhance","foo":1}"#)), ["steps[0].foo: unknown field"])
        XCTAssertEqual(problems(edits(#"{"action":"removeObject","target":"dog","point":{"x":0.5,"y":0.5,"z":1}}"#, grounding: .init(imageAspect: 1, canvasAspect: 1))),
                       ["steps[0].point.z: unknown field"])
        XCTAssertEqual(problems(edits(#"{"action":"autoEnhance","seconds":2}"#)), ["steps[0].seconds: unknown field"], "video fields are unknown in a photo")
        XCTAssertEqual(problems(edits(#"{"action":"autoEnhance","replacement":"x"}"#)), ["steps[0].replacement: unknown field"])
    }

    func testTypes() {
        XCTAssertEqual(problems(edits(#"{"action":"adjust","parameter":"brightness","amount":"10"}"#)), ["steps[0].amount: must be a number"])
        XCTAssertEqual(problems(edits(#"{"action":"removeObject","target":"dog","ordinal":1.5}"#)), ["steps[0].ordinal: must be an integer"])
        XCTAssertEqual(problems(edits(#"{"action":"removeObject","target":"dog","all":"yes"}"#)), ["steps[0].all: must be true or false"])
        XCTAssertEqual(problems(edits(#"{"action":"deleteClip","clipNumber":1.5}"#, validator: video, context: videoContext)), ["steps[0].clipNumber: must be an integer"])
        XCTAssertEqual(problems(edits(#"{"action":"removeObject","target":7}"#)).first, "steps[0].target: must be a string")
        XCTAssertEqual(problems(edits(#"{"action":"removeObject","target":"dog","attributes":"red"}"#)), ["steps[0].attributes: must be an array of strings"])
        XCTAssertEqual(problems(edits(#"{"action":"autoEnhance","amount":null}"#)), [], "null is absent")
    }

    func testEnumsMatchExactly() {
        XCTAssertEqual(problems(edits(#"{"action":"adjust","parameter":"warmth","amount":10}"#)).first, "steps[0].parameter: 'warmth' is not a valid value")
        XCTAssertEqual(problems(edits(#"{"action":"applyLook","look":"noir et blanc"}"#)).first, "steps[0].look: 'noir et blanc' is not a valid value")
        XCTAssertEqual(problems(edits(#"{"action":"remove","target":"dog"}"#)), ["steps[0].action: 'remove' is not a valid action"])
        XCTAssertEqual(problems(edits(#"{"action":"removeObject","target":"dog","spatialHint":"gauche"}"#)).first, "steps[0].spatialHint: 'gauche' is not a valid value")
        XCTAssertEqual(problems(edits(#"{"action":"adjust","parameter":"contrast","amountMode":"more","amount":10}"#)).first, "steps[0].amountMode: 'more' is not a valid value")
        XCTAssertEqual(problems(edits(#"{"action":"flip","flipAxis":"diagonal"}"#)).first, "steps[0].flipAxis: 'diagonal' is not a valid value")
        XCTAssertEqual(problems(edits(#"{"action":"mute","scope":"everything"}"#, validator: video, context: videoContext)).first, "steps[0].scope: 'everything' is not a valid value")
    }

    /// One case per AmountUnit row: the range edge passes, one step past it fails.
    func testAmountUnitRanges() {
        let rows: [(String, String, Double, Double, Bool)] = [
            ("adjust", #""parameter":"brightness","amountMode":"absolute","#, 100, 101, false),
            ("adjust", #""parameter":"brightness","amountMode":"relative","#, -100, -101, false),
            ("selectiveAdjust", #""target":"sky","parameter":"saturation","amountMode":"relative","#, 100, 150, false),
            ("applyLook", #""look":"mono","amountMode":"absolute","#, 100, 120, false),
            ("blurBackground", #""amountMode":"absolute","#, 0, -10, false),
            ("autoEnhance", #""amountMode":"absolute","#, 100, 130, false),
            ("denoise", #""amountMode":"absolute","#, 100, 101, false),
            ("sharpen", #""amountMode":"absolute","#, 100, 250, false),
            ("setVolume", #""amountMode":"absolute","#, 200, 250, true),
            ("moveObject", #""target":"car","#, 0.5, 0.6, false),
            ("moveObject", #""target":"car","#, 0.05, 0.02, false),
            ("removeSilences", "", 0.45, 0.5, true),
            ("autoDuck", "", 0.9, 0.95, true),
            ("recolor", #""target":"car","color":"red","#, 1, 1.2, false),
            ("splitScenes", "", 1, 1.5, true),
            ("fadeAudio", "", 10, 12, true),
            ("highlights", "", 300, 400, true),
            ("highlights", "", 5, 3, true),
            ("upscale", "", 4, 5, false),
            ("upscale", "", 2, 1, false),
            ("punchIns", "", 1.5, 2, true),
            ("speedRamp", "", 1, 1.5, true),
        ]
        for (action, fields, good, bad, isVideo) in rows {
            let validator = isVideo ? video : photo
            let context = isVideo ? videoContext : .photo
            let okResult = edits(#"{"action":"\#(action)",\#(fields)"amount":\#(ToolInputValidator.format(good))}"#, validator: validator, context: context)
            XCTAssertEqual(problems(okResult), [], "\(action) \(good)")
            XCTAssertFalse(intents(okResult).isEmpty, "\(action) \(good)")
            let badProblems = problems(edits(#"{"action":"\#(action)",\#(fields)"amount":\#(ToolInputValidator.format(bad))}"#, validator: validator, context: context))
            XCTAssertEqual(badProblems.count, 1, "\(action) \(bad)")
            XCTAssertTrue(badProblems.first?.hasPrefix("steps[0].amount: \(ToolInputValidator.format(bad)) is outside") ?? false, "\(action): \(badProblems)")
        }
        // punchIns 0 takes the zoom cuts off; setSpeed goes through speed.
        XCTAssertEqual(intents(edits(#"{"action":"punchIns","amount":0}"#, validator: video, context: videoContext)).first?.amount, .absolute(0))
        XCTAssertEqual(problems(edits(#"{"action":"setSpeed","speed":9}"#, validator: video, context: videoContext)), ["steps[0].speed: 9 is outside 0.1...8"])
        XCTAssertEqual(intents(edits(#"{"action":"setSpeed","speed":0.5}"#, validator: video, context: videoContext)).first?.amount, .absolute(0.5))
    }

    func testOtherRanges() {
        XCTAssertEqual(problems(edits(#"{"action":"rotate","degrees":720}"#)), ["steps[0].degrees: 720 is outside -360...360"])
        XCTAssertEqual(problems(edits(#"{"action":"split","seconds":11}"#, validator: video, context: videoContext)), ["steps[0].seconds: 11 is outside 0...10.5"])
        XCTAssertEqual(problems(edits(#"{"action":"split","seconds":10.4}"#, validator: video, context: videoContext)), [])
        XCTAssertEqual(problems(edits(#"{"action":"trim","startSeconds":5,"endSeconds":2}"#, validator: video, context: videoContext)), ["steps[0].endSeconds: must be after startSeconds"])
        XCTAssertEqual(problems(edits(#"{"action":"deleteClip","clipNumber":0}"#, validator: video, context: videoContext)).first, "steps[0].clipNumber: 0 is outside 1...3 (or -1 for the last)")
        XCTAssertEqual(problems(edits(#"{"action":"deleteClip","clipNumber":5}"#, validator: video, context: videoContext)).count, 1)
        XCTAssertEqual(problems(edits(#"{"action":"deleteClip","clipNumber":-1}"#, validator: video, context: videoContext)), [])
        XCTAssertEqual(problems(edits(#"{"action":"removeObject","target":"dog","ordinal":21}"#)), ["steps[0].ordinal: 21 is outside 1...20"])
        XCTAssertEqual(problems(edits(#"{"action":"removeObject","target":"dog","point":{"x":1.2,"y":0.5}}"#, grounding: .init(imageAspect: 1, canvasAspect: 1))),
                       ["steps[0].point: x and y must be within 0...1"])
        var pending = IntentContext.photo
        let dog = ObjectCandidate(label: "dog", boundingBox: PSRect(x: 0, y: 0, width: 0.2, height: 0.2), confidence: 0.9)
        pending.pendingClarification = ClarificationRequest(question: "Lequel ?", candidates: [dog, dog], pendingIntent: EditIntent(action: .removeObject))
        XCTAssertEqual(problems(edits(#"{"action":"moveObject","target":"dog","choiceIndex":3}"#, context: pending)), ["steps[0].choiceIndex: 3 is outside 1...2"])
        XCTAssertEqual(problems(edits(#"{"action":"moveObject","target":"dog","choiceIndex":2}"#, context: pending)), [])
    }

    func testStrings() {
        XCTAssertEqual(problems(edits(#"{"action":"removeObject","target":"  "}"#)).first, "steps[0].target: empty")
        XCTAssertEqual(problems(edits(#"{"action":"removeObject","target":"\#(String(repeating: "a", count: 41))"}"#)).first, "steps[0].target: longer than 40 characters")
        XCTAssertEqual(problems(edits(#"{"action":"addText","text":"a\u0007b"}"#)), ["steps[0].text: control characters"])
        XCTAssertEqual(problems(edits(#"{"action":"removeObject","target":"shirt","attributes":["red","blue","big","old"]}"#)), ["steps[0].attributes: at most 3"])
        XCTAssertEqual(problems(edits(#"{"action":"recolor","target":"car","color":"sparkly"}"#)), ["steps[0].color: 'sparkly' is not a colour name or #RRGGBB"])
        XCTAssertEqual(problems(edits(##"{"action":"recolor","target":"car","color":"#FF0000"}"##)), [])
        XCTAssertEqual(problems(edits(#"{"action":"replaceBackground","background":"plaid"}"#)), ["steps[0].background: 'plaid' is not a colour, transparent or blur"])
        XCTAssertEqual(problems(edits(#"{"action":"replaceBackground","background":"transparent"},{"action":"replaceBackground","background":"blur"}"#)), [])
    }

    func testActionsTheModeOrLiveDoesNotAllow() {
        XCTAssertEqual(problems(edits(#"{"action":"split","seconds":1}"#)), ["steps[0].seconds: unknown field", "steps[0].action: split is not available for a photo"])
        XCTAssertEqual(problems(edits(#"{"action":"split"}"#)), ["steps[0].action: split is not available for a photo"])
        XCTAssertEqual(problems(edits(#"{"action":"undo"}"#)), ["steps[0].action: use the undo tool for undo"])
        XCTAssertEqual(problems(edits(#"{"action":"compare"}"#)), ["steps[0].action: use the compare_before_after tool"])
        XCTAssertEqual(problems(edits(#"{"action":"export"}"#)), ["steps[0].action: export is not an editing step"])
        XCTAssertEqual(problems(edits(#"{"action":"moveObject","target":"dog"}"#, validator: video, context: videoContext)),
                       ["steps[0].action: moveObject is not available for a video"])
    }

    func testRequiredFields() {
        let cases: [(String, Bool, String)] = [
            (#"{"action":"removeObject"}"#, false, "steps[0]: removeObject needs target or point"),
            (#"{"action":"recolor","target":"car"}"#, false, "steps[0]: recolor needs color"),
            (#"{"action":"selectiveAdjust","target":"sky"}"#, false, "steps[0]: selectiveAdjust needs parameter"),
            (#"{"action":"adjust","amount":10}"#, false, "steps[0]: adjust needs parameter"),
            (#"{"action":"applyLook"}"#, false, "steps[0]: applyLook needs look"),
            (#"{"action":"addText"}"#, false, "steps[0]: addText needs text"),
            (#"{"action":"trim","startSeconds":1}"#, true, "steps[0]: trim needs startSeconds and endSeconds"),
            (#"{"action":"deleteRange","endSeconds":3}"#, true, "steps[0]: deleteRange needs startSeconds and endSeconds"),
            (#"{"action":"seek"}"#, true, "steps[0]: seek needs seconds"),
            (#"{"action":"setSpeed","amount":2}"#, true, "steps[0]: setSpeed needs speed"),
            (#"{"action":"addTransition"}"#, true, "steps[0]: addTransition needs transition"),
            (#"{"action":"translateCaptions","text":"klingon"}"#, true, "steps[0].text: translateCaptions needs one of de, en, es, fr, it, ja, ko, pt, zh"),
        ]
        for (step, isVideo, expected) in cases {
            XCTAssertEqual(problems(edits(step, validator: isVideo ? video : photo, context: isVideo ? videoContext : .photo)), [expected], step)
        }
        XCTAssertEqual(problems(edits(#"{"action":"translateCaptions","text":"en"}"#, validator: video, context: videoContext)), [])
    }

    func testStepCountAndAtomicity() {
        XCTAssertEqual(problems(photo.validate(RawToolUse(id: "t", name: "apply_edits", rawInput: #"{"steps":[]}"#, blockIndex: 0), context: .photo)),
                       ["steps: 0 steps, expected 1...6"])
        let seven = Array(repeating: #"{"action":"autoEnhance"}"#, count: 7).joined(separator: ",")
        XCTAssertEqual(problems(edits(seven)), ["steps: 7 steps, expected 1...6"])
        XCTAssertEqual(problems(photo.validate(RawToolUse(id: "t", name: "apply_edits", rawInput: "{}", blockIndex: 0), context: .photo)), ["steps: required"])
        // One bad step: nothing runs.
        let result = edits(#"{"action":"autoEnhance"},{"action":"adjust","parameter":"brightness","amount":250},{"action":"rotate","degrees":90}"#)
        guard case .failure(.problems(let list)) = result else { return XCTFail("atomic failure expected") }
        XCTAssertEqual(list, ["steps[1].amount: 250 is outside -100...100"])
    }

    func testAtMostEightProblems() {
        let bad = Array(repeating: #"{"action":"adjust","parameter":"brightness","amount":999}"#, count: 6).joined(separator: ",")
        let many = edits(bad.replacingOccurrences(of: #""amount":999"#, with: #""amount":999,"x":1"#))
        XCTAssertEqual(problems(many).count, 8)
        guard case .failure(let error) = many else { return XCTFail() }
        let payload = ToolResultEncoder.invalid(error).payload
        XCTAssertEqual(payload["error"], "invalid_input")
        XCTAssertEqual(payload["hint"], "Fix these fields and call the tool again.")
        XCTAssertEqual(payload["problems"]?.array?.count, 8)
    }

    func testPointsAndStaleImages() {
        let pointOnly = #"{"action":"removeObject","point":{"x":0.4,"y":0.6},"attributes":["red"]}"#
        let same = ToolInputValidator.Grounding(imageAspect: 4.0 / 3.0, canvasAspect: 4032.0 / 3024.0)
        let target = intents(edits(pointOnly, grounding: same)).first?.target
        XCTAssertEqual(target?.label, "object")
        XCTAssertEqual(target?.point, PSPoint(x: 0.4, y: 0.6))
        XCTAssertEqual(target?.attributes, ["red"])
        // The picture was rotated since Claude saw it: the point is dropped silently.
        let rotated = ToolInputValidator.Grounding(imageAspect: 4.0 / 3.0, canvasAspect: 3.0 / 4.0)
        XCTAssertEqual(problems(edits(pointOnly, grounding: rotated)), ["steps[0]: removeObject needs target or point"])
        let withTarget = intents(edits(#"{"action":"removeObject","target":"lamp","point":{"x":0.4,"y":0.6}}"#, grounding: rotated)).first?.target
        XCTAssertEqual(withTarget?.label, "lamp")
        XCTAssertNil(withTarget?.point)
        XCTAssertFalse(ToolInputValidator.Grounding(imageAspect: nil, canvasAspect: 1).keepsPoints, "no image seen, no point")
    }

    func testOtherTools() {
        func call(_ name: String, _ input: String) -> Result<LiveToolCall, ToolValidationError> {
            photo.validate(RawToolUse(id: "t", name: name, rawInput: input, blockIndex: 0), context: .photo)
        }
        XCTAssertEqual(try? call("undo", "{}").get().tool, .undo(count: 1, redo: false, toOriginal: false))
        XCTAssertEqual(try? call("undo", #"{"count":2,"direction":"redo"}"#).get().tool, .undo(count: 2, redo: true, toOriginal: false))
        XCTAssertEqual(try? call("undo", #"{"to_original":true}"#).get().tool, .undo(count: 1, redo: false, toOriginal: true))
        XCTAssertEqual(problems(call("undo", #"{"count":0}"#)), ["count: 0 is outside 1...20"])
        XCTAssertEqual(problems(call("undo", #"{"direction":"sideways"}"#)), ["direction: 'sideways' is not one of undo, redo"])
        XCTAssertEqual(try? call("compare_before_after", "{}").get().tool, .compare(seconds: 2))
        XCTAssertEqual(problems(call("compare_before_after", #"{"seconds":10}"#)), ["seconds: 10 is outside 1...5"])
        XCTAssertEqual(problems(call("compare_before_after", #"{"style":"split"}"#)), ["input.style: unknown field"])
    }

    func testIdeasAreCheckedOneByOne() throws {
        let input = #"{"ideas":[{"title":"Noir et blanc","why":"Des formes fortes.","symbol":"circle.lefthalf.filled","steps":[{"action":"applyLook","look":"mono"}]},{"title":"Cassé","why":"x","steps":[{"action":"teleport"}]},{"title":"Plus chaud","why":"Lumière du soir.","symbol":"flame","steps":[{"action":"adjust","parameter":"temperature","amount":20}]}]}"#
        let result = photo.validate(RawToolUse(id: "t", name: "propose_ideas", rawInput: input, blockIndex: 0), context: .photo)
        guard case .success(let call) = result, case .proposeIdeas(let ideas) = call.tool else { return XCTFail("\(result)") }
        XCTAssertEqual(ideas.count, 3)
        XCTAssertEqual(ideas.map { $0.steps.isEmpty }, [false, true, false])
        XCTAssertEqual(ideas[2].symbol, "sparkles", "unknown symbols are sanitized, not refused")
        XCTAssertTrue(ideas.allSatisfy { $0.source == .claude })
        XCTAssertEqual(problems(photo.validate(RawToolUse(id: "t", name: "propose_ideas", rawInput: #"{"ideas":[]}"#, blockIndex: 0), context: .photo)),
                       ["ideas: 0 ideas, expected 1...3"])
        let four = "{\"ideas\":[" + Array(repeating: #"{"title":"A","why":"B","steps":[{"action":"autoEnhance"}]}"#, count: 4).joined(separator: ",") + "]}"
        XCTAssertEqual(problems(photo.validate(RawToolUse(id: "t", name: "propose_ideas", rawInput: four, blockIndex: 0), context: .photo)),
                       ["ideas: 4 ideas, expected 1...3"])
    }

    func testTypedStepsGetTheSameChecks() {
        XCTAssertEqual(photo.steps(raw: [RawIntentStep(action: "adjust", parameter: "brightness", amount: 250)], context: .photo),
                       .failure(.problems(["steps[0].amount: 250 is outside -100...100"])))
        XCTAssertEqual(photo.steps(raw: [RawIntentStep(action: "split", seconds: 3)], context: .photo),
                       .failure(.problems(["steps[0].action: split is not available for a photo"])))
        guard case .success(let intents) = photo.steps(raw: [RawIntentStep(action: "adjust", parameter: "brightness", amount: 20)], context: .photo) else { return XCTFail() }
        XCTAssertEqual(intents.first?.amount, .relative(0.2))
        XCTAssertEqual(photo.steps(raw: [], context: .photo), .failure(.problems(["steps: at least 1 step"])))
    }
}

/// The amount-unit fix: each model amount reaches the executor in the unit it reads.
final class UnitsFixTests: XCTestCase {
    private func amount(_ step: RawIntentStep, _ context: IntentContext = .photo) -> AmountSpec? {
        IntentNormalizer.normalize(step, context: context)?.amount
    }

    private let video = IntentContext(mode: .video, clipCount: 1, timelineDuration: 60)

    func testTheFourReportedCases() {
        XCTAssertEqual(amount(RawIntentStep(action: "upscale", amount: 3)), .absolute(3))
        XCTAssertEqual(amount(RawIntentStep(action: "fadeAudio", amount: 2), video), .absolute(2))
        XCTAssertEqual(amount(RawIntentStep(action: "punchIns", amount: 1.2), video), .absolute(1.2))
        XCTAssertEqual(amount(RawIntentStep(action: "adjust", parameter: "brightness", amount: 20)), .relative(0.2))
    }

    func testEveryTableRow() {
        XCTAssertEqual(AmountUnit.for(.adjust), .percent(-100...100))
        XCTAssertEqual(AmountUnit.for(.selectiveAdjust), .percent(-100...100))
        for action in [IntentAction.applyLook, .blurBackground, .autoEnhance, .denoise, .sharpen] { XCTAssertEqual(AmountUnit.for(action), .percent(0...100), "\(action)") }
        XCTAssertEqual(AmountUnit.for(.setVolume), .percent(0...200))
        XCTAssertEqual(AmountUnit.for(.moveObject), .fraction(0.05...0.5))
        XCTAssertEqual(AmountUnit.for(.removeSilences), .fraction(0.2...0.45))
        XCTAssertEqual(AmountUnit.for(.autoDuck), .fraction(0...0.9))
        XCTAssertEqual(AmountUnit.for(.recolor), .fraction(0...1))
        XCTAssertEqual(AmountUnit.for(.splitScenes), .fraction(0...1))
        XCTAssertEqual(AmountUnit.for(.fadeAudio), .seconds(0...10))
        XCTAssertEqual(AmountUnit.for(.highlights), .seconds(5...300))
        XCTAssertEqual(AmountUnit.for(.upscale), .multiplier(2...4))
        XCTAssertEqual(AmountUnit.for(.punchIns), .multiplier(1...1.5))
        XCTAssertEqual(AmountUnit.for(.speedRamp), .multiplier(0.1...1))
        XCTAssertEqual(AmountUnit.for(.setSpeed), .multiplier(0.1...8))
        XCTAssertNil(AmountUnit.for(.rotate))
    }

    func testPercentRows() {
        XCTAssertEqual(amount(RawIntentStep(action: "selectiveAdjust", target: "face", parameter: "noiseReduction", amount: 30)), .relative(0.3))
        XCTAssertEqual(amount(RawIntentStep(action: "adjust", parameter: "contrast", amountMode: "absolute", amount: 1)), .absolute(0.01), "1 means 1 %")
        XCTAssertEqual(amount(RawIntentStep(action: "applyLook", amountMode: "absolute", amount: 80, look: "mono")), .absolute(0.8))
        XCTAssertEqual(amount(RawIntentStep(action: "blurBackground", amountMode: "absolute", amount: 60)), .absolute(0.6))
        XCTAssertEqual(amount(RawIntentStep(action: "autoEnhance", amount: 70)), .relative(0.7))
        XCTAssertEqual(amount(RawIntentStep(action: "denoise", amountMode: "absolute", amount: 40)), .absolute(0.4))
        XCTAssertEqual(amount(RawIntentStep(action: "sharpen", amount: 30)), .relative(0.3))
        XCTAssertEqual(amount(RawIntentStep(action: "setVolume", amountMode: "absolute", amount: 150), video), .absolute(1.5), "divided by 100, not clamped to 1")
        XCTAssertEqual(amount(RawIntentStep(action: "setVolume", amountMode: "absolute", amount: 400), video), .absolute(2))
        XCTAssertEqual(amount(RawIntentStep(action: "adjust", parameter: "contrast", amountMode: "multiplier", amount: 1.5)), .multiplier(1.5))
    }

    func testFractionSecondsAndMultiplierRows() {
        XCTAssertEqual(amount(RawIntentStep(action: "moveObject", target: "car", amount: 0.08)), .absolute(0.08))
        XCTAssertEqual(amount(RawIntentStep(action: "moveObject", target: "car", amount: 15))?.value ?? 0, 0.15, accuracy: 1e-9)
        XCTAssertEqual(amount(RawIntentStep(action: "removeSilences", amount: 0.3), video), .absolute(0.3))
        XCTAssertEqual(amount(RawIntentStep(action: "autoDuck", amount: 0), video), .absolute(0))
        XCTAssertEqual(amount(RawIntentStep(action: "recolor", target: "car", amount: 0.5, color: "red")), .absolute(0.5))
        XCTAssertEqual(amount(RawIntentStep(action: "splitScenes", amount: 0.7), video), .absolute(0.7))
        XCTAssertEqual(amount(RawIntentStep(action: "fadeAudio", amount: 30), video), .absolute(10))
        XCTAssertEqual(amount(RawIntentStep(action: "highlights", seconds: 45), video), .absolute(45))
        XCTAssertEqual(amount(RawIntentStep(action: "highlights", amount: 900), video), .absolute(300))
        XCTAssertEqual(amount(RawIntentStep(action: "upscale", amount: 8)), .absolute(4))
        XCTAssertEqual(amount(RawIntentStep(action: "punchIns", amount: 0), video), .absolute(0), "0 removes the zoom cuts")
        XCTAssertEqual(amount(RawIntentStep(action: "speedRamp", amount: 0.3), video), .absolute(0.3))
        XCTAssertEqual(amount(RawIntentStep(action: "setSpeed", speed: 2), video), .absolute(2))
        XCTAssertEqual(amount(RawIntentStep(action: "setSpeed", amount: 2), video), .absolute(2))
    }

    func testGroundingFields() {
        let pointOnly = IntentNormalizer.normalize(RawIntentStep(action: "removeObject", point: PSPoint(x: 0.3, y: 1.4)), context: .photo)
        XCTAssertEqual(pointOnly?.target?.label, "object")
        XCTAssertEqual(pointOnly?.target?.point, PSPoint(x: 0.3, y: 1))
        let described = IntentNormalizer.normalize(RawIntentStep(action: "recolor", target: "shirt", color: "red", attributes: ["blue", " "]), context: .photo)
        XCTAssertEqual(described?.target?.attributes, ["blue"])
        XCTAssertNil(IntentNormalizer.normalize(RawIntentStep(action: "removeObject", attributes: ["red"]), context: .photo), "attributes alone name nothing")
        // Codable: absent by default, round-trips when set.
        let step = RawIntentStep(action: "removeObject", point: PSPoint(x: 0.5, y: 0.25), attributes: ["red"])
        let data = try! JSONEncoder().encode(step)
        XCTAssertEqual(try! JSONDecoder().decode(RawIntentStep.self, from: data), step)
        XCTAssertFalse(String(decoding: try! JSONEncoder().encode(RawIntentStep(action: "autoEnhance")), as: UTF8.self).contains("point"))
    }

    func testExecutorsReadTheRightUnits() async throws {
        let photo = PhotoDocument(title: "T", baseImage: MediaAsset(kind: .image, relativePath: "media/a.jpg", pixelSize: PSSize(width: 400, height: 300)))
        let upscale = try XCTUnwrap(IntentNormalizer.normalize(RawIntentStep(action: "upscale", amount: 3), context: .photo))
        let (_, upscaled) = await PhotoCommandExecutor(services: FakePhotoServices(candidates: [])).execute(upscale, on: photo, context: .photo)
        XCTAssertEqual(upscaled.label, "Upscale 3×")

        var timeline = VideoTimeline(title: "V", asset: MediaAsset(kind: .video, relativePath: "media/v.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: 20, frameRate: 30))
        timeline.audioTracks = [AudioTrack(asset: MediaAsset(kind: .audio, relativePath: "media/a.m4a", pixelSize: .zero, duration: 60, origin: .file), name: "Music")]
        let context = IntentContext(mode: .video, clipCount: 1, timelineDuration: 20, frameRate: 30)
        let fade = try XCTUnwrap(IntentNormalizer.normalize(RawIntentStep(action: "fadeAudio", amount: 2), context: context))
        let (faded, _) = await VideoCommandExecutor(services: FakeVideoServices()).execute(fade, on: timeline, context: context)
        XCTAssertEqual(faded.audioTracks[0].fadeIn, 2, accuracy: 1e-9)
        XCTAssertEqual(faded.audioTracks[0].fadeOut, 2, accuracy: 1e-9)
    }
}

final class ToolResultEncoderTests: XCTestCase {
    func testApplyEditsPayload() {
        let execution = LiveExecution(steps: [
            LiveStepResult(index: 0, action: .removeObject, status: .applied, label: "Remove dog"),
            LiveStepResult(index: 1, action: .adjust, status: .skipped),
        ], version: 13, canUndo: true)
        let result = ToolResultEncoder.applyEdits(execution)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.changedDocument)
        XCTAssertEqual(result.payload.serialized(),
                       #"{"can_undo":true,"ok":true,"results":[{"action":"removeObject","label":"Remove dog","status":"applied","step":1},{"action":"adjust","reason":"a previous step did not apply","status":"skipped","step":2}],"version":13}"#)
        XCTAssertEqual(ToolResultEncoder.block(result, toolUseID: "toolu_1"),
                       .toolResult(toolUseID: "toolu_1", content: [.text(result.payload.serialized())], isError: false))
    }

    func testEveryStatus() {
        let steps = [
            LiveStepResult(index: 0, action: .describe, status: .info, message: "Un chien sur une plage."),
            LiveStepResult(index: 1, action: .removeObject, status: .needsClarification, message: "Lequel ?", candidates: ["dog (left)", "dog (right)"]),
            LiveStepResult(index: 2, action: .generativeFill, status: .needsUser, message: "Entoure la zone.", needsUser: "select_region"),
            LiveStepResult(index: 3, action: .upscale, status: .failed, message: "Trop chaud."),
            LiveStepResult(index: 4, action: .zoom, status: .ignored),
            LiveStepResult(index: 5, action: .generativeFill, status: .running),
            LiveStepResult(index: 6, action: .autoEnhance, status: .queued),
        ]
        let results = ToolResultEncoder.applyEdits(LiveExecution(steps: steps, version: 2, canUndo: false)).payload["results"]?.array ?? []
        XCTAssertEqual(results[0]["message"], "Un chien sur une plage.")
        XCTAssertEqual(results[1]["question"], "Lequel ?")
        XCTAssertEqual(results[1]["candidates"], [["index": 1, "label": "dog (left)"], ["index": 2, "label": "dog (right)"]])
        XCTAssertEqual(results[2]["needs"], "select_region")
        XCTAssertEqual(results[2]["status"], "needs_user")
        XCTAssertEqual(results[3]["message"], "Trop chaud.")
        XCTAssertEqual(results[4]["status"], "ignored")
        XCTAssertEqual(results[5]["job"], "generativeFill")
        XCTAssertEqual(results[6]["status"], "queued")
    }

    func testErrorOnlyWhenEveryStepFailed() {
        let failed = LiveExecution(steps: [LiveStepResult(index: 0, action: .upscale, status: .failed, message: "x")], version: 1, canUndo: false)
        XCTAssertTrue(ToolResultEncoder.applyEdits(failed).isError)
        XCTAssertEqual(ToolResultEncoder.applyEdits(failed).payload["ok"], false)
        let mixed = LiveExecution(steps: [LiveStepResult(index: 0, action: .upscale, status: .failed, message: "x"),
                                          LiveStepResult(index: 1, action: .adjust, status: .applied, label: "Contrast +10")], version: 1, canUndo: true)
        XCTAssertFalse(ToolResultEncoder.applyEdits(mixed).isError)
    }

    func testUndoCompareIdeasAndLimits() {
        XCTAssertEqual(ToolResultEncoder.undo(labels: ["Brightness +20"], redo: false, version: 11).payload.serialized(), #"{"ok":true,"undone":["Brightness +20"],"version":11}"#)
        XCTAssertEqual(ToolResultEncoder.undo(labels: ["Brightness +20"], redo: true, version: 12).payload["redone"], ["Brightness +20"])
        let nothing = ToolResultEncoder.undo(labels: [], redo: false, version: 3)
        XCTAssertFalse(nothing.isError)
        XCTAssertEqual(nothing.payload["ok"], false)
        XCTAssertNotNil(nothing.payload["message"])
        XCTAssertEqual(ToolResultEncoder.compare().payload.serialized(), #"{"ok":true}"#)
        XCTAssertEqual(ToolResultEncoder.ideas(shown: 2, replaced: 1).payload.serialized(), #"{"ok":true,"replaced":1,"shown":2}"#)
        XCTAssertTrue(ToolResultEncoder.loopLimit().isError)
        XCTAssertEqual(ToolResultEncoder.loopLimit().payload["error"], "loop_limit")
    }

    func testCompactTextStaysShort() {
        let steps = (0..<30).map { LiveStepResult(index: $0, action: .adjust, status: .applied, label: "Brightness +\($0) with a long label") }
        let text = ToolResultEncoder.compactText(ToolResultEncoder.applyEdits(LiveExecution(steps: steps, version: 1, canUndo: true)))
        XCTAssertLessThanOrEqual(text.count, 300)
        XCTAssertTrue(text.hasPrefix("1 adjust applied: Brightness +0"))
        let clarification = LiveExecution(steps: [LiveStepResult(index: 0, action: .removeObject, status: .needsClarification, message: "Lequel ?", candidates: ["dog (left)"])],
                                          version: 1, canUndo: false)
        XCTAssertEqual(ToolResultEncoder.compactText(ToolResultEncoder.applyEdits(clarification)), "1 removeObject needs_clarification: Lequel ? [1 dog (left)]")
        XCTAssertEqual(ToolResultEncoder.compactText(ToolResultEncoder.invalid(.problems(["steps[0].amount: 250 is outside -100...100"]))),
                       "Invalid input: steps[0].amount: 250 is outside -100...100")
        XCTAssertEqual(ToolResultEncoder.compactText(ToolResultEncoder.undo(labels: ["A", "B"], redo: false, version: 1)), "Undone: A, B")
        XCTAssertEqual(ToolResultEncoder.compactText(ToolResultEncoder.compare()), "Done.")
    }

    func testOutcomeText() {
        let applied = LiveExecution(steps: [LiveStepResult(index: 0, action: .adjust, status: .applied, label: "Warmth +15")], version: 1, canUndo: true)
        XCTAssertEqual(applied.outcomeText(language: .french), "C'est fait.")
        XCTAssertEqual(applied.outcomeText(language: .english), "Done.")
        let question = LiveExecution(steps: [LiveStepResult(index: 0, action: .removeObject, status: .needsClarification, message: "Lequel ?")], version: 1, canUndo: false)
        XCTAssertEqual(question.outcomeText(language: .french), "Lequel ?")
        let running = LiveExecution(steps: [LiveStepResult(index: 0, action: .generativeFill, status: .running)], version: 1, canUndo: false)
        XCTAssertEqual(running.outcomeText(language: .english), LiveLines.line(.running, .english))
        XCTAssertEqual(LiveExecution(steps: [], version: 1, canUndo: false).outcomeText(language: .french), "")
    }
}
