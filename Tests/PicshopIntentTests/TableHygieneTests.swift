import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// A8, T's half: no French error sentence carries an internal English label inside « », and every
/// failure that has a reason says it through the machine channel.
final class TableHygieneTests: XCTestCase {
    /// Internal labels that must never reach a French sentence.
    static let internalLabels: Set<String> = ["subject", "object", "person", "people", "text", "background", "foreground", "face", "faces", "sky",
                                              "table", "cell", "cells", "region", "area", "selection", "data", "number", "numbers", "sign", "the sign",
                                              "blemish", "watermark", "dog", "the person", "Fill cells", "Clear cells", "Highlight cells", "Erase area",
                                              "Move text", "Captions"]

    private func assertClean(_ message: String?, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let message else { return }
        XCTAssertFalse(message.lowercased().contains("subject"), "\(context): \(message)", file: file, line: line)
        var rest = Substring(message)
        while let open = rest.firstIndex(of: "«"), let close = rest[open...].firstIndex(of: "»") {
            let quoted = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            XCTAssertFalse(Self.internalLabels.contains(quoted), "\(context): « \(quoted) » in \(message)", file: file, line: line)
            rest = rest[rest.index(after: close)...]
        }
    }

    func testEveryPicshopErrorInFrench() {
        let errors: [PicshopError] = [
            .projectNotFound(UUID()), .corruptProject("json"), .mediaUnavailable("photo.jpg"), .objectNotFound("subject"), .objectNotFound("person"),
            .objectNotFound("the sign"), .objectNotFound("la girafe"), .ambiguousTarget(count: 3), .unsupportedOperation("Captions"), .modelUnavailable("Qwen"),
            .renderFailed("x"), .exportFailed("x"), .permissionDenied("Photos"), .speechUnavailable("x"), .cancelled, .noSubject,
        ]
        for error in errors { assertClean(error.message(french: true), "\(error)") }
        XCTAssertEqual(PicshopError.objectNotFound("subject").message(french: true), "Je ne trouve pas de sujet sur la photo.")
        XCTAssertEqual(PicshopError.objectNotFound("la girafe").message(french: true), "Je ne trouve pas « la girafe » sur la photo.", "the person's words stay")
        XCTAssertTrue(PicshopError.permissionDenied("Photos").message(french: true).contains("Tu peux"), "tu, never vous")
    }

    func testSubjectStepsOnATableSayItInFrenchWithTheReason() async {
        let executor = PhotoCommandExecutor(services: TableFakeServices(), language: .french)
        let context = IntentContext(mode: .photo, table: TableFixtures.benchmark())
        let steps = [EditIntent(action: .textBehind, text: "Paris"), EditIntent(action: .removeBackground), EditIntent(action: .replaceBackground, background: .white),
                     EditIntent(action: .blurBackground)]
        for step in steps {
            for ctx in [context, IntentContext.photo] {
                let (document, result) = await executor.execute(step, on: TableFixtures.document(), context: ctx)
                XCTAssertEqual(result.reason, .noSubject, "\(step.action)")
                XCTAssertEqual(result.outcome.message, PicshopError.noSubject.message(french: true))
                XCTAssertEqual(document.layers.count, 1)
            }
        }
        // On a table screenshot, Vision is not even asked.
        let services = TableFakeServices()
        _ = await PhotoCommandExecutor(services: services, language: .french).execute(EditIntent(action: .textBehind, text: "1"), on: TableFixtures.document(), context: context)
        XCTAssertEqual(services.calls.subjectMask, 0)
        // A background target reads the same.
        let recolor = EditIntent(action: .selectiveAdjust, target: ObjectTarget(label: "background"), parameter: .brightness)
        struct Throwing: PhotoAIServices {
            func candidates(for target: ObjectTarget, in document: PhotoDocument) async throws -> [ObjectCandidate] { throw PicshopError.noSubject }
            func mask(for candidates: [ObjectCandidate], target: ObjectTarget, in document: PhotoDocument) async throws -> MaskReference { throw PicshopError.noSubject }
            func subjectMask(in document: PhotoDocument) async throws -> MaskReference { throw PicshopError.noSubject }
            func horizonAngle(in document: PhotoDocument) async throws -> Double? { nil }
            func framingRect(for target: ObjectTarget, in document: PhotoDocument) async throws -> PSRect? { nil }
        }
        let (_, background) = await PhotoCommandExecutor(services: Throwing(), language: .french).execute(recolor, on: TableFixtures.document(), context: .photo)
        XCTAssertEqual(background.reason, .noSubject)
    }

