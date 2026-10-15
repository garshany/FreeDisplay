#if os(macOS)
import AppKit
import AutomationSchema
import Combine
import OSLog
import SwiftUI

/// The system sink remains active independently of whether the user retains a viewer buffer.
@MainActor
final class AppDiagnostics: ObservableObject {
    static let shared = AppDiagnostics()
    private let logger = Logger(subsystem: DiagnosticRecord.subsystem, category: DiagnosticRecord.category)
    @Published private(set) var buffer: DiagnosticBuffer
    var retaining: Bool {
        didSet { UserDefaults.standard.set(retaining, forKey: "console.loggingEnabled") }
    }

    private init() {
        retaining = UserDefaults.standard.bool(forKey: "console.loggingEnabled")
        buffer = DiagnosticBuffer(capacity: try? ConsoleCapacity.parse(UserDefaults.standard.string(forKey: "console.logCapacity") ?? ""))
    }

    static var exportPrivacy: DiagnosticPrivacy {
        let defaults = UserDefaults.standard
        return DiagnosticPrivacy(
            removeSerials: defaults.object(forKey: "diagnostics.removeSerials") as? Bool ?? true,
            removeUUIDs: defaults.object(forKey: "diagnostics.removeUUIDs") as? Bool ?? true,
            removeRegistryPaths: defaults.object(forKey: "diagnostics.removeRegistryPaths") as? Bool ?? true)
    }

    func record(_ message: String) {
        let record = DiagnosticRecord(message)
        logger.info("\(record.message, privacy: .public)")
        if retaining { buffer.append(record) }
    }

    func setCapacity(_ capacity: Int?) { buffer.capacity = capacity }
    func clear() { buffer.clear() }
}

@MainActor
final class CommandConsoleWindow {
    private var window: NSWindow?
    private let state = ConsoleViewModel()

    func close() { window?.close() }

