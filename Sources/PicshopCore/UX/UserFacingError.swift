import Foundation

/// An error as the person reads it (ux-spec §4.16): what happened, why when known, and what to do as buttons. No raw
/// `localizedDescription` ever reaches the screen; internal errors map here, and the technical detail goes to
/// « Partager le diagnostic ». The feedback slot, sheets' inline banners and Home's Activité card all show this.
public struct UserFacingError: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// « Cette retouche n'a pas abouti. »
        case generic
        /// The iPhone is too hot: Réessayer stays inactive for 30 s.
        case thermal
        /// Not enough space; `missingBytes` when known (« il manque 1,2 Go »).
        case noSpace(missingBytes: Int64?)
        /// A photo still in iCloud with no network.
        case iCloudUnavailable
        /// Photos access refused, when saving.
        case photosAccessDenied
        /// A project that could not be opened.
        case damagedProject
        /// A feature that needs a download (« Remplir avec l'IA », 1,9 Go).
        case missingFeature(name: String, bytes: Int64)
        /// Nothing matches what was named (« chien »).
        case noMatch(String)
        /// A request the app cannot do yet (« changer la saison »).
        case unsupported(String)
        /// An import that failed, with the reason when known (« format MKV non pris en charge »).
        case importFailed(reason: String?)
        /// A permission refused: what, with its French preposition (« au micro » / "the microphone").
        case permissionDenied(String)
        /// A PDF page with no text layer.
        case pdfWithoutText
        /// The person cancelled: nothing is shown.
        case cancelled
    }

    /// A button under the message. The host maps each to its behaviour.
    public enum Action: String, CaseIterable, Sendable {
        case retry, close, freeSpace, openSettings, saveToFiles, openLastSaved, download, later, chooseAnother, makeTextSelectable

        public func title(french: Bool) -> String {
            switch self {
            case .retry: return french ? "Réessayer" : "Retry"
            case .close: return french ? "Fermer" : "Close"
            case .freeSpace: return french ? "Libérer de l'espace" : "Free Up Space"
            case .openSettings: return french ? "Ouvrir Réglages" : "Open Settings"
            case .saveToFiles: return french ? "Enregistrer dans Fichiers" : "Save to Files"
            case .openLastSaved: return french ? "Ouvrir la dernière version enregistrée" : "Open the Last Saved Version"
            case .download: return french ? "Télécharger en Wi\u{2011}Fi" : "Download over Wi\u{2011}Fi"
            case .later: return french ? "Plus tard" : "Later"
            case .chooseAnother: return french ? "Choisir un autre fichier" : "Choose Another File"
            case .makeTextSelectable: return french ? "Rendre le texte sélectionnable" : "Make Text Selectable"
            }
        }
    }

    public var kind: Kind
    /// The buttons, in order; the last one is the quiet dismissal.
    public var actions: [Action]
    /// Seconds Réessayer stays inactive (« Réessayer dans 30 s »), 0 when it is active at once.
    public var retryDelay: Int

    public init(_ kind: Kind, actions: [Action]? = nil) {
        self.kind = kind
        self.actions = actions ?? Self.defaultActions(for: kind)
        if case .thermal = kind { retryDelay = 30 } else { retryDelay = 0 }
    }

    /// Whether the slot shows anything (a cancel is silent).
    public var isSilent: Bool { kind == .cancelled }

    /// The buttons each kind offers (§4.16).
    public static func defaultActions(for kind: Kind) -> [Action] {
        switch kind {
        case .generic: return [.retry, .close]
        case .thermal: return [.retry]
        case .noSpace: return [.freeSpace, .close]
        case .iCloudUnavailable: return [.retry, .close]
        case .photosAccessDenied: return [.openSettings, .saveToFiles]
        case .damagedProject: return [.openLastSaved, .close]
        case .missingFeature: return [.download, .later]
        case .noMatch, .unsupported: return [.close]
        case .importFailed: return [.chooseAnother, .close]
        case .permissionDenied: return [.openSettings, .close]
        case .pdfWithoutText: return [.makeTextSelectable, .close]
        case .cancelled: return []
        }
    }

    /// The message, « vous » register, French typography (non-breaking spaces before « : » and units).
    public func message(french: Bool) -> String {
        switch kind {
        case .generic:
            return french ? "Cette retouche n'a pas abouti." : "This edit didn't go through."
        case .thermal:
            return french ? "L'iPhone est trop chaud pour cette retouche. Réessayez dans un moment."
                : "The iPhone is too warm for this edit. Try again in a moment."
        case .noSpace(let missing):
            if let missing, missing > 0 {
                let size = Self.byteCount(missing, french: french)
                return french ? "L'iPhone n'a plus assez d'espace\u{00A0}: il manque \(size)." : "The iPhone is out of space: \(size) more is needed."
            }
            return french ? "L'iPhone n'a plus assez d'espace." : "The iPhone is out of space."
        case .iCloudUnavailable:
            return french ? "Cette photo est dans iCloud et n'a pas pu être téléchargée. Vérifiez la connexion."
                : "This photo is in iCloud and couldn't be downloaded. Check the connection."
        case .photosAccessDenied:
            return french ? "PicShop n'a pas accès à Photos pour enregistrer." : "PicShop can't access Photos to save."
        case .damagedProject:
            return french ? "Ce projet n'a pas pu être ouvert." : "This project couldn't be opened."
        case .missingFeature(let name, let bytes):
            let size = Self.byteCount(bytes, french: french)
            return french ? "\(name) nécessite un téléchargement de \(size)." : "\(name) needs a \(size) download."
        case .noMatch(let what):
            return french ? "Je ne trouve pas « \(what) » sur cette photo. Touchez ce que vous voulez modifier."
                : "I can't find “\(what)” in this photo. Tap what you want to change."
        case .unsupported(let what):
            return french ? "Je ne sais pas encore \(what)." : "I can't \(what) yet."
        case .importFailed(let reason):
            if let reason, !reason.isEmpty {
                return french ? "Ce fichier n'a pas pu être importé (\(reason))." : "This file couldn't be imported (\(reason))."
            }
            return french ? "Ce fichier n'a pas pu être importé." : "This file couldn't be imported."
        case .permissionDenied(let what):
            return french ? "PicShop n'a pas accès \(what)." : "PicShop doesn't have access to \(what)."
        case .pdfWithoutText:
            return french ? "Pas de texte ici. Ce PDF est peut-être une image." : "No text here. This PDF may be a picture."
        case .cancelled:
            return ""
        }
    }

    /// Réessayer's title while it waits (« Réessayer dans 30 s »).
    public func retryTitle(secondsLeft: Int, french: Bool) -> String {
        guard secondsLeft > 0 else { return Action.retry.title(french: french) }
        return french ? "Réessayer dans \(secondsLeft)\u{00A0}s" : "Retry in \(secondsLeft) s"
    }

    // MARK: - Mapping

    /// The person-facing form of any error: PicshopError cases, out-of-space and permission errors from the system;
    /// anything else is the generic « Cette retouche n'a pas abouti. ».
    public static func from(_ error: Error) -> UserFacingError {
        if let error = error as? UserFacingError.Wrapped { return error.value }
        if let error = error as? PicshopError { return from(error) }
        if error is CancellationError { return UserFacingError(.cancelled) }
        let nsError = error as NSError
        if isOutOfSpace(nsError) { return UserFacingError(.noSpace(missingBytes: nil)) }
        return UserFacingError(.generic)
    }

    public static func from(_ error: PicshopError) -> UserFacingError {
        switch error {
        case .cancelled: return UserFacingError(.cancelled)
        case .projectNotFound, .corruptProject: return UserFacingError(.damagedProject)
        case .mediaUnavailable: return UserFacingError(.iCloudUnavailable)
        case .objectNotFound(let target):
            let french = PicshopError.devicePrefersFrench
            return UserFacingError(.noMatch(french ? (PicshopError.frenchLabel(for: target) ?? target) : target))
        case .noSubject: return UserFacingError(.noMatch(PicshopError.devicePrefersFrench ? "sujet" : "subject"))
        case .unsupportedOperation: return UserFacingError(.generic, actions: [.close])
        case .permissionDenied(let what):
            if what == "Photos" { return UserFacingError(.photosAccessDenied) }
            let french = PicshopError.devicePrefersFrench
            if what.lowercased().contains("micro") { return UserFacingError(.permissionDenied(french ? "au micro" : "the microphone")) }
            return UserFacingError(.permissionDenied(french ? "à \(what)" : what))
        case .ambiguousTarget, .modelUnavailable, .renderFailed, .exportFailed, .speechUnavailable: return UserFacingError(.generic)
        }
    }

    /// An error that already carries its person-facing form (a lane throws it to choose the copy itself).
    public struct Wrapped: Error, Sendable {
        public var value: UserFacingError
        public init(_ value: UserFacingError) { self.value = value }
    }

    /// NSFileWriteOutOfSpaceError (Cocoa 640) or ENOSPC (POSIX 28), here or underneath.
    static func isOutOfSpace(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == 640 { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == 28 { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isOutOfSpace(underlying) }
        return false
    }

    /// « 1,2 Go » / "1.2 GB", « 850 Mo » / "850 MB" (decimal units, as Réglages › Stockage shows them).
    public static func byteCount(_ bytes: Int64, french: Bool) -> String {
        let space = french ? "\u{00A0}" : " "
        let value = Double(max(0, bytes))
        if value >= 1_000_000_000 {
            let tenths = Int((value / 100_000_000).rounded())
            let text = tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10)\(french ? "," : ".")\(tenths % 10)"
            return text + space + (french ? "Go" : "GB")
        }
        if value >= 1_000_000 { return "\(Int((value / 1_000_000).rounded()))" + space + (french ? "Mo" : "MB") }
        return "\(Int((value / 1_000).rounded()))" + space + (french ? "Ko" : "KB")
    }
}
