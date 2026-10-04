import XCTest
@testable import PicshopCore

/// The model broker's policy (W2, D12): the 700 MB floor, priorities, busy residents, the 6 GB and 8 GB classes,
/// the export releases, and the ledger the broker actor keeps.
final class ModelBrokerPolicyTests: XCTestCase {
    private let mib = 1_048_576
    private let gb: UInt64 = 1_000_000_000
    /// An iPhone 16 Pro / 15 Pro (8 GB) and an iPhone 15 (6 GB), as `ProcessInfo.physicalMemory` reports them.
    private var eightGB: UInt64 { 8 * gb - 200_000_000 }
    private var sixGB: UInt64 { 6 * gb - 150_000_000 }
    /// The 4B's memoryNeededToLoad: its 3.06 GB download plus the 1.2 GB load headroom.
    private let llm4B = 4_260_000_000

    private var floor: Int { ModelBrokerPolicy.freeFloorBytes }
    private var sam: Int { ModelBrokerPolicy.estimatedBytes(.sam) }
    private var depth: Int { ModelBrokerPolicy.estimatedBytes(.depth) }

    // MARK: Constants and estimates

    func testConstantsAndEstimatesUseMebibytes() {
        XCTAssertEqual(ModelBrokerPolicy.freeFloorBytes, 700 * mib)
        XCTAssertEqual(ModelBrokerPolicy.sixGBClassLimit, 7_000_000_000)
        XCTAssertEqual(ModelBrokerPolicy.estimatedBytes(.sam), 260 * mib)
        XCTAssertEqual(ModelBrokerPolicy.estimatedBytes(.depth), 170 * mib)
        XCTAssertEqual(ModelBrokerPolicy.estimatedBytes(.lama), 380 * mib)
        XCTAssertEqual(ModelBrokerPolicy.estimatedBytes(.upscaler), 140 * mib)
        XCTAssertEqual(ModelBrokerPolicy.estimatedBytes(.stableDiffusion), 2_300 * mib)
        XCTAssertEqual(ModelBrokerPolicy.estimatedBytes(.llm), 0, "Core cannot see the LLM's size: the caller passes it")
        XCTAssertEqual(ModelBrokerPolicy.estimatedBytes(.llm, llmBytes: llm4B), llm4B)
        XCTAssertEqual(ModelBrokerPolicy.estimatedBytes(.sam, llmBytes: llm4B), 260 * mib, "llmBytes only counts for the LLM")
    }

    func testPrioritiesOrderByRawValue() {
        XCTAssertLessThan(ModelPriority.background, .preload)
        XCTAssertLessThan(ModelPriority.preload, .interactive)
        XCTAssertLessThan(ModelPriority.interactive, .userWaiting)
        XCTAssertEqual([ModelPriority.userWaiting, .background, .interactive, .preload].sorted(),
                       [.background, .preload, .interactive, .userWaiting])
        XCTAssertTrue(ModelBrokerPolicy.isSixGBClass(sixGB))
        XCTAssertFalse(ModelBrokerPolicy.isSixGBClass(eightGB))
    }

    // MARK: Admission against the floor

    func testAdmitsWhenTheFloorHolds() {
        let decision = ModelBrokerPolicy.decide(.sam, bytes: sam, priority: .preload, residents: [],
                                                availableBytes: floor + sam, physicalMemory: eightGB)
        XCTAssertEqual(decision, .admit(evicting: []))
        XCTAssertTrue(decision.isAdmitted)
    }

    func testUnknownAvailableMemoryAdmits() {
        let residents = [ModelResident(client: .lama, bytes: 380 * mib, priority: .interactive)]
        XCTAssertEqual(ModelBrokerPolicy.decide(.sam, bytes: sam, priority: .background, residents: residents,
                                                availableBytes: nil, physicalMemory: eightGB),
                       .admit(evicting: []))
    }

