import Foundation

/// Revocation follows a request across actor, queue and group-follower boundaries. A child can
/// be cancelled independently; revoking its parent also refuses every not-yet-dispatched child.
public final class WriteAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    private let parent: WriteAuthorization?

    public init(parent: WriteAuthorization? = nil) { self.parent = parent }
    public func revoke() { lock.lock(); revoked = true; lock.unlock() }
    public var isAuthorized: Bool {
        lock.lock(); let allowed = !revoked; lock.unlock()
        return allowed && (parent?.isAuthorized ?? true)
    }
}
