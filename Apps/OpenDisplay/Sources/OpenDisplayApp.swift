#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// Menu-bar-first entry point (PRD UX-001). `LSUIElement` keeps it out of the Dock unless the user's
/// Dock icon policy asks otherwise (`DockPresenceController`). The menu bar AND
/// the Settings window are both AppKit-managed by `AppDelegate`: SwiftUI's `MenuBarExtra` mis-anchors
/// its pop-out across multiple displays, and a menu-bar app can't reliably surface SwiftUI's `Settings`
/// scene through the responder chain — so the delegate hosts `SettingsView` in its own `NSWindow` and
/// owns the shared `AppModel`. The placeholder scene below only satisfies `App`'s scene requirement;
/// if it is ever surfaced anyway, its content redirects to the delegate's window.
@main
struct OpenDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Self.enforceSingleInstance()
    }

    var body: some Scene {
        Settings { SettingsSceneRedirect() }
    }

    /// Refuses to run alongside another OpenDisplay instance — any copy: a Debug build, the
    /// installed release, a second bundle on disk. Two instances fight over everything this app
    /// manages exactly once per system: the per-display gamma slot, the DDC/I2C bus, the settings
    /// file, the Carbon hotkeys, and the menu-bar item. LaunchServices only prevents re-launching
    /// the *same* bundle, so distinct copies need this runtime guard. The oldest instance (lowest
    /// pid) wins; a newcomer exits here in `App.init`, before the delegate — and therefore
    /// `AppModel` and all its side effects — exists. Deterministic under a simultaneous
    /// multi-launch: every instance that can see an older sibling bows out.
    private static func enforceSingleInstance() {
        #if DEBUG
        // Escape hatch for cross-process test harnesses that intentionally run two copies.
        if ProcessInfo.processInfo.environment["OPENDISPLAY_ALLOW_MULTIPLE"] != nil { return }
        #endif
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let mine = ProcessInfo.processInfo.processIdentifier
        let hasOlderSibling = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { !$0.isTerminated && $0.processIdentifier != mine && $0.processIdentifier < mine }
        guard hasOlderSibling else { return }
        // Don't vanish without a trace: have the instance that's already running open its Settings
        // window, so launching a second copy still puts something on screen.
        DistributedNotificationCenter.default().postNotificationName(
            .openDisplayShowSettingsFromSibling, object: bundleID, userInfo: nil,
            deliverImmediately: true)
        exit(0)
    }
}

/// Content for the placeholder `Settings` scene. Registering the scene gives the app the standard
/// ⌘, "Settings…" behavior, but its SwiftUI-owned window is NOT the real settings UI — that lives in
/// the AppKit window `AppDelegate` owns (see `showSettings`). The delegate intercepts ⌘, before it
/// reaches this scene; this view is the backstop for any other path that surfaces the scene's window
/// (e.g. a `showSettingsWindow:` action): the moment it lands in a window, close that window and open
/// the real one.
private struct SettingsSceneRedirect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Redirector() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Redirector: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Async so we're not closing the window out from under AppKit mid-setup.
            DispatchQueue.main.async { [weak window] in
                window?.close()
                NotificationCenter.default.post(name: .openDisplayShowSettings, object: nil)
            }
        }
    }
}