    func testEvictsTheLowerPriorityFirstThenTheLeastRecentlyUsed() {
        let residents = [
            ModelResident(client: .upscaler, bytes: 140 * mib, priority: .interactive, lastUse: 1),
            ModelResident(client: .lama, bytes: 380 * mib, priority: .preload, lastUse: 50),
            ModelResident(client: .depth, bytes: 170 * mib, priority: .preload, lastUse: 10),
        ]
        // 200 MiB short of the floor: depth (preload, older) alone is not enough, lama (preload) completes it;
        // the interactive upscaler stays.
        let decision = ModelBrokerPolicy.decide(.sam, bytes: sam, priority: .userWaiting, residents: residents,
                                                availableBytes: floor + sam - 200 * mib, physicalMemory: eightGB)
        XCTAssertEqual(decision, .admit(evicting: [.depth, .lama]))

        // 100 MiB short: the least recently used of the lowest priority suffices.
        XCTAssertEqual(ModelBrokerPolicy.decide(.sam, bytes: sam, priority: .userWaiting, residents: residents,
                                                availableBytes: floor + sam - 100 * mib, physicalMemory: eightGB),
                       .admit(evicting: [.depth]))
    }

    func testOnlyLowerPrioritiesAreEvicted() {
        let residents = [ModelResident(client: .lama, bytes: 380 * mib, priority: .interactive)]
        let decision = ModelBrokerPolicy.decide(.sam, bytes: sam, priority: .interactive, residents: residents,
                                                availableBytes: floor + sam - 100 * mib, physicalMemory: eightGB)
        XCTAssertFalse(decision.isAdmitted, "an equal priority is not evicted")
        XCTAssertEqual(decision.evicting, [])
    }

    func testNeverEvictsABusyResident() {
        let residents = [
            ModelResident(client: .llm, bytes: llm4B, priority: .interactive, isBusy: true),
            ModelResident(client: .lama, bytes: 380 * mib, priority: .preload, isBusy: true),
        ]
        let decision = ModelBrokerPolicy.decide(.sam, bytes: sam, priority: .userWaiting, residents: residents,
                                                availableBytes: floor, physicalMemory: eightGB)
        guard case .refuse(let reason) = decision else { return XCTFail("expected a refusal, got \(decision)") }
        XCTAssertFalse(reason.isEmpty)
    }

    func testRefusesWhenTheFloorCannotHoldAndEvictsNothing() {
        let residents = [ModelResident(client: .depth, bytes: 170 * mib, priority: .background)]
        let decision = ModelBrokerPolicy.decide(.stableDiffusion, bytes: 2_300 * mib, priority: .userWaiting,
                                                residents: residents, availableBytes: 1_000 * mib, physicalMemory: eightGB)
        XCTAssertFalse(decision.isAdmitted)
        XCTAssertEqual(decision.evicting, [], "a refusal unloads nothing")
    }

    func testAResidentClientOnlyNeedsWhatItAdds() {
        let residents = [ModelResident(client: .sam, bytes: sam, priority: .preload)]
        XCTAssertEqual(ModelBrokerPolicy.decide(.sam, bytes: sam, priority: .userWaiting, residents: residents,
                                                availableBytes: floor, physicalMemory: eightGB),
                       .admit(evicting: []), "SAM is already in the free-memory figure")
    }

    // MARK: The 8 GB class

