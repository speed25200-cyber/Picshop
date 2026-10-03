import XCTest
@testable import PicshopIntent
@testable import PicshopCore

/// systemInstructions(mode:) feeds the Foundation Models and MLX planners: the
/// actionGuide refactor must leave it byte for byte as it was.
final class IntentPromptGoldenTests: XCTestCase {
    static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    func testSystemInstructionsAreByteIdentical() {
        let golden: [(EditorMode, Int, String)] = [
            // Re-baselined in W1: each planner names its own editor's actions and meta lines only (the PDF
            // planner no longer reads photo and video ones), and movePage's contract is clipNumber = the page.
            (.photo, 7496, "8dcb703d97e44b64"),
            (.video, 7119, "51fc4b977ad2356e"),
            (.pdf, 2473, "474f6e9eb420b0cf"),
        ]
        for (mode, length, hash) in golden {
            // The legacy actions only: the catalog's operation names follow the catalog.
            let text = IntentPrompt.systemInstructions(mode: mode, includesOperations: false)
            XCTAssertEqual(text.utf8.count, length, "\(mode)")
            XCTAssertEqual(Self.fnv1a(text), hash, "\(mode)")
        }
    }

    func testActionGuideFollowsTheMode() {
        let photo = IntentPrompt.actionGuide(mode: .photo)
        let video = IntentPrompt.actionGuide(mode: .video)
        XCTAssertTrue(photo.contains("- removeObject:"))
        XCTAssertTrue(photo.contains("moveObject (PHOTO"))
        XCTAssertFalse(photo.contains("VIDEO ONLY"))
        XCTAssertFalse(photo.contains("PDF ONLY"))
        XCTAssertTrue(video.contains("VIDEO ONLY"))
        XCTAssertTrue(video.contains("VIDEO MAGIC"))
        XCTAssertFalse(video.contains("(PHOTO:"))
        XCTAssertFalse(video.contains("PDF ONLY"))
        XCTAssertTrue(IntentPrompt.actionGuide(mode: .pdf).contains("PDF ONLY"))
        // Meta and dialogue actions are Live tools of their own, never apply_edits steps.
        XCTAssertFalse(photo.contains("- undo, redo"))
        XCTAssertFalse(photo.contains("saveVersion"))
        XCTAssertEqual(photo, IntentPrompt.actionGuide(mode: .photo))
    }

    func testPhotoInterpretationGuideIsPublicAndPhotoOnly() {
        XCTAssertTrue(IntentPrompt.photoInterpretationGuide.contains("How to read photo requests"))
        XCTAssertTrue(IntentPrompt.systemInstructions(mode: .photo).hasSuffix(IntentPrompt.photoInterpretationGuide))
        XCTAssertFalse(IntentPrompt.systemInstructions(mode: .video).contains("How to read photo requests"))
    }
}
