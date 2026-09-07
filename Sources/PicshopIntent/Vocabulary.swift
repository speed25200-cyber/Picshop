import Foundation
import PicshopCore

/// Maps spoken nouns (French/English, singular/plural) to canonical English
/// labels that the vision grounding layer understands, plus the WordNet-ish
/// synonyms Vision's classifier may report for each label.
public enum ObjectVocabulary {
    public struct Entry: Sendable {
        public let label: String
        /// Spoken forms, normalised (lower-case, no accents).
        public let spoken: [String]
        /// Classifier identifiers (Vision `VNClassifyImageRequest` taxonomy) that count as this label.
        public let classifierTerms: [String]
        /// Category used for coarse matching and person/animal detectors.
        public let category: Category

        public enum Category: String, Sendable {
            case person, animal, vehicle, furniture, nature, object, text, blemish, generic, region
        }
    }

    public static let entries: [Entry] = [
        Entry(label: "person", spoken: ["person", "people", "personne", "personnes", "gens", "man", "men", "homme", "hommes", "woman", "women", "femme", "femmes", "guy", "guys", "mec", "type", "monsieur", "madame", "dame", "lady", "kid", "kids", "child", "children", "enfant", "enfants", "boy", "garcon", "girl", "fille", "baby", "bebe", "tourist", "tourists", "touriste", "touristes", "passant", "passants", "passerby", "stranger", "inconnu", "photobomber", "someone", "quelqu un", "crowd", "foule", "human", "humain", "bystander", "silhouette", "him", "her", "lui", "elle", "them", "eux", "elles", "me", "moi", "myself", "moi meme", "couple", "family", "famille"], classifierTerms: ["person", "people", "man", "woman", "child", "boy", "girl", "baby", "adult", "crowd", "human", "face", "pedestrian"], category: .person),
        Entry(label: "face", spoken: ["face", "visage", "tete", "head"], classifierTerms: ["face", "head", "person"], category: .person),
        Entry(label: "hand", spoken: ["hand", "hands", "main", "mains", "finger", "doigt", "doigts", "arm", "bras"], classifierTerms: ["hand", "arm", "finger"], category: .person),
        Entry(label: "dog", spoken: ["dog", "dogs", "chien", "chiens", "chiot", "puppy", "puppies", "toutou"], classifierTerms: ["dog", "puppy", "canine", "hound", "terrier", "retriever", "labrador", "bulldog", "poodle", "shepherd"], category: .animal),
        Entry(label: "cat", spoken: ["cat", "cats", "chat", "chats", "chaton", "kitten", "kitty", "minou"], classifierTerms: ["cat", "kitten", "feline", "tabby"], category: .animal),
        Entry(label: "bird", spoken: ["bird", "birds", "oiseau", "oiseaux", "pigeon", "pigeons", "seagull", "mouette", "mouettes", "goeland", "crow", "corbeau"], classifierTerms: ["bird", "pigeon", "seagull", "gull", "crow", "sparrow", "duck", "goose"], category: .animal),
        Entry(label: "horse", spoken: ["horse", "horses", "cheval", "chevaux", "pony", "poney"], classifierTerms: ["horse", "pony", "equine"], category: .animal),
        Entry(label: "cow", spoken: ["cow", "cows", "vache", "vaches", "boeuf", "bull", "taureau"], classifierTerms: ["cow", "cattle", "bull", "ox"], category: .animal),
        Entry(label: "sheep", spoken: ["sheep", "mouton", "moutons", "goat", "chevre", "chevres", "lamb", "agneau"], classifierTerms: ["sheep", "goat", "lamb"], category: .animal),
        Entry(label: "animal", spoken: ["animal", "animals", "animaux", "bete", "bestiole", "insect", "insecte", "mosquito", "moustique", "fly", "mouche", "spider", "araignee"], classifierTerms: ["animal", "insect", "spider", "fly", "wildlife"], category: .animal),
        Entry(label: "car", spoken: ["car", "cars", "voiture", "voitures", "auto", "automobile", "bagnole", "vehicle", "vehicule", "vehicules", "taxi", "van", "camionnette", "suv", "jeep"], classifierTerms: ["car", "automobile", "vehicle", "taxi", "van", "sedan", "convertible", "jeep", "sports car", "minivan", "suv", "wagon"], category: .vehicle),
        Entry(label: "truck", spoken: ["truck", "trucks", "camion", "camions", "lorry", "poids lourd", "pickup"], classifierTerms: ["truck", "lorry", "pickup", "trailer", "tractor"], category: .vehicle),
        Entry(label: "bus", spoken: ["bus", "autobus", "autocar", "car de tourisme", "coach", "tram", "tramway", "train", "metro"], classifierTerms: ["bus", "coach", "tram", "train", "streetcar", "trolley"], category: .vehicle),
        Entry(label: "bicycle", spoken: ["bike", "bikes", "bicycle", "bicycles", "velo", "velos", "bicyclette", "cycliste", "cyclist", "scooter", "trottinette"], classifierTerms: ["bicycle", "bike", "cyclist", "scooter", "tricycle"], category: .vehicle),
        Entry(label: "motorcycle", spoken: ["motorcycle", "motorcycles", "motorbike", "moto", "motos", "scooter a moteur", "vespa"], classifierTerms: ["motorcycle", "motorbike", "moped", "scooter"], category: .vehicle),
        Entry(label: "boat", spoken: ["boat", "boats", "bateau", "bateaux", "ship", "navire", "voilier", "sailboat", "yacht", "kayak", "canoe", "canoe", "jet ski", "paddle"], classifierTerms: ["boat", "ship", "sailboat", "yacht", "kayak", "canoe", "vessel", "ferry", "speedboat", "watercraft"], category: .vehicle),
        Entry(label: "airplane", spoken: ["plane", "planes", "airplane", "aeroplane", "avion", "avions", "jet", "helicopter", "helicoptere", "drone"], classifierTerms: ["airplane", "aircraft", "plane", "jet", "helicopter", "drone", "airliner"], category: .vehicle),
        Entry(label: "tree", spoken: ["tree", "trees", "arbre", "arbres", "branch", "branches", "branche", "bush", "buisson", "buissons", "palm", "palmier", "sapin", "hedge", "haie"], classifierTerms: ["tree", "branch", "bush", "shrub", "palm", "foliage", "hedge", "plant"], category: .nature),
        Entry(label: "plant", spoken: ["plant", "plants", "plante", "plantes", "flower", "flowers", "fleur", "fleurs", "pot", "pot de fleurs", "cactus", "leaf", "feuille", "feuilles", "leaves", "grass", "herbe", "weeds", "mauvaises herbes"], classifierTerms: ["plant", "flower", "houseplant", "potted plant", "cactus", "leaf", "grass", "weed", "vase"], category: .nature),
        Entry(label: "cloud", spoken: ["cloud", "clouds", "nuage", "nuages"], classifierTerms: ["cloud", "sky"], category: .nature),
        Entry(label: "sky", spoken: ["sky", "ciel", "the sky", "le ciel", "heaven", "sunset", "coucher de soleil"], classifierTerms: ["sky", "cloud", "sunset"], category: .region),
        Entry(label: "background", spoken: ["backdrop", "the background", "l arriere plan", "le fond", "decor"], classifierTerms: [], category: .region),
        Entry(label: "hair", spoken: ["hair", "cheveux", "chevelure", "barbe", "beard"], classifierTerms: ["hair", "beard"], category: .person),
        Entry(label: "eyes", spoken: ["eyes", "eye", "yeux", "oeil", "regard"], classifierTerms: ["eye"], category: .person),
        Entry(label: "teeth", spoken: ["teeth", "tooth", "dents", "smile", "sourire"], classifierTerms: ["teeth", "smile"], category: .person),
        Entry(label: "grass", spoken: ["grass", "herbe", "pelouse", "lawn", "gazon", "field", "champ"], classifierTerms: ["grass", "lawn", "field", "meadow"], category: .region),
        Entry(label: "water", spoken: ["water", "eau", "sea", "mer", "ocean", "lake", "lac", "river", "riviere", "pool", "piscine"], classifierTerms: ["water", "sea", "ocean", "lake", "river", "pool"], category: .region),
        Entry(label: "rock", spoken: ["rock", "rocks", "rocher", "rochers", "stone", "stones", "pierre", "pierres", "caillou", "cailloux", "boulder"], classifierTerms: ["rock", "stone", "boulder", "pebble"], category: .nature),
        Entry(label: "pole", spoken: ["pole", "poles", "poteau", "poteaux", "lamppost", "lampadaire", "lampadaires", "streetlight", "reverbere", "post", "mat", "pylon", "pylone", "antenna", "antenne"], classifierTerms: ["pole", "lamppost", "streetlight", "post", "pylon", "antenna", "mast", "column"], category: .object),
        Entry(label: "wire", spoken: ["wire", "wires", "fil", "fils", "cable", "cables", "cable electrique", "fils electriques", "power line", "power lines", "ligne electrique", "lignes electriques", "cord", "cordon"], classifierTerms: ["wire", "cable", "power line", "cord", "rope"], category: .object),
        Entry(label: "sign", spoken: ["sign", "signs", "panneau", "panneaux", "pancarte", "pancartes", "billboard", "affiche", "affiches", "poster", "posters", "signpost", "plaque", "banner", "banniere"], classifierTerms: ["sign", "signboard", "billboard", "poster", "street sign", "traffic sign", "banner", "placard"], category: .object),
        Entry(label: "trash", spoken: ["trash", "garbage", "rubbish", "litter", "poubelle", "poubelles", "dechet", "dechets", "ordure", "ordures", "trash can", "bin", "dustbin", "wrapper", "emballage", "papier", "paper", "megot", "cigarette"], classifierTerms: ["trash", "garbage", "litter", "trash can", "bin", "waste", "rubbish", "wrapper", "paper", "cigarette"], category: .object),
        Entry(label: "bottle", spoken: ["bottle", "bottles", "bouteille", "bouteilles", "can", "canette", "canettes", "gourde", "flask"], classifierTerms: ["bottle", "can", "flask", "water bottle", "beverage"], category: .object),
        Entry(label: "cup", spoken: ["cup", "cups", "tasse", "tasses", "mug", "glass", "verre", "verres", "gobelet", "coffee", "cafe"], classifierTerms: ["cup", "mug", "glass", "coffee cup", "wine glass", "beverage", "drink"], category: .object),
        Entry(label: "plate", spoken: ["plate", "plates", "assiette", "assiettes", "bowl", "bol", "dish", "plat", "food", "nourriture", "fork", "fourchette", "knife", "couteau", "spoon", "cuillere"], classifierTerms: ["plate", "bowl", "dish", "food", "fork", "knife", "spoon", "tableware", "cutlery"], category: .object),
        Entry(label: "phone", spoken: ["phone", "phones", "telephone", "portable", "smartphone", "iphone", "cellphone", "mobile"], classifierTerms: ["phone", "cellphone", "smartphone", "telephone", "mobile phone", "electronic device"], category: .object),
        Entry(label: "laptop", spoken: ["laptop", "computer", "ordinateur", "ordi", "pc", "mac", "macbook", "screen", "ecran", "monitor", "tv", "tele", "television"], classifierTerms: ["laptop", "computer", "monitor", "screen", "television", "keyboard", "display"], category: .object),
        Entry(label: "bag", spoken: ["bag", "bags", "sac", "sacs", "backpack", "sac a dos", "handbag", "purse", "suitcase", "valise", "valises", "luggage", "bagage", "bagages", "cabas"], classifierTerms: ["bag", "backpack", "handbag", "purse", "suitcase", "luggage", "tote"], category: .object),
        Entry(label: "chair", spoken: ["chair", "chairs", "chaise", "chaises", "fauteuil", "armchair", "bench", "banc", "bancs", "stool", "tabouret", "sofa", "canape", "couch", "seat", "siege"], classifierTerms: ["chair", "armchair", "bench", "stool", "sofa", "couch", "seat", "furniture"], category: .furniture),
        Entry(label: "table", spoken: ["table", "tables", "desk", "bureau", "counter", "comptoir"], classifierTerms: ["table", "desk", "counter", "furniture"], category: .furniture),
        Entry(label: "lamp", spoken: ["lamp", "lamps", "lampe", "lampes", "light", "lumiere", "luminaire", "chandelier", "lustre"], classifierTerms: ["lamp", "light", "chandelier", "lantern", "light fixture"], category: .furniture),
        Entry(label: "umbrella", spoken: ["umbrella", "umbrellas", "parapluie", "parapluies", "parasol", "parasols"], classifierTerms: ["umbrella", "parasol"], category: .object),
        Entry(label: "ball", spoken: ["ball", "balls", "ballon", "ballons", "balle", "balles", "frisbee"], classifierTerms: ["ball", "balloon", "frisbee", "soccer ball", "football", "basketball"], category: .object),
        Entry(label: "balloon", spoken: ["balloon", "balloons", "ballon gonflable", "ballons gonflables", "montgolfiere"], classifierTerms: ["balloon", "hot air balloon"], category: .object),
        Entry(label: "hat", spoken: ["hat", "hats", "chapeau", "chapeaux", "cap", "casquette", "bonnet", "beanie", "helmet", "casque"], classifierTerms: ["hat", "cap", "helmet", "headwear", "beanie"], category: .object),
        Entry(label: "glasses", spoken: ["glasses", "lunettes", "sunglasses", "lunettes de soleil", "eyeglasses"], classifierTerms: ["glasses", "sunglasses", "eyeglasses", "spectacles"], category: .object),
        Entry(label: "shoe", spoken: ["shoe", "shoes", "chaussure", "chaussures", "basket", "baskets", "sneaker", "sneakers", "boot", "bottes", "sandal", "sandale"], classifierTerms: ["shoe", "sneaker", "boot", "sandal", "footwear"], category: .object),
        Entry(label: "watch", spoken: ["watch", "montre", "bracelet", "jewelry", "bijou", "bijoux", "necklace", "collier", "ring", "bague", "earring", "boucle d oreille"], classifierTerms: ["watch", "bracelet", "jewelry", "necklace", "ring", "earring"], category: .object),
        Entry(label: "camera", spoken: ["camera", "appareil photo", "camescope", "tripod", "trepied"], classifierTerms: ["camera", "tripod", "lens"], category: .object),
        Entry(label: "building", spoken: ["building", "buildings", "batiment", "batiments", "immeuble", "immeubles", "house", "maison", "maisons", "tower", "tour", "crane", "grue", "grues", "scaffolding", "echafaudage", "wall", "mur", "fence", "cloture", "barriere", "gate", "portail", "bridge", "pont"], classifierTerms: ["building", "house", "tower", "crane", "scaffolding", "wall", "fence", "gate", "bridge", "skyscraper", "structure"], category: .object),
        Entry(label: "window", spoken: ["window", "windows", "fenetre", "fenetres", "door", "porte", "portes", "mirror", "miroir"], classifierTerms: ["window", "door", "mirror"], category: .object),
        Entry(label: "vehicle", spoken: ["traffic", "circulation", "trafic"], classifierTerms: ["vehicle", "car", "truck", "bus"], category: .vehicle),
        Entry(label: "text", spoken: ["text", "texte", "writing", "ecriture", "words", "mots", "letters", "lettres", "caption", "legende", "subtitle", "sous titre", "sous titres", "watermark", "filigrane", "logo", "logos", "date", "timestamp", "sticker", "stickers", "emoji", "label", "etiquette", "price", "prix", "tag"], classifierTerms: ["text", "sign", "logo", "label", "sticker", "document", "handwriting"], category: .text),
        Entry(label: "blemish", spoken: ["blemish", "blemishes", "spot", "spots", "tache", "taches", "pimple", "pimples", "bouton", "boutons", "acne", "scar", "cicatrice", "wrinkle", "wrinkles", "ride", "rides", "mole", "grain de beaute", "stain", "stains", "dust", "poussiere", "poussieres", "scratch", "rayure", "rayures", "crack", "fissure", "smudge", "trace", "traces", "reflection", "reflet", "reflets", "glare", "flare", "lens flare", "highlight", "hot spot", "shadow", "ombre", "ombres", "shine", "brillance", "red eye", "yeux rouges", "hair", "cheveu", "cheveux", "poil", "poils", "crumb", "miette", "miettes"], classifierTerms: [], category: .blemish),
        Entry(label: "object", spoken: ["object", "objet", "thing", "things", "truc", "trucs", "machin", "chose", "stuff", "that", "this", "ca", "cela", "it", "element", "distraction", "distractions", "clutter", "bazar", "mess", "desordre", "item"], classifierTerms: [], category: .generic),
        Entry(label: "shadow", spoken: ["shadow", "shadows", "ombre portee"], classifierTerms: ["shadow"], category: .blemish),
    ]

