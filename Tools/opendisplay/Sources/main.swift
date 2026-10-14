import AutomationSchema
import CoreGraphics
import CoreGraphicsProvider
import Dispatch
import DisplayDomain
import ExperimentalLifecycleProvider
import Foundation
import ProviderInterfaces
import SceneEngine
import TopologyCore

// OpenDisplay automation CLI (PRD §12). Mutating commands route through CommandGateway (the same
// audited, safety-checked path the UI and App Intents use). A persisted DisplayRegistry recognizes
// displays across reconnects and stores user aliases/tags, so `alias:`/`tag:` selectors resolve.
// `disconnect --dry-run` previews the SafetyEngine decision without touching hardware.

#if arch(arm64)
let isAppleSilicon = true
#else
let isAppleSilicon = false
#endif

func fail(_ message: String, code: Int32 = CLIExitCode.failure.rawValue) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

/// A non-fatal problem worth a line on stderr, so stdout stays the command's result.
func warn(_ message: String) {
    FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
}

/// Ends the run with the exit status a result implies (`CLIExitCode`): returns for success, so a
/// command can finish normally, and exits non-zero for partial or failed results — whatever was
/// printed, a script must never read a failure as success from the status alone.
func exitIfUnsuccessful(_ status: ResultEnvelope.Status) {
    let code = CLIExitCode(status)
    if code != .success { exit(code.rawValue) }
}

let helpText = """
    opendisplay — OpenDisplay automation CLI

    USAGE:
      opendisplay list [--json]
      opendisplay diagnose [--json]
      opendisplay diagnose --bundle [directory]   # diagnostics zip for a bug report (default: Desktop)
      opendisplay lux [--json]
      opendisplay lid [--json]
      opendisplay listen
      opendisplay alias <selector> <name>
      opendisplay tag <selector> <tag>
      opendisplay disconnect <selector> [--dry-run] [--json]
      opendisplay reconnect <selector> [--json]
      opendisplay recover [--json]                # reconnect every display OpenDisplay turned off
      opendisplay scene <list|save|show|plan|apply|delete> [name] [--json]
      opendisplay layout <protect|unprotect|status> [--json]
      opendisplay group <list|create|delete> [name] [--json]
      opendisplay group <add|remove> <name> <selector>
      opendisplay brightness <selector> [0..1] [--json]
      opendisplay ddc <selector> <brightness|contrast|volume|input|colour|sharpness|red|green|blue|mute|power|caps> [value] [--json]
      opendisplay ddc <selector> reset                # restore the monitor's factory defaults (VCP 0x04)
      opendisplay ddc <selector> vcp <0xNN> [value]   # any raw MCCS feature code
      opendisplay edid <selector> [--out <path.bin>]
      opendisplay favorite <list|set|unset> <selector> [WxH[@Hz][@2x]]
      opendisplay help | --help | -h

    Options are accepted only by the commands listed with them; any other option is an error, so
    for example `--dry-run` never silently performs a real write.

    RESULTS: a write is reported as `verified` only when reading the value back shows it; `sent`
    means the display accepted the write but nothing confirmed it took. Failures go to stderr.

    EXIT STATUS: 0 success (including nothing to do) · 1 failed · 2 usage error (nothing ran) ·
    3 partly done (some displays/fields applied, others failed or were skipped).

    lux/lid exit non-zero when the sensor/state is unavailable. listen streams line-delimited JSON
    (one event per line) until Ctrl-C; see Tools/opendisplay/README.md for the event schema.

    SELECTORS: id:<recordID> · alias:<name> · tag:<tag> · group:<name> · main · builtin · state:<active|managedOffline> · <cgDisplayID>

    group:<name> matches every member of a display group. `brightness group:desk 0.6` sets the
    group's base level and each member follows it at its own learned offset.
    """

// MARK: - Argument parsing

// Parsed before anything touches a provider or a store: help and usage errors must be answered
// without probing hardware or reading (let alone writing) state.
let rawArgs = Array(CommandLine.arguments.dropFirst())
let invocation: CLIInvocation
do {
    switch try CLIGrammar.parse(rawArgs) {
    case .help:
        print(helpText)
        exit(CLIExitCode.success.rawValue)
    case .run(let parsed):
        invocation = parsed
    }
} catch {
    fail("\(error)", code: CLIExitCode.usage.rawValue)
}
let command = invocation.command
guard CLIGrammar.commands.contains(command) else {
    fail("unknown command '\(command)' (try: list, diagnose, lux, lid, listen, alias, tag, disconnect, reconnect, recover, scene, layout, group, brightness, ddc, edid, favorite, help)",
         code: CLIExitCode.usage.rawValue)
}
let flags = invocation.flags
/// The verb followed by its positional arguments — the indexing every command below was written
/// against (`positional[1]` is the first argument after the verb).
let positional = [command] + invocation.positional
let selectorArg: String? = invocation.argument1
let valueArg: String? = invocation.argument2
let asJSON = flags.contains("--json")
let dryRun = flags.contains("--dry-run")

func emit<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
        fail("failed to encode JSON output")
    }
    print(text)
}

/// Encodes one `listen` event compactly (no pretty-printing) so it prints as exactly one line, with
/// sorted keys so two events with the same shape diff cleanly.
func emitLine<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
        fail("failed to encode JSON event")
    }
    print(text)
}

// MARK: - Composition root

let observer = CoreGraphicsProvider()
let environment = ProviderEnvironment(
    osBuild: ProcessInfo.processInfo.operatingSystemVersionString,
    isAppleSilicon: isAppleSilicon, transport: .unknown, displayClass: .unknown
)
let experimental = ExperimentalLifecycleProvider()
let lifecycle: any LifecycleProvider =
    await experimental.probe(environment).status == .supported ? experimental : observer
let checkpoints: any CheckpointStoring =
    (try? DiskCheckpointStore.defaultDirectory()).map(DiskCheckpointStore.init(directory:))
    ?? InMemoryCheckpointStore()
let auditLog = (try? DiskAuditLog.defaultDirectory()).map(DiskAuditLog.init(directory:))
let gateway = CommandGateway(
    observer: observer, lifecycleProvider: lifecycle, checkpoints: checkpoints, auditLog: auditLog
)
let registryStore: any RegistryStoring =
    (try? DiskRegistryStore.defaultDirectory()).map { DiskRegistryStore(directory: $0) }
    ?? InMemoryRegistryStore()
let registry = await DisplayRegistry(store: registryStore)
let sceneStore: any SceneStoring =
    (try? DiskSceneStore.defaultDirectory()).map { DiskSceneStore(directory: $0) }
    ?? InMemorySceneStore()
let sceneLibrary = await SceneLibrary(store: sceneStore)

typealias ResolvedDisplay = (observation: DisplayObservation, record: DisplayRecord)

/// The app's persisted managed-offline list — displays OpenDisplay logically turned off. Read here
/// because a disabled display is GONE from `CGGetOnlineDisplayList`: enumeration can never
/// rediscover it, so without this file the CLI cannot see (or reconnect) the very displays it is
/// most needed for. Empty when the app never turned anything off.
let managedOfflineStore = (try? ManagedOfflineStore.defaultDirectory()).map(ManagedOfflineStore.init(directory:))
let managedOfflineDisplays = managedOfflineStore?.load() ?? []
let managedOfflineIDs = Set(managedOfflineDisplays.map(\.recordID))

/// The app's settings file — read for the Display Groups the `group:` selector and `group` verbs
/// work on. Group mutations re-read it immediately before writing, since the app owns the same file.
let settingsStore = (try? SettingsStore.defaultDirectory()).map(SettingsStore.init(directory:))
let displayGroups = settingsStore?.load().displayGroups ?? []

/// Resolves every live display's fingerprint into the registry (recognizing or minting), so the
/// registry learns the current displays and we can map observations <-> records for this run.
///
/// Managed-offline displays are appended as synthetic inactive observations: they have no live
/// hardware to fingerprint, so their registry record is looked up by id (it was minted when the
/// display was last online). This is what makes `reconnect`, `list`, and `state:managedOffline`
/// work on a display that the OS no longer reports at all.
func resolveCurrentDisplays() async -> [ResolvedDisplay] {
    let snapshot = await observer.currentSnapshot()
    let observations = snapshot.observations.filter { $0.cgDisplayID != nil }
    let inputs = observations.compactMap {
        obs -> (fingerprint: DisplayFingerprint, cgUUID: String?, displayClass: DisplayClass)? in
        guard let cgID = obs.cgDisplayID else { return nil }
        return (observer.fingerprint(for: cgID), obs.cgUUID, obs.displayClass)
    }
    // One batched resolve → exactly one registry write for the whole display set this run.
    let records = await registry.resolveAll(inputs)
    var pairs = Array(zip(observations, records))

    let online = Set(observations.map(\.recordID))
    for offline in managedOfflineDisplays where !online.contains(offline.recordID) {
        pairs.append((
            DisplayObservation(
                recordID: offline.recordID, cgDisplayID: offline.cgID, isActive: false,
                displayClass: offline.displayClass, generation: snapshot.generation),
            await offlineRecord(for: offline)))
    }
    return pairs
}

/// The registry record behind a display that isn't being observed right now. An observation id is
/// `cg:<uuid>` while the registry mints its own ids and indexes them by that UUID, so a display the
/// OS no longer reports at all — turned off, or merely unplugged — is only reachable through the
/// UUID index.
func registryRecord(for recordID: DisplayRecordID) async -> DisplayRecord? {
    guard let cgUUID = recordID.cgUUID else { return await registry.record(for: recordID) }
    return await registry.record(forCGUUID: cgUUID)
}

/// The registry record for a turned-off display, so it keeps its alias and tags while offline.
/// A lookup miss must NOT hide the display: falling back to a synthetic record keeps it listed and
/// reconnectable, which is the whole point of remembering it.
func offlineRecord(for offline: ManagedOfflineDisplay) async -> DisplayRecord {
    guard var record = await registryRecord(for: offline.recordID) else {
        return DisplayRecord(
            id: offline.recordID, fingerprint: DisplayFingerprint(modelName: offline.name),
            displayClass: offline.displayClass)
    }
    // Registry fingerprints carry a model name only when the EDID supplied one; the app stored the
    // OS-provided name when it turned the display off, which is what the user saw and recognizes.
    if record.alias == nil, record.fingerprint.modelName == nil {
        record.fingerprint.modelName = offline.name
    }
    return record
}

// MARK: - Selector resolution