    func testEightGBTheFourBAndSAMKeepTheFloor() {
        // The 4B loaded (it peaks near 3.9 GB under the ~6 GB per-app ceiling), about 1 GB left.
        let llm = ModelResident(client: .llm, bytes: llm4B, priority: .interactive, lastUse: 5)
        let available = 1_000 * mib
        XCTAssertEqual(ModelBrokerPolicy.decide(.sam, bytes: sam, priority: .preload, residents: [llm],
                                                availableBytes: available, physicalMemory: eightGB),
                       .admit(evicting: []), "260 MB SAM next to the 4B keeps ≥ 700 MB")
        // With less room, a preload does not push the LLM out; a tap (user waiting) does, between turns only.
        XCTAssertFalse(ModelBrokerPolicy.decide(.sam, bytes: sam, priority: .preload, residents: [llm],
                                                availableBytes: 800 * mib, physicalMemory: eightGB).isAdmitted)
        XCTAssertEqual(ModelBrokerPolicy.decide(.sam, bytes: sam, priority: .userWaiting, residents: [llm],
                                                availableBytes: 800 * mib, physicalMemory: eightGB),
                       .admit(evicting: [.llm]))
        var busy = llm
        busy.isBusy = true
        XCTAssertFalse(ModelBrokerPolicy.decide(.sam, bytes: sam, priority: .userWaiting, residents: [busy],
                                                availableBytes: 800 * mib, physicalMemory: eightGB).isAdmitted,
                       "the LLM is evicted only between Live turns")
    }

    func testEightGBDepthIsTransientWhileTheLLMIsResident() {
        let llm = ModelResident(client: .llm, bytes: llm4B, priority: .interactive)
        let samResident = ModelResident(client: .sam, bytes: sam, priority: .interactive)
        XCTAssertFalse(ModelBrokerPolicy.keepsResident(.depth, residents: [llm, samResident], physicalMemory: eightGB))
        XCTAssertTrue(ModelBrokerPolicy.keepsResident(.depth, residents: [samResident], physicalMemory: eightGB))
        XCTAssertTrue(ModelBrokerPolicy.keepsResident(.sam, residents: [llm], physicalMemory: eightGB))
        // Admitted all the same when it fits.
        XCTAssertTrue(ModelBrokerPolicy.decide(.depth, bytes: depth, priority: .interactive, residents: [llm, samResident],
                                               availableBytes: 1_000 * mib, physicalMemory: eightGB).isAdmitted)
    }

    func testEightGBStableDiffusionNeverRunsWithTheLLM() {
        let llm = ModelResident(client: .llm, bytes: llm4B, priority: .userWaiting, lastUse: 1)
        // Plenty of room on paper: the LLM still goes, whatever its priority.
        XCTAssertEqual(ModelBrokerPolicy.decide(.stableDiffusion, bytes: 2_300 * mib, priority: .userWaiting, residents: [llm],
                                                availableBytes: 8_000 * mib, physicalMemory: eightGB),
                       .admit(evicting: [.llm]))
        XCTAssertEqual(ModelBrokerPolicy.decide(.stableDiffusion, bytes: 2_300 * mib, priority: .userWaiting, residents: [llm],
                                                availableBytes: nil, physicalMemory: eightGB),
                       .admit(evicting: [.llm]), "the pairing rule holds without a memory figure too")
        var busy = llm
        busy.isBusy = true
        XCTAssertFalse(ModelBrokerPolicy.decide(.stableDiffusion, bytes: 2_300 * mib, priority: .userWaiting, residents: [busy],
                                                availableBytes: 8_000 * mib, physicalMemory: eightGB).isAdmitted)
        // And the reverse: the LLM coming back pushes an idle SD out.
        let sd = ModelResident(client: .stableDiffusion, bytes: 2_300 * mib, priority: .interactive)
        XCTAssertEqual(ModelBrokerPolicy.decide(.llm, bytes: llm4B, priority: .interactive, residents: [sd],
                                                availableBytes: 8_000 * mib, physicalMemory: eightGB),
                       .admit(evicting: [.stableDiffusion]))
        // SD and SAM may share an 8 GB phone when the floor holds.
        let samResident = ModelResident(client: .sam, bytes: sam, priority: .interactive)
        XCTAssertEqual(ModelBrokerPolicy.decide(.stableDiffusion, bytes: 2_300 * mib, priority: .userWaiting, residents: [samResident],
                                                availableBytes: 3_500 * mib, physicalMemory: eightGB),
                       .admit(evicting: []))
    }

    // MARK: The 6 GB class

