import SwiftUI
import AppKit

@main
struct FaceCoverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = CameraEngine()
    @StateObject private var library = RecordingLibrary()

    var body: some Scene {
        Window("脸罩 FaceCover", id: "main") {
            ContentView(engine: engine, library: library)
                .onAppear { appDelegate.engine = engine }
        }
        .defaultSize(width: 1080, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Window("录像库", id: "library") {
            LibraryView(library: library)
        }
        .defaultSize(width: 760, height: 560)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var engine: CameraEngine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.shutdown()
    }
}
