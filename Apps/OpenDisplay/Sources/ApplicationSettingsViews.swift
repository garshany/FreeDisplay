#if os(macOS)
import AppKit
import OpenDisplayDesignSystem
import SwiftUI
import TopologyCore
import UniformTypeIdentifiers

// Application-level settings that don't belong to any one display: safe startup (FA-09),
// notices (SO-12/FA-16), the Dock icon (SO-13), build information (SO-40) and the settings
// archive with its lifecycle sheet (SO-11/FA-10). Hosted by `SettingsView`'s existing sections.

// MARK: - Safe startup banner (FA-09)

/// Shown at the top of every Settings section, and summarised in the tray, while the session is a
/// safe startup: what is being held back, that nothing was changed, and the way out.
struct SafeStartupBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let held = SafeStartup.activeSuspensions(settings: model.settings,
                                                 turnedOffDisplays: !model.managedOffline.isEmpty)
        ODInlineBanner(tone: .orange, systemImage: "shield.lefthalf.filled",
                       title: String(localized: "Safe startup: FreeDisplay makes no automatic changes this session"),
                       message: message(held)) {
            Button("Relaunch Normally") { AppLanguage.relaunch() }
        }
    }

    private func message(_ held: [SafeStartup.Suspension]) -> String {
        let intro = String(localized: "Shift was held at launch, or FreeDisplay was started with --safe-mode. Settings and virtual-screen reconnections are not restored automatically. Saved configuration is kept. The menu, keys, command line and Shortcuts still work, and so does the safety net that brings a screen back.")
        guard !held.isEmpty else {
            return intro + "\n" + String(localized: "Nothing you have set up would have acted on its own.")
        }
        let lines = held.map { "\u{2022} " + Self.label($0) }
        return ([intro, String(localized: "Held back now:")] + lines).joined(separator: "\n")
    }

    static func label(_ suspension: SafeStartup.Suspension) -> String {
        switch suspension {
        case .layoutProtection: return String(localized: "Restoring your protected layout")
        case .turnedOffDisplays: return String(localized: "Keeping the displays you turned off switched off")
        case .autoDisconnectBuiltIn: return String(localized: "Turning the built-in display off when an external connects")
        case .adaptiveDisplay: return String(localized: "Adaptive brightness and warmth, Clock Mode")
        case .appPresets: return String(localized: "App presets")
        case .displayGroupSync: return String(localized: "Display groups following one another")
        case .launchRestores: return String(localized: "Restoring brightness left over from the last session")
        case .xdrPowerAutomation: return String(localized: "Automatic XDR boost changes")
        case .displaySleepPrevention: return String(localized: "Keeping displays awake with an external screen")
        }
    }
}

// MARK: - Notices (SO-12/FA-16)

