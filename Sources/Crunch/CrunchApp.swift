import SwiftUI

@main
struct CrunchApp: App {
    var body: some Scene {
        WindowGroup("Crunch") {
            ContentView()
                // Hide the title and extend content under the unified
                // titlebar so the app reads as a single focused surface.
                .toolbarBackground(.hidden, for: .windowToolbar)
                .containerBackground(.thickMaterial, for: .window)
        }
        .defaultSize(width: 620, height: 720)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {} // no "New Window"
        }
    }
}
