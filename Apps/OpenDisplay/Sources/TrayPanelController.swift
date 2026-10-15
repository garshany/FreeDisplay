#if os(macOS)
import AppKit
import Combine
import DisplayDomain
import SwiftUI
import TopologyCore

/// UI-only state of the tray panel: which sections are open. Display data stays in `AppModel`.
/// Device collapse state is remembered across launches (like BetterDisplay). The inline "more"
/// lists, features and tools collapse every time the panel closes so it opens compact — unless
/// Settings → Menu asks to remember them, in which case they persist across closing and relaunch.
@MainActor
final class TrayUIState: ObservableObject {
    private static let collapsedKey = "OpenDisplayTrayCollapsedDevices"
    private static let moreKey = "OpenDisplayTrayOpenMore"
    private static let featuresKey = "OpenDisplayTrayOpenFeatures"
    private static let toolsOpenKey = "OpenDisplayTrayToolsOpen"
    private static let openToolsKey = "OpenDisplayTrayOpenTools"

    @Published var collapsedDevices: Set<String> {
        didSet { UserDefaults.standard.set(Array(collapsedDevices), forKey: Self.collapsedKey) }
    }
    /// Devices (record ids) whose "More" list is open.
    @Published var moreOpen: Set<String> = [] {
        didSet { if layout.rememberExpandedSections { UserDefaults.standard.set(Array(moreOpen), forKey: Self.moreKey) } }
    }
    /// Open features, as "<device>|<feature>". By default several may be open at once — opening one
    /// never closes another, so nothing above the clicked row moves; Settings → Menu can ask for one
    /// at a time per display instead.
    @Published var openFeatures: Set<String> = [] {
        didSet { if layout.rememberExpandedSections { UserDefaults.standard.set(Array(openFeatures), forKey: Self.featuresKey) } }
    }
    @Published var toolsOpen = false {
        didSet { if layout.rememberExpandedSections { UserDefaults.standard.set(toolsOpen, forKey: Self.toolsOpenKey) } }
    }
    @Published var openTools: Set<String> = [] {
        didSet { if layout.rememberExpandedSections { UserDefaults.standard.set(Array(openTools), forKey: Self.openToolsKey) } }
    }
    /// The menu-layout preferences the expansion rules follow, kept in step by the panel controller.
    private(set) var layout = MenuLayoutSettings.default
    private var notificationObservers: [NSObjectProtocol] = []
    /// Devices whose mode list shows every variant instead of one row per size.
    @Published var showAllModes: Set<String> = []
    /// Device waiting for the second click of "factory reset".
    @Published var resetConfirm: String?
    /// DDC power command waiting for its second click, as "<device>|<DDCPowerMode.rawValue>".
    @Published var powerConfirm: String?
    /// Pinned panel stays open on outside clicks and Space switches (BetterDisplay's detachable
    /// menu); Esc, the status icon or the pin itself close it. Not remembered between openings.
    @Published var pinned = false
    /// A mode change started from the tray is still being applied (before `pendingRevert` exists).
    /// Locks every mode control on every screen: the model would refuse a second change anyway.
    @Published private(set) var modeApplying = false
    /// Display whose mode the tray changed last — the one the pending keep/revert window belongs to.
    @Published private(set) var lastModeDevice: String?

    /// Wired by the controller: hides the panel.
    var close: @MainActor () -> Void = {}
    /// Wired by the controller: briefly labels a physical screen.
    var identify: @MainActor (_ cgDisplayID: UInt32, _ title: String, _ detail: String) -> Void = { _, _, _ in }