/// The group a `group:<name>` selector names, or nil when the selector isn't one. An unknown group
/// name is fatal rather than an empty match — silently matching nothing would read as "no displays
/// are in that group" when the truth is that the group doesn't exist.
func groupSelector(_ raw: String, in groups: [DisplayGroup] = displayGroups) -> DisplayGroup? {
    let prefix = "group:"
    guard raw.hasPrefix(prefix) else { return nil }
    let wanted = String(raw.dropFirst(prefix.count))
    guard let group = DisplayGroupStore.group(named: wanted, in: groups) else {
        fail("no display group named '\(wanted)' (list them with: opendisplay group list)")
    }
    return group
}

func reachability(of observation: DisplayObservation, managedOffline: Set<DisplayRecordID>) -> Reachability {
    if managedOffline.contains(observation.recordID) { return .managedOffline }
    return observation.isActive ? .active : .discoveredInactive
}

func resolveObservation(_ raw: String, in pairs: [ResolvedDisplay],
                        managedOffline: Set<DisplayRecordID>) -> [DisplayObservation] {
    if let cgID = UInt32(raw) {
        return pairs.filter { $0.observation.cgDisplayID == cgID }.map(\.observation)
    }
    // `group:<name>` is resolved here rather than in `DisplaySelector`: groups are an app setting,
    // not part of the shared automation schema, and this keeps the schema free of a concept only
    // this surface can look up.
    if let group = groupSelector(raw) {
        return pairs.filter { group.contains($0.observation.recordID) || group.contains($0.record.id) }
            .map(\.observation)
    }
    let selector: DisplaySelector
    do { selector = try DisplaySelector.parse(raw) } catch { fail("could not parse selector '\(raw)': \(error)") }
    switch selector {
    case .id(let recordID):
        return pairs.filter { $0.observation.recordID == recordID || $0.record.id == recordID }.map(\.observation)
    case .alias(let alias):
        return pairs.filter { $0.record.alias == alias }.map(\.observation)
    case .tag(let tag):
        return pairs.filter { $0.record.tags.contains(tag) }.map(\.observation)
    case .role(.main):
        return pairs.filter { $0.observation.isMain }.map(\.observation)
    case .role(.builtin):
        return pairs.filter { $0.observation.displayClass == .builtIn }.map(\.observation)
    case .state(let reach):
        return pairs.filter { reachability(of: $0.observation, managedOffline: managedOffline) == reach }.map(\.observation)
    case .role, .name, .fingerprint, .topology:
        fail("selector '\(raw)' isn't resolvable yet (use id:/alias:/tag:/main/builtin/state:/<cgID>)")
    }
}

func uniqueDisplay(_ raw: String, in pairs: [ResolvedDisplay],
                   managedOffline: Set<DisplayRecordID>) -> ResolvedDisplay {
    let matches = resolveObservation(raw, in: pairs, managedOffline: managedOffline)
    guard !matches.isEmpty else { fail("no display matches '\(raw)'") }
    guard matches.count == 1 else {
        fail("'\(raw)' is ambiguous (\(matches.count) displays): \(matches.map(\.recordID.rawValue).joined(separator: ", "))")
    }
    let observation = matches[0]
    return pairs.first { $0.observation.recordID == observation.recordID }!
}

// MARK: - Output

/// A human-readable name: the user's alias, else the EDID model name, else a class + resolution
/// label — never the raw record id, which identifies nothing to a human, and these names are what
/// selectors and recovery hints are built from. One ladder shared with the app, so a display reads
/// the same in both surfaces (`DisplayRecord.friendlyName`).
func name(for pair: ResolvedDisplay) -> String {
    pair.record.friendlyName(mode: pair.observation.mode)
}

/// The name for a group member, which may be a display that isn't here right now: the live name
/// when it is connected, else the registry's remembered record — the bridge that keeps an unplugged
/// member from printing as `cg:37D8832A-2D66-…`. The raw id survives only for a display the
/// registry has never seen at all.
func memberLabel(_ member: DisplayRecordID, in pairs: [ResolvedDisplay]) async -> String {
    if let pair = pairs.first(where: { $0.observation.recordID == member }) { return name(for: pair) }
    return await registryRecord(for: member)?.friendlyName() ?? member.rawValue
}

/// The shortest selector that will reach this display again — its alias when it has one (stable
/// and memorable), otherwise the raw CG display id.
func recoverySelector(for pair: ResolvedDisplay) -> String {
    if let alias = pair.record.alias, !alias.isEmpty { return "alias:\(alias)" }
    return pair.observation.cgDisplayID.map(String.init) ?? "id:\(pair.observation.recordID.rawValue)"
}

func modeString(_ observation: DisplayObservation) -> String? {
    observation.mode.map { "\($0.pixelWidth)x\($0.pixelHeight)@\(Int($0.refreshHz.rounded()))" }
}

/// Prints an envelope (JSON, or one line per target) and then exits with the status it implies.
func emitEnvelope(_ envelope: ResultEnvelope) {
    defer { exitIfUnsuccessful(envelope.status) }
    if asJSON { emit(envelope); return }
    print("\(envelope.status.rawValue) [\(envelope.transactionId)]")
    for target in envelope.targets {
        // The outcome, when a surface records one, is the honest word (sent vs verified vs failed);
        // older producers only fill `verification`.
        let ops = target.operations.map { "\($0.field)=\($0.outcome?.rawValue ?? $0.verification.rawValue)" }
            .joined(separator: ", ")
        print("  \(target.displayId): \(ops)")
    }
    for error in envelope.errors {
        FileHandle.standardError.write(Data("  ! \(error.code): \(error.message)\n".utf8))
    }
}

// MARK: - Commands

func runList() async {
    let pairs = await resolveCurrentDisplays().sorted { $0.observation.recordID.rawValue < $1.observation.recordID.rawValue }
    if asJSON {
        struct Row: Encodable {
            var id: String; var recordId: String; var alias: String?; var tags: [String]
            var cgDisplayID: UInt32?; var active: Bool; var main: Bool
            var managedOffline: Bool
            var displayClass: String; var mode: String?; var origin: String
        }
        emit(pairs.map {
            Row(id: $0.observation.recordID.rawValue, recordId: $0.record.id.rawValue, alias: $0.record.alias,
                tags: $0.record.tags.sorted(), cgDisplayID: $0.observation.cgDisplayID,
                active: $0.observation.isActive, main: $0.observation.isMain,
                managedOffline: managedOfflineIDs.contains($0.observation.recordID),
                displayClass: $0.observation.displayClass.rawValue, mode: modeString($0.observation),
                origin: "(\($0.observation.origin.x),\($0.observation.origin.y))")
        })
        return
    }
    for pair in pairs {
        let isOffline = managedOfflineIDs.contains(pair.observation.recordID)
        let mark = pair.observation.isActive ? "●" : "○"
        let main = pair.observation.isMain ? " [main]" : ""
        let tags = pair.record.tags.isEmpty ? "" : " #\(pair.record.tags.sorted().joined(separator: " #"))"
        // Name the recovery command inline: a turned-off display is invisible to the OS, so
        // "how do I get it back" should never require reading the docs.
        let state = isOffline ? "  turned off — `opendisplay reconnect \(recoverySelector(for: pair))`" : ""
        print("\(mark) \(name(for: pair))\(main) \(modeString(pair.observation) ?? "—")\(tags)\(state)")
    }
}

/// One line in the shared display event timeline, from the CLI's side of an action.
func logDisplayEvent(_ reason: String) async {
    guard let directory = try? DiskDisplayEventLog.defaultDirectory() else { return }
    await DiskDisplayEventLog(directory: directory).append(DisplayEventLog.Entry(
        at: Date(), reason: "cli " + reason, owed: managedOfflineDisplays.map(\.name),
        displays: DisplayTruth.rows()))
}

/// `diagnose --bundle [directory]`: the same diagnostics zip the app's Export Diagnostics button
/// builds, for when the app's window is on the display that went missing.
func runDiagnoseBundle() async {
    await logDisplayEvent("export")
    let directory = selectorArg.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    // The CLI has no Info.plist of its own. When it runs from inside the app bundle
    // (Contents/Helpers/opendisplay, also what the Homebrew symlink points at), report the app's
    // version — the first thing anyone reading a bundle needs to know.
    let appPlist = Bundle.main.executableURL?.resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
    let info = appPlist.flatMap { NSDictionary(contentsOf: $0) as? [String: Any] }
    let app = DiagnosticsBundle.AppInfo(
        version: info?["CFBundleShortVersionString"] as? String ?? "unknown",
        build: info?["CFBundleVersion"] as? String ?? "unknown", flavor: "cli")
    print("Collecting diagnostics (this takes a few seconds)…")
    do {
        let zip = try DiagnosticsBundle.export(to: directory, app: app)
        print("Saved \(zip.path)")
        print("Nothing was sent anywhere. It contains:")
        for item in DiagnosticsBundle.contents { print("  - \(item)") }
    } catch {
        fail("could not write the diagnostics bundle: \(error)")
    }
}

func runDiagnose() async {
    if flags.contains("--bundle") { return await runDiagnoseBundle() }
    let probes = [
        ("coregraphics", false, await observer.probe(environment)),
        ("experimentalLifecycle", true, await experimental.probe(environment))
    ]
    if asJSON {
        struct Probe: Encodable { var provider: String; var experimental: Bool; var status: String; var risk: String; var reasons: [String] }
        emit(probes.map { id, experimental, probe in
            Probe(provider: id, experimental: experimental, status: probe.status.rawValue,
                  risk: probe.risk.rawValue, reasons: probe.reasons.map(\.rawValue))
        })
        return
    }
    for (id, experimental, probe) in probes {
        let labsTag = experimental ? " [labs]" : ""
        let reasons = probe.reasons.map(\.rawValue)
        let suffix = reasons.isEmpty ? "" : " (\(reasons.joined(separator: ",")))"
        print("\(id)\(labsTag): \(probe.status.rawValue) · risk=\(probe.risk.rawValue)\(suffix)")
    }
}

/// Prints the current ambient-light reading in lux — the direct ALS path Adaptive Display's ambient
/// mode falls back to (`Providers/ExperimentalLifecycleProvider/Sources/AmbientLight.swift`). Exits
/// non-zero when the sensor can't be read (no sensor, lid closed, or the IOKit SPI moved).
func runLux() async {
    guard let lux = AmbientLightReader().lux() else {
        fail("ambient light sensor unavailable (no sensor, lid closed, or SPI unreachable)")
    }
    if asJSON { emit(["lux": lux]) } else { print(String(format: "%.1f lux", lux)) }
}

