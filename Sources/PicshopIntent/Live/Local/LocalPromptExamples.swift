import Foundation
import PicshopCore

// The few-shot exchanges the local model reads before the conversation, in its own format: the state
// lines are rendered by the same code that renders the real ones (LiveSceneLines), and the tool results
// by ToolResultEncoder, so an example never teaches a line the app does not write. Deterministic.

extension LocalLivePrompt {
    /// Real exchanges in the model's own format, replayed as history: small models learn the call format
    /// from assistant turns rather than from rules. Photo, 4B (14): warmer, too much, an opinion, remove
    /// with a point, two steps at once; text by id (write in the same style, replace, "plus
    /// gros" on the layer the rewrite made); tables (fill all, "les autres aussi", a column of random
    /// numbers in English, one cell, a question the table line answers); a failed check and its one repair;
    /// a refusal the picture explains (no subject on a table). The last two come last (recency). The 2B
    /// gets 8 of them; video keeps its 6 and 4.
    public static func examples(mode: EditorMode, size: LocalPromptSize) -> [LocalPromptExample] {
        let video = mode == .video
        let warmer = LocalPromptExample(
            user: Examples.state(1, ["applied: nothing yet"]) + "\nlangue: fr\nrends-la plus chaude",
            assistant: "Je la réchauffe un peu.", toolName: .applyEdits,
            arguments: ["steps": [["action": "adjust", "parameter": "temperature", "amount": 15]]],
            toolResult: Examples.applied([(.adjust, "Warmth +15")], version: 2))
        let tooMuch = LocalPromptExample(
            user: Examples.state(2, ["applied: Warmth +15"]) + "\nlangue: fr\nc'est trop",
            assistant: "Je reviens en arrière.", toolName: .undo, arguments: [:],
            toolResult: ToolResultEncoder.compactText(ToolResultEncoder.undo(labels: ["Warmth +15"], redo: false, version: 3)))
        let opinionIdeas: JSONValue = [
            ["title": "Ciel plus dense", "why": "Le ciel est un peu pâle.", "symbol": "cloud.sun",
             "steps": [["action": "selectiveAdjust", "target": "sky", "parameter": "saturation", "amount": 25]]],
            ["title": "Lumière dorée", "why": "Pour une ambiance de fin de journée.", "symbol": "sun.max",
             "steps": [["action": "applyLook", "look": "goldenHour", "amount": 50]]],
            ["title": "Noir et blanc", "why": "Les contrastes s'y prêtent bien.", "symbol": "circle.lefthalf.filled",
             "steps": [["action": "applyLook", "look": "mono", "amount": 100]]],
        ]
        let opinion = LocalPromptExample(
            user: Examples.state(3, ["applied: nothing yet"]) + "\nlangue: fr\ntu en penses quoi ?",
            assistant: video ? "Belle lumière, mais les couleurs manquent un peu de relief." : "La lumière est douce, mais le ciel manque de relief.",
            toolName: .proposeIdeas,
            arguments: ["ideas": video && size == .full ? opinionIdeas : .array(Array(opinionIdeas.array?.prefix(2) ?? []))],
            toolResult: ToolResultEncoder.compactText(ToolResultEncoder.ideas(shown: video && size == .full ? 3 : 2, replaced: 0)))
        let pop = LocalPromptExample(
            user: Examples.state(3, ["applied: nothing yet"]) + "\nlangue: en\nmake it pop",
            assistant: "Adding some punch.", toolName: .applyEdits,
            arguments: ["steps": [["action": "applyLook", "look": "vivid", "amount": 60]]],
            toolResult: Examples.applied([(.applyLook, "Vivid 60%")], version: 4))
        let offTopic = LocalPromptExample(
            user: Examples.state(5, ["applied: Vivid 60%"]) + "\nlangue: fr\ntu connais une bonne recette de crêpes ?",
            assistant: video ? "Là, je ne suis bon qu'en vidéo ! On rend ta vidéo plus lumineuse ?" : "Là, je ne suis bon qu'en photo ! On rend ta photo plus lumineuse ?")

        if video {
            let precise = LocalPromptExample(
                user: Examples.state(4, ["applied: Vivid 60%"]) + "\nlangue: fr\ncoupe les trois premières secondes",
                assistant: "Je coupe le début.", toolName: .applyEdits,
                arguments: ["steps": [["action": "deleteRange", "startSeconds": 0, "endSeconds": 3]]],
                toolResult: Examples.applied([(.deleteRange, "Cut 0.0–3.0 s")], version: 5))
            return size == .full ? [warmer, tooMuch, opinion, pop, precise, offTopic] : [warmer, tooMuch, opinion, offTopic]
        }

        let precise = LocalPromptExample(
            user: Examples.state(4, ["applied: Vivid 60%", "image: attached (v4)"]) + "\nlangue: fr\nenlève la poubelle à droite de la lampe",
            assistant: "Je l'enlève.", toolName: .applyEdits,
            arguments: ["steps": [["action": "removeObject", "target": "trash", "point": ["x": 820, "y": 640]]]],
            toolResult: Examples.applied([(.removeObject, "Removed trash")], version: 5))
        let twoSteps = LocalPromptExample(
            user: Examples.state(5, ["new: Removed trash"]) + "\nlangue: fr\nenlève aussi le panneau et passe-la en noir et blanc",
            assistant: "J'enlève le panneau, puis noir et blanc.", toolName: .applyEdits,
            arguments: ["steps": [["action": "removeObject", "target": "sign"], ["action": "applyLook", "look": "mono", "amount": 100]]],
            toolResult: Examples.applied([(.removeObject, "Removed sign"), (.applyLook, "Mono 100%")], version: 7))

        // Text on the picture, by the ids of the texts line. Every id a call names is on that example's own state.
        let poster = Examples.posterScene()
        let placeText = LocalPromptExample(
            user: Examples.state(1, LiveSceneLines.scene(poster))
                + "\nlangue: fr\najoute « Jusqu'au 31 août » en bas, dans le même style que le sous-titre",
            assistant: "Je l'ajoute en bas.", toolName: .applyEdits,
            arguments: ["steps": [["action": "addText", "text": "Jusqu'au 31 août", "ref": "f2", "match": "t2"]]],
            toolResult: Examples.applied([(.addText, "Add Text")], version: 2, verified: true, created: ["l1"]))
        // After placeText (full) the new line is l1; the 2B, without it, reads the poster alone.
        let dated = Examples.posterLayer("Jusqu'au 31 août", center: PSPoint(x: 0.64, y: 0.96), size: 0.032)
        let replaceState = size == .full ? poster.overlaying([dated]) : poster
        let replaceText = LocalPromptExample(
            user: Examples.state(2, Examples.lines(replaceState, "texts:")) + "\nlangue: fr\nremplace « -50% sur tout » par « -70% sur tout »",
            assistant: "Je le remplace.", toolName: .applyEdits,
            arguments: ["steps": [["action": "editText", "ref": "t2", "text": "-70% sur tout"]]],
            toolResult: Examples.applied([(.editText, "Edit Text")], version: 3, verified: true, created: ["l2"]))
        // The printed t2 is gone: the rewrite is the layer l2, which the last: line and the texts line both name.
        var rewritten = poster.overlaying([dated, Examples.posterLayer("-70% sur tout", center: PSPoint(x: 0.5, y: 0.18), size: 0.032)])
        rewritten.texts.removeAll { $0.id == "t2" }
        let edited = LiveActionRecord(source: .model, steps: [RawIntentStep(action: "editText", text: "-70% sur tout", ref: "t2")],
                                      results: [LiveStepResult(index: 0, action: .editText, status: .applied, label: "Edit Text", createdRef: "l2")], version: 3)
        let biggerText = LocalPromptExample(
            user: Examples.state(3, Examples.lines(rewritten, "texts:") + [edited.line(scene: rewritten)]) + "\nlangue: fr\nplus gros",
            assistant: "Je l'agrandis.", toolName: .applyEdits,
            arguments: ["steps": [["action": "editText", "ref": "l2", "size": "bigger"]]],
            toolResult: Examples.applied([(.editText, "Edit Text")], version: 4, verified: true))
        // Act-then-verify: the check fails, one repair on what the step wrote, then one honest line.
        let unreadable = Examples.failedCheck(.addText)
        let written = poster.overlaying([Examples.posterLayer("Merci", center: PSPoint(x: 0.84, y: 0.31), size: 0.012)])
        let repairText = LocalPromptExample(
            user: Examples.state(5, Examples.lines(poster, "free:")) + "\nlangue: fr\nécris « Merci » dans le ciel",
            assistant: "Je l'écris dans le ciel.", toolName: .applyEdits,
            arguments: ["steps": [["action": "addText", "text": "Merci", "ref": "f1"]]],
            toolResult: ToolResultEncoder.compactText(ToolResultEncoder.applyEdits(LiveExecution(steps: [
                LiveStepResult(index: 0, action: .addText, status: .applied, label: "Add Text",
                               hint: ToolHints.hint(for: .verifyFailed, action: .addText, hasTable: false), verification: unreadable, createdRef: written.texts.last?.id),
            ], version: 6, canUndo: true))),
            afterResult: "C'est plus lisible comme ça.",
            repair: LocalPromptRepair(assistant: "Je l'agrandis.", arguments: ["steps": [["action": "editText", "ref": .string(written.texts.last?.id ?? "l1"), "size": "large"]]],
                                      toolResult: Examples.applied([(.editText, "Edit Text")], version: 7, verified: true)))

        // Tables, by the names of the table lines.
        let empty = Examples.table()
        let fillAll = LocalPromptExample(
            user: Examples.state(1, ["scene: table screenshot"] + LiveSceneLines.table(empty))
                + "\nlangue: fr\nremplis toutes les cases du tableau avec des 1",
            assistant: "Je remplis les \(empty.dataCells.count) cases.", toolName: .applyEdits,
            arguments: ["steps": [["action": "fillCells", "cells": "empty", "text": "1"]]],
            toolResult: Examples.table(.fillCells, changed: empty.dataCells.count, kept: 0, left: 0, value: "1", grid: empty, version: 2))
        let firstColumn = Examples.table(filled: (1...empty.dataRows.count).map { ($0, 1, "1") })
        let fillFirst = LiveActionRecord(source: .grammar, steps: [RawIntentStep(action: "fillCells", text: "1", cells: "empty", column: "Nova 2")],
                                         results: [LiveStepResult(index: 0, action: .fillCells, status: .applied, label: "Fill Cells",
                                                                  report: TableEditReport(action: .fillCells, changed: 5, kept: 0, emptyLeft: 15, dataRows: 5, dataColumns: 4, value: "1"))],
                                         version: 4)
        let fillOthers = LocalPromptExample(
            user: Examples.state(4, ["new: Fill Cells", LiveSceneLines.cellsLine(firstColumn)] + [LiveSceneLines.emptyRunsLine(firstColumn), fillFirst.line()].compactMap { $0 })
                + "\nlangue: fr\nil faut remplir les autres cases aussi",
            assistant: "Je remplis les 15 autres.", toolName: .applyEdits,
            arguments: ["steps": [["action": "fillCells", "cells": "empty", "text": "1"]]],
            toolResult: Examples.table(.fillCells, changed: 15, kept: 5, left: 0, value: "1", grid: empty, version: 5))
        let randomColumn = LocalPromptExample(
            user: Examples.state(6, [LiveSceneLines.cellsLine(empty)]) + "\nlangue: en\nput random numbers between 50 and 90 in the Atlas column",
            assistant: "Filling the Atlas column.", toolName: .applyEdits,
            arguments: ["steps": [["action": "fillCells", "column": "Atlas", "values": "random", "min": 50, "max": 90]]],
            toolResult: Examples.table(.fillCells, changed: 5, kept: 0, left: 15, value: "random 50–90", grid: empty, version: 7))
        let oneCell = LocalPromptExample(
            user: Examples.state(7, ["unchanged"]) + "\nlangue: fr\nmets 90% à Nova 1 sur la ligne Math",
            assistant: "Je mets 90 % dans cette case.", toolName: .applyEdits,
            arguments: ["steps": [["action": "fillCells", "row": "Math", "column": "Nova 1", "text": "90%"]]],
            toolResult: Examples.table(.fillCells, changed: 1, kept: 0, left: 14, value: "90%", grid: empty, version: 8))
        let answered = Examples.table(filled: [(4, 3, "67")])
        let tableQuestion = LocalPromptExample(
            user: Examples.state(8, [LiveSceneLines.tableFocus(answered, words: "combien a Atlas en Vision ?") ?? ""]) + "\nlangue: fr\ncombien a Atlas en Vision ?",
            assistant: "Atlas a 67 en Vision.")
        // A refusal the picture explains, and an offer that fits it; no call.
        let tableRefusal = LocalPromptExample(
            user: Examples.state(9, ["scene: table screenshot"]) + "\nlangue: fr\nécris 1 derrière la personne",
            assistant: "Il n'y a personne sur une capture de tableau. Je remplis les cases avec des 1 ?")

        if size == .compact {
            return [warmer, tooMuch, opinion, offTopic, replaceText, fillAll, fillOthers, tableRefusal]
        }
        return [warmer, tooMuch, opinion, precise, twoSteps, placeText, replaceText, biggerText,
                fillAll, fillOthers, randomColumn, oneCell, tableQuestion, repairText, tableRefusal]
    }
}

