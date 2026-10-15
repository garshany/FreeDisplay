// SPDX-License-Identifier: GPL-3.0-or-later
// Original FreeDisplay implementation: the per-display information report (SD-14). Read-only.
#if os(macOS)
import AppKit
import AutomationSchema
import CoreGraphics
import CoreGraphicsProvider
import DisplayDomain
import OpenDisplayDesignSystem
import SwiftUI
import UniformTypeIdentifiers

extension ReportLocalizer {
    /// Package report labels in the interface language: each English label is a catalog key
    /// that has to be added to Localizable.xcstrings by hand (Xcode can't extract runtime
    /// strings; an absent key shows the English text), and decimals use the UI language's
    /// separator, as `TrayModeCatalog.refreshText` does.
    static let app = ReportLocalizer(
        text: { $0.appLocalized },
        decimal: { value, digits in
            let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
            return value.formatted(.number.precision(.fractionLength(0...max(0, digits))).grouping(.never).locale(locale))
        })
}

/// Shared by the report and the EDID pane: the NSScreen for a Core Graphics display, if any.
enum DisplayScreenLookup {
    static func screen(for cgID: CGDirectDisplayID) -> NSScreen? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == cgID }
    }
}

extension AppModel {
    /// Gathers what the report states about a display, at the moment it is opened. Only reads:
    /// Core Graphics, NSScreen, IORegistry (EDID) and FreeDisplay's own caches. The EDID registry
    /// walk runs off the main actor.
    func informationReportFacts(for observation: DisplayObservation) async -> DisplayReportFacts {
        // A sheet keeps its opening observation. Refresh/reopen must use today's topology and mode,
        // rather than presenting that captured value as a new read.
        let observation = displays.first { $0.recordID == observation.recordID } ?? observation
        let info = Bundle.main.infoDictionary
        let appName = "FreeDisplay"
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let id = observation.recordID
        // `displays` is the current topology: a record that isn't in it is remembered, not online.
        let online = observation.cgDisplayID.map { CGDisplayIsOnline($0) != 0 } == true
            && displays.contains { $0.recordID == id }
        var facts = DisplayReportFacts(
            appName: appName, appVersion: version,
            generatedAt: Date().formatted(date: .abbreviated, time: .standard),
            presence: online ? .connected : .savedOnly,
            name: displayName(for: observation), displayClass: observation.displayClass, recordID: id.rawValue)
        let record = records[id]
        facts.alias = record?.alias
        facts.lastSeen = record?.lastSeen?.formatted(date: .abbreviated, time: .shortened)
        facts.physicalPresence = observation.physicalPresence
        facts.uuid = observation.cgUUID
        facts.ioServicePath = observation.ioServicePath
        facts.transport = observation.transport
        facts.luminanceAnchors = luminanceAnchors(for: observation)
        if let fingerprint = record?.fingerprint {
            facts.vendorNumber = fingerprint.vendorID.flatMap { UInt32(exactly: $0) }
            facts.modelNumber = fingerprint.productID.flatMap { UInt32(exactly: $0) }
            facts.serialNumber = fingerprint.serialNumber.flatMap(UInt32.init)
        }
        guard online, let cgID = observation.cgDisplayID else { return facts }

        facts.cgDisplayID = cgID
        let screen = DisplayScreenLookup.screen(for: cgID)
        facts.systemName = screen?.localizedName
        facts.vendorNumber = CGDisplayVendorNumber(cgID)
        facts.modelNumber = CGDisplayModelNumber(cgID)
        facts.serialNumber = CGDisplaySerialNumber(cgID)
        facts.isActive = observation.isActive
        facts.isAsleep = CGDisplayIsAsleep(cgID) != 0
        facts.isMain = observation.isMain
        facts.mirrorSourceName = observation.mirrorSourceID.map { source in
            displays.first { $0.recordID == source }.map(displayName(for:)) ?? source.rawValue
        }
        facts.origin = observation.origin
        facts.rotationDegrees = observation.rotation.rawValue
        facts.currentMode = CGDisplayCopyDisplayMode(cgID).map {
            DisplayMode(pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight,
                        pointWidth: $0.width, pointHeight: $0.height,
                        refreshHz: $0.refreshRate, isHiDPI: $0.pixelWidth > $0.width)
        }
        facts.backingScaleFactor = screen.map { Double($0.backingScaleFactor) }
        facts.listedModes = DisplayModeReader.listedOptions(for: cgID)
        let size = CGDisplayScreenSize(cgID)
        facts.physicalSize = DisplayPhysicalSize(widthMM: Double(size.width), heightMM: Double(size.height))

        switch brightnessMethod[id] {
        case .native: facts.brightness = .system
        case .hardware: facts.brightness = .ddc
        case .software: facts.brightness = .softwareGamma
        case nil: facts.brightness = .notResolved
        }
        #if PUBLIC_API_ONLY
        facts.ddc = .init(availability: .notInThisBuild)
        #else
        if observation.displayClass == .builtIn {
            facts.ddc = .init(availability: .notApplicable)
        } else if let refusal = ddcBindingRefusal[id] {
            facts.ddc = .init(availability: .refused(DDCStatusText.refusal(refusal)))
        } else {
            facts.ddc = .init(availability: .available,
                              advertisedCodes: ddcCapabilities[id].map { $0.supportedVCPCodes.sorted() },
                              answeredCodes: (ddcControlLevel[id] ?? [:]).keys.sorted(),
                              failedWriteCodes: (ddcWriteFailed[id] ?? []).sorted(),
                              ignoredWriteCodes: (ddcWriteIgnored[id] ?? []).sorted())
        }
        #endif
        facts.gammaWriteError = gammaWriteFailures[id]
        facts.gammaPausedForCustomProfile = !customProfileDisplays.isEmpty && !settings.allowGammaWithCustomProfiles
        facts.colorProfileName = colorProfileName[id]
        if let screen {
            facts.edrHeadroom = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
            facts.potentialEDRHeadroom = Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
            facts.refreshRange = ReportedRefreshRange(minimumInterval: screen.minimumRefreshInterval,
                                                      maximumInterval: screen.maximumRefreshInterval)
        }
        facts.brightnessLevel = brightness[id].map(Double.init)
        facts.hdrOutput = observation.hdrEnabled
        let lookup = await Task.detached(priority: .userInitiated) { EDIDReader.lookup(for: cgID) }.value
        switch lookup {
        case .matched(let bytes): facts.edid = .matched(bytes)
        case .ambiguous(let candidates): facts.edid = .ambiguous(candidates: candidates)
        case .notFound: facts.edid = .notFound
        case .unidentifiedTarget: facts.edid = .unidentifiedTarget
        }
        return facts
    }
}

