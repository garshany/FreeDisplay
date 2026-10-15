#if os(macOS)
import AppKit
import AutomationSchema
import CoreGraphics
import DisplayDomain
import SwiftUI
import TopologyCore

/// What the HUD needs to know about the app around it.
struct OSDHUDEnvironment {
    /// OpenDisplay's menu panel is open.
    var menuOpen = false
    /// The menu-bar icon's frame in screen coordinates; nil while macOS isn't showing it.
    var iconFrame: NSRect?
}

/// How the HUD looks and behaves — the OSD settings, read again at every showing.
struct OSDHUDAppearance: Equatable {
    var style: OSDStyle = .native
    var position: OSDPosition = .bottomCenter
    var screen: OSDScreenChoice = .affectedDisplay
    var showsValue = true
    var segmentedBar = true
    var rounded = false
    var adaptiveBackground = true
    var shadow = true
    var interactive = false
    var volumeCompletionSound = false
    /// What one press of an end icon moves: the standard adjustment step (SO-29).
    var step: Float = 1 / 16
}

/// The on-screen-display HUD (Batch-3 #4, SO-35). A borderless, non-activating panel that floats
/// above everything and never takes focus. Click-through by default, as macOS's own HUD is; with
/// interaction on it takes the pointer, so hovering holds it and its bar can be dragged. The *what*
/// (`OSDContent`), *where* (`OSDScreenPolicy`, `OSDLayout`) and *how long* (`OSDHoldTracker`) are
/// pure policies; this only measures, draws and runs the timers.
@MainActor
final class OSDHUDController {
    /// Where the menu is and whether it is open; set by the app delegate, which owns both.
    var environment: @MainActor () -> OSDHUDEnvironment = { OSDHUDEnvironment() }
    /// The bar was dragged or an end icon pressed: set `kind` on `display` to `level`. The flag is
    /// Shift, which changes that display alone (no group sync).
    var onAdjust: ((DisplayRecordID, OSDContent.Kind, Float, Bool) -> Void)?

    private let panel: NSPanel
    private let model = OSDHUDModel()
    private let hosting: OSDHostingView
    private var tracker = OSDHoldTracker(autoHide: OSDPresentationPolicy().autoHide)
    private var hideWorkItem: DispatchWorkItem?
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    private var verificationTarget: Int?

