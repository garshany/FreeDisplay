#if os(macOS)
import AppKit
import DisplayDomain
import OpenDisplayDesignSystem
import SwiftUI
import TopologyCore

/// The free-drag arrangement canvas, shared by Settings › Arrange and the tray's Tools › Arrange.
///
/// Each independent desktop is a proportionally sized tile at its real position; a mirror set is
/// one tile — its source — drawn as a stack and naming the displays that mirror it (a mirror target
/// is not a desktop of its own, see `ArrangementTiles`). Dragging a tile previews where it lands
/// (`ArrangementLayout.dropping`): against another display, on the nearest edge or centre — Shift
/// keeps the exact spot along the edge — or inserted at a seam with the peers moved aside.
/// Releasing applies exactly what the preview showed. The menu-bar strip on the main tile can be
/// dragged onto another tile to make that display main; the context menu does the same. Every
/// applied change is re-checked against the live topology and opens the usual keep/revert window
/// (`AppModel.applyArrangement`).
struct ArrangementCanvas: View {
    @EnvironmentObject private var model: AppModel
    let size: CGSize
    /// Smaller labels, for the tray.
    var compact = false
    /// Opens a display's settings from the context menu; nil leaves that item out.
    var openSettings: ((DisplayObservation) -> Void)?

    @State private var drag: TileDrag?
    @State private var menuBarDrag: MenuBarDrag?
    /// The released plan, shown while it is being applied (Core Graphics takes a moment), so the
    /// tile doesn't jump back to where it was as if the drop had been refused.
    @State private var applying: (drawn: ArrangementLayout, preview: ArrangementLayout)?
    /// True only while a tile / the menu bar is physically being dragged. Gesture state resets on
    /// its own when a gesture is cancelled without `onEnded` (window lost focus, an alert), which is
    /// what clears a drag that would otherwise be left half-done.
    @GestureState private var tileGestureActive = false
    @GestureState private var menuBarGestureActive = false

    /// A tile being dragged. `drawn` is the arrangement the gesture started on: the canvas keeps
    /// drawing it so nothing jumps if the topology changes underneath (the drop is re-checked).
    private struct TileDrag {
        let id: DisplayRecordID
        let drawn: ArrangementLayout
        var translation: CGSize
        var drop: ArrangementLayout.Drop?
    }

    /// The menu-bar strip being dragged toward another tile.
    private struct MenuBarDrag {
        let drawn: ArrangementLayout
        var location: CGPoint
        var target: DisplayRecordID?
    }

    private static let space = "arrangementCanvas"

