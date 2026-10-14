// Standalone no-hardware harness compiled alongside provider sources, not the app target.
import DisplayDomain
import Foundation
import ProviderInterfaces

@main struct SessionGuardTests {
    @MainActor static func main() async throws {
        let session = VirtualDisplaySession()
        let provider = VirtualDisplayProvider()
        let probe = await provider.probe(ProviderEnvironment(osBuild: "guard-test", isAppleSilicon: true,
                                                            transport: .unknown, displayClass: .virtual))
        precondition(probe.providerID == provider.providerID && provider.isExperimental)
        precondition(probe.status == (session.isAvailable ? .supported : .unsupported))
        precondition(probe.risk == .experimental)
        let valid = VirtualDisplayDefinition(name: "Guard test")
        for (optIn, safeMode) in [(false, false), (false, true), (true, true)] {
            do {
                _ = try await session.create(valid, experimentalOptIn: optIn, safeMode: safeMode)
                fatalError("Creation crossed the policy guard")
            } catch ProviderFailure.denied { }
        }
        do {
            _ = try await session.create(VirtualDisplayDefinition(name: "Invalid", pixelWidth: 0),
                                         experimentalOptIn: true, safeMode: false)
            fatalError("Invalid definition crossed validation")
        } catch ProviderFailure.providerError { }
        // Refusal must leave the session usable and empty; nonexistent removal is idempotent.
        try await session.destroy(UUID())
        try await session.destroy(UUID())
        precondition(session.endpoints.isEmpty)
        print("9 virtual session policy/validation/idempotency checks passed; no endpoint requested.")
    }
}
