#if os(macOS)
import AppKit
import DisplayDomain
import OpenDisplayDesignSystem
import SwiftUI
import TopologyCore
import UniformTypeIdentifiers

/// The profiles in the user's own `~/Library/ColorSync/Profiles` folder and the one undoable file
/// action on them: importing a copy, or moving a copy to the Trash. App-wide (the folder is), so a
/// single shared instance; every change re-enumerates what ColorSync offers (`AppModel`).
@MainActor
final class ColorProfileLibrary: ObservableObject {
    static let shared = ColorProfileLibrary()

    @Published private(set) var userProfiles: [ICCProfileDetails] = []
    @Published private(set) var loaded = false
    @Published private(set) var status: Status?
    /// Sequence number of the newest folder read: reloads can overlap (Refresh during an import),
    /// and a slower, older read must not land last and drop a file the newer one saw.
    private var readSequence = 0

    /// The outcome of the last file action, with what undoing it would do.
    struct Status: Equatable {
        let text: String
        let isError: Bool
        var undo: Undo?
    }

    /// The targeted undo of the last action — only that file, nothing else.
    enum Undo: Equatable {
        /// Move the copy an import made to the Trash — if it is still the file the import wrote.
        case removeImported(URL, ColorProfileService.FileStamp?)
        /// Put a removed copy back from the Trash.
        case restoreRemoved(trashed: URL, original: URL)
    }

    /// Re-reads the folder (off the main actor: it opens every profile).
    func reload(_ model: AppModel) async {
        readSequence &+= 1
        let read = readSequence
        let factories = model.colorProfileAssignment.values.flatMap(\.factoryURLs)
        let found = await Task.detached(priority: .userInitiated) {
            ColorProfileService.userFolderProfiles(factoryURLs: factories)
        }.value
        guard read == readSequence else { return }
        userProfiles = found
        loaded = true
    }

    func importProfile(from source: URL, model: AppModel) async {
        let result = await Self.run { () throws -> (ColorProfileService.ImportResult, ColorProfileService.FileStamp?) in
            let outcome = try ColorProfileService.importProfile(from: source)
            guard case .imported(let url) = outcome else { return (outcome, nil) }
            return (outcome, ColorProfileService.fileStamp(url))
        }
        switch result {
        case .success((.imported(let url), let stamp)):
            status = Status(text: String(localized: "Copied “\(url.lastPathComponent)” into your profiles folder; the original file is untouched."),
                            isError: false, undo: .removeImported(url, stamp))
        case .success((.alreadyInstalled(let url), _)):
            status = Status(text: String(localized: "This profile is already in your profiles folder as “\(url.lastPathComponent)”. Nothing was copied."),
                            isError: false)
        case .failure(let error):
            status = Status(text: Self.explain(error), isError: true)
        }
        await afterChange(model)
    }

    /// Moves a user-folder profile to the Trash. Refused while a connected display uses that file:
    /// removing it would leave the display's assignment pointing at nothing.
    func remove(_ profile: ICCProfileDetails, model: AppModel) async {
        if let names = Self.displaysUsing(profile.url, model: model) {
            status = Status(text: String(localized: "“\(profile.displayName)” is in use on \(names). Choose another profile for that display first, then remove it."),
                            isError: true)
            return
        }
        let url = profile.url
        let factories = model.colorProfileAssignment.values.flatMap(\.factoryURLs)
        let result = await Self.run { try ColorProfileService.moveToTrash(url, factoryURLs: factories) }
        switch result {
        case .success(let trashed):
            status = Status(text: String(localized: "Moved “\(profile.displayName)” to the Trash. Displays no longer offer it."),
                            isError: false, undo: .restoreRemoved(trashed: trashed, original: url))
        case .failure(let error):
            status = Status(text: Self.explain(error), isError: true)
        }
        await afterChange(model)
    }

