import Foundation

// The video editor's tool homes (ux-spec §3.6). Owned by U3. Increment 1 keeps the video editor's current UI, so
// the table is empty until U3 fills it (global bar, clip bars, VideoToolCatalog's tools as homes).

extension ToolLayout {
    /// The video editor's table (empty until U3 lands the video frame).
    public static let video = ToolLayout(kind: .video, categories: [])
}
