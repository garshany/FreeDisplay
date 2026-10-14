#if !PUBLIC_API_ONLY
import DisplayDomain
import SwiftUI
import VirtualDisplayProvider
import ProviderInterfaces

/// Wire into Settings with the app's actual safe-mode state. Never restores definitions at launch.
struct VirtualDisplaysSettingsView: View {
    let safeMode: Bool
    @ObservedObject var session: VirtualDisplaySession
    @State private var experimentalOptIn = false
    @State private var name = String(localized: "OpenDisplay Workspace")
    @State private var width = 1920
    @State private var height = 1080
    @State private var hiDPI = false
    @State private var refresh = 60.0
    @State private var busy = false
    @State private var result: String?

    var body: some View {
        Form {
            Section("Virtual screens · Experimental") {
                Text("Virtual screens use private macOS APIs and last until the app quits. Keep a physical display available for recovery.")
                    .font(.caption).foregroundStyle(.secondary)
                if safeMode { Text("Unavailable in Safe Mode.").foregroundStyle(.orange) }
                if !session.isAvailable { Text("This macOS version lacks the required virtual screen API.").foregroundStyle(.orange) }
                Toggle("Allow creating experimental virtual screens", isOn: $experimentalOptIn)
                    .disabled(safeMode || !session.isAvailable || busy)
                TextField("Name", text: $name)
                LabeledContent("Size in pixels") {
                    HStack {
                        TextField("Width in pixels", value: $width, format: .number).labelsHidden().frame(width: 90)
                        Text("×")
                        TextField("Height in pixels", value: $height, format: .number).labelsHidden().frame(width: 90)
                    }
                }
                Picker("Refresh rate", selection: $refresh) {
                    Text("30 Hz").tag(30.0); Text("60 Hz").tag(60.0); Text("120 Hz").tag(120.0)
                }
                Toggle("HiDPI: half the logical desktop size", isOn: $hiDPI)
                Button("Create Virtual Screen") {
                    guard let pixelWidth = UInt32(exactly: width), let pixelHeight = UInt32(exactly: height) else {
                        result = String(localized: "Enter valid positive pixel dimensions."); return
                    }
                    let definition = VirtualDisplayDefinition(name: name, pixelWidth: pixelWidth,
                        pixelHeight: pixelHeight, refreshRate: refresh, hiDPI: hiDPI)
                    run {
                        let endpoint = try await session.create(definition,
                            experimentalOptIn: experimentalOptIn, safeMode: safeMode)
                        result = String(localized: "Screen \(endpoint.displayID) is active. Pixel dimensions confirmed.")
                    }
                }
                .disabled(busy || !experimentalOptIn || safeMode || !session.isAvailable)
                ForEach(session.endpoints) { endpoint in
                    HStack {
                        Text(endpoint.definition.name)
                        Spacer()
                        Text("\(endpoint.definition.pixelWidth) × \(endpoint.definition.pixelHeight)")
                        Button("Remove") { run { try await session.destroy(endpoint.id); result = String(localized: "Screen removal confirmed.") } }
                            .disabled(busy)
                    }
                }
                if busy { ProgressView() }
                if let result { Text(result).font(.caption).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
    }

    private func localizedError(_ error: Error) -> String {
        guard let failure = error as? ProviderFailure else {
            // Definition validation errors come from VirtualDisplayProvider in English.
            return error is CancellationError ? String(localized: "Operation cancelled.")
                : String(localized: "Couldn’t complete the operation: \(error.localizedDescription.appLocalized)")
        }
        switch failure {
        case .denied: return String(localized: "Operation denied: check the experimental-features opt-in, Safe Mode, and that another display is active.")
        case .busy: return String(localized: "Another operation is still running, or the limit of four virtual screens has been reached.")
        case .unsupported: return String(localized: "This macOS version doesn’t support the required API.")
        case .timeout: return String(localized: "macOS didn’t confirm the screen was created in time.")
        case .providerError(let message), .partial(let message): return message.appLocalized
        case .osRejected(let code): return String(localized: "macOS rejected the operation (code \(code)).")
        case .ambiguous: return String(localized: "Couldn’t identify the screen unambiguously.")
        case .unknown: return String(localized: "The cause of the error is unknown.")
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true; result = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await action() }
            catch { result = localizedError(error) }
        }
    }
}
#endif
