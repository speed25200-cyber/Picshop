import Foundation
import PicshopCore

/// Argument coercion and validation for catalog operations, generated from their ParamSpecs.
///
/// - `coerce` repairs the form, never the meaning: key aliases, numbers and booleans sent as
///   text, enum values that differ by case or are a listed alias ("produit" → multiply),
///   points and boxes in 0–1 or as text, refs written "L2".
/// - `validate` is strict, like ToolInputValidator: known keys only, exact enum values,
///   ranges in each param's unit, required params and one-of groups, refs of the right kind.
///   Its problem lines name what is accepted, and an unknown operation lists the nearest ones,
///   so one repair round is enough.
/// - points are `[x, y]` and boxes `[x1, y1, x2, y2]`, in 0…1000 with a top-left origin
///   (0…1 is read too). OpValue keeps them in 0…1000.
public enum OperationArguments {
    /// apply_edits fields only a photo step has (LiveToolSchema.photoFields).
    static let photoKeys: Set<String> = ["cells", "row", "column", "values", "min", "max", "decimals", "ref", "box", "size", "weight", "align", "font", "match"]
    /// apply_edits fields a photo step never has (LiveToolSchema.videoFields); PDF steps name pages with clipNumber.
    static let timelineKeys: Set<String> = ["startSeconds", "endSeconds", "seconds", "clipNumber", "transition", "speed", "scope"]

    /// The params a step of this operation may carry in the domain. An existing action shared by
    /// several editors keeps the photo-only fields to photo steps and the timeline fields off them.
    public static func params(_ spec: OperationSpec, in domain: OpDomain?) -> [ParamSpec] {
        guard case .intent = spec.lowering, let domain else { return spec.params }
        return spec.params.filter { param in
            if domain != .photo, photoKeys.contains(param.key) { return false }
            if domain == .photo, timelineKeys.contains(param.key) { return false }
            return true
        }
    }

    /// Every key a step of this operation may carry before coercion: its params and their aliases.
    public static func allowedKeys(_ id: OpID, domain: OpDomain) -> Set<String> {
        guard let spec = OperationCatalog.shared.spec(id) else { return ["action"] }
        var keys: Set<String> = ["action"]
        for param in params(spec, in: domain) {
            keys.insert(param.key)
            keys.formUnion(param.keyAliases)
        }
        return keys
    }

    // MARK: Coerce

    /// Key and value aliases, types and units fixed before validation. Unknown keys stay, for
    /// `validate` to name them.
    public static func coerce(_ object: [String: JSONValue], for id: OpID) -> [String: JSONValue] {
        guard let spec = OperationCatalog.shared.spec(id) else { return object }
        var result = object.filter { $0.value != .null }
        for param in spec.params where result[param.key] == nil {
            for alias in param.keyAliases {
                if let value = result.removeValue(forKey: alias) {
                    result[param.key] = value
                    break
                }
            }
        }
        // "Opacity", "blend_mode": the key as the spec spells it.
        let keyed = Dictionary(spec.params.map { (foldedKey($0.key), $0.key) }, uniquingKeysWith: { first, _ in first })
        for key in result.keys.sorted() where key != "action" && spec.params.allSatisfy({ $0.key != key }) {
            if let exact = keyed[foldedKey(key)], result[exact] == nil, let value = result.removeValue(forKey: key) { result[exact] = value }
        }
        for param in spec.params {
            guard let value = result[param.key] else { continue }
            result[param.key] = coerce(value, kind: param.kind, param: param)
        }
        return result
    }

