import Foundation
import PicshopCore

/// Claude's four Live tools. Built once per mode and frozen for the session:
/// changing tools invalidates the prompt cache.
public enum LiveToolSchema {
    /// Never apply_edits steps: meta and dialogue actions have tools of their own or no place in a conversation.
    public static let excluded: Set<IntentAction> = [
        .unknown, .undo, .redo, .revert, .compare, .help, .confirm, .cancel, .describe, .summarizeEdits, .readPage, .export, .share,
        .zoom, .play, .pause, .saveVersion, .restoreVersion, .saveStyle, .applyStyle, .chooseCandidate,
    ]

    /// Fields only the video schema has.
    public static let videoFields: Set<String> = ["startSeconds", "endSeconds", "seconds", "clipNumber", "transition", "speed", "scope"]

    public static let applyEditsDescription = """
    Apply one or more edits to the open photo or video, in order. Call this whenever the user asks for a change, accepts one of your ideas or \
    says yes to your proposal. Say one short sentence before calling it; when the edit succeeds you usually will not get another turn to comment. \
    Do not call it for questions or opinions. Use only the listed values. At most 6 steps. To say which object, use point (x and y from 0 to 1, \
    top-left origin, in the last image you saw) or attributes such as a colour or clothing.
    """

    public static let undoDescription = """
    Undo the last edits, redo them, or go back to the original. Call it when the user says undo, too much, go back, \
    'c'est trop', 'reviens en arrière' or 'remets comme avant'.
    """

    public static let compareDescription = """
    Show the original for a moment so the user sees the difference. Call it when the user wants to see the before, \
    or asks what changed ('montre-moi l'avant').
    """

    public static let proposeIdeasDescription = """
    Show up to 3 idea chips the user can tap. Call it when the Live session starts, after the picture changed meaningfully, \
    or when the user asks what you would do. Title: at most 4 words, in the user's language. Why: one short line tied to what \
    you see. Ideas must differ from what is already applied.
    """

