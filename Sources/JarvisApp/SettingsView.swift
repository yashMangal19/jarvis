import JarvisCore
import SwiftUI

/// The Settings window: the Engines line, the allowed-tools checklist, quiet hours and the AirPods stem squeeze.
/// Every value comes from JarvisCore. Each change reads `settings.json` whole and writes it back whole, so keys
/// this window does not show (DEC-28's `screenRecordingAsked`) survive.
struct SettingsView: View {
    @ObservedObject var jarvis: Jarvis
    @State private var settings = JarvisCore.Settings.default
    @State private var tools = ToolList.loading
    @State private var saveError: String?
    private let store = SettingsStore(paths: .standard)

    var body: some View {
        Form {
            Section("Engines") {
                Text(jarvis.engines.description.line)
                    .textSelection(.enabled)
            }
            Section("Allowed tools") {
                allowedTools
            }
            Section("Quiet hours") {
                quietHours
            }
            Section("AirPods") {
                Toggle("AirPods stem squeeze (experimental)", isOn: Binding(
                    get: { jarvis.stemTriggerChosen },
                    set: { on in
                        do { try jarvis.setStemTrigger(on); saveError = nil } catch {
                            saveError = "Couldn't save settings: \(error.localizedDescription)"
                        }
                    }))
                Text("Squeeze a stem to start a command, and again to send it. While Jarvis is listening or paused, "
                     + "it plays silence to stay Now Playing: the Mac may not idle-sleep, the AirPods stay with this "
                     + "Mac, and Music loses Now Playing. Taking an AirPod out, a Bluetooth drop and the keyboard "
                     + "play/pause key can also start a command.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let saveError {
                Text(saveError).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 420)
        .onAppear { settings = store.load() }
        .task { await loadTools() }
    }

    @ViewBuilder private var allowedTools: some View {
        switch tools {
        case .loading:
            ProgressView().controlSize(.small)
        case .noClaude:
            Text("Install Claude Code to run commands")
            toolRows([])
        case .loaded(let list):
            Text("Spoken commands can use only the tools ticked here.")
                .font(.caption).foregroundStyle(.secondary)
            toolRows(list)
        }
    }

    /// The listed tools, then any ticked tool Claude Code no longer lists, so it can be unticked (DEC-9).
    private func toolRows(_ available: [ToolDescriptor]) -> some View {
        ForEach(ToolDescriptor.checklist(available: available, allowed: settings.allowedTools), id: \.id) { tool in
            Toggle(isOn: isAllowed(tool.id)) {
                Text(tool.title)
                if tool.isUnlisted {
                    Text("Not listed by Claude Code now, but still allowed. Untick to remove it.")
                } else if tool.isShell {
                    Text("Off by default — when ticked, Jarvis can run commands on this Mac.")
                } else if tool.isFileEdit {
                    Text("Off by default — when ticked, Jarvis can change files.")
                }
            }
        }
    }

    @ViewBuilder private var quietHours: some View {
        Toggle("Stop listening during quiet hours", isOn: Binding(
            get: { settings.quietHours != nil },
            set: { on in update { $0.quietHours = on ? .suggested : nil } }))
        if let window = settings.quietHours {
            DatePicker("From", selection: time(\.startMinutes), displayedComponents: .hourAndMinute)
            DatePicker("Until", selection: time(\.endMinutes), displayedComponents: .hourAndMinute)
            Text(window.startMinutes == window.endMinutes
                 ? "From and Until are the same time, so quiet hours never apply."
                 : "Everything stops, wake word included, and starts again when quiet hours end. "
                   + "Choosing Start listening from the menu keeps Jarvis on until they end.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func loadTools() async {
        guard let claude = ClaudeCLI.locate() else {
            tools = .noClaude
            return
        }
        tools = .loaded(await ClaudeCLI(executable: claude).availableTools())
    }

    private func isAllowed(_ id: String) -> Binding<Bool> {
        Binding(get: { settings.allowedTools.contains(id) },
                set: { on in
                    update { s in
                        s.allowedTools.removeAll { $0 == id }
                        if on { s.allowedTools.append(id) }
                    }
                })
    }

    /// A time of day bound to minutes from midnight in the quiet-hours window.
    private func time(_ key: WritableKeyPath<QuietHours, Int>) -> Binding<Date> {
        Binding(get: {
                    let minutes = settings.quietHours?[keyPath: key] ?? 0
                    return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0,
                                                 of: Date()) ?? Date()
                },
                set: { date in
                    let time = Calendar.current.dateComponents([.hour, .minute], from: date)
                    update { $0.quietHours?[keyPath: key] = (time.hour ?? 0) * 60 + (time.minute ?? 0) }
                })
    }

    /// Load, change, save the whole struct (DEC-28).
    private func update(_ change: (inout JarvisCore.Settings) -> Void) {
        var fresh = store.load()
        change(&fresh)
        do {
            try store.save(fresh)
            settings = fresh
            saveError = nil
        } catch {
            saveError = "Couldn't save settings: \(error.localizedDescription)"
        }
    }
}

private enum ToolList {
    case loading
    case noClaude
    case loaded([ToolDescriptor])
}
