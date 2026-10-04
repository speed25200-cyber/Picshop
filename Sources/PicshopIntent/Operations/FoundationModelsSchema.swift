import Foundation
import PicshopCore

/// A guided-generation schema for Apple's on-device model, as a pure tree (W2, D15): built from the catalog's
/// specs, measured and tested on Linux, then converted to `DynamicGenerationSchema` where FoundationModels exists.
public indirect enum FMSchemaNode: Hashable, Sendable {
    case object(name: String, [Property])
    /// A string, limited to these values when given.
    case string(anyOf: [String]?)
    case constant(String)
    case number(ClosedRange<Double>)
    case integer(ClosedRange<Int>)
    case boolean
    case array(of: FMSchemaNode, max: Int)
    case anyOf([FMSchemaNode])

    public struct Property: Hashable, Sendable {
        public var name: String
        /// At most 60 characters.
        public var description: String
        public var node: FMSchemaNode
        public var optional: Bool

        public init(name: String, description: String = "", node: FMSchemaNode, optional: Bool) {
            self.name = name
            self.description = String(description.prefix(FoundationModelsSchema.descriptionLimit))
            self.node = node
            self.optional = optional
        }
    }

    /// The object's name, or nil for a scalar.
    public var objectName: String? {
        if case .object(let name, _) = self { return name }
        return nil
    }
}

public enum FoundationModelsSchema {
    /// Operations in one schema (the planner's request, the FM Live brain's turn).
    public static let maxOps = 12
    /// The schema the model reads, in characters (`estimatedChars`).
    public static let budget = 2_400
    /// Steps in one plan.
    public static let maxSteps = 6
    public static let descriptionLimit = 60
    /// Enumerations this long are written as plain strings: the validator still checks them, and the
    /// schema stays within its budget (MaskRegion's 29 values alone would take a tenth of it).
    public static let longEnumeration = 20

    // MARK: Builders

    /// One step: an object named after the operation, `action` fixed to its id, then the parameters its card
    /// shows (required ones included; a `oneOf` group with no member on the card offers them all). Off-card
    /// optional ones stay with the validator, except the region keys while they fit (`regionKeys`).
    public static func stepSchema(_ spec: OperationSpec, regionKeys: Bool = true) -> FMSchemaNode {
        var properties = [FMSchemaNode.Property(name: "action", node: .constant(spec.id.raw), optional: false)]
        for param in spec.params where param.key != "action" && isOffered(param, in: spec, regionKeys: regionKeys) {
            let required: Bool
            if case .required = param.presence { required = true } else { required = false }
            properties.append(FMSchemaNode.Property(name: param.key, description: description(param), node: node(for: param.kind), optional: !required))
        }
        return .object(name: spec.id.raw, properties)
    }

    /// The plan: up to six steps, each one of the operations' step objects, and the short reply said back.
    public static func planSchema(specs: [OperationSpec], regionKeys: Bool = true) -> FMSchemaNode {
        let steps = specs.prefix(maxOps).map { stepSchema($0, regionKeys: regionKeys) }
        let step: FMSchemaNode = steps.count == 1 ? steps[0] : .anyOf(Array(steps))
        return .object(name: "Plan", [
            FMSchemaNode.Property(name: "steps", description: "The edits in order; empty when not an edit", node: .array(of: step, max: maxSteps),
                                  optional: false),
            FMSchemaNode.Property(name: "reply", description: "One short sentence, user's language", node: .string(anyOf: nil), optional: true),
        ])
    }

    /// The off-card keys a mask or a selection needs to name its area, which guided generation cannot emit
    /// unless the schema lists them: « tout ce qui est vert » (color), « la deuxième personne » (index), « la tasse
    /// bleue » (attributes).
    static let regionKeyOps: Set<String> = ["maskAdjust", "select"]
    static let regionKeyNames: Set<String> = ["color", "index", "attributes"]

    static func isOffered(_ param: ParamSpec, in spec: OperationSpec, regionKeys: Bool = true) -> Bool {
        if regionKeys, regionKeyOps.contains(spec.id.raw), regionKeyNames.contains(param.key) { return true }
        switch param.presence {
        case .required: return true
        case .optional: return param.onCard
        case .oneOf(let group):
            if param.onCard { return true }
            return !spec.params.contains { other in
                if case .oneOf(let otherGroup) = other.presence { return otherGroup == group && other.onCard }
                return false
            }
        }
    }

    /// Only what the type cannot say: the budget goes to the enumerations.
    static func description(_ param: ParamSpec) -> String {
        switch param.kind {
        case .box: return "[x1,y1,x2,y2] 0-1000, last image"
        case .point: return "[x,y] 0-1000, last image"
        case .ref: return "id: t3, o1, a1"
        case .text: return String(param.doc.prefix(descriptionLimit))
        case .enumeration(let values) where values.count > longEnumeration: return String(param.doc.prefix(descriptionLimit))
        default: return ""
        }
    }

