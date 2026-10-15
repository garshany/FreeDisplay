// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppIntents
import AutomationSchema
import DisplayDomain
import Foundation
import TopologyCore

// Display-targeted Shortcuts actions (IN-07, TB-05, TB-06, FB-14). Every action works through the
// running app's model — the one that holds the brightness routes, the mode-change safety gate and
// the offline ledger — and names its display by the stable record id. A display that isn't there
// fails the action with a clear message; nothing is ever redirected to the main or built-in display.

// MARK: - Display entity

/// A display as Shortcuts picks and passes it around.
struct DisplayEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Display"
    static let defaultQuery = DisplayEntityQuery()

    /// The stable `DisplayRecordID` raw value.
    let id: String
    @Property(title: "Name") var name: String
    @Property(title: "Connected") var isConnected: Bool
    @Property(title: "Main Display") var isMain: Bool
    @Property(title: "Built-in") var isBuiltIn: Bool
    private let availability: AutomationDisplayEntry.Availability

    init(_ entry: AutomationDisplayEntry) {
        id = entry.id.rawValue
        availability = entry.availability
        name = entry.name
        isConnected = entry.availability != .disconnected
        isMain = entry.isMain
        isBuiltIn = entry.isBuiltIn
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: subtitle,
                              image: .init(systemName: isBuiltIn ? "laptopcomputer" : "display"))
    }

    private var subtitle: LocalizedStringResource {
        switch availability {
        case .active: return isMain ? "Main display" : "Connected"
        case .inactive: return "Connected, not showing its own desktop"
        case .disconnected: return "Not connected"
        }
    }
}

/// Lists the current displays (main first) and the ones OpenDisplay turned off, finds them by name,
/// and brings saved ones back by id — remembered but absent displays included, so their actions can
/// say they aren't connected.
struct DisplayEntityQuery: EntityStringQuery {
    func entities(for identifiers: [DisplayEntity.ID]) async throws -> [DisplayEntity] {
        await DisplayIntentRunner.entities(for: identifiers)
    }

    func entities(matching string: String) async throws -> [DisplayEntity] {
        await DisplayIntentRunner.entities(matching: string)
    }

    func suggestedEntities() async throws -> [DisplayEntity] {
        await DisplayIntentRunner.entities(matching: "")
    }
}

// MARK: - Display mode entity

/// One exact display mode. Its id is the exact mode key, so a saved shortcut stores the whole mode
/// (size, framebuffer, refresh rate, density, depth) and is checked against what the display offers
/// when it runs.
struct DisplayModeEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Display Mode"
    static let defaultQuery = DisplayModeQuery()

    let id: String
    let mode: DisplayMode
    @Property(title: "Width (points)") var width: Int
    @Property(title: "Height (points)") var height: Int
    @Property(title: "Refresh Rate (Hz)") var refreshRate: Double
    @Property(title: "HiDPI") var isHiDPI: Bool

    init(_ mode: DisplayMode) {
        id = AutomationModeOptions.key(for: mode)
        self.mode = mode
        width = mode.pointWidth
        height = mode.pointHeight
        refreshRate = mode.refreshHz
        isHiDPI = mode.isHiDPI
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(mode.pointWidth) × \(mode.pointHeight)", subtitle: "\(details)")
    }

    private var details: String {
        var parts = [mode.isHiDPI ? String(localized: "HiDPI") : String(localized: "Standard resolution")]
        parts.append(mode.refreshHz > 0
            ? String(localized: "\(mode.refreshHz.formatted(.number.precision(.fractionLength(0...2)))) Hz")
            : String(localized: "refresh rate unknown"))
        parts.append(String(localized: "\(mode.pixelWidth) × \(mode.pixelHeight) px"))
        if let bits = mode.bitDepth { parts.append(String(localized: "\(bits)-bit")) }
        return parts.joined(separator: " · ")
    }
}

/// Brings saved modes back from their keys. The choices themselves come from the selected display
/// (`DisplayModeOptionsProvider`).
struct DisplayModeQuery: EntityQuery {
    func entities(for identifiers: [DisplayModeEntity.ID]) async throws -> [DisplayModeEntity] {
        identifiers.compactMap { AutomationModeOptions.mode(forKey: $0).map(DisplayModeEntity.init) }
    }

    func suggestedEntities() async throws -> [DisplayModeEntity] { [] }
}