    /// Sorted by name, each with eager_input_streaming.
    public static func tools(for mode: EditorMode) -> [ClaudeToolDefinition] {
        let step = stepSchema(for: mode)
        let tools = [
            ClaudeToolDefinition(name: LiveToolName.applyEdits.rawValue, description: applyEditsDescription, inputSchema: [
                "type": "object",
                "additionalProperties": false,
                "required": ["steps"],
                "properties": ["steps": ["type": "array", "minItems": 1, "maxItems": 6, "items": step]],
            ]),
            ClaudeToolDefinition(name: LiveToolName.undo.rawValue, description: undoDescription, inputSchema: [
                "type": "object",
                "additionalProperties": false,
                "properties": [
                    "count": ["type": "integer", "minimum": 1, "maximum": 20, "description": "How many edits, default 1."],
                    "direction": ["type": "string", "enum": ["undo", "redo"], "description": "undo (default) or redo."],
                    "to_original": ["type": "boolean", "description": "true to go back to the original, before every edit."],
                ],
            ]),
            ClaudeToolDefinition(name: LiveToolName.compareBeforeAfter.rawValue, description: compareDescription, inputSchema: [
                "type": "object",
                "additionalProperties": false,
                "properties": ["seconds": ["type": "number", "minimum": 1, "maximum": 5, "description": "How long the original shows, default 2."]],
            ]),
            ClaudeToolDefinition(name: LiveToolName.proposeIdeas.rawValue, description: proposeIdeasDescription, inputSchema: [
                "type": "object",
                "additionalProperties": false,
                "required": ["ideas"],
                "properties": ["ideas": [
                    "type": "array", "minItems": 1, "maxItems": 3,
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["title", "why", "steps"],
                        "properties": [
                            "title": ["type": "string", "maxLength": 26, "description": "At most 4 words, in the user's language."],
                            "why": ["type": "string", "maxLength": 90, "description": "One short line tied to what you see."],
                            "symbol": ["type": "string", "enum": .array(IdeaSymbols.allowed.sorted().map { .string($0) }), "description": "SF Symbol for the chip."],
                            "steps": ["type": "array", "minItems": 1, "maxItems": 4, "items": step],
                        ],
                    ],
                ]],
            ]),
        ]
        return tools.sorted { $0.name < $1.name }
    }

    /// IntentAction.allCases allowed in the mode, minus the excluded actions.
    public static func allowedActions(for mode: EditorMode) -> [IntentAction] {
        IntentAction.allCases.filter { $0.isAllowed(in: mode) && !excluded.contains($0) }
    }

    /// One apply_edits step. Field descriptions follow IntentPrompt so every brain reads the same contract.
    public static func stepSchema(for mode: EditorMode) -> JSONValue {
        func enumeration(_ values: [String]) -> JSONValue { .array(values.map { .string($0) }) }
        var properties: [String: JSONValue] = [
            "action": ["type": "string", "enum": enumeration(allowedActions(for: mode).map(\.rawValue))],
            "target": ["type": "string", "maxLength": 40,
                       "description": "Canonical English noun of the object or region: dog, person, car, sign, pole, wire, text, sky, face, eyes, teeth, background. Required for removeObject, moveObject (or point), recolor, selectiveAdjust."],
            "spatialHint": ["type": "string", "enum": enumeration(SpatialHint.allCases.map(\.rawValue))],
            "ordinal": ["type": "integer", "minimum": 1, "maximum": 20, "description": "The second person -> 2."],
            "all": ["type": "boolean", "description": "true when every matching object is meant."],
            "point": ["type": "object", "additionalProperties": false, "required": ["x", "y"],
                      "description": "Where the object is in the last image you saw: x and y from 0 to 1, top-left origin.",
                      "properties": ["x": ["type": "number", "minimum": 0, "maximum": 1], "y": ["type": "number", "minimum": 0, "maximum": 1]]],
            "attributes": ["type": "array", "maxItems": 3, "items": ["type": "string", "maxLength": 24],
                           "description": "Words that tell the object apart: a colour, clothing (red, blue shirt)."],
            "parameter": ["type": "string", "enum": enumeration(AdjustmentParameter.allCases.map(\.rawValue))],
            "amountMode": ["type": "string", "enum": ["relative", "absolute", "multiplier"],
                           "description": "relative for more/less, absolute for 'set to', multiplier for zoom and speed factors."],
            "amount": ["type": "number", "description": .string(amountDescription)],
            "look": ["type": "string", "enum": enumeration(FilterPreset.allCases.map(\.rawValue))],
            "aspect": ["type": "string", "enum": enumeration(AspectPreset.allCases.map(\.rawValue))],
            "degrees": ["type": "number", "minimum": -360, "maximum": 360, "description": "rotate: negative = counter-clockwise. moveObject: direction, 0 right, 90 up, 180 left, 270 down."],
            "flipAxis": ["type": "string", "enum": ["horizontal", "vertical"]],
            "text": ["type": "string", "maxLength": 200, "description": "addText: the words, verbatim in the user's language. generativeFill: what to generate, in English."],
            "placement": ["type": "string", "enum": enumeration(TextElement.Placement.allCases.map(\.rawValue))],
            "color": ["type": "string", "description": "English colour name (red, light blue) or #RRGGBB."],
            "background": ["type": "string", "description": "replaceBackground: colour name, transparent or blur."],
            "choiceIndex": ["type": "integer", "minimum": 1, "description": "1-based index: the candidate, or the destination of moveClip."],
        ]
        if mode == .video {
            properties["startSeconds"] = ["type": "number", "minimum": 0, "description": "Start of the range in seconds (trim keeps it, deleteRange removes it)."]
            properties["endSeconds"] = ["type": "number", "minimum": 0, "description": "End of the range in seconds."]
            properties["seconds"] = ["type": "number", "minimum": 0, "description": "A single time in seconds (split, seek, extractFrame, addMusic start); highlights: the recap length."]
            properties["clipNumber"] = ["type": "integer", "description": "1-based clip number, -1 = last; the track number for sound-track steps."]
            properties["transition"] = ["type": "string", "enum": enumeration(TransitionKind.allCases.map(\.rawValue))]
            properties["speed"] = ["type": "number", "minimum": 0.1, "maximum": 8, "description": "Playback speed multiplier: 0.5 slow motion, 2 twice as fast."]
            properties["scope"] = ["type": "string", "enum": ["current", "all", "selection"],
                                   "description": "current for the selected clip, all for every clip, selection for a sound track."]
        }
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["action"],
            "properties": .object(properties),
        ]
    }

    static let amountDescription = """
    Percent for adjust and selectiveAdjust (-100 to 100; relative: a touch 10, a bit 20, a lot 40), applyLook, blurBackground, \
    autoEnhance, denoise and sharpen (0 to 100) and setVolume (0 to 200). A fraction for moveObject (distance 0.05 to 0.5 of the frame), \
    removeSilences (0.2 gentle to 0.45 tight), autoDuck (0 to 0.9) and recolor (strength 0 to 1). Seconds for fadeAudio (0 to 10) and \
    highlights (5 to 300). A multiplier for upscale (2 to 4), punchIns (1 to 1.5, 0 removes them) and speedRamp (slowest speed 0.1 to 1).
    """
}
