import Foundation

/// A half-open time interval in seconds.
public struct TimeSpan: Hashable, Codable, Sendable {
    public var start: Double
    public var duration: Double

    public init(start: Double, duration: Double) {
        self.start = max(0, start)
        self.duration = max(0, duration)
    }

    public init(start: Double, end: Double) {
        self.init(start: start, duration: end - start)
    }

    public var end: Double { start + duration }
    public var isEmpty: Bool { duration <= 0 }

    public func contains(_ time: Double) -> Bool { time >= start && time < end }

    public func clamped(to bounds: TimeSpan) -> TimeSpan {
        let s = min(max(start, bounds.start), bounds.end)
        let e = min(max(end, bounds.start), bounds.end)
        return TimeSpan(start: s, end: e)
    }
}

public enum TransitionKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case none
    case crossDissolve
    case fadeToBlack
    case fadeToWhite
    case slideLeft
    case slideRight
    case wipeLeft
    case zoom
    case blur

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .crossDissolve: return "Dissolve"
        case .fadeToBlack: return "Fade to Black"
        case .fadeToWhite: return "Fade to White"
        case .slideLeft: return "Slide Left"
        case .slideRight: return "Slide Right"
        case .wipeLeft: return "Wipe"
        case .zoom: return "Zoom"
        case .blur: return "Blur"
        }
    }

    public var aliases: [String] {
        switch self {
        case .none: return ["none", "aucune", "aucun", "cut", "sans transition"]
        case .crossDissolve: return ["dissolve", "cross dissolve", "crossfade", "fondu", "fondu enchaine", "cross fade", "fade"]
        case .fadeToBlack: return ["fade to black", "fondu au noir", "noir", "black"]
        case .fadeToWhite: return ["fade to white", "fondu au blanc", "blanc", "white"]
        case .slideLeft: return ["slide", "slide left", "glisser", "glissement", "glissement gauche"]
        case .slideRight: return ["slide right", "glissement droite"]
        case .wipeLeft: return ["wipe", "balayage", "volet"]
        case .zoom: return ["zoom", "zoom transition"]
        case .blur: return ["blur", "flou", "blur transition"]
        }
    }

    public static func matching(_ text: String) -> TransitionKind? {
        let query = text.normalizedForMatching
        var best: (TransitionKind, Int)?
        for kind in allCases {
            for alias in kind.aliases where query == alias || query.contains(alias) {
                if best == nil || alias.count > best!.1 { best = (kind, alias.count) }
            }
        }
        return best?.0
    }
}

public struct Transition: Hashable, Codable, Sendable {
    public var kind: TransitionKind
    public var duration: Double

    public init(kind: TransitionKind, duration: Double = 0.5) {
        self.kind = kind
        self.duration = max(0.1, min(duration, 3))
    }
}

/// A clip on the primary video track.
public struct VideoClip: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var asset: MediaAsset
    /// Range of the *source* media used by this clip (before speed).
    public var sourceRange: TimeSpan
    /// Playback rate. 1 = normal, 2 = twice as fast, 0.5 = half speed.
    public var speed: Double
    public var volume: Double
    public var isMuted: Bool
    public var isReversed: Bool
    public var adjustments: Adjustments
    public var look: FilterPreset
    public var lookIntensity: Double
    /// Normalised crop inside the source frame.
    public var crop: PSRect?
    public var rotation: Double
    public var flipHorizontal: Bool
    /// Transition *into the next clip*.
    public var transitionOut: Transition?
    /// When an AI process (object removal, stabilisation) produced a new
    /// rendered file, it is referenced here and used instead of `asset`.
    public var processedAsset: MediaAsset?
    public var processedLabel: String?
    public var name: String

    public init(id: UUID = UUID(), asset: MediaAsset, sourceRange: TimeSpan? = nil, speed: Double = 1, volume: Double = 1,
                isMuted: Bool = false, isReversed: Bool = false, adjustments: Adjustments = .neutral, look: FilterPreset = .original,
                lookIntensity: Double = 1, crop: PSRect? = nil, rotation: Double = 0, flipHorizontal: Bool = false,
                transitionOut: Transition? = nil, processedAsset: MediaAsset? = nil, processedLabel: String? = nil, name: String? = nil) {
        self.id = id
        self.asset = asset
        self.sourceRange = sourceRange ?? TimeSpan(start: 0, duration: asset.duration)
        self.speed = max(0.1, min(speed, 8))
        self.volume = volume.clamped(to: 0...2)
        self.isMuted = isMuted
        self.isReversed = isReversed
        self.adjustments = adjustments
        self.look = look
        self.lookIntensity = lookIntensity
        self.crop = crop
        self.rotation = rotation
        self.flipHorizontal = flipHorizontal
        self.transitionOut = transitionOut
        self.processedAsset = processedAsset
        self.processedLabel = processedLabel
        self.name = name ?? "Clip"
    }

    /// The media the renderer should read from.
    public var renderAsset: MediaAsset { processedAsset ?? asset }

    /// Duration on the timeline after speed is applied.
    public var timelineDuration: Double { sourceRange.duration / speed }

    /// Maps a time offset within this clip on the timeline to a source time.
    public func sourceTime(forClipOffset offset: Double) -> Double {
        let clamped = offset.clamped(to: 0...timelineDuration)
        return isReversed ? sourceRange.end - clamped * speed : sourceRange.start + clamped * speed
    }
}

