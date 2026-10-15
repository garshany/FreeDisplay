import DisplayDomain
import Foundation

/// Unlike an export, this recovery snapshot includes live restore ledgers and managed-offline
/// state. It is retained even after rollback so a failing filesystem cannot destroy the only copy.
public struct DisplaySettingsRecoverySnapshot: Codable, Hashable, Sendable {
    public var settings: OpenDisplaySettings
    public var favorites: FavoriteResolutions
    public var menuLayout: MenuLayoutSettings
    public var managedOffline: [ManagedOfflineDisplay]
    public var registry: RegistryState

    public init(settings: OpenDisplaySettings, favorites: FavoriteResolutions, menuLayout: MenuLayoutSettings,
                managedOffline: [ManagedOfflineDisplay], registry: RegistryState) {
        self.settings = settings
        self.favorites = favorites
        self.menuLayout = menuLayout
        self.managedOffline = managedOffline
        self.registry = registry
    }
}

public enum DisplaySettingsTransaction {
    public enum Step: CaseIterable, Sendable {
        case settings, favorites, menuLayout, managedOffline, registry
    }

    public struct StateChanged: Error {
        public init() {}
    }

    /// Call on the owning actor after the final suspension. Persistence and publication must not
    /// yield: even an unchanged-state save during registry I/O may have overwritten staged files.
    public static func commitIfUnchanged<Value: Equatable>(expected: Value, current: Value,
                                                           persist: () throws -> Void,
                                                           publish: () -> Void) throws {
        guard current == expected else { throw StateChanged() }
        try persist()
        publish()
    }

    public struct Failure: Error {
        public var underlying: any Error
        public var recoveryURL: URL
        public var restored: Bool
    }

    /// Registry removal is last. The failing step is rolled back too: a backend may publish memory
    /// before its save throws. Each rollback is independent; one failure must not skip the others.
    public static func run(isolation: isolated (any Swift.Actor)? = #isolation,
                           snapshot: DisplaySettingsRecoverySnapshot, recoveryURL: URL,
                           write: (Step) async throws -> Void,
                           commit: () throws -> Void = {},
                           restore: (Step) async throws -> Void) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: recoveryURL, options: .atomic)
        var reached: [Step] = []
        do {
            for step in Step.allCases {
                reached.append(step)
                try await write(step)
            }
            try commit()
        } catch {
            var restored = true
            for step in reached.reversed() {
                do { try await restore(step) } catch { restored = false }
            }
            throw Failure(underlying: error, recoveryURL: recoveryURL, restored: restored)
        }
    }
}
