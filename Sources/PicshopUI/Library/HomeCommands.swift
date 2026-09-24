#if canImport(SwiftUI) && canImport(PhotosUI) && canImport(UIKit)
import Foundation
import PicshopCore
import PicshopIntent

/// One-tap results from Home: pick a photo or a video and the editor opens
/// already doing the thing, through the same command pipeline as the voice.
enum MagicShortcut: String, CaseIterable, Identifiable {
    case captions, highlights, jumpCuts, fillers, vertical, eraseObjects, expand, cutout, enhance, portrait

    var id: String { rawValue }

    var isVideo: Bool {
        switch self {
        case .captions, .highlights, .jumpCuts, .fillers, .vertical: return true
        default: return false
        }
    }

    /// The command the editor runs, in the interface language.
    var command: String {
        let fr = psPrefersFrench
        switch self {
        case .captions: return fr ? "ajoute des sous-titres" : "add captions"
        case .jumpCuts: return fr ? "enlève les blancs" : "remove the pauses"
        case .highlights: return fr ? "fais un résumé de 30 secondes" : "make a 30 second recap"
        case .fillers: return fr ? "enlève les euh" : "remove the ums"
        case .vertical: return fr ? "passe en vertical en suivant le sujet" : "smart reframe to vertical"
        case .eraseObjects: return fr ? "enlève les passants" : "remove the passers-by"
        case .expand: return fr ? "étends l'image" : "expand the image"
        case .cutout: return fr ? "enlève le fond" : "remove the background"
        case .enhance: return fr ? "améliore la photo" : "auto enhance"
        case .portrait: return fr ? "floute l'arrière-plan" : "blur the background"
        }
    }
}

/// What Home does with a typed or dictated sentence.
enum HomeCommand: Equatable {
    /// Pick a photo or a video; the editor opens running the shortcut.
    case magic(MagicShortcut)
    case magicMovie
    /// Pick new media of that kind.
    case pick(ProjectSummary.Kind)
    case open(UUID)
    /// Nothing to do on Home: say so, in the sentence's language.
    case reply(String, isProblem: Bool)
}

/// Home's small grammar. Everything is matched on the device, on
/// `NormalizedUtterance` (lowercase, no accents); nothing leaves the phone.
enum HomeCommands {
    /// A title matches when at least this share of the sentence's words are in it.
    static let titleOverlap = 0.6

    static func interpret(_ text: String, projects: [ProjectSummary]) -> HomeCommand? {
        let utterance = NormalizedUtterance(text)
        guard !utterance.tokens.isEmpty else { return nil }
        let french = utterance.language == .french
        let phrase = " " + utterance.text + " "
        let tokens = utterance.tokens

        if let verb = tokens.firstIndex(where: openVerbs.contains), verb <= 2 {
            return open(Array(tokens[(verb + 1)...]), projects: projects, french: french)
        }
        if has(phrase, [" film magique", " film magic", " magic movie", " montage magique"]) { return .magicMovie }
        if has(phrase, [" sous titr", " soustitr", " caption", " subtitle"]) { return .magic(.captions) }
        if has(phrase, [" vertical", " 9 16 ", " 9:16 ", " story "]) { return .magic(.vertical) }
        if has(phrase, [" efface", " effacer", " nettoi", " nettoy", " clean", " erase", " passants ", " passers"]) { return .magic(.eraseObjects) }
        return .reply(french ? "Ouvre une photo ou une vidéo, puis parle-moi." : "Open a photo or a video, then talk to me.", isProblem: false)
    }

    // MARK: Opening

    static let openVerbs: Set<String> = ["ouvre", "ouvrir", "ouvrez", "rouvre", "reouvre", "reprends", "reprendre", "open", "reopen", "resume", "continue", "continuer"]
    private static let recency: Set<String> = ["dernier", "derniere", "derniers", "dernieres", "last", "latest", "recent", "recente", "precedent", "precedente", "previous"]
    private static let newWords: Set<String> = ["un", "une", "a", "an", "nouveau", "nouvelle", "new", "autre", "another"]
    private static let stopwords: Set<String> = [
        "le", "la", "les", "l", "de", "du", "des", "d", "mon", "ma", "mes", "ce", "cette", "ces", "moi", "me", "m", "stp", "svp",
        "s", "il", "te", "vous", "plait", "peux", "tu", "pourrais", "projet", "fichier", "sur", "avec", "en", "a",
        "the", "my", "that", "this", "please", "can", "you", "project", "file", "of", "with", "on", "in", "to", "up", "for", "me",
    ]
    private static let kindWords: [String: ProjectSummary.Kind] = [
        "photo": .photo, "photos": .photo, "image": .photo, "images": .photo, "picture": .photo, "pic": .photo,
        "video": .video, "videos": .video, "film": .video, "clip": .video, "movie": .video,
        "pdf": .pdf, "pdfs": .pdf, "document": .pdf, "doc": .pdf,
    ]

    private static func open(_ words: [String], projects: [ProjectSummary], french: Bool) -> HomeCommand {
        var kind: ProjectSummary.Kind?
        var wantsLatest = false
        var wantsNew = false
        var content: [String] = []
        for (index, word) in words.enumerated() {
            if let found = kindWords[word] {
                kind = found
                // "une photo", "a new video": new media, unless a title follows.
                if index > 0, newWords.contains(words[index - 1]) { wantsNew = true }
            } else if recency.contains(word) {
                wantsLatest = true
            } else if !stopwords.contains(word), !newWords.contains(word) {
                content.append(word)
            }
        }
        let pool = kind.map { kind in projects.filter { $0.kind == kind } } ?? projects
        if content.isEmpty {
            if wantsNew, !wantsLatest, let kind { return .pick(kind) }
            if let latest = pool.first { return .open(latest.id) }
            if let kind { return .pick(kind) }
            return .reply(french ? "Tu n'as pas encore de projet. Ouvre une photo ou une vidéo." : "You have no projects yet. Open a photo or a video.", isProblem: false)
        }
        if let match = bestMatch(content, in: pool) ?? (kind != nil ? bestMatch(content, in: projects) : nil) {
            return .open(match.id)
        }
        return .reply(french ? "Je ne trouve pas ce projet." : "I can't find that project.", isProblem: true)
    }

    /// The project whose title holds the largest share of `words` (at least
    /// `titleOverlap`); the newest wins a tie, as `projects` is newest first.
    static func bestMatch(_ words: [String], in projects: [ProjectSummary]) -> ProjectSummary? {
        guard !words.isEmpty else { return nil }
        var best: (summary: ProjectSummary, score: Double)?
        for project in projects {
            let title = Set(NormalizedUtterance(project.title).tokens)
            let hits = words.filter { word in title.contains { same($0, word) } }.count
            let score = Double(hits) / Double(words.count)
            if score >= titleOverlap, score > (best?.score ?? 0) { best = (project, score) }
        }
        return best?.summary
    }

    /// Equal, or one a plural or a prefix of the other ("plage" / "plages").
    private static func same(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        guard min(lhs.count, rhs.count) >= 4 else { return false }
        return lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }

    private static func has(_ phrase: String, _ needles: [String]) -> Bool {
        needles.contains { phrase.contains($0) }
    }
}
#endif