    private static let lookup: [String: Entry] = {
        var map: [String: Entry] = [:]
        for entry in entries {
            for form in entry.spoken {
                if map[form] == nil { map[form] = entry }
            }
        }
        return map
    }()

    public static func entry(forLabel label: String) -> Entry? {
        entries.first { $0.label == label }
    }

    /// Returns the best entry for a spoken phrase such as "chien", "the two dogs",
    /// "power lines". Multi-word forms are matched longest-first.
    public static func match(_ phrase: String) -> (entry: Entry, matchedForm: String)? {
        let normalized = NormalizedUtterance.normalize(phrase)
        let tokens = normalized.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil }
        // Try n-grams from longest to shortest.
        for length in stride(from: min(4, tokens.count), through: 1, by: -1) {
            for start in 0...(tokens.count - length) {
                let candidate = tokens[start..<(start + length)].joined(separator: " ")
                if let entry = lookup[candidate] { return (entry, candidate) }
                if length == 1, let singular = singularize(candidate), let entry = lookup[singular] { return (entry, candidate) }
            }
        }
        return nil
    }

    static func singularize(_ word: String) -> String? {
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("aux") { return String(word.dropLast(3)) + "al" }
        if word.hasSuffix("es"), word.count > 4 { return String(word.dropLast(2)) }
        if word.hasSuffix("s"), word.count > 3 { return String(word.dropLast()) }
        if word.hasSuffix("x"), word.count > 3 { return String(word.dropLast()) }
        return nil
    }

    /// Words that can be dropped from a target phrase without changing meaning.
    public static let fillerWords: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "le", "la", "les", "l", "un", "une", "des", "du", "de", "d", "ce", "cet", "cette",
        "ces", "mon", "ma", "mes", "my", "sur", "on", "dans", "in", "de", "of", "photo", "image", "picture", "video", "frame", "there", "here",
        "la bas", "ici", "please", "s il te plait", "s il vous plait", "stp", "svp", "qui", "est", "which", "is", "who", "y", "il", "s", "te", "vous",
        "plait", "merci", "thanks", "thank", "you", "tu", "peux", "pouvez", "can", "could", "would", "like", "want", "veux", "voudrais", "je", "i", "d",
    ]

    /// Colour and material adjectives that describe (not identify) a target.
    public static let attributeWords: Set<String> = [
        "red", "rouge", "blue", "bleu", "bleue", "green", "vert", "verte", "yellow", "jaune", "white", "blanc", "blanche", "black", "noir",
        "noire", "orange", "pink", "rose", "purple", "violet", "gray", "grey", "gris", "grise", "brown", "marron", "brun", "wooden", "en bois",
        "metal", "metallique", "plastic", "plastique", "old", "vieux", "vieille", "young", "jeune", "tall", "grand", "short", "petit",
        "striped", "raye", "dark", "sombre", "light", "clair", "bright", "shiny", "brillant",
    ]
}

