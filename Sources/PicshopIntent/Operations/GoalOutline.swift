import Foundation
import PicshopCore

/// One step of an outline the 4B writes before acting on a long goal (D20).
public struct OutlineStep: Hashable, Sendable {
    public var op: OpID
    /// ≤ 4 words.
    public var purpose: String

    public init(op: OpID, purpose: String) {
        self.op = op
        self.purpose = purpose
    }
}

/// D20 outline-then-fill (4B only): round 1 asks for up to 12 numbered `op purpose` lines, rounds 2 and 3 fill them
/// in batches of 6 with the cards of exactly those ops. The requests are user-side text (`<task>`), so the prefix
/// stays byte-stable; they are written in English like the rest of the editor state, the purposes in the person's
/// language.
public enum GoalOutline {
    public static let maxSteps = 12, batchSize = 6, maxBatchesPerTurn = 2
    /// The fewest distinct retrieved operations that make a goal long.
    public static let minimumRetrieved = 7

    /// Clause separators (folded tokens): « fond blanc et carré, puis plus lumineux ».
    static let separators: Set<String> = ["et", "puis", "ensuite", "apres", "then", "and", "also", "aussi"]
    /// Goal words (folded): the person asks for the whole job.
    static let goalPhrases = ["complete", "complet", "completement", "de a a z", "tout", "entierement", "fais tout", "everything", "end to end",
                              "from start to finish", "the whole thing"]

    /// ≥ 3 clauses whose retrieved top families differ, or a goal word with ≥ 2 retrieved families; and ≥ 7 distinct
    /// ops retrieved (D20).
    public static func isLongGoal(_ utterance: String, retrieved: [OpID]) -> Bool {
        let distinct = Array(Set(retrieved))
        guard distinct.count >= minimumRetrieved else { return false }
        let catalog = OperationCatalog.shared
        let families = Set(distinct.compactMap { catalog.spec($0)?.category })
        let folded = " " + TextFolding.tokens(utterance).joined(separator: " ") + " "
        if goalPhrases.contains(where: { folded.contains(" \($0) ") }), families.count >= 2 { return true }
        let clauses = self.clauses(utterance)
        guard clauses.count >= 3 else { return false }
        let domain = majorityDomain(distinct, catalog: catalog)
        let language: NormalizedUtterance.Language = NormalizedUtterance(utterance).language
        var tops: Set<OpCategory> = []
        for clause in clauses {
            guard let top = OperationIndex.shared.ranking(OperationQuery(text: clause, domain: domain, language: language)).first,
                  let category = catalog.spec(top.id)?.category else { continue }
            tops.insert(category)
        }
        return tops.count >= 2
    }

    /// A Live turn's words as a long goal (D20), retrieval included: the twelve best operations for its words in the
    /// editor's domain, with what the editor state says is there. Off without the flag.
    /// The retrieval counts the core operations too (the cards leave them out, they are in the prefix) above τ: the
    /// turn's best 12 and each clause's best three, since a long sentence dilutes every word's weight and the
    /// whole-turn query alone under-counts what a many-part goal asks for.
    public static func isLongGoal(turn: LiveUserTurn, mode: EditorMode, index: OperationIndex = .shared) -> Bool {
        guard FeatureFlags.isOn(.outlineFill), turn.kind != .sessionStart else { return false }
        // The words alone first (no index work on an everyday turn): three clauses, or a goal word.
        let parts = clauses(turn.text)
        let folded = " " + TextFolding.tokens(turn.text).joined(separator: " ") + " "
        guard parts.count >= 3 || goalPhrases.contains(where: { folded.contains(" \($0) ") }) else { return false }
        let hints = LocalModelLiveBrain.stateHints(turn.editorState)
        let disabled = OperationGate.disabled()
        func passing(_ text: String, _ limit: Int) -> [OpID] {
            let query = OperationQuery(text: text, domain: mode.opDomain, language: turn.language, hints: hints)
            return index.ranking(query).filter { OperationIndex.passes($0, OperationIndex.threshold) && !disabled.contains($0.id) }.prefix(limit).map(\.id)
        }
        var retrieved = passing(turn.text, maxSteps)
        if parts.count > 1 { for clause in parts { retrieved += passing(clause, 3) } }
        return isLongGoal(turn.text, retrieved: retrieved)
    }