    func undo(_ model: AppModel) async {
        guard let undo = status?.undo else { return }
        let result: Result<Void, ICCProfileFileError>
        switch undo {
        case .removeImported(let url, let stamp):
            // The same checks as a removal, plus: the file must still be the one the import wrote.
            if let names = Self.displaysUsing(url, model: model) {
                status = Status(text: String(localized: "“\(url.lastPathComponent)” is in use on \(names). Choose another profile for that display first, then undo."),
                                isError: true, undo: undo)
                return
            }
            let factories = model.colorProfileAssignment.values.flatMap(\.factoryURLs)
            result = await Self.run {
                guard ColorProfileService.fileStamp(url) == stamp else {
                    throw ICCProfileFileError.fileSystem(String(localized: "The imported file has changed since, so it wasn’t removed. Remove it from the list if you no longer want it."))
                }
                _ = try ColorProfileService.moveToTrash(url, factoryURLs: factories)
            }
            if case .success = result {
                status = Status(text: String(localized: "Moved the imported copy “\(url.lastPathComponent)” to the Trash."), isError: false)
            }
        case .restoreRemoved(let trashed, let original):
            result = await Self.run { try ColorProfileService.restoreFromTrash(trashed, to: original) }
            if case .success = result {
                status = Status(text: String(localized: "Put “\(original.lastPathComponent)” back in your profiles folder."), isError: false)
            }
        }
        if case .failure(let error) = result {
            // Putting a file back can fail for a reason the user can clear (a file in the way), so
            // that undo stays offered; a changed import is not the file to remove any more.
            var retry: Undo?
            if case .restoreRemoved = undo { retry = undo }
            status = Status(text: Self.explain(error), isError: true, undo: retry)
        }
        await afterChange(model)
    }

    func report(_ text: String) {
        status = Status(text: text, isError: true)
    }

    /// The connected displays assigned this very file, named; nil when none is.
    private static func displaysUsing(_ url: URL, model: AppModel) -> String? {
        let path = url.standardizedFileURL.path
        let users = model.displays.filter { display in
            model.colorProfileAssignment[display.recordID]?.customURL.map { $0.standardizedFileURL.path == path } ?? false
        }
        guard !users.isEmpty else { return nil }
        return users.map { model.displayName(for: $0) }.sorted().joined(separator: ", ")
    }

    /// Runs a file operation off the main actor (ColorSync parses the file; the copy can be slow).
    nonisolated private static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async
        -> Result<T, ICCProfileFileError> {
        await Task.detached(priority: .userInitiated) {
            do { return .success(try body()) } catch let error as ICCProfileFileError {
                return .failure(error)
            } catch {
                return .failure(.fileSystem(error.localizedDescription))
            }
        }.value
    }

    private func afterChange(_ model: AppModel) async {
        await model.reloadInstalledColorProfiles()
        await reload(model)
    }

    private static func explain(_ error: ICCProfileFileError) -> String {
        switch error {
        case .notAProfile:
            return String(localized: "macOS couldn’t open this file as a valid ICC profile, so it wasn’t copied.")
        case .notRGB:
            return String(localized: "This isn’t an RGB profile, so macOS can’t use it for a display. It wasn’t copied.")
        case .fileSystem(let reason):
            return reason
        }
    }
}

/// Finder and ColorSync Utility for a profile file.
@MainActor
enum ColorProfileFileActions {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens the file in ColorSync Utility, which shows the profile's tags and gamut and can verify
    /// or repair it. Falls back to the default app for the file if ColorSync Utility isn't found.
    static func openInColorSyncUtility(_ url: URL) {
        let workspace = NSWorkspace.shared
        guard let app = workspace.urlForApplication(withBundleIdentifier: "com.apple.ColorSyncUtility") else {
            if !workspace.open(url) {
                ColorProfileLibrary.shared.report(String(localized: "Couldn’t open “\(url.lastPathComponent)”."))
            }
            return
        }
        workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            let reason = error.localizedDescription
            Task { @MainActor in
                ColorProfileLibrary.shared.report(String(localized: "ColorSync Utility didn’t open “\(url.lastPathComponent)”: \(reason)"))
            }
        }
    }
}

