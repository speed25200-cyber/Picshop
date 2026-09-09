import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// Deterministic stand-in for the vision layer.
struct FakePhotoServices: PhotoAIServices {
    var candidates: [ObjectCandidate]
    var horizon: Double? = 3

    func candidates(for target: ObjectTarget, in document: PhotoDocument) async throws -> [ObjectCandidate] {
        candidates.filter { $0.label == target.label || target.label == "object" }
    }

    func mask(for candidates: [ObjectCandidate], target: ObjectTarget, in document: PhotoDocument) async throws -> MaskReference {
        let box = candidates.map(\.boundingBox).reduce(PSRect.zero) { $0.union($1) }
        return MaskReference(source: .object(label: target.label, boundingBox: box), boundingBox: box)
    }

    func subjectMask(in document: PhotoDocument) async throws -> MaskReference {
        MaskReference(source: .subject)
    }

    func horizonAngle(in document: PhotoDocument) async throws -> Double? { horizon }

    func framingRect(for target: ObjectTarget, in document: PhotoDocument) async throws -> PSRect? {
        candidates.first { $0.label == target.label }?.boundingBox
    }
}

struct FakeVideoServices: VideoAIServices {
    var candidates: [ObjectCandidate] = []

    func candidates(for target: ObjectTarget, in clip: VideoClip, timeline: VideoTimeline, at time: Double) async throws -> [ObjectCandidate] {
        candidates.filter { $0.label == target.label }
    }

    func removeObject(candidates: [ObjectCandidate], target: ObjectTarget, from clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset {
        progress(1)
        return MediaAsset(kind: .video, relativePath: "media/removed.mov", pixelSize: clip.asset.pixelSize, duration: clip.sourceRange.duration, origin: .generated, frameRate: 30)
    }

    func stabilize(clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset {
        MediaAsset(kind: .video, relativePath: "media/stab.mov", pixelSize: clip.asset.pixelSize, duration: clip.asset.duration, origin: .generated, frameRate: 30)
    }

    func reverse(clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset {
        MediaAsset(kind: .video, relativePath: "media/reversed.mov", pixelSize: clip.asset.pixelSize, duration: clip.sourceRange.duration, origin: .generated, frameRate: 30)
    }

    func extractFrame(at time: Double, timeline: VideoTimeline) async throws -> MediaAsset {
        MediaAsset(kind: .image, relativePath: "media/frame.jpg", pixelSize: timeline.renderSize, origin: .generated)
    }

    func freezeFrame(at time: Double, duration: Double, timeline: VideoTimeline) async throws -> MediaAsset {
        MediaAsset(kind: .video, relativePath: "media/freeze.mov", pixelSize: timeline.renderSize, duration: duration, origin: .generated, frameRate: 30)
    }

    func subjectMatte(for clip: VideoClip, timeline: VideoTimeline, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset {
        MediaAsset(kind: .video, relativePath: "media/matte.mov", pixelSize: clip.asset.pixelSize, duration: clip.asset.duration, origin: .generated, frameRate: 30)
    }
}

final class PhotoExecutorTests: XCTestCase {
    let engine = RuleBasedIntentEngine()

    func makeDocument() -> PhotoDocument {
        PhotoDocument(title: "Test", baseImage: MediaAsset(kind: .image, relativePath: "media/a.jpg", pixelSize: PSSize(width: 4000, height: 3000)))
    }

    func testRemoveSingleDog() async {
        let dog = ObjectCandidate(label: "dog", boundingBox: PSRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), confidence: 0.9)
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: [dog]))
        let intent = engine.parse("efface le chien", context: .photo).intents[0]
        let (document, result) = await executor.execute(intent, on: makeDocument(), context: .photo)
        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertEqual(document.baseLayer?.edits.operations.count, 1)
        if case .removeObject(let mask)? = document.baseLayer?.edits.operations.first?.kind {
            XCTAssertEqual(mask.boundingBox, dog.boundingBox)
        } else {
            XCTFail("expected a removeObject operation")
        }
    }

    func testAmbiguousTargetAsksThenResolves() async {
        let left = ObjectCandidate(label: "person", boundingBox: PSRect(x: 0.05, y: 0.3, width: 0.2, height: 0.5), confidence: 0.9)
        let right = ObjectCandidate(label: "person", boundingBox: PSRect(x: 0.7, y: 0.3, width: 0.2, height: 0.5), confidence: 0.88)
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: [left, right]), language: .french)
        let intent = engine.parse("enlève la personne", context: .photo).intents[0]
        let (document, result) = await executor.execute(intent, on: makeDocument(), context: .photo)
        guard case .needsClarification(let request) = result.outcome else { return XCTFail("expected clarification") }
        XCTAssertEqual(request.candidates.count, 2)
        XCTAssertTrue(request.question.contains("2"))
        XCTAssertEqual(document.baseLayer?.edits.operations.count, 0)

