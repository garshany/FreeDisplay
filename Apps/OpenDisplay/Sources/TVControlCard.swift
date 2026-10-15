#if os(macOS)
import AutomationSchema
import DisplayDomain
import OpenDisplayDesignSystem
import SwiftUI

struct TVControlCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var store = TVControlStore.shared
    @StateObject private var discovery = TVDiscoveryAdapter()
    let display: DisplayObservation
    @State private var family: TVFamily = .lgWebOS
    @State private var enabled = false
    @State private var host = ""
    @State private var port = ""
    @State private var tls = true
    @State private var connectionSeconds = ""
    @State private var responseSeconds = ""
    @State private var sessionSeconds = ""
    @State private var certificate = ""
    @State private var verifiedCertificate = false
    @State private var requirePIN = false
    @State private var pin = ""
    @State private var wakeMAC = ""
    @State private var wakeHost = ""
    @State private var wakePort = ""
    @State private var expanded = false
    @State private var busy = false
    @State private var message: String?
    @State private var confirmPowerOff = false
    @State private var confirmInput: TVInput?
    @State private var discoveryWindow = ""
    @State private var discoveryMX = ""

    private var state: TVSessionState? { store.states[display.recordID] }
    private var isSaved: Bool { store.configuration(for: display.recordID) != nil }
    private var fieldsChanged: Bool {
        guard let saved = store.configuration(for: display.recordID) else { return true }
        return saved.family != family || saved.endpoint.host != host || String(saved.endpoint.port) != port
            || saved.endpoint.tls != tls || saved.enabled != enabled || saved.requirePIN != (family == .lgWebOS && requirePIN)
            || Double(connectionSeconds) != saved.deadlines.connection || Double(responseSeconds) != saved.deadlines.response
            || Double(sessionSeconds) != saved.deadlines.sessionLifetime || !certificate.isEmpty
            || wakeMAC != (saved.wake?.mac.text ?? "") || wakeHost != (saved.wake?.destination.host ?? "")
            || wakePort != (saved.wake.map { String($0.destination.port) } ?? "")
    }

    var body: some View {
        ODCard(title: String(localized: "TV control"),
               footnote: String(localized: "FreeDisplay uses a separately paired network controller. Video connection, pairing and a sent request do not prove that a TV changed power, volume or input. Automatic power handling is off.")) {
            VStack(alignment: .leading, spacing: 10) {
                Text("TV endpoints, pairing and remote preferences stay on this Mac under their original display identifiers. They are excluded from settings archives, app reset, per-display Forget or Reset, and transfer. Use TV control to disable a controller or delete its local pairing; device-side authorization is unchanged.").font(.caption).foregroundStyle(.secondary)
                Toggle("Enable TV control", isOn: $enabled)
                Picker("TV family", selection: $family) {
                    Text("LG webOS").tag(TVFamily.lgWebOS)
                    Text("Samsung Tizen").tag(TVFamily.samsungTizen)
                }
                discoveryControls
                TextField("TV host or IP address", text: $host)
                TextField("WebSocket service port", text: $port)
                Toggle("Use TLS (wss)", isOn: $tls)
                if !tls {
                    Text("Unencrypted local control exposes pairing credentials to the network. Select it only if this TV requires ws.")
                        .font(.caption).foregroundStyle(.orange)
                }
                TextField("Pairing and network inactivity deadline (seconds)", text: $connectionSeconds)
                TextField("Command response deadline (seconds)", text: $responseSeconds)
                TextField("Session lifetime (seconds)", text: $sessionSeconds)
                Text("Enter deadlines explicitly. FreeDisplay does not retry commands automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                if tls {
                    TextField("TV certificate SHA-256 fingerprint (optional)", text: $certificate)
                    if !certificate.isEmpty {
                        Toggle("I verified this fingerprint belongs to this TV", isOn: $verifiedCertificate)
                    }
                    Text("Normal certificate validation applies unless you explicitly approve a fingerprint for this TV. A changed certificate requires pairing again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if family == .lgWebOS { Toggle("Require the TV pairing PIN", isOn: $requirePIN) }
                HStack {
                    Button("Save TV Configuration") { save() }
                    Button("Pair / Reconnect") {
                        if save() { store.connect(display.recordID) }
                    }.disabled(!enabled)
                    if state?.connection == .waitingForPIN || state?.connection == .waitingForPrompt || state?.connection == .connecting {
                        Button("Cancel Pairing") { store.disconnect(display.recordID) }
                    }
                }
                Text(connectionText).font(.caption).foregroundStyle(.secondary)
                if state?.connection == .waitingForPIN {
                    SecureField("TV pairing PIN", text: $pin)
                    Button("Complete Pairing") {
                        Task {
                            do { try await store.submitPIN(pin, display: display.recordID); pin = "" }
                            catch { message = String(localized: "FreeDisplay could not submit the TV pairing PIN.") }
                        }
                    }
                }
                if isSaved {
                    HStack {
                        Button("Disconnect TV Session") { store.disconnect(display.recordID) }
                        Button("Delete Local TV Pairing") {
                            do { try store.deletePairing(display.recordID) }
                            catch { message = String(localized: "FreeDisplay could not delete the local TV credential.") }
                        }
                        Button("Remove TV Controller") {
                            do { try store.remove(display.recordID); enabled = false }
                            catch { message = String(localized: "FreeDisplay could not save the TV configuration.") }
                        }
                    }
                    Text("Removing disables the controller and keeps its configuration. Deleting local pairing does not revoke authorization on the TV.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Remote commands", isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            actionButton("Volume Down", .volumeDown)
                            actionButton("Volume Up", .volumeUp)
                            actionButton("Mute Toggle", .muteToggle)
                        }.environment(\.layoutDirection, .leftToRight)
                        Text("Relative volume only. Mute is a toggle; Samsung does not report an absolute volume or active input here.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("TV Power Off") { confirmPowerOff = true }
                            .disabled(!canPerform(.powerOff))
                        if family == .lgWebOS {
                            actionButton("Refresh TV Inputs", .refreshInputs)
                            ForEach(state?.inputs ?? [], id: \.id) { input in
                                Button(input.label) { confirmInput = input }.disabled(!canPerform(.switchInput(input.id)))
                            }
                            if let requested = state?.requestedInput {
                                Text("Requested input: \(requested). Active input is unconfirmed.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            HStack {
                                actionButton("Source Key", .source)
                                actionButton("HDMI Key", .hdmi)
                            }
                            Text("Source and HDMI keys depend on the TV model. Keep its physical remote available to return to the Mac input.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 6)
                }
                Text("Wake-on-LAN").font(.headline)
                TextField("Wake interface MAC address", text: $wakeMAC)
                TextField("Wake destination host or broadcast address", text: $wakeHost)
                TextField("Wake UDP port", text: $wakePort)
                actionButton("Send Wake Request", .wake)
                Text("Save wake settings before sending. WOL is independent of pairing and requires the correct Ethernet or Wi-Fi MAC, network standby and a reachable route. Packet submission does not confirm wake.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).font(.caption).textSelection(.enabled) }
            }.padding(10)
        }
        .disabled(model.safeStartup || busy)
        .onAppear { load() }
        .onChange(of: expanded) { _, value in
            UserDefaults.standard.set(value, forKey: "opendisplay.tvRemoteExpanded." + display.recordID.rawValue)
        }
        // Editing an endpoint immediately invalidates pending operations, before Save is pressed.
        .onChange(of: host) { _, _ in stopEditedSession() }
        .onChange(of: port) { _, _ in stopEditedSession() }
        .onChange(of: tls) { _, _ in stopEditedSession() }
        .onChange(of: family) { _, _ in stopEditedSession(); discovery.cancel() }
        .onChange(of: requirePIN) { _, _ in if family == .lgWebOS { stopEditedSession() } }
        .onChange(of: enabled) { _, value in
            if !value { try? store.remove(display.recordID) }
        }
        .onDisappear { discovery.cancel() }
        .confirmationDialog("Turn off this TV?", isPresented: $confirmPowerOff) {
            Button("TV Power Off", role: .destructive) { run(.powerOff) }
        } message: { Text("The TV may stop showing the Mac. Keep an independent screen and the TV remote available.") }
        .confirmationDialog("Switch the TV input?", isPresented: Binding(get: { confirmInput != nil }, set: { if !$0 { confirmInput = nil } })) {
            if let input = confirmInput { Button("Switch TV Input") { run(.switchInput(input.id)); confirmInput = nil } }
        } message: { Text("Switching away can remove the Mac picture and control path. Use the TV remote or another screen to return. A sent request does not confirm the active input.") }
    }

    private var discoveryControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Discovery window (seconds)", text: $discoveryWindow)
            TextField("SSDP maximum response delay (whole seconds)", text: $discoveryMX)
            HStack {
                Button("Discover TVs") {
                    do {
                        guard let window = Double(discoveryWindow), let mx = UInt(discoveryMX) else {
                            throw AutomationIssue.invalidValue("discovery", "invalid durations")
                        }
                        try discovery.search(TVDiscoveryRequest(family: family, window: window, maximumResponseDelaySeconds: mx))
                    } catch { message = String(localized: "Enter a positive discovery window and whole-second SSDP response delay.") }
                }
                if discovery.state.phase == .searching { Button("Cancel Discovery") { discovery.cancel() } }
            }
            if discovery.state.phase == .finished { Text("Discovery finished. No result does not prove a TV is absent.").font(.caption) }
            if discovery.state.phase == .failed { Text("TV discovery failed. Enter the TV address manually.").font(.caption) }
            ForEach(discovery.state.candidates) { candidate in
                Button("Use discovered host: \(candidate.host)") { host = candidate.host }
            }
            Text("Discovery is optional and runs only when requested. Advertisements are untrusted hints: select the correct TV and enter its service port. Discovery never pairs a TV or learns a wake MAC.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func actionButton(_ title: LocalizedStringKey, _ action: TVAction) -> some View {
        Button(title) { run(action) }.disabled(!canPerform(action))
    }
    private func canPerform(_ action: TVAction) -> Bool {
        !fieldsChanged && !busy && store.canPerform(action, display: display.recordID)
    }
    private func run(_ action: TVAction) {
        busy = true
        Task {
            let result = await AppAutomation.run(.byID(.tvControl(action), display.recordID), from: .console, model: model)
            if result.issue != nil { message = String(localized: "FreeDisplay could not confirm the TV command. Check the connection and TV authorization; no command was retried.") }
            else if result.tv?.delivery == .acknowledged { message = String(localized: "The TV accepted the request. The physical effect is unconfirmed.") }
            else { message = String(localized: "Request sent. The TV response and physical effect are unconfirmed.") }
            busy = false
        }
    }

    @discardableResult private func save() -> Bool {
        do {
            guard let port = UInt16(port), let connection = Double(connectionSeconds), let response = Double(responseSeconds),
                  let session = Double(sessionSeconds),
                  certificate.isEmpty || (tls && verifiedCertificate) else {
                message = String(localized: "Enter a valid host, service port and positive deadlines. Approve a certificate fingerprint only after verifying this TV.")
                return false
            }
            var wake: TVWakeConfiguration?
            if !wakeMAC.isEmpty || !wakeHost.isEmpty || !wakePort.isEmpty {
                guard let port = UInt16(wakePort) else { throw AutomationIssue.invalidValue("wake port", "invalid port") }
                wake = TVWakeConfiguration(mac: try TVMACAddress(wakeMAC), destination: try TVEndpoint(host: wakeHost, port: port, tls: false))
            }
            let configuration = TVControllerConfiguration(id: store.configuration(for: display.recordID)?.id ?? UUID(),
                family: family, endpoint: try TVEndpoint(host: host, port: port, tls: tls),
                deadlines: try TVDeadlines(connection: connection, response: response, sessionLifetime: session), enabled: enabled,
                requirePIN: family == .lgWebOS && requirePIN, wake: wake)
            try store.save(configuration, display: display.recordID, approvedPin: certificate.isEmpty ? nil : certificate)
            host = configuration.endpoint.host; self.port = String(configuration.endpoint.port)
            wakeMAC = configuration.wake?.mac.text ?? ""; wakeHost = configuration.wake?.destination.host ?? ""
            wakePort = configuration.wake.map { String($0.destination.port) } ?? ""
            certificate = ""; verifiedCertificate = false
            message = String(localized: "TV configuration saved. Connect explicitly to pair or reconnect.")
            return true
        } catch {
            message = String(localized: "FreeDisplay could not save the TV configuration. Check the endpoint, deadlines, MAC address and Keychain access.")
            return false
        }
    }
    private func load() {
        expanded = UserDefaults.standard.bool(forKey: "opendisplay.tvRemoteExpanded." + display.recordID.rawValue)
        guard let c = store.configuration(for: display.recordID) else { return }
        family = c.family; enabled = c.enabled; host = c.endpoint.host; port = String(c.endpoint.port); tls = c.endpoint.tls
        connectionSeconds = String(c.deadlines.connection); responseSeconds = String(c.deadlines.response); requirePIN = c.requirePIN
        sessionSeconds = String(c.deadlines.sessionLifetime)
        wakeMAC = c.wake?.mac.text ?? ""; wakeHost = c.wake?.destination.host ?? ""; wakePort = c.wake.map { String($0.destination.port) } ?? ""
    }
    private func stopEditedSession() { if fieldsChanged { store.disconnect(display.recordID) } }

    private var connectionText: String {
        switch state?.connection ?? (isSaved ? .configured : .disabled) {
        case .disabled: String(localized: "TV controller disabled")
        case .configured: String(localized: "Configured; not connected")
        case .connecting: String(localized: "Connecting to TV…")
        case .waitingForPrompt: String(localized: "Waiting for TV authorization prompt…")
        case .waitingForPIN: String(localized: "Waiting for TV pairing PIN…")
        case .ready: String(localized: "Authorized session; individual features remain device-dependent")
        case .pairedIdle: String(localized: "Paired; idle until explicitly reconnected")
        case .authorizationDenied: String(localized: "TV authorization denied")
        case .unreachable: String(localized: "TV unreachable or connection deadline expired")
        case .manifestRejected: String(localized: "TV rejected the LG permission manifest")
        case .credentialFailure: String(localized: "TV authorized, but FreeDisplay could not store its credential")
        }
    }
}
#endif