    static func coerce(_ value: JSONValue, kind: ParamKind, param: ParamSpec) -> JSONValue {
        switch kind {
        case .enumeration(let values):
            guard let text = scalarText(value) else { return value }
            if values.contains(text) { return .string(text) }
            if let exact = values.first(where: { foldedKey($0) == foldedKey(text) }) { return .string(exact) }
            if let aliased = param.valueAliases[TextFolding.tokens(text).joined(separator: " ")] { return .string(aliased) }
            return value
        case .number:
            return number(value).map { .number($0) } ?? value
        case .integer:
            guard let parsed = number(value), parsed == parsed.rounded() else { return value }
            return .number(parsed)
        case .boolean:
            return boolean(value).map { .bool($0) } ?? value
        case .color, .text:
            return scalarText(value).map { .string($0) } ?? value
        case .ref:
            guard let text = value.string else { return value }
            let compact = text.lowercased().filter { !$0.isWhitespace && $0 != "#" }
            return .string(compact)
        case .point:
            return pointPair(value).map { .array([.number($0.x), .number($0.y)]) } ?? value
        case .box:
            return boxCorners(value).map { .array($0.map { .number($0) }) } ?? value
        case .list(let item, _):
            var list = value
            if case .string(let text) = value, let parsed = try? JSONValue.parse(text) { list = parsed }
            // One point given where a list of points is expected: [500, 600] → [[500, 600]].
            if case .point = item, case .array(let items) = list, items.count == 2, items.allSatisfy({ number($0) != nil }) { list = .array([list]) }
            guard case .array(let items) = list else {
                // One item where a list is expected.
                return .array([coerce(value, kind: item, param: param)])
            }
            return .array(items.map { coerce($0, kind: item, param: param) })
        }
    }

    // MARK: Validate

    /// The call when the arguments are valid for the operation in the domain; else nil, with `problems` appended.
    public static func validate(_ id: OpID, _ object: [String: JSONValue], domain: OpDomain, path: String, problems: inout [String]) -> OperationCall? {
        guard let spec = OperationCatalog.shared.spec(id) else {
            problems.append("\(path).action: '\(id.raw)' is not an operation; nearest: \(nearest(to: id.raw, domain: domain).map(\.raw).joined(separator: ", "))")
            return nil
        }
        guard spec.domains.contains(domain) else {
            let near = nearest(to: id.raw, domain: domain).map(\.raw).joined(separator: ", ")
            problems.append("\(path).action: \(id.raw) is not available for a \(domain.rawValue); nearest: \(near)")
            return nil
        }
        let before = problems.count
        let allowed = params(spec, in: domain)
        let keys = Set(allowed.map(\.key))
        for key in object.keys.sorted() where key != "action" && !keys.contains(key) {
            let fields = allowed.isEmpty ? "none" : allowed.map(\.key).joined(separator: ", ")
            problems.append("\(path).\(key): unknown field for \(id.raw); fields: \(fields)")
        }
        var args: [String: OpValue] = [:]
        for param in allowed {
            guard let raw = object[param.key], raw != .null else { continue }
            if let value = check(raw, param: param, spec: spec, object: object, path: "\(path).\(param.key)", problems: &problems) {
                args[param.key] = value
            }
        }
        presence(spec, allowed: allowed, object: object, path: path, problems: &problems)
        crossChecks(spec, args: args, path: path, problems: &problems)
        guard problems.count == before else { return nil }
        if spec.lowering == .handler {
            // A new operation's call carries its defaults, so the handler reads what the card printed.
            for param in allowed where args[param.key] == nil {
                if case .optional(let value?) = param.presence { args[param.key] = value }
            }
        }
        return OperationCall(spec.id, args: args)
    }

    static func presence(_ spec: OperationSpec, allowed: [ParamSpec], object: [String: JSONValue], path: String, problems: inout [String]) {
        func given(_ key: String) -> Bool { object[key].map { $0 != .null } ?? false }
        var groups: [String: [String]] = [:]
        var order: [String] = []
        for param in allowed {
            switch param.presence {
            case .required:
                if !given(param.key) { problems.append("\(path): \(spec.id.raw) needs \(param.key)") }
            case .oneOf(let group):
                if groups[group] == nil { order.append(group) }
                groups[group, default: []].append(param.key)
            case .optional:
                break
            }
        }
        for group in order {
            let members = groups[group] ?? []
            let present = members.filter(given)
            if present.isEmpty {
                problems.append("\(path): \(spec.id.raw) needs \(members.count == 1 ? members[0] : "one of " + members.joined(separator: ", "))")
            } else if spec.exclusiveGroups.contains(group), present.count > 1 {
                problems.append("\(path): \(spec.id.raw) takes one of \(members.joined(separator: ", ")), not several")
            }
        }
    }

    static func crossChecks(_ spec: OperationSpec, args: [String: OpValue], path: String, problems: inout [String]) {
        if let black = args["black"]?.double, let white = args["white"]?.double, white <= black {
            problems.append("\(path).white: must be greater than black")
        }
        if let start = args["startSeconds"]?.double, let end = args["endSeconds"]?.double, end <= start {
            problems.append("\(path).endSeconds: must be after startSeconds")
        }
        if let low = args["min"]?.double, let high = args["max"]?.double, !(low < high) {
            problems.append("\(path).max: must be greater than min")
        }
    }