/// The modes the display chosen in the same action offers right now, current mode first.
struct DisplayModeOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<SetDisplayModeIntent>(\.$display) var intent

    func results() async throws -> ItemCollection<DisplayModeEntity> {
        guard let display = intent?.display else { return ItemCollection(items: []) }
        let choices = try await DisplayIntentRunner.modeChoices(for: display)
        var sections: [ItemSection<DisplayModeEntity>] = []
        if let current = choices.current {
            sections.append(ItemSection("Current Mode", items: [DisplayModeEntity(current)]))
        }
        let others = choices.options.filter { $0 != choices.current }.map(DisplayModeEntity.init)
        sections.append(ItemSection("Available Modes", items: others))
        return ItemCollection(sections: sections)
    }
}

// MARK: - Typed results

/// How a display's brightness is driven — say which, since only some routes can be read back.
enum BrightnessControlKind: String, AppEnum {
    case native, hardware, software, unknown

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Brightness Control"
    static let caseDisplayRepresentations: [BrightnessControlKind: DisplayRepresentation] = [
        .native: "The display’s own brightness control",
        .hardware: "Monitor hardware (DDC/CI)",
        .software: "Software dimming",
        .unknown: "Unknown",
    ]
}

/// The outcome of a brightness read or change, for a shortcut to branch on.
struct BrightnessResultEntity: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Brightness Result"

    @Property(title: "Display") var display: DisplayEntity?
    @Property(title: "Brightness (%)") var percent: Int?
    @Property(title: "Requested Brightness (%)") var requestedPercent: Int?
    @Property(title: "Confirmed by the Display") var confirmed: Bool
    @Property(title: "Control") var control: BrightnessControlKind
    @Property(title: "Outcome") var outcome: CommandIntentOutcome

    init() {
        display = nil
        percent = nil
        requestedPercent = nil
        confirmed = false
        control = .unknown
        outcome = .failed
    }

    init(_ report: DisplayIntentRunner.BrightnessReport) {
        self.init()
        display = report.display.map(DisplayEntity.init)
        percent = report.percent
        requestedPercent = report.requestedPercent
        confirmed = report.confirmed
        control = report.control
        outcome = report.outcome
    }

    var displayRepresentation: DisplayRepresentation {
        let name = display?.name ?? ""
        if let percent { return DisplayRepresentation(title: "\(name): \(percent) %") }
        return DisplayRepresentation(title: "\(name): brightness unknown")
    }
}

/// What a mode change did.
enum DisplayModeOutcome: String, AppEnum {
    case alreadyInEffect, awaitingConfirmation, applied

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mode Change Outcome"
    static let caseDisplayRepresentations: [DisplayModeOutcome: DisplayRepresentation] = [
        .alreadyInEffect: "Already in this mode",
        .applied: "Mode applied",
        .awaitingConfirmation: "Changed; waiting to be kept",
    ]
}

/// The outcome of a mode change, for a shortcut to branch on.
struct DisplayModeResultEntity: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Display Mode Result"

    @Property(title: "Display") var display: DisplayEntity?
    @Property(title: "Mode") var mode: DisplayModeEntity?
    @Property(title: "Outcome") var outcome: DisplayModeOutcome
    @Property(title: "Seconds Left to Keep It") var secondsToKeep: Int?

    init() {
        display = nil
        mode = nil
        outcome = .alreadyInEffect
        secondsToKeep = nil
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: mode?.displayRepresentation.title ?? "Display Mode", subtitle: outcome.caseTitle)
    }
}

/// What Reconnect All did.
enum ReconnectOutcome: String, AppEnum {
    case nothingToReconnect, reconnected, partlyReconnected, notConfirmed

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Reconnect Outcome"
    static let caseDisplayRepresentations: [ReconnectOutcome: DisplayRepresentation] = [
        .nothingToReconnect: "Nothing to reconnect",
        .reconnected: "Reconnected",
        .partlyReconnected: "Some displays couldn’t be restored",
        .notConfirmed: "Not confirmed",
    ]
}

/// The outcome of Reconnect All, for a shortcut to branch on.
struct ReconnectResultEntity: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Reconnect Result"

    @Property(title: "Outcome") var outcome: ReconnectOutcome
    @Property(title: "Displays Reconnected") var reconnectedCount: Int

    init() {
        outcome = .notConfirmed
        reconnectedCount = 0
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: outcome.caseTitle, subtitle: "Displays reconnected: \(reconnectedCount)")
    }
}

extension AppEnum {
    /// The case's own title, for composing a result's display representation.
    var caseTitle: LocalizedStringResource {
        Self.caseDisplayRepresentations[self]?.title ?? "\(String(describing: self))"
    }
}

// MARK: - Errors

