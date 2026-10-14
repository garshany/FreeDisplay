#if os(macOS)
import DisplayDomain
import OpenDisplayDesignSystem
import SwiftUI
import TopologyCore

/// Settings → Menu: how the menu-bar panel is laid out (AM-11, SO-23, FA-12–FA-15, SD-11). Every
/// change saves at once and only changes presentation — no display is touched from here.
struct MenuSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ODSpacing.lg) {
                MenuIconRecoveryCard()
                MenuDisplaysCard()
                MenuContentsCard()
                MenuBehaviorCard()
            }
            .padding(ODSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Menu")
    }
}

// MARK: - Icon recovery (FA-15)

/// macOS can hide the menu-bar icon without telling the app — behind the camera notch when the bar
/// is full, or switched off under System Settings → Menu Bar — and the icon is the app's only
/// standing UI. This names the ways back that don't need it.
private struct MenuIconRecoveryCard: View {
    var body: some View {
        ODCard(title: String(localized: "Menu bar icon"), padded: true) {
            VStack(alignment: .leading, spacing: ODSpacing.sm) {
                Text("If the OpenDisplay icon isn’t in the menu bar, macOS may be hiding it — behind the camera notch when the menu bar is full, or because it is switched off in System Settings → Menu Bar. Opening OpenDisplay again from Finder, Spotlight or Launchpad always brings up this window, and the button below opens the menu panel without the icon.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: ODSpacing.sm) {
                    Button("Open Menu Panel") {
                        NotificationCenter.default.post(name: .openDisplayShowTray, object: nil)
                    }
                    Text("⌥-click the icon opens Settings; right-click opens a short menu.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Displays: visibility, name, icon, order (SD-11, FA-12)

private struct MenuDisplaysCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let entries = model.rememberedDisplaysInMenuOrder
        VStack(alignment: .leading, spacing: ODSpacing.sm) {
            ODCard(title: String(localized: "Displays in the menu"),
                   footnote: String(localized: "Hiding a display only takes it out of this menu: it stays connected and keeps responding to brightness keys, hotkeys and automation. A display OpenDisplay turned off, or one that is blacked out, always stays in the menu, so it can be brought back. The order is the menu’s only — it doesn’t move displays on the desktop.")) {
                if entries.isEmpty {
                    Text("No displays yet.").font(.callout).foregroundStyle(.secondary).padding(12)
                }
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { ODDivider() }
                    MenuDisplayRow(entry: entry, index: index, entries: entries)
                }
            }
            HStack(spacing: ODSpacing.md) {
                Toggle("Show the main display first", isOn: Binding(
                    get: { model.menuLayout.mainDisplayFirst },
                    set: { value in model.updateMenuLayout { $0.mainDisplayFirst = value } }))
                Spacer()
                Text(model.menuLayout.displayOrder.isEmpty
                     ? String(localized: "Order: automatic — built-in first, then by name")
                     : String(localized: "Order: your own"))
                    .font(.caption).foregroundStyle(.secondary)
                Button("Automatic Order") { model.resetMenuOrder() }
                    .controlSize(.small)
                    .disabled(model.menuLayout.displayOrder.isEmpty)
            }
        }
    }
}

private struct MenuDisplayRow: View {
    @EnvironmentObject private var model: AppModel
    let entry: RememberedDisplay
    let index: Int
    let entries: [RememberedDisplay]
    @State private var name = ""

    var body: some View {
        let ids = entry.observationIDs
        HStack(spacing: 9) {
            DisplaySymbolButton(symbol: ids.lazy.compactMap { model.menuLayout.iconSymbol(for: $0) }.first,
                                fallback: trayGlyph(model.rememberedClass(of: entry))) { symbol in
                model.setMenuIcon(symbol, for: ids)
            }
            VStack(alignment: .leading, spacing: 1) {
                TextField(placeholder, text: $name)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    .onSubmit { Task { await model.setAlias(name, forRemembered: entry) } }
                    .disabled(!canRename)
                    .help(canRename ? String(localized: "The name OpenDisplay shows; leave it empty for the display’s own name")
                                    : String(localized: "This display has no saved record to name yet"))
                Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Toggle("Show in menu", isOn: Binding(
                get: { !ids.contains { model.menuLayout.isHidden($0) } },
                set: { model.setHiddenInMenu(!$0, for: ids) }))
                .toggleStyle(.switch).controlSize(.small)
            ControlGroup {
                Button { move(by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .help(String(localized: "Move up in the menu"))
                Button { move(by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == entries.count - 1)
                    .help(String(localized: "Move down in the menu"))
            }
            .controlSize(.small).frame(width: 64)
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .onChange(of: entry.record?.alias, initial: true) { _, alias in name = alias ?? "" }
    }

    /// A display with no persisted record (an off card the registry never named) has nowhere to
    /// keep a name; a connected one can always be named, which also gives it a record.
    private var canRename: Bool { entry.isConnected || entry.isRegistered }

    private var placeholder: String {
        entry.record?.fingerprint.modelName ?? model.rememberedName(of: entry)
    }

    private var statusText: String {
        switch entry.status {
        case .connected: return String(localized: "Connected")
        case .turnedOff, .reconnectFailed: return model.logicalOffMethod == .mirror
            ? String(localized: "Mirrored by OpenDisplay") : String(localized: "Turned off by OpenDisplay")
        case .notConnected: return String(localized: "Not connected")
        }
    }

    private func move(by delta: Int) {
        let moved = MenuDisplayOrder.moving(entries.map(candidate), from: index, to: index + delta).map(\.id)
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        model.setMenuOrder(moved.compactMap { byID[$0] })
    }

    private func candidate(_ entry: RememberedDisplay) -> MenuDisplayOrder.Candidate {
        .init(id: entry.id, name: entry.id)
    }
}

// MARK: - Contents (AM-11, SO-23, FA-14)

private struct MenuContentsCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: ODSpacing.sm) {
            familyCard(String(localized: "Sliders"), .slider)
            familyCard(String(localized: "Display features"), .displayFeature,
                       footnote: String(localized: "“Visible” puts an item straight into a display’s section, “In More” behind its More button. An item a display or this build can’t offer never appears, whatever is chosen here, and hiding an item only takes it out of the menu — what it controls keeps working. With “Toggles” hidden, its switches move into “Manage display”, or stay in More if that is hidden too."))
            familyCard(String(localized: "Tools"), .tool,
                       footnote: String(localized: "Reconnect all and Detect displays always stay in Tools: they are the way back when a display is lost."))
            HStack(alignment: .firstTextBaseline, spacing: ODSpacing.md) {
                Button("Reset Menu Layout") { model.resetMenuLayout() }
                    .disabled(model.menuLayout.hasDefaultContents)
                Text("Puts every item back where it was by default and closes open sections. Display names, icons, hidden displays, the order and the options below stay as they are.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func familyCard(_ title: String, _ section: MenuItemFamily.Section, footnote: String? = nil) -> some View {
        ODCard(title: title, footnote: footnote) {
            let families = MenuItemFamily.families(in: section)
            ForEach(Array(families.enumerated()), id: \.element) { index, family in
                if index > 0 { ODDivider() }
                ODRow(Self.title(of: family)) {
                    Picker("", selection: Binding(
                        get: { model.menuPlacement(family) },
                        set: { placement in model.updateMenuLayout { $0.setPlacement(placement, for: family) } })) {
                        ForEach(family.allowedPlacements, id: \.self) { placement in
                            Text(Self.label(placement, section: section)).tag(placement)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
    }

    private static func label(_ placement: MenuPlacement, section: MenuItemFamily.Section) -> String {
        switch placement {
        case .visible: return section == .tool ? String(localized: "Shown") : String(localized: "Visible")
        case .expanded: return String(localized: "In More")
        case .hidden: return String(localized: "Hidden")
        }
    }

    /// Row titles, matching what the tray itself calls each item.
    static func title(of family: MenuItemFamily) -> String {
        switch family {
        case .brightness: return String(localized: "Brightness")
        case .resolution: return String(localized: "Resolution")
        case .volume: return String(localized: "Volume")
        case .displayMode: return String(localized: "Display mode")
        case .refreshRate: return String(localized: "Refresh rate")
        case .toggles: return String(localized: "Toggles")
        case .picture: return String(localized: "Picture")
        case .monitorControls: return String(localized: "Monitor controls")
        case .inputSource: return String(localized: "Input source")
        case .monitorColorPreset: return String(localized: "Monitor color preset")
        case .colorProfile: return String(localized: "Color profile")
        case .rotation: return String(localized: "Display rotation")
        case .mirroring: return String(localized: "Mirroring")
        case .pictureInPicture: return String(localized: "Picture in Picture and streaming")
        case .manageDisplay: return String(localized: "Manage display")
        case .scenes: return String(localized: "Scenes")
        case .arrangement: return String(localized: "Display arrangement…")
        case .capture: return String(localized: "Capture and Picture in Picture…")
        case .edid: return String(localized: "EDID and HiDPI…")
        case .automation: return String(localized: "Automation and HTTP…")
        case .hotkeysAndDiagnostics: return String(localized: "Hotkeys and diagnostics…")
        case .exportDiagnostics: return String(localized: "Export diagnostics")
        case .updates: return String(localized: "Check for updates")
        }
    }
}

// MARK: - Behaviour (FA-13, FA-14)

private struct MenuBehaviorCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ODCard(title: String(localized: "Behaviour"), padded: true) {
            VStack(alignment: .leading, spacing: ODSpacing.sm) {
                toggle(String(localized: "Remember open sections"),
                       String(localized: "The menu reopens — also after a restart — with the same More sections, features and Tools open. Off, it always opens compact."),
                       \.rememberExpandedSections)
                toggle(String(localized: "One display’s More at a time"),
                       String(localized: "Opening a display’s More closes the other displays’ More."),
                       \.oneMoreSectionAtATime)
                toggle(String(localized: "One feature at a time"),
                       String(localized: "Opening a feature closes that display’s other open features."),
                       \.oneFeatureAtATime)
                toggle(String(localized: "Animate the menu"),
                       String(localized: "Off, sections open and close at once. macOS Reduce Motion always turns animation off."),
                       \.animateMenu)
                toggle(String(localized: "Show slider names"),
                       String(localized: "A small name above each slider."),
                       \.showSliderNames)
                toggle(String(localized: "Show slider values"),
                       String(localized: "The current percentage or size next to each slider."),
                       \.showSliderValues)
            }
        }
    }

    private func toggle(_ title: String, _ detail: String,
                        _ key: WritableKeyPath<MenuLayoutSettings, Bool>) -> some View {
        Toggle(isOn: Binding(get: { model.menuLayout[keyPath: key] },
                             set: { value in model.updateMenuLayout { $0[keyPath: key] = value } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
#endif