    var body: some View {
        let live = AppModel.arrangementLayout(model.displays)
        let layout = drag?.drawn ?? menuBarDrag?.drawn ?? applying?.drawn ?? live
        let mapping = mapping(for: layout)
        let shown = drag?.drop?.preview ?? applying?.preview ?? layout
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.1))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3)))
            if let drag, let landing = drag.drop?.preview.frame(of: drag.id) {
                // Where the dragged display will land.
                let target = canvasRect(landing, mapping)
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.08)))
                    .frame(width: target.width, height: target.height)
                    .position(x: target.midX, y: target.midY)
                    .allowsHitTesting(false)
            }
            ForEach(layout.tiles, id: \.id) { tile in
                let dragging = drag?.id == tile.id
                let frame = dragging
                    ? canvasRect(tile.frame, mapping).offsetBy(dx: drag?.translation.width ?? 0,
                                                               dy: drag?.translation.height ?? 0)
                    : canvasRect(shown.frame(of: tile.id) ?? tile.frame, mapping)
                tileView(tile, layout: layout, frame: frame, dragging: dragging)
            }
            if let menuBarDrag {
                Capsule().fill(Color.white).shadow(radius: 1)
                    .frame(width: compact ? 26 : 40, height: compact ? 3 : 5)
                    .position(menuBarDrag.location)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .coordinateSpace(name: Self.space)
        .animation(.easeOut(duration: 0.15), value: drag?.drop)
        .onChange(of: tileGestureActive) { _, active in
            // After `onEnded` (same event), so a completed drop has already been handed over.
            if !active { DispatchQueue.main.async { drag = nil } }
        }
        .onChange(of: menuBarGestureActive) { _, active in
            if !active { DispatchQueue.main.async { menuBarDrag = nil } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Display arrangement"))
    }

    // MARK: - Tiles

    @ViewBuilder
    private func tileView(_ tile: ArrangementLayout.Tile, layout: ArrangementLayout, frame: CGRect,
                          dragging: Bool) -> some View {
        let display = model.displays.first { $0.recordID == tile.id }
        let isMain = tile.id == layout.mainID
        let isMenuBarTarget = menuBarDrag?.target == tile.id
        let tint = isMain || isMenuBarTarget ? Color.accentColor : Color.secondary
        let name = display.map { model.displayName(for: $0) } ?? tile.id.rawValue
        let mirrorNames = tile.mirrorTargets.compactMap { id in
            model.displays.first { $0.recordID == id }.map { model.displayName(for: $0) }
        }
        let width = max(frame.width, 36)
        let height = max(frame.height, 24)
        ZStack(alignment: .top) {
            // A mirror set is drawn as a stack: its targets show this desktop, they aren't separate.
            ForEach(Array(mirrorNames.indices), id: \.self) { index in
                let offset = CGFloat(index + 1) * 3
                RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(0.5), lineWidth: 1)
                    .frame(width: width, height: height)
                    .offset(x: offset, y: offset)
            }
            RoundedRectangle(cornerRadius: 4)
                .fill(tint.opacity(dragging ? 0.28 : 0.18))
                .background(RoundedRectangle(cornerRadius: 4).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(tint, lineWidth: isMain || isMenuBarTarget ? 2 : 1))
                .overlay(labels(name: name, display: display, mirrorNames: mirrorNames))
                .frame(width: width, height: height)
            if isMain {
                // Stays in the tree while it's being dragged (only hidden): removing the view that
                // owns a gesture cancels the gesture.
                menuBarStrip(layout: layout, tileWidth: width)
                    .opacity(menuBarDrag == nil ? 1 : 0)
            }
        }
        .frame(width: width, height: height, alignment: .top)
        .shadow(color: .black.opacity(dragging ? 0.25 : 0), radius: dragging ? 4 : 0)
        .contentShape(Rectangle())
        .gesture(tileDrag(tile.id, layout: layout))
        .onTapGesture {
            // Option-click identifies the physical screen without moving anything.
            if NSEvent.modifierFlags.contains(.option), let display { identify(display) }
        }
        .contextMenu {
            Button("Use as Main Display") { makeMain(tile.id, in: layout) }
                .disabled(isMain || !canArrange(layout))
            if let display {
                Button("Identify") { identify(display) }
                if let openSettings { Button("Display Settings…") { openSettings(display) } }
            }
        }
        .help(isMain ? String(localized: "\(name) — main display. Drag to move; drag its menu bar onto another display to make that one main.")
                     : String(localized: "\(name). Drag to move; hold Shift while dropping to place it freely along the edge. Option-click to identify."))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel(name: name, isMain: isMain, mirrorNames: mirrorNames)))
        .accessibilityAction(named: Text("Use as Main Display")) { makeMain(tile.id, in: layout) }
        .accessibilityAction(named: Text("Identify")) { if let display { identify(display) } }
        // Positioned last: everything above hit-tests on the tile itself, not the whole canvas.
        .position(x: frame.midX, y: frame.midY)
        .zIndex(dragging ? 1 : 0)
    }

    private func labels(name: String, display: DisplayObservation?, mirrorNames: [String]) -> some View {
        VStack(spacing: 1) {
            Text(name).font(compact ? .system(size: 9) : .caption2).lineLimit(1).padding(.horizontal, 3)
            if !compact, let mode = display?.mode {
                Text(TrayModeCatalog.sizeText(mode)).font(.system(size: 8)).foregroundStyle(.secondary)
                    .monospacedDigit().lineLimit(1)
            }
            if !mirrorNames.isEmpty {
                let names = mirrorNames.joined(separator: ", ")
                Text("also on \(names)").font(.system(size: 8)).foregroundStyle(.secondary)
                    .lineLimit(1).padding(.horizontal, 3)
            }
        }
    }

    private func accessibilityLabel(name: String, isMain: Bool, mirrorNames: [String]) -> String {
        var parts = [name]
        if isMain { parts.append(String(localized: "main display")) }
        if !mirrorNames.isEmpty {
            let names = mirrorNames.joined(separator: ", ")
            parts.append(String(localized: "also on \(names)"))
        }
        return parts.joined(separator: ", ")
    }

    /// The white bar at the top of the main tile, standing for the menu bar. Dragging it onto
    /// another tile hands the menu bar (main display) to that display.
    private func menuBarStrip(layout: ArrangementLayout, tileWidth: CGFloat) -> some View {
        Capsule().fill(Color.white).shadow(color: .black.opacity(0.2), radius: 0.5)
            .frame(width: min(tileWidth - 10, compact ? 26 : 40), height: compact ? 3 : 5)
            .padding(.top, 3)
            .frame(width: tileWidth, height: compact ? 10 : 14, alignment: .top)
            .contentShape(Rectangle())
            .highPriorityGesture(menuBarGesture(layout: layout))
            .help(String(localized: "Drag the menu bar onto another display to make it the main display"))
    }

    // MARK: - Gestures

    private func canArrange(_ layout: ArrangementLayout) -> Bool {
        !model.arrangementApplying && applying == nil && layout.tiles.count > 1
    }

    private func tileDrag(_ id: DisplayRecordID, layout: ArrangementLayout) -> some Gesture {
        DragGesture(coordinateSpace: .named(Self.space))
            .updating($tileGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard drag?.id == id || (drag == nil && canArrange(layout)) else { return }
                var current = drag ?? TileDrag(id: id, drawn: layout, translation: .zero, drop: nil)
                current.translation = value.translation
                current.drop = plannedDrop(current)
                drag = current
            }
            .onEnded { _ in
                guard let current = drag, current.id == id else { return }
                drag = nil
                // What the preview showed is what gets applied — including the snapping mode it
                // was computed with, so pressing or releasing Shift without moving changes nothing.
                guard let drop = current.drop, !current.drawn.originChanges(to: drop.result).isEmpty else { return }
                apply(drop.result, preview: drop.preview, drawn: current.drawn)
            }
    }

    /// The drop for the drag's current translation; Shift (read as the pointer moves) turns
    /// snapping off.
    private func plannedDrop(_ drag: TileDrag) -> ArrangementLayout.Drop? {
        guard let origin = drag.drawn.frame(of: drag.id)?.origin else { return nil }
        let delta = mapping(for: drag.drawn).desktopDelta(canvasDX: drag.translation.width,
                                                          canvasDY: drag.translation.height)
        return drag.drawn.dropping(drag.id, at: DisplayOrigin(x: origin.x + delta.dx, y: origin.y + delta.dy),
                                   snapping: !NSEvent.modifierFlags.contains(.shift))
    }

    private func menuBarGesture(layout: ArrangementLayout) -> some Gesture {
        DragGesture(coordinateSpace: .named(Self.space))
            .updating($menuBarGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard menuBarDrag != nil || canArrange(layout) else { return }
                let drawn = menuBarDrag?.drawn ?? layout
                let point = mapping(for: drawn).desktopPoint(canvasX: value.location.x, canvasY: value.location.y)
                let target = drawn.tileID(atX: point.x, y: point.y).flatMap { $0 == drawn.mainID ? nil : $0 }
                menuBarDrag = MenuBarDrag(drawn: drawn, location: value.location, target: target)
            }
            .onEnded { _ in
                guard let current = menuBarDrag else { return }
                menuBarDrag = nil
                if let target = current.target { makeMain(target, in: current.drawn) }
            }
    }

    private func makeMain(_ id: DisplayRecordID, in layout: ArrangementLayout) {
        guard canArrange(layout), let planned = layout.makingMain(id) else { return }
        apply(planned, preview: planned, drawn: layout)
    }

    private func apply(_ planned: ArrangementLayout, preview: ArrangementLayout, drawn: ArrangementLayout) {
        applying = (drawn, preview)
        Task {
            await model.applyArrangement(planned, drawnFrom: drawn)
            applying = nil
        }
    }

    private func identify(_ display: DisplayObservation) {
        guard let cgID = display.cgDisplayID else { return }
        DisplayIdentifier.flash(cgDisplayID: cgID, title: model.displayName(for: display),
                                detail: display.mode.map { TrayModeCatalog.sizeText($0) } ?? "")
    }

    // MARK: - Geometry

    private func mapping(for layout: ArrangementLayout) -> ArrangementCanvasMapping {
        ArrangementCanvasMapping(layout: layout, canvasWidth: size.width, canvasHeight: size.height)
    }

    private func canvasRect(_ rect: ArrangementRect, _ mapping: ArrangementCanvasMapping) -> CGRect {
        let r = mapping.canvasRect(rect)
        return CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
    }
}

