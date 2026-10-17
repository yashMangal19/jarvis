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
        if jarvis.microphoneAccessOff {
            Text("Microphone access is off")
            Button("Open Microphone Settings…") { NSWorkspace.shared.open(Links.microphone) }
        }
        Divider()
        Button(session.topMenuItem) { jarvis.chooseTopMenuItem() }
        if !session.isStopped {
            Button("Stop") { session.stop(.user) }
        }
        Divider()
        Toggle("Meeting mode", isOn: $session.modes.meetingMode)
        Toggle("Demo mode", isOn: $session.modes.demoMode)
        Divider()
        Button("Ask my memory…") { show(WindowID.ask) }
        Button("Settings…") { show(WindowID.settings) }
        Divider()
        Button("Forget last hour") {
            RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated { confirmForgetLastHour() } }
        }
        Button("Open notes") { NSWorkspace.shared.open(jarvis.openNotesURL) }
        if jarvis.callAudioNeedsScreenRecording {
            Divider()
            Button("Call audio off — Allow Screen Recording…") { NSWorkspace.shared.open(Links.screenRecording) }
        }
        if jarvis.voiceMemosNeedFullDiskAccess {
            Divider()
            Text("Allow Full Disk Access to import Voice Memos")
            Button("Open Full Disk Access Settings…") { NSWorkspace.shared.open(Links.fullDiskAccess) }
        }
    }

    /// A menu-bar app is never frontmost on its own, so the window would open behind everything.
    private func show(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }

    /// Run through `RunLoop.main.perform(inModes: [.default])`: the menu tracks in the event-tracking
    /// mode, so the block waits until the menu has closed and the alert is not caught in its tracking.
    /// The question fixes the hour, so Delete removes the hour it names however long the alert is open.
    private func confirmForgetLastHour() {
        let question: ForgetLastHourQuestion
        do { question = try jarvis.askToForgetLastHour() } catch {
            NSAlert(error: error).runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete the last hour?"
        alert.informativeText = question.text
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try jarvis.forgetLastHour(question)
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
    static let screenRecording =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let microphone =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
}
