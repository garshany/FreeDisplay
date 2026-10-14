import SwiftUI
import AppKit
@preconcurrency import ScreenCaptureKit
@preconcurrency import CoreImage
import CaptureProvider
import UniformTypeIdentifiers

/// Explicitly initiated, in-memory SDR capture. No source or pixel persistence.
@MainActor
final class CapturePresentation: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate, NSWindowDelegate {
    struct Source: Identifiable {
        let id: String
        let title: String
        let display: SCDisplay?
        let window: SCWindow?
    }
    @Published var sources: [Source] = []
    @Published var selected = ""
    @Published var status = "Захват остановлен. Загрузите источники для запроса доступа к записи экрана."
    @Published var running = false
    @Published var busy = false
    @Published var flip = false
    @Published var angle = 0
    @Published var crop = 0.0
    @Published var lutName = "Нет"
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
            sources = content.displays.map { Source(id: "d\($0.displayID)", title: "Дисплей \($0.displayID) (\($0.width) × \($0.height))", display: $0, window: nil) }
            sources += content.windows.filter { $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.frame.width > 1 && $0.frame.height > 1 }.map {
                Source(id: "w\($0.windowID)", title: "\($0.owningApplication?.applicationName ?? "Приложение"): \($0.title ?? "Окно")", display: nil, window: $0)
            }
            if !sources.contains(where: { $0.id == selected }) { selected = sources.first?.id ?? "" }
            status = "Выберите источник и запустите захват. Будет захвачен только выбранный источник."
        } catch { status = "Не удалось загрузить источники: \(error.localizedDescription). Проверьте доступ к записи экрана в Системных настройках; может потребоваться перезапуск." }
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
            } else { status = "Источник исчез. Загрузите источники снова."; return }
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
            status = "Предпросмотр SDR запущен. Звук и запись в файл отключены."
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, self.running, !Task.isCancelled else { return }
                    do {
                        let current = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                        guard self.generation == token, !Task.isCancelled else { return }
                        let exists = source.display.map { d in current.displays.contains { $0.displayID == d.displayID } } ?? source.window.map { w in current.windows.contains { $0.windowID == w.windowID } } ?? false
                        if !exists { await self.stop(); self.status = "Источник исчез; захват остановлен."; return }
                    } catch { guard self.generation == token, !Task.isCancelled else { return }; await self.stop(); self.status = "Ошибка проверки источника; захват остановлен: \(error.localizedDescription)"; return }
                }
            }
        } catch {
            guard generation == token else { return }
            let failed = stream; stream = nil
            if let failed { try? await failed.stopCapture() }
            status = "Ошибка захвата: \(error.localizedDescription)"
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
            do { try await old.stopCapture(); if generation == stopToken { status = "Захват остановлен." } }
            catch { if generation == stopToken { status = "Предпросмотр закрыт; системная остановка сообщила: \(error.localizedDescription)" } }
        }
    }

    private func showPanel() {
        let window = NSPanel(contentRect: NSRect(x: 180, y: 180, width: 640, height: 360), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "OpenDisplay — предпросмотр захвата"
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
            self.status = "Захват завершён: \(error.localizedDescription)"
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
            guard (resource.fileSize ?? Int.max) <= 16_000_000 else { throw CubeLUT.ParseError.invalid("LUT превышает 16 МБ") }
            lut = try CubeLUT(text: String(contentsOf: url, encoding: .utf8)); lutName = url.lastPathComponent
        } catch { status = "LUT отклонён: \(error.localizedDescription)" }
    }
    func clearLUT() { lut = nil; lutName = "Нет" }
}

struct CapturePanel: View {
    @StateObject private var capture = CapturePresentation()
    var body: some View {
        Form {
            Section("Экспериментальный захват и «картинка в картинке»") {
                Text("Загрузите источники для начала. macOS может запросить доступ к записи экрана. Предпросмотр хранится в памяти; защищённое содержимое может быть пустым.").font(.caption)
                Button("Загрузить источники…") { Task { await capture.loadSources() } }.disabled(capture.busy || capture.running)
                Picker("Источник", selection: $capture.selected) {
                    Text("Выберите источник").tag("")
                    ForEach(capture.sources) { Text($0.title).tag($0.id) }
                }.disabled(capture.running || capture.busy)
                HStack {
                    Button("Запустить PIP") { Task { await capture.start() } }.disabled(capture.selected.isEmpty || capture.running || capture.busy)
                    Button("Остановить") { Task { await capture.stop() } }.disabled(!capture.running && !capture.busy)
                }
                Toggle("Отразить по горизонтали", isOn: $capture.flip)
                Picker("Поворот", selection: $capture.angle) { ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) } }
                LabeledContent("Обрезка / масштаб") {
                    HStack {
                        Slider(value: $capture.crop, in: 0...0.4).labelsHidden()
                        Text("\(Int(capture.crop * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent("LUT") {
                    HStack {
                        Text(capture.lutName).foregroundStyle(.secondary)
                        Button("Загрузить LUT .cube…") { capture.chooseLUT() }
                        Button("Сбросить LUT") { capture.clearLUT() }
                    }
                }
                Text(capture.status).font(.caption).textSelection(.enabled)
                Text("Только предпросмотр SDR. Точность HDR, калибровка цвета, защищённый контент и аппаратные маршруты не проверены.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { Task { await capture.stop() } }
    }
}
