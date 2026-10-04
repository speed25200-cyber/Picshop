#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import QuartzCore
import CoreImage
import PicshopCore
import PicshopImaging

/// Drives the photo canvas from the display instead of a sleep: one
/// CADisplayLink (80–120 Hz, capped by the performance governor), paused
/// whenever there is nothing to draw, asks a `FramePacer` on every vsync
/// whether to start a render. Frames under the finger go straight to the
/// canvas sink, their mask overlay with them (`presentOverlay`, same
/// generation); the sharp frame after 120 ms of stillness is published to
/// SwiftUI, the histogram and Live. Behind the `displayLinkCanvas` flag; the
/// session's sleep-paced loop stays for one wave as the fallback.
@MainActor
final class CanvasFramePump {
    private weak var session: PhotoEditorSession?
    private var pacer: FramePacer
    private var link: CADisplayLink?
    private var renderTask: Task<Void, Never>?
    private var generation = 0
    /// touchToPhoton: opened by the first change a frame will show, closed when that frame is on the glass.
    private var pendingTouch: PSSignpost.Interval?
    private var touchByGeneration: [Int: PSSignpost.Interval] = [:]
    private var appliedCap: Int = 0

    init(session: PhotoEditorSession) {
        self.session = session
        pacer = FramePacer(settleDelay: Self.settleDelay(for: session.app.performance))
    }

    /// The sharp frame follows 120 ms of stillness; a hot phone waits longer, as before.
    static func settleDelay(for governor: PerformanceGovernor) -> Double {
        guard governor.tier != .full else { return 0.12 }
        let delay = governor.settleDelay.components
        return Double(delay.seconds) + Double(delay.attoseconds) / 1e18
    }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: DisplayLinkProxy { [weak self] in self?.tick() }, selector: #selector(DisplayLinkProxy.tick))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
        updateLink()
    }

    func stop() {
        link?.invalidate()
        link = nil
        renderTask?.cancel()
        renderTask = nil
        if let pending = pendingTouch { PSSignpost.end(pending) }
        pendingTouch = nil
        for interval in touchByGeneration.values { PSSignpost.end(interval) }
        touchByGeneration = [:]
    }

    /// The document (or what the canvas shows of it) changed.
    func markDirty(interactive: Bool) {
        if interactive, pendingTouch == nil { pendingTouch = PSSignpost.begin("touchToPhoton") }
        if let session { pacer.settleDelay = Self.settleDelay(for: session.app.performance) }
        pacer.markDirty(interactive: interactive, now: CACurrentMediaTime())
        updateLink()
    }

    /// A frame reached the glass: every touch it (or an older frame) carried is done.
    func framePresented(generation presented: Int, at time: CFTimeInterval) {
        for (generation, interval) in touchByGeneration where generation <= presented {
            PSSignpost.end(interval)
            touchByGeneration.removeValue(forKey: generation)
        }
    }

    // MARK: Display link

    private func tick() {
        guard let session else {
            stop()
            return
        }
        switch pacer.tick(now: CACurrentMediaTime(), renderInFlight: renderTask != nil) {
        case .none: break
        case .renderInteractive: render(interactive: true, session: session)
        case .renderSettled: render(interactive: false, session: session)
        }
        updateLink()
    }

    private func render(interactive: Bool, session: PhotoEditorSession) {
        generation += 1
        let generation = generation
        if let touch = pendingTouch {
            touchByGeneration[generation] = touch
            pendingTouch = nil
        }
        session.isRendering = true
        renderTask = Task { [weak self, weak session] in
            // The frame and its mask or selection overlay (W2, D17): one render, one generation for both.
            let rendered = await session?.renderFrame(interactive: interactive)
            guard let self else { return }
            self.renderTask = nil
            if let session, let rendered, !Task.isCancelled {
                session.frameRendered(rendered.image, overlay: rendered.overlay, interactive: interactive, generation: generation)
            }
            self.pacer.renderFinished(now: CACurrentMediaTime())
            if self.pacer.phase == .idle { session?.isRendering = false }
            self.updateLink()
        }
    }

    /// Runs only while the pacer has something to do, at the governor's rate.
    private func updateLink() {
        guard let link else { return }
        let wants = pacer.wantsFrames
        if wants, let cap = session?.app.performance.maxFrameRate, cap != appliedCap {
            appliedCap = cap
            let rate = Float(max(30, cap))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, rate), maximum: rate, preferred: rate)
        }
        if link.isPaused == wants { link.isPaused = !wants }
    }
}

/// The display link's target (a CADisplayLink retains it): calls back on the main run loop.
private final class DisplayLinkProxy: NSObject {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func tick() {
        MainActor.assumeIsolated { action() }
    }
}
#endif
