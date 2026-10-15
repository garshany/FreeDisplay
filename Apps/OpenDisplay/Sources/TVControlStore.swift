#if os(macOS)
import AutomationSchema
import Combine
import DisplayDomain
import Foundation

/// One session per explicitly associated display. Loading preferences never starts network I/O.
@MainActor final class TVControlStore: ObservableObject {
    static let shared = TVControlStore()
    @Published private(set) var states: [DisplayRecordID: TVSessionState] = [:]
    private var controllers: [DisplayRecordID: TVController] = [:]
    private let credentials = TVKeychain()
    private let defaults = UserDefaults.standard
    private let key = "opendisplay.tvControllers.v1"

    func configuration(for display: DisplayRecordID) -> TVControllerConfiguration? {
        if let controller = controllers[display] { return controller.configuration }
        guard let data = (defaults.dictionary(forKey: key) as? [String: Data])?[display.rawValue] else { return nil }
        return try? JSONDecoder().decode(TVControllerConfiguration.self, from: data)
    }

    func save(_ configuration: TVControllerConfiguration, display: DisplayRecordID, approvedPin: String?) throws {
        if let approvedPin { _ = try TVCertificatePin(approvedPin) }
        if let controller = controllers[display] { try controller.update(configuration) }
        else {
            // Apply endpoint/family invalidation even when the old configuration wasn't opened.
            if let old = self.configuration(for: display) {
                let controller = TVNetworkFactory.controller(old, credentials: credentials)
                try controller.update(configuration)
            }
        }
        if let approvedPin {
            var credential = try credentials.read(id: configuration.id) ?? TVCredential(token: nil, certificateSHA256: nil)
            let normalized = try TVCertificatePin(approvedPin).hex
            if credential.certificateSHA256 != normalized { credential.token = nil }
            credential.certificateSHA256 = normalized
            try credentials.write(credential, id: configuration.id)
        }
        var saved = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
        saved[display.rawValue] = try JSONEncoder().encode(configuration)
        defaults.set(saved, forKey: key)
        install(configuration, display: display)
    }

    func connect(_ display: DisplayRecordID) { controller(display)?.connect() }
    func disconnect(_ display: DisplayRecordID) { controller(display)?.disconnect() }
    func submitPIN(_ pin: String, display: DisplayRecordID) async throws {
        guard let controller = controller(display) else { throw AutomationIssue(.notReady, "TV is not configured") }
        try await controller.submitPIN(pin)
    }
    func deletePairing(_ display: DisplayRecordID) throws {
        try controller(display)?.deletePairing()
    }
    func remove(_ display: DisplayRecordID) throws {
        guard var configuration = configuration(for: display) else { return }
        configuration.enabled = false
        try save(configuration, display: display, approvedPin: nil)
    }
    func canPerform(_ action: TVAction, display: DisplayRecordID) -> Bool {
        if let controller = controllers[display] { return controller.canPerform(action) }
        // SwiftUI reads this while rendering buttons. Only explicit actions may install/publish a
        // session; a separately saved wake interface is usable without opening a paired socket.
        guard action == .wake, let configuration = configuration(for: display) else { return false }
        return configuration.enabled && configuration.wake != nil
    }
    func capabilities(display: DisplayRecordID) -> TVCapabilityReport? { controller(display)?.capabilities }
    func perform(_ action: TVAction, display: DisplayRecordID) async throws(AutomationIssue) -> TVCommandReceipt {
        guard let controller = controller(display) else { throw AutomationIssue(.notReady, "TV is not configured") }
        return try await controller.perform(action)
    }

    private func controller(_ display: DisplayRecordID) -> TVController? {
        if let controller = controllers[display] { return controller }
        guard let configuration = configuration(for: display) else { return nil }
        install(configuration, display: display)
        return controllers[display]
    }
    private func install(_ configuration: TVControllerConfiguration, display: DisplayRecordID) {
        controllers[display]?.disconnect()
        let controller = TVNetworkFactory.controller(configuration, credentials: credentials)
        controller.onChange = { [weak self] in self?.states[display] = $0 }
        controllers[display] = controller
        states[display] = controller.state
    }
}
#endif
