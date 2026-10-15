// SPDX-License-Identifier: GPL-3.0-or-later
// Original clean-room implementation for FreeDisplay.
import Foundation

/// The physical image size macOS reports for a display (`CGDisplayScreenSize`, millimetres), and
/// the densities that follow from it. Nil-constructed when the size is unknown, so nothing
/// downstream can compute a density from a missing measurement.
public struct DisplayPhysicalSize: Hashable, Sendable {
    public let widthMM: Double
    public let heightMM: Double

    public init?(widthMM: Double, heightMM: Double) {
        guard widthMM.isFinite, heightMM.isFinite, widthMM > 0, heightMM > 0 else { return nil }
        self.widthMM = widthMM
        self.heightMM = heightMM
    }

    public var diagonalInches: Double { (widthMM * widthMM + heightMM * heightMM).squareRoot() / 25.4 }

    /// Pixels per inch along the diagonal. The diagonal doesn't depend on which axis the reported
    /// millimetres belong to, so a rotated display can't pair the wrong axes.
    public func density(width: Int, height: Int) -> Double? {
        guard width > 0, height > 0 else { return nil }
        return (Double(width * width + height * height)).squareRoot() / diagonalInches
    }
}

/// Everything the per-display report states, gathered by the app at the moment the report is
/// opened. Optionals mean "not known": they are written as unknown, never as false or zero.
public struct DisplayReportFacts: Sendable {
    public enum Presence: Hashable, Sendable {
        case connected
        /// Not online: only what was saved about it can be reported.
        case savedOnly
    }

    public enum BrightnessRoute: Hashable, Sendable {
        /// macOS's own brightness control (DisplayServices) — built-in and Apple displays.
        case system
        case ddc
        case softwareGamma
        /// Brightness hasn't been read for this display yet.
        case notResolved
    }

    public struct DDC: Hashable, Sendable {
        public enum Availability: Hashable, Sendable {
            /// The public-API-only build has no DDC.
            case notInThisBuild
            /// Built-in panels aren't driven over DDC.
            case notApplicable
            /// FreeDisplay deliberately sends no DDC to this display; the text says why.
            case refused(String)
            case available
        }
        public var availability: Availability
        /// VCP codes the monitor's capability string lists; nil when it hasn't been read.
        public var advertisedCodes: [UInt8]?
        /// VCP codes whose current value the monitor answered.
        public var answeredCodes: [UInt8]
        public var failedWriteCodes: [UInt8]
        public var ignoredWriteCodes: [UInt8]

        public init(availability: Availability, advertisedCodes: [UInt8]? = nil, answeredCodes: [UInt8] = [],
                    failedWriteCodes: [UInt8] = [], ignoredWriteCodes: [UInt8] = []) {
            self.availability = availability
            self.advertisedCodes = advertisedCodes
            self.answeredCodes = answeredCodes
            self.failedWriteCodes = failedWriteCodes
            self.ignoredWriteCodes = ignoredWriteCodes
        }
    }

    public enum EDIDSource: Hashable, Sendable {
        case matched([UInt8])
        case ambiguous(candidates: Int)
        case notFound
        case unidentifiedTarget
        case notRead
    }

    public var appName: String
    public var appVersion: String
    /// Already formatted for the reader.
    public var generatedAt: String
    public var presence: Presence

    public var name: String
    public var alias: String?
    /// The name macOS shows (`NSScreen.localizedName`).
    public var systemName: String?
    public var displayClass: DisplayClass
    public var physicalPresence: PhysicalPresence?
    public var recordID: String
    public var cgDisplayID: UInt32?
    public var uuid: String?
    public var vendorNumber: UInt32?
    public var modelNumber: UInt32?
    /// 0 = not programmed; nil = unknown.
    public var serialNumber: UInt32?
    public var ioServicePath: String?
    public var transport: ConnectionTransport

    public var isActive: Bool?
    public var isAsleep: Bool?
    public var isMain: Bool?
    public var mirrorSourceName: String?
    public var origin: DisplayOrigin?
    public var rotationDegrees: Int?
    public var lastSeen: String?

    public var currentMode: DisplayMode?
    /// `NSScreen.backingScaleFactor`.
    public var backingScaleFactor: Double?
    /// The modes as Core Graphics listed them, duplicates included.
    public var listedModes: [DisplayModeOption]
    public var physicalSize: DisplayPhysicalSize?