    init() {
        hosting = OSDHostingView(rootView: OSDHUDView(model: model))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = hosting

        hosting.onPointerMoved = { [weak self] location in self?.pointerMoved(to: location) }
        hosting.onPointerExited = { [weak self] in
            guard let self else { return }
            self.model.hovered = false
            self.apply(self.tracker.pointerExited(now: Date()))
        }
        model.onDrag = { [weak self] level in self?.dragged(to: level) }
        model.onDragEnded = { [weak self] in self?.dragEnded() }
        model.onStep = { [weak self] up in self?.step(up: up) }
        model.onClose = { [weak self] in self?.hide(animated: false) }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide(animated: false) }
        })
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.appearance.position.isMenuBarAnchored,
                      self.environment().menuOpen else { return }
                self.hide(animated: false)
            }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// The screen feedback for a change on `affected` goes to under `appearance` — also the screen
    /// hint published with the event.
    var foregroundFocusedScreen: @MainActor () -> CGDirectDisplayID? = { nil }

    func screenID(for appearance: OSDHUDAppearance, affected: CGDirectDisplayID?) -> CGDirectDisplayID? {
        let screens = NSScreen.screens
        let mouse = NSEvent.mouseLocation
        let icon = environment().iconFrame
        return OSDScreenPolicy.screen(
            position: appearance.position, choice: appearance.screen, affected: affected,
            pointer: screens.first { NSMouseInRect(mouse, $0.frame, false) }?.osdDisplayID,
            focused: foregroundFocusedScreen(), primary: CGMainDisplayID(),
            iconScreen: icon.flatMap { frame in screens.first { $0.frame.intersects(frame) }?.osdDisplayID },
            available: screens.compactMap(\.osdDisplayID))
    }

    /// Shows (or refreshes) the HUD. `display` is the changed display, which the interactive bar
    /// adjusts; nil leaves the bar a result only. `external` style draws nothing — the event is
    /// published for another app instead.
    func present(_ content: OSDContent, display: DisplayRecordID?, affected: CGDirectDisplayID?,
                 appearance: OSDHUDAppearance, verificationTarget: Int? = nil, adjustable: Bool = true) {
        guard appearance.style != .external else { hide(animated: false); return }
        model.content = content
        model.display = display
        model.canAdjust = adjustable
        model.appearance = appearance
        panel.hasShadow = appearance.shadow
        self.verificationTarget = verificationTarget
        panel.ignoresMouseEvents = !appearance.interactive

        let size = sizeToFit()
        if let id = screenID(for: appearance, affected: affected),
           let screen = NSScreen.screens.first(where: { $0.osdDisplayID == id }) {
            let icon = environment().iconFrame.flatMap { screen.frame.intersects($0) ? $0 : nil }
            let origin = OSDLayout.origin(position: appearance.position, width: size.width, height: size.height,
                                          visibleFrame: OSDFrame(screen.visibleFrame), icon: icon.map(OSDFrame.init),
                                          rightToLeft: NSApp.userInterfaceLayoutDirection == .rightToLeft)
            panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
        }

        // Stops a fade still running from the previous showing; its completion then sees a newer
        // generation and leaves this one up.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
        let mouse = NSEvent.mouseLocation
        apply(tracker.shown(now: Date(), pointer: (Double(mouse.x), Double(mouse.y))))
    }

    /// The display answered after a hardware change (TR-17). A HUD still showing that change now
    /// says whether it was confirmed, and shows the level the display reports.
    func noteVerification(_ verification: DDCWriteVerification, maxValue: Int?,
                          display: DisplayRecordID, kind: OSDContent.Kind, target: Int) {
        guard panel.isVisible, model.display == display, model.content.kind == kind,
              OSDAssurancePolicy.matches(requestedTarget: verificationTarget, completedTarget: target,
                                         assurance: model.content.assurance) else { return }
        model.content = OSDAssurancePolicy.content(model.content, after: verification, maxValue: maxValue)
        // A different-sized HUD (a caution line added) keeps its top edge where it was placed.
        let top = panel.frame.maxY
        let size = sizeToFit()
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - size.height))
    }

    func noteAdjustment(_ content: OSDContent, display: DisplayRecordID, verificationTarget: Int?) {
        guard panel.isVisible, model.display == display, model.content.kind == content.kind else { return }
        model.content = content
        self.verificationTarget = verificationTarget
    }

    /// Sizes the panel to the content just set. The model's changes reach the view on SwiftUI's
    /// next update, so the root view is set again and laid out first: measuring before that would
    /// size the panel for the previous content.
    private func sizeToFit() -> NSSize {
        hosting.rootView = OSDHUDView(model: model)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        panel.setContentSize(size)
        return size
    }

    func hide(animated: Bool) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        guard panel.isVisible else { tracker.hidden(); return }
        if animated {
            fade(generation: tracker.generation)
        } else {
            panel.orderOut(nil)
            tracker.hidden()
            model.hovered = false
        }
    }

    // MARK: Timing

    private func apply(_ decision: OSDHoldTracker.Decision) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        // Interactions invalidate a running fade just as a new showing does.
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().alphaValue = 1
            }
        }
        guard case .hide(let at) = decision else { return }
        let generation = tracker.generation
        let work = DispatchWorkItem { [weak self] in self?.fade(generation: generation) }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at.timeIntervalSinceNow), execute: work)
    }

    private func fade(generation: Int) {
        guard tracker.isCurrent(generation), panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A newer showing (or a hover that began during the fade) owns the panel now.
                guard let self, self.tracker.isCurrent(generation), !self.tracker.hovered,
                      !self.tracker.dragging else { return }
                self.panel.orderOut(nil)
                self.tracker.hidden()
            }
        })
    }

    // MARK: Interaction

    private func pointerMoved(to location: NSPoint) {
        let decision = tracker.pointerMoved(to: (Double(location.x), Double(location.y)),
                                            inside: panel.frame.contains(location), now: Date())
        model.hovered = tracker.hovered
        if decision == .hold, panel.alphaValue < 1 { panel.animator().alphaValue = 1 }
        apply(decision)
    }

    private func dragged(to level: Float) {
        guard let display = model.display else { return }
        if !tracker.dragging { apply(tracker.dragBegan()) }
        adjust(display, to: level)
    }

    private func dragEnded() {
        if tracker.dragging { completeAdjustment() }
        apply(tracker.dragEnded(pointerInside: panel.frame.contains(NSEvent.mouseLocation), now: Date()))
    }

    private func step(up: Bool) {
        guard let display = model.display else { return }
        adjust(display, to: OSDSliderPolicy.stepped(model.content.value, by: model.appearance.step, up: up))
        completeAdjustment()
        let mouse = NSEvent.mouseLocation
        apply(tracker.shown(now: Date(), pointer: (Double(mouse.x), Double(mouse.y))))
    }

    private func adjust(_ display: DisplayRecordID, to level: Float) {
        var content = model.content
        content.value = level
        // A new request is unconfirmed again; software dimming stays applied.
        if content.assurance != .applied { content.assurance = .requested }
        model.content = content
        onAdjust?(display, content.kind, level, NSEvent.modifierFlags.contains(.shift))
    }

    private func completeAdjustment() {
        if OSDSliderPolicy.playsSound(kind: model.content.kind, completed: true,
                                      enabled: model.appearance.volumeCompletionSound) {
            NSSound(named: NSSound.Name("Pop"))?.play()
        }
    }
}