/// The pictures and state lines the examples are written on.
enum Examples {
    /// `<editor_state v=N>` with the given lines.
    static func state(_ version: Int, _ lines: [String]) -> String {
        (["<editor_state v=\(version)>"] + lines.filter { !$0.isEmpty } + ["</editor_state>"]).joined(separator: "\n")
    }

    /// ToolResultEncoder.compactText of applied steps (with a passed check when `verified`, and the ids of the
    /// layers they wrote when `created` names them).
    static func applied(_ steps: [(IntentAction, String)], version: Int, verified: Bool = false, created: [String] = []) -> String {
        let results = steps.enumerated().map { index, step -> LiveStepResult in
            var result = LiveStepResult(index: index, action: step.0, status: .applied, label: step.1)
            if verified { result.verification = passedCheck(step.0) }
            if index < created.count { result.createdRef = created[index] }
            return result
        }
        return ToolResultEncoder.compactText(ToolResultEncoder.applyEdits(LiveExecution(steps: results, version: version, canUndo: true)))
    }

    /// The result of a table step, with its report.
    static func table(_ action: IntentAction, changed: Int, kept: Int, left: Int, value: String?, grid: TableGrid, version: Int) -> String {
        let report = TableEditReport(action: action, changed: changed, kept: kept, emptyLeft: left, dataRows: grid.dataRows.count,
                                     dataColumns: grid.dataColumns.count, value: value)
        let step = LiveStepResult(index: 0, action: action, status: .applied, label: "Fill Cells", report: report)
        return ToolResultEncoder.compactText(ToolResultEncoder.applyEdits(LiveExecution(steps: [step], version: version, canUndo: true)))
    }