public struct AudioTrack: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var asset: MediaAsset
    public var timelineStart: Double
    public var sourceRange: TimeSpan
    public var volume: Double
    public var fadeIn: Double
    public var fadeOut: Double
    /// Lower this track when clip audio is present.
    public var ducking: Double
    public var name: String

    public init(id: UUID = UUID(), asset: MediaAsset, timelineStart: Double = 0, sourceRange: TimeSpan? = nil, volume: Double = 0.8,
                fadeIn: Double = 0.5, fadeOut: Double = 1, ducking: Double = 0.4, name: String = "Music") {
        self.id = id
        self.asset = asset
        self.timelineStart = timelineStart
        self.sourceRange = sourceRange ?? TimeSpan(start: 0, duration: asset.duration)
        self.volume = volume
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.ducking = ducking
        self.name = name
    }
}

/// Something drawn on top of the video for a period of time.
public struct TimelineOverlay: Hashable, Codable, Sendable, Identifiable {
    public enum Content: Hashable, Codable, Sendable {
        case text(TextElement)
        case image(MediaAsset, transform: LayerTransform)
        case shape(ShapeElement, center: PSPoint)
    }

    public var id: UUID
    public var content: Content
    public var span: TimeSpan
    public var fadeIn: Double
    public var fadeOut: Double

    public init(id: UUID = UUID(), content: Content, span: TimeSpan, fadeIn: Double = 0.25, fadeOut: Double = 0.25) {
        self.id = id
        self.content = content
        self.span = span
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    public var textElement: TextElement? {
        if case .text(let element) = content { return element }
        return nil
    }
}

public enum AspectPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case original
    case free
    case square
    case ratio4x3
    case ratio3x4
    case ratio3x2
    case ratio2x3
    case ratio16x9
    case ratio9x16
    case ratio21x9
    case ratio5x4
    case ratio4x5

    public var id: String { rawValue }

    /// Width / height, nil for original/free.
    public var value: Double? {
        switch self {
        case .original, .free: return nil
        case .square: return 1
        case .ratio4x3: return 4.0 / 3.0
        case .ratio3x4: return 3.0 / 4.0
        case .ratio3x2: return 3.0 / 2.0
        case .ratio2x3: return 2.0 / 3.0
        case .ratio16x9: return 16.0 / 9.0
        case .ratio9x16: return 9.0 / 16.0
        case .ratio21x9: return 21.0 / 9.0
        case .ratio5x4: return 5.0 / 4.0
        case .ratio4x5: return 4.0 / 5.0
        }
    }

    public var displayName: String {
        switch self {
        case .original: return "Original"
        case .free: return "Free"
        case .square: return "1:1"
        case .ratio4x3: return "4:3"
        case .ratio3x4: return "3:4"
        case .ratio3x2: return "3:2"
        case .ratio2x3: return "2:3"
        case .ratio16x9: return "16:9"
        case .ratio9x16: return "9:16"
        case .ratio21x9: return "21:9"
        case .ratio5x4: return "5:4"
        case .ratio4x5: return "4:5"
        }
    }

    public var aliases: [String] {
        switch self {
        case .original: return ["original", "origine", "d'origine", "reset crop"]
        case .free: return ["free", "libre"]
        case .square: return ["square", "carre", "1:1", "1 1", "un sur un", "one by one", "instagram post", "instagram square", "1 par 1"]
        case .ratio4x3: return ["4:3", "4 3", "4 by 3", "4 par 3", "quatre tiers", "four three", "four by three", "quatre trois"]
        case .ratio3x4: return ["3:4", "3 4", "3 by 4", "3 par 4", "three by four", "trois quatre"]
        case .ratio3x2: return ["3:2", "3 2", "3 by 2", "3 par 2", "three by two", "trois deux"]
        case .ratio2x3: return ["2:3", "2 3", "2 by 3", "2 par 3", "two by three", "deux trois"]
        case .ratio16x9: return ["16:9", "16 9", "16 by 9", "16 par 9", "sixteen nine", "sixteen by nine", "seize neuvieme", "seize neuf", "widescreen", "landscape", "paysage", "youtube", "horizontal"]
        case .ratio9x16: return ["9:16", "9 16", "9 by 16", "9 par 16", "nine sixteen", "nine by sixteen", "neuf seize", "portrait", "vertical", "story", "stories", "instagram story", "insta story", "reel", "reels", "tiktok", "shorts"]
        case .ratio21x9: return ["21:9", "21 9", "21 by 9", "21 par 9", "cinemascope", "ultra wide", "ultrawide", "anamorphic", "cinema"]
        case .ratio5x4: return ["5:4", "5 4", "5 by 4", "5 par 4"]
        case .ratio4x5: return ["4:5", "4 5", "4 by 5", "4 par 5", "instagram portrait"]
        }
    }

