import Foundation
import XCTest
@testable import AutomationSchema

@MainActor private final class MemoryTVCredentials: TVCredentialStore {
    var values: [UUID: TVCredential] = [:]
    var fails = false
    func read(id: UUID) throws -> TVCredential? {
        if fails { throw CancellationError() }; return values[id]
    }
    func write(_ credential: TVCredential, id: UUID) throws {
        if fails { throw CancellationError() }; values[id] = credential
    }
    func remove(id: UUID) throws {
        if fails { throw CancellationError() }; values[id] = nil
    }
}

private actor ManualTVClock {
    var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    func wait(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func fire() {
        let pending = waiters.values; waiters = [:]
        for waiter in pending { waiter.resume() }
    }
    var count: Int { waiters.count }
}

@MainActor private final class FakeTVSocket: TVSocket {
    var sent: [String] = []
    var messages: [String] = []
    var waiting: CheckedContinuation<String, any Error>?
    var closed = false
    var sendFails = false
    var onSend: (([String: Any]) throws -> Void)?
    func start() async throws {}
    func send(_ text: String) async throws {
        if sendFails { throw CancellationError() }
        sent.append(text)
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        try onSend?(object)
    }
    func receive() async throws -> String {
        if !messages.isEmpty { return messages.removeFirst() }
        if closed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func close() { closed = true; waiting?.resume(throwing: CancellationError()); waiting = nil }
    func push(_ text: String) {
        if let waiting { self.waiting = nil; waiting.resume(returning: text) }
        else { messages.append(text) }
    }
    func reply(_ value: [String: Any]) throws {
        push(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }
    func authorizeLG() {
        onSend = { [weak self] object in
            let id = object["id"] as! String
            if object["type"] as? String == "register" {
                try self?.reply(["type": "registered", "id": id, "payload": ["client-key": "fake-key"]])
            } else {
                try self?.reply(["type": "response", "id": id, "payload": ["returnValue": true, "muted": false,
                    "devices": [["id": "HDMI_1", "label": "Mac", "connected": true]]]])
            }
        }
    }
}

@MainActor final class TVControllerTests: XCTestCase {
    private func config(_ family: TVFamily = .lgWebOS, enabled: Bool = true) throws -> TVControllerConfiguration {
        TVControllerConfiguration(family: family, endpoint: try TVEndpoint(host: "tv.invalid", port: 3001, tls: true),
            deadlines: try TVDeadlines(connection: 17, response: 23, sessionLifetime: 47), enabled: enabled)
    }
    private func make(_ config: TVControllerConfiguration, socket: FakeTVSocket, credentials: MemoryTVCredentials,
                      clock: ManualTVClock = ManualTVClock(), wake: @escaping TVController.WakeSender = { _, _, _ in }) -> TVController {
        TVController(configuration: config, credentials: credentials, factory: { _, _ in socket },
                     wait: { try await clock.wait($0) }, wakeSender: wake)
    }
    private func state(_ wanted: TVConnectionState, controller: TVController, operation: () -> Void) async {
        await withCheckedContinuation { continuation in
            controller.onChange = { value in
                if value.connection == wanted { controller.onChange = nil; continuation.resume() }
            }
            operation()
        }
    }

    func testDisabledConfigurationStartsNoTransportAndRejectsCommands() async throws {
        let socket = FakeTVSocket()
        let controller = make(try config(enabled: false), socket: socket, credentials: MemoryTVCredentials())
        controller.connect()
        XCTAssertEqual(controller.state.connection, .disabled)
        XCTAssertFalse(controller.canPerform(.volumeUp))
        do { _ = try await controller.perform(.volumeUp); XCTFail() } catch { XCTAssertEqual(error.code, .capabilityUnavailable) }
        XCTAssertTrue(socket.sent.isEmpty)
    }

    func testLGPromptAuthorizationPersistsKeyAndIdlesWithoutForgetting() async throws {
        let socket = FakeTVSocket(); socket.authorizeLG()
        let credentials = MemoryTVCredentials(); let config = try config()
        let controller = make(config, socket: socket, credentials: credentials)
        await state(.ready, controller: controller) { controller.connect() }
        XCTAssertEqual(credentials.values[config.id]?.token, "fake-key")
        XCTAssertTrue(controller.state.paired)
        controller.disconnect()
        XCTAssertEqual(controller.state.connection, .pairedIdle)
        XCTAssertTrue(socket.closed)
        XCTAssertEqual(credentials.values[config.id]?.token, "fake-key")
    }

    func testPINPairingWaitsForRegisteredAndCanBeCancelled() async throws {
        let socket = FakeTVSocket(); let credentials = MemoryTVCredentials()
        var config = try config(); config.requirePIN = true
        let controller = make(config, socket: socket, credentials: credentials)
        var registration = ""
        socket.onSend = { object in
            if object["type"] as? String == "register" {
                registration = object["id"] as! String
            } else {
                try socket.reply(["type": "registered", "id": registration, "payload": ["client-key": "pin-key"]])
            }
        }
        await state(.waitingForPIN, controller: controller) { controller.connect() }
        XCTAssertFalse(controller.canPerform(.volumeDown))
        await withCheckedContinuation { continuation in
            controller.onChange = { value in
                if value.connection == .ready { controller.onChange = nil; continuation.resume() }
            }
            Task { try await controller.submitPIN("1234") }
        }
        XCTAssertEqual(credentials.values[config.id]?.token, "pin-key")
        try controller.deletePairing()
        XCTAssertNil(credentials.values[config.id])
        XCTAssertEqual(controller.state.connection, .configured)
        XCTAssertFalse(controller.state.paired)
    }

    func testLGRegistrationDenialAndManifestRejectionAreIndependent() async throws {
        for (error, expected) in [("403 rejected", TVConnectionState.authorizationDenied), ("invalid manifest", .manifestRejected)] {
            let socket = FakeTVSocket()
            socket.onSend = { object in try socket.reply(["type": "error", "id": object["id"]!, "error": error]) }
            let controller = make(try config(), socket: socket, credentials: MemoryTVCredentials())
            await state(expected, controller: controller) { controller.connect() }
            XCTAssertFalse(controller.canPerform(.volumeUp))
            XCTAssertTrue(socket.closed)
        }
    }

    func testAuthorizationDenialIsNotConnectionDeadline() async throws {
        let denied = FakeTVSocket(); denied.messages = ["{\"event\":\"ms.channel.unauthorized\"}"]
        let controller = make(try config(.samsungTizen), socket: denied, credentials: MemoryTVCredentials())
        await state(.authorizationDenied, controller: controller) { controller.connect() }
        let idle = FakeTVSocket(); let clock = ManualTVClock()
        let unreachable = make(try config(.samsungTizen), socket: idle, credentials: MemoryTVCredentials(), clock: clock)
        await state(.waitingForPrompt, controller: unreachable) { unreachable.connect() }
        while await clock.count == 0 { await Task.yield() }
        await withCheckedContinuation { continuation in
            unreachable.onChange = { value in
                if value.connection == .unreachable { unreachable.onChange = nil; continuation.resume() }
            }
            Task { await clock.fire() }
        }
        XCTAssertTrue(idle.closed)
    }

    func testCredentialFailureDoesNotExposeReadyCommands() async throws {
        let socket = FakeTVSocket(); socket.authorizeLG()
        let credentials = MemoryTVCredentials()
        socket.onSend = { object in
            credentials.fails = true
            try socket.reply(["type": "registered", "id": object["id"]!, "payload": ["client-key": "lost"]])
        }
        let controller = make(try config(), socket: socket, credentials: credentials)
        await state(.credentialFailure, controller: controller) { controller.connect() }
        XCTAssertFalse(controller.canPerform(.volumeDown))
    }

    func testLGInputIdentityMustBeReportedAndSendRemainsRequested() async throws {
        let socket = FakeTVSocket(); socket.authorizeLG()
        let controller = make(try config(), socket: socket, credentials: MemoryTVCredentials())
        await state(.ready, controller: controller) { controller.connect() }
        XCTAssertFalse(controller.canPerform(.switchInput("HDMI_1")))
        let inputs = try await controller.perform(.refreshInputs)
        XCTAssertEqual(inputs.inputs?.map(\.id), ["HDMI_1"])
        XCTAssertTrue(controller.canPerform(.switchInput("HDMI_1")))
        XCTAssertFalse(controller.canPerform(.switchInput("HDMI_2")))
        let receipt = try await controller.perform(.switchInput("HDMI_1"))
        XCTAssertEqual(receipt.delivery, .acknowledged)
        XCTAssertEqual(controller.state.requestedInput, "HDMI_1")
        controller.disconnect()
        XCTAssertTrue(controller.state.inputs.isEmpty)
    }

    func testDeniedInputDoesNotChangeRequestedInputOrDisableOtherKeys() async throws {
        let socket = FakeTVSocket(); socket.authorizeLG()
        let controller = make(try config(), socket: socket, credentials: MemoryTVCredentials())
        await state(.ready, controller: controller) { controller.connect() }
        _ = try await controller.perform(.refreshInputs)
        socket.onSend = { object in try socket.reply(["type": "error", "id": object["id"]!, "error": "403 denied"]) }
        let receipt = try await controller.perform(.switchInput("HDMI_1"))
        XCTAssertEqual(receipt.delivery, .failed)
        XCTAssertNil(controller.state.requestedInput)
        XCTAssertTrue(controller.canPerform(.volumeDown))
        XCTAssertEqual(controller.state.connection, .ready)
        controller.disconnect()
    }

    func testLGMuteReadsStateBeforeSendingToggle() async throws {
        let socket = FakeTVSocket(); socket.authorizeLG()
        let controller = make(try config(), socket: socket, credentials: MemoryTVCredentials())
        await state(.ready, controller: controller) { controller.connect() }
        _ = try await controller.perform(.muteToggle)
        XCTAssertEqual(socket.sent.count, 3)
        let read = try JSONSerialization.jsonObject(with: Data(socket.sent[1].utf8)) as! [String: Any]
        let write = try JSONSerialization.jsonObject(with: Data(socket.sent[2].utf8)) as! [String: Any]
        XCTAssertEqual(read["uri"] as? String, "ssap://audio/getVolume")
        XCTAssertEqual(write["uri"] as? String, "ssap://audio/setMute")
        XCTAssertTrue(socket.sent[2].contains("\"mute\":true"))
        controller.disconnect()
    }

    func testUnknownMuteDoesNotSendAnInventedToggle() async throws {
        let socket = FakeTVSocket(); socket.authorizeLG()
        let controller = make(try config(), socket: socket, credentials: MemoryTVCredentials())
        await state(.ready, controller: controller) { controller.connect() }
        socket.onSend = { object in try socket.reply(["type": "response", "id": object["id"]!, "payload": ["returnValue": true]]) }
        do { _ = try await controller.perform(.muteToggle); XCTFail() } catch { XCTAssertEqual(error.code, .notConfirmed) }
        XCTAssertEqual(socket.sent.count, 2)
        controller.disconnect()
    }

    func testSamsungRelativeVolumeHasNoInputListAndNoConfirmationClaim() async throws {
        let socket = FakeTVSocket(); socket.messages = ["{\"event\":\"ms.channel.connect\",\"data\":{\"token\":\"fake-token\"}}"]
        let credentials = MemoryTVCredentials(); let config = try config(.samsungTizen)
        let controller = make(config, socket: socket, credentials: credentials)
        await state(.ready, controller: controller) { controller.connect() }
        let receipt = try await controller.perform(.volumeUp)
        XCTAssertEqual(receipt.delivery, .sent)
        XCTAssertFalse(controller.canPerform(.refreshInputs))
        XCTAssertFalse(controller.canPerform(.switchInput("HDMI_1")))
        XCTAssertTrue(controller.canPerform(.source))
        XCTAssertEqual(controller.capabilities.family, .samsungTizen)
        XCTAssertTrue(controller.capabilities.authorizedSession)
        XCTAssertTrue(controller.capabilities.actions.contains("volumeUp"))
        XCTAssertFalse(controller.capabilities.actions.contains("switchInput"))
        XCTAssertEqual(controller.capabilities.featureOutcomes["volumeUp"]?.delivery, .sent)
        XCTAssertEqual(credentials.values[config.id]?.token, "fake-token")
        XCTAssertEqual(socket.sent.count, 1)
        controller.disconnect()
    }

    func testEndpointEditClosesOldSessionAndInvalidatesSamsungToken() async throws {
        let socket = FakeTVSocket(); socket.messages = ["{\"event\":\"ms.channel.connect\",\"data\":{\"token\":\"old\"}}"]
        let credentials = MemoryTVCredentials(); var config = try config(.samsungTizen)
        let controller = make(config, socket: socket, credentials: credentials)
        await state(.ready, controller: controller) { controller.connect() }
        let generation = controller.state.generation
        config.endpoint = try TVEndpoint(host: "other.invalid", port: 8002, tls: true)
        try controller.update(config)
        XCTAssertTrue(socket.closed)
        XCTAssertNotEqual(controller.state.generation, generation)
        XCTAssertFalse(controller.canPerform(.powerOff))
        XCTAssertNil(credentials.values[config.id])
    }

    func testLGDHCPChangePreservesCredentialAndIndependentWakeMAC() async throws {
        let socket = FakeTVSocket(); socket.authorizeLG()
        let credentials = MemoryTVCredentials(); var config = try config()
        let mac = try TVMACAddress("02:11:22:33:44:55")
        config.wake = TVWakeConfiguration(mac: mac, destination: try TVEndpoint(host: "255.255.255.255", port: 9, tls: false))
        let controller = make(config, socket: socket, credentials: credentials)
        await state(.ready, controller: controller) { controller.connect() }
        config.endpoint = try TVEndpoint(host: "new-address.invalid", port: 3001, tls: true)
        try controller.update(config)
        XCTAssertEqual(credentials.values[config.id]?.token, "fake-key")
        XCTAssertEqual(controller.configuration.wake?.mac, mac)
        XCTAssertTrue(controller.canPerform(.wake))
        XCTAssertEqual(controller.capabilities.actions, ["wake"])
    }

    func testRemoveRetainsSettingsAndKeyWithoutClaimingRemoteRevocation() async throws {
        let socket = FakeTVSocket(); socket.authorizeLG()
        let credentials = MemoryTVCredentials(); let config = try config()
        let controller = make(config, socket: socket, credentials: credentials)
        await state(.ready, controller: controller) { controller.connect() }
        controller.remove()
        XCTAssertEqual(controller.state.connection, .disabled)
        XCTAssertEqual(controller.configuration.endpoint, config.endpoint)
        XCTAssertEqual(credentials.values[config.id]?.token, "fake-key")
        XCTAssertFalse(controller.canPerform(.powerOff))
    }

    func testWOLDoesNotNeedPairedSessionAndNeverClaimsWakeObserved() async throws {
        var config = try config(); let mac = try TVMACAddress("02:ab:cd:ef:01:23")
        let destination = try TVEndpoint(host: "broadcast.invalid", port: 9, tls: false)
        config.wake = TVWakeConfiguration(mac: mac, destination: destination)
        var packets: [Data] = []
        let socket = FakeTVSocket()
        let controller = make(config, socket: socket, credentials: MemoryTVCredentials(), wake: { packet, endpoint, seconds in
            packets.append(packet); XCTAssertEqual(endpoint, destination); XCTAssertEqual(seconds, 23)
        })
        let receipt = try await controller.perform(.wake)
        XCTAssertEqual(receipt.delivery, .sent)
        XCTAssertEqual(packets, [mac.magicPacket])
        XCTAssertTrue(socket.sent.isEmpty)
        XCTAssertNotEqual(controller.state.connection, .ready)
    }

    func testFailedSubmissionDoesNotRetryNonIdempotentMute() async throws {
        let socket = FakeTVSocket(); socket.messages = ["{\"event\":\"ms.channel.connect\"}"]
        let controller = make(try config(.samsungTizen), socket: socket, credentials: MemoryTVCredentials())
        await state(.ready, controller: controller) { controller.connect() }
        socket.sendFails = true
        do { _ = try await controller.perform(.muteToggle); XCTFail() } catch { XCTAssertEqual(error.code, .notConfirmed) }
        XCTAssertTrue(socket.sent.isEmpty)
        controller.disconnect()
    }

    func testResponseDeadlineCancelsSessionAndNeverRetries() async throws {
        let socket = FakeTVSocket(); socket.authorizeLG()
        let clock = ManualTVClock()
        let controller = make(try config(), socket: socket, credentials: MemoryTVCredentials(), clock: clock)
        await state(.ready, controller: controller) { controller.connect() }
        while await clock.count != 0 { await Task.yield() }
        var command: Task<TVCommandReceipt, any Error>!
        await withCheckedContinuation { continuation in
            socket.onSend = { _ in continuation.resume() }
            command = Task { try await controller.perform(.volumeUp) }
        }
        while await clock.count == 0 { await Task.yield() }
        await withCheckedContinuation { continuation in
            controller.onChange = { value in
                if value.connection == .unreachable { controller.onChange = nil; continuation.resume() }
            }
            Task { await clock.fire() }
        }
        do { _ = try await command.value; XCTFail() }
        catch { XCTAssertEqual((error as? AutomationIssue)?.code, .notConfirmed) }
        XCTAssertTrue(socket.closed)
        XCTAssertEqual(socket.sent.count, 2)
        XCTAssertFalse(controller.canPerform(.volumeUp))
    }

    func testConcurrentCommandRefusesAndCancellationInvalidatesPendingWork() async throws {
        let socket = FakeTVSocket(); socket.authorizeLG()
        let controller = make(try config(), socket: socket, credentials: MemoryTVCredentials())
        await state(.ready, controller: controller) { controller.connect() }
        var command: Task<TVCommandReceipt, any Error>!
        await withCheckedContinuation { continuation in
            socket.onSend = { _ in continuation.resume() }
            command = Task { try await controller.perform(.powerOff) }
        }
        do { _ = try await controller.perform(.muteToggle); XCTFail() }
        catch { XCTAssertEqual(error.code, .busy) }
        command.cancel()
        do { _ = try await command.value; XCTFail() } catch {}
        XCTAssertEqual(socket.sent.count, 2)
        XCTAssertTrue(socket.closed)
        XCTAssertEqual(controller.state.connection, .pairedIdle)
    }

    func testReconnectUsesSavedLGKeyAndDoesNotSendAPowerCommand() async throws {
        let socket = FakeTVSocket(); socket.authorizeLG()
        let credentials = MemoryTVCredentials(); let config = try config()
        credentials.values[config.id] = TVCredential(token: "saved-key", certificateSHA256: nil)
        let controller = make(config, socket: socket, credentials: credentials)
        await state(.ready, controller: controller) { controller.connect() }
        let register = try JSONSerialization.jsonObject(with: Data(socket.sent[0].utf8)) as! [String: Any]
        XCTAssertEqual((register["payload"] as? [String: Any])?["client-key"] as? String, "saved-key")
        XCTAssertEqual(socket.sent.count, 1)
        controller.disconnect()
    }

    func testPendingWakeIsCancelledWhenConfigurationChanges() async throws {
        let clock = ManualTVClock()
        var config = try config()
        config.wake = TVWakeConfiguration(mac: try TVMACAddress("02:11:22:33:44:55"),
            destination: try TVEndpoint(host: "wake.invalid", port: 9, tls: false))
        let controller = make(config, socket: FakeTVSocket(), credentials: MemoryTVCredentials(),
                              wake: { _, _, _ in try await clock.wait(23) })
        let command = Task { try await controller.perform(.wake) }
        while await clock.count == 0 { await Task.yield() }
        config.endpoint = try TVEndpoint(host: "new.invalid", port: 3001, tls: true)
        try controller.update(config)
        do { _ = try await command.value; XCTFail() }
        catch { XCTAssertEqual((error as? AutomationIssue)?.code, .notConfirmed) }
        XCTAssertTrue(controller.state.featureOutcomes.isEmpty)
    }

    func testQuitDisconnectCancelsPendingWakeWithoutDeletingConfiguration() async throws {
        let clock = ManualTVClock()
        var configuration = try config()
        configuration.wake = TVWakeConfiguration(mac: try TVMACAddress("02:11:22:33:44:55"),
            destination: try TVEndpoint(host: "wake.invalid", port: 9, tls: false))
        let controller = make(configuration, socket: FakeTVSocket(), credentials: MemoryTVCredentials(),
                              wake: { _, _, _ in try await clock.wait(23) })
        let command = Task { try await controller.perform(.wake) }
        while await clock.count == 0 { await Task.yield() }
        controller.disconnect()
        do { _ = try await command.value; XCTFail("Quit must invalidate pending WOL") }
        catch { XCTAssertEqual((error as? AutomationIssue)?.code, .notConfirmed) }
        XCTAssertEqual(controller.configuration, configuration)
        XCTAssertTrue(controller.state.featureOutcomes.isEmpty)
    }

    func testRejectedPINIsAuthorizationFailureAndDoesNotPersistAKey() async throws {
        let socket = FakeTVSocket(); let credentials = MemoryTVCredentials()
        var config = try config(); config.requirePIN = true
        let controller = make(config, socket: socket, credentials: credentials)
        socket.onSend = { object in
            if object["type"] as? String != "register" {
                try socket.reply(["type": "error", "id": object["id"]!, "error": "invalid pin"])
            }
        }
        await state(.waitingForPIN, controller: controller) { controller.connect() }
        await withCheckedContinuation { continuation in
            controller.onChange = { value in
                if value.connection == .authorizationDenied { controller.onChange = nil; continuation.resume() }
            }
            Task { try await controller.submitPIN("1234") }
        }
        XCTAssertFalse(controller.canPerform(.volumeUp))
        XCTAssertNil(credentials.values[config.id])
        XCTAssertTrue(socket.closed)
    }
}