/// Saves `text` as UTF-8 through a save panel; returns the outcome to show, nil when cancelled.
@MainActor
enum ReportExport {
    static func saveText(_ text: String, suggestedName: String) -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            return String(localized: "Saved \(url.lastPathComponent).")
        } catch {
            return String(localized: "Couldn’t save the report: \(error.localizedDescription)")
        }
    }
}

/// The report sheet opened from a display's Information card: collected when opened, refreshed on
/// demand, every value selectable, and the whole report copyable or exportable as UTF-8 text.
struct DisplayInformationReportSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let display: DisplayObservation
    @State private var report: InfoReport?
    @State private var loading = false
    @State private var status: String?
    /// SD-14's redaction choice: show, copy and export the report without serial numbers, UUIDs,
    /// registry paths and EDID bytes. Off by default — the full report is what explains a problem.
    @State private var hidingIdentifiers = false

    /// The report as shown, copied and exported: full, or with identifiers hidden.
    private var shownReport: InfoReport? {
        guard let report else { return nil }
        return hidingIdentifiers ? DisplayInformationReport.hidingIdentifiers(report, .app) : report
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(report?.title ?? String(localized: "Display report")).font(.headline)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            Text("The report can include serial numbers, UUIDs and registry paths that identify your hardware. Review it before sharing.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Hide serial numbers, UUIDs, registry paths and EDID bytes", isOn: $hidingIdentifiers)
                .font(.caption)
            ScrollView {
                if let report = shownReport { reportBody(report) }
            }
            .frame(minHeight: 320)
            .background(ODColor.fillQuaternary, in: RoundedRectangle(cornerRadius: 8))
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button("Refresh Report") { Task { await load() } }.disabled(loading)
                Spacer()
                Button("Copy") {
                    guard let report = shownReport else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.plainText(), forType: .string)
                    status = String(localized: "Report copied.")
                }
                .disabled(report == nil)
                Button("Export…") {
                    guard let report = shownReport else { return }
                    let name = DisplayInformationReport.suggestedFileName(displayName: model.displayName(for: display))
                    if let outcome = ReportExport.saveText(report.plainText(), suggestedName: name) { status = outcome }
                }
                .disabled(report == nil)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 520, idealHeight: 620)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let facts = await model.informationReportFacts(for: display)
        report = DisplayInformationReport.build(facts, .app)
        status = nil
    }

    private func reportBody(_ report: InfoReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(report.header, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(report.sections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title).font(.system(size: 12, weight: .semibold))
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                Text(row.label).foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                Text(row.value).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 11))
                        }
                    }
                    ForEach(section.notes, id: \.self) { note in
                        Text(note).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
