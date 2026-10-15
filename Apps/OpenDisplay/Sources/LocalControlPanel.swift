// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
import AutomationSchema
import DisplayDomain
import SwiftUI

@MainActor
struct LocalControlPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var server = LocalControlServer()
    @State private var status = String(localized: "Stopped")
    @State private var busy = false
    @State private var started = false
    @State private var tokenAvailable = false
    @State private var startTask: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var visible = false

    var body: some View {
        Form {
            // SO-18: App Intents are a separate integration from the keyboard shortcuts and the HTTP
            // control below; say what they cover and open the app that runs them.
            Section("Shortcuts app") {
                ShortcutsIntegrationRows()
            }
            Section("Local HTTP control") {
                Text("Control on 127.0.0.1 lasts only for the current session. Requests need the secret token. The server stops when you leave this section.")
                Text(status).textSelection(.enabled)
                HStack {
                    Button("Start Local Server") { start() }.disabled(busy || started)
                    Button("Stop", action: stop).disabled(!started && !busy)
                    Button("Copy Session Token") {
                        guard let token = server.token else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(token, forType: .string)
                    }.disabled(!tokenAvailable)
                }
                Text(verbatim: "GET /v1/displays · GET /v1/commands · POST /v1/brightness · POST /v1/reconnect-all · POST /v1/command")  // routes, not prose
                    .font(.system(.caption, design: .monospaced))
                Text("A brightness change returns its settled status and readback when available; physical luminance is not verified. Display brightness in the list is FreeDisplay’s last requested or read value, with its age; it is empty until a value is known. Reconnect All starts in the background and answers with the displays it is reconnecting. TV and AV-receiver protocols and HDMI-CEC are not implemented in this build.").font(.caption)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Automation")
        .onAppear { visible = true }
        .task {
            while !Task.isCancelled {
                if let port = server.port { status = String(localized: "Server running: http://127.0.0.1:\(port)") }
                else if let failure = server.failure { status = failure; started = false }
                tokenAvailable = server.token != nil && server.port != nil
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        .onDisappear { visible = false; stop() }
    }

    private func stop() {
        generation = UUID()
        startTask?.cancel(); startTask = nil
        server.stop(); started = false; busy = false
        tokenAvailable = false; status = String(localized: "Stopped")
    }

    private func start() {
        busy = true
        let attempt = UUID()
        generation = attempt
        startTask = Task { @MainActor in
            defer { if generation == attempt { busy = false; startTask = nil } }
            guard !Task.isCancelled, visible, generation == attempt else { return }
            do {
                try server.start { command in
                    func encode(_ object: [String: Any], status: Int = 200) -> AutomationHTTPResponse {
                        AutomationHTTPResponse(status: status, body:
                            (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8))
                    }
                    switch command {
                    case .displays:
                        let result = await AppAutomation.run(.init(.listDisplays), from: .http, model: model)
                        let now = Date()
                        let list: [[String: Any]] = (result.displays ?? []).map { display in
                            var row: [String: Any] = [
                                "id": display.id, "name": display.name,
                                "active": display.availability == .active, "physicalBrightnessVerified": false]
                            let id = DisplayRecordID(rawValue: display.id)
                            if let level = model.brightness[id] {
                                row["brightness"] = Double(level)
                                row["brightnessSource"] = "appCache"
                                if let since = model.brightnessCachedSince[id] {
                                    row["brightnessCachedAt"] = ISO8601DateFormatter().string(from: since)
                                    row["brightnessAgeSeconds"] = (now.timeIntervalSince(since) * 10).rounded() / 10
                                }
                            } else {
                                row["brightness"] = NSNull()
                                row["brightnessSource"] = "unknown"
                            }
                            return row
                        }
                        return encode(["displays": list], status: AutomationHTTPStatus.code(for: result))
                    case .brightness(let id, let value):
                        // Framing already validated the number; the typed engine validates the target
                        // and settles the same write as every other app surface.
                        let request = AutomationRequest.byID(.setBrightness(AutomationLevel(normalized: value)!, method: .automatic),
                                                             DisplayRecordID(rawValue: id))
                        return AutomationHTTPResponse(await AppAutomation.run(request, from: .http, model: model),
                                                      style: .legacyBrightness)
                    case .command(let request, let style):
                        return AutomationHTTPResponse(await AppAutomation.run(request, from: .http, model: model), style: style)
                    case .catalog:
                        return AutomationHTTPResponse(status: 200, body:
                            (try? ResultEnvelope.makeEncoder().encode(AutomationCatalog.descriptors(for: .http))) ?? Data("[]".utf8))
                    case .invalid(let issue):
                        return encode(["status": "rejected", "error": issue.message, "code": issue.code.rawValue],
                                      status: AutomationHTTPStatus.code(for: issue))
                    case .reconnectAll:
                        let result = await AppAutomation.run(.init(.reconnectAll), from: .http, model: model)
                        if let issue = result.issue {
                            return encode(["status": "rejected", "error": issue.message], status: AutomationHTTPStatus.code(for: result))
                        }
                        return encode(["status": result.status == .noOp ? "noOp" : "requested",
                                       "displayIds": result.envelope.targets.map(\.displayId), "physicalEffectVerified": false])
                    case .incomplete, .rejected:
                        return encode(["status": "rejected"], status: 400)
                    }
                }
                started = true; status = String(localized: "Starting…")
            } catch { status = String(localized: "Couldn’t start the server: \(error.localizedDescription)") }
        }
    }
}
#endif