    /// Phrases whose « et » / "and" is not a clause break.
    static let boundPhrases = [("noir et blanc", "noir_et_blanc"), ("black and white", "black_and_white"), ("avant et après", "avant_et_après"),
                               ("before and after", "before_and_after"), ("sel et poivre", "sel_et_poivre")]

    /// The clauses of an utterance: split on commas, semicolons, a colon before a space (« 4:5 » stays whole) and the
    /// separator words (folded).
    static func clauses(_ utterance: String) -> [String] {
        var text = utterance
        for (phrase, bound) in boundPhrases { text = text.replacingOccurrences(of: phrase, with: bound, options: .caseInsensitive) }
        text = text.replacingOccurrences(of: #":\s"#, with: ", ", options: .regularExpression)
        var clauses: [String] = []
        for part in text.split(whereSeparator: { ",;".contains($0) }) {
            var current: [String] = []
            for word in part.split(separator: " ").map(String.init) {
                let folded = TextFolding.tokens(word).joined(separator: " ")
                if separators.contains(folded) {
                    if !current.isEmpty { clauses.append(current.joined(separator: " ")) }
                    current = []
                } else {
                    current.append(word)
                }
            }
            if !current.isEmpty { clauses.append(current.joined(separator: " ")) }
        }
        return clauses.map { $0.replacingOccurrences(of: "_", with: " ") }
            .filter { !TextFolding.tokens($0).filter { !TextFolding.stopwords.contains($0) }.isEmpty }
    }

    static func majorityDomain(_ ids: [OpID], catalog: OperationCatalog) -> OpDomain {
        var counts: [OpDomain: Int] = [:]
        for id in ids { for domain in catalog.spec(id)?.domains ?? [] { counts[domain, default: 0] += 1 } }
        return counts.max { lhs, rhs in lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key.rawValue > rhs.key.rawValue }?.key ?? .photo
    }

    /// The `<task>` text of round 1 (user-side only; the prefix stays byte-stable).
    public static func outlineRequest(language: OpLanguage) -> String {
        let words = language == .fr ? "French" : "English"
        return "This is a long goal. Do not call any tool yet. First write the plan: at most \(maxSteps) numbered lines, in the order to do them, "
            + "one operation per line as `N. opId purpose`, opId exactly as on the cards, purpose at most 4 words in \(words). "
            + "Leave out what no operation can do. Nothing else."
    }

    /// Numbered `op purpose` lines; unknown ids dropped, repeated ids merged (the first purpose kept), at most 12.
    public static func parse(_ text: String, catalog: OperationCatalog) -> [OutlineStep] {
        var steps: [OutlineStep] = []
        var seen: Set<OpID> = []
        let byFolded = Dictionary(catalog.specs.map { (fold($0.id.raw), $0.id) }, uniquingKeysWith: { first, _ in first })
        // A list written on one line (« 1. crop carré 2. adjust plus lumineux… ») is split before each number.
        let lines = text.replacingOccurrences(of: #"\s+(?=\d{1,2}[\.\)]\s)"#, with: "\n", options: .regularExpression)
        for rawLine in lines.split(whereSeparator: \.isNewline) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            // Numbering and bullets: "1.", "1)", "1 -", "-", "*", "•", "**", "Step 1:".
            while let first = line.first, "-*•#>".contains(first) {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            if let match = line.range(of: #"^(?:(?:step|étape|etape)\s*)?\d{1,2}\s*[\.\):-]?\s*"#, options: [.regularExpression, .caseInsensitive]) {
                line.removeSubrange(match)
            }
            line = line.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let head = words.first else { continue }
            let candidate = head.trimmingCharacters(in: CharacterSet(charactersIn: ":,.;()[]\"'"))
            guard let id = byFolded[fold(candidate)] else { continue }
            guard seen.insert(id).inserted else { continue }
            var purpose = words.dropFirst().map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ":—–-")) }.filter { !$0.isEmpty }
            if purpose.count > 4 { purpose = Array(purpose.prefix(4)) }
            steps.append(OutlineStep(op: id, purpose: purpose.joined(separator: " ")))
            if steps.count == maxSteps { break }
        }
        return steps
    }

    /// An id without case, underscores or hyphens ("layer_via" → "layervia").
    static func fold(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The steps a fill round covers (batch 1: the first 6, batch 2: the next 6).
    public static func batch(_ number: Int, of steps: [OutlineStep]) -> [OutlineStep] {
        let start = max(0, number - 1) * batchSize
        guard start < steps.count else { return [] }
        return Array(steps[start..<min(steps.count, start + batchSize)])
    }

    /// The `<task>` text of fill round `batch` (1 or 2): exactly those steps, in one apply_edits call.
    public static func fillRequest(batch: Int, steps: [OutlineStep], language: OpLanguage) -> String {
        let chosen = self.batch(batch, of: steps)
        guard !chosen.isEmpty else { return "" }
        let first = (batch - 1) * batchSize + 1
        let list = chosen.enumerated().map { "\(first + $0.offset). \($0.element.op.raw) \($0.element.purpose)".trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        let said = language == .fr ? "French" : "English"
        return "Now do steps \(first) to \(first + chosen.count - 1) of your plan in ONE apply_edits call, these steps in this order "
            + "(at most \(batchSize)), using the cards above; skip a step you cannot fill. Say one short sentence in \(said) first.\n" + list
    }

    /// The `<task>` of the round after an outline round that wrote no usable plan: act now, within one batch.
    public static func directRequest(language: OpLanguage) -> String {
        let said = language == .fr ? "French" : "English"
        return "Now do the most important steps of that goal in ONE apply_edits call (at most \(batchSize) steps), using the cards above. "
            + "Say one short sentence in \(said) first."
    }

    /// The `<task>` a model without outlines (the 2B) gets on a long goal: the first batch only, honestly.
    public static func firstStepsRequest(language: OpLanguage) -> String {
        let said = language == .fr ? "French" : "English"
        return "This is a long goal. Do only its first \(batchSize) steps now, in ONE apply_edits call, in the order to do them. "
            + "Say one short sentence in \(said) first."
    }

    /// The outline said once before acting: « Je fais ça en deux temps : fond blanc, format carré, plus lumineux… ».
    public static func spokenOutline(_ steps: [OutlineStep], french: Bool) -> String {
        let purposes = steps.map(\.purpose).filter { !$0.isEmpty }
        let shown = purposes.prefix(3).joined(separator: ", ")
        let more = steps.count - min(3, purposes.count)
        let plural = more > 1 ? "s" : ""
        if french {
            guard !shown.isEmpty else { return "Je fais ça en deux temps : \(steps.count) étapes." }
            return "Je fais ça en deux temps : " + shown + (more > 0 ? " et \(more) autre\(plural) étape\(plural)." : ".")
        }
        guard !shown.isEmpty else { return "I'll do this in two passes: \(steps.count) steps." }
        return "I'll do this in two passes: " + shown + (more > 0 ? " and \(more) more step\(plural)." : ".")
    }

    /// Said when a turn stops with outline steps left: « J'ai fait les 12 premières étapes ; dis « continue » pour la suite. »
    public static func stoppedLine(done: Int, french: Bool) -> String {
        french ? "J'ai fait les \(done) premières étapes ; dis « continue » pour la suite."
               : "I've done the first \(done) steps; say “continue” for the rest."
    }

    /// The 2B's and Foundation Models' honest line on a long goal (they keep no outline, so never « continue »).
    /// `count` nil: Foundation Models, whose apply_edits takes fewer steps per call, says no number.
    public static func firstStepsLine(count: Int? = batchSize, french: Bool) -> String {
        guard let count else {
            return french ? "J'ai fait les premières étapes ; redis-moi la suite." : "I've done the first steps; tell me the rest again."
        }
        return french ? "Je fais les \(count) premières étapes ; redis-moi la suite." : "I'm doing the first \(count) steps; tell me the rest again."
    }

    /// The recap line that carries a pending outline across a compaction: `outline: curves S curve | addFillLayer white`.
    public static func recapLine(_ steps: [OutlineStep]) -> String? {
        guard !steps.isEmpty else { return nil }
        return "outline: " + steps.map { "\($0.op.raw) \($0.purpose)".trimmingCharacters(in: .whitespaces) }.joined(separator: " | ")
    }

    /// The words that resume a pending outline: « continue », « la suite », « vas-y », "keep going", "go on".
    public static let continueWords: Set<String> = ["continue", "la suite", "vas y", "keep going", "go on", "continue stp", "et la suite",
                                                    "on continue", "carry on", "continue please"]

    public static func isContinue(_ utterance: String) -> Bool {
        continueWords.contains(TextFolding.tokens(utterance).joined(separator: " "))
    }
}
