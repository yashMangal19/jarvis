import JarvisCore
import SwiftUI

/// The Settings window: the Engines line, the allowed-tools checklist and quiet hours. Every value comes from
/// JarvisCore. Each change reads `settings.json` whole and writes it back whole, so keys this window does not
/// show (DEC-28's `screenRecordingAsked`) survive.
struct SettingsView: View {
    @ObservedObject var jarvis: Jarvis
    @State private var settings = JarvisCore.Settings.default
    @State private var tools = ToolList.loading
    @State private var saveError: String?
    private let store = SettingsStore(paths: .standard)

    /// What the pickers show when quiet hours are first switched on.
    private static let suggestedQuietHours = QuietHours(startMinutes: 22 * 60, endMinutes: 7 * 60)

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
        case .loaded(let list):
            Text("Spoken commands can use only the tools ticked here.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(list, id: \.id) { tool in
                Toggle(isOn: isAllowed(tool.id)) {
                    Text(tool.title)
                    if tool.isShell {
                        Text("Off by default — when ticked, Jarvis can run commands on this Mac.")
                    } else if tool.isFileEdit {
                        Text("Off by default — when ticked, Jarvis can change files.")
                    }
                }
            }
        }
    }

    @ViewBuilder private var quietHours: some View {
        Toggle("Stop listening during quiet hours", isOn: Binding(
            get: { settings.quietHours != nil },
            set: { on in update { $0.quietHours = on ? Self.suggestedQuietHours : nil } }))
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
