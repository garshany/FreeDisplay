// SPDX-License-Identifier: GPL-3.0-or-later
// Original OpenDisplay tools. Uses public APIs only; exported plans never install themselves.
#if os(macOS)
import AppKit
import CoreGraphics
import CoreGraphicsProvider
import DisplayDomain
import SwiftUI
import TopologyCore

/// Settings → EDID & HiDPI. Reads the chosen display's EDID read-only (SD-15 / FB-20), decodes it,
/// shows its bytes and exports them; imports EDID files for inspection. Nothing here writes EDID,
/// installs an override or changes a mode.
@MainActor
struct AdvancedDisplayToolsView: View {
    @EnvironmentObject private var model: AppModel
    /// The display this pane inspects. Its own choice: setting `model.selectedDisplayID` would
    /// also switch Settings to the Displays section.
    @State private var pickedID: DisplayRecordID?
    @State private var live: LiveEDID = .notRead
    @State private var imported: ImportedEDID?
    @State private var inspecting: Source = .display
    @State private var byteFormat: EDIDByteFormat = .hexDump
    @State private var status: String?
    @State private var width = 1920
    @State private var height = 1080
    @State private var pastingBase64 = false

    private enum Source: Hashable { case display, file }

    /// The registry lookup for one display. The display it was read for travels with the result,
    /// so after switching the picker the previous display's bytes are never shown under the new
    /// one — not even for the moment before the new read starts.
    private enum LiveEDID: Equatable {
        case notRead
        case reading(CGDirectDisplayID)
        case read(EDIDBinding.Outcome, CGDirectDisplayID)
    }

    /// `live`, if it belongs to the display now selected.
    private var liveForDisplay: LiveEDID {
        switch live {
        case .reading(let id) where id == display?.cgDisplayID: return live
        case .read(_, let id) where id == display?.cgDisplayID: return live
        default: return .notRead
        }
    }

    private var isReading: Bool {
        if case .reading = liveForDisplay { return true }
        return false
    }

    private struct ImportedEDID {
        let name: String
        let bytes: [UInt8]
        /// Pasted as Base64 text rather than read from a file.
        var pasted = false
    }

    /// Online displays macOS gave an ID; the pane follows the Displays selection until a display
    /// is picked here.
    private var candidates: [DisplayObservation] { model.displays.filter { $0.cgDisplayID != nil } }

    private var display: DisplayObservation? {
        candidates.first { $0.recordID == pickedID }
            ?? candidates.first { $0.recordID == model.selectedDisplayID }
            ?? candidates.first { $0.isMain }
            ?? candidates.first
    }

    private var screen: NSScreen? { display?.cgDisplayID.flatMap(DisplayScreenLookup.screen(for:)) }

    /// The bytes being inspected, with the words that say where they came from.
    private var inspected: (bytes: [UInt8], source: String)? {
        switch inspecting {
        case .file:
            guard let imported else { return nil }
            if imported.pasted {
                return (imported.bytes, String(localized: "Pasted Base64 text. It isn’t matched to any display."))
            }
            return (imported.bytes, String(localized: "File “\(imported.name)”. It isn’t matched to any display."))
        case .display:
            guard case .read(.matched(let bytes), _) = liveForDisplay else { return nil }
            return (bytes, String(localized: "Read from macOS (IORegistry) and matched to this display by vendor, product code and serial number."))
        }
    }

