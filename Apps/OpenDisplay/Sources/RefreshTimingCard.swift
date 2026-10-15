// SPDX-License-Identifier: GPL-3.0-or-later
// Original FreeDisplay implementation: the refresh timing reporter (AM-13). Read-only, public APIs.
#if os(macOS)
import AppKit
import DisplayDomain
import OpenDisplayDesignSystem
import QuartzCore
import SwiftUI

/// Feeds one screen's display-link callbacks into a `RefreshMeasurementSession` — only between
/// an explicit Start and Stop. The link asks for nothing and changes nothing; it is the public
/// `NSScreen.displayLink(target:selector:)` (macOS 14), the same timing source an app drawing on
/// that screen gets.
@MainActor
final class RefreshTimingMeasurer: NSObject, ObservableObject {
    @Published private(set) var session = RefreshMeasurementSession()
    private var link: CADisplayLink?

    func start(screen: NSScreen, mode: DisplayMode?) {
        invalidateLink()
        let link = screen.displayLink(target: self, selector: #selector(frame(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        session.start(mode: mode)
    }

    /// Ends the measurement, keeping its result. The display link holds its target strongly, so it
    /// has to be invalidated here rather than left to deinit.
    func stop(_ reason: RefreshMeasurementSession.StopReason) {
        invalidateLink()
        session.stop(reason)
    }

    func modeChanged(to mode: DisplayMode?) {
        session.modeChanged(to: mode)
    }

    @objc private func frame(_ link: CADisplayLink) {
        // A link outliving its measurement (it holds this object alive) ends itself here.
        guard session.isRunning, link === self.link else {
            link.invalidate()
            return
        }
        session.record(timestamp: link.timestamp, reportedFrameDuration: link.targetTimestamp - link.timestamp)
    }

    private func invalidateLink() {
        link?.invalidate()
        link = nil
    }
}

/// Settings → Displays → Refresh timing: the mode's nominal rate, the range macOS reports and,
/// while the user runs it, the cadence measured from display-link callbacks — each in its own row,
/// none presented as the panel's or the cable's timing.
struct RefreshTimingCard: View {
    @EnvironmentObject private var model: AppModel
    let display: DisplayObservation
    @StateObject private var measurer = RefreshTimingMeasurer()
    @State private var status: String?

    private var screen: NSScreen? { display.cgDisplayID.flatMap(DisplayScreenLookup.screen(for:)) }

    private var reportedRange: ReportedRefreshRange? {
        screen.flatMap { ReportedRefreshRange(minimumInterval: $0.minimumRefreshInterval,
                                              maximumInterval: $0.maximumRefreshInterval) }
    }

    /// Online and lit: a screen to take a display link from.
    private var isMeasurable: Bool {
        model.displays.contains { $0.recordID == display.recordID && $0.isActive } && screen != nil
    }

    var body: some View {
        let section = RefreshTimingReport.section(nominalHz: display.mode?.refreshHz, range: reportedRange,
                                                  session: measurer.session, .app)
        ODCard(title: String(localized: "Refresh timing"),
               footnote: String(localized: "A measurement runs only after you press Start, and until you press Stop, leave this page or the display goes away.")) {
            ForEach(Array(section.rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { ODDivider() }
                ODRow(row.label) {
                    Text(row.value).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ODDivider()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if measurer.session.isRunning {
                        Button("Stop Measuring") { measurer.stop(.user) }
                    } else {
                        Button("Start Measuring") { start() }.disabled(!isMeasurable)
                    }
                    Button("Copy Results") { copy(section) }
                    Spacer()
                }
                .controlSize(.small)
                Text("While measuring, this screen draws frames for FreeDisplay, which can keep a variable-refresh display at a higher rate than it would otherwise use.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(section.notes, id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
        }
        .onChange(of: display.mode) { _, mode in measurer.modeChanged(to: mode) }
        .onChange(of: isMeasurable) { _, measurable in
            if !measurable { measurer.stop(.displayUnavailable) }
        }
        .onDisappear { measurer.stop(.viewClosed) }
    }

    private func start() {
        guard let screen, isMeasurable else { return }
        status = nil
        measurer.start(screen: screen, mode: display.mode)
    }

    private func copy(_ section: InfoReport.Section) {
        let report = InfoReport(title: String(localized: "Refresh timing: \(model.displayName(for: display))"),
                                sections: [section])
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.plainText(), forType: .string)
        status = String(localized: "Results copied.")
    }
}
#endif
