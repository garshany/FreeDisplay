#if os(macOS)
import CoreGraphics
import DisplayDomain
import Foundation
import ProviderInterfaces
import Combine

@_silgen_name("ODVirtualDisplayAvailable") private func runtimeAvailable() -> Bool
@_silgen_name("ODVirtualDisplayCreate") private func runtimeCreate(
    _ name: UnsafePointer<CChar>, _ width: UInt32, _ height: UInt32,
    _ refresh: Double, _ serial: UInt32, _ hidpi: Bool) -> UnsafeRawPointer?
@_silgen_name("ODVirtualDisplayID") private func runtimeID(_ handle: UnsafeRawPointer) -> UInt32
@_silgen_name("ODVirtualDisplayRelease") private func runtimeRelease(_ handle: UnsafeRawPointer)

public struct VirtualDisplayProvider: DisplayProvider {
    public let providerID = "virtualDisplay.v1"
    public let isExperimental = true
    public init() {}
    public func probe(_ environment: ProviderEnvironment) async -> ProviderProbe {
        ProviderProbe(providerID: providerID, status: runtimeAvailable() ? .supported : .unsupported,
                      risk: .experimental, reasons: runtimeAvailable() ? [] : [.osVersion])
    }
}

/// Session-owned endpoints. No automatic startup restore: safe mode/crash restart creates none.
/// Does not alter physical modes, mirroring, main display or existing arrangements.
@MainActor public final class VirtualDisplaySession: ObservableObject {
    public struct Endpoint: Identifiable, Hashable {
        public var id: UUID { definition.id }
        public let definition: VirtualDisplayDefinition
        public let displayID: CGDirectDisplayID
    }
    private final class RuntimeHandle: @unchecked Sendable {
        let pointer: UnsafeRawPointer
        init(_ pointer: UnsafeRawPointer) { self.pointer = pointer }
        deinit { runtimeRelease(pointer) }
    }
    private var handles: [UUID: RuntimeHandle] = [:]
    private var inFlight = false
    @Published public private(set) var endpoints: [Endpoint] = []
    private var serial: UInt32 = UInt32.random(in: 1...UInt32.max / 2)
    public init() {}
    public var isAvailable: Bool { runtimeAvailable() }

    public func create(_ definition: VirtualDisplayDefinition, experimentalOptIn: Bool,
                       safeMode: Bool) async throws -> Endpoint {
        guard !inFlight else { throw ProviderFailure.busy }
        inFlight = true
        defer { inFlight = false }
        guard experimentalOptIn && !safeMode else { throw ProviderFailure.denied }
        if let error = definition.validationError { throw ProviderFailure.providerError(message: error) }
        guard handles[definition.id] == nil, endpoints.count < 4 else { throw ProviderFailure.busy }
        guard isAvailable else { throw ProviderFailure.unsupported(reason: []) }
        // A physical visible recovery surface must exist before adding an experimental endpoint.
        guard VirtualDisplaySafetyPolicy.canCreate(activeSurfaces: try activeSurfaces()) else {
            throw ProviderFailure.denied
        }
        serial &+= 1
        guard let handle = definition.name.withCString({ runtimeCreate($0, definition.pixelWidth,
            definition.pixelHeight, definition.refreshRate, serial, definition.hiDPI) }) else {
            throw ProviderFailure.providerError(message: "macOS отклонила параметры виртуального экрана.")
        }
        let displayID = runtimeID(handle)
        handles[definition.id] = RuntimeHandle(handle)
        // Yield while WindowServer publishes the endpoint. A call alone is never success.
        for _ in 0..<30 {
            do { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(100)) }
            catch { handles.removeValue(forKey: definition.id); throw error }
            if CGDisplayIsOnline(displayID) != 0, CGDisplayIsActive(displayID) != 0,
               let mode = CGDisplayCopyDisplayMode(displayID),
               mode.pixelWidth == Int(definition.pixelWidth), mode.pixelHeight == Int(definition.pixelHeight) {
                let endpoint = Endpoint(definition: definition, displayID: displayID)
                endpoints.append(endpoint)
                return endpoint
            }
        }
        handles.removeValue(forKey: definition.id)
        throw ProviderFailure.timeout
    }

    public func destroy(_ id: UUID) async throws {
        guard !inFlight else { throw ProviderFailure.busy }
        inFlight = true
        defer { inFlight = false }
        guard let displayID = handles[id].map({ runtimeID($0.pointer) }) else { return }
        guard VirtualDisplaySafetyPolicy.canRemove(displayID: displayID, activeSurfaces: try activeSurfaces()) else {
            throw ProviderFailure.denied
        }
        handles.removeValue(forKey: id)
        endpoints.removeAll { $0.id == id }
        for _ in 0..<30 {
            if CGDisplayIsOnline(displayID) == 0 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ProviderFailure.partial(message: "Экран освобождён, но macOS всё ещё считает его подключённым. При необходимости используйте восстановление.")
    }

    private func activeSurfaces() throws -> [VirtualDisplaySurface] {
        try activeIDs().map {
            VirtualDisplaySurface(displayID: $0, vendorID: CGDisplayVendorNumber($0),
                isBuiltIn: CGDisplayIsBuiltin($0) != 0, mirroredSourceID: CGDisplayMirrorsDisplay($0))
        }
    }

    private func activeIDs() throws -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 64)
        var count: UInt32 = 0
        let result = CGGetActiveDisplayList(UInt32(ids.count), &ids, &count)
        guard result == .success else { throw ProviderFailure.osRejected(code: Int(result.rawValue)) }
        return Array(ids.prefix(Int(count)))
    }
}
#endif
