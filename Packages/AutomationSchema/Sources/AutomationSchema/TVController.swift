import Foundation

@MainActor public protocol TVSocket: AnyObject {
    func start() async throws
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

/// Credentials are never part of command/results or exported controller configuration.
public struct TVCredential: Sendable, Codable, Equatable {
    public var token: String?
    public var certificateSHA256: String?
    public init(token: String?, certificateSHA256: String?) { self.token = token; self.certificateSHA256 = certificateSHA256 }
}

@MainActor public protocol TVCredentialStore: AnyObject {
    func read(id: UUID) throws -> TVCredential?
    func write(_ credential: TVCredential, id: UUID) throws
    func remove(id: UUID) throws
}

/// Public I/O seams. Fakes exercise the exact pairing/command path used by the app.
@MainActor public final class TVController {
    public typealias SocketFactory = @MainActor (TVControllerConfiguration, TVCredential?) throws -> any TVSocket
    public typealias Wait = @Sendable (TimeInterval) async throws -> Void
    public typealias WakeSender = @MainActor (Data, TVEndpoint, TimeInterval) async throws -> Void

    public private(set) var configuration: TVControllerConfiguration
    public private(set) var state = TVSessionState()
    public var onChange: (@MainActor (TVSessionState) -> Void)?
    private let credentials: any TVCredentialStore
    private let factory: SocketFactory
    private let wait: Wait
    private let wakeSender: WakeSender
    private var socket: (any TVSocket)?
    private var reader: Task<Void, Never>?
    private var pairingDeadline: Task<Void, Never>?
    private var wakeTask: Task<Void, any Error>?
    private var pending: [String: CheckedContinuation<TVWireProtocol.Event, any Error>] = [:]
    private var responseDeadlines: [String: Task<Void, Never>] = [:]
    private var registrationID = ""
    private var pinRequestID: String?
    private var executing = false

    public init(configuration: TVControllerConfiguration, credentials: any TVCredentialStore,
                factory: @escaping SocketFactory, wait: @escaping Wait, wakeSender: @escaping WakeSender) {
        self.configuration = configuration; self.credentials = credentials
        self.factory = factory; self.wait = wait; self.wakeSender = wakeSender
        state.reset(to: configuration.enabled ? .configured : .disabled, paired: false)
    }

    public func canPerform(_ action: TVAction) -> Bool {
        guard configuration.enabled else { return false }
        if action == .wake { return configuration.wake != nil }
        guard state.connection == .ready else { return false }
        switch (configuration.family, action) {
        case (.lgWebOS, .source), (.lgWebOS, .hdmi), (.samsungTizen, .refreshInputs), (.samsungTizen, .switchInput): return false
        case (.lgWebOS, .switchInput(let id)): return state.inputs.contains { $0.id == id }
        default: return true
        }
    }

    public var capabilities: TVCapabilityReport {
        let actions: [TVAction] = [.volumeUp, .volumeDown, .muteToggle, .powerOff, .source, .hdmi, .refreshInputs, .wake]
        var names = actions.filter { canPerform($0) }.map(\.name)
        if state.inputs.contains(where: { canPerform(.switchInput($0.id)) }) { names.append("switchInput") }
        return TVCapabilityReport(family: configuration.family, connection: state.connection,
            authorizedSession: state.connection == .ready, actions: names, inputs: state.inputs,
            featureOutcomes: state.featureOutcomes)
    }

