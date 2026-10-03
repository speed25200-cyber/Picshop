import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// For every mode, every action LiveToolSchema allows executes with minimal valid arguments without
/// unsupportedOperation: what the model may write, the editor can run.
final class ExecutorParityTests: XCTestCase {
    /// Minimal arguments, in the model's vocabulary, for the actions that need some.
    static func minimal(_ action: IntentAction) -> RawIntentStep {
        var step = RawIntentStep(action: action.rawValue)
        switch action {
        case .removeObject, .moveObject, .blurObject: step.target = "dog"
        case .recolor: step.target = "dog"; step.color = "red"
        case .selectiveAdjust: step.target = "dog"; step.parameter = "brightness"; step.amount = 20
        case .adjust: step.parameter = "brightness"; step.amount = 20
        case .applyLook: step.look = "vivid"
        case .addText, .textBehind: step.text = "Été"
        case .editText, .removeText: step.ref = "l1"; step.text = action == .editText ? "Hiver" : nil
        case .moveText: step.ref = "l1"; step.placement = "bottom"
        case .eraseRegion: step.box = PSRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
        case .generativeFill: step.target = "dog"; step.text = "a cat"
        case .replaceBackground: step.background = "white"
        case .crop, .setAspect, .smartReframe, .expandCanvas: step.aspect = "square"
        case .trim, .deleteRange: step.startSeconds = 1; step.endSeconds = 3
        case .split, .extractFrame, .freezeFrame, .moveAudio, .seek: step.seconds = 2
        case .setSpeed: step.speed = 2
        case .addTransition: step.transition = "crossDissolve"
        case .translateCaptions: step.text = "en"
        case .cutWords: step.text = "bref"
        case .fillCells: step.text = "1"
        case .clearCells: step.cells = "all"
        case .highlightCells: step.column = "1"
        case .moveClip, .duplicateClip, .deleteClip: step.clipNumber = 2
        default: break
        }
        return step
    }

    func testEveryAllowedActionExecutesInItsEditor() async throws {
        let photoDocument = OperationFixtures.photo()
        let photo = PhotoCommandExecutor(services: OperationPhotoServices(), language: .french)
        let video = VideoCommandExecutor(services: FakeVideoServices(), language: .french)
        for mode in [EditorMode.photo, .video] {
            for action in LiveToolSchema.allowedActions(for: mode) {
                let context = mode == .photo ? OperationFixtures.photoContext(photoDocument) : IntentContext(mode: .video, clipCount: 3, timelineDuration: 30)
                let step = Self.minimal(action)
                guard let intent = IntentNormalizer.normalize(step, context: context) else {
                    XCTFail("\(mode) \(action): the minimal step does not normalize")
                    continue
                }
                let result: ExecutionResult
                if mode == .photo {
                    result = await photo.execute(intent, on: photoDocument, context: context).1
                } else {
                    result = await video.execute(intent, on: OperationFixtures.video(), context: context).1
                }
                let unsupported = result.effects.contains(ExecutionReason.unsupported.effect)
                    || (result.outcome.message ?? "").contains("can't do") || (result.outcome.message ?? "").contains("ne peux pas le faire")
                XCTAssertFalse(unsupported, "\(mode) \(action): \(result.outcome)")
            }
        }
    }

    func testCatalogOperationsAreAllowedOnlyInTheirDomains() {
        for spec in OperationCatalog.shared.specs where spec.lowering == .handler {
            let intent = EditIntent(action: .operation, operation: OperationCall(spec.id))
            for mode in [EditorMode.photo, .video, .pdf] {
                XCTAssertEqual(intent.isAllowed(in: mode), spec.domains.contains(mode.opDomain), "\(spec.id) in \(mode)")
            }
        }
    }
}