    init() {
        collapsedDevices = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? [])
        let center = NotificationCenter.default
        // Forgetting or resetting a display drops what the tray remembered about it, so a display
        // seen again later starts out like a new one.
        notificationObservers.append(center.addObserver(forName: .openDisplayForgetTrayState, object: nil,
                                                        queue: .main) { [weak self] note in
            let devices = Set(note.object as? [String] ?? [])
            MainActor.assumeIsolated { self?.forget(devices) }
        })
        // "Reset menu layout" closes every expanded section.
        notificationObservers.append(center.addObserver(forName: .openDisplayCollapseTray, object: nil,
                                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeExpandedSections() }
        })
    }

    /// Takes on new menu-layout preferences. Switching "remember expanded sections" on starts saving
    /// what is open from now on (and, at launch, brings back what was saved); switching it off
    /// forgets the saved state so the next opening is compact again.
    func apply(_ newLayout: MenuLayoutSettings) {
        let wasRemembering = layout.rememberExpandedSections
        layout = newLayout
        TrayMotion.animates = newLayout.animateMenu
        guard wasRemembering != newLayout.rememberExpandedSections else { return }
        let defaults = UserDefaults.standard
        if newLayout.rememberExpandedSections {
            if defaults.object(forKey: Self.moreKey) != nil {
                moreOpen = Set(defaults.stringArray(forKey: Self.moreKey) ?? [])
                openFeatures = Set(defaults.stringArray(forKey: Self.featuresKey) ?? [])
                toolsOpen = defaults.bool(forKey: Self.toolsOpenKey)
                openTools = Set(defaults.stringArray(forKey: Self.openToolsKey) ?? [])
            } else {
                saveExpansion()
            }
        } else {
            for key in [Self.moreKey, Self.featuresKey, Self.toolsOpenKey, Self.openToolsKey] {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// Called as the panel opens and after it closes. Pending confirmations never outlive the panel;
    /// expanded sections do only when the user asked the tray to remember them.
    func resetTransient() {
        resetConfirm = nil
        powerConfirm = nil
        guard !layout.rememberExpandedSections else { return }
        moreOpen = []
        openFeatures = []
        toolsOpen = false
        openTools = []
    }

    /// Closes every «More», feature and Tools section — and the saved copies of them.
    func closeExpandedSections() {
        moreOpen = []
        openFeatures = []
        toolsOpen = false
        openTools = []
        showAllModes = []
        resetConfirm = nil
        powerConfirm = nil
    }

    private func forget(_ devices: Set<String>) {
        guard !devices.isEmpty else { return }
        collapsedDevices = MenuExpansionPolicy.forgetting(collapsedDevices, devices: devices)
        moreOpen = MenuExpansionPolicy.forgetting(moreOpen, devices: devices)
        openFeatures = MenuExpansionPolicy.forgetting(openFeatures, devices: devices)
        showAllModes = MenuExpansionPolicy.forgetting(showAllModes, devices: devices)
    }

    private func saveExpansion() {
        let defaults = UserDefaults.standard
        defaults.set(Array(moreOpen), forKey: Self.moreKey)
        defaults.set(Array(openFeatures), forKey: Self.featuresKey)
        defaults.set(toolsOpen, forKey: Self.toolsOpenKey)
        defaults.set(Array(openTools), forKey: Self.openToolsKey)
    }

    /// Opens or closes one expandable item with the shared tray animation, following the layout's
    /// one-at-a-time preferences for «More» sections and features.
    func toggle(_ set: ReferenceWritableKeyPath<TrayUIState, Set<String>>, _ id: String) {
        withAnimation(TrayMotion.expand) {
            if set == \TrayUIState.moreOpen {
                moreOpen = MenuExpansionPolicy.togglingMore(moreOpen, device: id, oneAtATime: layout.oneMoreSectionAtATime)
            } else if set == \TrayUIState.openFeatures {
                openFeatures = MenuExpansionPolicy.togglingFeature(openFeatures, feature: id,
                                                                   oneAtATime: layout.oneFeatureAtATime)
            } else if self[keyPath: set].contains(id) {
                self[keyPath: set].remove(id)
            } else {
                self[keyPath: set].insert(id)
            }
        }
    }

    /// Mode controls of `display` are locked only while a change is being applied, or while another
    /// screen's change waits for keep/revert. The screen that was just changed stays adjustable.
    /// A pending arrangement change locks every screen: changing a mode must not silently keep it.
    func isModeLocked(_ model: AppModel, for display: DisplayObservation) -> Bool {
        if modeApplying || model.arrangementApplying { return true }
        guard let pending = model.pendingRevert else { return false }
        if pending.kind == .arrangement { return true }
        return lastModeDevice != display.recordID.rawValue
    }

    /// The single path for tray-initiated mode changes (slider, mode list, refresh list, HiDPI).
    /// Changing the same screen again while its keep/revert window is open counts as "keep" for the
    /// previous step — the user is evidently looking at a usable picture — and the new mode gets its
    /// own revert window, so every step is still protected.
    func applyMode(_ mode: DisplayMode, for display: DisplayObservation, model: AppModel,
                   completion: @escaping @MainActor () -> Void = {}) {
        guard !isModeLocked(model, for: display) else { return }
        if model.pendingRevert != nil { model.confirmArrangementChange() }
        lastModeDevice = display.recordID.rawValue
        modeApplying = true
        Task {
            await model.setMode(mode, for: display)
            modeApplying = false
            completion()
        }
    }

    /// Opens the Settings window (owned by the app delegate) on a given section, optionally with a
    /// display preselected, and hides the panel.
    func openSettings(_ section: SettingsSection = .displays) {
        close()
        NotificationCenter.default.post(name: .openDisplayShowSettings, object: nil)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("OpenDisplayShowSection"), object: section.rawValue)
        }
    }
}