/// Why a display action didn't run. Each message says what to do; none echoes anything but the
/// display's own name.
enum DisplayIntentError: Error, CustomLocalizedStringResourceConvertible {
    case commandFailed(AutomationIssue.Code)
    case appNotReady
    case displayNotConnected(String)
    case displayInactive(String)
    case noBuiltInDisplay
    case brightnessUnavailable(String)
    case modeNotOffered(String)
    case modeChangePending
    case modeChangeFailed(String)
    case modeNotConfirmed(String)
    case mainNotConfirmed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .commandFailed(let code):
            switch code {
            case .displayNotFound, .displayNotConnected:
                return "The selected display isn’t connected. Connect it and try again in FreeDisplay."
            case .displayInactive:
                return "The selected display isn’t showing its own desktop. Nothing was changed."
            case .ambiguousSelector, .ambiguousMode, .ambiguousProfile:
                return "The selection is ambiguous. Choose an exact display, mode or color profile in FreeDisplay."
            case .methodUnavailable, .capabilityUnavailable, .refusedFromSurface:
                return "The requested control isn’t available for this display or build of FreeDisplay."
            case .modeNotOffered:
                return "The display no longer offers this mode. Choose it again from the current mode list."
            case .profileNotFound:
                return "The selected color profile is no longer installed. Choose an installed profile."
            case .busy, .confirmationRequired:
                return "Another display change is waiting. Finish or revert it in FreeDisplay first."
            case .executionFailed:
                return "FreeDisplay couldn’t complete the display operation. Check the display’s status in FreeDisplay."
            case .notConfirmed:
                return "The display operation couldn’t be confirmed. Check the actual display state in FreeDisplay."
            case .notReady:
                return "FreeDisplay isn’t ready. Open FreeDisplay and try again."
            default:
                return "The display request is invalid. Check its parameters in FreeDisplay."
            }
        case .appNotReady:
            return "FreeDisplay isn’t ready to run this action. Open FreeDisplay and try again."
        case .displayNotConnected(let name):
            return "“\(name)” isn’t connected. Connect it, or turn it back on in FreeDisplay, and try again."
        case .displayInactive(let name):
            return "“\(name)” is connected but isn’t showing its own desktop (for example, it’s mirroring another display). Nothing was changed."
        case .noBuiltInDisplay:
            return "There’s no active built-in display. Choose a display for this action."
        case .brightnessUnavailable(let name):
            return "FreeDisplay can’t read or set the brightness of “\(name)”."
        case .modeNotOffered(let name):
            return "“\(name)” doesn’t offer this mode now. Choose the mode again from the display’s current list."
        case .modeChangePending:
            return "Another display mode change is waiting to be kept or reverted. Finish it in FreeDisplay first."
        case .modeChangeFailed(let message):
            return "\(message)"
        case .modeNotConfirmed(let name):
            return "macOS didn’t confirm the new mode on “\(name)”."
        case .mainNotConfirmed(let name):
            return "macOS didn’t make “\(name)” the main display."
        }
    }
}

// MARK: - Actions

/// Reads one display's brightness.
struct GetBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Display Brightness"
    static let description = IntentDescription(
        "Gets a display’s brightness in percent (0–100). The result says whether the display itself reported it; with software dimming it is the level FreeDisplay applies."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Display")
    var display: DisplayEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get the brightness of \(\.$display)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<BrightnessResultEntity> & ProvidesDialog {
        let report = try await DisplayIntentRunner.readBrightness(of: display)
        let name = report.display?.name ?? display.name
        let dialog: IntentDialog = report.confirmed
            ? "\(name): \(report.percent ?? 0) %."
            : "\(name): \(report.percent ?? 0) % (the level FreeDisplay applies; the display can’t report it)."
        return .result(value: BrightnessResultEntity(report), dialog: dialog)
    }
}

/// Sets a display's brightness (TB-05). The type and the `percent` parameter keep their original
/// names so shortcuts saved with the earlier built-in-only action keep working; those have no display
/// and still target the built-in panel, now as a documented default rather than the only choice.
struct SetBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Display Brightness"
    static let description = IntentDescription(
        "Sets a display’s brightness in percent (0–100) and reports the level the display confirms afterwards. With no display chosen, it sets the built-in display."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Display", description: "Leave empty for the built-in display.")
    var display: DisplayEntity?

    @Parameter(title: "Brightness (%)", inclusiveRange: (0, 100))
    var percent: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set the brightness of \(\.$display) to \(\.$percent) %")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<BrightnessResultEntity> & ProvidesDialog {
        let report = try await DisplayIntentRunner.setBrightness(percent: percent, of: display)
        let name = report.display?.name ?? display?.name ?? ""
        let requested = report.requestedPercent ?? percent
        let dialog: IntentDialog
        if report.confirmed {
            dialog = "\(name): brightness \(report.percent ?? requested) %."
        } else if report.control == .software, let applied = report.percent {
            dialog = "\(name): \(applied) % (the level FreeDisplay applies; the display can’t report it)."
        } else if let actual = report.percent {
            dialog = "Requested \(requested) % on \(name); it reports \(actual) %."
        } else {
            dialog = "Requested \(requested) % on \(name). The display couldn’t confirm the new level."
        }
        return .result(value: BrightnessResultEntity(report), dialog: dialog)
    }
}

