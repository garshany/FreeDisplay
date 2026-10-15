#if os(macOS)
import AutomationSchema
import Combine
import Foundation
import Network

@MainActor final class TVDiscoveryAdapter: ObservableObject {
    @Published private(set) var state = TVDiscoveryState()
    private var group: NWConnectionGroup?
    private var deadline: Task<Void, Never>?
    private var sentGeneration: UUID?

    func search(_ request: TVDiscoveryRequest) throws {
        cancel()
        let descriptor = try NWMulticastGroup(for: [.hostPort(host: "239.255.255.250", port: 1900)])
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let group = NWConnectionGroup(with: descriptor, using: parameters)
        self.group = group
        let generation = state.begin()
        group.setReceiveHandler { [weak self] _, data, complete in
            guard complete, let data, let candidate = request.candidate(from: data) else { return }
            Task { @MainActor in self?.state.add(candidate, generation: generation) }
        }
        group.stateUpdateHandler = { [weak self] status in
            Task { @MainActor in
                guard let self, self.state.generation == generation else { return }
                switch status {
                case .ready:
                    guard self.sentGeneration != generation else { return }
                    self.sentGeneration = generation
                    group.send(content: request.searchPacket) { [weak self] error in
                        if error != nil { Task { @MainActor in self?.finish(generation, failed: true) } }
                    }
                case .failed: self.finish(generation, failed: true)
                default: break
                }
            }
        }
        deadline = Task { [weak self] in
            do { try await TVNetworkDelay.wait(request.window) } catch { return }
            self?.finish(generation, failed: false)
        }
        group.start(queue: .global())
    }
    func cancel() {
        deadline?.cancel(); deadline = nil
        group?.stateUpdateHandler = nil; group?.cancel(); group = nil
        state.cancel()
    }
    private func finish(_ generation: UUID, failed: Bool) {
        guard state.generation == generation else { return }
        deadline?.cancel(); deadline = nil
        group?.stateUpdateHandler = nil; group?.cancel(); group = nil
        state.finish(generation: generation, failed: failed)
    }
}
#endif