private extension OSDFrame {
    init(_ rect: NSRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}

extension NSScreen {
    /// The Core Graphics display number behind this screen.
    var osdDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// The HUD's live state, so content changes during a drag don't rebuild the view.
@MainActor
final class OSDHUDModel: ObservableObject {
    @Published var content = OSDContent(kind: .brightness, value: 0)
    @Published var appearance = OSDHUDAppearance()
    @Published var display: DisplayRecordID?
    @Published var canAdjust = false
    @Published var hovered = false
    var onDrag: (Float) -> Void = { _ in }
    var onDragEnded: () -> Void = {}
    var onStep: (Bool) -> Void = { _ in }
    var onClose: () -> Void = {}

    /// The bar takes drags and the end icons appear: interaction is on, the change has one display
    /// to adjust, and it is a level rather than a result (mute, an input name).
    var isAdjustable: Bool {
        appearance.interactive && canAdjust && display != nil && OSDSliderPolicy.isAdjustable(content.kind)
    }
}

/// The hosting view, with what a click-through-by-default panel needs once it takes the pointer:
/// the first click acts (the panel never becomes key), and pointer movement is reported even
/// while OpenDisplay is in the background.
final class OSDHostingView: NSHostingView<OSDHUDView> {
    var onPointerMoved: ((NSPoint) -> Void)?
    var onPointerExited: (() -> Void)?
    private var pointerArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        // Moves only, not entries: a HUD appearing under a resting pointer must not count as a hover.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        pointerArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerMoved?(NSEvent.mouseLocation)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerExited?()
    }
}

/// The HUD's SwiftUI body. `native`/`classicTahoe` render a square glyph-over-bar HUD; `minimal` is a
/// compact pill. Materials adapt to light/dark automatically (app floor is macOS 14).
struct OSDHUDView: View {
    @ObservedObject var model: OSDHUDModel

    private var content: OSDContent { model.content }
    private var appearance: OSDHUDAppearance { model.appearance }
    private var showsNumber: Bool {
        appearance.showsValue && (content.kind == .brightness || content.kind == .volume)
    }
    private var notConfirmed: Bool { content.assurance == .notConfirmed }

