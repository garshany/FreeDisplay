// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
import AutomationSchema
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
                Text(verbatim: "GET /v1/displays · POST /v1/brightness · POST /v1/reconnect-all")  // routes, not prose
                    .font(.system(.caption, design: .monospaced))
                Text("A brightness change returns the request status; the hardware result is not verified. TV and AV-receiver protocols and HDMI-CEC are not implemented in this build.").font(.caption)
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
            let gateway = await OpenDisplayAutomation.makeGateway()
            guard !Task.isCancelled, visible, generation == attempt else { return }
            do {
                try server.start(gateway: gateway) { command in
                    func encode(_ object: [String: Any]) -> Data {
                        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
                    }
                    switch command {
                    case .displays:
                        let list: [[String: Any]] = model.displays.map {
                            ["id": $0.recordID.rawValue, "name": model.displayName(for: $0),
                             "active": $0.isActive, "brightness": Double(model.brightness[$0.recordID] ?? 1)]
                        }
                        return encode(["displays": list])
                    case .brightness(let id, let value):
                        guard value.isFinite, (0...1).contains(value),
                              let display = model.displays.first(where: { $0.recordID.rawValue == id && $0.isActive }) else {
                            // API payload for HTTP clients, not UI: kept as stable, unlocalized English.
                            return encode(["status": "rejected", "error": "No active display with this ID, or the brightness is out of range"])
                        }
                        model.setBrightness(Float(value), for: display)
                        return encode(["status": "requested", "displayId": id, "value": value,
                                       "physicalEffectVerified": false])
                    default:
                        return encode(["status": "rejected"])
                    }
                }
                started = true; status = String(localized: "Starting…")
            } catch { status = String(localized: "Couldn’t start the server: \(error.localizedDescription)") }
        }
    }
}
#endif
