import Foundation
import PicshopCore

/// Applies intents to a `PDFDocumentModel`.
public struct PDFCommandExecutor: Sendable {
    public let services: PDFAIServices
    public var language: NormalizedUtterance.Language

    public init(services: PDFAIServices, language: NormalizedUtterance.Language = .english) {
        self.services = services
        self.language = language
    }

    public func execute(_ intent: EditIntent, on input: PDFDocumentModel, context: IntentContext) async -> (PDFDocumentModel, ExecutionResult) {
        var document = input
        let fr = language == .french
        let current = document.currentPageIndex

        switch intent.action {
        case .goToPage:
            guard let index = document.resolvePageIndex(intent.index) else { return (document, .failed(fr ? "Page introuvable." : "No such page.")) }
            document.goToPage(index)
            return (document, .applied("Page \(index + 1)"))

        case .deletePage:
            if intent.scope == .all { return (document, .failed(fr ? "Impossible de supprimer toutes les pages." : "Can't delete every page.")) }
            guard let index = document.resolvePageIndex(intent.index) else { return (document, .failed(fr ? "Page introuvable." : "No such page.")) }
            guard document.pageCount > 1 else { return (document, .failed(fr ? "Le document n'a qu'une page." : "The document has only one page.")) }
            document.deletePage(at: index)
            return (document, .applied("Delete Page \(index + 1)"))

        case .rotatePage:
            let degrees = Int((intent.degrees ?? 90).rounded())
            if intent.scope == .all {
                for index in document.pages.indices { document.rotatePage(at: index, by: degrees) }
                return (document, .applied("Rotate All Pages"))
            }
            guard let index = document.resolvePageIndex(intent.index) else { return (document, .failed(fr ? "Page introuvable." : "No such page.")) }
            document.rotatePage(at: index, by: degrees)
            return (document, .applied("Rotate Page \(index + 1)"))

        case .movePage:
            guard let index = document.resolvePageIndex(intent.index) else { return (document, .failed(fr ? "Page introuvable." : "No such page.")) }
            guard let destinationNumber = intent.clipIndex, let destination = document.resolvePageIndex(destinationNumber) ?? (destinationNumber > document.pageCount ? document.pageCount - 1 : nil) else {
                return (document, .failed(fr ? "Où déplacer la page ?" : "Where should the page go?"))
            }
            document.movePage(from: index, to: destination)
            return (document, .applied("Move Page"))

        case .duplicatePage:
            guard let index = document.resolvePageIndex(intent.index) else { return (document, .failed(fr ? "Page introuvable." : "No such page.")) }
            document.duplicatePage(at: index)
            return (document, .applied("Duplicate Page"))

        case .insertBlankPage:
            let size = document.currentPage?.size ?? PSSize(width: 595, height: 842)
            let page = PDFPageModel(source: .blank(size), size: size)
            let position: Int
            if intent.scope == .selection {
                position = intent.index == -1 ? document.pageCount : (document.resolvePageIndex(intent.index) ?? current) + 1
            } else {
                position = document.resolvePageIndex(intent.index) ?? current
            }
            document.insert(page, at: position)
            return (document, .applied("Insert Page"))

        case .addPageNumbers:
            for index in document.pages.indices {
                document.pages[index].markups.removeAll { if case .pageNumber = $0.kind { return true } else { return false } }
                var element = TextElement(text: "\(index + 1)", fontName: "SFPro-Regular", relativeSize: 0.014, color: .black, style: .plain, center: PSPoint(x: 0.5, y: 0.965))
                element.maxRelativeWidth = 0.2
                document.pages[index].markups.append(PDFMarkup(kind: .pageNumber(element)))
            }
            document.touch()
            return (document, .applied("Page Numbers"))

        case .highlightText, .underlineText, .redactText, .findText:
            guard let query = intent.text, !query.isEmpty else {
                return (document, ExecutionResult(outcome: .info(message: fr ? "Quel mot ?" : "Which words?")))
            }
            do {
                let hits = try await services.findText(query, in: document, pageIndex: intent.scope == .all ? nil : current)
                guard !hits.isEmpty else {
                    if intent.scope != .all, let anywhere = try? await services.findText(query, in: document, pageIndex: nil), let first = anywhere.first {
                        document.goToPage(first.pageIndex)
                        let message = fr ? "« \(query) » se trouve page \(first.pageIndex + 1)." : "“\(query)” is on page \(first.pageIndex + 1)."
                        if intent.action == .findText { return (document, ExecutionResult(outcome: .info(message: message), effects: [.message("find:\(query)")])) }
                        return (document, ExecutionResult(outcome: .info(message: message)))
                    }
                    return (document, .failed(fr ? "« \(query) » introuvable." : "“\(query)” not found."))
                }
                if intent.action == .findText {
                    document.goToPage(hits[0].pageIndex)
                    let message = fr ? "\(hits.count) résultat(s) pour « \(query) »." : "\(hits.count) match(es) for “\(query)”."
                    return (document, ExecutionResult(outcome: .info(message: message), effects: [.message("find:\(query)")]))
                }
                for hit in hits {
                    let color = intent.color ?? .yellow
                    let kind: PDFMarkup.Kind
                    switch intent.action {
                    case .highlightText: kind = .highlight(rects: hit.rects, color: color)
                    case .underlineText: kind = intent.color == .red ? .strikeout(rects: hit.rects, color: .red) : .underline(rects: hit.rects, color: intent.color ?? .blue)
                    default: kind = .redaction(rects: hit.rects)
                    }
                    document.addMarkup(PDFMarkup(kind: kind), toPageAt: hit.pageIndex)
                }
                let label = intent.action == .highlightText ? "Highlight" : (intent.action == .underlineText ? "Underline" : "Redact")
                return (document, .applied("\(label) “\(query)”"))
            } catch {
                return (document, .failed(errorMessage(error)))
            }

        case .replaceText:
            guard let query = intent.text, !query.isEmpty else {
                return (document, ExecutionResult(outcome: .info(message: fr ? "Quel mot remplacer ?" : "Which words should I replace?")))
            }
            guard let replacement = intent.replacement else {
                return (document, ExecutionResult(outcome: .info(message: fr ? "Remplacer « \(query) » par quoi ?" : "Replace “\(query)” with what?")))
            }
            do {
                var hits = try await services.findText(query, in: document, pageIndex: intent.scope == .all ? nil : current)
                if hits.isEmpty, intent.scope != .all { hits = try await services.findText(query, in: document, pageIndex: nil) }
                guard !hits.isEmpty else { return (document, .failed(fr ? "« \(query) » introuvable." : "“\(query)” not found.")) }
                for hit in hits {
                    // Keep the case pattern of the original word ("Monsieur" → "Madame", "MONSIEUR" → "MADAME").
                    var text = replacement
                    let original = hit.text.isEmpty ? query : hit.text
                    if original == original.uppercased(), original != original.lowercased() { text = replacement.uppercased() }
                    else if let first = original.first, first.isUppercase { text = replacement.prefix(1).uppercased() + replacement.dropFirst() }
                    let element = TextElement(text: text, fontName: "SFPro-Regular", relativeSize: 0.02, color: intent.color ?? .black, alignment: .leading, style: .plain)
                    document.addMarkup(PDFMarkup(kind: .replacement(rects: hit.rects, text: element, background: hit.background)), toPageAt: hit.pageIndex)
                }
                document.goToPage(hits[0].pageIndex)
                return (document, .applied(replacement.isEmpty ? "Erase “\(query)”" : "Replace “\(query)”"))
            } catch {
                return (document, .failed(errorMessage(error)))
            }

        case .addSignature:
            guard let signature = await services.signatureAsset() else {
                return (document, ExecutionResult(outcome: .info(message: fr ? "Dessine ta signature." : "Draw your signature."), effects: [.message("signature")]))
            }
            guard let index = document.resolvePageIndex(intent.index), let page = document.pages.indices.contains(index) ? document.pages[index] : nil else {
                return (document, .failed(fr ? "Page introuvable." : "No such page."))
            }
            let placement = intent.placement ?? .bottomTrailing
            let aspect = signature.pixelSize.isEmpty ? 3.0 : signature.pixelSize.aspectRatio
            let width = 0.28
            let height = width / aspect * (page.displaySize.width / max(1, page.displaySize.height))
            let center = placement.center
            let frame = PSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height).clampedToUnit()
            document.addMarkup(PDFMarkup(kind: .signature(signature, frame: frame)), toPageAt: index)
            return (document, .applied("Signature"))

        case .addText:
            guard let text = intent.text, !text.isEmpty else { return (document, ExecutionResult(outcome: .info(message: fr ? "Quel texte ?" : "What should it say?"))) }
            var element = TextElement(text: text, fontName: "SFPro-Semibold", relativeSize: 0.025, color: intent.color ?? .black, style: .plain, center: (intent.placement ?? .center).center)
            element.maxRelativeWidth = 0.8
            document.addMarkup(PDFMarkup(kind: .text(element)), toPageAt: current)
            return (document, .applied("Add Text"))

        case .removeText:
            if intent.text == "all" {
                for index in document.pages.indices { document.pages[index].markups.removeAll() }
                document.touch()
                return (document, .applied("Clear Markups"))
            }
            func matches(_ markup: PDFMarkup) -> Bool {
                guard let kind = intent.text else { return true }
                switch (kind, markup.kind) {
                case ("signature", .signature), ("highlight", .highlight), ("highlight", .underline), ("highlight", .strikeout), ("ink", .ink), ("text", .text), ("image", .image), ("pageNumber", .pageNumber): return true
                default: return false
                }
            }
            if intent.text == "pageNumber" {
                for index in document.pages.indices { document.pages[index].markups.removeAll { if case .pageNumber = $0.kind { return true } else { return false } } }
                document.touch()
                return (document, .applied("Remove Page Numbers"))
            }
            let candidatesOnPage = document.pages[current].markups.filter(matches)
            let anywhere = document.allMarkups.filter { matches($0.markup) }
            guard let last = candidatesOnPage.last ?? anywhere.last?.markup else { return (document, .failed(fr ? "Rien à supprimer." : "Nothing to remove.")) }
            document.removeMarkup(id: last.id)
            return (document, .applied("Remove \(last.label)"))

        case .extractPage:
            guard let index = document.resolvePageIndex(intent.index) else { return (document, .failed(fr ? "Page introuvable." : "No such page.")) }
            do {
                _ = try await services.extractPage(index, from: document)
                return (document, ExecutionResult(outcome: .info(message: fr ? "Page \(index + 1) enregistrée dans Photos." : "Page \(index + 1) saved to Photos.")))
            } catch {
                return (document, .failed(errorMessage(error)))
            }

        case .mergeDocument:
            return (document, .effect(.message(intent.text == "image" ? "image" : "merge"), label: ""))

        case .undo: return (document, .effect(.undo, label: ""))
        case .redo: return (document, .effect(.redo, label: ""))
        case .revert: return (document, .effect(.revert, label: ""))
        case .export: return (document, .effect(.export, label: ""))
        case .share: return (document, .effect(.share, label: ""))
        case .help: return (document, .effect(.help, label: ""))
        case .zoom: return (document, .effect(.zoom(intent.amount, nil), label: ""))
        case .confirm: return (document, .effect(.confirm, label: ""))
        case .cancel: return (document, .effect(.cancel, label: ""))
        case .unknown: return (document, ExecutionResult(outcome: .info(message: Replies.reply(for: intent, language: language))))
        default: return (document, .failed(PicshopError.unsupportedOperation(intent.summary).message))
        }
    }

    func errorMessage(_ error: Error) -> String {
        if let known = error as? PicshopError { return known.message }
        return error.localizedDescription
    }
}
