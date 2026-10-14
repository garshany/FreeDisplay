import DisplayDomain
import Foundation

/// A display's rectangle in the global desktop space — points, top-left origin, y grows downward —
/// the space Core Graphics positions displays in, with the main display at (0, 0).
public struct ArrangementRect: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var origin: DisplayOrigin { DisplayOrigin(x: x, y: y) }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }

    public func offsetBy(dx: Int, dy: Int) -> ArrangementRect {
        ArrangementRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    public func moved(to origin: DisplayOrigin) -> ArrangementRect {
        ArrangementRect(x: origin.x, y: origin.y, width: width, height: height)
    }

    /// Two displays covering the same desktop points (a positive-area intersection).
    public func overlaps(_ other: ArrangementRect) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }

    /// Contact without overlap: a shared edge segment or, diagonally, a shared corner — what makes
    /// two displays neighbours in a macOS arrangement.
    public func touches(_ other: ArrangementRect) -> Bool {
        guard !overlaps(other) else { return false }
        let sideBySide = (maxX == other.x || other.maxX == x) && y <= other.maxY && other.y <= maxY
        let stacked = (maxY == other.y || other.maxY == y) && x <= other.maxX && other.x <= maxX
        return sideBySide || stacked
    }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= Double(x) && px < Double(maxX) && py >= Double(y) && py < Double(maxY)
    }
}

/// The geometry behind the drag-to-arrange canvas: one tile per desktop (a mirror set is one tile,
/// see `ArrangementTiles`) and the rules a drop must satisfy to be a layout macOS takes as is —
/// no two displays overlap, every display reaches every other through edge contacts, and the main
/// display stays at (0, 0). Pure, so the snapping, insertion and normalisation math is unit-tested;
/// the app reads the topology, draws it and applies the result.
///
/// Snapping has no distance threshold: with snapping on, the free coordinate along the contact edge
/// always lands on the nearest alignment stop (leading/trailing edges, centres, outer corners);
/// with it off (Shift held) it keeps the dropped offset. Adjacency and no-overlap apply either way.
public struct ArrangementLayout: Hashable, Sendable {
    public struct Tile: Hashable, Sendable {
        public let id: DisplayRecordID
        public var frame: ArrangementRect
        /// The displays mirroring this one; they show its image and move with it.
        public let mirrorTargets: [DisplayRecordID]

        public init(id: DisplayRecordID, frame: ArrangementRect, mirrorTargets: [DisplayRecordID] = []) {
            self.id = id
            self.frame = frame
            self.mirrorTargets = mirrorTargets
        }
    }

    public private(set) var tiles: [Tile]
    /// The tile that carries the menu bar (the main display, or the source of its mirror set).
    public let mainID: DisplayRecordID?

    public init(tiles: [Tile], mainID: DisplayRecordID?) {
        self.tiles = tiles
        self.mainID = mainID
    }

    /// The arrangement as observed: active, independent desktops (mirror sets collapsed onto their
    /// source) at their Core Graphics origin. `desktopSize` supplies a display's size on the desktop
    /// when the caller can read it (the app passes `CGDisplayBounds`); otherwise it comes from the
    /// mode and rotation. Tiles are ordered by record id, so two reads of the same arrangement are
    /// equal whatever order the displays were enumerated in.
    public init(observations: [DisplayObservation],
                desktopSize: (DisplayObservation) -> (width: Int, height: Int)? = { _ in nil }) {
        let tiles = ArrangementTiles.tiles(for: observations).compactMap { tile -> Tile? in
            guard let mode = tile.display.mode else { return nil }
            let size = desktopSize(tile.display) ?? Self.desktopSize(of: mode, rotation: tile.display.rotation)
            guard size.width > 0, size.height > 0 else { return nil }
            return Tile(id: tile.display.recordID,
                        frame: ArrangementRect(x: tile.display.origin.x, y: tile.display.origin.y,
                                               width: size.width, height: size.height),
                        mirrorTargets: tile.mirrorTargets)
        }
        .sorted { $0.id.rawValue < $1.id.rawValue }
        let main = observations.first { $0.isMain && $0.isActive }?.recordID
        let mainTile = main.flatMap { main in tiles.first { $0.id == main || $0.mirrorTargets.contains(main) } }
        self.init(tiles: tiles, mainID: mainTile?.id ?? tiles.first { $0.frame.x == 0 && $0.frame.y == 0 }?.id)
    }

    /// The size a mode occupies on the desktop. A display mode reports its unrotated size, while the
    /// desktop (`CGDisplayBounds`) is laid out rotated: a portrait display is taller than wide.
    public static func desktopSize(of mode: DisplayMode, rotation: Rotation) -> (width: Int, height: Int) {
        switch rotation {
        case .degrees90, .degrees270: return (mode.pointHeight, mode.pointWidth)
        case .degrees0, .degrees180: return (mode.pointWidth, mode.pointHeight)
        }
    }

