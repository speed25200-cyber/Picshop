import Foundation
@testable import PicshopCore
@testable import PicshopIntent

/// Scene maps for the text, reference and follow-up cases. Owned by T; B's tests read them (frozen API,
/// like TableFixtures); the pictures live in PicshopIntent (`LiveEvalFixtures`).
enum SceneFixtures {
    static let dark = LiveEvalFixtures.dark

    // MARK: The benchmark screenshot

    /// The benchmark table screenshot as a scene map: t1 the title, t2…t6 the headers, t7…t15 the row
    /// labels, the emptied table, and a free band under the title.
    static func benchmarkScene(withValues: Bool = false) -> SceneMap { LiveEvalFixtures.benchmarkScene(withValues: withValues) }

    // MARK: A poster photo

    static let posterCanvas = LiveEvalFixtures.posterCanvas
    static let posterAssetPath = LiveEvalFixtures.posterAssetPath

    /// A summer-sale poster photo: a person (o1) in the middle, a bold white title at the top (t1), a
    /// subtitle under it (t2), a price at the bottom left (t3); sky free at the top right (f1), a flat
    /// band at the bottom (f2).
    static func posterScene() -> SceneMap { LiveEvalFixtures.posterScene() }

    static func posterDocument() -> PhotoDocument { LiveEvalFixtures.posterDocument() }

    /// The fake a poster test runs on: the scene above, no table, the person as the subject.
    static func posterServices(failingChecks: Set<String> = []) -> TableFakeServices { LiveEvalFixtures.posterServices(failingChecks: failingChecks) }
}
