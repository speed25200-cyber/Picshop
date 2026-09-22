#if canImport(SwiftUI) && canImport(PhotosUI) && canImport(UIKit)
import SwiftUI
import PhotosUI
import AVFoundation
import CoreImage
import ImageIO
import PicshopCore
import PicshopImaging
import PicshopVideo

/// Shape of the finished movie.
public enum MagicMovieFormat: String, CaseIterable, Identifiable, Sendable {
    case vertical, square, landscape

    public var id: String { rawValue }

    var aspect: AspectPreset {
        switch self {
        case .vertical: return .ratio9x16
        case .square: return .square
        case .landscape: return .ratio16x9
        }
    }

    var title: String {
        switch self {
        case .vertical: return L("Vertical")
        case .square: return L("Square")
        case .landscape: return L("Landscape")
        }
    }

    var symbol: String {
        switch self {
        case .vertical: return "rectangle.portrait"
        case .square: return "square"
        case .landscape: return "rectangle"
        }
    }
}

extension ProjectLibrary {
    /// Builds a finished edit from picked clips and photos and an optional
    /// song: every item is copied into one project (photos become short
    /// clips that get a Ken Burns move), the song's beats are found, and
    /// MagicMovie cuts the shots on them.
    public func createMagicMovie(items: [PhotosPickerItem], music: URL?, pace: MagicMovie.Pace, format: MagicMovieFormat,
                                 progress: @escaping @MainActor (Double, String) -> Void) async -> Project? {
        isImporting = true
        defer { isImporting = false }
        do {
            let id = UUID()
            try store.createPackage(for: id)
            var sources: [MagicMovie.Source] = []
            for (index, item) in items.enumerated() {
                progress(Double(index) / Double(max(1, items.count)) * 0.7, L("Gathering your moments…"))
                let source = try await importSource(item, index: index, projectID: id)
                if let source { sources.append(source) }
            }
            guard !sources.isEmpty else { throw PicshopError.mediaUnavailable(L("clips")) }

            var musicAsset: MediaAsset?
            var beats: BeatGrid?
            if let music {
                progress(0.75, L("Listening to the music…"))
                let accessed = music.startAccessingSecurityScopedResource()
                defer { if accessed { music.stopAccessingSecurityScopedResource() } }
                let relative = "\(Project.mediaDirectory)/music.\(music.pathExtension.isEmpty ? "m4a" : music.pathExtension)"
                let destination = store.url(for: relative, in: id)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: music, to: destination)
                let asset = AVURLAsset(url: destination)
                let duration = try await asset.load(.duration).seconds
                musicAsset = MediaAsset(kind: .audio, relativePath: relative, pixelSize: .zero, duration: duration, origin: .file)
                let signal = try await AudioDecoder.decode(asset: asset, range: TimeSpan(start: 0, duration: min(duration, 600)), sampleRate: 22_050)
                beats = await Task.detached(priority: .userInitiated) { BeatTracker().analyze(signal) }.value
            }

            progress(0.9, L("Cutting on the beat…"))
            let natural = sources.reduce(0.0) { $0 + min($1.duration, $1.isStill ? 3.5 : 6) }
            let target = min(musicAsset?.duration ?? natural, max(6, natural), 90)
            let plan = MagicMovie.plan(sources: sources, beats: beats, targetDuration: target, pace: pace)
            let title = String(format: L("Magic Movie · %@"), Date.now.formatted(date: .abbreviated, time: .omitted))
            let base = sources.first { !$0.isStill }?.asset.pixelSize ?? PSSize(width: 1920, height: 1080)
            var timeline = MagicMovie.timeline(title: title, sources: sources, plan: plan, music: musicAsset, renderSize: base, frameRate: 30)
            timeline.id = id
            timeline.setAspect(format.aspect, sourceSize: base)
            timeline.beatGrid = beats
            let project = Project(id: id, content: .video(timeline))
            try store.save(project)
            if let poster = await VideoThumbnailer(store: store, projectID: id).poster(for: timeline) {
                ThumbnailGenerator.writeThumbnail(image: poster, projectID: id, store: store)
            }
            progress(1, L("Ready"))
            refresh()
            return project
        } catch {
            errorMessage = (error as? PicshopError)?.message ?? error.localizedDescription
            return nil
        }
    }

    private func importSource(_ item: PhotosPickerItem, index: Int, projectID: UUID) async throws -> MagicMovie.Source? {
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
        if isVideo {
            guard let file = try await item.loadTransferable(type: ImportedMovie.self) else { return nil }
            let relative = "\(Project.mediaDirectory)/clip-\(index).\(file.url.pathExtension.isEmpty ? "mov" : file.url.pathExtension)"
            let destination = store.url(for: relative, in: projectID)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: file.url, to: destination)
            let metadata = try await VideoThumbnailer.metadata(for: destination)
            let asset = MediaAsset(kind: .video, relativePath: relative, pixelSize: metadata.size, duration: metadata.duration, origin: .photoLibrary(localIdentifier: ""), frameRate: metadata.frameRate)
            return MagicMovie.Source(asset: asset, duration: metadata.duration)
        }
        guard let data = try await item.loadTransferable(type: Data.self) else { return nil }
        // A photo becomes a five-second clip at up to 1920 px; the Ken Burns move is added by the plan.
        let still = await Task.detached(priority: .userInitiated) { () -> CIImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                                      kCGImageSourceThumbnailMaxPixelSize: 1920] as CFDictionary) else { return nil }
            return CIImage(cgImage: cg)
        }.value
        guard let still else { return nil }
        let url = store.mediaURL(for: projectID).appendingPathComponent("still-\(index).mov")
        var asset = try await VideoTranscoder.writeStill(still, duration: 5, frameRate: 30, to: url)
        asset.relativePath = "\(Project.mediaDirectory)/\(url.lastPathComponent)"
        return MagicMovie.Source(asset: asset, duration: 5, isStill: true)
    }
}