    func testSixGBNeverAnLLM() {
        let decision = ModelBrokerPolicy.decide(.llm, bytes: 2_400_000_000, priority: .userWaiting, residents: [],
                                                availableBytes: 4_000 * mib, physicalMemory: sixGB)
        XCTAssertFalse(decision.isAdmitted)
        XCTAssertFalse(ModelBrokerPolicy.decide(.llm, bytes: 1, priority: .userWaiting, residents: [],
                                                availableBytes: nil, physicalMemory: sixGB).isAdmitted)
    }

    func testSixGBSAMStaysAndDepthIsTransient() {
        let samResident = ModelResident(client: .sam, bytes: sam, priority: .interactive)
        XCTAssertTrue(ModelBrokerPolicy.keepsResident(.sam, residents: [], physicalMemory: sixGB))
        XCTAssertFalse(ModelBrokerPolicy.keepsResident(.depth, residents: [], physicalMemory: sixGB))
        XCTAssertFalse(ModelBrokerPolicy.keepsResident(.depth, residents: [samResident], physicalMemory: sixGB))
        // SAM resident plus a depth request above the floor: admitted, nothing evicted.
        XCTAssertEqual(ModelBrokerPolicy.decide(.depth, bytes: depth, priority: .interactive, residents: [samResident],
                                                availableBytes: floor + depth + 50 * mib, physicalMemory: sixGB),
                       .admit(evicting: []))
    }

    func testSixGBStableDiffusionRunsAlone() {
        let residents = [
            ModelResident(client: .sam, bytes: sam, priority: .interactive, lastUse: 3),
            ModelResident(client: .lama, bytes: 380 * mib, priority: .userWaiting, lastUse: 1),
        ]
        XCTAssertEqual(ModelBrokerPolicy.decide(.stableDiffusion, bytes: 2_300 * mib, priority: .userWaiting, residents: residents,
                                                availableBytes: 6_000 * mib, physicalMemory: sixGB),
                       .admit(evicting: [.sam, .lama]))
        // Something else asking while SD is loaded and idle pushes SD out; while SD works, it waits.
        let sd = ModelResident(client: .stableDiffusion, bytes: 2_300 * mib, priority: .interactive)
        XCTAssertEqual(ModelBrokerPolicy.decide(.sam, bytes: sam, priority: .userWaiting, residents: [sd],
                                                availableBytes: 3_000 * mib, physicalMemory: sixGB),
                       .admit(evicting: [.stableDiffusion]))
        var busy = sd
        busy.isBusy = true
        XCTAssertFalse(ModelBrokerPolicy.decide(.sam, bytes: sam, priority: .userWaiting, residents: [busy],
                                                availableBytes: 3_000 * mib, physicalMemory: sixGB).isAdmitted)
        // On 8 GB the same pairing is left to the floor.
        XCTAssertEqual(ModelBrokerPolicy.conflicts(of: .sam, among: [sd], physicalMemory: eightGB), [])
    }

    // MARK: Export

    func testExportReleasesSAMAndDepthAlwaysAndTheLLMWhenBigOrShort() {
        let residents = [
            ModelResident(client: .llm, bytes: llm4B, priority: .interactive),
            ModelResident(client: .depth, bytes: depth, priority: .interactive),
            ModelResident(client: .sam, bytes: sam, priority: .interactive),
            ModelResident(client: .lama, bytes: 380 * mib, priority: .interactive),
        ]
        XCTAssertEqual(ModelBrokerPolicy.exportReleases(residents: residents, megapixels: 12, availableBytes: 3_000 * mib), [.sam, .depth])
        XCTAssertEqual(ModelBrokerPolicy.exportReleases(residents: residents, megapixels: 48, availableBytes: 3_000 * mib), [.sam, .depth, .llm])
        XCTAssertEqual(ModelBrokerPolicy.exportReleases(residents: residents, megapixels: 24, availableBytes: nil), [.sam, .depth, .llm])
        XCTAssertEqual(ModelBrokerPolicy.exportReleases(residents: residents, megapixels: 12, availableBytes: 1_000 * mib), [.sam, .depth, .llm])
        XCTAssertEqual(ModelBrokerPolicy.exportReleases(residents: residents, megapixels: 12, availableBytes: nil), [.sam, .depth])
        // Only what is loaded, and never a busy model.
        XCTAssertEqual(ModelBrokerPolicy.exportReleases(residents: [], megapixels: 48, availableBytes: 100), [])
        let busyLLM = [ModelResident(client: .llm, bytes: llm4B, priority: .interactive, isBusy: true),
                       ModelResident(client: .sam, bytes: sam, priority: .interactive)]
        XCTAssertEqual(ModelBrokerPolicy.exportReleases(residents: busyLLM, megapixels: 48, availableBytes: nil), [.sam])
    }

