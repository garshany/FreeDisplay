import SwiftUI
import AppKit
@preconcurrency import ScreenCaptureKit
@preconcurrency import CoreImage
import CaptureProvider
import UniformTypeIdentifiers

/// Explicitly initiated, in-memory SDR capture. No source or pixel persistence.
///
/// One process-wide instance (AM-08): the preview window is a PIP the user started and stops by
/// closing it or pressing Stop, so its lifetime can't be the Settings pane's. Owned by a SwiftUI
/// `@StateObject`, switching sections or closing Settings deallocated the presentation and its
/// stream with it — a running PIP silently ended.
@MainActor
final class CapturePresentation: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate, NSWindowDelegate {
    static let shared = CapturePresentation()

    struct Source: Identifiable {
        let id: String
        let title: String
        let display: SCDisplay?
        let window: SCWindow?
    }
    /// A display a per-device menu entry asked to capture, waiting for the source list.
    struct RequestedDisplay: Equatable {
        let displayID: CGDirectDisplayID
        let name: String
        var sourceID: String { "d\(displayID)" }
    }
    @Published var sources: [Source] = []
    @Published var selected = ""
    @Published private(set) var requestedDisplay: RequestedDisplay?
    @Published var status = String(localized: "Capture stopped. Load sources to request Screen Recording access.")
    @Published var running = false
    @Published var busy = false
    @Published var flip = false
    @Published var angle = 0
    @Published var crop = 0.0
    @Published var lutName = String(localized: "None")
    private var lut: CubeLUT?
    private var stream: SCStream?
    private var panel: NSPanel?
    private var imageView: NSImageView?
    private let context = CIContext()
    nonisolated private let frameContext = CIContext()
    private var generation = 0
    private var watchdog: Task<Void, Never>?

    deinit {
        watchdog?.cancel()
        if let stream { Task { try? await stream.stopCapture() } }
    }

    func loadSources() async {
        guard !busy, !running else { return }
        busy = true
        defer { busy = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            sources = content.displays.map { Source(id: "d\($0.displayID)", title: String(localized: "Display \($0.displayID) (\($0.width) × \($0.height))"), display: $0, window: nil) }
            sources += content.windows.filter { $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.frame.width > 1 && $0.frame.height > 1 }.map {
                Source(id: "w\($0.windowID)", title: "\($0.owningApplication?.applicationName ?? String(localized: "Application")): \($0.title ?? String(localized: "Window"))", display: nil, window: $0)
            }
            if !applyRequestedDisplay(), !sources.contains(where: { $0.id == selected }) {
                selected = sources.first?.id ?? ""
            }
            status = String(localized: "Choose a source and start capture. Only the selected source is captured.")
        } catch { status = String(localized: "Couldn’t load sources: \(error.localizedDescription). Check Screen Recording access in System Settings; a relaunch may be required.") }
    }

    /// Remembers which display the user opened capture for from that display's menu, and selects it
    /// as soon as the source list has it. Never re-targets a running capture, and doesn't load
    /// sources itself: loading is what asks macOS for Screen Recording access, so it stays a click.
    func request(displayID: CGDirectDisplayID, name: String) {
        requestedDisplay = RequestedDisplay(displayID: displayID, name: name)
        _ = applyRequestedDisplay()
    }

    /// Selects the requested display if it can, and reports whether it did. Consumed once applied,
    /// so a later manual choice isn't overridden on the next load.
    private func applyRequestedDisplay() -> Bool {
        guard !running, let requested = requestedDisplay,
              sources.contains(where: { $0.id == requested.sourceID }) else { return false }
        selected = requested.sourceID
        requestedDisplay = nil
        return true
    }

