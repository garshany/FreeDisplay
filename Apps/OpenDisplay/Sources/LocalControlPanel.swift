// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
import AutomationSchema
import DisplayDomain
import SwiftUI

@MainActor
struct LocalControlPanel: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        IntegrationControlPanel(service: model.integrationService)
    }
}

@MainActor
private struct IntegrationControlPanel: View {
    @ObservedObject var service: IntegrationService
    @ObservedObject private var server: LocalControlServer
    @State private var port = ""
    @State private var remoteWarning = false
    init(service: IntegrationService) { self.service = service; self.server = service.http }

    var body: some View {
        Form {
            // SO-18: App Intents are a separate integration from the keyboard shortcuts and the HTTP
            // control below; say what they cover and open the app that runs them.
            Section("Shortcuts app") {
                ShortcutsIntegrationRows()
            }
            Section("Local HTTP control") {
                Text("FreeDisplay keeps an enabled HTTP server running until you disable it or quit the app. HTTP is off on a new installation. The token is saved in Keychain; the chosen port is remembered.")
                Toggle("Enable HTTP control", isOn: Binding(get: { service.configuration.enabled }, set: { enabled in
                    service.configure(enabled: enabled, port: port, remoteAccess: service.configuration.remoteAccess)
                }))
                TextField("HTTP port (blank chooses once)", text: $port)
                    .onSubmit { applyPort() }
                Button("Apply Port", action: applyPort)
                Toggle("Allow remote HTTP access", isOn: Binding(get: { service.configuration.remoteAccess }, set: { enabled in
                    if enabled { remoteWarning = true }
                    else { service.configure(enabled: service.configuration.enabled, port: port, remoteAccess: false) }
                }))
                Text("Remote HTTP sends credentials and commands without encryption. Use a trusted network or an authenticated TLS tunnel. Never expose this listener to the public internet.").font(.caption)
                if let boundPort = server.port {
                    Text("Server running: http://\(service.configuration.host):\(boundPort)").textSelection(.enabled)
                } else if service.configuration.enabled {
                    Text("HTTP enabled; listener is not ready")
                    Button("Retry HTTP Server") { service.retryHTTP() }
                } else { Text("Stopped") }
                if let failure = server.failure ?? service.configurationFailure { Text(failure).foregroundStyle(.red) }
                HStack {
                    Button("Copy HTTP Token") {
                        guard let token = service.tokenForCopy() else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(token, forType: .string)
                    }
                    Button("Replace HTTP Token") { service.rotateToken() }.disabled(service.configuration.enabled)
                }
                Text("Replacing the token requires HTTP to be disabled and updates to every client. Disabling HTTP stops access; it does not undo commands already accepted.").font(.caption)
                if let failure = service.ipcFailure { Text(failure).foregroundStyle(.red) }
                Text(verbatim: "GET /v1/displays · GET /v1/commands · POST /v1/brightness · POST /v1/reconnect-all · POST /v1/command")  // routes, not prose
                    .font(.system(.caption, design: .monospaced))
                Text("A brightness change returns its settled status and readback when available; physical luminance is not verified. Display brightness in the list is FreeDisplay’s last requested or read value, with its age; it is empty until a value is known. Reconnect All starts in the background and answers with the displays it is reconnecting. TV and AV-receiver protocols and HDMI-CEC are not implemented in this build.").font(.caption)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Automation")
        .onAppear { port = service.configuration.port.map(String.init) ?? "" }
        .onChange(of: service.configuration.port) { _, value in port = value.map(String.init) ?? "" }
        .alert("Allow unencrypted remote HTTP access?", isPresented: $remoteWarning) {
            Button("Allow Remote Access", role: .destructive) {
                service.configure(enabled: service.configuration.enabled, port: port, remoteAccess: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anyone who can reach this Mac and has the token can control its displays. HTTP provides no encryption. Limit access to a trusted network or use a TLS tunnel.")
        }
    }

    private func applyPort() {
        service.configure(enabled: service.configuration.enabled, port: port, remoteAccess: service.configuration.remoteAccess)
    }


}

#endif
