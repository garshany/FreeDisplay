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
            // SO-18: App Intents are a separate integration from the keyboard shortcuts and the HTTP
            // control below; say what they cover and open the app that runs them.
            Section("Shortcuts app") {
                Text("OpenDisplay’s actions are in the Shortcuts app: get or set a display’s brightness, switch a display to one of its modes, make a display the main display, and reconnect all displays. They act on connected displays while OpenDisplay is running, and say when a display isn’t available. Keyboard shortcuts for OpenDisplay’s own actions are in Settings → Keyboard.")
                Button("Open Shortcuts") { openShortcutsApp() }
                    .disabled(Self.shortcutsAppURL == nil)
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
                Text(verbatim: "GET /v1/displays · POST /v1/brightness · POST /v1/reconnect-all")  // routes, not prose
                    .font(.system(.caption, design: .monospaced))
                Text("A brightness change returns the request status; the hardware result is not verified. Display brightness in the list is OpenDisplay’s last requested or read value, with its age; it is empty until a value is known. Reconnect All starts in the background and answers with the displays it is reconnecting. TV and AV-receiver protocols and HDMI-CEC are not implemented in this build.").font(.caption)
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

    /// Where macOS's Shortcuts app is installed, or nil when it can't be found.
    private static var shortcutsAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts")
    }

    private func openShortcutsApp() {
        guard let url = Self.shortcutsAppURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
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
                    func encode(_ object: [String: Any]) -> Data {
                        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
                    }
                    // API payloads for HTTP clients, not UI: kept as stable, unlocalized English.
                    switch command {
                    case .displays:
                        let now = Date()
                        let list: [[String: Any]] = model.displays.map { display in
                            // IN-05: the level is the app's cache — the last value it requested or
                            // read for this display — never a fresh device read, and a display it
                            // hasn't read yet has no level at all (it used to be reported as 1).
                            var row: [String: Any] = [
                                "id": display.recordID.rawValue, "name": model.displayName(for: display),
                                "active": display.isActive, "physicalBrightnessVerified": false]
                            if let level = model.brightness[display.recordID] {
                                row["brightness"] = Double(level)
                                row["brightnessSource"] = "appCache"
                                if let since = model.brightnessCachedSince[display.recordID] {
                                    row["brightnessCachedAt"] = ISO8601DateFormatter().string(from: since)
                                    row["brightnessAgeSeconds"] = (now.timeIntervalSince(since) * 10).rounded() / 10
                                }
                            } else {
                                row["brightness"] = NSNull()
                                row["brightnessSource"] = "unknown"
                            }
                            return row
                        }
                        return encode(["displays": list])
                    case .brightness(let id, let value):
                        guard value.isFinite, (0...1).contains(value),
                              let display = model.displays.first(where: { $0.recordID.rawValue == id && $0.isActive }) else {
                            return encode(["status": "rejected", "error": "No active display with this ID, or the brightness is out of range"])
                        }
                        model.setBrightness(Float(value), for: display, eventSource: .http)
                        return encode(["status": "requested", "displayId": id, "value": value,
                                       "physicalEffectVerified": false])
                    case .reconnectAll:
                        // Through the live model: only it holds the managed-offline ledger, so a
                        // gateway composed for HTTP always answered noOp. A verified reconnect
                        // watches each display until it lights (with one escalation), which
                        // outlasts a connection, so it runs as its own operation — the socket
                        // closing doesn't cancel it — and the reply says what was requested. The
                        // outcome goes to the audit log; GET /v1/displays shows displays returning.
                        guard !model.busy else {
                            return encode(["status": "rejected", "error": "Another display operation is in progress"])
                        }
                        let pending = model.managedOffline.map(\.recordID.rawValue)
                        Task { @MainActor in await model.reconnectAll(actor: .httpAPI) }
                        return encode(["status": pending.isEmpty ? "noOp" : "requested", "displayIds": pending,
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