    func start() async {
        guard !busy, !running, let source = sources.first(where: { $0.id == selected }) else { return }
        busy = true
        defer { busy = false }
        generation += 1
        let token = generation
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard generation == token else { return }
            let filter: SCContentFilter
            let size: CGSize
            if let id = source.display?.displayID, let display = content.displays.first(where: { $0.displayID == id }) {
                let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                size = CGSize(width: display.width, height: display.height)
            } else if let id = source.window?.windowID, let window = content.windows.first(where: { $0.windowID == id }), window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier {
                filter = SCContentFilter(desktopIndependentWindow: window)
                size = window.frame.size
            } else { status = String(localized: "The source disappeared. Load sources again."); return }
            let config = SCStreamConfiguration()
            let scale = min(1, 1920 / max(size.width, size.height))
            config.width = max(2, Int(size.width * scale))
            config.height = max(2, Int(size.height * scale))
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.queueDepth = 3
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.capturesAudio = false
            guard generation == token else { return }
            let capture = SCStream(filter: filter, configuration: config, delegate: self)
            try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            stream = capture
            try await capture.startCapture()
            guard generation == token else { try? await capture.stopCapture(); return }
            showPanel()
            running = true
            status = String(localized: "SDR preview running. Audio and recording to file are off.")
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, self.running, !Task.isCancelled else { return }
                    do {
                        let current = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                        guard self.generation == token, !Task.isCancelled else { return }
                        let exists = source.display.map { d in current.displays.contains { $0.displayID == d.displayID } } ?? source.window.map { w in current.windows.contains { $0.windowID == w.windowID } } ?? false
                        if !exists { await self.stop(); self.status = String(localized: "The source disappeared; capture stopped."); return }
                    } catch { guard self.generation == token, !Task.isCancelled else { return }; await self.stop(); self.status = String(localized: "Source check failed; capture stopped: \(error.localizedDescription)"); return }
                }
            }
        } catch {
            guard generation == token else { return }
            let failed = stream; stream = nil
            if let failed { try? await failed.stopCapture() }
            status = String(localized: "Capture failed: \(error.localizedDescription)")
        }
    }

    func stop() async {
        generation += 1
        let stopToken = generation
        watchdog?.cancel(); watchdog = nil
        let old = stream; stream = nil
        running = false
        panel?.orderOut(nil); panel = nil; imageView = nil
        if let old {
            do { try await old.stopCapture(); if generation == stopToken { status = String(localized: "Capture stopped.") } }
            catch { if generation == stopToken { status = String(localized: "Preview closed; stopping the system capture reported: \(error.localizedDescription)") } }
        }
    }

    private func showPanel() {
        let window = NSPanel(contentRect: NSRect(x: 180, y: 180, width: 640, height: 360), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "OpenDisplay — Capture Preview")
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        let view = NSImageView(frame: window.contentView!.bounds)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        panel = window; imageView = view
        window.makeKeyAndOrderFront(nil)
    }
    nonisolated func windowWillClose(_ notification: Notification) {
        let closedID = (notification.object as? NSWindow).map(ObjectIdentifier.init)
        Task { @MainActor [weak self] in
            guard let self, let panel = self.panel, ObjectIdentifier(panel) == closedID else { return }
            await self.stop()
        }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            await self.stop()
            self.status = String(localized: "Capture ended: \(error.localizedDescription)")
        }
    }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        // Materialize the borrowed pixel buffer before entering actor isolation.
        // Core Image can otherwise retain mutable stream-backed storage across that boundary.
        let frame = CIImage(cvPixelBuffer: buffer)
        guard let pixels = frameContext.createCGImage(frame, from: frame.extent) else { return }
        MainActor.assumeIsolated {
            guard self.stream === stream, running else { return }
            let image = CaptureImageTransform.apply(to: CIImage(cgImage: pixels), crop: crop, flip: flip, angle: angle, lut: lut)
            guard let rendered = context.createCGImage(image, from: image.extent) else { return }
            imageView?.image = NSImage(cgImage: rendered, size: .zero)
        }
    }
    func chooseLUT() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .plainText]
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do {
            let resource = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (resource.fileSize ?? Int.max) <= 16_000_000 else { throw CubeLUT.ParseError.invalid(String(localized: "LUT exceeds 16 MB")) }
            lut = try CubeLUT(text: String(contentsOf: url, encoding: .utf8)); lutName = url.lastPathComponent
        } catch {
            // CubeLUT reports its parse errors in English; look them up in the catalog.
            status = String(localized: "LUT rejected: \(error.localizedDescription.appLocalized)")
        }
    }
    func clearLUT() { lut = nil; lutName = String(localized: "None") }
}

struct CapturePanel: View {
    // Observed, not owned: the presentation outlives this editor (AM-08).
    @ObservedObject private var capture = CapturePresentation.shared
    var body: some View {
        Form {
            Section("Experimental capture and picture in picture") {
                Text("Load sources to begin. macOS may ask for Screen Recording access. The preview stays in memory; protected content may appear blank.").font(.caption)
                Text("A running preview keeps going when you leave this section or close Settings. Close its window or press Stop to end it.").font(.caption)
                if let requested = capture.requestedDisplay {
                    Text("Opened for \(requested.name). Load sources to select it.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Load Sources…") { Task { await capture.loadSources() } }.disabled(capture.busy || capture.running)
                Picker("Source", selection: $capture.selected) {
                    Text("Choose a source").tag("")
                    ForEach(capture.sources) { Text($0.title).tag($0.id) }
                }.disabled(capture.running || capture.busy)
                HStack {
                    Button("Start PIP") { Task { await capture.start() } }.disabled(capture.selected.isEmpty || capture.running || capture.busy)
                    Button("Stop") { Task { await capture.stop() } }.disabled(!capture.running && !capture.busy)
                }
                Toggle("Flip horizontally", isOn: $capture.flip)
                Picker("Rotation", selection: $capture.angle) { ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) } }
                LabeledContent("Crop / zoom") {
                    HStack {
                        Slider(value: $capture.crop, in: 0...0.4).labelsHidden()
                        Text("\(Int(capture.crop * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent("LUT") {
                    HStack {
                        Text(capture.lutName).foregroundStyle(.secondary)
                        Button("Load .cube LUT…") { capture.chooseLUT() }
                        Button("Reset LUT") { capture.clearLUT() }
                    }
                }
                Text(capture.status).font(.caption).textSelection(.enabled)
                Text("SDR preview only. HDR accuracy, colour calibration, protected content and hardware routes are not verified.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
