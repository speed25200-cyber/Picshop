import Foundation
import PicshopCore

/// One-line operation cards for the model's prompt, generated from the catalog.
///
/// A card is the step contract in a line: `id: params — summary « example »`.
/// - `key*` is required; `{a / b}` is a one-of group (`*` when one must be given);
/// - numbers print their range in the param's unit (`amount 0..100=50`, default after `=`);
/// - short enums print inline, exactly (`channel:rgb|red|green|blue`); long ones print
///   `key:…` and their values once on a `key: a|b|c` line under the cards;
/// - points are `[x,y]`, boxes `[x1,y1,x2,y2]`, both 0-1000.
/// Every value printed is exactly what OperationArguments accepts (catalog invariant I4).
public enum OperationCards {
    /// Cards are at most this long; the example, then the summary, give way first.
    public static let cardLimit = 160
    /// The domain's core block in the stable prompt prefix is at most this long.
    public static let coreBudget = 1_400
    /// Enumerations up to this many characters print inline on the card.
    static let inlineEnumLimit = 36

    /// The operation's card, at most 160 characters.
    public static func card(_ spec: OperationSpec, language: OpLanguage, unavailable: String? = nil) -> String {
        card(spec, language: language, unavailable: unavailable, domain: nil, detail: .full)
    }

    /// How much of a card is printed: the core block drops examples (the few-shots show them).
    enum Detail: Int, Comparable {
        case bare, summary, full

        static func < (lhs: Detail, rhs: Detail) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static func card(_ spec: OperationSpec, language: OpLanguage, unavailable: String?, domain: OpDomain?, detail: Detail) -> String {
        let head = spec.id.raw + ":" + (paramsText(spec, domain: domain).map { " " + $0 } ?? "")
        let reason = unavailable.map { " (unavailable: \($0))" } ?? ""
        let summary = " — " + spec.summary(language)
        let example = firstExample(spec, language: language).map { " « \($0) »" } ?? ""
        var candidates: [String] = []
        if detail >= .full { candidates.append(head + summary + example + reason) }
        if detail >= .summary { candidates.append(head + summary + reason) }
        candidates.append(head + reason)
        for line in candidates where line.count <= cardLimit { return line }
        let line = candidates.last ?? head
        return String(line.prefix(cardLimit - 1)) + "…"
    }

    /// The params on the card, or nil when there are none.
    static func paramsText(_ spec: OperationSpec, domain: OpDomain?) -> String? {
        let params = OperationArguments.params(spec, in: domain).filter(\.onCard)
        guard !params.isEmpty else { return nil }
        var parts: [String] = []
        var groups: [String: [ParamSpec]] = [:]
        var order: [(group: String?, param: ParamSpec?)] = []
        for param in params {
            if case .oneOf(let group) = param.presence {
                if groups[group] == nil { order.append((group, nil)) }
                groups[group, default: []].append(param)
            } else {
                order.append((nil, param))
            }
        }
        for entry in order {
            if let param = entry.param {
                parts.append(paramText(param))
            } else if let group = entry.group, let members = groups[group] {
                // A group whose other members are off the card still needs one of the shown ones.
                let shown = members.map(paramText)
                parts.append(shown.count == 1 ? shown[0] + "*" : "{" + shown.joined(separator: " / ") + "}*")
            }
        }
        return parts.joined(separator: ", ")
    }

    static func paramText(_ param: ParamSpec) -> String {
        let required = param.presence == .required ? "*" : ""
        var defaultText = ""
        if case .optional(let value?) = param.presence { defaultText = "=" + valueText(value) }
        return param.key + required + kindText(param.kind, key: param.key) + defaultText
    }

    static func kindText(_ kind: ParamKind, key: String) -> String {
        switch kind {
        case .enumeration(let values):
            let joined = values.joined(separator: "|")
            return joined.count <= inlineEnumLimit ? ":" + joined : ":…"
        case .number(_, .seconds):
            return ":s"
        case .number(let range, _):
            return " " + number(range.lowerBound) + ".." + number(range.upperBound)
        case .integer(let range):
            return " " + String(range.lowerBound) + ".." + String(range.upperBound)
        case .boolean:
            return ":true|false"
        case .color:
            return ":name|#hex"
        case .point:
            return ":[x,y] 0-1000"
        case .box:
            return ":[x1,y1,x2,y2] 0-1000"
        case .text:
            return ":\"…\""
        case .ref(let kinds):
            return ":" + RefKind.allCases.filter(kinds.contains).map { "\($0.prefix)1" }.joined(separator: "|")
        case .list(let item, let max):
            if case .point = item { return ":[[x,y]…] 0-1000 ≤\(max)" }
            return ":[" + String(kindText(item, key: key).dropFirst()) + "…] ≤\(max)"
        }
    }

    static func valueText(_ value: OpValue) -> String {
        switch value {
        case .number(let number): return self.number(number)
        case .string(let string): return string
        case .bool(let bool): return bool ? "true" : "false"
        case .point(let point): return "[\(number(point.x)),\(number(point.y))]"
        case .box(let box): return "[\(number(box.minX)),\(number(box.minY)),\(number(box.maxX)),\(number(box.maxY))]"
        case .list(let values): return "[" + values.map(valueText).joined(separator: ",") + "]"
        }
    }

    static func number(_ value: Double) -> String {
        JSONValue.number(value).serialized()
    }