    func show(model: AppModel) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = String(localized: "FreeDisplay Console")
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("FreeDisplayCommandConsole")
            window.contentView = NSHostingView(rootView: CommandConsoleView(state: state, model: model))
            if !window.setFrameUsingName("FreeDisplayCommandConsole") { window.center() }
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class ConsoleViewModel: ObservableObject {
    @Published var session = ConsoleSession(
        historyCapacity: try? ConsoleCapacity.parse(UserDefaults.standard.string(forKey: "console.historyCapacity") ?? ""),
        outputCapacity: try? ConsoleCapacity.parse(UserDefaults.standard.string(forKey: "console.outputCapacity") ?? ""))
    @Published var running = false
    @Published var error: String?

    func submit(model: AppModel, close: () -> Void) async {
        guard !running else { return }
        let line = session.submit()
        do {
            switch try ConsoleGrammar.parse(line) {
            case .empty: return
            case .clear: session.clear(); AppDiagnostics.shared.clear(); return
            case .exit: close(); return
            case .help(let name):
                session.append("> \(line)")
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                session.append(String(localized: "FreeDisplay version \(version)"))
                session.append(String(localized: "Use command name=value or command --name value. Quotes preserve spaces; backslash escapes the next character. Common parameter: --dry-run. Use capabilities display=<selector> for this build and display. clear and exit affect only this console."))
                let descriptors: [AutomationCommandDescriptor]
                if let name {
                    // Use the shared alias matcher via discovery, without resolving a target or executing.
                    descriptors = AutomationCatalog.descriptors(for: .console).filter {
                        AutomationCatalog.normalize($0.name.rawValue) == AutomationCatalog.normalize(name)
                        || $0.aliases.contains(AutomationCatalog.normalize(name))
                    }
                } else { descriptors = AutomationCatalog.descriptors(for: .console) }
                if descriptors.isEmpty { session.append(String(localized: "No console command matches this help topic.")) }
                for descriptor in descriptors {
                    let parameters = descriptor.parameters.map { "\($0.name)=<\($0.kind.rawValue)>" }.joined(separator: " ")
                    session.append("\(descriptor.name.rawValue) \(parameters)\n\(descriptor.summary.appLocalized)")
                }
            case .command(let request):
                session.append("> \(line)")
                running = true
                defer { running = false }
                let result = await AppAutomation.run(request, from: .console, model: model)
                if let issue = result.issue {
                    session.append(String(localized: DisplayIntentError.commandFailed(issue.code).localizedStringResource))
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(result)
                session.append(String(decoding: data, as: UTF8.self))
            }
        } catch {
            session.append("> \(line)")
            session.append(String(localized: "Command failed: \(ConsoleErrorPresentation.text(error))"))
        }
    }
}

private enum ConsoleErrorPresentation {
    static func text(_ error: Error) -> String {
        if let issue = error as? AutomationIssue {
            return issue.message.appLocalized
        }
        return error.localizedDescription
    }
}

private struct CommandConsoleView: View {
    @ObservedObject var state: ConsoleViewModel
    let model: AppModel
    @ObservedObject private var diagnostics = AppDiagnostics.shared
    @AppStorage("console.loggingEnabled") private var logging = false
    @State private var historyCapacity = UserDefaults.standard.string(forKey: "console.historyCapacity") ?? ""
    @State private var outputCapacity = UserDefaults.standard.string(forKey: "console.outputCapacity") ?? ""
    @State private var logCapacity = UserDefaults.standard.string(forKey: "console.logCapacity") ?? ""
    @State private var showOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FreeDisplay commands run inside the app. Type help for commands; use display=\"alias:Desk\" value=40% or --display builtin. This console does not run a shell.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Command output and session history can contain identifiers. Review selected text before sharing.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Help") { state.session.draft = "help"; submit() }
                Button("Clear", systemImage: "trash") { state.session.clear(); diagnostics.clear() }
                Toggle("Logging", isOn: $logging).onChange(of: logging) { _, enabled in diagnostics.retaining = enabled }
                Spacer()
                Button("Retention…") { showOptions.toggle() }
            }
            if showOptions {
                Text("Retain newest entries. Blank means no configured limit; 0 retains nothing. Changes apply after Apply Retention.")
                    .font(.caption)
                HStack {
                    TextField("History entries", text: $historyCapacity)
                    TextField("Output entries", text: $outputCapacity)
                    TextField("Log entries", text: $logCapacity)
                    Button("Apply Retention") {
                        do {
                            let history = try ConsoleCapacity.parse(historyCapacity)
                            let output = try ConsoleCapacity.parse(outputCapacity)
                            let log = try ConsoleCapacity.parse(logCapacity)
                            UserDefaults.standard.set(historyCapacity, forKey: "console.historyCapacity")
                            UserDefaults.standard.set(outputCapacity, forKey: "console.outputCapacity")
                            UserDefaults.standard.set(logCapacity, forKey: "console.logCapacity")
                            state.session.historyCapacity = history
                            state.session.outputCapacity = output
                            diagnostics.setCapacity(log)
                            state.error = nil
                        } catch { state.error = ConsoleErrorPresentation.text(error) }
                    }
                }
            }
            if let error = state.error { Text(error).foregroundStyle(.red) }
            ScrollView {
                Text(state.session.output.joined(separator: "\n\n"))
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            if logging || !diagnostics.buffer.records.isEmpty {
                Text("Diagnostic log").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(diagnostics.buffer.records.map(\.line).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: .infinity)
            }
            HStack {
                Text(">").font(.system(.body, design: .monospaced))
                ConsolePrompt(text: $state.session.draft, submit: submit,
                              previous: { state.session.previous() }, next: { state.session.next() })
                Button("Run", action: submit).disabled(state.running)
            }
            if state.running { ProgressView().controlSize(.small) }
            Text("clear clears output and logs; exit closes this window. History lasts until FreeDisplay quits.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .environment(\.layoutDirection, .leftToRight)
        .frame(minWidth: 640, minHeight: 420)
    }

    private func submit() {
        Task { await state.submit(model: model) {
            // This view belongs to one app-owned window; closing it never terminates the app.
            (NSApp.delegate as? AppDelegate)?.closeCommandConsole()
        } }
    }
}

/// A separate field editor makes the immutable transcript and incoming logs unable to replace draft text.
private struct ConsolePrompt: NSViewRepresentable {
    @Binding var text: String
    var submit: () -> Void
    var previous: () -> Void
    var next: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.baseWritingDirection = .leftToRight
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            if let editor = field.currentEditor() {
                editor.string = text
                editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ConsolePrompt
        init(_ parent: ConsolePrompt) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.moveUp(_:)): parent.previous()
            case #selector(NSResponder.moveDown(_:)): parent.next()
            default: return false
            }
            return true
        }
    }
}
#endif