/// Borderless panel that can take key focus (sliders, Esc) without activating the app — so opening
/// the tray never steals focus from the app the user is working in.
final class TrayPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Hosts the tray (`MenuBarView`) in a panel pinned under the status item.
///
/// Why not `NSPopover`: a popover re-centres itself on its arrow whenever its content size changes,
/// so expanding a section made the whole pop-out jump sideways or flip ("уезжает"). This panel keeps
/// its top edge and left edge fixed under the icon and only grows or shrinks downward; content taller
/// than the screen scrolls inside it. Same model as BetterDisplay's app menu.
@MainActor
final class TrayPanelController: NSObject {
    static let width: CGFloat = 344
    private static let cornerRadius: CGFloat = 14

    let ui = TrayUIState()
    private let model: AppModel
    private let panel: TrayPanel
    private let scrollView = NSScrollView()
    private var hosting: NSView?
    private weak var anchorButton: NSStatusBarButton?
    /// Where the panel is pinned for as long as it is open: the screen it was opened on and the icon's
    /// distance from that screen's right edge (status items are right-aligned). Captured once in
    /// `show`. The status item has a single window that macOS moves to the menu bar of whichever
    /// screen is active, so re-reading the icon's position later made the open panel jump to the
    /// other monitor.
    private var anchor: (displayID: CGDirectDisplayID, fromRight: CGFloat)?
    private var contentHeight: CGFloat = 0
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var confirmHost: NSView?
    private var pendingWatch: AnyCancellable?
    private var layoutWatch: AnyCancellable?
    /// Logical open state (the window stays visible for a moment while it fades out).
    private var isOpen = false
    /// Bumped on every show/close so a finished fade-out never hides a panel reopened meanwhile.
    private var visibilityGeneration = 0

    var isShown: Bool { isOpen }