/// Spoken synonyms for adjustment parameters and the direction they imply.
public enum ParameterVocabulary {
    public struct Match: Sendable {
        public let parameter: AdjustmentParameter
        /// +1 or -1 when the word itself implies a direction ("brighter", "assombris"), 0 otherwise.
        public let impliedDirection: Int
        public let matchedPhrase: String
    }

    /// (phrase, parameter, implied direction). Longer phrases win.
    static let table: [(String, AdjustmentParameter, Int)] = [
        // Exposure / brightness
        ("exposure", .exposure, 0), ("exposition", .exposure, 0), ("expose", .exposure, 0), ("overexposed", .exposure, -1), ("surexpose", .exposure, -1),
        ("surexposee", .exposure, -1), ("underexposed", .exposure, 1), ("sous expose", .exposure, 1), ("sous exposee", .exposure, 1),
        ("brightness", .brightness, 0), ("luminosite", .brightness, 0), ("brighter", .brightness, 1), ("brighten", .brightness, 1),
        ("lighter", .brightness, 1), ("lighten", .brightness, 1), ("plus clair", .brightness, 1), ("plus claire", .brightness, 1),
        ("plus lumineux", .brightness, 1), ("plus lumineuse", .brightness, 1), ("eclaircis", .brightness, 1), ("eclaircir", .brightness, 1),
        ("eclairci", .brightness, 1), ("illumine", .brightness, 1), ("too dark", .brightness, 1), ("trop sombre", .brightness, 1),
        ("trop foncee", .brightness, 1), ("trop fonce", .brightness, 1), ("darker", .brightness, -1), ("darken", .brightness, -1),
        ("plus sombre", .brightness, -1), ("plus fonce", .brightness, -1), ("plus foncee", .brightness, -1), ("assombris", .brightness, -1),
        ("assombrir", .brightness, -1), ("assombri", .brightness, -1), ("too bright", .brightness, -1), ("trop clair", .brightness, -1),
        ("trop claire", .brightness, -1), ("trop lumineux", .brightness, -1), ("trop lumineuse", .brightness, -1), ("bright", .brightness, 1),
        ("lumineux", .brightness, 1), ("lumineuse", .brightness, 1), ("dark", .brightness, -1), ("sombre", .brightness, -1), ("fonce", .brightness, -1), ("foncee", .brightness, -1), ("light", .brightness, 1),
        ("c est sombre", .brightness, 1), ("it s dark", .brightness, 1), ("it is dark", .brightness, 1), ("looks dark", .brightness, 1), ("elle est sombre", .brightness, 1), ("il est sombre", .brightness, 1), ("is too dark", .brightness, 1), ("est trop sombre", .brightness, 1), ("is dark", .brightness, 1),
        // Contrast
        ("contrast", .contrast, 0), ("contraste", .contrast, 0), ("contrasty", .contrast, 1), ("plus contraste", .contrast, 1), ("plus contrastee", .contrast, 1),
        ("more punch", .contrast, 1), ("plus de punch", .contrast, 1), ("flat", .contrast, 1), ("plat", .contrast, 1), ("terne", .contrast, 1),
        ("moins contraste", .contrast, -1), ("less contrast", .contrast, -1),
        // Highlights / shadows / whites / blacks
        ("highlights", .highlights, 0), ("hautes lumieres", .highlights, 0), ("highlight", .highlights, 0), ("blown out", .highlights, -1),
        ("crame", .highlights, -1), ("cramee", .highlights, -1), ("cramees", .highlights, -1), ("recover the highlights", .highlights, -1),
        ("recupere les hautes lumieres", .highlights, -1), ("shadows", .shadows, 0), ("ombres", .shadows, 0), ("shadow", .shadows, 0),
        ("open the shadows", .shadows, 1), ("lift the shadows", .shadows, 1), ("deboucher les ombres", .shadows, 1), ("debouche les ombres", .shadows, 1),
        ("whites", .whites, 0), ("blancs", .whites, 0), ("blacks", .blacks, 0), ("noirs", .blacks, 0), ("deeper blacks", .blacks, -1), ("noirs plus profonds", .blacks, -1),
        // Colour
        ("saturation", .saturation, 0), ("saturate", .saturation, 1), ("sature", .saturation, 1), ("saturer", .saturation, 1), ("desaturate", .saturation, -1),
        ("desature", .saturation, -1), ("desaturer", .saturation, -1), ("more colorful", .saturation, 1), ("more colourful", .saturation, 1),
        ("plus colore", .saturation, 1), ("plus coloree", .saturation, 1), ("more color", .saturation, 1), ("more colors", .saturation, 1),
        ("more colour", .saturation, 1), ("plus de couleur", .saturation, 1), ("plus de couleurs", .saturation, 1), ("less color", .saturation, -1),
        ("less colour", .saturation, -1), ("moins de couleur", .saturation, -1), ("moins de couleurs", .saturation, -1), ("colors", .saturation, 0),
        ("colours", .saturation, 0), ("couleurs", .saturation, 0), ("couleur", .saturation, 0), ("color", .saturation, 0), ("colour", .saturation, 0),
        ("washed out", .saturation, 1), ("delave", .saturation, 1), ("fade", .saturation, 0), ("vibrance", .vibrance, 0), ("vibrant", .vibrance, 1),
        ("plus vibrant", .vibrance, 1), ("plus vibrante", .vibrance, 1), ("pop", .vibrance, 1), ("peps", .vibrance, 1),
        ("temperature", .temperature, 0), ("warmth", .temperature, 0), ("chaleur", .temperature, 0), ("warmer", .temperature, 1), ("warm", .temperature, 1),
        ("plus chaud", .temperature, 1), ("plus chaude", .temperature, 1), ("rechauffe", .temperature, 1), ("rechauffer", .temperature, 1),
        ("chaud", .temperature, 1), ("chaude", .temperature, 1), ("cooler", .temperature, -1), ("cool", .temperature, -1), ("colder", .temperature, -1),
        ("plus froid", .temperature, -1), ("plus froide", .temperature, -1), ("refroidis", .temperature, -1), ("refroidir", .temperature, -1),
        ("froid", .temperature, -1), ("froide", .temperature, -1), ("too yellow", .temperature, -1), ("trop jaune", .temperature, -1),
        ("too blue", .temperature, 1), ("trop bleu", .temperature, 1), ("trop bleue", .temperature, 1), ("too orange", .temperature, -1), ("trop orange", .temperature, -1),
        ("tint", .tint, 0), ("teinte", .tint, 0), ("too green", .tint, 1), ("trop vert", .tint, 1), ("trop verte", .tint, 1), ("too magenta", .tint, -1),
        ("trop magenta", .tint, -1), ("too pink", .tint, -1), ("trop rose", .tint, -1), ("hue", .hue, 0), ("nuance", .hue, 0),
        ("skin tone", .skinTone, 0), ("skin tones", .skinTone, 0), ("skin", .skinTone, 0), ("teint", .skinTone, 0), ("peau", .skinTone, 0), ("carnation", .skinTone, 0),
        // Detail
        ("sharpness", .sharpness, 0), ("nettete", .sharpness, 0), ("sharper", .sharpness, 1), ("sharpen", .sharpness, 1), ("sharp", .sharpness, 1),
        ("plus net", .sharpness, 1), ("plus nette", .sharpness, 1), ("net", .sharpness, 1), ("nette", .sharpness, 1), ("crisp", .sharpness, 1),
        ("crisper", .sharpness, 1), ("blurry", .sharpness, 1), ("flou", .sharpness, 1), ("floue", .sharpness, 1), ("softer", .sharpness, -1),
        ("soften", .sharpness, -1), ("adoucis", .sharpness, -1), ("adoucir", .sharpness, -1), ("clarity", .clarity, 0), ("clarte", .clarity, 0),
        ("texture", .clarity, 0), ("details", .clarity, 1), ("detail", .clarity, 1), ("more detail", .clarity, 1), ("plus de details", .clarity, 1),
        ("noise reduction", .noiseReduction, 0), ("reduction du bruit", .noiseReduction, 0), ("denoise", .noiseReduction, 1), ("noise", .noiseReduction, 0),
        ("bruit", .noiseReduction, 0), ("noisy", .noiseReduction, 1), ("bruitee", .noiseReduction, 1), ("bruite", .noiseReduction, 1), ("grainy", .noiseReduction, 1),
        ("remove the noise", .noiseReduction, 1), ("enleve le bruit", .noiseReduction, 1), ("reduis le bruit", .noiseReduction, 1), ("reduce the noise", .noiseReduction, 1),
        ("bluer", .saturation, 1), ("plus bleu", .saturation, 1), ("plus bleue", .saturation, 1), ("greener", .saturation, 1), ("plus verte", .saturation, 1),
        ("more blue", .saturation, 1), ("more green", .saturation, 1), ("plus de bleu", .saturation, 1), ("plus de vert", .saturation, 1), ("whiter", .brightness, 1), ("plus blanc", .brightness, 1), ("plus blanches", .brightness, 1), ("plus blancs", .brightness, 1),
        // Effects
        ("vignette", .vignette, 0), ("vignettage", .vignette, 0), ("vignetting", .vignette, 0), ("dark corners", .vignette, 0), ("coins sombres", .vignette, 0),
        ("grain", .grain, 0), ("film grain", .grain, 0), ("grain argentique", .grain, 0), ("matte", .fade, 0), ("mat", .fade, 0), ("faded", .fade, 1),
        ("faded look", .fade, 1), ("voile", .fade, 0), ("haze", .fade, 0), ("dehaze", .fade, -1), ("brume", .fade, 0),
    ]

