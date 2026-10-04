import Foundation

// D21: the plan's four recipes as deterministic one-step expansions. `recipe` is one catalog op (L4); the executors
// expand it here, run the steps in order and commit one history step « Recette : <titre> ». Recipe arguments:
// instagramPost `format` (portrait4x5 | square | story9x16, default 4:5), productPhoto `background` (a colour name or
// #RRGGBB, default white), portraitRetouch `strength` (0…100, default 50), vlogCleanup `captions` (default true).

public enum RecipeName: String, Codable, Sendable, CaseIterable { case instagramPost, productPhoto, portraitRetouch, vlogCleanup }

/// What an expansion may depend on besides its arguments.
public struct RecipeContext: Hashable, Sendable {
    public var domain: OpDomain
    public var hasMusic: Bool
    public var hasCaptions: Bool

    public init(domain: OpDomain, hasMusic: Bool = false, hasCaptions: Bool = false) {
        self.domain = domain
        self.hasMusic = hasMusic
        self.hasCaptions = hasCaptions
    }
}

public enum RecipeBook {
    /// vlogCleanup .video, the rest .photo.
    public static func domain(of recipe: RecipeName) -> OpDomain {
        switch recipe {
        case .instagramPost, .productPhoto, .portraitRetouch: return .photo
        case .vlogCleanup: return .video
        }
    }

    public static func title(of recipe: RecipeName) -> Bilingual {
        switch recipe {
        case .instagramPost: return Bilingual(en: "Instagram post", fr: "Post Instagram")
        case .productPhoto: return Bilingual(en: "Product photo", fr: "Photo produit")
        case .portraitRetouch: return Bilingual(en: "Portrait retouch", fr: "Retouche portrait")
        case .vlogCleanup: return Bilingual(en: "Vlog cleanup", fr: "Nettoyage vlog")
        }
    }

    /// D21: the recipe's steps, in order; [] when the domain does not match. Deterministic: two calls give equal
    /// steps (the intents' ids come from the recipe and the step index, not from `UUID()`). Catalog operations are
    /// `.operation` intents from the planner; setAspect, sharpen and the video steps are their legacy actions.
    /// Amounts are in the catalog's units (signedPercent ±100: 0.3·s is in percent points).
    public static func expand(_ recipe: RecipeName, args: [String: OpValue], context: RecipeContext) -> [EditIntent] {
        guard context.domain == domain(of: recipe) else { return [] }
        var steps: [EditIntent] = []
        func operation(_ id: OpID, _ arguments: [String: OpValue]) {
            steps.append(EditIntent(id: stepID(recipe, steps.count), action: .operation, operation: OperationCall(id, args: arguments, source: .planner)))
        }
        func legacy(_ intent: EditIntent) {
            var step = intent
            step.id = stepID(recipe, steps.count)
            steps.append(step)
        }
        switch recipe {
        case .instagramPost:
            let aspect: AspectPreset
            switch args["format"]?.string {
            case "square": aspect = .square
            case "story9x16": aspect = .ratio9x16
            default: aspect = .ratio4x5
            }
            legacy(EditIntent(action: .setAspect, aspect: aspect))
            operation("autoTone", ["amount": .number(60)])
            operation("adjust", ["parameter": .string(AdjustmentParameter.vibrance.rawValue), "amount": .number(12), "amountMode": .string("relative")])
            operation("adjust", ["parameter": .string(AdjustmentParameter.clarity.rawValue), "amount": .number(8), "amountMode": .string("relative")])
            legacy(EditIntent(action: .sharpen, amount: .absolute(0.25)))
            operation("exportPhoto", ["preset": .string("instagram")])
        case .productPhoto:
            let background = args["background"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            legacy(EditIntent(action: .setAspect, aspect: .square))
            operation("layerVia", ["mode": .string("copy"), "where": .string(MaskRegion.subject.rawValue), "name": .string("Produit")])
            operation("addFillLayer", ["fill": .string("solid"), "color": .string(background?.isEmpty == false ? background! : "white"),
                                       "position": .string("below")])
            operation("autoTone", ["amount": .number(50)])
        case .portraitRetouch:
            let strength = (args["strength"]?.double ?? 50).clamped(to: 0...100)
            func points(_ value: Double) -> Double { (value * 100).rounded() / 100 }
            operation("maskAdjust", ["where": .string(MaskRegion.faceSkin.rawValue), "parameter": .string(AdjustmentParameter.clarity.rawValue),
                                     "amount": .number(points(-(15 + 0.3 * strength))), "amountMode": .string("absolute")])
            operation("maskAdjust", ["where": .string(MaskRegion.faceSkin.rawValue), "parameter": .string(AdjustmentParameter.skinTone.rawValue),
                                     "amount": .number(points(5 + 0.1 * strength))])
            operation("maskAdjust", ["where": .string(MaskRegion.eyes.rawValue), "parameter": .string(AdjustmentParameter.exposure.rawValue),
                                     "amount": .number(points(8 + 0.12 * strength))])
            operation("maskAdjust", ["where": .string(MaskRegion.teeth.rawValue), "parameter": .string(AdjustmentParameter.exposure.rawValue),
                                     "amount": .number(points(6 + 0.1 * strength))])
            operation("maskAdjust", ["where": .string(MaskRegion.subject.rawValue), "parameter": .string(AdjustmentParameter.exposure.rawValue),
                                     "amount": .number(5)])
            operation("adjust", ["parameter": .string(AdjustmentParameter.vibrance.rawValue), "amount": .number(5), "amountMode": .string("relative")])
        case .vlogCleanup:
            let captions = args["captions"]?.bool ?? true
            legacy(EditIntent(action: .enhanceVoice, scope: .all))
            legacy(EditIntent(action: .removeFillers))
            legacy(EditIntent(action: .removeSilences))
            if captions, !context.hasCaptions { legacy(EditIntent(action: .autoCaptions)) }
            if context.hasMusic { legacy(EditIntent(action: .autoDuck, amount: .absolute(0.6))) }
        }
        return steps
    }

    /// A step's id, the same on every expansion: the recipe and the step index through StableHash.
    static func stepID(_ recipe: RecipeName, _ index: Int) -> UUID {
        let hex = StableHash.hex("recipe:\(recipe.rawValue):\(index)") + StableHash.hex("step:\(index):\(recipe.rawValue)")
        var bytes: [UInt8] = []
        var cursor = hex.startIndex
        while cursor < hex.endIndex, bytes.count < 16 {
            let next = hex.index(cursor, offsetBy: 2)
            bytes.append(UInt8(hex[cursor..<next], radix: 16) ?? 0)
            cursor = next
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