/// Reports the lid's open/closed state via `LidStatePolicy`, reusing the same signals Adaptive
/// Display already senses. Exits non-zero only when this Mac has no built-in panel to reason about
/// at all (a desktop Mac) — see `LidStatePolicy` for why `closed` is otherwise inferred, not sensed.
func runLid() async {
    let snapshot = await observer.currentSnapshot()
    let builtInObservations = snapshot.observations.filter { $0.displayClass == .builtIn }
    let builtInIsActive = builtInObservations.contains { $0.isActive }
    let ambientLux = AmbientLightReader().lux()
    guard let state = LidStatePolicy.evaluate(
        builtInIsActive: builtInIsActive, hasBuiltInPanel: !builtInObservations.isEmpty,
        ambientLux: ambientLux
    ) else {
        fail("lid state unavailable — no built-in display observed on this Mac")
    }
    if asJSON { emit(["state": state.rawValue]) } else { print(state.rawValue) }
}

func runAlias() async {
    guard let selectorArg, let valueArg else { fail("usage: opendisplay alias <selector> <name>") }
    let pairs = await resolveCurrentDisplays()
    let target = uniqueDisplay(selectorArg, in: pairs, managedOffline: managedOfflineIDs)
    await registry.setAlias(valueArg, for: target.record.id)
    print("aliased \(target.observation.recordID.rawValue) → \"\(valueArg)\"")
}

func runTag() async {
    guard let selectorArg, let valueArg else { fail("usage: opendisplay tag <selector> <tag>") }
    let pairs = await resolveCurrentDisplays()
    let target = uniqueDisplay(selectorArg, in: pairs, managedOffline: managedOfflineIDs)
    await registry.addTag(valueArg, to: target.record.id)
    print("tagged \(name(for: target)) #\(valueArg)")
}

/// Reconnects every display in the shared managed-offline ledger, each the same verified way
/// `reconnect` does it.
///
/// This used to ask `CommandGateway.reconnectAll`, whose coordinator only sees the provider
/// snapshot's offline list — which `CoreGraphicsProvider` never fills — so `recover` printed
/// "nothing to reconnect" while the ledger still held every display the app or CLI had turned off.
/// The ledger is re-saved after each display, so an interrupted run never loses a record.
func runRecover() async {
    let requestedAt = Date()
    var ledger = managedOfflineDisplays
    var results: [(displayId: String, reconnected: Bool)] = []
    for offline in managedOfflineDisplays {
        let attempt = await attemptVerifiedReconnect(offline, reconnectID: offline.reconnectID)
        switch attempt {
        case .lit:
            ledger.removeAll { $0.recordID == offline.recordID }
            await logDisplayEvent("reconnect:lit \(offline.name)")
        case .notLit:
            ledger = ledger.map { $0.recordID == offline.recordID ? stampedReconnectFailure(offline) : $0 }
            await logDisplayEvent("reconnect:notLit \(offline.name)")
        case .rejected(let reason):
            warn("\(offline.name): macOS rejected the reconnect: \(reason)")
            await logDisplayEvent("reconnect:rejected \(offline.name)")
        }
        do { try managedOfflineStore?.save(ledger) } catch {
            warn("could not update the turned-off list: \(error)")
        }
        results.append((offline.recordID.rawValue, attempt == .lit))
    }
    let envelope = ResultEnvelope.reconnectAll(
        results: results, actor: .cli, requestedAt: requestedAt,
        topologyGeneration: await observer.currentSnapshot().generation.value)
    await auditLog?.append(AuditEntry(
        timestamp: requestedAt, actor: .cli, command: "reconnectAll",
        transactionId: envelope.transactionId, status: envelope.status.rawValue,
        targets: envelope.targets.map(\.displayId)))
    if !asJSON && envelope.targets.isEmpty {
        print("recover: nothing to reconnect")
        return
    }
    emitEnvelope(envelope)
}

/// How one verified reconnect ended.
enum ReconnectAttempt: Equatable {
    /// The display was observed lit again.
    case lit
    /// macOS accepted the request but the display never came back.
    case notLit
    /// macOS refused the request.
    case rejected(String)
}

/// One reconnect, checked: accepted is not back (issue #40), so only a display observed lit counts.
/// The caller owns the ledger — it forgets the entry on `.lit` and keeps it otherwise, since the
/// entry is the only thing that still knows a dark display exists.
func attemptVerifiedReconnect(_ offline: ManagedOfflineDisplay,
                              reconnectID: DisplayRecordID) async -> ReconnectAttempt {
    do {
        try await lifecycle.reconnect(reconnectID, deadline: Date().addingTimeInterval(15))
    } catch {
        return .rejected("\(error)")
    }
    return await verifyReconnect(of: offline) ? .lit : .notLit
}

/// The ledger entry for a display that didn't come back, stamped so the app's off card can say so.
func stampedReconnectFailure(_ offline: ManagedOfflineDisplay) -> ManagedOfflineDisplay {
    ManagedOfflineDisplay(
        recordID: offline.recordID, cgID: offline.cgID, name: offline.name,
        displayClass: offline.displayClass, relitDuringWakeAt: offline.relitDuringWakeAt,
        reconnectFailedAt: Date())
}

func runDisconnect() async {
    guard let selectorArg else { fail("usage: opendisplay disconnect <selector> [--dry-run] [--json]") }
    let pairs = await resolveCurrentDisplays()
    let target = uniqueDisplay(selectorArg, in: pairs, managedOffline: managedOfflineIDs)

    if dryRun {
        let outcome = await gateway.preflightDisconnect(target.observation.recordID, identityConfidence: 1.0)
        let surface = outcome.safeSurface?.rawValue ?? "none"
        if asJSON {
            // A preview, not a result envelope: nothing was attempted, so there is no transaction.
            struct DryRun: Encodable {
                var dryRun = true; var displayId: String; var decision: String
                var safeSurface: String?; var reasons: [String]
            }
            emit(DryRun(displayId: target.observation.recordID.rawValue, decision: outcome.decision.rawValue,
                        safeSurface: outcome.safeSurface?.rawValue, reasons: outcome.reasons))
            return
        }
        switch outcome.decision {
        case .allowed:
            print("dry-run: ALLOWED — would disconnect \(name(for: target)); safe surface = \(surface)")
        case .needsConfirmation:
            print("dry-run: NEEDS CONFIRMATION (\(outcome.reasons.joined(separator: ","))) — safe surface = \(surface)")
        case .blocked:
            print("dry-run: BLOCKED (\(outcome.reasons.joined(separator: ",")))")
        }
        return
    }

    // Same pre-disconnect copy of macOS's saved display configuration the app takes (issue #40).
    if let root = try? WindowServerConfigBackup.defaultDirectory() {
        WindowServerConfigBackup.snapshot(
            sources: WindowServerConfigBackup.defaultSources(), into: root, label: name(for: target),
            now: Date())
    }
    let envelope = await gateway.disconnect(
        target.observation.recordID, options: DisconnectOptions(actor: .cli, identityConfidence: 1.0)
    )
    // Remember what we turned off, exactly as the app does. Without this the display is
    // unreachable the moment it leaves the online list — including by `reconnect` in this same
    // CLI a second later — because nothing anywhere records that it exists.
    if envelope.status == .committed {
        rememberManagedOffline(ManagedOfflineDisplay(
            recordID: target.observation.recordID,
            cgID: target.observation.cgDisplayID ?? 0,
            name: name(for: target),
            displayClass: target.observation.displayClass))
    }
    await logDisplayEvent("disconnect:\(envelope.status == .committed ? "committed" : "failed") \(name(for: target))")
    emitEnvelope(envelope)
}

func runReconnect() async {
    guard let selectorArg else { fail("usage: opendisplay reconnect <selector> [--json]") }
    let pairs = await resolveCurrentDisplays()
    let target = uniqueDisplay(selectorArg, in: pairs, managedOffline: managedOfflineIDs)
    let recordID = target.observation.recordID
    // A disabled display is off the online list, so its CG UUID can't be resolved — reconnect by
    // raw display id, the same way the app does.
    let reconnectID = managedOfflineDisplays.first { $0.recordID == recordID }?.reconnectID
        ?? target.observation.cgDisplayID.map { DisplayRecordID(rawValue: "cgid:\($0)") }
        ?? recordID
    let offline = managedOfflineDisplays.first { $0.recordID == recordID }
        ?? ManagedOfflineDisplay(recordID: recordID, cgID: target.observation.cgDisplayID ?? 0,
                                 name: name(for: target), displayClass: target.observation.displayClass)
    // Accepted is not back (issue #40): only forget the display once it is observed lit. If it
    // never appears, the record stays — it is the only thing that still knows the display exists.
    switch await attemptVerifiedReconnect(offline, reconnectID: reconnectID) {
    case .rejected(let reason):
        fail("reconnect failed: \(reason)")
    case .notLit:
        await logDisplayEvent("reconnect:notLit \(offline.name)")
        rememberManagedOffline(stampedReconnectFailure(offline))
        fail("macOS accepted the reconnect but \(offline.name) did not come back. It is still "
            + "recorded as turned off. If it is plugged in and powered, see "
            + ReconnectVerification.recoveryGuideURL.absoluteString)
    case .lit:
        break
    }
    forgetManagedOffline(recordID)
    await logDisplayEvent("reconnect:lit \(offline.name)")
    if asJSON { emit(["status": "committed", "target": recordID.rawValue]) }
    else { print("reconnected \(name(for: target))") }
}

/// The app's reconnect check, for the CLI: watch the topology, escalate once to the public
/// permanent-configuration restore, and report whether the display was ever seen lit.
func verifyReconnect(of offline: ManagedOfflineDisplay) async -> Bool {
    var phaseStart = Date()
    var escalated = false
    while true {
        let observations = await observer.currentSnapshot().observations
        switch ReconnectVerification.next(
            isLit: ReconnectVerification.isLit(offline, in: observations),
            waited: Date().timeIntervalSince(phaseStart), escalated: escalated) {
        case .confirmed: return true
        case .failed: return false
        case .lookAgain(let delay):
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        case .escalate:
            escalated = true
            phaseStart = Date()
            CoreGraphicsProvider.restorePermanentConfiguration()
        }
    }
}

/// Adds (replacing any prior entry for the same display) to the shared managed-offline list.
func rememberManagedOffline(_ display: ManagedOfflineDisplay) {
    var remaining = managedOfflineDisplays.filter { $0.recordID != display.recordID }
    remaining.append(display)
    try? managedOfflineStore?.save(remaining)
}

/// Drops a display from the shared managed-offline list once it is back online.
func forgetManagedOffline(_ recordID: DisplayRecordID) {
    let remaining = managedOfflineDisplays.filter { $0.recordID != recordID }
    if remaining.count != managedOfflineDisplays.count { try? managedOfflineStore?.save(remaining) }
}

// MARK: - Scenes

