/// Ownership is decided at the initial press. An unhandled held key must not suddenly be stolen
/// on a repeat after the pointer/output/preferences change. Permission loss releases everything.
public struct NativeKeySequence: Sendable {
    public enum Key: Hashable, Sendable {
        case media(MediaKeyAction)
        case function(UInt16)
    }

    private var owned: [Key: Bool] = [:]

    public init() {}

    public mutating func press(_ key: Key, isRepeat: Bool, permissionGranted: Bool,
                                handle: () -> Bool) -> Bool {
        guard permissionGranted else { cancel(); return false }
        if isRepeat {
            guard owned[key] == true else { return false }
            _ = handle()
            return true
        }
        let consumed = handle()
        owned[key] = consumed
        return consumed
    }

    public mutating func release(_ key: Key, permissionGranted: Bool) -> Bool {
        guard permissionGranted else { cancel(); return false }
        return owned.removeValue(forKey: key) == true
    }

    public mutating func cancel() { owned.removeAll() }

    public mutating func cancel(_ key: Key) { owned[key] = nil }
}