/// The Magic Movie sheet: pick moments, optionally a song, a pace and a
/// shape — PicShop does the edit.
struct MagicMovieSheet: View {
    var onCreated: (Project) -> Void
    @Environment(\.picshop) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var items: [PhotosPickerItem] = []
    @State private var music: URL?
    @State private var showsMusicPicker = false
    @State private var pace: MagicMovie.Pace = .balanced
    @State private var format: MagicMovieFormat = .vertical
    @State private var working: (progress: Double, title: String)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PSSpacing.xLarge) {
                    hero
                    step(number: 1, title: L("Moments")) {
                        PhotosPicker(selection: $items, maxSelectionCount: 30, selectionBehavior: .ordered, matching: .any(of: [.videos, .images])) {
                            HStack(spacing: 12) {
                                Image(systemName: items.isEmpty ? "plus.viewfinder" : "checkmark.circle.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(items.isEmpty ? PSTheme.textPrimary : PSTheme.success)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(items.isEmpty ? L("Choose clips and photos") : String(format: L("%d moments chosen"), items.count))
                                        .font(PSFont.headline(15)).foregroundStyle(PSTheme.textPrimary)
                                    Text(L("In the order you like. Up to 30.")).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(PSTheme.textTertiary)
                            }
                            .padding(16)
                            .psCard(cornerRadius: 22, shadow: false)
                        }
                    }
                    step(number: 2, title: L("Music")) {
                        Button { showsMusicPicker = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: music == nil ? "music.note" : "music.note.list")
                                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(PSTheme.textPrimary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(music?.deletingPathExtension().lastPathComponent ?? L("Add a song (optional)"))
                                        .font(PSFont.headline(15)).foregroundStyle(PSTheme.textPrimary).lineLimit(1)
                                    Text(L("Cuts land on its beat.")).font(PSFont.caption(12)).foregroundStyle(PSTheme.textSecondary)
                                }
                                Spacer()
                                if music != nil {
                                    Button { music = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(PSTheme.textTertiary) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .padding(16)
                            .psCard(cornerRadius: 22, shadow: false)
                        }
                        .buttonStyle(PSPressStyle(scale: 0.98))
                    }
                    step(number: 3, title: L("Pace")) {
                        choiceRow(MagicMovie.Pace.allCases, selection: $pace, title: { paceTitle($0) }, symbol: { paceSymbol($0) })
                    }
                    step(number: 4, title: L("Format")) {
                        choiceRow(MagicMovieFormat.allCases, selection: $format, title: { $0.title }, symbol: { $0.symbol })
                    }
                }
                .padding(.horizontal, PSSpacing.page)
                .padding(.bottom, 110)
            }
            .scrollIndicators(.hidden)
            .background(PSTheme.ink.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { footer }
            .navigationTitle(L("Magic Movie"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() }.disabled(working != nil) } }
            .fileImporter(isPresented: $showsMusicPicker, allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff]) { result in
                if case .success(let url) = result { music = url }
            }
            .interactiveDismissDisabled(working != nil)
        }
        .overlay { IntelligenceGlow(isActive: working != nil, level: 0.3) }
        .preferredColorScheme(.dark)
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            IntelligenceField(animated: true)
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "film.stack.fill").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                Text(L("An edit on the beat, made for you.")).font(PSFont.title(22)).foregroundStyle(.white).tracking(-0.4)
                Text(L("PicShop picks the best part of each clip and cuts to the music.")).font(PSFont.caption(13)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(18)
        }
        .padding(.top, 8)
    }

    private func step<Content: View>(number: Int, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(number)").font(PSFont.label(11)).foregroundStyle(.black).frame(width: 18, height: 18).background(Circle().fill(Color.white))
                Text(title.uppercased()).font(PSFont.label(12)).tracking(0.8).foregroundStyle(PSTheme.textSecondary)
            }
            content()
        }
    }

    private func choiceRow<Item: Hashable & Identifiable>(_ items: [Item], selection: Binding<Item>, title: @escaping (Item) -> String, symbol: @escaping (Item) -> String) -> some View {
        HStack(spacing: 8) {
            ForEach(items) { item in
                let active = selection.wrappedValue == item
                Button {
                    Haptics.tick()
                    withAnimation(PSMotion.quick) { selection.wrappedValue = item }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: symbol(item)).font(.system(size: 18, weight: .semibold)).foregroundStyle(active ? PSTheme.accent : PSTheme.textPrimary)
                        Text(title(item)).font(PSFont.caption(12)).foregroundStyle(active ? PSTheme.textPrimary : PSTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color.white.opacity(active ? 0 : 0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .psActivePill(RoundedRectangle(cornerRadius: 18, style: .continuous), isActive: active)
                }
                .buttonStyle(PSPressStyle())
                .accessibilityAddTraits(active ? [.isSelected] : [])
            }
        }
    }

    private func paceTitle(_ pace: MagicMovie.Pace) -> String {
        switch pace {
        case .energetic: return L("Energetic")
        case .balanced: return L("Balanced")
        case .cinematic: return L("Cinematic")
        }
    }

    private func paceSymbol(_ pace: MagicMovie.Pace) -> String {
        switch pace {
        case .energetic: return "bolt.fill"
        case .balanced: return "metronome.fill"
        case .cinematic: return "film"
        }
    }

    @ViewBuilder private var footer: some View {
        Group {
            if let working {
                VStack(spacing: 10) {
                    ShimmerText(working.title, font: PSFont.headline(15))
                    ProgressView(value: working.progress).tint(PSTheme.voice)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .psCard(cornerRadius: 22, shadow: false)
            } else {
                Button {
                    Haptics.magic()
                    create()
                } label: {
                    Label(L("Create my movie"), systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(MagicButtonStyle())
                .disabled(items.isEmpty)
                .opacity(items.isEmpty ? 0.45 : 1)
            }
        }
        .padding(.horizontal, PSSpacing.page)
        .padding(.vertical, 10)
        .background(LinearGradient(colors: [PSTheme.ink.opacity(0), PSTheme.ink], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .animation(PSMotion.standard, value: working == nil)
    }

    private func create() {
        guard let app, !items.isEmpty else { return }
        working = (0, L("Gathering your moments…"))
        let chosen = items
        Task {
            let project = await app.library.createMagicMovie(items: chosen, music: music, pace: pace, format: format) { progress, title in
                working = (progress, title)
            }
            working = nil
            if let project {
                Haptics.success()
                dismiss()
                onCreated(project)
            } else {
                Haptics.error()
            }
        }
    }
}
#endif