    public var brightness: BrightnessRoute
    public var ddc: DDC
    /// Core Graphics error of the last rejected gamma write, nil when the last one landed.
    public var gammaWriteError: Int32?
    /// Gamma writes are paused because a custom colour profile is assigned somewhere.
    public var gammaPausedForCustomProfile: Bool
    public var colorProfileName: String?
    public var edrHeadroom: Double?
    public var potentialEDRHeadroom: Double?
    /// Whether HDR output is on, nil when nothing observed it (the normal case today).
    public var hdrOutput: Bool?

    public var edid: EDIDSource

    /// The refresh-interval range macOS reports for the screen (`NSScreen`), nil when it reports none.
    public var refreshRange: ReportedRefreshRange?
    /// The luminance anchors the user configured for this display, nil when none are stored.
    public var luminanceAnchors: LuminanceAnchorSettings?
    /// The brightness control's current position (0...1), when it has been read.
    public var brightnessLevel: Double?

    public init(appName: String, appVersion: String, generatedAt: String, presence: Presence, name: String,
                displayClass: DisplayClass, recordID: String) {
        self.appName = appName
        self.appVersion = appVersion
        self.generatedAt = generatedAt
        self.presence = presence
        self.name = name
        self.displayClass = displayClass
        self.recordID = recordID
        self.transport = .unknown
        self.listedModes = []
        self.brightness = .notResolved
        self.ddc = DDC(availability: .available)
        self.gammaPausedForCustomProfile = false
        self.edid = .notRead
    }
}

/// Builds the per-display information report: identity, state, the current and every listed
/// mode, physical size, capabilities and connection, with unknowns kept visible as unknown.
public enum DisplayInformationReport {
    public static func build(_ facts: DisplayReportFacts, _ l: ReportLocalizer = .english) -> InfoReport {
        var header = ["\(facts.appName) \(facts.appVersion)", l.fill("Generated %1", facts.generatedAt)]
        if facts.presence == .savedOnly {
            header.append(l("This display isn’t connected: only saved information is shown."))
        }
        var sections = [identity(facts, l)]
        if facts.presence == .connected {
            sections.append(state(facts, l))
            sections.append(currentMode(facts, l))
            sections.append(RefreshTimingReport.section(nominalHz: facts.currentMode?.refreshHz,
                                                        range: facts.refreshRange, l))
            sections.append(physical(facts, l))
            sections.append(modes(facts, l))
            sections.append(capabilities(facts, l))
        }
        sections.append(luminance(facts, l))
        sections.append(connection(facts, l))
        sections.append(contentsOf: edid(facts, l))
        return InfoReport(
            title: l.fill("Display report: %1", facts.name), header: header,
            sections: sections.filter { !$0.isEmpty },
            footer: [l("This report can include serial numbers, UUIDs and registry paths that identify your hardware. Review it before sharing.")])
    }