    /// One value against its param.
    static func check(_ raw: JSONValue, param: ParamSpec, spec: OperationSpec, object: [String: JSONValue], path: String,
                      problems: inout [String]) -> OpValue? {
        check(raw, kind: param.kind, key: param.key, range: amountRange(param, spec: spec, object: object), spec: spec, path: path, problems: &problems)
    }

    static func check(_ raw: JSONValue, kind: ParamKind, key: String, range: ClosedRange<Double>?, spec: OperationSpec, path: String,
                      problems: inout [String]) -> OpValue? {
        switch kind {
        case .enumeration(let values):
            guard case .string(let text) = raw else {
                problems.append("\(path): must be one of \(values.joined(separator: ", "))")
                return nil
            }
            guard values.contains(text) else {
                problems.append("\(path): '\(text)' is not one of \(values.joined(separator: ", "))")
                return nil
            }
            return .string(text)
        case .number(let declared, _):
            guard case .number(let value) = raw, value.isFinite else {
                problems.append("\(path): must be a number")
                return nil
            }
            if case .intent(let action) = spec.lowering, key == "amount", AmountUnit.removesAtZero(action), value == 0 { return .number(0) }
            let accepted = range ?? declared
            guard accepted.contains(value) else {
                problems.append("\(path): \(format(value)) is outside \(format(accepted.lowerBound))...\(format(accepted.upperBound))")
                return nil
            }
            return .number(value)
        case .integer(let accepted):
            guard case .number(let value) = raw, let whole = Int(exactly: value) else {
                problems.append("\(path): must be an integer")
                return nil
            }
            guard accepted.contains(whole) else {
                problems.append("\(path): \(whole) is outside \(accepted.lowerBound)...\(accepted.upperBound)")
                return nil
            }
            return .number(Double(whole))
        case .boolean:
            guard case .bool(let flag) = raw else {
                problems.append("\(path): must be true or false")
                return nil
            }
            return .bool(flag)
        case .color:
            guard case .string(let text) = raw, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                problems.append("\(path): must be a colour name or #RRGGBB")
                return nil
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard PSColor.named(trimmed) != nil || PSColor(hex: trimmed) != nil else {
                problems.append("\(path): '\(trimmed)' is not a colour name or #RRGGBB")
                return nil
            }
            return .string(trimmed)
        case .point:
            guard let pair = pointPair(raw, strict: true) else {
                problems.append("\(path): must be [x, y]")
                return nil
            }
            guard (0...1_000).contains(pair.x), (0...1_000).contains(pair.y) else {
                problems.append("\(path): x and y must be within 0...1000")
                return nil
            }
            return .point(PSPoint(x: pair.x, y: pair.y))
        case .box:
            guard let corners = boxCorners(raw, strict: true) else {
                problems.append("\(path): must be [x1, y1, x2, y2]")
                return nil
            }
            guard corners.allSatisfy({ (0...1_000).contains($0) }) else {
                problems.append("\(path): x1, y1, x2 and y2 must be within 0...1000")
                return nil
            }
            guard corners[2] > corners[0], corners[3] > corners[1] else {
                problems.append("\(path): x2 and y2 must be greater than x1 and y1")
                return nil
            }
            // A box names a thing: at least 10 of 1000 each way.
            guard corners[2] > corners[0] + 10, corners[3] > corners[1] + 10 else {
                problems.append("\(path): too small: x2 > x1 + 10 and y2 > y1 + 10")
                return nil
            }
            return .box(PSRect(x: corners[0], y: corners[1], width: corners[2] - corners[0], height: corners[3] - corners[1]))
        case .text(let limit):
            guard case .string(let text) = raw else {
                problems.append("\(path): must be a string")
                return nil
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // replacement "" erases the words.
            if trimmed.isEmpty, key != "replacement" {
                problems.append("\(path): empty")
                return nil
            }
            if trimmed.count > limit {
                problems.append("\(path): longer than \(limit) characters")
                return nil
            }
            if trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                problems.append("\(path): control characters")
                return nil
            }
            return .string(trimmed)
        case .ref(let kinds):
            let prefixes = RefKind.allCases.filter(kinds.contains).map { String($0.prefix) }
            guard case .string(let text) = raw, let letter = text.first.map(String.init), prefixes.contains(letter),
                  let number = Int(text.dropFirst()), (1...999).contains(number) else {
                let examples = prefixes.map { "\($0)1" }.joined(separator: ", ")
                problems.append("\(path): '\(raw.string ?? raw.serialized())' is not an id such as \(examples)")
                return nil
            }
            // Masks are a1…a16 (W2): whether one exists is the handler's to say, with the list of masks.
            if letter == String(RefKind.mask.prefix), number > LocalAdjustment.maxPerLayer {
                problems.append("\(path): masks are a1...a\(LocalAdjustment.maxPerLayer)")
                return nil
            }
            return .string(letter + String(number))
        case .list(let item, let max):
            guard case .array(let items) = raw else {
                problems.append("\(path): must be a list")
                return nil
            }
            guard (1...max).contains(items.count) else {
                problems.append("\(path): \(items.count) items, expected 1...\(max)")
                return nil
            }
            var values: [OpValue] = []
            for (index, element) in items.enumerated() {
                guard let value = check(element, kind: item, key: key, range: nil, spec: spec, path: "\(path)[\(index)]", problems: &problems) else { return nil }
                values.append(value)
            }
            return .list(values)
        }
    }

