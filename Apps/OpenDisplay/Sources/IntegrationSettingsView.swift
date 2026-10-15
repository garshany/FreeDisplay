#if os(macOS)
import AutomationSchema
import DisplayDomain
import SwiftUI
import TopologyCore

struct IntegrationSettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View { IntegrationEditor(session: model.integrationSession) }
}

private struct IntegrationEditor: View {
    @ObservedObject var session: IntegrationSession
    @State private var text = ""
    @State private var allowEnabled = false
    @State private var error: String?
    @State private var selected = ""
    @State private var hookPreview = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Actions & Hooks").font(.title2)
                Text("FreeDisplay actions are disabled until configured. Editing never runs an action. Shift safe startup suppresses actions, hooks and polling.")
                Text("Integration controls are separate from native brightness and audio controller ownership.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Process actions use an absolute executable and a JSON argument array. Metadata stays in individual arguments; no inline shell code. HTTP/URL placeholders are percent encoded. Notification names are literal.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Picker("Display", selection: $selected) {
                        Text("Choose a display").tag("")
                        ForEach(session.displaySet.candidates) { display in
                            Text(verbatim: "\(display.name) — \(display.id.rawValue)").tag(display.id.rawValue)
                        }
                    }
                    Button("Add paused configuration") { addPaused() }.disabled(selected.isEmpty)
                }
                Text("Configuration JSON (preview)").font(.headline)
                TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minHeight: 220)
                Toggle("I reviewed the targets and allow enabled actions in this configuration", isOn: $allowEnabled)
                HStack {
                    Button("Review & save") { save() }
                    Button("Reload saved configuration") { reload() }
                    Button("Preview hook requests") { previewHooks() }
                    Button("Cancel running actions") { session.stopWork() }
                }
                Text("Timeout, output byte budget, polling interval, freshness and delayed wake are supplied in the configuration. Polling is off without an interval, parser and explicit failure policy. Removing a readback parser stops polling and retains its action text. Imported settings pause every controller, control and hook.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Cancellation requests termination of the direct process or transport. Child processes or external effects may remain; cancellation and timeout never mean rollback. An opened URL or sent notification confirms dispatch only.")
                    .font(.caption).foregroundStyle(.secondary)
                if !hookPreview.isEmpty { Text(verbatim: hookPreview).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                if let error = error ?? session.failure { Text(error.appLocalized).foregroundStyle(.red).textSelection(.enabled) }
                ForEach(session.configuration.displays) { display in
                    VStack(alignment: .leading) {
                        Text(verbatim: display.id.rawValue).font(.headline)
                        ForEach(display.controls) { control in
                            IntegrationControlRow(session: session, display: display, control: control)
                        }
                        ForEach(display.hooks) { hook in
                            HStack {
                                Text(hook.phase.integrationTitle)
                                Text(hook.enabled && display.enabled ? "Enabled" : "Paused")
                            }.font(.caption)
                        }
                    }
                }
                Text("Hard disconnect means observed disappearance, not proof of cable removal. Reconnect waits for identity and app configuration, not proof that hardware or a network peer is ready. Hooks dispatch independently; completion order is not guaranteed.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Integration diagnostics (machine format)").font(.headline)
                ForEach(Array(session.activity.enumerated()), id: \.offset) { _, entry in
                    Text(verbatim: entry).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }.padding()
        }
        .navigationTitle("Actions & Hooks")
        .onAppear { reload() }
    }
    private func reload() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        text = (try? encoder.encode(session.configuration)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        allowEnabled = false; error = nil
    }
    private func addPaused() {
        let id = DisplayRecordID(rawValue: selected)
        guard !session.configuration.displays.contains(where: { $0.id == id }) else { return }
        var copy = session.configuration
        copy.displays.append(.init(id: id, controls: [
            .init(name: "Brightness", kind: .ranged(multiplier: 100, decimalPlaces: 0)),
            .init(name: "Mute", kind: .boolean), .init(name: "Command", kind: .command)
        ], hooks: IntegrationHookPhase.allCases.map { .init(phase: $0) }))
        do { try session.save(copy); reload() } catch { self.error = (error as? IntegrationError)?.message ?? error.localizedDescription }
    }
    private func previewHooks() {
        do {
            let copy = try JSONDecoder().decode(IntegrationConfiguration.self, from: Data(text.utf8))
            try copy.validate(in: session.displaySet)
            var previews: [String] = []
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            for display in copy.displays {
                let candidate = try AutomationSelectorResolver.resolveOne(.display(.id(display.id)), in: session.displaySet)
                for hook in display.hooks {
                    let prepared = try IntegrationActionPolicy.prepare(hook.action, context: .init(display: candidate, hook: hook.phase.rawValue, parameters: display.parameters))
                    previews.append("target=\(prepared.target.rawValue) phase=\(hook.phase.rawValue)\n" + String(decoding: try encoder.encode(prepared.action), as: UTF8.self))
                }
            }
            hookPreview = previews.joined(separator: "\n")
        } catch { self.error = (error as? IntegrationError)?.message ?? error.localizedDescription }
    }
    private func save() {
        do {
            var copy = try JSONDecoder().decode(IntegrationConfiguration.self, from: Data(text.utf8))
            if !allowEnabled { copy = copy.pausedForImport() }
            try session.save(copy); reload()
        } catch { self.error = (error as? IntegrationError)?.message ?? error.localizedDescription }
    }
}