/// Resolves a scene member selector to a single record id, or nil if absent/ambiguous (unlike the
/// command selectors, a scene with an unresolved member is "missing", not an error).
func resolveMember(_ selector: String, in pairs: [ResolvedDisplay]) -> DisplayRecordID? {
    if let cgID = UInt32(selector) {
        let matches = pairs.filter { $0.observation.cgDisplayID == cgID }
        return matches.count == 1 ? matches[0].observation.recordID : nil
    }
    guard let parsed = try? DisplaySelector.parse(selector) else { return nil }
    let matches: [DisplayRecordID]
    switch parsed {
    case .id(let recordID):
        matches = pairs.filter { $0.observation.recordID == recordID || $0.record.id == recordID }.map(\.observation.recordID)
    case .alias(let alias):
        matches = pairs.filter { $0.record.alias == alias }.map(\.observation.recordID)
    case .tag(let tag):
        matches = pairs.filter { $0.record.tags.contains(tag) }.map(\.observation.recordID)
    case .role(.main):
        matches = pairs.filter { $0.observation.isMain }.map(\.observation.recordID)
    case .role(.builtin):
        matches = pairs.filter { $0.observation.displayClass == .builtIn }.map(\.observation.recordID)
    default:
        matches = []
    }
    return matches.count == 1 ? matches[0] : nil
}

func runScene() async {
    let sub = positional.count > 1 ? positional[1] : "list"
    let nameArg: String? = positional.count > 2 ? positional[2] : nil

    switch sub {
    case "list":
        let scenes = await sceneLibrary.all()
        if asJSON { emit(scenes) }
        else if scenes.isEmpty { print("no saved scenes (capture one with: scene save <name>)") }
        else { for scene in scenes { print("\(scene.name)  (\(scene.members.count) displays)") } }

    case "save":
        guard let nameArg else { fail("usage: opendisplay scene save <name>") }
        let snapshot = await observer.currentSnapshot()
        let id = await sceneLibrary.scene(named: nameArg)?.id ?? "scene_\(UUID().uuidString.prefix(8))"
        let scene = SceneRecorder.capture(from: snapshot, name: nameArg, id: String(id))
        await sceneLibrary.save(scene)
        print("saved scene \"\(nameArg)\" (\(scene.members.count) displays)")

    case "show":
        guard let nameArg, let scene = await sceneLibrary.scene(named: nameArg) else {
            fail("no scene named '\(nameArg ?? "")'")
        }
        if asJSON { emit(scene); return }
        print("Scene \"\(scene.name)\":")
        for member in scene.members {
            var parts: [String] = []
            if let connected = member.desired.connected { parts.append(connected ? "connected" : "offline") }
            if member.desired.main == true { parts.append("main") }
            if let p = member.desired.position { parts.append("pos=(\(p.x),\(p.y))") }
            if let m = member.desired.mode { parts.append("\(m.pixelWidth)x\(m.pixelHeight)") }
            print("  \(member.selector): \(parts.joined(separator: ", "))")
        }

    case "plan":
        guard let nameArg, let scene = await sceneLibrary.scene(named: nameArg) else {
            fail("no scene named '\(nameArg ?? "")'")
        }
        let pairs = await resolveCurrentDisplays()
        let snapshot = await observer.currentSnapshot()
        var resolution: ScenePlanner.Resolution = [:]
        for member in scene.members {
            if let recordID = resolveMember(member.selector, in: pairs) { resolution[member.selector] = recordID }
        }
        let plan = ScenePlanner().plan(scene: scene, snapshot: snapshot, resolution: resolution)
        if asJSON { emit(plan); return }
        if plan.isBlocked { print("scene \"\(scene.name)\": BLOCKED — missing required: \(plan.missingRequired.joined(separator: ", "))") }
        else if !plan.hasWork { print("scene \"\(scene.name)\": already satisfied (no changes)") }
        for op in plan.operations where op.status == .willApply {
            print("  → \(op.kind.rawValue) \(op.target.rawValue): \(op.detail)")
        }
        let satisfied = plan.operations.filter { $0.status == .alreadySatisfied }.count
        if satisfied > 0 { print("  (\(satisfied) already satisfied)") }
        for selector in plan.missingOptional { print("  · skipped (absent): \(selector)") }

    case "apply":
        guard let nameArg, let scene = await sceneLibrary.scene(named: nameArg) else {
            fail("no scene named '\(nameArg ?? "")'")
        }
        await runSceneApply(scene)

    case "delete":
        guard let nameArg, let scene = await sceneLibrary.scene(named: nameArg) else {
            fail("no scene named '\(nameArg ?? "")'")
        }
        await sceneLibrary.delete(id: scene.id)
        print("deleted scene \"\(nameArg)\"")

    default:
        fail("unknown scene subcommand '\(sub)' (try: list, save, show, plan, apply, delete)", code: 2)
    }
}

/// `scene apply`: writes the scene's positions and modes in one arrangement transaction, then judges
/// every field against the topology read afterwards (TB-04) — what took, what was already so, what
/// macOS didn't apply, and which fields scene apply doesn't execute at all. It used to print
/// "applied" and exit 0 whatever the provider reported, and ignored a missing required member.
func runSceneApply(_ scene: Scene) async {
    let pairs = await resolveCurrentDisplays()
    let before = await observer.currentSnapshot()
    var resolution: ScenePlanner.Resolution = [:]
    for member in scene.members {
        if let recordID = resolveMember(member.selector, in: pairs) { resolution[member.selector] = recordID }
    }
    let preparation = SceneApplication.prepare(scene: scene, resolution: resolution, before: before)
    var warnings: [String] = []
    if !preparation.isBlocked {
        let targets = preparation.writes.compactMap { write -> CoreGraphicsProvider.ArrangementTarget? in
            guard let cgID = before.observation(for: write.target)?.cgDisplayID else { return nil }
            return .init(displayID: cgID, origin: write.origin, mode: write.mode)
        }
        if !targets.isEmpty { warnings = observer.applyArrangement(targets) }
    }
    let after = await observer.currentSnapshot()
    let report = SceneApplication.report(scene: scene, preparation: preparation, resolution: resolution,
                                         before: before, after: after, providerWarnings: warnings)
    let envelope = sceneEnvelope(report, generation: after.generation.value)
    if asJSON {
        emit(envelope)
    } else {
        printSceneReport(report)
    }
    exitIfUnsuccessful(envelope.status)
}

/// Why scene apply leaves a field alone — it is in the scene schema, but no executor writes it.
func sceneSkipReason(_ field: SceneApplyReport.Field) -> String {
    switch field {
    case .connected: return "scene apply doesn't connect or disconnect displays"
    case .main: return "the main display is set only through positions"
    case .rotation: return "scene apply doesn't rotate displays"
    case .brightness: return "scene apply doesn't set brightness"
    case .colorProfile: return "scene apply doesn't set colour profiles"
    case .hdr: return "scene apply doesn't switch HDR"
    case .relativePosition: return "scene apply doesn't resolve relative placement"
    case .position, .mode: return "not applied"
    }
}

func printSceneReport(_ report: SceneApplyReport) {
    switch report.status {
    case .blocked:
        FileHandle.standardError.write(Data(
            "scene \"\(report.sceneName)\": BLOCKED — missing required: \(report.missingRequired.joined(separator: ", ")). Nothing was changed.\n".utf8))
        return
    case .failed where report.entries.isEmpty:
        FileHandle.standardError.write(Data("scene \"\(report.sceneName)\" resolved to no present displays\n".utf8))
        return
    default:
        break
    }
    let counts = Dictionary(grouping: report.entries, by: \.outcome).mapValues(\.count)
    let summary = [("applied", SceneApplyReport.Outcome.applied), ("already set", .alreadySatisfied),
                   ("not applied", .notApplied), ("skipped", .skipped)]
        .compactMap { label, outcome in counts[outcome].map { "\($0) \(label)" } }
        .joined(separator: ", ")
    print("scene \"\(report.sceneName)\": \(report.status.rawValue) (\(summary))")
    for entry in report.entries {
        let what = "\(entry.selector) \(entry.field.rawValue) \(entry.requested)"
        let now = entry.observed.map { " (now \($0))" } ?? ""
        switch entry.outcome {
        case .applied: print("  ✓ \(what)")
        case .alreadySatisfied: continue  // counted in the summary; listing them buries the news
        case .notApplied: print("  ! \(what): not applied\(now)")
        case .skipped: print("  · \(what): skipped — \(sceneSkipReason(entry.field))\(now)")
        }
    }
    for selector in report.missingOptional { print("  · skipped (absent): \(selector)") }
    for warning in report.providerWarnings { warn("macOS: \(warning)") }
}

/// The scene report as the shared result envelope: one target per display, one operation per field.
func sceneEnvelope(_ report: SceneApplyReport, generation: UInt64) -> ResultEnvelope {
    let status: ResultEnvelope.Status
    switch report.status {
    case .applied: status = .committed
    case .noChange: status = .noOp
    case .partial: status = .partial
    case .failed, .blocked: status = .failed
    }
    var order: [DisplayRecordID] = []
    var operations: [DisplayRecordID: [ResultEnvelope.OperationResult]] = [:]
    for entry in report.entries {
        if operations[entry.target] == nil { order.append(entry.target) }
        let outcome: OperationOutcome
        switch entry.outcome {
        case .applied: outcome = .verified
        case .alreadySatisfied: outcome = .alreadySatisfied
        case .notApplied: outcome = .failed
        case .skipped: outcome = .skipped
        }
        operations[entry.target, default: []].append(.init(
            field: "scene.\(entry.field.rawValue)", requested: .string(entry.requested),
            observed: entry.observed.map(AnyCodableValue.string),
            verification: entry.outcome == .applied ? .verified : .notApplicable,
            warnings: entry.outcome == .skipped ? [sceneSkipReason(entry.field)] : [],
            outcome: outcome))
    }
    var errors = report.missingRequired.map {
        ResultEnvelope.ErrorInfo(code: "missingRequired", message: "required member \($0) is not present")
    }
    errors += report.missingOptional.map {
        ResultEnvelope.ErrorInfo(code: "memberAbsent", message: "\($0) is not present; skipped")
    }
    errors += report.providerWarnings.map { ResultEnvelope.ErrorInfo(code: "providerWarning", message: $0) }
    return ResultEnvelope(
        transactionId: "txn_sceneApply", status: status, actor: .cli, requestedAt: Date(),
        topologyGeneration: generation,
        targets: order.map { .init(displayId: $0.rawValue, alias: nil, identityConfidence: 1.0,
                                   operations: operations[$0] ?? []) },
        errors: errors)
}

// MARK: - Control commands

func percentLabel(_ level: Float) -> String { "\(Int((level * 100).rounded()))%" }

