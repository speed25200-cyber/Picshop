import Foundation

/// Zoom cuts, as creators edit talking videos: after jump cuts, every other
/// segment is framed a little tighter, so the cut reads as a new angle
/// instead of a jump in the same shot.
public enum PunchIn {
    /// Whether the cut into clip `index` is a jump cut: the same file, later
    /// in time, not far after the previous clip.
    public static func isJumpCut(into index: Int, clips: [VideoClip]) -> Bool {
        guard index > 0, index < clips.count else { return false }
        let a = clips[index - 1], b = clips[index]
        guard a.renderAsset.relativePath == b.renderAsset.relativePath, !a.isReversed, !b.isReversed else { return false }
        let gap = b.sourceRange.start - a.sourceRange.end
        return gap >= -0.05 && gap < 30
    }

    /// The zoom for each clip: runs of jump cuts alternate between the wide
    /// frame and `zoom`; clips framed by a move of their own are left alone.
    public static func plan(clips: [VideoClip], zoom: Double = 1.18) -> [Double] {
        var zooms = [Double](repeating: 1, count: clips.count)
        var tight = false
        for index in clips.indices {
            if isJumpCut(into: index, clips: clips) {
                tight.toggle()
            } else {
                tight = false
            }
            let ownMove = clips[index].motion.map { $0.kind == .kenBurns || $0.kind == .smartReframe || $0.kind == .manual } ?? false
            zooms[index] = tight && !ownMove ? zoom : 1
        }
        return zooms
    }

    /// A still frame at `zoom` around `focus` for the whole clip.
    public static func motion(zoom: Double, focus: PSPoint, duration: Double) -> ClipMotion {
        ClipMotion(kind: .punchIn, keyframes: [MotionKeyframe(time: 0, focus: focus, zoom: zoom, easing: .linear),
                                               MotionKeyframe(time: max(0.01, duration), focus: focus, zoom: zoom, easing: .linear)])
    }
}
