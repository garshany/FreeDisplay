// SPDX-License-Identifier: GPL-3.0-or-later
// Original OpenDisplay tools. Uses public APIs only; exported plans never install themselves.
#if os(macOS)
import AppKit
import CoreGraphics
import SwiftUI
import TopologyCore

@MainActor
struct AdvancedDisplayToolsView: View {
    let displayID: CGDirectDisplayID
    let displayName: String
    @State private var edid: EDIDDocument?
    @State private var status = String(localized: "Import a monitor’s binary EDID to validate it and export a configuration.")
    @State private var width = 1920
    @State private var height = 1080

    private var screen: NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }
    }

    var body: some View {
        Form {
            Section("HDR capabilities") {
                // The pane follows the display selected under Displays; name it so the
                // EDR values below are not ambiguous on multi-monitor setups.
                LabeledContent("Display", value: displayName)
                if let screen {
                    LabeledContent("Available EDR headroom", value: String(format: "%.2f×", screen.maximumExtendedDynamicRangeColorComponentValue))
                    LabeledContent("Potential EDR headroom", value: String(format: "%.2f×", screen.maximumPotentialExtendedDynamicRangeColorComponentValue))
                    Text("EDR headroom describes macOS’s current output. It doesn’t confirm that HDR reaches the display, and it doesn’t turn on hardware HDR.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No NSScreen data for this display.")
                }
            }
            Section("EDID tools — export only") {
                Button("Import EDID…", action: importEDID)
                if let edid {
                    LabeledContent("Manufacturer", value: edid.manufacturer)
                    LabeledContent("Product code", value: String(format: "0x%04X", edid.productID))
                    LabeledContent("Name", value: edid.displayName ?? String(localized: "Not specified"))
                    LabeledContent("Validated blocks", value: String(edid.extensionCount + 1))
                    Button("Export Validated Configuration…", action: exportEDID)
                }
                Text(status).font(.caption).textSelection(.enabled)
                Text("The imported file isn’t matched to a display automatically. Check the manufacturer and product code before installing it by other means. OpenDisplay doesn’t install system configurations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("HiDPI mode planning") {
                TextField("Logical width", value: $width, format: .number)
                TextField("Logical height", value: $height, format: .number)
                Button("Export HiDPI Plan…", action: exportPlan)
                Text("Modes macOS already offers are chosen in the regular resolution list. Custom physical modes need external setup with administrator rights. Only the sizes and the restore steps are exported here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        // Without .grouped macOS renders Form in the two-column style: section headers drift into
        // the value column, the form is centred vertically and long captions widen the window.
        .formStyle(.grouped)
        .navigationTitle("EDID & HiDPI")
    }

    private func importEDID() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 32768 else { throw EDIDError.invalidLength }
            edid = try EDIDDocument(data: Data(contentsOf: url))
            status = String(localized: "Checksums of all EDID blocks verified. Extension blocks are kept as-is, uninterpreted.")
        } catch {
            edid = nil; status = String(localized: "EDID rejected: \(Self.describe(error))")
        }
    }

    /// EDID parse errors come from TopologyCore in English: static ones are looked up in the
    /// catalog, the one carrying a block number is re-worded here so it can be translated too.
    private static func describe(_ error: Error) -> String {
        if case EDIDError.checksum(let block) = error {
            return String(localized: "Invalid checksum in EDID block #\(block + 1).")
        }
        return error.localizedDescription.appLocalized
    }

    private func save(_ data: Data, name: String) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic); status = String(localized: "Exported \(url.lastPathComponent). Display settings were not changed.") }
        catch { status = String(localized: "Export failed: \(error.localizedDescription)") }
    }

    private func exportEDID() {
        guard let edid else { return }
        do { save(try edid.overridePropertyList(), name: "DisplayProductID-\(String(edid.productID, radix: 16)).plist") }
        catch { status = String(localized: "Configuration export failed: \(error.localizedDescription.appLocalized)") }
    }

    private func exportPlan() {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            save(try encoder.encode(HiDPIConfigurationPlan(width: width, height: height)), name: "HiDPI-plan.json")
        } catch { status = String(localized: "Invalid HiDPI plan: \(error.localizedDescription.appLocalized)") }
    }
}
#endif