    public static func node(for kind: ParamKind) -> FMSchemaNode {
        switch kind {
        case .enumeration(let values): return .string(anyOf: values.count > longEnumeration ? nil : values)
        case .number(let range, _): return .number(range)
        case .integer(let range): return .integer(range)
        case .boolean: return .boolean
        case .color, .text, .ref: return .string(anyOf: nil)
        case .point: return .array(of: .integer(0...1000), max: 2)
        case .box: return .array(of: .integer(0...1000), max: 4)
        case .list(let element, let max): return .array(of: node(for: element), max: max)
        }
    }

    // MARK: Measure

    /// What the schema costs the model's context, in characters: a compact rendering of the tree, close to
    /// what `includeSchemaInPrompt` writes.
    public static func estimatedChars(_ node: FMSchemaNode) -> Int {
        rendered(node).count
    }

    public static func rendered(_ node: FMSchemaNode) -> String {
        switch node {
        case .object(let name, let properties):
            let body = properties.map { property in
                var text = "\"\(property.name)\"\(property.optional ? "?" : ""):" + rendered(property.node)
                if !property.description.isEmpty { text += " //" + property.description }
                return text
            }
            return "\(name){" + body.joined(separator: ",") + "}"
        case .string(let values?): return "\"" + values.joined(separator: "|") + "\""
        case .string(nil): return "string"
        case .constant(let value): return "\"\(value)\""
        case .number(let range): return "number \(short(range.lowerBound))…\(short(range.upperBound))"
        case .integer(let range): return "int \(range.lowerBound)…\(range.upperBound)"
        case .boolean: return "bool"
        case .array(let element, let max): return "[" + rendered(element) + "]≤\(max)"
        case .anyOf(let nodes): return "(" + nodes.map(rendered).joined(separator: "|") + ")"
        }
    }

