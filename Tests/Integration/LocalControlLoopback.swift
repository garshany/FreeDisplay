// SPDX-License-Identifier: GPL-3.0-or-later
// Synthetic providers only. Never enumerates or mutates real displays.
import Foundation
import Darwin
import AutomationSchema
import DisplayDomain
import SimulatorProvider
import TopologyCore

@main
@MainActor
struct LocalControlLoopback {
    final class Probe {
        var calls = 0
        var slow = false
        var entered = false
        var cancelled = false
    }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "LoopbackAssertion", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func request(_ method: String = "POST", _ path: String = "/v1/reconnect-all",
                        token: String, body: String = "{}", extra: String = "") -> Data {
        Data("\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\(extra)\r\n\(body)".utf8)
    }
    static func exchange(port: UInt16, bytes: Data) async -> Data {
        await Task.detached {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return Data() }
            defer { close(fd) }
            var timeout = timeval(tv_sec: 7, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { return Data() }
            let sent = bytes.withUnsafeBytes { send(fd, $0.baseAddress, bytes.count, 0) }
            guard sent == bytes.count else { return Data() }
            var response = Data()
            var buffer = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = recv(fd, &buffer, buffer.count, 0)
                if n <= 0 { break }
                response.append(contentsOf: buffer.prefix(n))
            }
            return response
        }.value
    }
    static func ready(_ server: LocalControlServer) async throws -> (UInt16, String) {
        for _ in 0..<100 {
            if let port = server.port, let token = server.token { return (port, token) }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "LoopbackAssertion", code: 2)
    }
    static func status(_ data: Data) -> Int? {
        Int(String(decoding: data, as: UTF8.self).components(separatedBy: " ").dropFirst().first ?? "")
    }
    static func main() async throws {
        let system = SimulatedDisplaySystem(observations: [])
        let gateway = CommandGateway(observer: system, lifecycleProvider: system, checkpoints: InMemoryCheckpointStore())
        let server = LocalControlServer()
        let probe = Probe()
        let handler: LocalControlServer.Handler = { command in
            probe.calls += 1
            if probe.slow {
                probe.entered = true
                do { try await Task.sleep(for: .seconds(30)) }
                catch { probe.cancelled = true; return Data() }
            }
            switch command {
            case .displays: return Data("{\"displays\":[{\"id\":\"synthetic\"}]}".utf8)
            case .brightness(let id, let value):
                return Data("{\"displayId\":\"\(id)\",\"value\":\(value),\"status\":\"requested\"}".utf8)
            case .reconnectAll:
                // Synthetic recovery: the app hands this route to its live model; here the
                // synthetic system's gateway stands in for it and answers with its envelope.
                let envelope = await gateway.reconnectAll(actor: .httpAPI)
                return (try? JSONEncoder().encode(envelope)) ?? Data("{}".utf8)
            default: return Data("{}".utf8)
            }
        }
        try require(server.port == nil && server.token == nil, "Construction must stay stopped")
        try server.start(handler: handler)
        let (port, token) = try await ready(server)
        try require(token.count == 64, "Session token size")
        try server.start(handler: handler)
        try require(server.token == token, "Duplicate start must preserve session")
        let unauthorized = await exchange(port: port, bytes: request(token: "invalid"))
        try require(status(unauthorized) == 401 && probe.calls == 0, "Wrong token must never dispatch")
        let list = await exchange(port: port, bytes: request("GET", "/v1/displays", token: token, body: ""))
        try require(status(list) == 200 && String(decoding: list, as: UTF8.self).contains("synthetic"), "Read-only list endpoint")
        let brightness = await exchange(port: port, bytes: request("POST", "/v1/brightness", token: token, body: "{\"displayId\":\"synthetic\",\"value\":0.4}"))
        try require(status(brightness) == 200 && probe.calls == 2, "Typed brightness dispatch")
        for body in ["{\"displayId\":\"synthetic\",\"value\":true}", "{\"displayId\":\"synthetic\",\"value\":2}"] {
            let invalid = await exchange(port: port, bytes: request("POST", "/v1/brightness", token: token, body: body))
            try require(status(invalid) == 400 && probe.calls == 2, "Invalid brightness must not dispatch")
        }
        let recovery = await exchange(port: port, bytes: request(token: token))
        try require(status(recovery) == 200 && probe.calls == 3
                    && String(decoding: recovery, as: UTF8.self).contains("noOp"), "Synthetic gateway recovery envelope")
        let unknown = await exchange(port: port, bytes: request("POST", "/v1/disconnect", token: token))
        try require(status(unknown) == 404, "Unknown/destructive endpoint")
        let origin = await exchange(port: port, bytes: request(token: token, extra: "Origin: https://example.com\r\n"))
        try require(status(origin) == 400, "Browser Origin rejected")
        let hugeBody = await exchange(port: port, bytes: request(token: token, body: String(repeating: "x", count: 257)))
        try require(status(hugeBody) == 400, "Body length limit")
        let hugeRequest = await exchange(port: port, bytes: Data(repeating: 65, count: 8193))
        try require(status(hugeRequest) == 413, "Total request limit")
        let before = Date()
        let idle = await exchange(port: port, bytes: Data("POST ".utf8))
        try require(idle.isEmpty && Date().timeIntervalSince(before) < 7, "Incomplete connection deadline")
        probe.slow = true
        let pending = Task { await exchange(port: port, bytes: request("GET", "/v1/displays", token: token, body: "")) }
        for _ in 0..<100 where !probe.entered { try await Task.sleep(for: .milliseconds(10)) }
        try require(probe.entered, "In-flight handler entered")
        server.stop()
        let cancelledResponse = await pending.value
        for _ in 0..<100 where !probe.cancelled { try await Task.sleep(for: .milliseconds(10)) }
        try require(cancelledResponse.isEmpty && probe.cancelled, "Stop cancels in-flight cooperative handler")
        try require(server.port == nil && server.token == nil, "Stop clears credentials")
        probe.slow = false
        try server.start(handler: handler)
        let (newPort, newToken) = try await ready(server)
        try require(newToken != token, "Restart rotates token")
        let oldAuth = await exchange(port: newPort, bytes: request(token: token))
        try require(status(oldAuth) == 401, "Previous token rejected after restart")
        let restarted = await exchange(port: newPort, bytes: request("GET", "/v1/displays", token: newToken, body: ""))
        try require(status(restarted) == 200, "Restart serves authenticated list")
        server.stop(); server.stop()
        try server.start(handler: handler)
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        try require(server.port == nil && server.token == nil, "Stop before readiness cannot revive listener")
        print("PASS: synthetic loopback lifecycle, auth, list, brightness, recovery, limits, timeout, cancellation and restart")
    }
}