    public static func matching(_ text: String) -> AspectPreset? {
        let query = text.normalizedForMatching
        var best: (AspectPreset, Int)?
        for preset in allCases {
            for alias in preset.aliases where query == alias || query.contains(alias) {
                if best == nil || alias.count > best!.1 { best = (preset, alias.count) }
            }
        }
        return best?.0
    }

    /// A centred crop rectangle with this aspect inside a canvas of `size`.
    public func cropRect(in size: PSSize) -> PSRect {
        guard let target = value, !size.isEmpty else { return .unit }
        let current = size.aspectRatio
        if target > current {
            let height = current / target
            return PSRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
        } else {
            let width = target / current
            return PSRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
        }
    }
}

/// The complete state of a video project.
public struct VideoTimeline: Hashable, Codable, Sendable, Identifiable {
    public static let formatVersion = 1

    public var id: UUID
    public var formatVersion: Int
    public var title: String
    public var clips: [VideoClip]
    public var overlays: [TimelineOverlay]
    public var audioTracks: [AudioTrack]
    public var renderSize: PSSize
    public var frameRate: Double
    public var aspect: AspectPreset
    public var backgroundColor: PSColor
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), title: String, clips: [VideoClip] = [], overlays: [TimelineOverlay] = [],
                audioTracks: [AudioTrack] = [], renderSize: PSSize = PSSize(width: 1920, height: 1080), frameRate: Double = 30,
                aspect: AspectPreset = .original, backgroundColor: PSColor = .black, createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.id = id
        self.formatVersion = Self.formatVersion
        self.title = title
        self.clips = clips
        self.overlays = overlays
        self.audioTracks = audioTracks
        self.renderSize = renderSize
        self.frameRate = frameRate
        self.aspect = aspect
        self.backgroundColor = backgroundColor
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    public init(title: String, asset: MediaAsset) {
        let clip = VideoClip(asset: asset, name: title)
        let size = asset.pixelSize.isEmpty ? PSSize(width: 1920, height: 1080) : asset.pixelSize
        self.init(title: title, clips: [clip], renderSize: size, frameRate: asset.frameRate > 0 ? asset.frameRate : 30)
    }

    // MARK: Time mapping

    /// Total duration on the timeline, accounting for overlapping transitions.
    public var duration: Double {
        var total = 0.0
        for (index, clip) in clips.enumerated() {
            total += clip.timelineDuration
            if index < clips.count - 1, let transition = clip.transitionOut, transition.kind != .none {
                total -= min(transition.duration, clip.timelineDuration / 2, clips[index + 1].timelineDuration / 2)
            }
        }
        return max(0, total)
    }

    /// Start time of each clip on the timeline (parallel array to `clips`).
    public var clipStartTimes: [Double] {
        var starts: [Double] = []
        var cursor = 0.0
        for (index, clip) in clips.enumerated() {
            starts.append(cursor)
            cursor += clip.timelineDuration
            if index < clips.count - 1, let transition = clip.transitionOut, transition.kind != .none {
                cursor -= min(transition.duration, clip.timelineDuration / 2, clips[index + 1].timelineDuration / 2)
            }
        }
        return starts
    }

    public func span(of clipID: UUID) -> TimeSpan? {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return nil }
        return TimeSpan(start: clipStartTimes[index], duration: clips[index].timelineDuration)
    }

    /// The clip under the playhead. During a transition overlap the outgoing clip is returned.
    public func clipIndex(at time: Double) -> Int? {
        let starts = clipStartTimes
        for index in stride(from: clips.count - 1, through: 0, by: -1) {
            let span = TimeSpan(start: starts[index], duration: clips[index].timelineDuration)
            if span.contains(time) || (index == clips.count - 1 && time >= span.end && time <= span.end + 0.001) {
                if index > 0 {
                    let previousEnd = starts[index - 1] + clips[index - 1].timelineDuration
                    if time < previousEnd && time < starts[index] + (clips[index - 1].transitionOut?.duration ?? 0) {
                        return index - 1
                    }
                }
                return index
            }
        }
        return clips.isEmpty ? nil : (time < 0 ? 0 : clips.count - 1)
    }

    public func clip(at time: Double) -> VideoClip? {
        guard let index = clipIndex(at: time) else { return nil }
        return clips[index]
    }

    public var isEmpty: Bool { clips.isEmpty }

    // MARK: Editing operations

    public mutating func touch() { modifiedAt = Date() }

    public func index(of clipID: UUID) -> Int? { clips.firstIndex(where: { $0.id == clipID }) }

    public mutating func update(clipID: UUID, _ body: (inout VideoClip) -> Void) {
        guard let index = index(of: clipID) else { return }
        body(&clips[index])
        touch()
    }

    /// Splits the clip under `time` into two clips at that point.
    @discardableResult
    public mutating func split(at time: Double) -> (UUID, UUID)? {
        guard let index = clipIndex(at: time) else { return nil }
        let start = clipStartTimes[index]
        let clip = clips[index]
        let offset = time - start
        guard offset > 0.05, offset < clip.timelineDuration - 0.05 else { return nil }
        let sourceSplit = clip.sourceRange.start + offset * clip.speed
        var first = clip
        first.sourceRange = TimeSpan(start: clip.sourceRange.start, end: sourceSplit)
        first.transitionOut = nil
        var second = clip
        second.id = UUID()
        second.sourceRange = TimeSpan(start: sourceSplit, end: clip.sourceRange.end)
        second.name = clip.name
        clips[index] = first
        clips.insert(second, at: index + 1)
        touch()
        return (first.id, second.id)
    }

    /// Trims the clip so it starts `newStart` seconds after the original source start
    /// and ends at `newEnd` (timeline-relative offsets within the clip).
    public mutating func trim(clipID: UUID, startOffset: Double? = nil, endOffset: Double? = nil) {
        guard let index = index(of: clipID) else { return }
        var clip = clips[index]
        let sourceStart = startOffset.map { clip.sourceRange.start + max(0, $0) * clip.speed } ?? clip.sourceRange.start
        let sourceEnd = endOffset.map { clip.sourceRange.start + max(0, $0) * clip.speed } ?? clip.sourceRange.end
        let bounded = TimeSpan(start: sourceStart, end: min(sourceEnd, clip.asset.duration > 0 ? clip.asset.duration : sourceEnd))
        guard bounded.duration >= 0.1 else { return }
        clip.sourceRange = bounded
        clips[index] = clip
        touch()
    }

    /// Removes the timeline range, splitting clips as required.
    public mutating func removeRange(_ range: TimeSpan) {
        guard !range.isEmpty, !clips.isEmpty else { return }
        split(at: range.end)
        split(at: range.start)
        let starts = clipStartTimes
        var survivors: [VideoClip] = []
        for (index, clip) in clips.enumerated() {
            let span = TimeSpan(start: starts[index], duration: clip.timelineDuration)
            let overlap = TimeSpan(start: max(span.start, range.start), end: min(span.end, range.end))
            if overlap.duration <= 0.001 || overlap.duration < span.duration - 0.001 {
                survivors.append(clip)
            }
        }
        clips = survivors
        touch()
    }

    @discardableResult
    public mutating func removeClip(id: UUID) -> VideoClip? {
        guard let index = index(of: id) else { return nil }
        let removed = clips.remove(at: index)
        touch()
        return removed
    }

    public mutating func moveClip(id: UUID, to newIndex: Int) {
        guard let index = index(of: id), newIndex >= 0, newIndex < clips.count, index != newIndex else { return }
        let clip = clips.remove(at: index)
        clips.insert(clip, at: newIndex)
        touch()
    }

    public mutating func duplicateClip(id: UUID) {
        guard let index = index(of: id) else { return }
        var copy = clips[index]
        copy.id = UUID()
        clips.insert(copy, at: index + 1)
        touch()
    }

    public mutating func setTransition(_ transition: Transition?, afterClipID: UUID) {
        update(clipID: afterClipID) { $0.transitionOut = transition }
    }

    public mutating func addOverlay(_ overlay: TimelineOverlay) {
        overlays.append(overlay)
        touch()
    }

    public mutating func removeOverlay(id: UUID) {
        overlays.removeAll { $0.id == id }
        touch()
    }

    /// Adjusts render size to a new aspect preset while keeping the pixel budget.
    public mutating func setAspect(_ preset: AspectPreset, sourceSize: PSSize? = nil) {
        aspect = preset
        let base = sourceSize ?? clips.first?.asset.pixelSize ?? renderSize
        guard let ratio = preset.value else {
            renderSize = base
            touch()
            return
        }
        let area = max(base.area, 1280 * 720)
        let height = (area / ratio).squareRoot()
        let width = height * ratio
        renderSize = PSSize(width: (width / 2).rounded() * 2, height: (height / 2).rounded() * 2)
        touch()
    }

    /// Overlays visible at a timeline time.
    public func overlays(at time: Double) -> [TimelineOverlay] {
        overlays.filter { $0.span.contains(time) }
    }
}
