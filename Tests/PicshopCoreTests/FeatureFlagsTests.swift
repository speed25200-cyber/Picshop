import XCTest
@testable import PicshopCore

/// The W1, W2 and W3 kill switches and the signpost facade.
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
        XCTAssertEqual(Set(FeatureFlag.allCases.map(\.rawValue)), [
            // W1
            "catalogOps", "retrievalCards", "displayLinkCanvas", "proTone", "studioWorkspace", "psBackdrop",
            // W2
            "masks", "aiSelection", "samModel", "depthModel", "pixelPostconditions", "fmDynamicSchema", "commandPalette", "metalOrb",
            "graphiteSurround", "modelBroker",
            // W3
            "proLayers", "freeTransform", "layersColumn", "paramInspector", "contentHashCache", "interactiveSnapshot", "tiledRendering",
            "proExport", "psdExport", "layerOps", "outlineFill", "recipes", "kvEngine", "persistedPrefix",
        ])
    }

    /// The ten W2 switches ship on (TestFlight testers get finished features), each can be turned off on its
    /// own, and turning one off leaves the others alone.
    func testTheTenW2FlagsShipOnAndSwitchOffAlone() {
        let w2: [FeatureFlag] = [.masks, .aiSelection, .samModel, .depthModel, .pixelPostconditions, .fmDynamicSchema,
                                 .commandPalette, .metalOrb, .graphiteSurround, .modelBroker]
        XCTAssertEqual(w2.count, 10)
        XCTAssertEqual(FeatureFlag.allCases.count, 30)
        for flag in w2 {
            XCTAssertTrue(flag.releaseDefault, flag.rawValue)
            XCTAssertEqual(FeatureFlags.key(flag), "picshop.flag.\(flag.rawValue)")
        }
        for flag in w2 {
            FeatureFlags.set(flag, false)
            XCTAssertFalse(FeatureFlags.isOn(flag), flag.rawValue)
            for other in w2 where other != flag {
                XCTAssertEqual(FeatureFlags.isOn(other), FeatureFlags.defaultValue(other), "\(flag.rawValue) moved \(other.rawValue)")
            }
            FeatureFlags.set(flag, nil)
        }
    }

    /// D24: the fourteen W3 switches, each its own key, each on in Release (P2 turns off what a lane reports
    /// unfinished; `kvEngine` and `persistedPrefix` are also gated at run time by the KV self-test).
    func testTheFourteenW3FlagsShipOnAndSwitchOffAlone() {
        let w3: [FeatureFlag] = [.proLayers, .freeTransform, .layersColumn, .paramInspector, .contentHashCache, .interactiveSnapshot,
                                 .tiledRendering, .proExport, .psdExport, .layerOps, .outlineFill, .recipes, .kvEngine, .persistedPrefix]
        XCTAssertEqual(Set(w3).count, 14)
        for flag in w3 {
            XCTAssertTrue(flag.releaseDefault, flag.rawValue)
            XCTAssertEqual(FeatureFlags.key(flag), "picshop.flag.\(flag.rawValue)")
            FeatureFlags.set(flag, false)
            XCTAssertFalse(FeatureFlags.isOn(flag), flag.rawValue)
            for other in w3 where other != flag {
                XCTAssertEqual(FeatureFlags.isOn(other), FeatureFlags.defaultValue(other), "\(flag.rawValue) moved \(other.rawValue)")
            }
            FeatureFlags.set(flag, nil)
        }
    }

    func testSignpostsAreANoOpWhereThereIsNoOSLog() {
        let interval = PSSignpost.begin("test.interval", "detail")
        PSSignpost.end(interval)
        PSSignpost.event("test.event")
        XCTAssertEqual(PSSignpost.measure("test.measure") { 21 * 2 }, 42)
        XCTAssertThrowsError(try PSSignpost.measure("test.throws") { throw PicshopError.unsupportedOperation("x") })
    }
}
