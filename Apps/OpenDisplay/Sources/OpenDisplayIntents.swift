#if os(macOS)
import AppIntents
import AppKit
import AutomationSchema
import CoreGraphicsProvider
import DisplayDomain
import Foundation
import ProviderInterfaces
import TopologyCore
#if !PUBLIC_API_ONLY
import ExperimentalLifecycleProvider
#endif

/// Shortcuts / Siri integration (PRD §1 automation, recovery hierarchy step 3). Every intent routes
/// through the same `CommandGateway` the menu bar and CLI use, so it inherits the full safety,
/// verification, and audit path. Each invocation builds a fresh gateway (the intent may run outside
/// the running app), mirroring the CLI's independent composition.
enum OpenDisplayAutomation {
    static func makeGateway() async -> CommandGateway {
        let observer = CoreGraphicsProvider()
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        let environment = ProviderEnvironment(
            osBuild: ProcessInfo.processInfo.operatingSystemVersionString,
            isAppleSilicon: appleSilicon, transport: .unknown, displayClass: .unknown
        )
        let lifecycle: any LifecycleProvider
        #if !PUBLIC_API_ONLY
        let experimental = ExperimentalLifecycleProvider()
        lifecycle = await experimental.probe(environment).status == .supported ? experimental : observer
        #else
        lifecycle = observer
        #endif
        let checkpoints: any CheckpointStoring =
            (try? DiskCheckpointStore.defaultDirectory()).map(DiskCheckpointStore.init(directory:))
            ?? InMemoryCheckpointStore()
        let audit = (try? DiskAuditLog.defaultDirectory()).map(DiskAuditLog.init(directory:))
        return CommandGateway(observer: observer, lifecycleProvider: lifecycle,
                              checkpoints: checkpoints, auditLog: audit)
    }

    /// Routes an `opendisplay://` URL onto the shared `CommandGateway` (Issue 4) — the third automation
    /// front door beside the CLI and App Intents, inheriting the same safety/verification/audit path.
    ///
    /// Safe recovery commands run immediately and are audited like every other surface. Arrangement-
    /// altering commands are NEVER fired silently from a URL (any app or web link can trigger one):
    /// they bring the app forward for explicit in-app confirmation instead. Malformed or unknown URLs
    /// are a logged no-op, never a crash. Returns the parsed command (nil when unrecognized).
    @discardableResult
    static func handleURL(_ url: URL) async -> URLCommand? {
        guard let command = URLCommandParser.parse(url) else {
            log("ignored malformed/unknown URL: \(url.absoluteString)")
            return nil
        }
        guard !command.requiresConfirmation else {
            log("URL command \(command.name) is arrangement-altering — requires in-app confirmation, not auto-run")
            await MainActor.run { NSApp.activate(ignoringOtherApps: true) }
            return command
        }
        let gateway = await makeGateway()
        switch command {
        case .reconnectAll:
            _ = await gateway.reconnectAll(actor: .url)
        case .disconnect:
            break  // unreachable: disconnect requiresConfirmation and returned above
        }
        log("routed URL command \(command.name)")
        return command
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("OpenDisplay URL: \(message)\n".utf8))
    }
}

/// Reconnects every managed-offline display — the always-available recovery action, now usable from
/// Shortcuts, Siri, and the Shortcuts menu-bar surface.
struct ReconnectAllIntent: AppIntent {
    static let title: LocalizedStringResource = "Подключить все дисплеи"
    static let description = IntentDescription(
        "Подключает все дисплеи, отключённые через OpenDisplay. Команда восстановления доступна всегда."
    )
    // The intent does its own work; no need to bring the app forward.
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let envelope = await OpenDisplayAutomation.makeGateway().reconnectAll(actor: .appIntent)
        let restored = envelope.targets.filter { target in
            target.operations.contains { $0.verification == .verified }
        }.count
        let message: String
        switch envelope.status {
        case .noOp: message = "Нет дисплеев, требующих подключения."
        case .committed: message = "Подключено дисплеев: \(restored)."
        case .partial: message = "Подключено дисплеев: \(restored). Некоторые дисплеи восстановить не удалось."
        default: message = "Не удалось подтвердить восстановление дисплеев."
        }
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

/// Sets the built-in display's brightness from Shortcuts / Siri (via the same private DisplayServices
/// path the menu uses). Excluded from the public-API-only build.
struct SetBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Установить яркость дисплея"
    static let description = IntentDescription("Устанавливает яркость встроенного дисплея (0–100%).")
    static let openAppWhenRun = false

    @Parameter(title: "Яркость", inclusiveRange: (0, 100))
    var percent: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let clamped = max(0, min(100, percent))
        #if !PUBLIC_API_ONLY
        let observer = CoreGraphicsProvider()
        let snapshot = await observer.currentSnapshot()
        guard let builtIn = snapshot.observations.first(where: { $0.displayClass == .builtIn }),
              let cgID = builtIn.cgDisplayID else {
            return .result(dialog: "Встроенный дисплей не найден.")
        }
        let ok = DisplayServicesBrightnessProvider().setBrightness(Float(clamped) / 100, for: cgID)
        let message = ok ? "Запрошена яркость встроенного дисплея: \(clamped)%. Аппаратный результат не подтверждён." : "Не удалось изменить яркость."
        return .result(dialog: IntentDialog(stringLiteral: message))
        #else
        return .result(dialog: "Управление яркостью недоступно в этой сборке.")
        #endif
    }
}

struct OpenDisplayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ReconnectAllIntent(),
            phrases: [
                "Подключить все дисплеи через \(.applicationName)",
                "\(.applicationName) подключи все дисплеи"
            ],
            shortTitle: "Подключить все",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: SetBrightnessIntent(),
            phrases: [
                "Установить яркость через \(.applicationName)",
                "\(.applicationName) установи яркость"
            ],
            shortTitle: "Установить яркость",
            systemImageName: "sun.max"
        )
    }
}
#endif