        var context = IntentContext.photo
        context.pendingClarification = request
        let choice = engine.parse("celle de droite", context: context).intents[0]
        XCTAssertEqual(choice.action, .chooseCandidate)
        let (resolved, second) = await executor.execute(choice, on: document, context: context)
        XCTAssertTrue(second.outcome.isSuccess)
        if case .removeObject(let mask)? = resolved.baseLayer?.edits.operations.first?.kind {
            XCTAssertEqual(mask.boundingBox, right.boundingBox)
        } else {
            XCTFail("expected removal of the right person")
        }
    }

    func testSpatialHintAvoidsClarification() async {
        let left = ObjectCandidate(label: "person", boundingBox: PSRect(x: 0.05, y: 0.3, width: 0.2, height: 0.5), confidence: 0.9)
        let right = ObjectCandidate(label: "person", boundingBox: PSRect(x: 0.7, y: 0.3, width: 0.2, height: 0.5), confidence: 0.88)
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: [left, right]))
        let intent = engine.parse("remove the person on the left", context: .photo).intents[0]
        let (document, result) = await executor.execute(intent, on: makeDocument(), context: .photo)
        XCTAssertTrue(result.outcome.isSuccess, "\(result.outcome)")
        if case .removeObject(let mask)? = document.baseLayer?.edits.operations.first?.kind {
            XCTAssertEqual(mask.boundingBox, left.boundingBox)
        }
    }

    func testRemoveAllPeople() async {
        let people = (0..<3).map { ObjectCandidate(label: "person", boundingBox: PSRect(x: Double($0) * 0.3, y: 0.3, width: 0.2, height: 0.5), confidence: 0.8) }
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: people))
        let intent = engine.parse("supprime toutes les personnes", context: .photo).intents[0]
        let (document, result) = await executor.execute(intent, on: makeDocument(), context: .photo)
        XCTAssertEqual(result.label, "Remove 3 × person")
        XCTAssertEqual(document.baseLayer?.edits.operations.count, 1)
    }

    func testObjectNotFound() async {
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: []))
        let intent = engine.parse("remove the giraffe", context: .photo).intents[0]
        let (_, result) = await executor.execute(intent, on: makeDocument(), context: .photo)
        guard case .failed(let message) = result.outcome else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("giraffe"))
    }

    func testAdjustRelativeToCurrentValue() async {
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: []))
        var document = makeDocument()
        document.apply(.adjust(.brightness, value: 0.5))
        var context = IntentContext.photo
        context.currentAdjustments = document.activeAdjustments
        let intent = engine.parse("un peu plus lumineux", context: context).intents[0]
        let (updated, _) = await executor.execute(intent, on: document, context: context)
        XCTAssertEqual(updated.activeAdjustments[.brightness], 0.6, accuracy: 1e-9)
        let max = engine.parse("luminosité au max", context: context).intents[0]
        let (maxed, _) = await executor.execute(max, on: updated, context: context)
        XCTAssertEqual(maxed.activeAdjustments[.brightness], 1)
    }

    func testTextLifecycle() async {
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: []))
        let add = engine.parse("ajoute le texte « Bonjour » en haut en rouge", context: .photo).intents[0]
        let (withText, result) = await executor.execute(add, on: makeDocument(), context: .photo)
        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertEqual(withText.textLayers.count, 1)
        XCTAssertEqual(withText.textLayers[0].textElement?.text, "Bonjour")
        XCTAssertEqual(withText.textLayers[0].textElement?.color, .red)
        XCTAssertEqual(withText.textLayers[0].textElement?.center, TextElement.Placement.top.center)

        var context = IntentContext.photo
        context.textLayerCount = 1
        let bigger = engine.parse("make the text bigger", context: context).intents[0]
        let (grown, _) = await executor.execute(bigger, on: withText, context: context)
        XCTAssertGreaterThan(grown.textLayers[0].textElement!.relativeSize, withText.textLayers[0].textElement!.relativeSize)

        let remove = engine.parse("remove the text", context: context).intents[0]
        let (cleared, _) = await executor.execute(remove, on: grown, context: context)
        XCTAssertTrue(cleared.textLayers.isEmpty)
    }

    func testMetaEffects() async {
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: []))
        let (_, undo) = await executor.execute(EditIntent(action: .undo), on: makeDocument(), context: .photo)
        XCTAssertEqual(undo.effects, [.undo])
        let (_, export) = await executor.execute(EditIntent(action: .export), on: makeDocument(), context: .photo)
        XCTAssertEqual(export.effects, [.export])
        let (doc, straighten) = await executor.execute(EditIntent(action: .straighten), on: makeDocument(), context: .photo)
        XCTAssertTrue(straighten.outcome.isSuccess)
        XCTAssertEqual(doc.baseLayer?.edits.resolvedRotation ?? 0, -3, accuracy: 1e-9)
    }

    func testCropToFace() async {
        let face = ObjectCandidate(label: "face", boundingBox: PSRect(x: 0.4, y: 0.2, width: 0.2, height: 0.3), confidence: 0.95)
        let executor = PhotoCommandExecutor(services: FakePhotoServices(candidates: [face]))
        let intent = engine.parse("recadre sur le visage", context: .photo).intents[0]
        let (document, result) = await executor.execute(intent, on: makeDocument(), context: .photo)
        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertEqual(document.baseLayer?.edits.resolvedCrop, face.boundingBox)
    }
}

