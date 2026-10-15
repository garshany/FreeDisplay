#if os(macOS)
import AppKit
import TopologyCore

/// Applies the Dock icon policy (SO-13/FB-15) to the running app. The bundle stays a menu-bar
/// agent (`LSUIElement`); this only switches the activation policy between `.accessory` and
/// `.regular`, so windows, the menu-bar item and any running capture are never recreated — the
/// Dock icon simply appears or goes. Re-evaluated whenever an app window opens, closes, is
/// minimised or restored, and whenever the policy changes.
///
/// "A window" is any titled window this process shows: Settings, About, a picture-in-picture
/// capture, the notice window, an update or open/save panel. The tray panel, OSD and overlays
/// are borderless and never count. A minimised window counts as open — it lives in the Dock.
@MainActor
final class DockPresenceController {
    var policy: DockIconPolicy {
        didSet { if policy != oldValue { update() } }
    }
    private let isSettingsWindow: (NSWindow) -> Bool
    private var observers: [NSObjectProtocol] = []

    init(policy: DockIconPolicy, isSettingsWindow: @escaping (NSWindow) -> Bool) {
        self.policy = policy
        self.isSettingsWindow = isSettingsWindow
        let center = NotificationCenter.default
        let changes: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification, NSApplication.didUnhideNotification,
        ]
        for name in changes {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        // `willClose` arrives while the window is still visible, so it is left out of the count by
        // identity — otherwise closing the last window would leave the icon up until something
        // else happened to re-evaluate.
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                            queue: .main) { [weak self] notification in
            let closing = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.update(closing: closing) }
        })
    }

    /// Recounts the open windows and shows or hides the Dock icon to match the policy. `opening`
    /// is a window about to be shown — counted already, so the caller can switch the policy before
    /// activating the app, which is what puts the app's menus in the menu bar straight away.
    func update(closing: ObjectIdentifier? = nil, opening: NSWindow? = nil) {
        // A hidden app (⌘H) reports its windows as not visible; dropping the Dock icon then would
        // take away the usual way back to them. Leave it as it is until the app is unhidden.
        guard !NSApp.isHidden else { return }
        let open = NSApp.windows.filter { window in
            ObjectIdentifier(window) != closing
                && window.styleMask.contains(.titled)
                && (window.isVisible || window.isMiniaturized || window === opening)
        }
        let show = policy.showsDockIcon(settingsWindowOpen: open.contains(where: isSettingsWindow),
                                        anyWindowOpen: !open.isEmpty)
        apply(show ? .regular : .accessory)
    }

    private func apply(_ target: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
        // AppKit doesn't put a newly regular app's menus in the menu bar until it is activated
        // again. Only re-activate an app that is already in front: a notice window appearing while
        // the user works elsewhere must not pull focus.
        if target == .regular, NSApp.isActive {
            DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        }
    }
}

/// What the Settings window remembers between openings and launches (SD-08): the last section,
/// the window's size and where it was left. Whether it reopens there or on the screen under the
/// pointer is the user's choice (`placement`); `SettingsWindowPlacementPolicy` decides the spot.
enum SettingsWindowMemory {
    /// The section shown when Settings opens, unless `-OpenDisplaySettingsSection` is given.
    static let lastSectionKey = "OpenDisplayLastSettingsSection"
    private static let contentSizeKey = "OpenDisplaySettingsWindowContentSize"
    private static let frameKey = "OpenDisplaySettingsWindowFrame"
    static let placementKey = "OpenDisplaySettingsWindowPlacement"

    /// Where the window opens. Defaults to where it was left.
    static var placement: SettingsWindowPlacement {
        get {
            UserDefaults.standard.string(forKey: placementKey).flatMap(SettingsWindowPlacement.init(rawValue:))
                ?? .lastPosition
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: placementKey) }
    }

    /// The window frame last left by the user, if any (AppKit screen coordinates).
    static var frame: NSRect? {
        get {
            guard let stored = UserDefaults.standard.string(forKey: frameKey) else { return nil }
            let frame = NSRectFromString(stored)
            return frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite
                && frame.height.isFinite && frame.width > 0 && frame.height > 0 ? frame : nil
        }
        set { UserDefaults.standard.set(newValue.map(NSStringFromRect), forKey: frameKey) }
    }

    static var lastSection: String? {
        get { UserDefaults.standard.string(forKey: lastSectionKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastSectionKey) }
    }

    /// The content size last left by the user, if any.
    static var contentSize: NSSize? {
        get {
            guard let stored = UserDefaults.standard.string(forKey: contentSizeKey) else { return nil }
            let size = NSSizeFromString(stored)
            return size.width > 0 && size.height > 0 ? size : nil
        }
        set { UserDefaults.standard.set(newValue.map(NSStringFromSize), forKey: contentSizeKey) }
    }
}
#endif