    static let sortedTable = table.sorted { $0.0.count > $1.0.count }

    public static func match(in utterance: NormalizedUtterance) -> Match? {
        for (phrase, parameter, direction) in sortedTable where utterance.containsPhrase(phrase) {
            return Match(parameter: parameter, impliedDirection: direction, matchedPhrase: phrase)
        }
        return nil
    }

    /// Resolves a loosely-typed parameter name from an LLM ("warmth", "temp", "luminosité").
    public static func parameter(named name: String) -> AdjustmentParameter? {
        let key = name.normalizedForMatching
        if let direct = AdjustmentParameter(rawValue: key) { return direct }
        for parameter in AdjustmentParameter.allCases {
            if parameter.englishName.normalizedForMatching == key || parameter.frenchName.normalizedForMatching == key { return parameter }
        }
        let aliases: [String: AdjustmentParameter] = [
            "temp": .temperature, "warmth": .temperature, "warm": .temperature, "chaleur": .temperature, "white balance": .temperature,
            "brightness": .brightness, "luminosite": .brightness, "light": .brightness, "lumiere": .brightness, "exposure": .exposure,
            "sharpen": .sharpness, "sharp": .sharpness, "nettete": .sharpness, "denoise": .noiseReduction, "noise": .noiseReduction,
            "noise reduction": .noiseReduction, "bruit": .noiseReduction, "color": .saturation, "colour": .saturation, "couleur": .saturation,
            "colors": .saturation, "vignetting": .vignette, "haze": .fade, "dehaze": .fade, "matte": .fade, "skin": .skinTone,
            "skintone": .skinTone, "skin_tone": .skinTone, "noise_reduction": .noiseReduction, "highlight": .highlights, "shadow": .shadows,
        ]
        if let alias = aliases[key] { return alias }
        let probe = NormalizedUtterance(name)
        return match(in: probe)?.parameter
    }
}