/// Switches a display to one of its exact modes (TB-06), through the same keep-or-revert gate as
/// the menu: the shortcut reports the change, and it stays only if the user keeps it in time.
struct SetDisplayModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Display Mode"
    static let description = IntentDescription(
        "Switches a display to one of the exact modes it offers. Keep the new mode in FreeDisplay before the countdown ends, or the previous mode comes back."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Display")
    var display: DisplayEntity

    @Parameter(title: "Without confirmation", description: "Keeps a verified mode immediately. Leave off to keep the keep-or-revert window.", default: false)
    var withoutConfirmation: Bool

    @Parameter(title: "Mode", optionsProvider: DisplayModeOptionsProvider())
    var mode: DisplayModeEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$display) to \(\.$mode)") {
            \.$withoutConfirmation
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<DisplayModeResultEntity> & ProvidesDialog {
        let report = try await DisplayIntentRunner.setMode(mode.mode, of: display, withoutConfirmation: withoutConfirmation)
        let result = DisplayModeResultEntity()
        result.display = DisplayEntity(report.display)
        result.mode = DisplayModeEntity(report.mode)
        result.outcome = report.outcome
        result.secondsToKeep = report.secondsToKeep
        let name = report.display.name
        let dialog: IntentDialog
        switch report.outcome {
        case .alreadyInEffect:
            dialog = "\(name) is already in this mode."
        case .applied:
            dialog = "\(name) switched modes without confirmation."
        case .awaitingConfirmation:
            dialog = "\(name) switched modes. Keep the new mode in FreeDisplay within \(report.secondsToKeep ?? 0) seconds, or it reverts."
        }
        return .result(value: result, dialog: dialog)
    }
}

/// Makes a connected display the main display (FB-14). It doesn't connect a display: a display that
/// isn't connected fails the action, so a shortcut connects it in a step of its own first.
struct SetMainDisplayIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Main Display"
    static let description = IntentDescription(
        "Makes a connected display the main display, the one with the menu bar. The displays keep their arrangement. Returns the main display macOS reports afterwards."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Display")
    var display: DisplayEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Make \(\.$display) the main display")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<DisplayEntity> & ProvidesDialog {
        let report = try await DisplayIntentRunner.setMain(display)
        let main = DisplayEntity(report.main)
        let dialog: IntentDialog
        if let seconds = report.secondsToKeep {
            dialog = "\(main.name) is now the main display. Keep the arrangement in FreeDisplay within \(seconds) seconds, or it reverts."
        } else {
            dialog = report.changed ? "\(main.name) is now the main display." : "\(main.name) is already the main display."
        }
        return .result(value: main, dialog: dialog)
    }
}

// MARK: - Work on the live model

/// The main-actor half of the display actions: everything that touches `AppModel`, returning plain
/// values the nonisolated intents can carry.
@MainActor
enum DisplayIntentRunner {
    struct BrightnessReport: Sendable {
        var display: AutomationDisplayEntry?
        var percent: Int?
        var requestedPercent: Int?
        var confirmed: Bool
        var control: BrightnessControlKind
        var outcome: CommandIntentOutcome
    }

    struct ModeChoices: Sendable {
        var current: DisplayMode?
        var options: [DisplayMode]
    }

    struct ModeReport: Sendable {
        var display: AutomationDisplayEntry
        var mode: DisplayMode
        var outcome: DisplayModeOutcome
        var secondsToKeep: Int?
    }

    struct MainReport: Sendable {
        var main: AutomationDisplayEntry
        var changed: Bool
        var secondsToKeep: Int?
    }

    static func entities(for identifiers: [String]) async -> [DisplayEntity] {
        guard let model = await readyModel() else { return [] }
        return AutomationDisplayCatalog.resolve(identifiers, in: model.automationDisplayEntries,
                                                rememberedName: model.automationRememberedName)
            .map(DisplayEntity.init)
    }

    static func entities(matching query: String) async -> [DisplayEntity] {
        guard let model = await readyModel() else { return [] }
        return AutomationDisplayCatalog.entries(matching: query, in: model.automationDisplayEntries)
            .map(DisplayEntity.init)
    }

