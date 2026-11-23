import SwiftUI

@main
struct ABetterVoiceApp: App {
    @StateObject private var model = EnhancerModel()

    init() {
        Workspace.cleanUp()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                // "Open with A Better Voice" from Files, Finder or the share sheet.
                .onOpenURL { url in model.open(url) }
                #if os(macOS)
                .frame(minWidth: 560, minHeight: 520)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 760, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        #endif
    }
}
