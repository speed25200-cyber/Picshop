import Foundation
import PicshopCore

/// What the help sheet lists (W2): the catalog's operations grouped by category, in catalog order, with two
/// positive examples each. HelpSheet (PicshopUI) renders it above its own content.
public enum OperationHelp {
    /// Examples shown per operation.
    public static let examplesPerOperation = 2

    /// One section per category the domain has (in the order its first operation appears in the catalog); in
    /// each, one item per example: the operation's title and a sentence to say, in the language asked (the
    /// other language's examples when it has none). Operations the flags turn off are left out.
    public static func sections(domain: OpDomain, language: OpLanguage) -> [(title: String, items: [(title: String, say: String)])] {
        let disabled = OperationGate.disabled()
        var order: [OpCategory] = []
        var grouped: [OpCategory: [(title: String, say: String)]] = [:]
        for spec in OperationCatalog.shared.specs(in: domain) where !disabled.contains(spec.id) {
            let says = sentences(spec, language: language)
            guard !says.isEmpty else { continue }
            if grouped[spec.category] == nil { order.append(spec.category) }
            let title = language == .fr ? spec.title.fr : spec.title.en
            grouped[spec.category, default: []] += says.map { (title: title, say: $0) }
        }
        return order.map { category in (title: categoryTitle(category, language: language), items: grouped[category] ?? []) }
    }

    /// Two positive examples (or paraphrases), the language asked first.
    static func sentences(_ spec: OperationSpec, language: OpLanguage) -> [String] {
        let said = spec.examples.filter { $0.role == .positive }
        let preferred = said.filter { $0.language == language } + said.filter { $0.language != language }
        var seen: Set<String> = []
        return preferred.map(\.say).filter { seen.insert($0.lowercased()).inserted }.prefix(examplesPerOperation).map { $0 }
    }

    static func categoryTitle(_ category: OpCategory, language: OpLanguage) -> String {
        let titles: [OpCategory: (fr: String, en: String)] = [
            .light: ("Lumière", "Light"), .color: ("Couleur", "Colour"), .detail: ("Détails", "Detail"), .retouch: ("Retouche", "Retouch"),
            .objects: ("Objets", "Objects"), .background: ("Arrière-plan", "Background"), .geometry: ("Cadrage", "Framing"), .text: ("Texte", "Text"),
            .layers: ("Calques", "Layers"), .shapes: ("Formes", "Shapes"), .selection: ("Masques et sélection", "Masks and selection"),
            .generative: ("Génératif", "Generative"), .effects: ("Effets", "Effects"), .table: ("Tableaux", "Tables"), .cut: ("Montage", "Editing"),
            .speed: ("Vitesse", "Speed"), .audio: ("Audio", "Audio"), .captions: ("Sous-titres", "Captions"), .transitions: ("Transitions", "Transitions"),
            .overlays: ("Incrustations", "Overlays"), .motion: ("Mouvement", "Motion"), .clipColor: ("Couleur des clips", "Clip colour"),
            .story: ("Récit", "Story"), .pages: ("Pages", "Pages"), .annotate: ("Annoter", "Annotate"), .pdfText: ("Texte du PDF", "PDF text"),
            .sign: ("Signer", "Sign"), .document: ("Document", "Document"), .export: ("Exporter", "Export"), .history: ("Historique", "History"),
        ]
        let title = titles[category] ?? (category.rawValue, category.rawValue)
        return language == .fr ? title.fr : title.en
    }
}
