#if os(macOS)
import AppKit
import DisplayDomain
import OpenDisplayDesignSystem
import SwiftUI

/// A display's menu icon (SD-11): a button showing the current symbol that opens the picker.
/// Shared by Settings → Menu and the display's own settings so both edit the same value the same way.
struct DisplaySymbolButton: View {
    /// The stored custom symbol, or nil for the class glyph. Passed as stored (not pre-validated) so
    /// a name this macOS doesn't have can still be seen and removed.
    let symbol: String?
    let fallback: String
    let onChange: (String?) -> Void
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            Image(systemName: symbol.flatMap(DisplaySymbolPicker.existing) ?? fallback)
                .font(.system(size: 15)).frame(width: 26, height: 22)
        }
        .buttonStyle(.bordered).controlSize(.small)
        .help(String(localized: "Choose the icon shown in the menu"))
        .accessibilityLabel(String(localized: "Menu icon"))
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            DisplaySymbolPicker(selected: symbol, fallback: fallback, onSelect: onChange) { picking = false }
        }
    }
}

/// The picker: a searchable grid of display-related SF Symbols plus any valid symbol name typed in.
/// A choice applies at once; Remove (only when a custom icon is set) goes back to the class glyph;
/// Done closes. macOS has no public list of every symbol, so the grid is a curated set and the
/// search field also accepts an exact symbol name, checked against this macOS before it's offered.
private struct DisplaySymbolPicker: View {
    let selected: String?
    let fallback: String
    let onSelect: (String?) -> Void
    let onDone: () -> Void
    @State private var search = ""

    /// Display-ish symbols first, then general markers for telling identical monitors apart.
    private static let curated = [
        "display", "display.2", "laptopcomputer", "desktopcomputer", "macmini", "macpro.gen3", "pc",
        "tv", "tv.inset.filled", "play.tv", "videoprojector", "ipad.landscape", "ipad", "iphone",
        "airplayvideo", "rectangle.dashed", "rectangle.on.rectangle", "rectangle.split.2x1",
        "rectangle.portrait", "rectangle.inset.filled", "menubar.rectangle", "sidebar.left",
        "gamecontroller", "film", "photo", "paintpalette", "music.note", "keyboard", "house",
        "briefcase", "building.2", "star", "heart", "bolt", "moon", "sun.max", "leaf", "flame",
        "cube", "sparkles", "eye", "bookmark", "flag", "tag",
        "1.circle", "2.circle", "3.circle", "4.circle", "l.circle", "r.circle",
    ].filter(Self.exists)

    nonisolated private static func exists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// The name, if this macOS has that symbol.
    nonisolated static func existing(_ name: String) -> String? { exists(name) ? name : nil }

    private var query: String { search.trimmingCharacters(in: .whitespaces).lowercased() }

    private var shown: [String] {
        guard !query.isEmpty else { return Self.curated }
        var matches = Self.curated.filter { $0.contains(query) }
        // An exact symbol name outside the curated set is offered too, once macOS confirms it exists.
        if !matches.contains(query), Self.exists(query) { matches.insert(query, at: 0) }
        return matches
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ODSpacing.sm) {
            TextField(String(localized: "Search or type a symbol name"), text: $search)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 4), count: 8), spacing: 4) {
                    ForEach(shown, id: \.self) { name in
                        Button { onSelect(name) } label: {
                            Image(systemName: name).font(.system(size: 15))
                                .frame(width: 32, height: 28)
                                .background(name == selected ? ODColor.accentTint : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(name)
                        .accessibilityLabel(name)
                    }
                }
            }
            .frame(height: 170)
            if shown.isEmpty {
                Text("No symbol by that name on this Mac.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: selected.flatMap(Self.existing) ?? fallback).frame(width: 18)
                Text(selected ?? String(localized: "Standard icon")).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if selected != nil {
                    Button("Remove") { onSelect(nil) }.controlSize(.small)
                }
                Button("Done") { onDone() }.controlSize(.small).keyboardShortcut(.defaultAction)
            }
        }
        .padding(ODSpacing.md)
        .frame(width: 330)
    }
}
#endif