    static func passedCheck(_ action: IntentAction) -> VerificationReport {
        let check = VerificationCheck(kind: .textPresent, region: .unit, text: "text", tag: "text")
        return VerificationReport(intentID: exampleID, action: action, items: [.init(check: check, outcome: .passed)], method: .pixels)
    }

    /// Only the scene lines an example needs ("texts:", "free:"), to keep the cached prefix small.
    static func lines(_ scene: SceneMap, _ prefixes: String...) -> [String] {
        LiveSceneLines.scene(scene).filter { line in prefixes.contains { line.hasPrefix($0) } }
    }

    /// A text the check could not read where it was written ("verify failed 1/1: text missing").
    static func failedCheck(_ action: IntentAction) -> VerificationReport {
        let check = VerificationCheck(kind: .textPresent, region: .unit, text: "text", tag: "text")
        return VerificationReport(intentID: exampleID, action: action, items: [.init(check: check, outcome: .failed)], method: .pixels)
    }

    static let exampleID = UUID(uuidString: "00000000-0000-0000-0000-00000000E0E0") ?? UUID()

    /// A Picshop text layer on the poster (fixed ids, so the examples stay byte-identical).
    static func posterLayer(_ text: String, center: PSPoint, size: Double) -> Layer {
        let seed = text.unicodeScalars.reduce(UInt32(0)) { ($0 &* 31) &+ $1.value }
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", seed)) ?? UUID()
        var element = TextElement(text: text)
        element.center = center
        element.relativeSize = size
        element.color = .white
        return Layer(id: id, name: text, content: .text(element))
    }