private struct IntegrationControlRow: View {
    @ObservedObject var session: IntegrationSession
    let display: DisplayIntegration
    let control: IntegrationControl
    @State private var level = 0.0
    @State private var command = ""
    @State private var feed = ""
    @State private var preview = ""
    private var key: String { IntegrationControlRuntime.key(display: display.id, control: control.id) }
    var body: some View {
        VStack(alignment: .leading) {
            Text(control.name.appLocalized).font(.headline)
            Group {
                switch control.kind {
                case .ranged:
                    Slider(value: $level, in: 0...1) { Text("Requested level") }
                    Button("Send level") { run(.level(AutomationLevel(normalized: level)!)) }
                case .boolean:
                    HStack {
                        Button("Send ON") { run(.boolean(true)) }
                        Button("Send OFF") { run(.boolean(false)) }
                    }
                case .command:
                    TextField("Command parameter", text: $command)
                    Button("Run configured action") { run(.command(command)) }
                }
            }.disabled(!display.enabled || !control.enabled || session.safeStartup)
            Button("Preview expanded request") { makePreview() }
            if case .boolean = control.kind { Button("Preview OFF request") { makePreview(off: true) } }
            if !preview.isEmpty { Text(verbatim: preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            if control.readback != nil {
                Button("Read now") { Task { await session.pull(control, on: display) } }
                    .disabled(!display.enabled || !control.enabled || session.safeStartup)
                HStack {
                    TextField("Feed response (no setter)", text: $feed)
                    Button("Feed") { Task { await session.feed(feed, control: control, display: display) } }
                }
            }
            if let sample = session.runtime.samples[key] {
                HStack {
                    Text(sample.source == .feed ? "Fed value" : "Parsed readback")
                    switch sample.value {
                    case .level(let level): Text("\(level.wholePercent)%")
                    case .boolean(let value): Text(value ? "On" : "Off")
                    case .command(let text): Text(verbatim: text)
                    }
                    Text(sample.at, style: .time)
                    // Evaluated when rendered; no independent freshness timer or invented cadence.
                    Text(sample.isFresh(at: Date(), for: control.freshnessSeconds) ? "Fresh at render" : "Stale or freshness unconfigured")
                }.font(.caption)
            }
            if session.runtime.stoppedPolls.contains(key) {
                Text("Polling stopped after failure. Review the action and save to restart.").font(.caption).foregroundStyle(.red)
            }
            if let failure = session.runtime.failures[key] { Text(failure.appLocalized).foregroundStyle(.red) }
            if let receipt = session.runtime.receipts[key] {
                Text(verbatim: receipt.outcome.rawValue).font(.system(.caption, design: .monospaced))
            }
        }
        .onChange(of: session.runtime.samples[key]) { _, sample in
            if case .level(let value) = sample?.value { level = value.normalized }
        }
    }
    private func makePreview(off: Bool = false) {
        do {
            let candidate = try AutomationSelectorResolver.resolveOne(.display(.id(display.id)), in: session.displaySet)
            let value: IntegrationValue
            switch control.kind {
            case .ranged: value = .level(AutomationLevel(normalized: level)!)
            case .boolean: value = .boolean(!off)
            case .command: value = .command(command)
            }
            let action = try IntegrationActionPolicy.prepare(off ? control.offAction : control.action, context: .init(display: candidate,
                value: try control.kind.text(for: value), parameters: display.parameters, input: value))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            preview = String(decoding: try encoder.encode(action.action), as: UTF8.self)
        } catch { preview = (error as? IntegrationError)?.message.appLocalized ?? error.localizedDescription }
    }
    private func run(_ value: IntegrationValue) { Task { await session.invoke(control, on: display, value: value) } }
}
private extension IntegrationHookPhase {
    var integrationTitle: String {
        switch self {
        case .softDisconnect: return String(localized: "After disconnect attempt")
        case .softReconnect: return String(localized: "Before reconnect attempt")
        case .hardDisconnect: return String(localized: "Observed display loss")
        case .hardReconnect: return String(localized: "Remembered display return")
        case .systemSleep: return String(localized: "System sleep")
        case .systemWakeImmediate: return String(localized: "Immediate system wake")
        case .systemWake: return String(localized: "Configured delayed wake")
        }
    }
}
#endif