    public func connect() {
        stop(to: configuration.enabled ? .configured : .disabled)
        guard configuration.enabled else { return }
        let generation = state.reset(to: .connecting, paired: false)
        changed()
        registrationID = UUID().uuidString
        let registrationID = registrationID
        pairingDeadline = Task { [weak self, wait, seconds = configuration.deadlines.connection] in
            do { try await wait(seconds) } catch { return }
            guard let self, self.state.generation == generation else { return }
            self.stop(to: .unreachable)
        }
        reader = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, self.state.generation == generation else { return }
            do {
                let credential: TVCredential?
                do { credential = try self.credentials.read(id: self.configuration.id) }
                catch { self.stop(to: .credentialFailure); return }
                self.state.transition(.connecting, generation: generation, paired: credential?.token != nil)
                let socket = try self.factory(self.configuration, credential)
                self.socket = socket
                try await socket.start()
                guard self.state.generation == generation else { socket.close(); return }
                self.state.transition(self.configuration.requirePIN ? .waitingForPIN : .waitingForPrompt, generation: generation)
                self.changed()
                guard !Task.isCancelled, self.state.generation == generation else { return }
                if self.configuration.family == .lgWebOS {
                    try await socket.send(TVWireProtocol.lgRegister(clientKey: credential?.token,
                        requirePIN: self.configuration.requirePIN, id: registrationID))
                }
                while !Task.isCancelled {
                    let text = try await socket.receive()
                    guard self.state.generation == generation else { return }
                    let event = try TVWireProtocol.parse(text, family: self.configuration.family, registrationID: registrationID)
                    try self.handle(event, generation: generation)
                }
            } catch {
                guard self.state.generation == generation else { return }
                self.stop(to: .unreachable)
            }
        }
    }

    public func submitPIN(_ pin: String) async throws {
        guard configuration.family == .lgWebOS, state.connection == .waitingForPIN, let socket else {
            throw AutomationIssue(.notReady, "LG is not waiting for a PIN")
        }
        guard pinRequestID == nil else { throw AutomationIssue(.busy, "a TV PIN submission is already pending") }
        let id = UUID().uuidString
        let message = try TVWireProtocol.lgPIN(pin, id: id)
        pinRequestID = id
        // PIN acceptance does not itself mark the session authorized; registration must complete.
        try await socket.send(message)
    }

    public func disconnect() { stop(to: state.paired ? .pairedIdle : .configured) }

    public func remove() {
        configuration.enabled = false
        stop(to: .disabled)
    }

    public func deletePairing() throws {
        stop(to: configuration.enabled ? .configured : .disabled)
        try credentials.remove(id: configuration.id)
        state.reset(to: configuration.enabled ? .configured : .disabled, paired: false)
        changed()
    }

    public func update(_ replacement: TVControllerConfiguration) throws {
        let old = configuration
        stop(to: .configured)
        // Samsung authorization is endpoint-bound. LG may keep a valid client key at a new DHCP
        // address; TLS remains bound to the explicitly paired certificate in its credential.
        if old.id != replacement.id || old.family != replacement.family || old.requirePIN != replacement.requirePIN
            || (old.family == .samsungTizen && old.endpoint != replacement.endpoint) {
            try credentials.remove(id: old.id)
        }
        configuration = replacement
        state.reset(to: replacement.enabled ? .configured : .disabled, paired: false)
        changed()
    }

    public func perform(_ action: TVAction) async throws(AutomationIssue) -> TVCommandReceipt {
        guard !Task.isCancelled else { throw AutomationIssue(.notConfirmed, "TV command was cancelled before submission") }
        guard canPerform(action) else { throw AutomationIssue(.capabilityUnavailable, "TV control is disabled, unpaired, disconnected or does not offer that action") }
        guard !executing else { throw AutomationIssue(.busy, "a TV command is already in progress") }
        executing = true
        let generation = state.generation
        defer { executing = false }
        do {
            let receipt: TVCommandReceipt
            if action == .wake, let wake = configuration.wake {
                let task = Task { [wakeSender, seconds = configuration.deadlines.response] in
                    try await wakeSender(wake.mac.magicPacket, wake.destination, seconds)
                }
                wakeTask = task
                defer { wakeTask = nil }
                try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                receipt = TVCommandReceipt(.sent)
            } else if configuration.family == .samsungTizen {
                guard let socket else { throw AutomationIssue(.notReady, "TV is disconnected") }
                try await socket.send(TVWireProtocol.samsungMessage(action))
                receipt = TVCommandReceipt(.sent)
            } else {
                var muted: Bool?
                if action == .muteToggle {
                    let id = UUID().uuidString
                    let reply = try await exchange(id: id, message: TVWireProtocol.lgVolume(id: id), generation: generation)
                    if case .reply(_, true, let value, _) = reply { muted = value }
                    guard muted != nil else { throw AutomationIssue(.notConfirmed, "LG did not report its current mute state") }
                }
                guard state.generation == generation else { throw CancellationError() }
                let id = UUID().uuidString
                let reply = try await exchange(id: id, message: TVWireProtocol.lgMessage(action, id: id, muted: muted), generation: generation)
                guard case .reply(_, true, _, let inputs) = reply else {
                    let failed = TVCommandReceipt(.failed)
                    state.record(failed, action: action, generation: generation); changed()
                    return failed
                }
                if action == .refreshInputs, inputs == nil {
                    throw AutomationIssue(.notConfirmed, "LG did not return an input list")
                }
                receipt = TVCommandReceipt(.acknowledged, inputs: inputs)
            }
            guard state.generation == generation else { throw CancellationError() }
            state.record(receipt, action: action, generation: generation); changed()
            return receipt
        } catch let issue as AutomationIssue { throw issue }
        catch {
            throw AutomationIssue(.notConfirmed, "TV command was not confirmed; it may have reached the device. Reconnect explicitly; no command was retried.")
        }
    }