    static let headers = ["Nova 2", "Nova 1", "Atlas", "Orion Pro"]
    static let labels = ["Coding", "Reasoning", "Math", "Vision", "Agents"]

    /// A 5 × 4 score table, "Scores 2026", every data cell empty but the ones `filled` names (1-based,
    /// written by the user's earlier fills).
    static func table(filled: [(row: Int, column: Int, text: String)] = []) -> TableGrid {
        let bounds = PSRect(x: 0.05, y: 0.12, width: 0.9, height: 0.8)
        let labelWidth = 0.3, headerHeight = 0.1
        let columnWidth = (bounds.width - labelWidth) / Double(headers.count)
        let rowHeight = (bounds.height - headerHeight) / Double(labels.count)
        var columns = [TableGrid.Column(index: 0, rect: PSRect(x: bounds.minX, y: bounds.minY, width: labelWidth, height: bounds.height), header: "", isLabel: true)]
        for (offset, header) in headers.enumerated() {
            columns.append(TableGrid.Column(index: offset + 1, rect: PSRect(x: bounds.minX + labelWidth + Double(offset) * columnWidth, y: bounds.minY,
                                                                            width: columnWidth, height: bounds.height), header: header))
        }
        var rows = [TableGrid.Row(index: 0, rect: PSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: headerHeight), label: "", isHeader: true)]
        for (offset, label) in labels.enumerated() {
            rows.append(TableGrid.Row(index: offset + 1, rect: PSRect(x: bounds.minX, y: bounds.minY + headerHeight + Double(offset) * rowHeight,
                                                                      width: bounds.width, height: rowHeight), label: label))
        }
        var cells: [TableGrid.Cell] = []
        for row in rows {
            for column in columns {
                let rect = PSRect(x: column.rect.minX, y: row.rect.minY, width: column.rect.width, height: row.rect.height)
                let kind: TableGrid.CellKind = row.isHeader ? (column.isLabel ? .corner : .header) : (column.isLabel ? .label : .data)
                var text = kind == .header ? column.header : kind == .label ? row.label : ""
                var state: TableGrid.CellState = kind == .data ? .empty : .printed
                if kind == .data, let fill = filled.first(where: { $0.row == row.index && $0.column == column.index }) {
                    text = fill.text
                    state = .layer
                }
                cells.append(TableGrid.Cell(row: row.index, column: column.index, rect: rect, contentRect: rect.insetBy(dx: rect.width * 0.1, dy: rect.height * 0.15),
                                            text: text, kind: kind, state: state))
            }
        }
        return TableGrid(id: TableGrid.makeID(bounds: bounds, rows: rows, columns: columns), bounds: bounds, title: "Scores 2026", rows: rows,
                         columns: columns, cells: cells, headerRowCount: 1, labelColumnCount: 1, ruling: .horizontal, bodyStyle: nil,
                         confidence: 0.9, source: .detected)
    }

    /// A summer-sale poster: a bold title, a subtitle, a price, a person, two free areas.
    static func posterScene() -> SceneMap {
        let light = PSColor.white
        let texts = [
            SceneMap.TextBlock(id: "t1", text: "SOLDES D'ÉTÉ", box: PSRect(x: 0.12, y: 0.05, width: 0.76, height: 0.09),
                               style: TableGrid.Style(relativeSize: 0.075, color: light, weight: .bold), role: .title),
            SceneMap.TextBlock(id: "t2", text: "-50% sur tout", box: PSRect(x: 0.3, y: 0.16, width: 0.4, height: 0.04),
                               style: TableGrid.Style(relativeSize: 0.032, color: light, weight: .medium), role: .heading),
            SceneMap.TextBlock(id: "t3", text: "29,99 €", box: PSRect(x: 0.06, y: 0.86, width: 0.22, height: 0.05),
                               style: TableGrid.Style(relativeSize: 0.04, color: PSColor(hex: "#FFD60A") ?? .yellow, weight: .bold, alignment: .leading)),
        ]
        let person = SceneMap.Object(id: "o1", label: "person", box: PSRect(x: 0.3, y: 0.24, width: 0.4, height: 0.7), confidence: 0.94, kind: .person)
        let areas = [
            SceneMap.FreeArea(id: "f1", box: PSRect(x: 0.7, y: 0.22, width: 0.28, height: 0.18), background: PSColor(hex: "#7EC8F0")),
            SceneMap.FreeArea(id: "f2", box: PSRect(x: 0.3, y: 0.93, width: 0.68, height: 0.06), background: PSColor(hex: "#E9D8B4")),
        ]
        return SceneMap(stateKey: "example", canvasSize: PSSize(width: 1080, height: 1350), kind: .photo, texts: texts, objects: [person], freeAreas: areas)
    }
}