    init(model: AppModel) {
        self.model = model
        panel = TrayPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.onCancel = { [weak self] in self?.close() }

        // Real initial size: subviews below use autoresizing, which mis-scales from a zero-size parent.
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 300))
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Self.cornerRadius)

        let root = MenuBarView(onHeightChange: { [weak self] height in self?.contentHeightDidChange(height) })
            .environmentObject(model)
            .environmentObject(ui)
        // The SwiftUI content is the document of an AppKit scroll view with a *flipped* clip view:
        // the document's top stays at the panel's top whatever the window height does. (A SwiftUI
        // `ScrollView` here kept its offset from the bottom while the panel resized, so the content
        // slid up or down inside a correctly placed panel.) The document is sized frame-by-frame to
        // the measured content height; no Auto Layout negotiates with SwiftUI.
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = NSRect(x: 0, y: 0, width: Self.width, height: 300)
        self.hosting = hosting
        scrollView.contentView = TopAnchoredClipView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = hosting
        scrollView.frame = background.bounds
        scrollView.autoresizingMask = [.width, .height]
        background.addSubview(scrollView)

        // Keep/revert prompt floats over the bottom edge, outside the scrolled document.
        let confirm = NSHostingView(rootView: TrayConfirmBar()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .environmentObject(model))
        confirm.sizingOptions = []
        confirm.frame = NSRect(x: 0, y: 0, width: Self.width, height: 76)
        confirm.autoresizingMask = [.width, .maxYMargin]
        confirm.isHidden = true
        background.addSubview(confirm)
        confirmHost = confirm
        pendingWatch = model.$pendingRevert
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] pending in
                MainActor.assumeIsolated { self?.confirmHost?.isHidden = !pending }
            }
        panel.contentView = background

        ui.close = { [weak self] in self?.close() }
        ui.identify = { cgID, title, detail in DisplayIdentifier.flash(cgDisplayID: cgID, title: title, detail: detail) }
        ui.apply(model.menuLayout)
        layoutWatch = model.$menuLayout
            .removeDuplicates()
            .sink { [weak self] layout in
                MainActor.assumeIsolated { self?.ui.apply(layout) }
            }
    }

    func toggle(from button: NSStatusBarButton?) {
        if isShown { close() } else { show(from: button) }
    }

    func show(from button: NSStatusBarButton?) {
        anchorButton = button
        anchor = nil
        // No `isVisible` test on the status-item window: an icon behind the notch still has an
        // on-screen frame there, and anchoring under it is right; the normal click path must stay
        // exactly as it was. Only a frame that lies on no screen falls through to the fallback.
        if let button, let window = button.window,
           let screen = window.screen ?? NSScreen.main, let id = screen.displayID {
            let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
            if screen.frame.intersects(icon) { anchor = (id, screen.frame.maxX - icon.minX) }
        }
        // No usable icon — macOS hid it (behind the notch, or switched off under System Settings →
        // Menu Bar) and the panel was asked for from Settings: open at the top right of the screen
        // under the pointer, where the icon would normally be, instead of nowhere.
        if anchor == nil, let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main, let id = screen.displayID {
            anchor = (id, Self.width + 14)
        }
        ui.resetTransient()
        isOpen = true
        visibilityGeneration += 1
        reposition(animated: false)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        button?.highlight(true)
        installMonitors()
        // Until SwiftUI has reported a height the panel stays invisible (no flash at a stale size);
        // otherwise fade in like a menu.
        if contentHeight > 0 { fade(to: 1) }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        visibilityGeneration += 1
        let generation = visibilityGeneration
        anchorButton?.highlight(false)
        removeMonitors()
        fade(to: 0) { [weak self] in
            guard let self, self.visibilityGeneration == generation else { return }
            self.panel.orderOut(nil)
            self.ui.resetTransient()
            self.ui.pinned = false
        }
    }

    private func fade(to alpha: CGFloat, completion: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = alpha
        }, completionHandler: {
            MainActor.assumeIsolated { completion?() }
        })
    }

    private func contentHeightDidChange(_ height: CGFloat) {
        let rounded = ceil(height)
        guard rounded != contentHeight else { return }
        let firstMeasurement = contentHeight == 0
        contentHeight = rounded
        hosting?.setFrameSize(NSSize(width: Self.width, height: rounded))
        guard isOpen else { return }
        if firstMeasurement {
            reposition(animated: false)
            fade(to: 1)
        } else {
            reposition(animated: true)
        }
    }

    /// Pins the panel's top-left corner under the status item on the screen it was opened on and sizes
    /// it to the content (capped by the screen). Height changes animate with the same duration and
    /// curve as the SwiftUI content (`TrayMotion`), so the bottom edge moves together with it.
    private func reposition(animated: Bool = false) {
        guard let anchor else { return }
        // The anchored screen may have gone away (unplugged) — then fall back to the main screen.
        guard let screen = NSScreen.screens.first(where: { $0.displayID == anchor.displayID }) ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        let top = visible.maxY - 5
        let maxHeight = max(160, top - visible.minY - 10)
        let height = min(max(contentHeight, 60), maxHeight)
        let iconX = screen.frame.maxX - anchor.fromRight
        let x = min(max(iconX - 8, visible.minX + 6), visible.maxX - Self.width - 6)
        let frame = NSRect(x: x, y: top - height, width: Self.width, height: height)
        guard animated, TrayMotion.isAnimating, frame.origin.x == panel.frame.origin.x else {
            panel.setFrame(frame, display: true, animate: false)
            panel.invalidateShadow()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = TrayMotion.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.panel.invalidateShadow() }
        })
    }

    private func installMonitors() {
        removeMonitors()
        // Clicks in other apps close the tray, like a menu.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.ui.pinned else { return }
                self.close()
            }
        }
        // Clicks in our own other windows (Settings) close it too; the status item toggles it itself.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.ui.pinned, let window = event.window else { return }
                if window !== self.panel, window !== self.anchorButton?.window { self.close() }
            }
            return event
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            // A resolution/main-display change moves the menu bar: re-pin under the icon.
            Task { @MainActor in self?.reposition(animated: false) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.ui.pinned else { return }
                self.close()
            }
        })
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Clip view with a top-left origin, so the scroll position is measured from the top and a taller
/// or shorter document never shifts what the user sees.
private final class TopAnchoredClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// Right-click menu on the status item (BetterDisplay's "quick menu"): the few global actions that
/// should be one click away without opening the panel.
@MainActor
enum TrayQuickMenu {
    static func make(model: AppModel, showSettings: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ActionMenuItem(String(localized: "Settings…"), key: ",") { showSettings() })
        menu.addItem(ActionMenuItem(String(localized: "Show Console…")) {
            NotificationCenter.default.post(name: Notification.Name("FreeDisplayShowCommandConsole"), object: nil)
        })
        menu.addItem(.separator())
        let reconnectTitle = model.busy ? String(localized: "Reconnecting…") : String(localized: "Reconnect all")
        menu.addItem(ActionMenuItem(reconnectTitle, enabled: !model.busy) {
            Task { await model.reconnectAll() }
        })
        menu.addItem(ActionMenuItem(String(localized: "Detect displays")) { Task { await model.refresh() } })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(String(localized: "Keep displays awake while external connected"),
                                    checked: model.settings.preventDisplaySleepWithExternal) {
            model.setPreventDisplaySleepWithExternal(!model.settings.preventDisplaySleepWithExternal)
        })
        menu.addItem(ActionMenuItem(String(localized: "Turn built-in off when an external connects"),
                                    checked: model.settings.autoDisconnectBuiltInOnExternal) {
            model.setAutoDisconnectBuiltInOnExternal(!model.settings.autoDisconnectBuiltInOnExternal)
        })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(String(localized: "About OpenDisplay")) {
            NotificationCenter.default.post(name: .openDisplayShowAbout, object: nil)
        })
        menu.addItem(ActionMenuItem(String(localized: "Quit OpenDisplay"), key: "q") { NSApp.terminate(nil) })
        return menu
    }
}