final class VideoExecutorTests: XCTestCase {
    let engine = RuleBasedIntentEngine()

    func makeTimeline() -> VideoTimeline {
        VideoTimeline(title: "Clip", asset: MediaAsset(kind: .video, relativePath: "media/v.mov", pixelSize: PSSize(width: 1920, height: 1080), duration: 20, frameRate: 30))
    }

    func context(for timeline: VideoTimeline, playhead: Double = 0) -> IntentContext {
        IntentContext(mode: .video, clipCount: timeline.clips.count, playheadSeconds: playhead, timelineDuration: timeline.duration, frameRate: 30)
    }

    func testDeleteFirstSecondsAndSpeed() async {
        let executor = VideoCommandExecutor(services: FakeVideoServices())
        var timeline = makeTimeline()
        let plan = engine.parse("coupe les 3 premières secondes et accélère x2", context: context(for: timeline))
        XCTAssertEqual(plan.intents.map(\.action), [.deleteRange, .setSpeed])
        for intent in plan.intents {
            let (updated, result) = await executor.execute(intent, on: timeline, context: context(for: timeline))
            XCTAssertTrue(result.outcome.isSuccess, "\(result.outcome)")
            timeline = updated
        }
        XCTAssertEqual(timeline.clips.count, 1)
        XCTAssertEqual(timeline.clips[0].sourceRange.start, 3, accuracy: 1e-9)
        XCTAssertEqual(timeline.clips[0].speed, 2)
        XCTAssertEqual(timeline.duration, 8.5, accuracy: 1e-9)
    }

    /// Two sound tracks live side by side; commands address one by number.
    func testSeveralSoundTracks() async {
        let executor = VideoCommandExecutor(services: FakeVideoServices())
        var timeline = makeTimeline()
        let asset = MediaAsset(kind: .audio, relativePath: "media/a.m4a", pixelSize: .zero, duration: 60, origin: .file)
        timeline.audioTracks = [AudioTrack(asset: asset, name: "Music"), AudioTrack(asset: asset, timelineStart: 4, name: "Voice")]
        let lower = engine.parse("baisse la deuxième piste", context: context(for: timeline)).intents[0]
        (timeline, _) = await executor.execute(lower, on: timeline, context: context(for: timeline))
        XCTAssertEqual(timeline.audioTracks[0].volume, 0.8, accuracy: 0.001, "the first track is untouched")
        XCTAssertEqual(timeline.audioTracks[1].volume, 0.55, accuracy: 0.001)
        let mute = engine.parse("mute the music", context: context(for: timeline)).intents[0]
        (timeline, _) = await executor.execute(mute, on: timeline, context: context(for: timeline))
        XCTAssertTrue(timeline.audioTracks.allSatisfy(\.isMuted))
        XCTAssertFalse(timeline.clips[0].isMuted, "muting the music leaves the clip's own sound alone")
        let move = engine.parse("move the last track to 12 seconds", context: context(for: timeline)).intents[0]
        (timeline, _) = await executor.execute(move, on: timeline, context: context(for: timeline))
        XCTAssertEqual(timeline.audioTracks[1].timelineStart, 12, accuracy: 0.001)
        XCTAssertEqual(timeline.audioTracks[0].timelineStart, 0, accuracy: 0.001)
        let fade = engine.parse("fade out the music over 3 seconds", context: context(for: timeline)).intents[0]
        (timeline, _) = await executor.execute(fade, on: timeline, context: context(for: timeline))
        XCTAssertEqual(timeline.audioTracks[0].fadeOut, 3, accuracy: 0.001)
        XCTAssertEqual(timeline.audioTracks[0].fadeIn, 0.5, accuracy: 0.001, "a fade-out leaves the fade-in alone")
        let remove = engine.parse("supprime la deuxième piste", context: context(for: timeline)).intents[0]
        (timeline, _) = await executor.execute(remove, on: timeline, context: context(for: timeline))
        XCTAssertEqual(timeline.audioTracks.map(\.name), ["Music"])
        let add = engine.parse("ajoute un deuxième son à 10 secondes", context: context(for: timeline)).intents[0]
        let (_, result) = await executor.execute(add, on: timeline, context: context(for: timeline))
        guard case .pickMusic(_, let at, let replace) = result.effects.first else { return XCTFail("adding a sound opens the picker") }
        XCTAssertEqual(at, 10)
        XCTAssertFalse(replace)
    }