    // MARK: The ledger

    func testLedgerTracksLoadsBusyMarksAndEvictions() {
        var ledger = ModelBrokerLedger()
        ledger.noteLoaded(.llm, bytes: llm4B, now: 1)
        XCTAssertEqual(ledger.resident(.llm)?.priority, .interactive, "the LLM loads without asking")

        XCTAssertTrue(ledger.request(.sam, bytes: sam, priority: .preload, availableBytes: 1_000 * mib,
                                     physicalMemory: eightGB, now: 2).isAdmitted)
        XCTAssertEqual(ledger.pending[.sam]?.bytes, sam)
        ledger.noteLoaded(.sam, bytes: sam, now: 3)
        XCTAssertNil(ledger.pending[.sam])
        XCTAssertEqual(ledger.resident(.sam)?.priority, .preload)
        XCTAssertEqual(ledger.residentBytes, llm4B + sam)

        // A Live turn makes the LLM busy: a user-waiting LaMa that needs its room is refused.
        ledger.markBusy(.llm, true, now: 4)
        let refused = ledger.request(.lama, bytes: 380 * mib, priority: .userWaiting, availableBytes: 400 * mib,
                                     physicalMemory: eightGB, now: 5)
        XCTAssertFalse(refused.isAdmitted)
        XCTAssertTrue(ledger.isResident(.llm))
        XCTAssertTrue(ledger.isResident(.sam), "a refusal evicts nothing")

        // Between turns, the same request evicts SAM first (preload < interactive), then the LLM.
        ledger.markBusy(.llm, false, now: 6)
        let admitted = ledger.request(.lama, bytes: 380 * mib, priority: .userWaiting, availableBytes: 400 * mib,
                                      physicalMemory: eightGB, now: 7)
        XCTAssertEqual(admitted, .admit(evicting: [.sam, .llm]))
        XCTAssertFalse(ledger.isResident(.sam))
        XCTAssertFalse(ledger.isResident(.llm))
        ledger.noteLoaded(.lama, bytes: 380 * mib, now: 8)
        XCTAssertEqual(ledger.resident(.lama)?.priority, .interactive, "kept priority is capped at interactive once idle")
        ledger.noteUnloaded(.lama)
        XCTAssertTrue(ledger.residents.isEmpty)
    }

    func testLedgerBusyMarksNest() {
        var ledger = ModelBrokerLedger()
        ledger.noteLoaded(.sam, bytes: sam, now: 0)
        XCTAssertTrue(ledger.markBusy(.sam, true, now: 1))
        XCTAssertTrue(ledger.markBusy(.sam, true, now: 2))
        XCTAssertTrue(ledger.markBusy(.sam, false, now: 3), "one segment is still running")
        XCTAssertEqual(ledger.resident(.sam)?.isBusy, true)
        XCTAssertFalse(ledger.markBusy(.sam, false, now: 4))
        XCTAssertFalse(ledger.markBusy(.sam, false, now: 5), "an extra 'idle' never goes negative")
        XCTAssertTrue(ledger.markBusy(.sam, true, now: 6))
        XCTAssertEqual(ledger.resident(.sam)?.lastUse, 6)
    }