/// Binds a display's DDC channel under the app's rules: Apple displays only with the user's
/// per-display override from Settings (FB-08), and never a service identity can't single out (TR-06).
func bindDDC(_ target: ResolvedDisplay) -> ExternalDisplayDDC.Binding {
    guard let cgID = target.observation.cgDisplayID else { return .unavailable }
    let overrides = settingsStore?.load().ddcAppleDisplayOverrideIDs ?? []
    return ExternalDisplayDDC.bind(displayID: cgID,
                                   allowAppleDisplay: overrides.contains(target.observation.recordID.rawValue))
}

func ddcRefusalText(_ reason: DDCBindingRefusal) -> String {
    switch reason {
    case .ambiguousIdentity:
        return "DDC refused: another connected monitor reports the same identity, so a command could reach the wrong one"
    case .unidentified:
        return "DDC refused: can't tell which DDC service belongs to this display"
    case .appleDisplay:
        return "DDC refused: withheld from Apple displays (allow it per display in Settings → Displays)"
    }
}

/// One display's brightness write, as it really went.
struct BrightnessWrite {
    var target: ResolvedDisplay
    var requested: Float
    var outcome: OperationOutcome
    /// The level read back after the write, when a read answered.
    var observed: Float?
    var provider: String?
    /// Why it failed, or what an unconfirming read-back said.
    var note: String?

    var operation: ResultEnvelope.OperationResult {
        .init(field: "brightness", requested: .double(Double(requested)),
              observed: observed.map { .double(Double($0)) },
              verification: outcome == .verified ? .verified
                  : outcome == .sent ? .readBackUnavailable : .notApplicable,
              provider: provider, warnings: note.map { [$0] } ?? [], outcome: outcome)
    }

    var line: String {
        let label = name(for: target)
        let via = provider == "ddc" ? " (DDC)" : ""
        switch outcome {
        case .verified: return "\(label): brightness \(percentLabel(requested))\(via) — verified"
        case .sent: return "\(label): brightness \(percentLabel(requested)) sent\(via) — not verified: \(note ?? "no read-back")"
        case .unsupported: return "\(label): \(note ?? "no brightness control for this display")"
        default: return "\(label): brightness \(percentLabel(requested)) failed — \(note ?? "write failed")"
        }
    }
}

/// Writes one display's brightness through whichever route it has, then reads it back. Only a
/// read-back of exactly the written value counts as `verified` — no tolerance is assumed — so a
/// panel that quantizes, is still applying, or ignored the write reports `sent` with what it said.
func applyBrightness(_ level: Float, to target: ResolvedDisplay) async -> BrightnessWrite {
    var write = BrightnessWrite(target: target, requested: level, outcome: .failed)
    guard let cgID = target.observation.cgDisplayID else {
        write.note = "no Core Graphics id"
        return write
    }
    if target.observation.displayClass == .builtIn {
        let provider = DisplayServicesBrightnessProvider()
        write.provider = "displayServices"
        guard provider.setBrightness(level, for: cgID) else {
            write.note = "DisplayServices unavailable"
            return write
        }
        write.observed = provider.brightness(for: cgID)
        if write.observed == level {
            write.outcome = .verified
        } else {
            write.outcome = .sent
            write.note = write.observed.map { String(format: "read back %.4f", $0) } ?? "no read-back"
        }
        return write
    }
    let binding = bindDDC(target)
    guard let ddc = binding.controller else {
        write.outcome = .unsupported
        write.note = binding.refusal.map(ddcRefusalText) ?? "no brightness control for this display"
        return write
    }
    write.provider = "ddc"
    let maxValue = await ddc.read(.brightness)?.max ?? 100
    let raw = Int((level * Float(maxValue)).rounded())
    guard await ddc.write(.brightness, raw) else {
        write.note = "DDC write failed"
        return write
    }
    let reading = await ddc.read(.brightness)
    if let reading, reading.max > 0 { write.observed = Float(reading.current) / Float(reading.max) }
    switch DDCWriteVerification.outcome(target: raw, readback: reading?.current) {
    case .applied:
        write.outcome = .verified
    case .ignored(let actual):
        write.outcome = .sent
        write.note = "the panel reports \(actual)/\(reading?.max ?? maxValue) instead of \(raw)"
    case .unknown:
        write.outcome = .sent
        write.note = "no read-back"
    }
    return write
}

/// Publishes a CLI brightness change on the OSD event channel, as the app does for its own
/// changes (IN-04): `listen` and external HUD apps otherwise never hear about CLI writes. The
/// setting is re-read at publish time because the app owns the file.
func publishBrightnessEvent(_ write: BrightnessWrite) {
    guard write.outcome.isSuccess, settingsStore?.load().publishOSDEventsEnabled == true else { return }
    let broadcast = OSDBroadcast(
        kind: .brightness, value: Double(write.requested), maxValue: 1,
        displayID: write.target.observation.recordID.rawValue, displayName: name(for: write.target),
        source: OSDBroadcast.Source.cli.rawValue, timestamp: Date().timeIntervalSince1970)
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(OSDBroadcast.notificationName), object: nil, userInfo: broadcast.userInfo,
        deliverImmediately: true)
}

/// Reports brightness writes — successes on stdout, failures on stderr — and exits with the status
/// they add up to. `skipped` targets (absent or held group members) are listed but, being the
/// group policy working as designed, don't count against the result.
func finishBrightness(_ writes: [BrightnessWrite], skipped: [ResultEnvelope.TargetResult] = []) async {
    let status = ResultEnvelope.Status.aggregate(writes.map(\.outcome))
    if asJSON {
        emit(ResultEnvelope(
            transactionId: "txn_brightness", status: status, actor: .cli, requestedAt: Date(),
            topologyGeneration: await observer.currentSnapshot().generation.value,
            targets: writes.map {
                .init(displayId: $0.target.observation.recordID.rawValue, alias: $0.target.record.alias,
                      identityConfidence: 1.0, operations: [$0.operation])
            } + skipped,
            errors: writes.filter { !$0.outcome.isSuccess }.map {
                .init(code: $0.outcome == .unsupported ? "unsupported" : "writeFailed",
                      message: "\(name(for: $0.target)): \($0.note ?? "failed")")
            }))
    } else {
        for write in writes {
            if write.outcome.isSuccess { print(write.line) }
            else { FileHandle.standardError.write(Data((write.line + "\n").utf8)) }
        }
    }
    exitIfUnsuccessful(status)
}

/// `opendisplay brightness group:<name> <0..1>` — the group itself is the target, so `level` is the
/// group's new base level and every present member takes it with its own learned offset (in the
/// absolute and delta modes, which have no base, every member takes `level` itself), decided by the
/// same `GroupSyncPolicy` the app fans out through.
///
/// That includes the precedence ladder: group sync sits below FaceLight and App Presets, and both
/// record the displays they are holding in the settings file this process just read. Fanning out
/// without that set would have the CLI overwrite a fill light the app is mid-way through owing a
/// restore for — the one case where "same policy" has to mean the same world, not just the same
/// arithmetic. Re-read at write time, since the app owns the file and may have toggled FaceLight
/// since launch.
func runGroupBrightness(_ group: DisplayGroup, in pairs: [ResolvedDisplay]) async {
    guard let raw = valueArg, let level = Float(raw), (0...1).contains(level) else {
        fail("usage: opendisplay brightness group:\(group.name) <0..1>", code: CLIExitCode.usage.rawValue)
    }
    let present = pairs.filter { $0.observation.isActive }.map(\.observation.recordID)
    let governed = GroupSyncPolicy.governedDisplays(in: settingsStore?.load() ?? OpenDisplaySettings())
    let world = GroupSyncPolicy.World(present: Set(present), governed: governed)
    let fanOut = GroupSyncPolicy.groupWrites(level, group: group, world: world)
    // Skips first, so a group where every member was skipped explains itself before the failure.
    var skipped: [ResultEnvelope.TargetResult] = []
    func skip(_ member: DisplayRecordID, _ reason: String) async {
        if !asJSON { print("  · skipped (\(reason)): \(await memberLabel(member, in: pairs))") }
        skipped.append(.init(displayId: member.rawValue, alias: nil, identityConfidence: 1.0, operations: [
            .init(field: "brightness", verification: .notApplicable, warnings: [reason], outcome: .skipped)]))
    }
    for member in fanOut.absent { await skip(member, "absent") }
    for member in fanOut.governed { await skip(member, "FaceLight or an app preset owns it") }
    guard !fanOut.isEmpty else { fail("no writable displays in group '\(group.name)'") }
    var writes: [BrightnessWrite] = []
    for write in fanOut.writes {
        guard let target = pairs.first(where: { $0.observation.recordID == write.member }) else { continue }
        let result = await applyBrightness(write.value, to: target)
        publishBrightnessEvent(result)
        writes.append(result)
    }
    await finishBrightness(writes, skipped: skipped)
}

/// Get or set a display's brightness (0..1). Built-in via DisplayServices, external via DDC.
func runBrightness() async {
    guard let sel = selectorArg else { fail("usage: opendisplay brightness <selector> [0..1]") }
    let pairs = await resolveCurrentDisplays()
    if let group = groupSelector(sel) {
        await runGroupBrightness(group, in: pairs)
        return
    }
    let target = uniqueDisplay(sel, in: pairs, managedOffline: managedOfflineIDs)
    guard let cgID = target.observation.cgDisplayID else { fail("display has no Core Graphics id") }
    let builtIn = target.observation.displayClass == .builtIn
    if let raw = valueArg {
        guard let level = Float(raw), (0...1).contains(level) else {
            fail("brightness value must be 0..1", code: CLIExitCode.usage.rawValue)
        }
        let write = await applyBrightness(level, to: target)
        publishBrightnessEvent(write)
        await finishBrightness([write])
        return
    }
    struct Reading: Encodable {
        var displayId: String; var level: Double; var provider: String; var raw: Int?; var max: Int?
    }
    let id = target.observation.recordID.rawValue
    if builtIn, let value = DisplayServicesBrightnessProvider().brightness(for: cgID) {
        if asJSON { emit(Reading(displayId: id, level: Double(value), provider: "displayServices")) }
        else { print("\(Int((value * 100).rounded()))%") }
    } else if !builtIn, let ddc = bindDDC(target).controller,
              let reading = await ddc.read(.brightness), reading.max > 0 {
        let level = Float(reading.current) / Float(reading.max)
        if asJSON {
            emit(Reading(displayId: id, level: Double(level), provider: "ddc", raw: reading.current, max: reading.max))
        } else {
            print("\(Int((level * 100).rounded()))% (\(reading.current)/\(reading.max), DDC)")
        }
    } else {
        fail("brightness can't be read on \(name(for: target)) (no DisplayServices or DDC answer)")
    }
}