/// `NSMenuItem` that runs a closure — keeps the quick menu declarative.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", checked: Bool = false, enabled: Bool = true,
         handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

/// "Identify display": a large label in the middle of one physical screen for a moment, so the
/// user can tell which row in the tray is which monitor.
@MainActor
enum DisplayIdentifier {
    private static var windows: [NSWindow] = []

    static func flash(cgDisplayID: UInt32, title: String, detail: String) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == cgDisplayID
        }) else { return }
        let size = NSSize(width: 420, height: 150)
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                           width: size.width, height: size.height)
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let view = NSHostingView(rootView:
            VStack(spacing: 6) {
                Image(systemName: "display").font(.system(size: 34, weight: .semibold))
                Text(title).font(.system(size: 24, weight: .bold)).lineLimit(1)
                Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(width: size.width, height: size.height)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        )
        window.contentView = view
        window.orderFrontRegardless()
        windows.append(window)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            window.orderOut(nil)
            windows.removeAll { $0 === window }
        }
    }
}

extension Notification.Name {
    /// Posted by `AppModel` after a display is forgotten or its settings reset, with the observation
    /// id raw values as the object: the tray drops their collapse/expansion state.
    static let openDisplayForgetTrayState = Notification.Name("OpenDisplayForgetTrayState")
    /// Posted by "Reset menu layout": the tray closes every expanded section.
    static let openDisplayCollapseTray = Notification.Name("OpenDisplayCollapseTray")
    /// Posted by Settings → Menu's "Open the menu panel": the app delegate shows the tray even while
    /// macOS hides the menu-bar icon.
    static let openDisplayShowTray = Notification.Name("OpenDisplayShowTray")
}
#endif
