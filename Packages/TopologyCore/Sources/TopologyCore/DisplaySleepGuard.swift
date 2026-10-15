import DisplayDomain
import Foundation

/// Creates and releases the OS "prevent display idle-sleep" power assertion. The concrete macOS
/// implementation (in the app) wraps `IOPMAssertionCreateWithName` /
/// `kIOPMAssertionTypePreventUserIdleDisplaySleep` / `IOPMAssertionRelease`; tests inject a fake.
///
/// `createPreventDisplaySleepAssertion` returns an opaque handle (the IOKit `IOPMAssertionID`, a
/// `UInt32`) or `nil` if the OS refused — callers must tolerate a `nil` handle and simply not hold an
/// assertion, never crash.
public protocol PowerAssertionControlling: Sendable {
    func createPreventDisplaySleepAssertion(named name: String) -> UInt32?
    func releaseAssertion(_ handle: UInt32)
}

/// Holds **at most one** "prevent display idle-sleep" assertion. What decides it is the pure
/// `DisplaySleepPrevention` policy (which lit displays own it, `apply(_:)`), or for older callers
/// the two-input form `enabled && externalPresent` (`update(enabled:externalPresent:)`). The side
/// effect is delegated to a `PowerAssertionControlling` backend so the lifecycle is unit-testable
/// off-device.
///
/// Reconciliation is idempotent: re-applying the same effective state is a no-op, so the guard never
/// double-creates or leaks an assertion across connect/disconnect cycles. `releaseAll()` (also called
/// from `deinit`) guarantees the assertion never outlives the guard, covering app teardown/relaunch.
///
/// Not `Sendable`: it holds mutable state and is meant to be driven from a single actor (the app's
/// `@MainActor` model). Tests drive it synchronously.
public final class DisplaySleepGuard {
    /// What the guard is doing about the assertion, for the UI and diagnostics.
    public enum Status: Hashable, Sendable {
        /// Nothing asks for it, and none is held.
        case released
        /// Held, under this IOKit assertion id.
        case held(assertionID: UInt32)
        /// Asked for, but macOS refused to create it. Tried again on the next reconcile.
        case refused
    }

    /// The name macOS shows for the assertion (`pmset -g assertions`). It says whose it is and that
    /// it covers idle display sleep only, so it can't be mistaken for another app's or a system one.
    public static let defaultAssertionName = "FreeDisplay: keeping displays awake (idle display sleep only)"

    private let backend: any PowerAssertionControlling
    private let assertionName: String
    private var handle: UInt32?
    private var wanted = false

    /// The displays the assertion is held for, as last applied. Empty after `update` or a release.
    public private(set) var owners: [DisplayRecordID] = []

    public init(
        backend: any PowerAssertionControlling,
        assertionName: String = DisplaySleepGuard.defaultAssertionName
    ) {
        self.backend = backend
        self.assertionName = assertionName
    }

    /// True while an OS assertion is currently held.
    public var isHoldingAssertion: Bool { handle != nil }

    /// The effective decision: whether the assertion should be held right now.
    public var shouldHold: Bool { wanted }

    public var status: Status {
        if let handle { return .held(assertionID: handle) }
        return wanted ? .refused : .released
    }

    /// Re-evaluate against the latest feature toggle and external-presence state, creating or
    /// releasing the single assertion as needed. Safe to call on every topology change and every
    /// settings change — repeated calls with an unchanged effective state do nothing.
    public func update(enabled: Bool, externalPresent: Bool) {
        owners = []
        wanted = enabled && externalPresent
        reconcile()
    }

    /// Holds the assertion exactly while `decision` names an owner. A change of owners while it is
    /// held keeps the same assertion — one display handing over to another must not drop the
    /// displays into idle sleep for an instant.
    public func apply(_ decision: DisplaySleepPrevention.Decision) {
        owners = decision.owners
        wanted = decision.shouldHold
        reconcile()
    }

    private func reconcile() {
        if shouldHold {
            guard handle == nil else { return }
            handle = backend.createPreventDisplaySleepAssertion(named: assertionName)
        } else {
            guard let held = handle else { return }
            backend.releaseAssertion(held)
            handle = nil
        }
    }

    /// Release any held assertion and forget it. Idempotent. Call on app teardown so the assertion
    /// can never outlive the process. A later `update`/`apply` may take it again.
    public func releaseAll() {
        wanted = false
        owners = []
        guard let held = handle else { return }
        backend.releaseAssertion(held)
        handle = nil
    }

    deinit { releaseAll() }
}