    /// An existing action's amount is read as its AmountUnit reads it: relative percentages go
    /// both ways, a multiplier on a percent is 0…4.
    static func amountRange(_ param: ParamSpec, spec: OperationSpec, object: [String: JSONValue]) -> ClosedRange<Double>? {
        guard param.key == "amount", case .intent(let action) = spec.lowering, let unit = AmountUnit.for(action) else { return nil }
        let mode: AmountSpec.Mode
        switch object["amountMode"]?.string {
        case "absolute": mode = .absolute
        case "multiplier": mode = .multiplier
        default: mode = .relative
        }
        return unit.acceptedRange(mode: mode)
    }

    // MARK: JSON

    /// The call as a step object: {"action": id, …args}, points `[x, y]` and boxes `[x1, y1, x2, y2]` in 0…1000.
    public static func json(_ call: OperationCall) -> JSONValue {
        var object: [String: JSONValue] = ["action": .string(call.id.raw)]
        for (key, value) in call.args { object[key] = json(value) }
        return .object(object)
    }

    static func json(_ value: OpValue) -> JSONValue {
        switch value {
        case .number(let number): return .number(number)
        case .string(let string): return .string(string)
        case .bool(let bool): return .bool(bool)
        case .point(let point): return .array([.number(point.x), .number(point.y)])
        case .box(let box): return .array([.number(box.minX), .number(box.minY), .number(box.maxX), .number(box.maxY)])
        case .list(let values): return .array(values.map(json))
        }
    }

    /// JSON value → OpValue without a spec (numbers, text, flags and lists of them).
    static func opValue(_ value: JSONValue) -> OpValue? {
        switch value {
        case .number(let number): return .number(number)
        case .string(let string): return .string(string)
        case .bool(let bool): return .bool(bool)
        case .array(let array):
            let values = array.compactMap(opValue)
            return values.count == array.count ? .list(values) : nil
        case .null, .object: return nil
        }
    }

    // MARK: Nearest

    /// The domain's operations whose ids are closest to `name`, closest first: spelling
    /// (edit distance on the folded ids) fused with retrieval over the name's words.
    public static func nearest(to name: String, domain: OpDomain, limit: Int = 5) -> [OpID] {
        guard limit > 0 else { return [] }
        let catalog = OperationCatalog.shared
        let specs = catalog.specs(in: domain)
        guard !specs.isEmpty else { return [] }
        let folded = foldedKey(name)
        let words = TextFolding.camelWords(name).replacingOccurrences(of: "_", with: " ")
        let lexical = OperationIndex.shared.ranking(OperationQuery(text: words, domain: domain, language: .english))
        let best = lexical.first?.score ?? 0
        let lexicalScore = Dictionary(lexical.map { ($0.id, best > 0 ? $0.score / best : 0) }, uniquingKeysWith: { first, _ in first })
        var scored: [(OpID, Double, Int)] = []
        for (position, spec) in specs.enumerated() {
            let id = foldedKey(spec.id.raw)
            var spelling = 1 - Double(editDistance(folded, id)) / Double(max(folded.count, id.count, 1))
            if !folded.isEmpty, id.contains(folded) || folded.contains(id) { spelling = max(spelling, 0.75) }
            let score = 0.55 * max(0, spelling) + 0.45 * (lexicalScore[spec.id] ?? 0)
            scored.append((spec.id, score, position))
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
        return scored.filter { $0.1 > 0 }.prefix(limit).map(\.0)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    // MARK: Readers

    /// Lowercased, without accents or anything but letters and digits.
    static func foldedKey(_ text: String) -> String {
        TextFolding.tokens(text).joined().filter { $0.isLetter || $0.isNumber }
    }

    static func scalarText(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): return text
        case .number: return value.serialized()
        default: return nil
        }
    }

