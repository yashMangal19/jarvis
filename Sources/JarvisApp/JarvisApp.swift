import AppKit
import JarvisCore
import SwiftUI

/// The menu-bar app. It binds to `Jarvis` and renders; every rule lives in JarvisCore.
@main
struct JarvisApp: App {
    @NSApplicationDelegateAdaptor private var app: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(app: app)
        } label: {
            MenuBarLabel(app: app)
        }
        .menuBarExtraStyle(.menu)

        Window("Settings", id: WindowID.settings) {
            OnceStarted(app: app) { SettingsView(jarvis: $0) }
        }
        Window("Ask my memory", id: WindowID.ask) {
            OnceStarted(app: app) { AskMemoryView(jarvis: $0) }
        }
    }
}

enum WindowID {
    static let settings = "settings"
    static let ask = "ask"
}

/// Owns `Jarvis` for the life of the process: builds and starts it after the launch permissions, and
/// holds Quit until `shutdown()` has stopped the whisper servers (DEC-6, DEC-10).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var jarvis: Jarvis?
    @Published private(set) var launchError: String?
    private var launch: Task<Jarvis?, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // No Dock icon when run as a bare binary; the bundle says the same with LSUIElement.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launch = Task {
            await Permissions.requestAtLaunch()
            do {
                let jarvis = try await Jarvis.live()
                Triggers.install(into: jarvis)
                self.jarvis = jarvis
                return jarvis
            } catch {
                launchError = "Jarvis couldn't start: \(error.localizedDescription)"
                return nil
            }
        }
        Task { await launch?.value?.start() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let launch else { return .terminateNow }
        Task {
            await launch.value?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// A window's content once `Jarvis` exists; a window restored at launch waits for it.
private struct OnceStarted<Content: View>: View {
    @ObservedObject var app: AppDelegate
    let content: (Jarvis) -> Content

    var body: some View {
        if let jarvis = app.jarvis {
            content(jarvis)
        } else {
            Text(app.launchError ?? "Starting…").padding()
        }
    }
}
