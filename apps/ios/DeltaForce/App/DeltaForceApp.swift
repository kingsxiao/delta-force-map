// DeltaForceApp.swift — 入口
import SwiftUI

@main
struct DeltaForceApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onAppear { app.start() }
                .onChange(of: scenePhase) { _, phase in app.handleScenePhase(phase) }
        }
    }
}