/// Get or set a raw DDC/CI feature on an external display.
func runDDC() async {
    let featureNames: [String: ExternalDisplayDDC.Feature] = [
        "brightness": .brightness, "contrast": .contrast, "volume": .volume, "input": .inputSource,
        "colour": .colorPreset, "color": .colorPreset, "preset": .colorPreset,
        "sharpness": .sharpness, "red": .redGain, "green": .greenGain, "blue": .blueGain,
        "mute": .audioMute,
    ]
    let usage = "usage: opendisplay ddc <selector> <brightness|contrast|volume|input|colour|sharpness|red|green|blue|mute|power|caps|reset|vcp <0xNN>> [value]"
    guard let sel = selectorArg, let featureArg = valueArg else { fail(usage, code: CLIExitCode.usage.rawValue) }
    let featureKey = featureArg.lowercased()
    let isCaps = featureKey == "caps" || featureKey == "capabilities"
    let isReset = featureKey == "reset"
    guard isCaps || isReset || featureKey == "power" || featureKey == "vcp" || featureNames[featureKey] != nil else {
        fail("unknown feature '\(featureArg)' — \(usage)", code: CLIExitCode.usage.rawValue)
    }
    let pairs = await resolveCurrentDisplays()
    let target = uniqueDisplay(sel, in: pairs, managedOffline: managedOfflineIDs)
    let binding = bindDDC(target)
    guard let ddc = binding.controller else {
        fail(binding.refusal.map(ddcRefusalText) ?? "no DDC for this display (external displays only)")
    }
    // Capabilities (VCP 0xF3): read the display's advertised feature set, read-only.
    if isCaps {
        guard let raw = await ddc.readCapabilitiesString() else {
            fail("capabilities unavailable for \(name(for: target)) (the monitor didn't answer VCP 0xF3)")
        }
        let codes = DDCCapabilities.parse(raw)?.supportedVCPCodes.sorted().map { String(format: "0x%02X", $0) }
        if asJSON {
            struct Capabilities: Encodable { var capabilities: String; var supportedVCPCodes: [String]? }
            emit(Capabilities(capabilities: raw, supportedVCPCodes: codes))
            return
        }
        print("capabilities: \(raw)")
        if let codes { print("supported VCP codes: \(codes.joined(separator: " "))") }
        return
    }
    // Restore Factory Defaults (VCP 0x04, MCCS): the monitor resets brightness, contrast, colour
    // mode and whatever else its firmware ties to "factory". One-shot, no value — the same write
    // the app's "Reset to defaults…" sends. A panel that ignores it still ACKs, so "sent" is all
    // the CLI can honestly claim; read the features back to see what changed.
    if isReset {
        let ok = await ddc.write(.restoreFactoryDefaults, 1)
        await finishDDCWrite(target, field: "ddc.reset", subject: "factory reset (VCP 0x04)", value: 1, ok: ok)
        return
    }
    let setValue = positional.count > 3 ? positional[3] : nil
    // Raw VCP escape hatch: monitors implement far more of MCCS than we name (KVM switches, OSD
    // language, colour temperature, power LEDs…). `ddc <sel> vcp 0x87 [value]` reads/writes ANY
    // code — 0x-prefixed hex or plain decimal — so a new panel's controls are reachable without a
    // rebuild. Same best-effort semantics as the named features.
    if featureKey == "vcp" {
        guard let codeArg = setValue else { fail("usage: opendisplay ddc <selector> vcp <0xNN|decimal> [value]") }
        let lower = codeArg.lowercased()
        let code: UInt8? = lower.hasPrefix("0x") ? UInt8(lower.dropFirst(2), radix: 16) : UInt8(lower)
        guard let code else { fail("bad VCP code '\(codeArg)' (0x00–0xFF, e.g. 0x87)") }
        let label = String(format: "vcp 0x%02X", code)
        if positional.count > 4 {
            // DDC values are 16-bit on the wire; an unchecked Int would be silently truncated and
            // the success message would then lie about what was written.
            guard let value = Int(positional[4]), (0...0xFFFF).contains(value) else {
                fail("value must be an integer 0-65535", code: CLIExitCode.usage.rawValue)
            }
            let ok = await ddc.write(vcp: code, value)
            await finishDDCWrite(target, field: String(format: "ddc.vcp.0x%02X", code),
                                 subject: "\(label) = \(value)", value: value, ok: ok,
                                 readBack: { await ddc.read(vcp: code) })
        } else {
            await printDDCReading(await ddc.read(vcp: code), feature: label, code: code, target: target)
        }
        return
    }
    // Power is a one-shot DPM command whose value is a word (on|standby|off), not a numeric level.
    // Best-effort: a NAK/ignore just reports a failed write, never crashes.
    if featureKey == "power" {
        guard let raw = setValue else {
            fail("usage: opendisplay ddc <selector> power <\(DDCPowerMode.acceptedTokens)>")
        }
        guard let mode = DDCPowerMode(parsing: raw) else {
            fail("unknown power mode '\(raw)' (\(DDCPowerMode.acceptedTokens))")
        }
        let ok = await ddc.write(.power, mode.vcpValue)
        // No read-back: a panel going to standby stops answering, so "sent" is the honest ceiling.
        await finishDDCWrite(target, field: "ddc.power", subject: "power = \(mode.label)",
                             value: mode.vcpValue, ok: ok)
        return
    }
    guard let feature = featureNames[featureKey] else {
        fail("unknown feature '\(featureArg)' — \(usage)", code: CLIExitCode.usage.rawValue)
    }
    if var raw = setValue {
        // VCP 0x8D (mute) is discrete — 1 = mute, 2 = unmute — which nobody guesses from numbers;
        // accept the words. (`power` gets the same treatment via DDCPowerMode above.)
        if feature == .audioMute {
            switch raw.lowercased() {
            case "on", "mute", "muted": raw = "1"
            case "off", "unmute", "unmuted": raw = "2"
            default: break
            }
        }
        guard let value = Int(raw), (0...0xFFFF).contains(value) else {
            fail(feature == .audioMute ? "mute value must be on|off (or 1=mute, 2=unmute)"
                                       : "value must be an integer 0-65535", code: CLIExitCode.usage.rawValue)
        }
        let ok = await ddc.write(feature, value)
        await finishDDCWrite(target, field: "ddc.\(featureKey)", subject: "\(featureArg) = \(value)",
                             value: value, ok: ok, readBack: { await ddc.read(feature) })
    } else {
        await printDDCReading(await ddc.read(feature), feature: featureArg, code: feature.rawValue, target: target)
    }
}

/// Reports one DDC write and exits with its status. `sent` once the panel ACKs the write;
/// `verified` only when `readBack` — for features that can be read at all — returns exactly the
/// written value. A different answer is reported, not called a failure: the panel may still be
/// applying the value, or may have ignored it (they ACK writes they then drop).
func finishDDCWrite(_ target: ResolvedDisplay, field: String, subject: String, value: Int, ok: Bool,
                    readBack: (() async -> (current: Int, max: Int)?)? = nil) async {
    var operation = ResultEnvelope.OperationResult(
        field: field, requested: .int(value), verification: .notApplicable, provider: "ddc", outcome: .failed)
    var detail = "not verified (no read-back)"
    if ok {
        operation.outcome = .sent
        operation.verification = .readBackUnavailable
        if let readBack {
            let reading = await readBack()
            operation.observed = reading.map { .int($0.current) }
            switch DDCWriteVerification.outcome(target: value, readback: reading?.current) {
            case .applied:
                operation.outcome = .verified
                operation.verification = .verified
                detail = "verified"
            case .ignored(let actual):
                detail = "not verified: the panel reports \(actual)"
                operation.warnings = [detail]
            case .unknown:
                break
            }
        }
    }
    let outcome = operation.outcome ?? .failed
    let status = ResultEnvelope.Status.aggregate([outcome])
    if asJSON {
        emit(ResultEnvelope(
            transactionId: "txn_ddc", status: status, actor: .cli, requestedAt: Date(),
            topologyGeneration: await observer.currentSnapshot().generation.value,
            targets: [.init(displayId: target.observation.recordID.rawValue, alias: target.record.alias,
                            identityConfidence: 1.0, operations: [operation])],
            errors: ok ? [] : [.init(code: "writeFailed", message: "DDC write failed")]))
    } else if ok {
        print("\(subject) — \(outcome == .verified ? "verified" : "sent, \(detail)")")
    } else {
        FileHandle.standardError.write(Data("\(name(for: target)): \(subject) — DDC write failed\n".utf8))
    }
    exitIfUnsuccessful(status)
}

/// Prints a DDC read, or fails when the panel didn't answer — an unanswered read is not a value.
func printDDCReading(_ reading: (current: Int, max: Int)?, feature: String, code: UInt8,
                     target: ResolvedDisplay) async {
    guard let reading else {
        fail("\(feature) unsupported or unanswered on \(name(for: target))")
    }
    if asJSON {
        struct Reading: Encodable { var displayId: String; var feature: String; var vcp: String; var current: Int; var max: Int }
        emit(Reading(displayId: target.observation.recordID.rawValue, feature: feature,
                     vcp: String(format: "0x%02X", code), current: reading.current, max: reading.max))
    } else {
        print("\(feature): \(reading.current)/\(reading.max)")
    }
}

func runEDID() async {
    guard let sel = selectorArg else { fail("usage: opendisplay edid <selector> [--out <path.bin>]") }
    let pairs = await resolveCurrentDisplays()
    let target = uniqueDisplay(sel, in: pairs, managedOffline: managedOfflineIDs)
    guard let cgID = target.observation.cgDisplayID else { fail("no display for selector '\(sel)'") }
    // Only bytes that are provably this display's are printed or written; a guess between
    // identical monitors would export another monitor's identity under this one's name.
    let bytes: [UInt8]
    switch EDIDReader.lookup(for: cgID) {
    case .matched(let found):
        bytes = found
    case .ambiguous(let count):
        fail("edid: \(count) different EDIDs carry this display's vendor, product code and serial — "
            + "can't tell which one is this display's, so none is shown")
    case .notFound:
        fail("edid: unavailable for this display (no exposed EDID carries its vendor, product code and serial)")
    case .unidentifiedTarget:
        fail("edid: unavailable for this display (macOS reports no vendor/product code to match an EDID against)")
    }
    let parsed = EDID.parse(bytes)
    if let edid = parsed {
        print("manufacturer:     \(edid.manufacturerID)")
        print("product code:     \(edid.productCode)")
        if let n = edid.monitorName { print("model:            \(n)") }
        if let s = edid.serialText { print("serial (text):    \(s)") }
        if edid.serialNumber != 0 { print("serial (numeric): \(edid.serialNumber)") }
        print("edid version:     \(edid.edidVersion).\(edid.edidRevision)")
        if let y = edid.manufactureYear {
            print("manufactured:     week \(edid.manufactureWeek.map(String.init) ?? "?") / \(y)")
        }
        if let r = edid.preferredResolution { print("preferred:        \(r.width)x\(r.height)") }
        if let w = edid.widthCm, let h = edid.heightCm { print("size:             \(w)x\(h) cm") }
        print("checksum:         \(edid.checksumValid ? "valid" : "INVALID")")
        print("extensions:       \(edid.extensionCount)")
        print("hash:             \(EDID.stableHash(bytes))")
    } else {
        warn("edid: \(bytes.count) bytes read, but the base block failed to parse")
    }
    if let path = invocation.values["--out"] {
        do {
            try Data(bytes).write(to: URL(fileURLWithPath: path))
            print("wrote \(bytes.count) bytes → \(path)")
        } catch {
            fail("could not write \(path): \(error)")
        }
        // The raw dump is the salvage for an EDID this parser can't read, so with --out a parse
        // failure is only a warning.
        return
    }
    if parsed == nil { exit(CLIExitCode.failure.rawValue) }
}