    func testLedgerCountsPendingAdmissionsUntilTheyLoadOrExpire() {
        var ledger = ModelBrokerLedger()
        let available = floor + 400 * mib
        XCTAssertTrue(ledger.request(.sam, bytes: sam, priority: .interactive, availableBytes: available,
                                     physicalMemory: eightGB, now: 0).isAdmitted)
        // LaMa asks before SAM has loaded: SAM's bytes are not in the free figure yet, so they count.
        XCTAssertFalse(ledger.request(.lama, bytes: 380 * mib, priority: .interactive, availableBytes: available,
                                      physicalMemory: eightGB, now: 1).isAdmitted)
        // A load that never reported back stops counting after its lifetime.
        XCTAssertTrue(ledger.request(.lama, bytes: 380 * mib, priority: .interactive, availableBytes: available,
                                     physicalMemory: eightGB, now: ModelBrokerLedger.pendingLifetime + 1).isAdmitted)
    }

    func testLedgerExportAndIdleDepth() {
        var ledger = ModelBrokerLedger()
        ledger.noteLoaded(.llm, bytes: llm4B, now: 0)
        ledger.noteLoaded(.sam, bytes: sam, now: 1)
        ledger.noteLoaded(.depth, bytes: depth, now: 2)
        ledger.markBusy(.depth, true, now: 3)
        XCTAssertFalse(ledger.shouldUnloadWhenIdle(.depth, physicalMemory: eightGB), "busy: not now")
        ledger.markBusy(.depth, false, now: 4)
        XCTAssertTrue(ledger.shouldUnloadWhenIdle(.depth, physicalMemory: eightGB), "transient while the LLM is resident")
        XCTAssertFalse(ledger.shouldUnloadWhenIdle(.sam, physicalMemory: eightGB))

        XCTAssertEqual(ledger.releaseForExport(megapixels: 48, availableBytes: 3_000 * mib), [.sam, .depth, .llm])
        XCTAssertTrue(ledger.residents.isEmpty)
    }

    func testLedgerSixGBDepthNeverStays() {
        var ledger = ModelBrokerLedger()
        XCTAssertTrue(ledger.request(.depth, bytes: depth, priority: .interactive, availableBytes: 2_000 * mib,
                                     physicalMemory: sixGB, now: 0).isAdmitted)
        ledger.noteLoaded(.depth, bytes: depth, now: 1)
        XCTAssertTrue(ledger.shouldUnloadWhenIdle(.depth, physicalMemory: sixGB))
        XCTAssertFalse(ledger.request(.llm, bytes: 2_400_000_000, priority: .userWaiting, availableBytes: 4_000 * mib,
                                      physicalMemory: sixGB, now: 2).isAdmitted)
    }

    /// Room for the LLM (it loads without asking) and the memory warning: idle models only, lowest priority first,
    /// then least recently used; a busy one and the LLM never.
    func testTheRoomOrderForTheLLM() {
        let residents = [
            ModelResident(client: .lama, bytes: 380 * mib, priority: .interactive, lastUse: 1),
            ModelResident(client: .sam, bytes: sam, priority: .preload, lastUse: 40),
            ModelResident(client: .upscaler, bytes: 140 * mib, priority: .preload, lastUse: 5),
            ModelResident(client: .depth, bytes: 170 * mib, priority: .preload, isBusy: true),
            ModelResident(client: .llm, bytes: llm4B, priority: .interactive),
        ]
        XCTAssertEqual(ModelBrokerPolicy.roomOrder(for: .llm, residents: residents), [.upscaler, .sam, .lama])
        XCTAssertEqual(ModelBrokerPolicy.roomOrder(for: .sam, residents: residents), [.upscaler, .lama], "never the client itself")
        XCTAssertEqual(ModelBrokerPolicy.roomOrder(for: .llm, residents: []), [])
    }
}