/// Settings › Displays: what the display's colour profile actually is (from the file), where it
/// lives and whether it counts as custom for the gamma safeguard; the user's own profiles with
/// import and removal; and what choosing a profile does and doesn't do.
struct ColorProfileCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var library = ColorProfileLibrary.shared
    let display: DisplayObservation
    @State private var active: ICCProfileDetails?
    @State private var pendingRemoval: ICCProfileDetails?
    @State private var showsLibrary = false
    @State private var showsHelp = false

    private var assignment: ICCAssignment? { model.colorProfileAssignment[display.recordID] }
    /// The file in effect: the custom override, else the display's factory profile.
    private var activeURL: URL? { assignment.flatMap { $0.customURL ?? $0.factoryURLs.first } }

    var body: some View {
        ODCard(title: String(localized: "Colour profile details")) {
            VStack(alignment: .leading, spacing: ODSpacing.sm) {
                if model.colorProfileControllable[display.recordID] != true {
                    note(String(localized: "macOS doesn’t expose a colour profile for this display."))
                } else if let active {
                    activeProfile(active)
                } else if assignment != nil && activeURL == nil {
                    note(String(localized: "macOS reports no profile file for this display."))
                } else {
                    note(String(localized: "Reading the profile…"))
                }
                ODDivider(inset: 0)
                DisclosureGroup(isExpanded: $showsLibrary) {
                    userFolder.padding(.top, 4)
                } label: {
                    Text("Your profiles").font(.system(size: 13))
                }
                DisclosureGroup(isExpanded: $showsHelp) {
                    Text("A colour profile describes how a screen shows colour, so macOS can convert pictures for it. Choosing one doesn’t measure or calibrate the display — OpenDisplay doesn’t calibrate. A profile is accurate only for the monitor settings it was made with (picture preset, brightness, white point). To make one for this screen, measure it with a colorimeter and its software, or use macOS’s Display Calibrator Assistant (in System Settings › Displays, open the Colour Profile menu and choose Customise…). A profile such as Display P3 describes a colour space: choosing it doesn’t turn on HDR or change the signal sent to the monitor.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                } label: {
                    Text("About profiles and calibration").font(.system(size: 13))
                }
            }
            .padding(12)
        }
        // Keyed by display too: the same card is reused when another display is selected.
        .task(id: "\(display.recordID.rawValue)|\(activeURL?.path ?? "")") { await loadActive() }
        // Opening the list is when files added or removed outside OpenDisplay should show up — in
        // the list and in every profile chooser (which otherwise keep the launch-time scan).
        .task(id: showsLibrary) {
            guard showsLibrary else { return }
            await model.reloadInstalledColorProfiles()
            await library.reload(model)
        }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { pendingRemoval != nil },
                                                             set: { if !$0 { pendingRemoval = nil } }),
                            presenting: pendingRemoval) { profile in
            Button("Move to Trash", role: .destructive) {
                Task { await library.remove(profile, model: model) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The file leaves your profiles folder and displays stop offering it. You can undo this here or put it back from the Trash.")
        }
    }

    private var removalTitle: String {
        pendingRemoval.map { String(localized: "Move “\($0.displayName)” to the Trash?") } ?? ""
    }

    private func loadActive() async {
        guard let url = activeURL else { active = nil; return }
        let factories = assignment?.factoryURLs ?? []
        active = await Task.detached(priority: .userInitiated) {
            ColorProfileService.details(of: url, factoryURLs: factories)
        }.value
    }

    // MARK: - Active profile

    @ViewBuilder
    private func activeProfile(_ profile: ICCProfileDetails) -> some View {
        let isCustom = ICCProfileCatalog.guardAssignment(for: profile.provenance) == .custom
        HStack(spacing: 6) {
            Text(profile.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                .textSelection(.enabled)
            ODBadge(Self.provenanceBadge(profile.provenance), tone: isCustom ? .orange : .neutral)
        }
        Text(Self.provenanceText(profile.provenance)).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if !profile.exists {
            note(String(localized: "The profile file is missing: \(profile.url.path)"), warning: true)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if let header = profile.header {
                    fact(String(localized: "Kind"), "\(Self.classText(header.deviceClass)) · \(header.colorSpace) · ICC \(header.version)")
                    if let created = header.created {
                        fact(String(localized: "Created"), created.formatted(date: .abbreviated, time: .omitted))
                    }
                } else {
                    fact(String(localized: "Kind"), String(localized: "Unreadable header"))
                }
                fact(String(localized: "File"), profile.url.lastPathComponent)
                fact(String(localized: "Folder"), profile.url.deletingLastPathComponent().path)
            }
            HStack(spacing: 8) {
                Button("Show in Finder") { ColorProfileFileActions.reveal(profile.url) }
                Button("Open in ColorSync Utility") { ColorProfileFileActions.openInColorSyncUtility(profile.url) }
            }
            .controlSize(.small)
        }
        if isCustom && model.customProfileDisplays.contains(display.recordID) {
            note(model.gammaBlockedByCustomProfile
                 ? String(localized: "This counts as a custom profile, so while it’s assigned OpenDisplay pauses gamma changes on every display: dimming uses the overlay, colour temperature and XDR boost are off. The Dimming card can allow gamma anyway.")
                 : String(localized: "This counts as a custom profile. Gamma changes are allowed anyway by the override in the Dimming card; if a screen turns black or tinted, turn the override off."),
                 warning: model.gammaBlockedByCustomProfile)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).font(.system(size: 11)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }

    // MARK: - User folder

    @ViewBuilder
    private var userFolder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Profiles in \(ColorProfileService.userProfilesFolder.path). OpenDisplay imports copies here and removes only copies from here; profiles of macOS, other users or apps stay in the profile chooser but are left alone.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if library.loaded && library.userProfiles.isEmpty {
                note(String(localized: "No profiles in your folder."))
            }
            ForEach(library.userProfiles) { profile in
                userProfileRow(profile)
            }
            HStack(spacing: 8) {
                Button("Import Profile…") { chooseImport() }
                Button("Open Folder") {
                    let folder = ColorProfileService.userProfilesFolder
                    if FileManager.default.fileExists(atPath: folder.path) {
                        NSWorkspace.shared.open(folder)
                    } else {
                        library.report(String(localized: "Your profiles folder doesn’t exist yet; importing a profile creates it."))
                    }
                }
                Button("Refresh") { Task { await model.reloadInstalledColorProfiles(); await library.reload(model) } }
            }
            .controlSize(.small)
            if let status = library.status {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(status.text).font(.caption)
                        .foregroundStyle(status.isError ? ODColor.caution : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if status.undo != nil {
                        Button("Undo") { Task { await library.undo(model) } }.controlSize(.small)
                    }
                }
            }
        }
    }

    private func userProfileRow(_ profile: ICCProfileDetails) -> some View {
        let inUse = assignment?.customURL.map { $0.standardizedFileURL.path == profile.id } ?? false
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName).font(.system(size: 12)).lineLimit(1)
                Text(profile.header.map { "\(profile.url.lastPathComponent) · \(Self.classText($0.deviceClass)) · \($0.colorSpace)" }
                     ?? profile.url.lastPathComponent)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if inUse {
                ODBadge(String(localized: "In use"), tone: .accent)
            } else if profile.header?.isRGB == true, model.colorProfileControllable[display.recordID] == true {
                Button("Use") {
                    Task { await model.setColorProfile(ICCProfile(name: profile.displayName, url: profile.url), for: display) }
                }
                .controlSize(.small)
                .help(String(localized: "Assign this profile to \(model.displayName(for: display))"))
            }
            Menu {
                Button("Show in Finder") { ColorProfileFileActions.reveal(profile.url) }
                Button("Open in ColorSync Utility") { ColorProfileFileActions.openInColorSyncUtility(profile.url) }
                Divider()
                Button("Move to Trash…", role: .destructive) { pendingRemoval = profile }
                    .disabled(!profile.isRemovable || inUse)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .help(profile.url.path)
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ICCProfileCatalog.fileExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose an ICC profile to copy into your profiles folder. The original stays where it is.")
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        showsLibrary = true
        Task { await library.importProfile(from: url, model: model) }
    }

    private func note(_ text: String, warning: Bool = false) -> some View {
        Text(text).font(.caption).foregroundStyle(warning ? ODColor.caution : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Labels

    static func provenanceBadge(_ provenance: ICCProfileProvenance) -> String {
        switch provenance {
        case .factory: return String(localized: "Factory")
        case .system: return String(localized: "macOS")
        case .user: return String(localized: "Your profile")
        case .shared: return String(localized: "Shared")
        case .other: return String(localized: "Other")
        }
    }

    static func provenanceText(_ provenance: ICCProfileProvenance) -> String {
        switch provenance {
        case .factory: return String(localized: "Made by macOS for a display from what the display reports about itself.")
        case .system: return String(localized: "Supplied with macOS.")
        case .user: return String(localized: "In your own profiles folder — for example one you calibrated, downloaded or imported. Counts as a custom profile.")
        case .shared: return String(localized: "Installed for all users of this Mac. Counts as a custom profile.")
        case .other: return String(localized: "Kept outside the standard profile folders, for example inside an app. Counts as a custom profile.")
        }
    }

    static func classText(_ deviceClass: String) -> String {
        switch deviceClass {
        case "mntr": return String(localized: "Display")
        case "spac": return String(localized: "Colour space")
        case "prtr": return String(localized: "Printer")
        case "scnr": return String(localized: "Input device")
        case "link": return String(localized: "Device link")
        case "abst": return String(localized: "Abstract")
        case "nmcl": return String(localized: "Named colour")
        default: return deviceClass
        }
    }
}
#endif