    func testEveryPhotoFailurePathInFrenchIsClean() async {
        let nothing = FakePhotoServices(candidates: [])
        let two = FakePhotoServices(candidates: [ObjectCandidate(label: "person", boundingBox: PSRect(x: 0.1, y: 0.1, width: 0.2, height: 0.5), confidence: 0.9),
                                                 ObjectCandidate(label: "person", boundingBox: PSRect(x: 0.6, y: 0.1, width: 0.2, height: 0.5), confidence: 0.88)])
        let document = TableFixtures.document()
        let steps: [(EditIntent, PhotoAIServices)] = [
            (EditIntent(action: .removeObject), nothing),
            (EditIntent(action: .moveObject), nothing),
            (EditIntent(action: .removeObject, target: ObjectTarget(label: "person", originalPhrase: "person")), nothing),
            (EditIntent(action: .removeObject, target: ObjectTarget(label: "sign", originalPhrase: "the sign")), nothing),
            (EditIntent(action: .blurObject, target: ObjectTarget(label: "face", originalPhrase: "face")), nothing),
            (EditIntent(action: .generativeFill, target: ObjectTarget(label: "sky", originalPhrase: "sky"), text: "clouds"), nothing),
            (EditIntent(action: .selectiveAdjust, target: ObjectTarget(label: "person", originalPhrase: "person"), parameter: .brightness), nothing),
            (EditIntent(action: .crop, target: ObjectTarget(label: "dog", originalPhrase: "dog")), nothing),
            (EditIntent(action: .removeObject, target: ObjectTarget(label: "person", originalPhrase: "person")), two),
            (EditIntent(action: .editText), nothing),
            (EditIntent(action: .removeText), nothing),
            (EditIntent(action: .moveText), nothing),
            (EditIntent(action: .duplicateLayer), nothing),
            (EditIntent(action: .fillCells, table: TableEditSpec(value: .constant("1"))), TableFakeServices(grid: nil)),
            (EditIntent(action: .fillCells, table: TableEditSpec(columns: [.name("GPT 7")], value: .constant("1"))), TableFakeServices()),
            (EditIntent(action: .fillCells, table: TableEditSpec(columns: [.name("Opus")], value: .constant("1"))), TableFakeServices()),
            (EditIntent(action: .clearCells, table: TableEditSpec()), TableFakeServices()),
            (EditIntent(action: .editText, text: "x", ref: .text(9)), TableFakeServices()),
            (EditIntent(action: .eraseRegion), TableFakeServices()),
            (EditIntent(action: .eraseRegion, region: PSRect(x: 0, y: 0, width: 0.9, height: 0.9)), TableFakeServices()),
            (EditIntent(action: .speedRamp), nothing),
        ]
        for (step, services) in steps {
            let (_, result) = await PhotoCommandExecutor(services: services, language: .french).execute(step, on: document, context: .photo)
            assertClean(result.outcome.message, "\(step.action)")
            if case .needsClarification(let request) = result.outcome { assertClean(request.question, "\(step.action) question") }
        }
        let (_, person) = await PhotoCommandExecutor(services: nothing, language: .french).execute(steps[2].0, on: document, context: .photo)
        XCTAssertEqual(person.outcome.message, "Je ne trouve pas « la personne ». Touche ou entoure ce qu'il faut effacer.")
    }

    func testReasonsTravelWithTheFailures() async {
        let executor = PhotoCommandExecutor(services: TableFakeServices(), language: .english)
        let cases: [(EditIntent, ExecutionReason)] = [
            (EditIntent(action: .fillCells, table: TableEditSpec(value: .constant("1"))), .noTable),
            (EditIntent(action: .editText, text: "x", ref: .text(4)), .unknownRef),
            (EditIntent(action: .eraseRegion, region: PSRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001)), .badRegion),
            (EditIntent(action: .eraseRegion), .needsSelection),
            (EditIntent(action: .editText), .noText),
            (EditIntent(action: .removeObject), .needsSelection),
            (EditIntent(action: .speedRamp), .unsupported),
        ]
        for (step, reason) in cases {
            let services = step.action == .fillCells ? TableFakeServices(grid: nil) : TableFakeServices()
            let (_, result) = await PhotoCommandExecutor(services: services, language: .english).execute(step, on: TableFixtures.document(), context: .photo)
            XCTAssertEqual(result.reason, reason, "\(step.action)")
        }
        _ = executor
    }
}
