import SwiftUI
import PicshopCore
import PicshopIntent
import PicshopUI
#if DEBUG
import CoreImage
import CoreImage.CIFilterBuiltins
#endif

@main
struct PicshopApp: App {
    @State private var environment: AppEnvironment
    #if DEBUG
    /// `-PicshopScenario <name>` (W2): the editor opens on a procedural photo in that state, for CI's screenshots.
    private let scenario: String?
    #endif

    init() {
        let launch = PSSignpost.begin("app.init")
        defer { PSSignpost.end(launch) }
        // First, so a crash or memory kill in this session leaves a report for the next one.
        Diagnostics.shared.start()
        // The local brain's runtime (MLX), before AppEnvironment attaches to the hub.
        #if canImport(MLXVLM)
        LocalBrainHub.shared.runtime = MLXLocalRuntime.shared
        #endif
        let environment = AppEnvironment()
        _environment = State(initialValue: environment)
        #if canImport(StableDiffusion)
        environment.generativeEngineProvider = { url in StableDiffusionFillEngine(resourcesURL: url) }
        #endif
        #if DEBUG
        scenario = DebugScenario.name()
        if let scenario { PSLog.info("launch scenario \(scenario)", category: .ui) }
        #endif
        PSLog.info("Picshop launched", category: .ui)
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // The fixture photo is built off the main thread by the scenario host.
            RootView(environment: environment, scenarioName: scenario, scenarioPhoto: { DebugScenario.fixturePhoto() })
            #else
            RootView(environment: environment)
            #endif
        }
    }
}

#if DEBUG
/// DEBUG launch scenarios (W2, §9.8; W3, §9.12): `-PicshopScenario masks3` (or maskHandles, selectOutline, colorRange,
/// selectAndMask, graphiteOn; W3: layers10, groupsClip, freeTransform, layersInspector, layerMaskPaint, exportPro)
/// builds a procedural fixture photo with Core Image generators: a sky gradient, a ground band and a subject disc. No
/// bundled photo, so no licence question; parametric masks only, so the simulator needs no model. RootView's scenario
/// host builds it off the main thread, imports it, opens the photo editor and calls the session's
/// `applyDebugScenario(_:)` (which builds the W3 layer fixtures), then logs « scenario ready ». CI screenshots all
/// twelve, and reads the freeTransform drag's `layers.bodyCount` line.
enum DebugScenario {
    static let names: Set<String> = ["masks3", "maskHandles", "selectOutline", "colorRange", "selectAndMask", "graphiteOn",
                                     // W3: the layer fixtures are built by the session's applyDebugScenario (L3).
                                     "layers10", "groupsClip", "freeTransform", "layersInspector", "layerMaskPaint", "exportPro"]

    /// The scenario named after `-PicshopScenario`; nil without the argument or for an unknown name.
    static func name(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard let flag = arguments.firstIndex(of: "-PicshopScenario"), arguments.indices.contains(flag + 1) else { return nil }
        let name = arguments[flag + 1]
        guard names.contains(name) else {
            PSLog.error("unknown launch scenario \(name)", category: .ui)
            return nil
        }
        return name
    }

    /// A 2048 × 1536 PNG: a blue sky fading to a pale horizon over the top 60 %, a green-brown ground band below,
    /// and an orange subject disc standing on the horizon, left of centre (sky, subject, ground and colour masks
    /// all have something to find).
    static func fixturePhoto(width: Int = 2048, height: Int = 1536) -> Data? {
        let w = CGFloat(width), h = CGFloat(height)
        let extent = CGRect(x: 0, y: 0, width: w, height: h)
        // Core Image's origin is the bottom left.
        let horizon = h * 0.40
        let sky = CIFilter.linearGradient()
        sky.point0 = CGPoint(x: 0, y: h)
        sky.point1 = CGPoint(x: 0, y: horizon)
        sky.color0 = CIColor(red: 0.16, green: 0.38, blue: 0.78)
        sky.color1 = CIColor(red: 0.78, green: 0.86, blue: 0.94)
        let ground = CIFilter.linearGradient()
        ground.point0 = CGPoint(x: 0, y: horizon)
        ground.point1 = CGPoint(x: 0, y: 0)
        ground.color0 = CIColor(red: 0.30, green: 0.52, blue: 0.22)
        ground.color1 = CIColor(red: 0.36, green: 0.27, blue: 0.16)
        let disc = CIFilter.radialGradient()
        let radius = h * 0.17
        disc.center = CGPoint(x: w * 0.40, y: horizon + radius * 0.55)
        disc.radius0 = Float(radius)
        disc.radius1 = Float(radius + 2)
        disc.color0 = CIColor(red: 0.95, green: 0.45, blue: 0.12)
        disc.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let skyImage = sky.outputImage?.cropped(to: CGRect(x: 0, y: horizon, width: w, height: h - horizon)),
              let groundImage = ground.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: w, height: horizon)),
              let discImage = disc.outputImage?.cropped(to: extent) else { return nil }
        let picture = discImage.composited(over: skyImage.composited(over: groundImage)).cropped(to: extent)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        return context.pngRepresentation(of: picture, format: .RGBA8, colorSpace: space)
    }
}
#endif
