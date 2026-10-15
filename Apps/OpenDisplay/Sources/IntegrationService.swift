#if os(macOS)
import AutomationSchema
import Combine
import CoreGraphicsProvider
import DisplayDomain
import Foundation
import Security

/// Process lifetime, independent of any Settings window. Only the explicitly enabled HTTP listener
/// has network reachability; same-user IPC is available for the CLI throughout the app lifetime.
@MainActor
final class IntegrationService: ObservableObject {
    let http = LocalControlServer()
    @Published private(set) var configuration: IntegrationHTTPConfiguration
    @Published private(set) var ipcState: LocalAutomationProtocol.State = .starting
    @Published private(set) var ipcFailure: String?
    @Published private(set) var configurationFailure: String?
    private unowned let model: AppModel
    private let defaults: UserDefaults
    private let socket = LocalAutomationSocket.Server()
    private var preparation: Task<Void, Never>?
    private static let configurationKey = "OpenDisplay.Integration.HTTP.v1"

    init(model: AppModel, defaults: UserDefaults = .standard) {
        self.model = model; self.defaults = defaults
        configuration = defaults.data(forKey: Self.configurationKey)
            .flatMap { try? JSONDecoder().decode(IntegrationHTTPConfiguration.self, from: $0) } ?? .init()
    }

    var httpPaused: Bool { configuration.enabled && model.safeStartup }

    func start() {
        do {
            try socket.start(path: LocalAutomationSocket.defaultPath()) { [weak self] data in
                guard let self else { return Data() }
                let response = await LocalAutomationProtocol.respond(to: data, state: self.ipcState) { request in
                    await AppAutomation.run(request, from: .cli, model: self.model)
                }
                return (try? JSONEncoder().encode(response)) ?? Data()
            }
        } catch { ipcFailure = String(localized: "FreeDisplay IPC could not start: \(error.localizedDescription)") }
        preparation = Task { [weak self] in
            guard let self else { return }
            await model.prepareForAutomation()
            guard !Task.isCancelled else { return }
            ipcState = .ready
            if configuration.shouldStart(safeStartup: model.safeStartup) { startHTTP() }
        }
    }
    func stop() {
        ipcState = .stopping
        preparation?.cancel(); preparation = nil
        socket.stop(); http.stop()
    }
    private func save() {
        if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: Self.configurationKey) }
    }
    func configure(enabled: Bool, port: String, remoteAccess: Bool) {
        do {
            let next = try configuration.updating(enabled: enabled, port: port, remoteAccess: remoteAccess)
            configurationFailure = nil
            guard next != configuration else { return }
            http.stop()
            configuration = next; save()
            if enabled, ipcState == .ready { startHTTP() }
        } catch { configurationFailure = String(localized: "HTTP configuration error: \(error.localizedDescription)") }
    }
    func retryHTTP() {
        guard configuration.enabled, ipcState == .ready else { return }
        http.stop(); startHTTP()
    }
    func rotateToken() {
        guard !configuration.enabled else { return }
        do { try IntegrationCredential.replace(); configurationFailure = nil }
        catch { configurationFailure = String(localized: "HTTP credential error: \(error.localizedDescription)") }
    }
    func tokenForCopy() -> String? {
        do { return try IntegrationCredential.loadOrCreate() }
        catch { configurationFailure = String(localized: "HTTP credential error: \(error.localizedDescription)"); return nil }
    }
    private func startHTTP() {
        guard configuration.shouldStart(safeStartup: model.safeStartup) else { return }
        configurationFailure = nil
        do {
            try http.start(token: IntegrationCredential.loadOrCreate(), configuration: configuration, onReady: { [weak self] port in
                guard let self else { return }
                self.configuration.port = port
                self.save()
            }) { [weak self] command in
                guard let self else { return AutomationHTTPResponse(status: 503, body: Data()) }
                return await self.handleHTTP(command)
            }
        } catch { configurationFailure = String(localized: "Couldn’t start the server: \(error.localizedDescription)") }
    }
    private func handleHTTP(_ command: LocalHTTPControl.ParseResult) async -> AutomationHTTPResponse {
        func encode(_ object: [String: Any], status: Int = 200) -> AutomationHTTPResponse {
            AutomationHTTPResponse(status: status, body:
                (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8))
        }
        guard !model.safeStartup else { return encode(["status": "paused", "error": "HTTP is paused during safe startup"], status: 503) }
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
}

/// No UserDefaults/archive/log representation of the bearer token. A locked/denied Keychain is a
/// startup failure, never permission to replace a credential that existing clients still use.
private enum IntegrationCredential {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.personal.OpenDisplay.http",
         kSecAttrAccount as String: "integration-token"]
    }
    static func loadOrCreate() throws -> String {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode))
            }
            return token
        }
        guard status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let token = try generate()
        var insert = query
        insert[kSecValueData as String] = Data(token.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let saved = SecItemAdd(insert as CFDictionary, nil)
        guard saved == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(saved)) }
        return token
    }
    private static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(randomStatus)) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    static func replace() throws {
        let token = try generate()
        let changes = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound { _ = try loadOrCreate(); return }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
#endif