    var body: some View {
        Group {
            if appearance.rounded || appearance.style == .minimal { minimalBody }
            else { squareBody }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityValue(assuranceText)
        .accessibilityAdjustableAction { direction in
            guard model.isAdjustable else { return }
            switch direction {
            case .increment: model.onStep(true)
            case .decrement: model.onStep(false)
            @unknown default: break
            }
        }
    }

    private var accessibilityDescription: String {
        switch content.kind {
        case .brightness: return String(localized: "Brightness: \(content.percent)%")
        case .volume: return String(localized: "Volume: \(content.percent)%")
        case .mute: return String(localized: "Muted")
        case .input:
            let input = content.label ?? String(localized: "not specified")
            return String(localized: "Input source: \(input)")
        }
    }

    private var squareBody: some View {
        VStack(spacing: 14) {
            Image(systemName: content.glyph)
                .font(.system(size: 78, weight: .regular))
                .frame(height: 90)
            levelRow(metrics: model.isAdjustable ? .compactSquare : .square)
            if showsNumber { valueText.font(.system(size: 15, weight: .medium)) }
            if showsNumber, !notConfirmed { assuranceText.font(.caption).foregroundStyle(.secondary) }
            if notConfirmed {
                Label("Not confirmed by the display", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 200)
        .frame(minHeight: 200)
        .background {
            hudBackground(RoundedRectangle(cornerRadius: appearance.style == .classicTahoe ? 10 : 18,
                                             style: .continuous))
        }
        .overlay(alignment: .topTrailing) {
            if appearance.interactive, model.hovered {
                Button(action: model.onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).padding(8)
                    .help("Close on-screen display")
            }
        }
    }

    private var minimalBody: some View {
        HStack(spacing: 12) {
            Image(systemName: content.glyph).font(.system(size: 18)).frame(width: 22)
            levelRow(metrics: .pill)
            if showsNumber { valueText.font(.system(size: 13, weight: .medium)) }
            if showsNumber, !notConfirmed { assuranceText.font(.caption).foregroundStyle(.secondary) }
            if notConfirmed {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13))
            }
        }
        .padding(.horizontal, 16)
        .frame(minWidth: 240)
        .frame(height: 48)
        .background { hudBackground(Capsule()) }
    }

    @ViewBuilder private func hudBackground<S: Shape>(_ shape: S) -> some View {
        if appearance.adaptiveBackground { shape.fill(.regularMaterial) }
        else { shape.fill(Color(nsColor: .windowBackgroundColor)) }
    }

    private var valueText: some View {
        Text(Double(content.percent) / 100, format: .percent.precision(.fractionLength(0)))
            .monospacedDigit()
    }

    private var assuranceText: Text {
        switch content.assurance {
        case .requested: return Text("Requested")
        case .verified: return Text("Reported by the display")
        case .applied: return Text("Software level")
        case .notConfirmed: return Text("Not confirmed by the display")
        }
    }

    /// Bar sizes per layout. The square's bar is narrower when end icons share its row.
    private struct BarMetrics {
        var segmentWidth: CGFloat
        var segmentHeight: CGFloat
        var spacing: CGFloat

        var width: CGFloat {
            CGFloat(OSDContent.segmentCount) * segmentWidth + CGFloat(OSDContent.segmentCount - 1) * spacing
        }

        static let square = BarMetrics(segmentWidth: 9, segmentHeight: 9, spacing: 3)
        static let compactSquare = BarMetrics(segmentWidth: 7, segmentHeight: 9, spacing: 2)
        static let pill = BarMetrics(segmentWidth: 8, segmentHeight: 8, spacing: 3)
    }

    /// The level bar for brightness/volume/mute, or the switched-to input's name for `.input` — an
    /// input has no meaningful 0...1 level, so it gets a text confirmation instead.
    @ViewBuilder private func levelRow(metrics: BarMetrics) -> some View {
        if content.kind == .input {
            Text(content.label ?? "").font(.system(size: 15, weight: .medium)).lineLimit(1)
        } else if model.isAdjustable {
            HStack(spacing: 6) {
                endIcon(up: false)
                bar(metrics).gesture(dragGesture(width: metrics.width))
                endIcon(up: true)
            }
        } else {
            bar(metrics)
        }
    }

    @ViewBuilder private func bar(_ metrics: BarMetrics) -> some View {
        Group {
            if appearance.segmentedBar, !model.hovered {
                HStack(spacing: metrics.spacing) {
                    ForEach(0..<OSDContent.segmentCount, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(index < content.filledSegments ? Color.primary : Color.primary.opacity(0.18))
                            .frame(width: metrics.segmentWidth, height: metrics.segmentHeight)
                    }
                }
            } else {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.18))
                    Capsule().fill(Color.primary).frame(width: metrics.width * CGFloat(content.value))
                }
                .frame(width: metrics.width, height: metrics.segmentHeight)
            }
        }
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if let level = OSDSliderPolicy.level(atX: Double(value.location.x), trackMinX: 0,
                                                     trackWidth: Double(width)) {
                    model.onDrag(level)
                }
            }
            .onEnded { _ in model.onDragEnded() }
    }

    private func endIcon(up: Bool) -> some View {
        Button {
            model.onStep(up)
        } label: {
            Image(systemName: endGlyph(up: up)).font(.system(size: 12, weight: .medium)).frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .help(up ? String(localized: "Increase") : String(localized: "Decrease"))
    }

    private func endGlyph(up: Bool) -> String {
        switch content.kind {
        case .volume: return up ? "speaker.wave.3" : "speaker"
        default: return up ? "sun.max" : "sun.min"
        }
    }
}
#endif
