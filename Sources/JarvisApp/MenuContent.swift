import AppKit
import JarvisCore
import SwiftUI

/// The menu, top to bottom as the spec orders it. Quit is always there, even before `Jarvis` exists.
struct MenuContent: View {
    @ObservedObject var app: AppDelegate

    var body: some View {
        if let jarvis = app.jarvis {
            JarvisMenu(jarvis: jarvis, session: jarvis.session)
        } else {
            Text(app.launchError ?? "Starting…")
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

private struct JarvisMenu: View {
    @ObservedObject var jarvis: Jarvis
    @ObservedObject var session: ListeningSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if jarvis.notesAvailable {
            Text(session.statusLine)
        } else {
            Button("Notes off — install Claude Code or Ollama") { NSWorkspace.shared.open(Links.installGuide) }
        }
        Divider()
        Button(session.topMenuItem, action: topMenuItemChosen)
        if !isStopped {
            Button("Stop") { session.stop(.user) }
        }
        Divider()
        Toggle("Meeting mode", isOn: $session.modes.meetingMode)
        Toggle("Demo mode", isOn: $session.modes.demoMode)
        Divider()
        Button("Ask my memory…") { show(WindowID.ask) }
        Button("Settings…") { show(WindowID.settings) }
        Divider()
        Button("Forget last hour") { Task { confirmForgetLastHour() } }
        Button("Open notes") { NSWorkspace.shared.open(jarvis.openNotesURL) }
        if jarvis.voiceMemosNeedFullDiskAccess {
            Divider()
            Text("Allow Full Disk Access to import Voice Memos")
            Button("Open Full Disk Access Settings…") { NSWorkspace.shared.open(Links.fullDiskAccess) }
        }
    }

    private var isStopped: Bool {
        if case .stopped = session.state { return true }
        return false
    }

    /// "Pause listening" / "Resume" / "Start listening", as `topMenuItem` names them.
    private func topMenuItemChosen() {
        switch session.state {
        case .listening: session.pause(.user)
        case .paused: session.resume()
        case .stopped: session.start()
        }
    }

    /// A menu-bar app is never frontmost on its own, so the window would open behind everything.
    private func show(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }

    /// Run after the menu has closed (hence the `Task`), so the alert is not caught in menu tracking.
    private func confirmForgetLastHour() {
        let alert = NSAlert()
        alert.messageText = "Delete the last hour?"
        alert.informativeText = (try? jarvis.forgetLastHourDescription()) ?? ""
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try jarvis.forgetLastHour()
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

private enum Links {
    /// The install section of the guide published from `docs/guide.html`.
    static let installGuide = URL(string: "https://yashmangal19.github.io/jarvis/guide.html#install")!
    static let fullDiskAccess =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