/// Owns the menu-bar status item + tray panel and the shared `AppModel`, and receives `opendisplay://`
/// URL activations (Issue 4).
///
/// Why AppKit instead of `MenuBarExtra`: with several displays, SwiftUI's `MenuBarExtra(.window)`
/// pop-out frequently opens on the *wrong* screen. The tray is a panel pinned under the clicked
/// status-item button (`TrayPanelController`) — unlike the earlier `NSPopover` it never re-centres or
/// jumps when a section expands. The Keep/Revert confirmation lives inside that panel.
///
/// Icon clicks follow BetterDisplay: left — tray, ⌥-left — Settings, right/⌃ — the quick menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private lazy var tray = TrayPanelController(model: model)
    private var pendingRevertWatch: AnyCancellable?
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private let commandConsole = CommandConsoleWindow()
    private var settingsKeyMonitor: Any?
    /// Dock icon policy (SO-13), created at launch once the status item exists.
    private var dockPresence: DockPresenceController?
    private var dockPolicyWatch: AnyCancellable?
    private var settingsWindowObservers: [NSObjectProtocol] = []

    override init() {
        super.init()
        // App Intents run in this process; they reach the live model (and its ledger) through
        // here. Registered as the model is created rather than at didFinishLaunching: an intent
        // arriving in between would find no model and work the ledger from disk while the model's
        // own launch loads and rewrites the same file. With the model, it waits for that load.
        OpenDisplayAutomation.liveModel = model
    }

    @objc func showCommandConsole() { commandConsole.show(model: model) }
    func closeCommandConsole() { commandConsole.close() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(showCommandConsole),
            name: Notification.Name("FreeDisplayShowCommandConsole"), object: nil)
        // Close the pop-out when an action that re-lays-out the displays is picked (e.g. Set as Main):
        // otherwise the open pop-out, anchored to the status item, gets displaced to a random spot when
        // set-main relocates the menu bar to the new main display.
        NotificationCenter.default.addObserver(
            self, selector: #selector(dismissPopover), name: .openDisplayDismissMenu, object: nil)
        // The menu's gear / "Displays & arrangement…" rows ask the delegate to open Settings (we own
        // that window, not SwiftUI) so it reliably appears on the screen the user is looking at.
        NotificationCenter.default.addObserver(
            self, selector: #selector(showSettings), name: .openDisplayShowSettings, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(showAbout), name: .openDisplayShowAbout, object: nil)
        // The "Show or Hide the Menu" keyboard shortcut (SO-38) acts like a click on the icon.
        NotificationCenter.default.addObserver(
            self, selector: #selector(toggleMenuFromShortcut), name: .openDisplayToggleMenu, object: nil)
        // Settings → Menu can open the panel itself: the way in when macOS hides the icon (FA-15).
        NotificationCenter.default.addObserver(
            self, selector: #selector(showTrayPanel), name: .openDisplayShowTray, object: nil)

        // ⌘, is registered by the placeholder SwiftUI `Settings` scene, whose window is not the real
        // settings UI. Intercept the shortcut before the scene sees it and open OUR Settings window —
        // the same one the menu's gear opens. (`SettingsSceneRedirect` backstops non-keyboard paths.)
        settingsKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "," else { return event }
            self?.showSettings()
            return nil
        }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showSettings), name: .openDisplayShowSettingsFromSibling,
            object: Bundle.main.bundleIdentifier, suspensionBehavior: .deliverImmediately)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "OpenDisplay")
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.target = self
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        // Docs/screenshot mode: `-OpenDisplayShowTrayAtLaunch YES` opens the tray panel once launch
        // settles. Read from the launch-argument domain only; the app never writes this key.
        if UserDefaults.standard.bool(forKey: "OpenDisplayShowTrayAtLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let button = self.statusItem?.button else { return }
                self.tray.show(from: button)
            }
        }

        // A mode change opens a short keep/revert window. Make sure its countdown is on screen even
        // when the change didn't come from the tray (hotkey, URL, CLI) and Settings isn't open.
        pendingRevertWatch = model.$pendingRevert
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] pending in
                MainActor.assumeIsolated {
                    guard pending, let self, let button = self.statusItem?.button, !self.tray.isShown,
                          self.settingsWindow?.isVisible != true else { return }
                    self.tray.show(from: button)
                }
            }

        // Dock icon policy (SO-13): applied now, then on every window change and policy change.
        let dockPresence = DockPresenceController(policy: model.settings.dockIconPolicy) { [weak self] window in
            window === self?.settingsWindow
        }
        self.dockPresence = dockPresence
        dockPresence.update()
        dockPolicyWatch = model.$settings
            .map(\.dockIconPolicy)
            .removeDuplicates()
            .sink { [weak self] policy in
                MainActor.assumeIsolated { self?.dockPresence?.policy = policy }
            }

        // Safe startup (FA-09) says so straight away: Settings opens with the banner explaining
        // what this session holds back, rather than leaving a quieter-than-usual app to puzzle over.
        if model.safeStartup { showSettings() }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        if event?.type == .rightMouseUp || flags.contains(.control) {
            tray.close()
            let menu = TrayQuickMenu.make(model: model) { [weak self] in self?.showSettings() }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        } else if flags.contains(.option) {
            showSettings()
        } else {
            tray.toggle(from: button)
        }
    }

    @objc private func dismissPopover() {
        tray.close()
    }

    @objc private func toggleMenuFromShortcut() {
        guard let button = statusItem?.button else { return }
        tray.toggle(from: button)
    }

    /// Opens the tray without a click on the icon. Anchored under the icon when macOS shows it;
    /// otherwise the panel controller places it where the icon would be.
    @objc private func showTrayPanel() {
        guard !tray.isShown else { return }
        tray.show(from: statusItem?.button)
    }

    /// Opening the app while it is already running (Finder, Spotlight, Launchpad) opens Settings.
    /// The menu-bar icon is the app's only standing UI, and macOS can hide it without telling
    /// anyone — behind the notch when the bar is full, or switched off under System Settings →
    /// Menu Bar — which otherwise leaves a running app with nothing to click (issue #44).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return false
    }

    /// Opens (or re-focuses) the Settings window on the screen the user is looking at. Hosting it in our
    /// own `NSWindow` — rather than SwiftUI's `Settings` scene — is the only reliable way to surface and
    /// position it from a menu-bar (LSUIElement) app, especially with "Displays have separate Spaces".
    @objc private func showSettings() {
        dismissPopover()
        let window: NSWindow
        if let existing = settingsWindow {
            window = existing
        } else {
            let hosting = NSHostingController(rootView: SettingsView().environmentObject(model))
            let created = NSWindow(contentViewController: hosting)
            // SwiftUI's navigationTitle only reaches a freshly created window once the section
            // re-renders, so seed the title with the starting section; switching sections updates it.
            created.title = SettingsSection.launchSection.title
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.isReleasedWhenClosed = false
            created.contentMinSize = NSSize(width: 760, height: 540)
            created.setContentSize(Self.settingsContentSize(onScreenWith: created.contentMinSize))
            settingsWindow = created
            window = created
            // SD-08: remember the size the user leaves it at, for the next opening and launch — at
            // the end of a drag, after a zoom (a resize with no drag) and on close.
            for name in [NSWindow.didEndLiveResizeNotification, NSWindow.didResizeNotification,
                         NSWindow.willCloseNotification] {
                settingsWindowObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: created, queue: .main) { [weak created] _ in
                    MainActor.assumeIsolated {
                        guard let created, !created.inLiveResize else { return }
                        Self.rememberSettingsSize(of: created)
                    }
                })
            }
        }
        if let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                          y: visible.midY - size.height / 2))
        }
        dockPresence?.update(opening: window)  // SO-13: Dock icon first, so activation shows the app's menus
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The Settings window's starting content size: the remembered one (SD-08), else the default,
    /// shrunk to fit the screen under the pointer — a size saved on a large external display must
    /// not open past the edges of the laptop panel — and never below the window's minimum.
    private static func settingsContentSize(onScreenWith minimum: NSSize) -> NSSize {
        let wanted = SettingsWindowMemory.contentSize ?? NSSize(width: 900, height: 660)
        guard let visible = (NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
                             ?? NSScreen.main)?.visibleFrame else { return wanted }
        return NSSize(width: max(minimum.width, min(wanted.width, visible.width)),
                      height: max(minimum.height, min(wanted.height, visible.height)))
    }

    /// Opens (or re-focuses) the custom About window (`AboutView`) — same ownership story as
    /// Settings: an AppKit window the delegate places on the screen the user is looking at.
    @objc private func showAbout() {
        dismissPopover()
        let window: NSWindow
        if let existing = aboutWindow {
            window = existing
        } else {
            let hosting = NSHostingController(rootView: AboutView().environmentObject(model))
            let created = NSWindow(contentViewController: hosting)
            created.title = String(localized: "About OpenDisplay")
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            aboutWindow = created
            window = created
        }
        if let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                          y: visible.midY - size.height / 2))
        }
        dockPresence?.update(opening: window)  // SO-13: Dock icon first, so activation shows the app's menus
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Returns the Mac to a clean default on quit. Reconnecting a display the app turned off is async
    /// (CoreGraphics reconfiguration), so when there's something to undo we defer termination until the
    /// revert completes; otherwise quit immediately. Gamma and the keep-awake assertion are also
    /// restored synchronously by `AppModel`'s `willTerminate` backstop.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.needsQuitReversion else { return .terminateNow }
        Task {
            await model.teardownForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// A quit or relaunch with Settings still open sends no `willClose`, so its size (SD-08) is
    /// saved here too.
    func applicationWillTerminate(_ notification: Notification) {
        if let window = settingsWindow, window.isVisible { Self.rememberSettingsSize(of: window) }
    }

    /// Full screen is the screen's size, not one the user chose, so it is never remembered.
    private static func rememberSettingsSize(of window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        SettingsWindowMemory.contentSize = window.contentRect(forFrameRect: window.frame).size
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            Task { [model] in await OpenDisplayAutomation.handleURL(url, model: model) }
        }
    }
}

extension Notification.Name {
    /// Posted by a menu action that re-lays-out the displays (e.g. Set as Main) so the app delegate
    /// closes the pop-out before the menu bar relocates and displaces it.
    static let openDisplayDismissMenu = Notification.Name("OpenDisplayDismissMenu")
    /// Posted by the menu's gear / "Displays & arrangement…" rows to ask the delegate to open the
    /// Settings window (AppKit-owned, so it lands on the screen the user clicked from).
    static let openDisplayShowSettings = Notification.Name("OpenDisplayShowSettings")
    /// Posted across processes by a second copy of the app as it bows out to the one already
    /// running (see `enforceSingleInstance`), asking that one to show its Settings window.
    static let openDisplayShowSettingsFromSibling = Notification.Name("dev.opendisplay.app.showSettings")
    /// Posted by the menu's "About OpenDisplay" item; the delegate owns the About window.
    static let openDisplayShowAbout = Notification.Name("OpenDisplayShowAbout")
    /// Posted by the "Show or Hide the Menu" keyboard shortcut; the delegate owns the panel.
    static let openDisplayToggleMenu = Notification.Name("OpenDisplayToggleMenu")
}
#endif
