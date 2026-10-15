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
/// ledger and settings — and wait for it to have loaded that ledger (`AppModel.awaitStartupLoad`).
/// Reconnect All falls back to working from the persisted ledger when no model exists in this
/// process (`reconnectAllFromLedger`); the display actions (DisplayIntents.swift) need the model.
enum OpenDisplayAutomation {
    /// The app's model, registered by `AppDelegate` as it is created. Weak: automation must never
    /// keep a torn-down model alive. App Intents in this target run inside the app process, so an
    /// intent normally finds it here.
    @MainActor static weak var liveModel: AppModel?

    /// Reconnect All with no app model: every display in the persisted managed-offline ledger, each
    /// reconnected and verified the way the app does it, the ledger re-saved after each one, the
    /// run audited. A fresh `CommandGateway` can't stand in for this — its coordinator only sees the
    /// provider snapshot's offline list, which Core Graphics never fills — so it reconnected nothing.
    static func reconnectAllFromLedger(actor: Actor) async -> ResultEnvelope {
        let requestedAt = Date()
        let observer = CoreGraphicsProvider()
        let lifecycle = await makeLifecycleProvider(observer)
        let store = (try? ManagedOfflineStore.defaultDirectory()).map(ManagedOfflineStore.init(directory:))
        let results = await ManagedOfflineRecovery.reconnectAll(
            ledger: store?.load() ?? [],
            attempt: { offline in
                // Per display, the request deadline the CLI's `recover` gives the same verified
                // reconnect (and the gateway this replaces gave the whole batch).
                await ManagedOfflineRecovery.verifiedAttempt(
                    offline, lifecycle: lifecycle, observer: observer, deadline: Date().addingTimeInterval(15),
                    escalate: { CoreGraphicsProvider.restorePermanentConfiguration() })
            },
            save: { ledger in
                do { try store?.save(ledger) } catch { log("could not update the turned-off list: \(error)") }
            })
        let envelope = ResultEnvelope.reconnectAll(
            results: results, actor: actor, requestedAt: requestedAt,
            topologyGeneration: await observer.currentSnapshot().generation.value)
        let audit = (try? DiskAuditLog.defaultDirectory()).map(DiskAuditLog.init(directory:))
        await audit?.append(AuditEntry(
            timestamp: requestedAt, actor: actor, command: "reconnectAll",
            transactionId: envelope.transactionId, status: envelope.status.rawValue,
            targets: envelope.targets.map(\.displayId)))
        return envelope
    }

    /// The lifecycle provider a model-less surface uses: the experimental one where it is
    /// supported, the public Core Graphics one otherwise (and always in the public-API-only build).
    private static func makeLifecycleProvider(_ observer: CoreGraphicsProvider) async -> any LifecycleProvider {
        #if !PUBLIC_API_ONLY
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        let environment = ProviderEnvironment(
            osBuild: ProcessInfo.processInfo.operatingSystemVersionString,
            isAppleSilicon: appleSilicon, transport: .unknown, displayClass: .unknown
        )
        let experimental = ExperimentalLifecycleProvider()
        return await experimental.probe(environment).status == .supported ? experimental : observer
        #else
        return observer
        #endif
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

    func perform() async throws -> some IntentResult & ReturnsValue<ReconnectResultEntity> & ProvidesDialog {
        // The running app's Reconnect All, which works through the managed-offline ledger once
        // launch has loaded it. With no model in this process, the same ledger is read from disk.
        let envelope: ResultEnvelope
        if let model = await OpenDisplayAutomation.liveModel {
            envelope = await model.reconnectAll(actor: .appIntent)
        } else {
            envelope = await OpenDisplayAutomation.reconnectAllFromLedger(actor: .appIntent)
        }
        let restored = envelope.targets.filter { target in
            target.operations.contains { $0.verification == .verified }
        }.count
        let result = ReconnectResultEntity()
        result.reconnectedCount = restored
        let message: LocalizedStringResource
        switch envelope.status {
        case .noOp:
            result.outcome = .nothingToReconnect
            message = "No displays needed reconnecting."
        case .committed:
            result.outcome = .reconnected
            message = "Displays reconnected: \(restored)."
        case .partial:
            result.outcome = .partlyReconnected
            message = "Displays reconnected: \(restored). Some displays couldn’t be restored."
        default:
            result.outcome = .notConfirmed
            message = "Couldn’t confirm that the displays were restored."
        }
        return .result(value: result, dialog: IntentDialog(message))
    }
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
        AppShortcut(
            intent: GetBrightnessIntent(),
            phrases: [
                "Get display brightness with \(.applicationName)",
                "\(.applicationName) get brightness"
            ],
            shortTitle: "Get Brightness",
            systemImageName: "sun.min"
        )
        AppShortcut(
            intent: SetDisplayModeIntent(),
            phrases: [
                "Change a display mode with \(.applicationName)",
                "\(.applicationName) change display mode"
            ],
            shortTitle: "Set Display Mode",
            systemImageName: "rectangle.expand.vertical"
        )
        AppShortcut(
            intent: SetMainDisplayIntent(),
            phrases: [
                "Set the main display with \(.applicationName)",
                "\(.applicationName) set main display"
            ],
            shortTitle: "Set Main Display",
            systemImageName: "menubar.rectangle"
        )
    }
}
#endif