    func testSplitTransitionAndMute() async {
        let executor = VideoCommandExecutor(services: FakeVideoServices())
        var timeline = makeTimeline()
        let split = engine.parse("split here", context: context(for: timeline, playhead: 8)).intents[0]
        (timeline, _) = await executor.execute(split, on: timeline, context: context(for: timeline, playhead: 8))
        XCTAssertEqual(timeline.clips.count, 2)
        let transition = engine.parse("add a dissolve between all clips", context: context(for: timeline)).intents[0]
        (timeline, _) = await executor.execute(transition, on: timeline, context: context(for: timeline))
        XCTAssertEqual(timeline.clips[0].transitionOut?.kind, .crossDissolve)
        XCTAssertNil(timeline.clips[1].transitionOut)
        let mute = engine.parse("coupe le son", context: context(for: timeline, playhead: 12)).intents[0]
        (timeline, _) = await executor.execute(mute, on: timeline, context: context(for: timeline, playhead: 12))
        XCTAssertFalse(timeline.clips[0].isMuted)
        XCTAssertTrue(timeline.clips[1].isMuted)
    }

    func testRemoveObjectRendersProcessedAsset() async {
        let person = ObjectCandidate(label: "person", boundingBox: PSRect(x: 0.6, y: 0.2, width: 0.2, height: 0.6), confidence: 0.9)
        let executor = VideoCommandExecutor(services: FakeVideoServices(candidates: [person]))
        let timeline = makeTimeline()
        let intent = engine.parse("efface le passant", context: context(for: timeline)).intents[0]
        let (updated, result) = await executor.execute(intent, on: timeline, context: context(for: timeline))
        XCTAssertTrue(result.outcome.isSuccess)
        XCTAssertEqual(updated.clips[0].processedAsset?.relativePath, "media/removed.mov")
        XCTAssertEqual(updated.clips[0].renderAsset.relativePath, "media/removed.mov")
    }

    func testTrimKeepsRange() async {
        let executor = VideoCommandExecutor(services: FakeVideoServices())
        let timeline = makeTimeline()
        let intent = engine.parse("garde seulement de 2 à 8 secondes", context: context(for: timeline)).intents[0]
        XCTAssertEqual(intent.action, .trim)
        let (updated, result) = await executor.execute(intent, on: timeline, context: context(for: timeline))
        XCTAssertTrue(result.outcome.isSuccess, "\(result.outcome)")
        XCTAssertEqual(updated.duration, 6, accuracy: 1e-9)
        XCTAssertEqual(updated.clips[0].sourceRange.start, 2, accuracy: 1e-9)
    }

    func testAddTextOverlayWithDuration() async {
        let executor = VideoCommandExecutor(services: FakeVideoServices())
        let timeline = makeTimeline()
        let intent = engine.parse("ajoute le texte Vacances pendant 3 secondes", context: context(for: timeline, playhead: 5)).intents[0]
        let (updated, _) = await executor.execute(intent, on: timeline, context: context(for: timeline, playhead: 5))
        XCTAssertEqual(updated.overlays.count, 1)
        XCTAssertEqual(updated.overlays[0].span, TimeSpan(start: 5, duration: 3))
        XCTAssertEqual(updated.overlays[0].textElement?.text, "Vacances")
    }

    func testCannotDeleteEverything() async {
        let executor = VideoCommandExecutor(services: FakeVideoServices())
        let timeline = makeTimeline()
        let (_, result) = await executor.execute(EditIntent(action: .deleteClip), on: timeline, context: context(for: timeline))
        guard case .failed = result.outcome else { return XCTFail("deleting the only clip must fail") }
    }
}
