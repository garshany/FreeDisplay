// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppIntents
import AutomationSchema
import DisplayDomain
import Foundation

/// Shared result vocabulary for Shortcuts branches; labels are presentation only.
enum CommandIntentOutcome: String, AppEnum {
    case done, requested, alreadyInEffect, partial, failed

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Command Outcome"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .done: "Done", .requested: "Requested; not confirmed", .alreadyInEffect: "Already in effect",
        .partial: "Partly completed", .failed: "Failed",
    ]

    init(_ result: AutomationResult) {
        self = Self(rawValue: AutomationOutcomeKind(result).rawValue) ?? .failed
    }
}

struct ColorProfileEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Color Profile"
    static let defaultQuery = ColorProfileQuery()
    let id: String
    @Property(title: "Name") var name: String

    init(_ info: AutomationProfileInfo) { id = info.id; name = info.name }
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)", subtitle: "\(id)") }
}

struct ColorProfileQuery: EntityStringQuery {
    func suggestedEntities() async throws -> [ColorProfileEntity] {
        let result = try await DisplayIntentRunner.run(.init(.listColorProfiles))
        return (result.colorProfiles ?? []).map(ColorProfileEntity.init)
    }
    func entities(for identifiers: [String]) async throws -> [ColorProfileEntity] {
        let installed = try await suggestedEntities()
        // Preserve a saved path even after uninstall: execution will reject it rather than choosing
        // a different profile or silently resetting the display.
        return identifiers.map { id in
            installed.first { $0.id == id } ?? ColorProfileEntity(.init(id: id, name: URL(fileURLWithPath: id).lastPathComponent))
        }
    }
    func entities(matching string: String) async throws -> [ColorProfileEntity] {
        try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
}

struct ColorProfileResultEntity: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Color Profile Result"
    @Property(title: "Name") var name: String?
    @Property(title: "Profile Path") var path: String?
    @Property(title: "Factory Profile") var isFactory: Bool
    @Property(title: "Outcome") var outcome: CommandIntentOutcome

    init() { name = nil; path = nil; isFactory = false; outcome = .failed }
    init(_ result: AutomationResult) {
        self.init()
        name = result.colorProfile?.state.name
        path = result.colorProfile?.state.customProfilePath
        isFactory = result.colorProfile?.state.isFactory ?? false
        outcome = CommandIntentOutcome(result)
    }
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name ?? "")", subtitle: outcome.caseTitle) }
}

struct GetDisplayModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Display Mode"
    static let description = IntentDescription("Reads the exact current mode of a connected display in FreeDisplay.")
    static let openAppWhenRun = false
    @Parameter(title: "Display") var display: DisplayEntity

    func perform() async throws -> some IntentResult & ReturnsValue<DisplayModeEntity> {
        let result = try await DisplayIntentRunner.run(.byID(.getMode, .init(rawValue: display.id)))
        guard let mode = result.modes?.current?.mode else { throw DisplayIntentError.appNotReady }
        return .result(value: DisplayModeEntity(mode))
    }
}

struct GetColorProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Display Color Profile"
    static let description = IntentDescription("Reads the color profile ColorSync reports for the selected display.")
    static let openAppWhenRun = false
    @Parameter(title: "Display") var display: DisplayEntity

    func perform() async throws -> some IntentResult & ReturnsValue<ColorProfileResultEntity> {
        let result = try await DisplayIntentRunner.run(.byID(.getColorProfile, .init(rawValue: display.id)))
        return .result(value: ColorProfileResultEntity(result))
    }
}

struct SetColorProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Display Color Profile"
    static let description = IntentDescription("Assigns an installed color profile and checks the profile ColorSync reports afterwards.")
    static let openAppWhenRun = false
    @Parameter(title: "Display") var display: DisplayEntity
    @Parameter(title: "Color Profile") var profile: ColorProfileEntity

    func perform() async throws -> some IntentResult & ReturnsValue<ColorProfileResultEntity> {
        let result = try await DisplayIntentRunner.run(.byID(.setColorProfile(.path(profile.id)), .init(rawValue: display.id)))
        return .result(value: ColorProfileResultEntity(result))
    }
}

struct ResetColorProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Reset Display Color Profile"
    static let description = IntentDescription("Returns the selected display to its factory color profile and checks ColorSync.")
    static let openAppWhenRun = false
    @Parameter(title: "Display") var display: DisplayEntity

    func perform() async throws -> some IntentResult & ReturnsValue<ColorProfileResultEntity> {
        let result = try await DisplayIntentRunner.run(.byID(.resetColorProfile, .init(rawValue: display.id)))
        return .result(value: ColorProfileResultEntity(result))
    }
}
#endif