/// Parses a mode argument like `1920x1080`, `1920x1080@60`, or `1512x982@60@2x` into a `DisplayMode`
/// (pixel size mirrors point size; only point-size/refresh/HiDPI matter for the favourite key).
func parseModeArg(_ s: String) -> DisplayMode? {
    let hiDPI = s.contains("@2x")
    let parts = s.replacingOccurrences(of: "@2x", with: "").split(separator: "@")
    guard let sizePart = parts.first else { return nil }  // a bare "@2x" leaves nothing to parse
    let dims = sizePart.lowercased().split(separator: "x")
    guard dims.count == 2, let w = Int(dims[0]), let h = Int(dims[1]) else { return nil }
    let hz = parts.count > 1 ? (Double(parts[1]) ?? 60) : 60
    return DisplayMode(pixelWidth: w, pixelHeight: h, pointWidth: w, pointHeight: h, refreshHz: hz, isHiDPI: hiDPI)
}

func runFavorite() async {
    guard let sub = selectorArg, let sel = valueArg else {
        fail("usage: opendisplay favorite <list|set|unset> <selector> [WxH[@Hz][@2x]]")
    }
    let store = (try? SettingsStore.defaultDirectory()).map(FavoritesStore.init(directory:))
    var favorites = store?.load() ?? FavoriteResolutions()
    let pairs = await resolveCurrentDisplays()
    let target = uniqueDisplay(sel, in: pairs, managedOffline: managedOfflineIDs)
    let recordID = target.record.id
    switch sub.lowercased() {
    case "list":
        let keys = favorites.favoriteKeys(for: recordID)
        print(keys.isEmpty ? "(no favourites)" : keys.joined(separator: "\n"))
    case "set", "unset":
        guard positional.count > 3, let spec = parseModeArg(positional[3]) else {
            fail("mode must look like 1920x1080[@60][@2x]")
        }
        // Favourites name exact modes (framebuffer, unrounded refresh), which the WxH@Hz argument
        // doesn't spell out — resolve it against what the display really offers. The refresh must
        // match the argument itself, so `@60` never picks a 59.94 Hz mode or the reverse.
        let available = target.observation.cgDisplayID.map { observer.allModes(for: $0) } ?? []
        let modes = available.filter {
            $0.pointWidth == spec.pointWidth && $0.pointHeight == spec.pointHeight
                && $0.isHiDPI == spec.isHiDPI && abs($0.refreshHz - spec.refreshHz) < 0.01
        }
        let changedKeys: [String]
        if modes.isEmpty, sub.lowercased() == "unset" {
            // A favourite the display no longer offers must stay removable: match the stored keys
            // on what the argument does say (logical size, density, refresh).
            changedKeys = favorites.removeKeys(matchingLogical: spec, for: recordID)
            guard !changedKeys.isEmpty else { fail("no favourite matches \(positional[3]) for \(name(for: target))") }
        } else {
            guard !modes.isEmpty else {
                fail("\(name(for: target)) doesn't offer \(positional[3]) right now — it must be connected and the refresh rate exact (e.g. @59.94)")
            }
            for mode in modes {
                if sub.lowercased() == "set" { favorites.add(mode, for: recordID) }
                else { favorites.remove(mode, among: available, for: recordID) }
            }
            changedKeys = modes.map(FavoriteResolutions.key(for:))
        }
        guard let store else { fail("settings directory unavailable; nothing was saved") }
        do { try store.save(favorites) } catch { fail("could not save favourites: \(error)") }
        for key in changedKeys { print("\(sub.lowercased()) \(key) for \(name(for: target))") }
    default:
        fail("unknown favorite subcommand '\(sub)' (list|set|unset)")
    }
}

// MARK: - Protected layout (Batch-4 #A)

/// `layout protect|unprotect|status`. Protection is keyed by the display set on the desk right now,
/// so the CLI protects exactly what `list` shows — and the app, reading the same settings file
/// through the same fingerprint, is looking at the same layout. The two writes route through
/// `CommandGateway`, so they land in the audit trail with every other command.
func runLayout() async {
    let sub = positional.count > 1 ? positional[1] : "status"
    guard let store = (try? SettingsStore.defaultDirectory()).map(SettingsStore.init(directory:)) else {
        fail("settings directory unavailable")
    }
    switch sub {
    case "protect", "unprotect":
        let change: LayoutProtectionChange = sub == "protect" ? .protect : .unprotect
        let envelope = await gateway.applyLayoutProtection(
            change, store: store, managedOffline: managedOfflineDisplays, actor: .cli)
        if asJSON { emit(envelope); exitIfUnsuccessful(envelope.status); return }
        switch envelope.status {
        case .committed:
            let count = envelope.targets.count
            print(change == .protect
                  ? "protected this layout (\(count) display\(count == 1 ? "" : "s"))"
                  : "removed protection for this display set")
        case .noOp:
            print("this display set isn't protected")
        default:
            emitEnvelope(envelope)
        }
        if change == .protect && !store.load().layoutProtectionEnabled {
            print("note: turn on \u{201C}Put my arrangement back when it changes\u{201D} in "
                  + "OpenDisplay \u{2192} Arrange for it to be restored automatically")
        }
    case "status":
        await runLayoutStatus(store: store)
    default:
        fail("unknown layout subcommand '\(sub)' (try: protect, unprotect, status)", code: 2)
    }
}

/// Per-fingerprint protection plus the last automatic restore, so "why didn't my layout come back?"
/// is answerable without opening the app.
func runLayoutStatus(store: SettingsStore) async {
    let settings = store.load()
    let snapshot = await observer.currentSnapshot()
    let currentFingerprint = LayoutProtectionPolicy.fingerprint(
        for: snapshot,
        managedOffline: LayoutProtectionPolicy.switchedOffIDs(in: snapshot,
                                                              ledger: managedOfflineDisplays))
    let pairs = await resolveCurrentDisplays()
    let namesByID = Dictionary(pairs.map { ($0.observation.recordID, name(for: $0)) },
                               uniquingKeysWith: { _, latest in latest })
    // Members, not observations: a display the arrangement keeps switched off is still one of the
    // displays it covers, and on the experimental path it left no observation to be listed by.
    func members(of config: ProtectedConfig) -> [String] {
        LayoutProtectionPolicy.members(of: config)
            .map { namesByID[$0] ?? $0.rawValue }.sorted()
    }
    let lastRestore = await lastLayoutProtectionEntry()

    if asJSON {
        struct Layout: Encodable {
            var fingerprint: String; var current: Bool; var displays: [String]; var capturedAt: Date
        }
        struct Status: Encodable {
            var enabled: Bool; var currentFingerprint: String; var currentSetProtected: Bool
            var layouts: [Layout]; var lastRestoreAt: Date?; var lastRestoreStatus: String?
        }
        emit(Status(
            enabled: settings.layoutProtectionEnabled, currentFingerprint: currentFingerprint,
            currentSetProtected: settings.protectedLayouts[currentFingerprint] != nil,
            layouts: settings.protectedLayouts.sorted { $0.key < $1.key }.map {
                Layout(fingerprint: $0.key, current: $0.key == currentFingerprint,
                       displays: members(of: $0.value), capturedAt: $0.value.capturedAt)
            },
            lastRestoreAt: lastRestore?.timestamp, lastRestoreStatus: lastRestore?.status))
        return
    }

    print("automatic restore: \(settings.layoutProtectionEnabled ? "on" : "off")")
    if settings.protectedLayouts.isEmpty {
        print("no protected layouts (protect this one with: opendisplay layout protect)")
    }
    for (fingerprint, config) in settings.protectedLayouts.sorted(by: { $0.key < $1.key }) {
        let mark = fingerprint == currentFingerprint ? "\u{25CF}" : "\u{25CB}"
        let here = fingerprint == currentFingerprint ? "  [this display set]" : ""
        print("\(mark) \(members(of: config).joined(separator: " + "))  captured "
              + "\(ISO8601DateFormatter().string(from: config.capturedAt))\(here)")
    }
    if settings.protectedLayouts[currentFingerprint] == nil, !settings.protectedLayouts.isEmpty {
        print("this display set isn't protected")
    }
    if let lastRestore {
        print("last restore: \(ISO8601DateFormatter().string(from: lastRestore.timestamp)) "
              + "\u{2014} \(lastRestore.status)")
    }
}

/// The newest protected-layout entry in the shared audit trail, or nil when none has run.
func lastLayoutProtectionEntry() async -> AuditEntry? {
    guard let auditLog else { return nil }
    return await auditLog.recent(limit: 200).last { $0.command == "layoutProtection" }
}

// MARK: - Display Groups (Issue #39)

/// Re-reads settings, applies one group mutation, and writes back. The app owns the same file, so
/// the read has to happen at mutation time — a groups list captured at launch would clobber
/// everything the app changed in between.
func mutateDisplayGroups(_ change: ([DisplayGroup]) -> [DisplayGroup]?) -> Bool {
    guard let settingsStore else { fail("settings directory unavailable") }
    var settings = settingsStore.load()
    guard let updated = change(settings.displayGroups) else { return false }
    settings.displayGroups = updated
    do { try settingsStore.save(settings) } catch { fail("could not save settings: \(error)") }
    return true
}