    /// `<name>_report.txt`, with characters a file name can't carry replaced.
    public static func suggestedFileName(displayName: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.controlCharacters).union(.newlines)
        let cleaned = displayName.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "Display" : cleaned) + "_report.txt"
    }

    public static func classLabel(_ displayClass: DisplayClass, presence: PhysicalPresence?, _ l: ReportLocalizer) -> String {
        let base: String
        switch displayClass {
        case .builtIn: base = l("Built-in")
        case .external: base = l("External")
        case .projector: base = l("Projector")
        case .television: base = l("Television")
        case .sidecar: base = "Sidecar"
        case .airplay: base = "AirPlay"
        case .virtual: base = l("Virtual")
        case .headlessAdapter: base = l("Headless adapter")
        case .unknown: base = l("Unknown")
        }
        // The provider classes every non-built-in screen as external; without hardware evidence it
        // may as well be a virtual, Sidecar, AirPlay or DisplayLink screen — or a physical one
        // whose hardware node another display also matches — so don't assert it.
        if displayClass == .external, presence == .unverified {
            return l("External or virtual (not confirmed as display hardware)")
        }
        if displayClass == .external, presence == .virtual { return l("Virtual") }
        return base
    }

    // MARK: Sections

    static func identity(_ f: DisplayReportFacts, _ l: ReportLocalizer) -> InfoReport.Section {
        var rows: [InfoReport.Row] = [.init(l("Name"), f.name)]
        if let alias = f.alias, !alias.isEmpty { rows.append(.init(l("Custom name"), alias)) }
        if let system = f.systemName { rows.append(.init(l("Name in macOS"), system)) }
        rows.append(.init(l("Type"), classLabel(f.displayClass, presence: f.physicalPresence, l)))
        rows.append(.init(l("Hardware evidence"), presenceText(f.physicalPresence, l)))
        rows.append(.init(l("Vendor number"), numberText(f.vendorNumber, placeholder: unknownVendor, l)))
        rows.append(.init(l("Model number"), numberText(f.modelNumber, placeholder: genericProduct, l)))
        // Core Graphics returns 0 both for an unprogrammed serial and when it can't tell.
        rows.append(.init(l("Serial number"), f.serialNumber.map { serial in
            serial == 0 ? l("Not reported") : serial == 0xFFFF_FFFF ? l("Unknown") : "\(serial)"
        } ?? l("Unknown")))
        rows.append(.init("UUID", f.uuid ?? l("Unknown")))
        rows.append(.init(l("Display ID (this session)"), f.cgDisplayID.map { "\($0)" } ?? l("Not connected")))
        rows.append(.init(l("App record"), f.recordID))
        if let seen = f.lastSeen { rows.append(.init(l("Last seen"), seen)) }
        return InfoReport.Section(title: l("Identity"), rows: rows)
    }

    static func state(_ f: DisplayReportFacts, _ l: ReportLocalizer) -> InfoReport.Section {
        var rows: [InfoReport.Row] = []
        rows.append(.init(l("Active"), optionalYesNo(f.isActive, l)))
        rows.append(.init(l("Asleep"), optionalYesNo(f.isAsleep, l)))
        rows.append(.init(l("Main display"), optionalYesNo(f.isMain, l)))
        rows.append(.init(l("Mirrors"), f.mirrorSourceName ?? l("No")))
        if let origin = f.origin { rows.append(.init(l("Position"), l.fill("%1, %2 points", "\(origin.x)", "\(origin.y)"))) }
        if let rotation = f.rotationDegrees { rows.append(.init(l("Rotation"), "\(rotation)°")) }
        return InfoReport.Section(title: l("State"), rows: rows)
    }

    static func currentMode(_ f: DisplayReportFacts, _ l: ReportLocalizer) -> InfoReport.Section {
        var section = InfoReport.Section(title: l("Current mode"))
        guard let mode = f.currentMode else {
            section.rows = [.init(l("Mode"), l("macOS didn’t report the current mode"))]
            return section
        }
        let options = DisplayModeCatalog.distinct(f.listedModes)
        section.rows = [
            .init(l("Logical size"), l.fill("%1 × %2 points", "\(mode.pointWidth)", "\(mode.pointHeight)")),
            .init(l("Framebuffer"), l.fill("%1 × %2 pixels", "\(mode.pixelWidth)", "\(mode.pixelHeight)")),
            .init(l("Refresh rate"), refreshText(mode.refreshHz, l)),
            .init(l("Density"), mode.isHiDPI ? "HiDPI" : "LoDPI"),
            .init(l("Bit depth"), mode.bitDepth.map { l.fill("%1-bit", "\($0)") } ?? l("Not reported by macOS")),
        ]
        if let scale = f.backingScaleFactor { section.rows.append(.init(l("Backing scale"), "\(l.decimal(scale, 2))×")) }
        let option = options.first { DisplayModeChoices.matches($0.mode, requested: mode) }
            ?? DisplayModeOption(mode: mode, isNative: false, isDefault: false)
        let tags = DisplayModeCatalog.tags(for: option, among: options, current: mode).filter { $0 != .current }
        section.rows.append(.init(l("Markers"), tags.map { DisplayModeCatalog.tagLabel($0, l) }.joined(separator: ", ")))
        section.notes = [l("The logical size is the workspace; the framebuffer is the image macOS renders. Neither is the signal sent over the cable or the panel’s physical resolution.")]
        return section
    }

    static func physical(_ f: DisplayReportFacts, _ l: ReportLocalizer) -> InfoReport.Section {
        var section = InfoReport.Section(title: l("Physical size"))
        var rows: [InfoReport.Row] = []
        // macOS estimates a size (at 72 dpi from the screen's bounds) when it has none from the
        // display, so a size is stated only for a screen with display hardware behind it.
        let size = f.physicalPresence == .physical ? f.physicalSize : nil
        if let size {
            rows.append(.init(l("Image size"), l.fill("%1 × %2 mm", l.decimal(size.widthMM, 1), l.decimal(size.heightMM, 1))))
            rows.append(.init(l("Diagonal"), l.fill("%1 inches", l.decimal(size.diagonalInches, 1))))
        } else if f.physicalSize != nil {
            rows.append(.init(l("Size"), l("Not stated: macOS may only estimate the size of a screen without display hardware")))
        } else {
            rows.append(.init(l("Size"), l("Not reported by macOS")))
        }
        if let edidSize = edidSizeText(f.edid, l) { rows.append(.init(l("Size in the EDID"), edidSize)) }
        let options = DisplayModeCatalog.distinct(f.listedModes)
        let native = DisplayModeCatalog.nativeFramebuffer(options)
        if let native {
            rows.append(.init(l("Native-flagged framebuffer"), l.fill("%1 × %2 pixels", "\(native.width)", "\(native.height)")))
        }
        if let size {
            if let native, let ppi = size.density(width: native.width, height: native.height) {
                rows.append(.init(l("Pixel density"), l.fill("%1 pixels per inch", l.decimal(ppi, 1))))
            } else {
                rows.append(.init(l("Pixel density"), l("Unknown: no mode is flagged native")))
            }
            if let mode = f.currentMode, let points = size.density(width: mode.pointWidth, height: mode.pointHeight) {
                rows.append(.init(l("Interface density"), l.fill("%1 points per inch at the current mode", l.decimal(points, 1))))
            }
            section.notes = [l("The size is what macOS reports, normally from the display’s EDID; it can be rounded, and for projectors and TVs it can be wrong. When a display gives no size, macOS estimates one at 72 dpi.")]
        } else {
            section.notes = [l("Without a physical size no pixel density can be calculated.")]
        }
        section.rows = rows
        return section
    }

    /// The image size the EDID itself states: the basic parameters' centimetres, else the
    /// preferred timing's millimetres.
    static func edidSizeText(_ source: DisplayReportFacts.EDIDSource, _ l: ReportLocalizer) -> String? {
        guard case .matched(let bytes) = source, let base = EDIDDecoder.decode(bytes).base else { return nil }
        if case .centimeters(let width, let height) = base.screenSize {
            return l.fill("%1 × %2 cm", "\(width)", "\(height)")
        }
        if let timing = base.detailedTimings.first, let width = timing.imageWidthMM, let height = timing.imageHeightMM {
            return l.fill("%1 × %2 mm", "\(width)", "\(height)")
        }
        return nil
    }

    static func modes(_ f: DisplayReportFacts, _ l: ReportLocalizer) -> InfoReport.Section {
        let summary = DisplayModeCatalog.summary(listed: f.listedModes)
        let options = DisplayModeCatalog.distinct(f.listedModes)
        var section = InfoReport.Section(title: l("Display modes"))
        section.rows = [
            .init(l("Listed by macOS"), "\(summary.listed)"),
            .init(l("Distinct modes"), "\(summary.distinct)"),
            .init(l("Usable for the desktop"), "\(summary.ordinary)"),
            .init(l("Not for desktop use"), "\(summary.notForDesktop)"),
            .init(l("Not flagged valid"), "\(summary.flaggedInvalid)"),
            .init(l("Not flagged safe"), "\(summary.flaggedUnsafe)"),
            .init(l("HiDPI / LoDPI"), "\(summary.hiDPI) / \(summary.loDPI)"),
        ]
        let rates = DisplayModeCatalog.facets(options).refreshRates.map { refreshText($0.hertz, l) }
        if !rates.isEmpty { section.rows.append(.init(l("Refresh rates"), rates.joined(separator: ", "))) }
        let lines = options.map { option -> String in
            let tags = DisplayModeCatalog.tags(for: option, among: options, current: f.currentMode)
            return modeText(option.mode, l) + (tags.isEmpty ? "" : " [" + tags.map { DisplayModeCatalog.tagLabel($0, l) }.joined(separator: ", ") + "]")
        }
        if !lines.isEmpty { section.rows.append(.init(l("All modes"), lines.joined(separator: "\n"))) }
        section.notes = [l("macOS lists only the modes the display, connection and GPU offer now; OpenDisplay can’t add modes.")]
        if summary.duplicates > 0 {
            section.notes.append(l.fill("Entries that repeat another mode’s size, framebuffer and rate exactly, shown once: %1.", "\(summary.duplicates)"))
        }
        return section
    }

    static func capabilities(_ f: DisplayReportFacts, _ l: ReportLocalizer) -> InfoReport.Section {
        var section = InfoReport.Section(title: l("Capabilities"))
        let route: String
        switch f.brightness {
        case .system: route = l("macOS brightness control (DisplayServices)")
        case .ddc: route = l("Monitor hardware over DDC")
        case .softwareGamma: route = l("Software (gamma)")
        case .notResolved: route = l("Not determined yet")
        }
        section.rows.append(.init(l("Brightness control"), route))
        switch f.ddc.availability {
        case .notInThisBuild: section.rows.append(.init("DDC", l("Not available in this build")))
        case .notApplicable: section.rows.append(.init("DDC", l("Not used for built-in displays")))
        case .refused(let reason): section.rows.append(.init("DDC", reason))
        case .available:
            section.rows.append(.init(l("DDC capability list"), f.ddc.advertisedCodes.map { codes in
                codes.isEmpty ? l("Read, lists no controls") : codes.map(vcpText).joined(separator: " ")
            } ?? l("Not read")))
            section.rows.append(.init(l("DDC answered reads for"), f.ddc.answeredCodes.isEmpty
                ? l("None yet") : f.ddc.answeredCodes.map(vcpText).joined(separator: " ")))
            if !f.ddc.failedWriteCodes.isEmpty {
                section.rows.append(.init(l("DDC writes that failed"), f.ddc.failedWriteCodes.map(vcpText).joined(separator: " ")))
            }
            if !f.ddc.ignoredWriteCodes.isEmpty {
                section.rows.append(.init(l("DDC writes the monitor ignored"), f.ddc.ignoredWriteCodes.map(vcpText).joined(separator: " ")))
            }
            section.notes.append(l("A control in the capability list is advertised, not verified: only answered reads show that DDC works."))
        }
        let gamma: String
        if f.gammaPausedForCustomProfile {
            gamma = l("Paused: a custom colour profile is assigned")
        } else if let error = f.gammaWriteError {
            gamma = l.fill("Last write rejected (error %1)", "\(error)")
        } else {
            // Nothing records a successful write, so the absence of a failure is all that's known.
            gamma = l("No rejected write recorded")
        }
        section.rows.append(.init(l("Software gamma"), gamma))
        section.rows.append(.init(l("Colour profile"), f.colorProfileName ?? l("Unknown")))
        if let current = f.edrHeadroom, let potential = f.potentialEDRHeadroom {
            section.rows.append(.init(l("EDR headroom"), l.fill("%1× now, %2× potential", l.decimal(current, 2), l.decimal(potential, 2))))
        }
        section.rows.append(.init(l("HDR output"), f.hdrOutput.map { l.yesNo($0) } ?? l("Not observed")))
        return section
    }

    /// Entered and EDID-stated luminance, with an estimate for the current brightness where the
    /// brightness route allows one. Saved-only reports keep the entered values.
    static func luminance(_ f: DisplayReportFacts, _ l: ReportLocalizer) -> InfoReport.Section {
        var reported = ReportedLuminance()
        if case .matched(let bytes) = f.edid { reported = ReportedLuminance.from(EDIDDecoder.decode(bytes)) }
        let input = f.presence == .connected
            ? luminanceEstimateInput(f.brightness, level: f.brightnessLevel, l)
            : (position: nil, note: nil)
        return LuminanceReport.section(
            settings: f.luminanceAnchors, reported: reported,
            includeHDR: LuminanceAnchorResolver.showsHDRAnchors(reported: reported, potentialEDRHeadroom: f.potentialEDRHeadroom,
                                                                settings: f.luminanceAnchors),
            brightnessPosition: input.position, estimateNote: input.note, l)
    }

    /// Which brightness positions a luminance estimate is given for. Hardware and macOS brightness
    /// get the linear estimate between the SDR anchors; software brightness gets none, because it
    /// scales signal values and how the panel turns those into light isn't known.
    public static func luminanceEstimateInput(_ route: DisplayReportFacts.BrightnessRoute, level: Double?,
                                              _ l: ReportLocalizer = .english) -> (position: Double?, note: String?) {
        switch route {
        case .system, .ddc:
            guard let level else { return (nil, l("No estimate: the brightness position isn’t known")) }
            return (level, nil)
        case .softwareGamma:
            return (nil, l("No estimate for software brightness: it scales the signal, and how the panel turns that into light isn’t known"))
        case .notResolved:
            return (nil, l("No estimate: brightness hasn’t been read yet"))
        }
    }

    static func connection(_ f: DisplayReportFacts, _ l: ReportLocalizer) -> InfoReport.Section {
        var section = InfoReport.Section(title: l("Connection"))
        let transport: String
        switch f.transport {
        case .internalPanel: transport = l("Internal panel")
        case .usbCDisplayPort: transport = l("USB-C (DisplayPort)")
        case .thunderbolt: transport = "Thunderbolt"
        case .hdmi: transport = "HDMI"
        case .displayPort: transport = "DisplayPort"
        case .dock: transport = l("Dock")
        case .kvm: transport = "KVM"
        case .wireless: transport = l("Wireless")
        case .virtual: transport = l("Virtual")
        case .unknown: transport = l("Not reported")
        }
        section.rows.append(.init(l("Connection type"), transport))
        if let path = f.ioServicePath { section.rows.append(.init(l("Registry path"), path)) }
        section.notes = [l("Link rate, lane count, DSC and HDCP aren’t read by this version.")]
        return section
    }

    static func edid(_ f: DisplayReportFacts, _ l: ReportLocalizer) -> [InfoReport.Section] {
        var section = InfoReport.Section(title: "EDID")
        switch f.edid {
        case .notRead:
            section.rows = [.init(l("Source"), l("Not read"))]
            return [section]
        case .ambiguous(let candidates):
            section.rows = [.init(l("Source"), l.fill("Ambiguous: %1 different EDIDs carry this display’s vendor, product code and serial", "\(candidates)"))]
            return [section]
        case .notFound:
            section.rows = [.init(l("Source"), l("Not found: no EDID macOS exposes carries this display’s vendor, product code and serial"))]
            return [section]
        case .unidentifiedTarget:
            section.rows = [.init(l("Source"), l("Unavailable: macOS reports no vendor or product code to match an EDID against"))]
            return [section]
        case .matched(let bytes):
            section.rows = [.init(l("Source"), l("Read from the macOS registry, matched by vendor, product code and serial")),
                            .init("Base64", EDIDByteFormat.base64.render(bytes))]
            section.notes = [l("Decoded values are what the EDID states — advertised capability and receiver maxima, not measured values or the current link.")]
            let decoded = EDIDDecoder.decode(bytes)
            let decodedSections = EDIDReportFormatter.sections(decoded, l).map { sub in
                InfoReport.Section(title: "EDID — " + sub.title, rows: sub.rows, notes: sub.notes)
            }
            return [section] + decodedSections
        }
    }

    // MARK: Values

    static func modeText(_ mode: DisplayMode, _ l: ReportLocalizer) -> String {
        l.fill("%1 × %2 points, framebuffer %3 × %4 pixels, %5",
               "\(mode.pointWidth)", "\(mode.pointHeight)", "\(mode.pixelWidth)", "\(mode.pixelHeight)",
               refreshText(mode.refreshHz, l))
    }

    static func refreshText(_ hz: Double, _ l: ReportLocalizer) -> String {
        hz > 0 ? l.fill("%1 Hz", l.decimal(hz, 2)) : l("refresh rate not reported")
    }

    /// What Core Graphics reports for a display it can't identify (`kDisplayVendorIDUnknown`,
    /// 'unkn', and `kDisplayProductIDGeneric`).
    static let unknownVendor: UInt32 = 0x756E_6B6E
    static let genericProduct: UInt32 = 0x0717

    static func numberText(_ value: UInt32?, placeholder: UInt32, _ l: ReportLocalizer) -> String {
        guard let value, value != 0, value != 0xFFFF_FFFF else { return l("Unknown") }
        if value == placeholder { return l("Unknown (macOS reports its placeholder value)") }
        return "\(value) (\(String(format: "0x%04X", value)))"
    }

    static func optionalYesNo(_ value: Bool?, _ l: ReportLocalizer) -> String {
        value.map { l.yesNo($0) } ?? l("Unknown")
    }

    static func presenceText(_ presence: PhysicalPresence?, _ l: ReportLocalizer) -> String {
        switch presence {
        case .physical: return l("Display hardware found")
        case .virtual: return l("Window-server screen without display hardware")
        case .unverified: return l("Not confirmed: no display hardware could be tied to it alone")
        case nil: return l("Not assessed")
        }
    }

    static func vcpText(_ code: UInt8) -> String { String(format: "%02X", code) }
}