    /// A number, or text that is one ("15", "+15", "15 %", "0,5", "-20°").
    static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .number(let number):
            return number.isFinite ? number : nil
        case .string(let text):
            var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            for suffix in ["%", "°", "s", "x", "×"] where cleaned.hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            }
            if cleaned.hasPrefix("+") { cleaned.removeFirst() }
            if cleaned.contains(","), !cleaned.contains(".") { cleaned = cleaned.replacingOccurrences(of: ",", with: ".") }
            guard let parsed = Double(cleaned), parsed.isFinite else { return nil }
            return parsed
        default:
            return nil
        }
    }

    static func boolean(_ value: JSONValue) -> Bool? {
        switch value {
        case .bool(let flag): return flag
        case .number(let number): return number == 1 ? true : number == 0 ? false : nil
        case .string(let text):
            switch foldedKey(text) {
            case "true", "yes", "oui", "vrai", "1", "visible", "show", "affiche": return true
            case "false", "no", "non", "faux", "0", "hidden", "hide", "masque", "cache": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    /// `[x, y]`, `{"x", "y"}` or "x, y", in 0…1000 (0…1 is scaled up). Strict: only the two JSON forms.
    static func pointPair(_ value: JSONValue, strict: Bool = false) -> (x: Double, y: Double)? {
        var pair: (Double, Double)?
        switch value {
        case .array(let items) where items.count == 2:
            if let x = items[0].double, let y = items[1].double { pair = (x, y) }
            if !strict, pair == nil, let x = number(items[0]), let y = number(items[1]) { pair = (x, y) }
        case .object(let object):
            if let x = object["x"]?.double, let y = object["y"]?.double { pair = (x, y) }
            if !strict, pair == nil, let x = object["x"].flatMap(number), let y = object["y"].flatMap(number) { pair = (x, y) }
        case .string(let text) where !strict:
            let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace || $0 == "[" || $0 == "]" })
                .compactMap { number(.string(String($0))) }
            if parts.count == 2 { pair = (parts[0], parts[1]) }
        default:
            break
        }
        guard let (x, y) = pair, x.isFinite, y.isFinite else { return nil }
        let scale = max(abs(x), abs(y)) <= 1 ? 1_000.0 : 1
        return (x * scale, y * scale)
    }

    /// `[x1, y1, x2, y2]`, `{"x1",…}` or text, in 0…1000 (0…1 is scaled up).
    static func boxCorners(_ value: JSONValue, strict: Bool = false) -> [Double]? {
        var corners: [Double]?
        switch value {
        case .array(let items) where items.count == 4:
            let numbers = items.compactMap { strict ? $0.double : number($0) }
            if numbers.count == 4 { corners = numbers }
        case .object(let object):
            let keys = ["x1", "y1", "x2", "y2"]
            let numbers = keys.compactMap { key in object[key].flatMap { strict ? $0.double : number($0) } }
            if numbers.count == 4 { corners = numbers }
        case .string(let text) where !strict:
            let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace || $0 == "[" || $0 == "]" })
                .compactMap { number(.string(String($0))) }
            if parts.count == 4 { corners = parts }
        default:
            break
        }
        guard let corners, corners.allSatisfy(\.isFinite) else { return nil }
        let scale = corners.allSatisfy { abs($0) <= 1 } ? 1_000.0 : 1
        return corners.map { $0 * scale }
    }

    /// Numbers in problem lines read like the JSON they came from.
    static func format(_ value: Double) -> String {
        JSONValue.number(value).serialized()
    }
}