    static func short(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    // MARK: Which operations

    /// One request's or one turn's operations: the core of the domain and the five operations retrieved for the
    /// words (the ones the user named come first), capped at 12. When the cap bites, the core operations the
    /// words score lowest give way.
    public static func specs(for query: OperationQuery, catalog: OperationCatalog = .shared, index: OperationIndex = .shared) -> [OperationSpec] {
        let core = OperationGate.core(for: query.domain, catalog: catalog)
        let retrieved = index.retrieve(query, limit: 5).compactMap { catalog.spec($0.id) }
        var picked = retrieved
        let room = maxOps - picked.count
        if core.count <= room {
            picked += core.filter { spec in !picked.contains { $0.id == spec.id } }
        } else {
            let scores = Dictionary(index.ranking(query).map { ($0.id, $0.score) }, uniquingKeysWith: { first, _ in first })
            let ranked = core.enumerated().sorted { lhs, rhs in
                let left = scores[lhs.element.id] ?? 0, right = scores[rhs.element.id] ?? 0
                return left != right ? left > right : lhs.offset < rhs.offset
            }.map(\.element)
            picked += ranked.filter { spec in !picked.contains { $0.id == spec.id } }.prefix(max(0, room))
        }
        return Array(picked.prefix(maxOps))
    }

    /// The fixed schema when a turn's would not fit: the core, the six mask and selection operations, and
    /// selectiveAdjust (each kept only while it is enabled), capped at 12.
    public static func fallbackSpecs(domain: OpDomain, catalog: OperationCatalog = .shared) -> [OperationSpec] {
        let core = OperationGate.core(for: domain, catalog: catalog)
        guard domain == .photo else { return Array(core.prefix(maxOps)) }
        let disabled = OperationGate.disabled()
        let ids: [OpID] = ["maskAdjust", "maskEdit", "maskDelete", "select", "selectionModify", "selectionApply", "selectiveAdjust"]
        let masks = ids.filter { !disabled.contains($0) }.compactMap { catalog.spec($0) }
        var picked: [OperationSpec] = masks
        for spec in core where !picked.contains(where: { $0.id == spec.id }) && picked.count < maxOps { picked.append(spec) }
        return picked
    }

    /// The turn's (or the request's) plan schema and its operations: within budget, else the fixed fallback.
    public static func plan(for query: OperationQuery, catalog: OperationCatalog = .shared, index: OperationIndex = .shared)
        -> (specs: [OperationSpec], schema: FMSchemaNode) {
        let chosen = specs(for: query, catalog: catalog, index: index)
        // With the region keys while they fit, else without them: they never cost a turn its retrieved operations.
        for keys in [true, false] {
            let schema = planSchema(specs: chosen, regionKeys: keys)
            if estimatedChars(schema) <= budget { return (chosen, schema) }
        }
        var fallback = fallbackSpecs(domain: query.domain, catalog: catalog)
        var fixed = planSchema(specs: fallback, regionKeys: false)
        while estimatedChars(fixed) > budget, fallback.count > 1 {
            fallback.removeLast()
            fixed = planSchema(specs: fallback, regionKeys: false)
        }
        return (fallback, fixed)
    }

    /// Live's apply_edits arguments for one turn (the FM Live brain): `{steps: [...]}`, at most 4 steps, each one
    /// of the turn's operations.
    public static func toolSchema(specs: [OperationSpec], regionKeys: Bool = true) -> FMSchemaNode {
        let steps = specs.prefix(maxOps).map { stepSchema($0, regionKeys: regionKeys) }
        let step: FMSchemaNode = steps.count == 1 ? steps[0] : .anyOf(Array(steps))
        return .object(name: "ApplyEdits", [FMSchemaNode.Property(name: "steps", description: "The steps, in order", node: .array(of: step, max: 4), optional: false)])
    }

    /// A Live turn's retrieval query: its words, its language and what the editor state says is there.
    public static func query(for turn: LiveUserTurn, mode: EditorMode) -> OperationQuery {
        OperationQuery(text: turn.text, domain: mode.opDomain, language: turn.language, hints: LocalModelLiveBrain.stateHints(turn.editorState))
    }

    /// One Live turn's operations and apply_edits schema (FM Live brain): core + the turn's retrieved ops (≤ 12),
    /// else the fixed core + mask and selection set when the estimate passes the budget.
    public static func turnTool(for turn: LiveUserTurn?, mode: EditorMode) -> (specs: [OperationSpec], schema: FMSchemaNode) {
        let chosen = turn.map { specs(for: query(for: $0, mode: mode)) } ?? Array(OperationGate.core(for: mode.opDomain).prefix(maxOps))
        for keys in [true, false] {
            let schema = toolSchema(specs: chosen, regionKeys: keys)
            if estimatedChars(schema) <= budget { return (chosen, schema) }
        }
        var fallback = fallbackSpecs(domain: mode.opDomain)
        var fixed = toolSchema(specs: fallback, regionKeys: false)
        while estimatedChars(fixed) > budget, fallback.count > 1 {
            fallback.removeLast()
            fixed = toolSchema(specs: fallback, regionKeys: false)
        }
        return (fallback, fixed)
    }

    /// The model's plan JSON as the validator reads it: `{"steps": [...]}` objects with an `action` each.
    public static func steps(in json: JSONValue) -> [JSONValue] {
        guard case .object(let object) = json, case .array(let steps)? = object["steps"] else { return [] }
        return steps.filter { step in
            guard case .object(let fields) = step, case .string(let action)? = fields["action"] else { return false }
            return !action.isEmpty
        }
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
extension FoundationModelsSchema {
    /// The guided-generation schema for a plan tree.
    public static func generationSchema(_ node: FMSchemaNode) throws -> GenerationSchema {
        try GenerationSchema(root: dynamicSchema(node, name: node.objectName ?? "Plan"), dependencies: [])
    }

    /// The tree as FoundationModels' dynamic schema. Enumerations are named after their property path so every
    /// name in the schema is unique.
    static func dynamicSchema(_ node: FMSchemaNode, name: String) -> DynamicGenerationSchema {
        switch node {
        case .object(let objectName, let properties):
            return DynamicGenerationSchema(name: objectName, description: nil, properties: properties.map { property in
                DynamicGenerationSchema.Property(name: property.name, description: property.description.isEmpty ? nil : property.description,
                                                 schema: dynamicSchema(property.node, name: "\(objectName).\(property.name)"),
                                                 isOptional: property.optional)
            })
        case .string(let values?):
            return DynamicGenerationSchema(name: name, description: nil, anyOf: values)
        case .string(nil):
            return DynamicGenerationSchema(type: String.self)
        case .constant(let value):
            return DynamicGenerationSchema(type: String.self, guides: [.constant(value)])
        case .number(let range):
            return DynamicGenerationSchema(type: Double.self, guides: [.range(range)])
        case .integer(let range):
            return DynamicGenerationSchema(type: Int.self, guides: [.range(range)])
        case .boolean:
            return DynamicGenerationSchema(type: Bool.self)
        case .array(let element, let max):
            return DynamicGenerationSchema(arrayOf: dynamicSchema(element, name: name + ".item"), minimumElements: nil, maximumElements: max)
        case .anyOf(let nodes):
            return DynamicGenerationSchema(name: name, description: nil, anyOf: nodes.enumerated().map { offset, child in
                dynamicSchema(child, name: child.objectName ?? "\(name).\(offset)")
            })
        }
    }
}
#endif