    static func firstExample(_ spec: OperationSpec, language: OpLanguage) -> String? {
        spec.examples.first { $0.language == language && $0.role == .positive }?.say
    }

    // MARK: Long enumerations

    /// The long enumerations a card prints as `key:…`: key → values.
    static func longEnums(_ spec: OperationSpec, domain: OpDomain?) -> [(key: String, values: [String])] {
        OperationArguments.params(spec, in: domain).filter(\.onCard).compactMap { param in
            switch param.kind {
            case .enumeration(let values) where values.joined(separator: "|").count > inlineEnumLimit: return (param.key, values)
            case .list(.enumeration(let values), _) where values.joined(separator: "|").count > inlineEnumLimit: return (param.key, values)
            default: return nil
            }
        }
    }

    /// `key: a|b|c`, once per key, in first-use order.
    static func enumLines(_ specs: [OperationSpec], domain: OpDomain?, excluding: Set<String> = []) -> [String] {
        var seen = excluding
        var lines: [String] = []
        for spec in specs {
            for entry in longEnums(spec, domain: domain) where !seen.contains(entry.key) {
                seen.insert(entry.key)
                lines.append(entry.key + ": " + entry.values.joined(separator: "|"))
            }
        }
        return lines
    }

    /// The long-enum keys the domain's core block already prints.
    static func coreEnumKeys(_ domain: OpDomain) -> Set<String> {
        Set(OperationGate.core(for: domain).flatMap { longEnums($0, domain: domain).map(\.key) })
    }

    // MARK: Blocks

    /// Short: the photo core block carries maskAdjust's `where:` values (W2) within its 1,400 characters.
    static let coreHeader = "Ops (* required, {a / b} one of, key:… below):"

    /// The domain's core cards for the stable prompt prefix, at most 1,400 characters.
    /// Deterministic for a domain and size, so the prefix stays byte-identical.
    public static func coreBlock(for domain: OpDomain, size: LocalPromptSize) -> String {
        // The flags decide the photo core set (W2): maskAdjust, or selectiveAdjust when `masks` is off.
        let specs = OperationGate.core(for: domain)
        guard !specs.isEmpty else { return "" }
        let enums = enumLines(specs, domain: domain)
        // The richest cards that fit: every card at one level if they all fit, else bare cards upgraded
        // one by one in catalog order while the block stays within budget. The 2B never gets examples.
        let levels: [Detail] = size == .full ? [.full, .summary] : [.summary]
        for detail in levels {
            let cards = specs.map { card($0, language: .fr, unavailable: nil, domain: domain, detail: detail) }
            let block = ([coreHeader] + cards + enums).joined(separator: "\n")
            if block.count <= coreBudget { return block }
        }
        var cards = specs.map { card($0, language: .fr, unavailable: nil, domain: domain, detail: .bare) }
        if ([coreHeader] + cards + enums).joined(separator: "\n").count <= coreBudget {
            for (index, spec) in specs.enumerated() {
                var upgraded = cards
                upgraded[index] = card(spec, language: .fr, unavailable: nil, domain: domain, detail: .summary)
                if ([coreHeader] + upgraded + enums).joined(separator: "\n").count <= coreBudget { cards = upgraded }
            }
            return ([coreHeader] + cards + enums).joined(separator: "\n")
        }
        // Still too long: whole lines only, cards first.
        var lines: [String] = []
        for line in [coreHeader] + specs.map({ card($0, language: .fr, unavailable: nil, domain: domain, detail: .bare) }) + enums {
            guard (lines + [line]).joined(separator: "\n").count <= coreBudget else { break }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// The turn's retrieved cards inside <ops>…</ops> within `budget` characters, or empty.
    public static func turnBlock(_ ops: [RetrievedOperation], language: OpLanguage, budget: Int) -> String {
        turnBlock(ops, language: language, budget: budget, domain: nil)
    }

    /// With the domain: the cards keep only that editor's fields, and the long enums its core
    /// block already prints are not repeated.
    public static func turnBlock(_ ops: [RetrievedOperation], language: OpLanguage, budget: Int, domain: OpDomain?) -> String {
        let catalog = OperationCatalog.shared
        let specs = ops.compactMap { op in catalog.spec(op.id).map { (op, $0) } }
        let resolved = domain ?? sharedDomain(specs.map(\.1))
        let printed = resolved.map(coreEnumKeys) ?? []
        var cards: [String] = []
        var enums: [String] = []
        var seen = printed
        let wrapper = "<ops>\n\n</ops>".count
        for (op, spec) in specs {
            let card = card(spec, language: language, unavailable: op.unavailable, domain: resolved, detail: .full)
            let added = enumLines([spec], domain: resolved, excluding: seen)
            let length = wrapper + (cards + [card] + enums + added).joined(separator: "\n").count
            guard length <= budget else { continue }
            cards.append(card)
            enums += added
            for line in added { if let key = line.split(separator: ":").first { seen.insert(String(key)) } }
        }
        guard !cards.isEmpty else { return "" }
        return "<ops>\n" + (cards + enums).joined(separator: "\n") + "\n</ops>"
    }

    /// The one domain every spec is in, when there is exactly one.
    static func sharedDomain(_ specs: [OperationSpec]) -> OpDomain? {
        guard let first = specs.first else { return nil }
        let common = specs.dropFirst().reduce(first.domains) { $0.intersection($1.domains) }
        return common.count == 1 ? common.first : nil
    }
}
