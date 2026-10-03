import Foundation

/// Every operation the editors offer to the language layer, in one place: the
/// single source of truth for cards, retrieval, argument validation, abstention
/// and postconditions.
///
/// The entries are in Catalog+*.swift, written with the OperationBuilders DSL:
/// every IntentAction a model may write as an apply_edits step (lowering
/// `.intent`), plus the operations that run through a domain handler table
/// (lowering `.handler`, IntentAction.operation). docs/OPERATIONS.md is
/// generated from it.
public struct OperationCatalog: Sendable {
    public static let shared = OperationCatalog(specs: OperationCatalog.entries)

    /// In catalog order.
    public let specs: [OperationSpec]
    private let byID: [OpID: Int]
    private let byAction: [IntentAction: Int]

    /// The first spec wins when two share an id or lower to the same action (a catalog test forbids both).
    public init(specs: [OperationSpec]) {
        self.specs = specs
        var byID: [OpID: Int] = [:]
        var byAction: [IntentAction: Int] = [:]
        for (index, spec) in specs.enumerated() {
            if byID[spec.id] == nil { byID[spec.id] = index }
            if case .intent(let action) = spec.lowering, byAction[action] == nil { byAction[action] = index }
        }
        self.byID = byID
        self.byAction = byAction
    }

    public func spec(_ id: OpID) -> OperationSpec? {
        byID[id].map { specs[$0] }
    }

    /// The operations that exist in the domain, in catalog order.
    public func specs(in domain: OpDomain) -> [OperationSpec] {
        specs.filter { $0.domains.contains(domain) }
    }

    /// The operations whose card is always in the domain's stable prompt prefix.
    public func core(for domain: OpDomain) -> [OperationSpec] {
        specs.filter { $0.coreIn.contains(domain) }
    }

    /// The spec that lowers to this IntentAction, if any.
    public func spec(lowering action: IntentAction) -> OperationSpec? {
        byAction[action].map { specs[$0] }
    }
}