/// What the arrangement canvas has to say beside it: why the last change didn't land, what macOS
/// did differently, and the protected-layout conflict. Shared so Settings and the tray say the same.
enum ArrangementCanvasMessages {
    struct Message: Hashable {
        let text: String
        let isWarning: Bool
    }

    @MainActor
    static func current(_ model: AppModel) -> [Message] {
        var messages: [Message] = []
        if let error = model.arrangementError { messages.append(Message(text: error, isWarning: true)) }
        if let note = model.arrangementNote { messages.append(Message(text: note, isWarning: false)) }
        if model.settings.layoutProtectionEnabled && model.protectedLayoutForCurrentSet != nil {
            // Protection restores ITS saved layout on the next change it sees; a canvas move isn't
            // added to it, so say so before the user is surprised by the move being undone later.
            messages.append(Message(
                text: String(localized: "Protected layout is on for these displays. A move made here isn’t saved into it: the next time the arrangement changes, the protected layout is put back. Update the protected layout to keep the new one."),
                isWarning: false))
        }
        return messages
    }
}

/// The keep/revert prompt in Settings › Arrange (the tray floats its own).
struct ArrangementRevertBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let pending = model.pendingRevert {
            VStack(alignment: .leading, spacing: 6) {
                ODInlineBanner(tone: .orange, systemImage: "clock.arrow.circlepath",
                               title: pending.kind == .mainDisplay ? String(localized: "Keep the new main display?")
                                   : pending.kind == .arrangement
                                   ? String(localized: "Keep the new arrangement?")
                                   : String(localized: "Keep these display settings?"),
                               message: String(localized: "\(pending.message). Reverting in \(pending.secondsRemaining)s…"))
                HStack(spacing: 8) {
                    Button("Keep") { model.confirmArrangementChange() }
                        .keyboardShortcut(.defaultAction)
                    Button("Revert Now") { Task { await model.revertArrangementChange() } }
                    Spacer()
                }
            }
        }
    }
}
#endif