    public func frame(of id: DisplayRecordID) -> ArrangementRect? {
        tiles.first { $0.id == id }?.frame
    }

    /// The tile under a desktop point, if any.
    public func tileID(atX x: Double, y: Double) -> DisplayRecordID? {
        tiles.first { $0.frame.contains(x: x, y: y) }?.id
    }

    /// The smallest rectangle holding every tile; nil without tiles.
    public var bounds: ArrangementRect? {
        guard let first = tiles.first?.frame else { return nil }
        let minX = tiles.map(\.frame.x).min() ?? first.x
        let minY = tiles.map(\.frame.y).min() ?? first.y
        let maxX = tiles.map(\.frame.maxX).max() ?? first.maxX
        let maxY = tiles.map(\.frame.maxY).max() ?? first.maxY
        return ArrangementRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Whether macOS would take this arrangement as it is: no overlap, one connected group.
    public var isValid: Bool { Self.isValid(tiles.map(\.frame)) }

    /// Shifted so the main tile sits at (0, 0): Core Graphics treats the display at the origin as
    /// main, so writing origins that don't keep it there would hand the menu bar to another screen.
    public func normalized() -> ArrangementLayout {
        guard let mainID, let main = frame(of: mainID), main.x != 0 || main.y != 0 else { return self }
        var copy = self
        for index in copy.tiles.indices {
            copy.tiles[index].frame = copy.tiles[index].frame.offsetBy(dx: -main.x, dy: -main.y)
        }
        return copy
    }

    /// The same arrangement with `id` as the main display: every origin re-anchored so that tile is at
    /// (0, 0), which keeps the physical arrangement. Nil when `id` has no tile or already is main.
    public func makingMain(_ id: DisplayRecordID) -> ArrangementLayout? {
        guard id != mainID, frame(of: id) != nil else { return nil }
        return ArrangementLayout(tiles: tiles, mainID: id).normalized()
    }

    /// The origins to write to turn this arrangement into `other`: tiles whose origin differs.
    public func originChanges(to other: ArrangementLayout) -> [DisplayRecordID: DisplayOrigin] {
        var changes: [DisplayRecordID: DisplayOrigin] = [:]
        for tile in other.tiles {
            guard let current = frame(of: tile.id), current.origin != tile.frame.origin else { continue }
            changes[tile.id] = tile.frame.origin
        }
        return changes
    }

    // MARK: - Dropping a tile

    /// Where a dragged tile lands.
    public struct Drop: Hashable, Sendable {
        /// Every tile where it lands, in this layout's coordinates — what the drag preview draws.
        public let preview: ArrangementLayout
        /// The same arrangement with the main display back at (0, 0) — what gets applied.
        public let result: ArrangementLayout
        /// Tiles other than the dragged one that move with it: peers shifted aside for an insertion,
        /// or closing the gap the dragged tile left.
        public let displaced: [DisplayRecordID]
    }

    /// Places tile `id` as close as possible to `proposed` (its dragged origin) on a valid spot:
    /// beside or above/below another tile, or inserted at a seam between two touching tiles (the
    /// peers on the far side shift aside). If lifting the tile out splits the others, the gap it
    /// leaves closes. Nil when the tile is unknown, alone, or no valid spot exists; a drop that puts
    /// everything back where it was has no `originChanges`.
    public func dropping(_ id: DisplayRecordID, at proposed: DisplayOrigin, snapping: Bool) -> Drop? {
        guard let index = tiles.firstIndex(where: { $0.id == id }), tiles.count > 1 else { return nil }
        let moving = tiles[index].frame
        let otherIndices = tiles.indices.filter { $0 != index }
        let others = otherIndices.map { tiles[$0].frame }

        var bases = [others]
        if !Self.isConnected(others) {
            bases += Self.closingGap(of: moving, in: others).filter(Self.isValid)
        }

        var best: (cost: Int64, displaced: Int, frame: ArrangementRect, others: [ArrangementRect])?
        for (number, base) in bases.enumerated() {
            // Where it was is always a valid fallback (in a valid layout), so a tile that can't go
            // anywhere better — say the one bridging two others — stays put instead of failing.
            let stay = number == 0 ? [(frame: moving, others: base)] : []
            for candidate in stay + Self.placements(width: moving.width, height: moving.height, near: proposed,
                                                    among: base, snapping: snapping) {
                guard Self.isValid(candidate.others + [candidate.frame]) else { continue }
                let displaced = zip(candidate.others, others).filter { $0 != $1 }.count
                let cost = Self.squaredDistance(candidate.frame.origin, proposed)
                if let current = best, (current.cost, current.displaced) <= (cost, displaced) { continue }
                best = (cost, displaced, candidate.frame, candidate.others)
            }
        }
        guard let best else { return nil }

        var preview = self
        for (position, tileIndex) in otherIndices.enumerated() {
            preview.tiles[tileIndex].frame = best.others[position]
        }
        preview.tiles[index].frame = best.frame
        let displaced = otherIndices.enumerated()
            .filter { best.others[$0.offset] != others[$0.offset] }
            .map { tiles[$0.element].id }
        return Drop(preview: preview, result: preview.normalized(), displaced: displaced)
    }

    /// Every spot a `width`×`height` tile could take against `base`, each with the others' frames
    /// (shifted for a seam insertion). Validity is checked by the caller.
    static func placements(width: Int, height: Int, near proposed: DisplayOrigin,
                           among base: [ArrangementRect], snapping: Bool)
        -> [(frame: ArrangementRect, others: [ArrangementRect])] {
        let xSpans = base.map { (start: $0.x, length: $0.width) }
        let ySpans = base.map { (start: $0.y, length: $0.height) }
        func ys(in range: ClosedRange<Int>) -> [Int] {
            edgeCoordinates(proposed.y, in: range, length: height, spans: ySpans, snapping: snapping)
        }
        func xs(in range: ClosedRange<Int>) -> [Int] {
            edgeCoordinates(proposed.x, in: range, length: width, spans: xSpans, snapping: snapping)
        }
        func rect(_ x: Int, _ y: Int) -> ArrangementRect {
            ArrangementRect(x: x, y: y, width: width, height: height)
        }

        var out: [(frame: ArrangementRect, others: [ArrangementRect])] = []
        for neighbour in base {
            for y in ys(in: (neighbour.y - height)...neighbour.maxY) {
                out.append((rect(neighbour.x - width, y), base))
                out.append((rect(neighbour.maxX, y), base))
            }
            for x in xs(in: (neighbour.x - width)...neighbour.maxX) {
                out.append((rect(x, neighbour.y - height), base))
                out.append((rect(x, neighbour.maxY), base))
            }
        }

        // Seam insertion: between two tiles that share an edge, everything from the seam onward
        // shifts by the dragged tile's size so it fits in between.
        for a in base {
            for b in base where a != b {
                if a.maxX == b.x && a.y < b.maxY && b.y < a.maxY {
                    let seam = a.maxX
                    let shifted = base.map { $0.x >= seam ? $0.offsetBy(dx: width, dy: 0) : $0 }
                    for y in ys(in: (min(a.y, b.y) - height)...max(a.maxY, b.maxY)) {
                        out.append((rect(seam, y), shifted))
                    }
                }
                if a.maxY == b.y && a.x < b.maxX && b.x < a.maxX {
                    let seam = a.maxY
                    let shifted = base.map { $0.y >= seam ? $0.offsetBy(dx: 0, dy: height) : $0 }
                    for x in xs(in: (min(a.x, b.x) - width)...max(a.maxX, b.maxX)) {
                        out.append((rect(x, seam), shifted))
                    }
                }
            }
        }
        return out
    }

    /// The coordinates along a contact edge worth trying, ascending. The stops: both ends of
    /// `range` (the outer corners, where the tile still just touches its neighbour) and, for every
    /// other tile, its leading edge, trailing edge and centre (aligned), and the spots just touching
    /// it from either side. Snapping tries only the stops; free placement also tries the dropped
    /// coordinate itself, kept within `range`. The cheapest valid one wins, so a stop is used in
    /// free placement only when the dropped spot is blocked.
    static func edgeCoordinates(_ wanted: Int, in range: ClosedRange<Int>, length: Int,
                                spans: [(start: Int, length: Int)], snapping: Bool) -> [Int] {
        var candidates: Set<Int> = [range.lowerBound, range.upperBound]
        for span in spans {
            candidates.insert(span.start)
            candidates.insert(span.start + span.length - length)
            candidates.insert(span.start + floorDivide(span.length - length, by: 2))
            candidates.insert(span.start - length)
            candidates.insert(span.start + span.length)
        }
        if !snapping { candidates.insert(min(max(wanted, range.lowerBound), range.upperBound)) }
        return candidates.filter(range.contains).sorted()
    }

    /// Lifting `moving` out of a row or column can leave the others in two pieces; these are the
    /// arrangements with the far piece moved back by the lifted tile's width or height.
    static func closingGap(of moving: ArrangementRect, in others: [ArrangementRect]) -> [[ArrangementRect]] {
        [others.map { $0.x >= moving.maxX ? $0.offsetBy(dx: -moving.width, dy: 0) : $0 },
         others.map { $0.y >= moving.maxY ? $0.offsetBy(dx: 0, dy: -moving.height) : $0 }]
    }

    static func isValid(_ frames: [ArrangementRect]) -> Bool {
        for i in frames.indices {
            for j in frames.indices where j > i && frames[i].overlaps(frames[j]) { return false }
        }
        return isConnected(frames)
    }

    /// Every frame reaches every other through edge contacts (a graph walk from the first).
    static func isConnected(_ frames: [ArrangementRect]) -> Bool {
        guard !frames.isEmpty else { return true }
        var reached: Set<Int> = [0]
        var queue = [0]
        while let current = queue.popLast() {
            for next in frames.indices where !reached.contains(next) && frames[current].touches(frames[next]) {
                reached.insert(next)
                queue.append(next)
            }
        }
        return reached.count == frames.count
    }

    private static func squaredDistance(_ a: DisplayOrigin, _ b: DisplayOrigin) -> Int64 {
        let dx = Int64(a.x - b.x)
        let dy = Int64(a.y - b.y)
        return dx * dx + dy * dy
    }

    private static func floorDivide(_ value: Int, by divisor: Int) -> Int {
        let quotient = value / divisor
        return (value % divisor != 0 && (value < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }

    // MARK: - Checking what macOS did

    /// How the arrangement read back after applying `planned` to `before`.
    public enum ApplyOutcome: Hashable, Sendable {
        /// Exactly as planned.
        case applied
        /// Something moved, but macOS placed the displays differently from the plan.
        case adjusted
        /// Nothing moved.
        case nothingMoved
        /// A desktop appeared or vanished, or a mirror set gained or lost a member.
        case desktopsChanged
        /// The menu bar ended up on a different display than planned.
        case mainChanged
    }

    public static func outcome(planned: ArrangementLayout, before: ArrangementLayout,
                               after: ArrangementLayout) -> ApplyOutcome {
        func sets(_ layout: ArrangementLayout) -> Set<[DisplayRecordID]> {
            Set(layout.tiles.map { [$0.id] + $0.mirrorTargets })
        }
        guard sets(after) == sets(before) else { return .desktopsChanged }
        guard after.mainID == planned.mainID else { return .mainChanged }
        func frames(_ layout: ArrangementLayout) -> [DisplayRecordID: ArrangementRect] {
            Dictionary(layout.tiles.map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        }
        if frames(after) == frames(before) { return .nothingMoved }
        return frames(after) == frames(planned) ? .applied : .adjusted
    }
}

/// Maps the arrangement onto a canvas of a given size: uniformly scaled and centred, with room
/// around the outermost tiles so a tile dropped beside them is still (mostly) drawn.
public struct ArrangementCanvasMapping: Hashable, Sendable {
    public let scale: Double
    public let offsetX: Double
    public let offsetY: Double

    public init(layout: ArrangementLayout, canvasWidth: Double, canvasHeight: Double) {
        guard let bounds = layout.bounds, bounds.width > 0, bounds.height > 0,
              canvasWidth > 0, canvasHeight > 0 else {
            scale = 1
            offsetX = canvasWidth / 2
            offsetY = canvasHeight / 2
            return
        }
        // Half the largest tile on every side: the space a neighbour dropped there mostly occupies.
        let marginX = Double(layout.tiles.map(\.frame.width).max() ?? 0) / 2
        let marginY = Double(layout.tiles.map(\.frame.height).max() ?? 0) / 2
        let fitWidth = Double(bounds.width) + 2 * marginX
        let fitHeight = Double(bounds.height) + 2 * marginY
        scale = min(canvasWidth / fitWidth, canvasHeight / fitHeight)
        offsetX = canvasWidth / 2 - (Double(bounds.x) + Double(bounds.width) / 2) * scale
        offsetY = canvasHeight / 2 - (Double(bounds.y) + Double(bounds.height) / 2) * scale
    }

    /// A desktop rectangle on the canvas: (x, y, width, height) in canvas points.
    public func canvasRect(_ rect: ArrangementRect) -> (x: Double, y: Double, width: Double, height: Double) {
        (Double(rect.x) * scale + offsetX, Double(rect.y) * scale + offsetY,
         Double(rect.width) * scale, Double(rect.height) * scale)
    }

    /// The desktop point under a canvas point.
    public func desktopPoint(canvasX: Double, canvasY: Double) -> (x: Double, y: Double) {
        ((canvasX - offsetX) / scale, (canvasY - offsetY) / scale)
    }

    /// A canvas drag translated to whole desktop points.
    public func desktopDelta(canvasDX: Double, canvasDY: Double) -> (dx: Int, dy: Int) {
        (Int((canvasDX / scale).rounded()), Int((canvasDY / scale).rounded()))
    }
}
