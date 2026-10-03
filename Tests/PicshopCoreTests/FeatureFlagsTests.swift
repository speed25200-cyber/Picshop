import XCTest
@testable import PicshopCore

/// The W1 kill switches and the signpost facade.
final class FeatureFlagsTests: XCTestCase {
    override func tearDown() {
        for flag in FeatureFlag.allCases { FeatureFlags.set(flag, nil) }
        super.tearDown()
    }

    func testAnOverrideWinsAndNilRestoresTheDefault() {
        for flag in FeatureFlag.allCases {
            FeatureFlags.set(flag, false)
            XCTAssertFalse(FeatureFlags.isOn(flag), flag.rawValue)
            FeatureFlags.set(flag, true)
            XCTAssertTrue(FeatureFlags.isOn(flag), flag.rawValue)
            FeatureFlags.set(flag, nil)
            XCTAssertEqual(FeatureFlags.isOn(flag), FeatureFlags.defaultValue(flag), flag.rawValue)
        }
    }

    func testDebugBuildsHaveEveryFlagOn() {
        #if DEBUG
        for flag in FeatureFlag.allCases { XCTAssertTrue(FeatureFlags.defaultValue(flag), flag.rawValue) }
        #endif
        XCTAssertEqual(Set(FeatureFlag.allCases.map(\.rawValue)), ["catalogOps", "retrievalCards", "displayLinkCanvas", "proTone", "studioWorkspace", "psBackdrop"])
    }

    func testSignpostsAreANoOpWhereThereIsNoOSLog() {
        let interval = PSSignpost.begin("test.interval", "detail")
        PSSignpost.end(interval)
        PSSignpost.event("test.event")
        XCTAssertEqual(PSSignpost.measure("test.measure") { 21 * 2 }, 42)
        XCTAssertThrowsError(try PSSignpost.measure("test.throws") { throw PicshopError.unsupportedOperation("x") })
    }
}