/// Event notices: off, Notification Center or OpenDisplay's own window; the routine-protection
/// filter; and what macOS currently allows, which can differ from what was chosen here.
struct NotificationSettingsRows: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var permission = NotificationPermission.shared

    private enum Choice: Hashable { case off, notificationCenter, appWindow }

    private var choice: Choice {
        guard model.settings.displayNotificationsEnabled else { return .off }
        switch model.settings.notificationStyle {
        case .notificationCenter: return .notificationCenter
        case .appWindow: return .appWindow
        }
    }

    private func apply(_ choice: Choice) {
        switch choice {
        case .off:
            model.setDisplayNotificationsEnabled(false)
        case .notificationCenter:
            model.setNotificationStyle(.notificationCenter)
            model.setDisplayNotificationsEnabled(true)
        case .appWindow:
            model.setNotificationStyle(.appWindow)
            model.setDisplayNotificationsEnabled(true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Event notices", selection: Binding(get: { choice }, set: { apply($0) })) {
                Text("Off").tag(Choice.off)
                Text("Notification Center").tag(Choice.notificationCenter)
                Text("OpenDisplay window").tag(Choice.appWindow)
            }
            .fixedSize()
            Text("Notices about displays connecting or disconnecting, the built-in turning off automatically, protection results and failures. Confirmation prompts and the on-screen display are separate and work whatever is chosen here.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if choice != .off {
                Toggle(isOn: Binding(
                    get: { model.settings.routineProtectionNoticesEnabled },
                    set: { model.setRoutineProtectionNoticesEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Routine protection notices")
                        Text("Say when a protected layout was put back. Turning this off doesn’t stop protection, and you are still told when a layout can’t be restored.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, ODSpacing.lg)
            }
            if choice == .notificationCenter {
                permissionStatus.padding(.leading, ODSpacing.lg)
            }
        }
        .onAppear { permission.refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in permission.refresh() }
    }

    @ViewBuilder private var permissionStatus: some View {
        let (icon, tint, text) = statusPresentation
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(text).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = permission.lastDeliveryError {
                Text("The last notice couldn’t be delivered: \(error)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: ODSpacing.sm) {
                if permission.state == .notRequested {
                    Button("Ask for Permission") { NotificationDelivery.requestAuthorization() }
                        .controlSize(.small)
                }
                Button("Open Notification Settings…") { NotificationPermission.openSystemSettings() }
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var statusPresentation: (String, Color, String) {
        switch permission.state {
        case .unknown:
            return ("ellipsis.circle", .secondary, String(localized: "Checking what macOS allows…"))
        case .notRequested:
            return ("questionmark.circle", ODColor.caution,
                    String(localized: "macOS hasn’t asked you about OpenDisplay’s notifications yet."))
        case .denied:
            return ("bell.slash.fill", ODColor.caution,
                    String(localized: "Notifications are off for OpenDisplay in System Settings, so notices won’t appear. Everything else works as usual."))
        case .allowedQuietly:
            return ("bell.badge", ODColor.caution,
                    String(localized: "Allowed, but the alert style is None: notices go to Notification Center without appearing on screen."))
        case .provisional:
            return ("bell.badge", ODColor.caution,
                    String(localized: "Delivered quietly to Notification Center until you choose how they appear."))
        case .allowed:
            return ("checkmark.circle.fill", ODColor.connected, String(localized: "Allowed by macOS."))
        }
    }
}

// MARK: - Dock icon (SO-13/FB-15)

struct DockIconPolicyRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Picker("Show in the Dock", selection: Binding(
                get: { model.settings.dockIconPolicy }, set: { model.setDockIconPolicy($0) })) {
                Text("Never").tag(DockIconPolicy.never)
                Text("While Settings is open").tag(DockIconPolicy.whileSettingsOpen)
                Text("While any OpenDisplay window is open").tag(DockIconPolicy.whileAnyWindowOpen)
                Text("Always").tag(DockIconPolicy.always)
            }
            .fixedSize()
            Text("The menu-bar icon stays either way, and changing this never closes a window or stops a capture.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Build information (SO-40)

/// The running build's identity, as one source for both About surfaces and the copy button.
struct BuildMetadata {
    let version: String
    let build: String
    let configuration: String
    let apiSurface: String
    /// `configuration` and `apiSurface` in the interface language, for the rows; the copied
    /// report keeps the English words.
    let configurationTitle: String
    let apiSurfaceTitle: String
    let isLocalBuild: Bool
    let bundleIdentifier: String
    let operatingSystem: String
    let architecture: String
    /// When the executable was written — the closest thing to a build stamp the bundle carries.
    let builtAt: Date?

    @MainActor static var current: BuildMetadata {
        #if DEBUG
        let configuration = "Debug"
        let configurationTitle = String(localized: "Debug")
        #else
        let configuration = "Release"
        let configurationTitle = String(localized: "Release")
        #endif
        #if PUBLIC_API_ONLY
        let apiSurface = "public-API-only"
        let apiSurfaceTitle = String(localized: "public APIs only")
        #else
        let apiSurface = "full"
        let apiSurfaceTitle = String(localized: "full")
        #endif
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let builtAt = (try? Bundle.main.executableURL?.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return BuildMetadata(
            version: AboutView.version, build: AboutView.build, configuration: configuration,
            apiSurface: apiSurface, configurationTitle: configurationTitle, apiSurfaceTitle: apiSurfaceTitle,
            isLocalBuild: Bundle.main.object(forInfoDictionaryKey: "OpenDisplayLocalBuild") as? Bool == true,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "?",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture, builtAt: builtAt)
    }

    /// Labelled rows for display, in the interface language.
    var rows: [(label: String, value: String)] {
        var rows: [(String, String)] = [
            (String(localized: "Version"), "\(version) (\(build))"),
            (String(localized: "Build"), localizedBuildDescription),
            (String(localized: "Channel"), channelTitle),
        ]
        if let builtAt { rows.append((String(localized: "Built"), builtAt.formatted(date: .abbreviated, time: .shortened))) }
        rows.append((String(localized: "macOS"), operatingSystem))
        rows.append((String(localized: "Architecture"), architecture))
        rows.append((String(localized: "Bundle ID"), bundleIdentifier))
        return rows
    }

    var channelTitle: String {
        isLocalBuild ? String(localized: "Source build") : String(localized: "Release")
    }

    private var localizedBuildDescription: String {
        [configurationTitle, apiSurfaceTitle].joined(separator: " · ")
    }

    var reportText: String {
        BuildReport(version: version, build: build,
                    configuration: configuration == "Debug" ? .debug : .release,
                    apiSurface: apiSurface == "full" ? .full : .publicOnly,
                    isLocalBuild: isLocalBuild, bundleIdentifier: bundleIdentifier,
                    operatingSystem: operatingSystem, architecture: architecture, builtAt: builtAt).reportText
    }

}

/// Selectable build rows and a Copy button — shared by Settings › About and the About window.
struct BuildMetadataView: View {
    private let metadata = BuildMetadata.current
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(metadata.rows, id: \.label) { row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary)
                        Text(row.value).textSelection(.enabled)
                    }
                    .font(.caption)
                }
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(metadata.reportText, forType: .string)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy Build Information",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.small)
            .accessibilityHint("Copies the version, build and macOS details for a bug report")
        }
    }
}

// MARK: - Settings archive and lifecycle (SO-11/FA-10)

/// The Settings › About entry point to the lifecycle sheet.
struct AppSettingsCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingSheet = false

    var body: some View {
        ODCard(title: String(localized: "App settings")) {
            ODRow(String(localized: "Back up, restore or reset"),
                  secondary: String(localized: "Export to a file, import one, or start again from defaults")) {
                Button("Manage…") { showingSheet = true }
                    .controlSize(.small)
            }
        }
        .sheet(isPresented: $showingSheet) {
            ManageAppSettingsSheet().environmentObject(model)
        }
    }
}

/// Export, import and reset of OpenDisplay's own configuration, plus relaunch and quit. Every
/// action that replaces settings or ends the app asks first, and cancelling changes nothing.
/// Import and reset write a backup before touching anything and then relaunch, which is what
/// re-arms hotkeys, schedules and observers from the new settings.
struct ManageAppSettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var status: Status?
    @State private var working = false
    @State private var importPreview: AppModel.SettingsImportPreview?
    @State private var confirmingReset = false
    @State private var confirmingRelaunch = false
    @State private var confirmingQuit = false

    struct Status {
        var text: String
        var isError: Bool
        var revealURL: URL?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ODSpacing.md) {
            Text("Manage App Settings").font(.title2.weight(.semibold))

            section(title: String(localized: "Back up"),
                    text: String(localized: "Saves FreeDisplay’s preferences, display names, favourite resolutions, groups, app presets, protected layouts, shortcuts, scenes, menu layout and luminance values to a file you choose.")) {
                Button("Export Settings…") { export() }
            }
            section(title: String(localized: "Restore"),
                    text: String(localized: "Replaces every OpenDisplay setting with a file exported earlier. The current settings are backed up first.")) {
                Button("Import Settings…") { chooseImport() }
                Button("Show Backups in Finder") { revealBackups() }
            }
            section(title: String(localized: "Reset"),
                    text: String(localized: "Returns every OpenDisplay setting to its default. The current settings are backed up first.")) {
                Button("Reset to Defaults…", role: .destructive) { confirmingReset = true }
            }
            Text("Not part of the app settings, so never replaced or reset: the macOS display arrangement and resolutions, recovery checkpoints, logs, Launch at Login and the interface language. Import and reset end with a relaunch, which — like any quit — turns the displays OpenDisplay turned off back on.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(spacing: ODSpacing.sm) {
                Button("Relaunch OpenDisplay…") { confirmingRelaunch = true }
                Button("Quit OpenDisplay…") { confirmingQuit = true }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if let status {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(status.isError ? ODColor.caution : ODColor.connected)
                    Text(status.text).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let url = status.revealURL {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
        .disabled(working)
        .padding(ODSpacing.xl)
        .frame(width: 520)
        .sheet(item: $importPreview) { preview in
            ImportConfirmationView(preview: preview) {
                importPreview = nil
                replace(with: preview.archive)
            } onCancel: {
                importPreview = nil
            }
        }
        .confirmationDialog("Reset all OpenDisplay settings to their defaults?", isPresented: $confirmingReset) {
            Button("Back Up, Reset and Relaunch", role: .destructive) {
                replace(with: model.factoryDefaultSettingsArchive())
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Preferences, display names, favourite resolutions, groups, app presets, protected layouts, shortcuts, scenes, menu layout and luminance values return to their defaults. A backup of the current settings is written first, and FreeDisplay then relaunches — like any quit, turning the displays it turned off back on.")
        }
        .confirmationDialog("Relaunch OpenDisplay?", isPresented: $confirmingRelaunch) {
            Button("Relaunch") { AppLanguage.relaunch() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("OpenDisplay quits — putting back what it changed, as on every quit — and opens again.")
        }
        .confirmationDialog("Quit OpenDisplay?", isPresented: $confirmingQuit) {
            Button("Quit") { NSApp.terminate(nil) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The menu-bar icon goes away until you open OpenDisplay again.")
        }
    }

    private func section<Actions: View>(title: String, text: String,
                                         @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: ODSpacing.sm) { actions() }.padding(.top, 2)
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = String(localized: "OpenDisplay Settings \(day).json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        Task {
            do {
                try await model.exportSettings(to: url)
                status = Status(text: String(localized: "Exported to \(url.lastPathComponent)."), isError: false, revealURL: url)
            } catch {
                status = Status(text: String(localized: "Couldn’t export the settings: \(error.localizedDescription)"),
                                isError: true)
            }
            working = false
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        Task {
            do {
                importPreview = try await model.previewSettingsImport(from: url)
                status = nil
            } catch {
                status = Status(text: Self.describe(error), isError: true)
            }
            working = false
        }
    }

    private func replace(with archive: SettingsArchive) {
        working = true
        Task {
            do {
                _ = try await model.replaceSettings(with: archive)
                AppLanguage.relaunch()  // same relaunch the language switch uses
            } catch AppModel.SettingsReplaceError.backupFailed(let underlying) {
                status = Status(text: String(localized: "Couldn’t back up the current settings, so nothing was changed: \(underlying.localizedDescription)"),
                                isError: true)
                working = false
            } catch AppModel.SettingsReplaceError.installFailed(let underlying, _, true) {
                // Every store was put back: the app keeps running on its previous settings.
                status = Status(text: String(localized: "Couldn’t write the new settings: \(underlying.localizedDescription) Your previous settings were put back, so nothing changed."),
                                isError: true)
                working = false
            } catch AppModel.SettingsReplaceError.installFailed(let underlying, let backup, false) {
                status = Status(text: String(localized: "Some settings couldn’t be written: \(underlying.localizedDescription) Your previous settings are in \(backup.lastPathComponent) — import it to go back."),
                                isError: true, revealURL: backup)
                working = false
            } catch {
                status = Status(text: error.localizedDescription, isError: true)
                working = false
            }
        }
    }

    private func revealBackups() {
        guard let directory = model.settingsBackupDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    /// Words a refused import. Nothing has changed in any of these cases.
    static func describe(_ error: Error) -> String {
        guard let error = error as? SettingsArchiveError else {
            return String(localized: "Couldn’t read the file: \(error.localizedDescription)")
        }
        switch error {
        case .unreadable:
            return String(localized: "The file couldn’t be read. Nothing was changed.")
        case .notAnArchive:
            return String(localized: "This isn’t an OpenDisplay settings file. Nothing was changed.")
        case .newerVersion(let version):
            return String(localized: "This file was made by a newer OpenDisplay (format \(version)). Update OpenDisplay to import it. Nothing was changed.")
        case .unsupportedVersion(let version):
            return String(localized: "This settings file has a format OpenDisplay doesn’t know (\(version)). Nothing was changed.")
        case .damaged(let section):
            return String(localized: "Part of this settings file is damaged (\(section)). Nothing was changed.")
        case .invalidValue(let section, let item):
            return String(localized: "This settings file holds a value OpenDisplay can’t use (\(section): \(item)). Nothing was changed.")
        }
    }
}

/// The last look before an import replaces everything: what the file holds, which of its
/// displays this Mac doesn't know, and that a backup and a relaunch follow.
private struct ImportConfirmationView: View {
    let preview: AppModel.SettingsImportPreview
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let archive = preview.archive
        VStack(alignment: .leading, spacing: ODSpacing.md) {
            Text("Replace all settings with “\(preview.fileName)”?").font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(origin(archive)).font(.caption).foregroundStyle(.secondary)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                countRow(String(localized: "Remembered displays"), archive.registry.records.count)
                countRow(String(localized: "Display groups"), archive.settings.displayGroups.count)
                countRow(String(localized: "App presets"), archive.settings.appPresets.count)
                countRow(String(localized: "Protected layouts"), archive.settings.protectedLayouts.count)
                countRow(String(localized: "Scenes"), archive.scenes.count)
            }

            if !preview.unmatchedDisplays.isEmpty {
                ODInlineBanner(tone: .orange, systemImage: "display.trianglebadge.exclamationmark",
                               title: String(localized: "Settings for displays this Mac doesn’t know"),
                               message: unmatchedMessage)
            }

            Text("Your current settings are backed up first. OpenDisplay then relaunches to use the imported ones — like any quit, turning the displays it turned off back on.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Back Up, Replace and Relaunch", role: .destructive, action: onConfirm)
            }
        }
        .padding(ODSpacing.xl)
        .frame(width: 480)
    }

    private func origin(_ archive: SettingsArchive) -> String {
        let date = archive.createdAt.formatted(date: .abbreviated, time: .shortened)
        guard let version = archive.appVersion else { return String(localized: "Exported \(date).") }
        return String(localized: "Exported \(date) by OpenDisplay \(version).")
    }

    private var unmatchedMessage: String {
        let names = preview.unmatchedDisplays.map { "\u{2022} " + ($0.name ?? $0.id.rawValue) }
        return ([String(localized: "Their settings are imported as they are and take effect only when a display with the same identity connects — nothing is moved to a different display.")]
                + names).joined(separator: "\n")
    }

    private func countRow(_ label: String, _ count: Int) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(count.formatted())
        }
        .font(.caption)
    }
}
#endif
