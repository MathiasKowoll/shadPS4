import AppKit
import SwiftUI

final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            LauncherModel.shared.terminationReply()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated {
            !LauncherModel.shared.isRunning
        }
    }
}

@main
struct FC26PortApp: App {
    @NSApplicationDelegateAdaptor(LauncherAppDelegate.self) private var delegate

    var body: some Scene {
        Window("EA SPORTS FC 26 Port", id: "launcher") {
            LauncherView(model: .shared)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {}
        }
    }
}