    static func run(_ request: AutomationRequest) async throws -> AutomationResult {
        let model = try await requireModel()
        let result = await AppAutomation.run(request, from: .appIntent, model: model)
        if let issue = result.issue { throw DisplayIntentError.commandFailed(issue.code) }
        return result
    }

    static func readBrightness(of display: DisplayEntity) async throws -> BrightnessReport {
        try await brightness(.byID(.getBrightness(method: .automatic), DisplayRecordID(rawValue: display.id)))
    }

    static func setBrightness(percent: Int, of display: DisplayEntity?) async throws -> BrightnessReport {
        let level = try AutomationValueParser.level(number: Double(percent) / 100)
        let command = AutomationCommand.setBrightness(level, method: .automatic)
        let request = display.map { AutomationRequest.byID(command, DisplayRecordID(rawValue: $0.id)) }
            ?? AutomationRequest(command, target: .display(.role(.builtin)), targetText: "builtin")
        return try await brightness(request)
    }

    private static func brightness(_ request: AutomationRequest) async throws -> BrightnessReport {
        let result = try await run(request)
        guard let report = result.brightness else { throw DisplayIntentError.appNotReady }
        let model = try await requireModel()
        return BrightnessReport(display: entry(for: DisplayRecordID(rawValue: report.displayId), in: model),
                                percent: report.level?.wholePercent, requestedPercent: report.requested?.wholePercent,
                                confirmed: report.requested == nil ? report.reportedByDisplay : report.outcome == .verified,
                                control: report.route == .native ? .native : report.route == .ddc ? .hardware : .software,
                                outcome: CommandIntentOutcome(result))
    }

    static func modeChoices(for display: DisplayEntity) async throws -> ModeChoices {
        let result = try await run(.byID(.listModes, DisplayRecordID(rawValue: display.id)))
        return ModeChoices(current: result.modes?.current?.mode, options: result.modes?.available.map(\.mode) ?? [])
    }

    static func setMode(_ requested: DisplayMode, of display: DisplayEntity,
                        withoutConfirmation: Bool) async throws -> ModeReport {
        let result = try await run(.byID(.setMode(.exact(requested), keepWithoutConfirmation: withoutConfirmation),
                                        DisplayRecordID(rawValue: display.id)))
        guard let report = result.mode, let model = await readyModel(),
              let entry = entry(for: DisplayRecordID(rawValue: report.displayId), in: model)
        else { throw DisplayIntentError.appNotReady }
        let outcome: DisplayModeOutcome
        switch report.settlement {
        case .alreadyInEffect: outcome = .alreadyInEffect
        case .awaitingConfirmation: outcome = .awaitingConfirmation
        case .applied: outcome = .applied
        }
        return ModeReport(display: entry, mode: report.mode.mode, outcome: outcome, secondsToKeep: report.secondsToKeep)
    }

    static func setMain(_ display: DisplayEntity) async throws -> MainReport {
        let result = try await run(.byID(.setMain, DisplayRecordID(rawValue: display.id)))
        guard let report = result.main, let model = await readyModel(),
              let entry = entry(for: DisplayRecordID(rawValue: report.displayId), in: model)
        else { throw DisplayIntentError.appNotReady }
        return MainReport(main: entry, changed: report.changed, secondsToKeep: report.secondsToKeep)
    }

    // MARK: Helpers

    /// The live model after its first display read, or nil when this process has none.
    private static func readyModel() async -> AppModel? {
        guard let model = OpenDisplayAutomation.liveModel else { return nil }
        await model.prepareForAutomation()
        return model
    }

    private static func requireModel() async throws -> AppModel {
        guard let model = await readyModel() else { throw DisplayIntentError.appNotReady }
        return model
    }

    /// The display an action may change: connected and showing its own desktop. Anything else is an
    /// error naming the display — never a substitute.
    private static func activeTarget(_ display: DisplayEntity, in model: AppModel) throws -> DisplayObservation {
        switch AutomationDisplayCatalog.target(DisplayRecordID(rawValue: display.id), in: model.displays) {
        case .active(let observation): return observation
        case .inactive(let observation): throw DisplayIntentError.displayInactive(model.displayName(for: observation))
        case .missing: throw DisplayIntentError.displayNotConnected(display.name)
        }
    }

    private static func entry(for id: DisplayRecordID, in model: AppModel) -> AutomationDisplayEntry? {
        model.automationDisplayEntries.first { $0.id == id }
    }

    private static func control(_ method: BrightnessMethod?) -> BrightnessControlKind {
        switch method {
        case .native?: return .native
        case .hardware?: return .hardware
        case .software?: return .software
        case nil: return .unknown
        }
    }
}
#endif
