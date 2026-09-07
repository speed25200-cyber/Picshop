import SwiftUI
import PicshopCore
import PicshopIntent
import PicshopUI

@main
struct PicshopApp: App {
    @State private var environment: AppEnvironment

    init() {
        var engines: [any IntentEngine] = []
        #if canImport(MLXLLM)
        engines.append(MLXIntentEngine.shared)
        #endif
        let environment = AppEnvironment(extraEngines: engines)
        _environment = State(initialValue: environment)
        #if canImport(MLXLLM)
        ProBrainInstaller.shared = ProBrainInstaller { model, app in
            await MLXIntentEngine.shared.install(model, models: app.models)
            await app.refreshEngines()
        }
        #endif
        PSLog.info("Picshop launched", category: .ui)
    }

    var body: some Scene {
        WindowGroup {
            RootView(environment: environment)
        }
    }
}
