#if os(macOS)
import DisplayDomain
import ProviderInterfaces

/// Capability registration. CapturePanel owns explicitly initiated ScreenCaptureKit PIP sessions.
/// Probe deliberately remains unknown: permission and live delivery are assessed when the user
/// chooses a source. This provider never requests access during discovery/startup.
public struct CaptureProvider: DisplayProvider {
    public let providerID = "capture.v1"
    public let isExperimental = false

    public init() {}

    public func probe(_ environment: ProviderEnvironment) async -> ProviderProbe {
        ProviderProbe(providerID: providerID, status: .unknown, risk: .normal, reasons: [.permission])
    }
}
#endif
