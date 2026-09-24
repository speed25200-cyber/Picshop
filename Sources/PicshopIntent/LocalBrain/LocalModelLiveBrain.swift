import Foundation
import PicshopCore

/// Live's model brain: Qwen3.5 on the iPhone, through a `LocalChatEngine`.
/// It talks, looks at the picture when it needs to, and acts only through the
/// four validated tools. When it cannot answer before saying anything, the turn
/// goes to `fallback`, the rules-only grammar.
///
/// Phase 0: the frozen signature. A turn yields `.started` then
/// `.completed(.answered)`; the tool loop, pictures, deadlines and compaction
/// arrive in phase 1.
public actor LocalModelLiveBrain: LiveBrain {
    public struct Limits: Sendable, Equatable {
        /// Seconds without a token before `.timeout(stage: "first_token")`.
        public var firstTokenTimeout = 6.0
        public var turnTimeout = 25.0
        /// Generations per turn, tool round trips included.
        public var maxRounds = 3
        public var maxApplyEdits = 2
        /// Context tokens above which the conversation is compacted.
        public var compactAt = 6_000
        public var maxImagesInContext = 2
        public var speechMaxTokens = 120
        /// Session start and opinions, when propose_ideas is expected.
        public var ideasMaxTokens = 320
        /// Thermal state serious.
        public var hotMaxTokens = 80

        public init() {}
    }

    /// .model
    public nonisolated let kind: LiveBrainKind
    public nonisolated let capabilities: LiveBrainCapabilities

    private let mode: EditorMode
    private let info: LocalModelInfo
    private let makeEngine: LocalChatEngineFactory
    private let fallback: (any LiveBrain)?
    private let limits: Limits
    private let clock: any LiveClock
    private let log: (@Sendable (LiveLogEntry) -> Void)?
    private var thermalSerious = false

    /// The long side of the snapshot the session hands over for a look.
    private static let imageMaxPixel = 768

    public init(mode: EditorMode, info: LocalModelInfo, makeEngine: @escaping LocalChatEngineFactory,
                fallback: (any LiveBrain)?, limits: Limits = .init(),
                clock: any LiveClock = SystemLiveClock(), log: (@Sendable (LiveLogEntry) -> Void)? = nil) {
        kind = .model
        capabilities = LiveBrainCapabilities(opensSession: true, seesImages: info.supportsVision, imageMaxPixel: Self.imageMaxPixel, proposesIdeas: true)
        self.mode = mode
        self.info = info
        self.makeEngine = makeEngine
        self.fallback = fallback
        self.limits = limits
        self.clock = clock
        self.log = log
    }

    /// Serious: shorter answers (`hotMaxTokens`) and no ideas at session start.
    public func setThermalSerious(_ serious: Bool) {
        thermalSerious = serious
    }

    public func isAvailable() async -> Bool { true }

    public func warmUp() async {}

    public nonisolated func respond(to turn: LiveUserTurn, tools: any LiveToolHandler) -> AsyncThrowingStream<LiveBrainEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<LiveBrainEvent, Error>.makeStream()
        let task = Task {
            await self.answer(turn, output: continuation)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func answer(_ turn: LiveUserTurn, output: AsyncThrowingStream<LiveBrainEvent, Error>.Continuation) {
        output.yield(.started(model: info.displayName))
        output.yield(.completed(.answered))
    }

    /// Records what was heard for the next message (`interruptedAfter`); there is no rewind.
    public func interrupt(turn: Int, spokenText: String) async {}

    public func reset() async {}
}