    private func handle(_ event: TVWireProtocol.Event, generation: UUID) throws {
        switch event {
        case .authorized(let token):
            // Late/duplicate authorization must never re-enable a denied or already-ready session.
            guard [.connecting, .waitingForPrompt, .waitingForPIN].contains(state.connection) else { return }
            do {
                var credential = try credentials.read(id: configuration.id) ?? TVCredential(token: nil, certificateSHA256: nil)
                if let token { credential.token = token }
                try credentials.write(credential, id: configuration.id)
            } catch { stop(to: .credentialFailure); return }
            pairingDeadline?.cancel(); pairingDeadline = nil
            pinRequestID = nil
            state.transition(.ready, generation: generation, paired: true); changed()
        case .prompt:
            if state.connection != .ready { state.transition(.waitingForPrompt, generation: generation); changed() }
        case .pin:
            if state.connection != .ready { state.transition(.waitingForPIN, generation: generation); changed() }
        case .authorizationDenied: stop(to: .authorizationDenied)
        case .manifestRejected: stop(to: .manifestRejected)
        case .reply(let id, let success, _, _):
            if id == pinRequestID {
                pinRequestID = nil
                if !success { stop(to: .authorizationDenied) }
                return
            }
            responseDeadlines.removeValue(forKey: id)?.cancel()
            pending.removeValue(forKey: id)?.resume(returning: event)
        case .ignored: break
        }
    }

    private func exchange(id: String, message: String, generation: UUID) async throws -> TVWireProtocol.Event {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                responseDeadlines[id] = Task { [weak self, wait, seconds = configuration.deadlines.response] in
                    do { try await wait(seconds) } catch { return }
                    guard let self, self.state.generation == generation else { return }
                    self.responseDeadlines.removeValue(forKey: id)
                    self.pending.removeValue(forKey: id)?.resume(throwing: AutomationIssue(.notConfirmed, "TV response deadline expired"))
                    self.stop(to: .unreachable)
                }
                Task { [weak self] in
                    guard let self, self.state.generation == generation, let socket = self.socket else { return }
                    do { try await socket.send(message) }
                    catch {
                        self.responseDeadlines.removeValue(forKey: id)?.cancel()
                        self.pending.removeValue(forKey: id)?.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.responseDeadlines.removeValue(forKey: id)?.cancel()
                self?.pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
                if self?.state.generation == generation { self?.stop(to: .pairedIdle) }
            }
        }
    }

    private func stop(to state: TVConnectionState) {
        reader?.cancel(); reader = nil
        pairingDeadline?.cancel(); pairingDeadline = nil
        wakeTask?.cancel(); wakeTask = nil
        socket?.close(); socket = nil
        pinRequestID = nil
        responseDeadlines.values.forEach { $0.cancel() }; responseDeadlines = [:]
        let continuations = pending.values; pending = [:]
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
        self.state.reset(to: state, paired: self.state.paired)
        changed()
    }

    private func changed() { onChange?(state) }
}