func runGroup() async {
    let sub = positional.count > 1 ? positional[1] : "list"
    let nameArg: String? = positional.count > 2 ? positional[2] : nil
    let selector: String? = positional.count > 3 ? positional[3] : nil
    let groups = settingsStore?.load().displayGroups ?? []

    switch sub {
    case "list":
        await runGroupList(groups)

    case "create":
        guard let nameArg else { fail("usage: opendisplay group create <name>") }
        let created = mutateDisplayGroups { DisplayGroupStore.create(named: nameArg, in: $0) }
        _ = await gateway.recordGroupChange("groupCreate", targets: [], committed: created)
        guard created else { fail("a group named '\(nameArg)' already exists") }
        print("created group \"\(nameArg)\"")

    case "delete":
        guard let nameArg, let group = DisplayGroupStore.group(named: nameArg, in: groups) else {
            fail("no display group named '\(nameArg ?? "")'")
        }
        _ = mutateDisplayGroups { DisplayGroupStore.delete(id: group.id, from: $0) }
        _ = await gateway.recordGroupChange("groupDelete",
                                            targets: group.memberRecordIDs.map(\.rawValue))
        print("deleted group \"\(group.name)\"")

    case "add", "remove":
        guard let nameArg, let selector else {
            fail("usage: opendisplay group \(sub) <name> <selector>")
        }
        await runGroupMembership(sub, groupName: nameArg, selector: selector, groups: groups)

    default:
        fail("unknown group subcommand '\(sub)' (try: list, create, delete, add, remove)", code: 2)
    }
}

func runGroupList(_ groups: [DisplayGroup]) async {
    if asJSON {
        emit(groups)
        return
    }
    guard !groups.isEmpty else {
        print("no display groups (create one with: opendisplay group create <name>)")
        return
    }
    let pairs = await resolveCurrentDisplays()
    for group in groups {
        // A group on the original offsets mode reads exactly as before; another mode is named.
        let brightness = group.brightnessMode == .offsets ? "brightness" : "brightness (\(group.brightnessMode.rawValue))"
        let channels = [group.syncBrightness ? brightness : nil,
                        group.syncContrast ? "contrast" : nil].compactMap { $0 }
        print("\(group.name)  (\(group.memberRecordIDs.count) displays · syncs \(channels.joined(separator: " + ")))")
        for member in group.memberRecordIDs {
            let pair = pairs.first { $0.observation.recordID == member }
            let label = await memberLabel(member, in: pairs)
            let offset = group.offset(for: member)
            let offsetNote = offset == 0 ? "" : String(format: "  %+.0f%%", offset * 100)
            print("  \(pair == nil ? "○" : "●") \(label)\(offsetNote)")
        }
    }
}

func runGroupMembership(_ sub: String, groupName: String, selector: String,
                        groups: [DisplayGroup]) async {
    guard let group = DisplayGroupStore.group(named: groupName, in: groups) else {
        fail("no display group named '\(groupName)'")
    }
    let pairs = await resolveCurrentDisplays()
    let target = uniqueDisplay(selector, in: pairs, managedOffline: managedOfflineIDs)
    let member = target.observation.recordID
    let isAdding = sub == "add"
    _ = mutateDisplayGroups {
        isAdding ? DisplayGroupStore.addMember(member, to: group.id, in: $0)
                 : DisplayGroupStore.removeMember(member, from: group.id, in: $0)
    }
    _ = await gateway.recordGroupChange(isAdding ? "groupAdd" : "groupRemove",
                                        targets: [member.rawValue])
    // A display belongs to one group, so `add` may have moved it — say where it came from.
    let previous = DisplayGroupStore.group(containing: member, in: groups)
    let moved = isAdding && previous != nil && previous?.id != group.id
    let from = moved ? " (moved from \"\(previous?.name ?? "")\")" : ""
    print(isAdding ? "added \(name(for: target)) to \"\(group.name)\"\(from)"
                   : "removed \(name(for: target)) from \"\(group.name)\"")
}

// MARK: - Experimental rotation helper (short-lived, gated, isolated)

/// EXPERIMENTAL rotation writer. Gated behind OPENDISPLAY_EXPERIMENTAL_ROTATION=1 so it never runs by
/// accident. Validates the angle + display safety, calls the private SkyLight rotator, polls
/// CGDisplayRotation to confirm, verifies no other display moved, and rolls back on any mismatch.
/// Running this in its own process isolates the app from a client-side WindowServer crash.
func runRotateExperimental() async {
    guard ProcessInfo.processInfo.environment["OPENDISPLAY_EXPERIMENTAL_ROTATION"] == "1" else {
        fail("experimental rotation disabled — set OPENDISPLAY_EXPERIMENTAL_ROTATION=1 to opt in", code: 3)
    }
    guard let sel = selectorArg, let raw = valueArg, let degrees = Int(raw) else {
        fail("usage: OPENDISPLAY_EXPERIMENTAL_ROTATION=1 opendisplay _rotate-exp <selector> <0|90|180|270>")
    }
    guard [0, 90, 180, 270].contains(degrees) else { fail("angle must be 0, 90, 180 or 270") }
    let pairs = await resolveCurrentDisplays()
    let target = uniqueDisplay(sel, in: pairs, managedOffline: managedOfflineIDs)
    guard let cgID = target.observation.cgDisplayID else { fail("target has no Core Graphics id") }
    let snapshot = await observer.currentSnapshot()
    let active = snapshot.activeDisplays
    guard target.observation.isActive else { fail("target display is not active") }
    guard target.observation.mirrorSourceID == nil else { fail("refusing to rotate a mirrored display") }
    guard active.count > 1 else { fail("refusing: target is the only active display") }

    let before = Int(CGDisplayRotation(cgID).rounded())
    let rotator = SkyLightDisplayRotator()
    guard rotator.isAvailable else { fail("SLSSetDisplayRotation unavailable on this OS", code: 4) }

    let rc = rotator.rotate(Int32(degrees), displayID: cgID)
    var observed = before
    for _ in 0..<12 { usleep(150_000); observed = Int(CGDisplayRotation(cgID).rounded()); if observed == degrees { break } }
    // No other active display should have changed rotation.
    let othersOK = active.allSatisfy { other in
        guard let oid = other.cgDisplayID, oid != cgID else { return true }
        return Int(CGDisplayRotation(oid).rounded()) == other.rotation.rawValue
    }
    if observed == degrees && othersOK {
        print("rotated \(cgID) \(before)° → \(degrees)° (rc=\(rc))")
    } else {
        _ = rotator.rotate(Int32(before), displayID: cgID)
        fail("verification failed (rc=\(rc), observed=\(observed)°, othersOK=\(othersOK)) — rolled back to \(before)°", code: 5)
    }
}

// MARK: - Listen (line-delimited JSON event stream)

/// Keeps the Ctrl-C signal source alive for the process's lifetime — a `DispatchSourceSignal` stops
/// firing the moment nothing retains it, so a local `let` inside `installCleanSigintExit` would be
/// silently deallocated before any signal ever arrived. `nonisolated(unsafe)`: written once at
/// startup, on the same thread that later reads it only to keep it retained (matches the retained-
/// token pattern in `GlobalHotKey.swift`).
nonisolated(unsafe) var sigintSource: DispatchSourceSignal?

/// Installs a clean Ctrl-C exit for `listen`: ignore the default disposition (which would kill the
/// process mid-write) and `exit(0)` from a dedicated queue once the signal lands.
func installCleanSigintExit() {
    signal(SIGINT, SIG_IGN)
    let queue = DispatchQueue(label: "opendisplay.listen.sigint")
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
    source.setEventHandler { exit(0) }
    source.resume()
    sigintSource = source
}

/// The live topology as `listen`'s compact per-display summary.
func summarizeCurrentDisplays() async -> [ListenEvent.DisplaySummary] {
    let snapshot = await observer.currentSnapshot()
    return snapshot.observations.map {
        ListenEvent.DisplaySummary(id: $0.recordID.rawValue, active: $0.isActive, main: $0.isMain,
                                   mode: modeString($0))
    }
}

/// Streams a `config` event on every topology change (hotplug, mode, rotation, mirror, main display).
func watchConfigEvents() async {
    let topologyChanges = await observer.changes()
    for await _ in topologyChanges {
        let displays = await summarizeCurrentDisplays()
        emitLine(ListenEvent.config(at: Date().timeIntervalSince1970, displays: displays))
    }
}

/// Streams a `brightness` event for every live `OSDBroadcast` (menu/media-key/CLI/App-Intent origin).
/// Requires "Broadcast OSD events" enabled in OpenDisplay's settings — `runListen` warns on stderr
/// once at startup when it's off.
func watchBrightnessEvents() async {
    let center = DistributedNotificationCenter.default()
    let broadcastName = Notification.Name(OSDBroadcast.notificationName)
    for await notification in center.notifications(named: broadcastName) {
        guard let userInfo = notification.userInfo as? [String: String],
              let broadcast = OSDBroadcast(userInfo: userInfo), broadcast.kind == .brightness
        else { continue }
        emitLine(ListenEvent.brightness(from: broadcast))
    }
}

/// One-time stderr note when the app hasn't opted into broadcasting brightness changes — otherwise
/// `listen` would sit silent on brightness with no clue why.
func warnIfBrightnessEventsAreOff() {
    let settingsStore = (try? SettingsStore.defaultDirectory()).map(SettingsStore.init(directory:))
    guard settingsStore?.load().publishOSDEventsEnabled != true else { return }
    FileHandle.standardError.write(Data(
        "note: brightness events need \"Broadcast OSD events\" on in OpenDisplay settings\n".utf8))
}

/// Streams brightness + config-change events as line-delimited JSON until Ctrl-C. Line-buffered
/// (`setvbuf`) so a piped consumer (`| jq`, `| tail -f`) sees each event as it happens rather than
/// batched at exit.
func runListen() async {
    setvbuf(stdout, nil, _IOLBF, 0)
    installCleanSigintExit()
    warnIfBrightnessEventsAreOff()
    async let brightnessEvents: Void = watchBrightnessEvents()
    async let configEvents: Void = watchConfigEvents()
    _ = await (brightnessEvents, configEvents)
}

// MARK: - Dispatch

switch command {
case "list": await runList()
case "diagnose": await runDiagnose()
case "lux": await runLux()
case "lid": await runLid()
case "listen": await runListen()
case "alias": await runAlias()
case "tag": await runTag()
case "recover": await runRecover()
case "disconnect": await runDisconnect()
case "reconnect": await runReconnect()
case "scene": await runScene()
case "layout": await runLayout()
case "group": await runGroup()
case "brightness": await runBrightness()
case "ddc": await runDDC()
case "edid": await runEDID()
case "favorite", "favourite": await runFavorite()
case "_rotate-exp": await runRotateExperimental()
default:
    // Unknown verbs and `help` are answered before the composition root; reaching here means the
    // grammar's command list and this switch disagree.
    fail("command '\(command)' is not dispatched", code: CLIExitCode.usage.rawValue)
}
