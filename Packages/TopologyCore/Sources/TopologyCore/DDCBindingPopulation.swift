import DisplayDomain

/// A logically disconnected monitor still owns its I2C service. Count it even though Core
/// Graphics no longer enumerates it, without counting a mirrored/relit ledger entry twice.
public enum DDCBindingPopulation {
    public static func unobservedExternalCount(observations: [DisplayObservation],
                                               ledger: [ManagedOfflineDisplay]) -> Int {
        Set(ledger.filter { entry in
            entry.displayClass != .builtIn && entry.displayClass != .virtual
                && !observations.contains { ReconnectIdentity.isSameDisplay($0, as: entry) }
        }.map(\.recordID)).count
    }
}
