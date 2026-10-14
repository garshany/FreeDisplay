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

/// Shortcuts / Siri integration (PRD §1 automation, recovery hierarchy step 3). Intents and URLs act
/// through the running app's `AppModel` when there is one — it alone holds the live managed-offline
/// ledger and settings — and fall back to a freshly composed `CommandGateway` only when no model
/// exists in this process.
enum OpenDisplayAutomation {
    /// The app's model, registered by `AppDelegate` at launch. Weak: automation must never keep a
    /// torn-down model alive. App Intents in this target run inside the app process, so an intent
    /// normally finds it here.
    @MainActor static weak var liveModel: AppModel?

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
    /// altering commands are NEVER fired from a URL (any app or web link can trigger one). There is
    /// no in-app review flow for them, so they are explicitly refused with a visible alert rather
    /// than the app merely coming forward and the request vanishing. Malformed or unknown URLs are a
    /// logged no-op, never a crash. Returns the parsed command (nil when unrecognized).
    @discardableResult
    static func handleURL(_ url: URL, model: AppModel) async -> URLCommand? {
        guard let command = URLCommandParser.parse(url) else {
            log("ignored malformed/unknown URL: \(url.absoluteString)")
            return nil
        }
        guard !command.requiresConfirmation else {
            log("refused URL command \(command.name): arrangement-altering commands aren't accepted from URLs")
            // Shown from a run-loop block, not a main-actor job: a modal alert run inside a main-queue
            // job would hold every other main-actor task — the display safety net included — until
            // someone dismisses it, and any web page can open this URL.
            RunLoop.main.perform { MainActor.assumeIsolated { presentRefusal(of: command) } }
            CFRunLoopWakeUp(CFRunLoopGetMain())  // a scheduled block doesn't wake an idle run loop
            return command
        }
        switch command {
        case .reconnectAll:
            // The app's own Reconnect All: a gateway composed here never sees the managed-offline
            // ledger, so it reconnected nothing.
            let envelope = await model.reconnectAll(actor: .url)
            log("routed URL command \(command.name): \(envelope.status.rawValue)")
        case .disconnect:
            break  // unreachable: disconnect requiresConfirmation and returned above
        }
        return command
    }

    @MainActor private static var isPresentingRefusal = false

    /// Tells the user a link's request was refused and what to do instead. Nothing from the URL is
    /// echoed — its text is whatever the linking page chose, and an alert from this app must not be
    /// a place to show it.
    @MainActor private static func presentRefusal(of command: URLCommand) {
        guard case .disconnect = command else { return }  // recovery is never refused
        // One explanation at a time: a page firing the URL repeatedly must not stack alerts. Each
        // refusal is still logged by the caller.
        guard !isPresentingRefusal else { return }
        isPresentingRefusal = true
        defer { isPresentingRefusal = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "A link asked OpenDisplay to disconnect a display")
        alert.informativeText = String(localized: "OpenDisplay doesn’t change displays from links, so nothing was changed. To disconnect a display, use its switch in the OpenDisplay menu.")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("OpenDisplay URL: \(message)\n".utf8))
    }
}

/// Reconnects every managed-offline display — the always-available recovery action, now usable from
/// Shortcuts, Siri, and the Shortcuts menu-bar surface.
struct ReconnectAllIntent: AppIntent {
    static let title: LocalizedStringResource = "Reconnect All Displays"
    static let description = IntentDescription(
        "Reconnects every display OpenDisplay turned off — the always-available recovery action."
    )
    // The intent does its own work; no need to bring the app forward.
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // The running app's Reconnect All, which works through the managed-offline ledger. The
        // gateway fallback (no model in this process) can only reach a provider's own offline list.
        let envelope: ResultEnvelope
        if let model = await OpenDisplayAutomation.liveModel {
            envelope = await model.reconnectAll(actor: .appIntent)
        } else {
            envelope = await OpenDisplayAutomation.makeGateway().reconnectAll(actor: .appIntent)
        }
        let restored = envelope.targets.filter { target in
            target.operations.contains { $0.verification == .verified }
        }.count
        let message: LocalizedStringResource
        switch envelope.status {
        case .noOp: message = "No displays needed reconnecting."
        case .committed: message = "Displays reconnected: \(restored)."
        case .partial: message = "Displays reconnected: \(restored). Some displays couldn’t be restored."
        default: message = "Couldn’t confirm that the displays were restored."
        }
        return .result(dialog: IntentDialog(message))
    }
}

/// Sets the built-in display's brightness from Shortcuts / Siri (via the same private DisplayServices
/// path the menu uses). Excluded from the public-API-only build.
struct SetBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Display Brightness"
    static let description = IntentDescription("Sets the built-in display’s brightness (0–100%).")
    static let openAppWhenRun = false

    @Parameter(title: "Brightness", inclusiveRange: (0, 100))
    var percent: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let clamped = max(0, min(100, percent))
        #if !PUBLIC_API_ONLY
        let observer = CoreGraphicsProvider()
        let snapshot = await observer.currentSnapshot()
        guard let builtIn = snapshot.observations.first(where: { $0.displayClass == .builtIn }),
              let cgID = builtIn.cgDisplayID else {
            return .result(dialog: "No built-in display found.")
        }
        let ok = DisplayServicesBrightnessProvider().setBrightness(Float(clamped) / 100, for: cgID)
        if ok { await Self.publishEvent(level: Double(clamped) / 100, display: builtIn) }
        let message: LocalizedStringResource = ok
            ? "Requested built-in display brightness: \(clamped)%. The hardware result isn’t verified."
            : "Couldn’t set the brightness."
        return .result(dialog: IntentDialog(message))
        #else
        return .result(dialog: "Brightness control isn’t available in this build.")
        #endif
    }

    #if !PUBLIC_API_ONLY
    /// Publishes the change on the OSD event channel like every other brightness origin (IN-04):
    /// this intent writes DisplayServices directly, so nothing else would announce it to `listen`
    /// or an external HUD. Honours the broadcast switch — the live model's, or the saved one when
    /// no model runs in this process.
    @MainActor
    private static func publishEvent(level: Double, display: DisplayObservation) {
        let model = OpenDisplayAutomation.liveModel
        let enabled = model?.settings.publishOSDEventsEnabled
            ?? (try? SettingsStore.defaultDirectory()).map { SettingsStore(directory: $0).load().publishOSDEventsEnabled }
            ?? false
        guard enabled else { return }
        OSDBroadcaster.publish(kind: .brightness, value: level, displayID: display.recordID.rawValue,
                               displayName: model?.displayName(for: display),
                               source: OSDBroadcast.Source.appIntent.rawValue)
    }
    #endif
}

struct OpenDisplayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ReconnectAllIntent(),
            phrases: [
                "Reconnect all displays with \(.applicationName)",
                "\(.applicationName) reconnect all displays"
            ],
            shortTitle: "Reconnect All",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: SetBrightnessIntent(),
            phrases: [
                "Set \(.applicationName) brightness",
                "\(.applicationName) set brightness"
            ],
            shortTitle: "Set Brightness",
            systemImageName: "sun.max"
        )
    }
}
#endif