    var body: some View {
        Form {
            Section {
                if candidates.isEmpty {
                    Text("No connected display.").foregroundStyle(.secondary)
                } else {
                    Picker("Display", selection: Binding(get: { display?.recordID }, set: { pickedID = $0 })) {
                        ForEach(candidates, id: \.recordID) { candidate in
                            Text(model.displayName(for: candidate)).tag(Optional(candidate.recordID))
                        }
                    }
                }
                Text("Everything here only reads. Nothing writes to the display, installs a configuration or changes a mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("HDR capabilities") {
                if let screen {
                    LabeledContent("Available EDR headroom", value: String(format: "%.2f×", screen.maximumExtendedDynamicRangeColorComponentValue))
                    LabeledContent("Potential EDR headroom", value: String(format: "%.2f×", screen.maximumPotentialExtendedDynamicRangeColorComponentValue))
                    Text("EDR headroom describes macOS’s current output. It doesn’t confirm that HDR reaches the display, and it doesn’t turn on hardware HDR.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No NSScreen data for this display.")
                }
            }
            Section("EDID of this display") {
                liveStatus
                HStack {
                    Button("Read Again") { Task { await readLive() } }
                        .disabled(display == nil || isReading)
                    if imported != nil {
                        Spacer()
                        Picker("Inspect", selection: $inspecting) {
                            Text("This display").tag(Source.display)
                            Text("Imported file").tag(Source.file)
                        }
                        .pickerStyle(.segmented).fixedSize()
                    }
                }
            }
            if let inspected {
                inspector(bytes: inspected.bytes, source: inspected.source)
            }
            Section("EDID file") {
                HStack {
                    Button("Import EDID…", action: importEDID)
                    Button("Paste Base64…") { pastingBase64 = true }
                }
                if let imported, !imported.pasted {
                    LabeledContent("File", value: imported.name)
                }
                Text("The imported file isn’t matched to a display automatically. Check the manufacturer and product code before installing it by other means. OpenDisplay doesn’t install system configurations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let status {
                Section { Text(status).font(.caption).textSelection(.enabled) }
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
        .sheet(isPresented: $pastingBase64) {
            Base64EDIDSheet { bytes in
                imported = ImportedEDID(name: String(localized: "Pasted Base64"), bytes: bytes, pasted: true)
                inspecting = .file
                status = nil
            }
        }
        .task(id: display?.recordID) {
            inspecting = .display
            await readLive()
        }
    }

    // MARK: Live EDID

    @ViewBuilder private var liveStatus: some View {
        switch liveForDisplay {
        case .notRead:
            Text("Not read yet.").foregroundStyle(.secondary)
        case .reading:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reading…") }
        case .read(.matched(let bytes), _):
            LabeledContent("Found", value: String(localized: "Size: \(bytes.count) B"))
        case .read(.ambiguous(let candidates), _):
            Text("Ambiguous: \(candidates) different EDIDs carry this display’s vendor, product code and serial number — typically identical monitors without serial numbers. None is shown, because it could be another monitor’s.")
                .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        case .read(.notFound, _):
            Text("Not found: no EDID that macOS exposes carries this display’s vendor, product code and serial number. Built-in panels and some adapters don’t expose one.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .read(.unidentifiedTarget, _):
            Text("Unavailable: macOS reports no vendor or product code for this display, so no EDID can be tied to it.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func readLive() async {
        guard let cgID = display?.cgDisplayID else { live = .notRead; return }
        live = .reading(cgID)
        let outcome = await Task.detached(priority: .userInitiated) { EDIDReader.lookup(for: cgID) }.value
        // The selection may have moved on while the registry was walked.
        guard display?.cgDisplayID == cgID else { return }
        live = .read(outcome, cgID)
    }

    // MARK: Inspector

    @ViewBuilder
    private func inspector(bytes: [UInt8], source: String) -> some View {
        let decoded = EDIDDecoder.decode(bytes)
        let strict = Result { try EDIDDocument(data: Data(bytes)) }
        Section("Decoded EDID") {
            LabeledContent("Source") {
                Text(source).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Validity") {
                Text(decoded.isStructurallyValid
                     ? String(localized: "Header, checksums and block count are consistent")
                     : String(localized: "Problems found — see Structure"))
                    .foregroundStyle(decoded.isStructurallyValid ? Color.secondary : Color.orange)
            }
            HStack {
                Button("Export Original Bytes (.bin)…") { exportBinary(bytes, decoded: decoded) }
                Button("Export Override Plist…") { exportPlist(strict) }
                    .disabled((try? strict.get()) == nil)
            }
            if case .failure(let error) = strict {
                Text("No override plist: \(Self.describe(error))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Decoded values are what the bytes state. They don’t prove the display or macOS supports them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(EDIDReportFormatter.sections(decoded, .app)) { section in
            Section(section.title) {
                ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                    LabeledContent(row.label) {
                        Text(row.value).multilineTextAlignment(.trailing).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(section.notes, id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        Section("Bytes") {
            Picker("Format", selection: $byteFormat) {
                Text("Hex dump").tag(EDIDByteFormat.hexDump)
                Text("Hex").tag(EDIDByteFormat.hex)
                Text("Base64").tag(EDIDByteFormat.base64)
                Text("C array").tag(EDIDByteFormat.cArray)
            }
            .pickerStyle(.segmented)
            let rendered = byteFormat.render(bytes)
            ScrollView([.horizontal, .vertical]) {
                Text(rendered).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: byteFormat != .hex && byteFormat != .base64, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(minHeight: 120, idealHeight: 220)
            Button("Copy Bytes") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rendered, forType: .string)
                status = String(localized: "Bytes copied as text.")
            }
        }
    }

    // MARK: Files

    private func importEDID() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 32768 else { throw EDIDError.invalidLength }
            imported = ImportedEDID(name: url.lastPathComponent, bytes: Array(try Data(contentsOf: url)))
            inspecting = .file
            status = nil
        } catch {
            status = String(localized: "EDID rejected: \(Self.describe(error))")
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

    /// The bytes exactly as read or imported — no re-encoding, nothing dropped.
    private func exportBinary(_ bytes: [UInt8], decoded: EDIDDecoded) {
        var stem = inspecting == .display ? (display.map(model.displayName(for:)) ?? "Display") : "EDID"
        if let base = decoded.base { stem += "-\(base.manufacturerID)\(String(format: "%04X", base.productCode))" }
        let safe = stem.map { "/:\\".contains($0) ? "-" : $0 }
        save(Data(bytes), name: String(safe) + ".bin")
    }

    private func exportPlist(_ strict: Result<EDIDDocument, Error>) {
        guard let document = try? strict.get() else { return }
        do { save(try document.overridePropertyList(), name: "DisplayProductID-\(String(document.productID, radix: 16)).plist") }
        catch { status = String(localized: "Configuration export failed: \(error.localizedDescription.appLocalized)") }
    }

    private func exportPlan() {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            save(try encoder.encode(HiDPIConfigurationPlan(width: width, height: height)), name: "HiDPI-plan.json")
        } catch { status = String(localized: "Invalid HiDPI plan: \(error.localizedDescription.appLocalized)") }
    }
}
/// Takes pasted Base64 EDID text for inspection (SD-15): whitespace and line breaks are ignored,
/// anything that isn't canonical Base64 is refused with the reason, and the decoded bytes go to the
/// inspector unchanged — valid EDID or not.
private struct Base64EDIDSheet: View {
    @Environment(\.dismiss) private var dismiss
    let accept: ([UInt8]) -> Void
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste EDID as Base64").font(.headline)
            Text("Spaces and line breaks are ignored. The bytes are only inspected: nothing is installed or written to a display.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Inspect") { inspect() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 300)
    }

    private func inspect() {
        do throws(EDIDByteFormat.Base64Error) {
            let bytes = try EDIDByteFormat.decodeBase64(text)
            accept(bytes)
            dismiss()
        } catch {
            switch error {
            case .empty:
                problem = String(localized: "Nothing to inspect: the text is empty.")
            case .invalid:
                problem = String(localized: "This isn’t Base64: it has characters outside the Base64 alphabet, or a length or padding no encoder writes.")
            case .nonCanonical:
                problem = String(localized: "This Base64 doesn’t encode its bytes the standard way (stray bits at the end), so it isn’t used.")
            }
        }
    }
}
#endif
