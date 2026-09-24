import SwiftUI
import PicshopCore
import PicshopIntent
import PicshopUI

@main
struct PicshopApp: App {
    @State private var environment: AppEnvironment

    init() {
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
        PSLog.info("Picshop launched", category: .ui)
    }

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
        }
    }
}
