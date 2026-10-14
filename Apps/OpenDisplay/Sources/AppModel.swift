#if os(macOS)
import AppKit
import AutomationSchema
import CoreGraphicsProvider
import DisplayDomain
import Foundation
import ProviderInterfaces
import SceneEngine
import TopologyCore
#if !PUBLIC_API_ONLY
import ExperimentalLifecycleProvider
#endif

/// A hardware (DDC) control the menu can offer for an external display. Public-safe (no private-SPI
/// types), so the menu can reference it in every build; AppModel maps it to a DDC VCP code.
enum HardwareControl: CaseIterable, Hashable {
    case contrast, volume, sharpness, redGain, greenGain, blueGain

    var vcp: UInt8 {
        switch self {
        case .contrast: return 0x12
        case .volume: return 0x62
        case .sharpness: return 0x87
        case .redGain: return 0x16
        case .greenGain: return 0x18
        case .blueGain: return 0x1A
        }
    }
    var label: String {
        switch self {
        case .contrast: return String(localized: "Contrast")
        case .volume: return String(localized: "Volume")
        case .sharpness: return String(localized: "Sharpness")
        case .redGain: return String(localized: "Red gain")
        case .greenGain: return String(localized: "Green gain")
        case .blueGain: return String(localized: "Blue gain")
        }
    }
    var icon: String {
        switch self {
        case .contrast: return "circle.lefthalf.filled"
        case .volume: return "speaker.wave.2"
        case .sharpness: return "triangle.lefthalf.filled"
        case .redGain: return "r.circle"
        case .greenGain: return "g.circle"
        case .blueGain: return "b.circle"
        }
    }
}

/// Which route a display's unified brightness slider drives. Resolved per display when brightness is
/// read: built-in panels use the OS (`native`), externals that answer DDC use `hardware`, and anything
/// else falls back to `software` gamma dimming (works on any display). Surfaced as a small caption so
/// the single slider stays honest about *how* it's dimming.
enum BrightnessMethod: String, Hashable {
    case native, hardware, software

    /// Caption shown beneath the slider. `native` needs none — it *is* the system brightness.
    var caption: String? {
        switch self {
        case .native: return nil
        case .hardware: return String(localized: "Hardware · DDC")
        case .software: return String(localized: "Software · gamma")
        }
    }
}

/// Build/runtime feature flags for the experimental control paths (PRD: risky behaviour is opt-in).
enum FeatureFlags {
    /// ICC profile writing uses *public* ColorSync, so it's App-Store-safe and on by default.
    static var iccProfileWrite: Bool { true }
    #if !PUBLIC_API_ONLY
    /// Rotation writing uses a *private* API — OFF unless explicitly enabled, and the whole path is
    /// compiled out of the public-API-only / App Store build.
    static var experimentalRotation: Bool { UserDefaults.standard.bool(forKey: "OpenDisplayExperimentalRotation") }
    #else
    static var experimentalRotation: Bool { false }
    #endif
}

/// The app's composition root. It wires the platform-independent `TopologyCoordinator`
/// (Packages/TopologyCore) to a display system and exposes an observable snapshot for the UI.
///
/// M0: observation comes from the real `CoreGraphicsProvider` (live enumeration + a
/// reconfiguration event source). The lifecycle path prefers the experimental SkyLight provider
/// (true logical disconnect, full build only) and falls back to `CoreGraphicsProvider`'s public,
/// reversible mirroring approach — selected by `RoutedLifecycleProvider`. In the public-API-only
/// build the experimental module is absent and the public provider is used directly.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var displays: [DisplayObservation] = []
    @Published private(set) var statusText = String(localized: "Scanning…")
    @Published private(set) var busy = false
    @Published private(set) var diagnostics: [DisplayDiagnostic] = []
    @Published private(set) var phase: DisplayLoadPhase = .scanning
    @Published private(set) var recentActivity: [AuditEntry] = []
    /// Identity records for the current displays, keyed by the observation's record id.
    @Published private(set) var records: [DisplayRecordID: DisplayRecord] = [:]
    /// Every display the registry remembers — including ones that aren't plugged in right now —
    /// keyed by the same observation record id `records` uses. This is what lets the Groups card
    /// offer (and name) a display that is currently unplugged or turned off.
    @Published private(set) var registryKnownRecords: [DisplayRecordID: DisplayRecord] = [:]
    @Published private(set) var scenes: [Scene] = []
    /// Non-fatal note from the last scene apply (e.g. rotation skipped) — shown in the Scenes tab.
    @Published var sceneWarning: String?
    /// Displays the app has logically turned off. The OS drops them from the online list, so we track
    /// them here to keep an "off" card in the menu (with a way back on) and to feed the safety net.
    @Published private(set) var managedOffline: [OfflineDisplay] = []
    /// Cached brightness (0...1) for displays we can control — built-in via DisplayServices, externals
    /// via DDC, or software gamma as a universal fallback. A missing key means "not yet read".
    @Published private(set) var brightness: [DisplayRecordID: Float] = [:]
    /// The route the unified brightness slider drives for each display (resolved on read).
    @Published private(set) var brightnessMethod: [DisplayRecordID: BrightnessMethod] = [:]
    /// The display selected in the Settings → Displays detail pane. The menu bar sets this when it
    /// deep-links into Settings ("Display settings…"), so the right display is shown on arrival.
    @Published var selectedDisplayID: DisplayRecordID?
    /// Opt-in toggle for the experimental (private-API) rotation writer; persisted to UserDefaults.
    /// Drives the rotation backend live and stays false in the public-API-only build.
    @Published var experimentalRotationEnabled: Bool = FeatureFlags.experimentalRotation {
        didSet { UserDefaults.standard.set(experimentalRotationEnabled, forKey: "OpenDisplayExperimentalRotation") }
    }
    /// Cached DDC hardware-control levels (0...1) keyed by display then VCP code (contrast/volume).
    @Published private(set) var ddcControlLevel: [DisplayRecordID: [UInt8: Float]] = [:]
    /// Cached DDC capabilities (VCP 0xF3) per external display (Batch-2 #1): what the panel advertises,
    /// so the UI/CLI only offer supported controls. Absent = not yet read → fall back to offering all.
    @Published private(set) var ddcCapabilities: [DisplayRecordID: DDCCapabilities] = [:]
    /// Per-display software (gamma) dim level, 1 = no dim. Applies on top of hardware brightness and
    /// works on any display, including DDC-less externals and below the hardware minimum.
    @Published private(set) var softwareDim: [DisplayRecordID: Float] = [:]
    /// DDC input-source code (VCP 0x60) per external display as the MONITOR last reported it — a
    /// read-back, never a request (AM-05). Nil = unknown, e.g. right after a switch was sent.
    @Published private(set) var inputSource: [DisplayRecordID: Int] = [:]
    /// The last input switch OpenDisplay requested per display and what the transport said about it,
    /// shown next to — never instead of — the reported `inputSource`. Cleared by a fresh read.
    @Published private(set) var inputSwitch: [DisplayRecordID: DDCInputSwitch] = [:]
    /// Current DDC colour-preset code (VCP 0x14) per external display, and the max code it reports.
    @Published private(set) var colorPreset: [DisplayRecordID: Int] = [:]
    @Published private(set) var colorPresetMax: [DisplayRecordID: Int] = [:]
    /// VCP codes, per display, whose last DDC write the panel answered with a different value — it
    /// ACKed and then ignored (or clamped) the change, e.g. an LG whose picture mode locks contrast,
    /// or a colour-preset code the panel doesn't implement. The cached level has already been snapped
    /// back to the panel's value; this only drives the quiet "the monitor ignored this" caption.
    /// Set by the post-drain read-back (`DDCWriteVerification`); cleared by the next verified write
    /// or successful read of that feature, by a factory reset, and when the display leaves.
    @Published private(set) var ddcWriteIgnored: [DisplayRecordID: Set<UInt8>] = [:]
    /// Displays OpenDisplay deliberately sends no DDC to, and why (TR-06 ambiguous service binding,
    /// FB-08 Apple display without the override). Set on every controller lookup, so it follows
    /// topology changes; the UI shows it instead of "the monitor didn't respond".
    @Published private(set) var ddcBindingRefusal: [DisplayRecordID: DDCBindingRefusal] = [:]
    /// VCP codes, per display, whose last write failed at the transport (the I2C call itself) with no
    /// read-back to say otherwise (TB-02). The control is then no longer treated as usable by the
    /// volume keys, and the UI says the change didn't reach the monitor. Cleared like
    /// `ddcWriteIgnored`: by a verified write or a fresh successful read.
    @Published private(set) var ddcWriteFailed: [DisplayRecordID: Set<UInt8>] = [:]
    /// The monitor's discrete audio mute (VCP 0x8D) as read back, per display: true = muted. Absent =
    /// no readable discrete mute, so mute falls back to volume 0 (TB-03).
    @Published private(set) var ddcAudioMuted: [DisplayRecordID: Bool] = [:]
    /// MCCS audio mute (VCP 0x8D) — `ExternalDisplayDDC.Feature.audioMute`, named here so the public
    /// build (which has no DDC module) can still key the maps above.
    static let ddcAudioMuteVCP: UInt8 = 0x8D
    /// Current ICC colour-profile name per display (ColorSync), for the Colour profile row.
    @Published private(set) var colorProfileName: [DisplayRecordID: String] = [:]
    /// Whether each display exposes a ColorSync device that profile writes can target — resolved
    /// off-main and cached so the menu never probes ColorSync during a view body.
    @Published private(set) var colorProfileControllable: [DisplayRecordID: Bool] = [:]
    /// Installed ICC profiles the user can assign, enumerated off-main once and cached (the scan reads
    /// and parses every installed profile from disk, so it must never run during a SwiftUI body).
    @Published private(set) var availableColorProfilesCache: [ICCProfile] = []
    /// What ColorSync reports each display is assigned — the profile FILE, so the menus mark the
    /// actual current profile even when two installed files share a name. Absent = not read yet.
    @Published private(set) var colorProfileAssignment: [DisplayRecordID: ICCAssignment] = [:]
    /// Why the last profile change on a display didn't land (ColorSync refused it, or the re-read
    /// shows a different profile); cleared by the next change that does.
    @Published private(set) var colorProfileError: [DisplayRecordID: String] = [:]
    /// Connected displays with a user/shared custom ICC profile assigned (`ColorProfileGuard`).
    /// While non-empty, OpenDisplay's gamma writes are blocked on every display unless the user
    /// overrode the safeguard.
    @Published private(set) var customProfileDisplays: Set<DisplayRecordID> = []
    /// Per display, the Core Graphics error of the last gamma write that was rejected; nil once a
    /// write lands. Surfaced next to the software brightness, dimming and temperature controls,
    /// whose cached values are the request — this says the request isn't on screen.
    @Published private(set) var gammaWriteFailures: [DisplayRecordID: Int32] = [:]
    /// Displays whose gamma table currently holds OpenDisplay's formula/table rather than
    /// ColorSync's. Only these ever need handing back, so a display nothing has dimmed or warmed
    /// gets no colour-table call at all.
    private var gammaOwned: Set<DisplayRecordID> = []
    /// Sequence number of the newest custom-profile safeguard read (`refreshCustomProfileGuard`).
    private var customProfileGuardRead = 0

    /// Standard DDC colour-preset labels (VCP 0x14, MCCS 2.2 codes 0x01…0x0C). Monitors vary; the
    /// menu offers the advertised codes (or a bounded 1...max guess) and labels the standard ones,
    /// falling back to "Preset N".
    static let presetNames: [Int: String] = [
        1: "sRGB", 2: String(localized: "Display native"), 3: "4000K", 4: "5000K", 5: "6500K",
        6: "7500K", 7: "8200K", 8: "9300K", 9: "10000K", 10: "11500K",
        11: String(localized: "User 1"), 12: String(localized: "User 2"),
    ]
    func presetName(_ code: Int) -> String { Self.presetNames[code] ?? String(localized: "Preset \(code)") }

    /// Common DDC/CI input-source codes (VCP 0x60). Monitors mostly follow these; the menu shows the
    /// live code too, so a non-standard panel is still legible.
    static let standardInputs: [(name: String, code: Int)] = [
        ("HDMI 1", 0x11), ("HDMI 2", 0x12), ("DisplayPort 1", 0x0F), ("DisplayPort 2", 0x10),
        ("USB-C", 0x1B), ("DVI", 0x03), ("VGA", 0x01),
    ]

    /// Human label for a DDC input code, or "Code N" if non-standard.
    func inputName(_ code: Int) -> String {
        Self.standardInputs.first { $0.code == code }?.name ?? String(localized: "Code \(code)")
    }

    /// A display OpenDisplay turned off — remembered (and persisted) so it stays visible and
    /// re-enableable even across app restarts, and so the watchdog can always recover it. The type
    /// and its on-disk format live in TopologyCore because the CLI reads the same file: the display
    /// you turned off is exactly the one you may need the CLI to bring back.
    typealias OfflineDisplay = ManagedOfflineDisplay

    /// Count of currently-active REAL displays — the UI disables the off-toggle on the last one.
    /// Excludes macOS's `.virtual` placeholder, which is never a surface the user can see; the
    /// predicate is `WakeConvergencePolicy`'s so the menu, the safety net, and the ledger can never
    /// disagree about what counts as a screen.
    var activeDisplayCount: Int {
        WakeConvergencePolicy.visibleSurfaces(in: displays).count
    }

    /// True when any provider isn't fully supported — drives the menu-bar caution banner.
    var isDegraded: Bool { diagnostics.contains { $0.status != "supported" } }

    private let observer: CoreGraphicsProvider
    private let coordinator: TopologyCoordinator
    private let checkpoints: any CheckpointStoring
    private let lifecycle: any LifecycleProvider
    /// Read-only by default; the experimental SkyLight rotator is selected only when the opt-in toggle
    /// is on (and is compiled out of the public-API-only build entirely). Computed so toggling the
    /// setting takes effect immediately, without a relaunch.
    private var rotationBackend: any RotationBackend {
        #if !PUBLIC_API_ONLY
        if experimentalRotationEnabled { return ExperimentalRotationBackend() }
        #endif
        return ReadOnlyRotationBackend()
    }
    #if !PUBLIC_API_ONLY
    private let brightnessControl = DisplayServicesBrightnessProvider()
    private var ddc: [DisplayRecordID: ExternalDisplayDDC] = [:]
    /// In-flight DDC-controller constructions, so concurrent first-uses of one display await the same
    /// build instead of each spinning up (and binding) a duplicate IOAVService.
    private var ddcBuilders: [DisplayRecordID: Task<ExternalDisplayDDC.Binding, Never>] = [:]
    private var brightnessMax: [DisplayRecordID: Int] = [:]
    private var ddcTarget: [DisplayRecordID: Int] = [:]
    private var ddcWriters: [DisplayRecordID: Task<Void, Never>] = [:]
    private struct DDCControlKey: Hashable { let id: DisplayRecordID; let vcp: UInt8 }
    private var ddcControlMax: [DDCControlKey: Int] = [:]
    private var ddcControlTarget: [DDCControlKey: Int] = [:]
    private var ddcControlWriter: [DDCControlKey: Task<Void, Never>] = [:]
    private var inputSourceTarget: [DisplayRecordID: Int] = [:]
    private var inputSourceWriter: [DisplayRecordID: Task<Void, Never>] = [:]
    private var colorPresetTarget: [DisplayRecordID: Int] = [:]
    private var colorPresetWriter: [DisplayRecordID: Task<Void, Never>] = [:]
    /// Coalesced discrete-mute writes (VCP 0x8D), like every other DDC control.
    private var muteTarget: [DisplayRecordID: Bool] = [:]
    private var muteWriter: [DisplayRecordID: Task<Void, Never>] = [:]
    /// Displays whose audio controls are being probed because a volume key arrived before their
    /// DDC volume was confirmed (TB-02) — one probe at a time per display.
    private var audioProbes: Set<DisplayRecordID> = []
    /// Per-display negative cache of VCP features that repeatedly failed to read, so refresh passes
    /// stop spending ~0.7s of retried I2C on every control the panel doesn't implement (with a
    /// periodic recheck baked into the tracker — see `DDCProbeTracker`). Dropped on disconnect.
    private var ddcProbe: [DisplayRecordID: DDCProbeTracker] = [:]
    /// Adaptive Display (Labs): per-display policy state. Published so the detail card's status
    /// line updates as the loop acts. All decisions live in the pure `AdaptiveDisplayPolicy`.
    @Published private(set) var adaptiveStates: [DisplayRecordID: AdaptiveDisplayPolicy.DisplayState] = [:]
    private var adaptiveLoop: Task<Void, Never>?
    /// App Presets (Issue #33): the pure policy's threaded state (which app's preset is applied, the
    /// debounce window, and the restore ledger). Decisions live in `AppPresetPolicy`; this actor only
    /// observes the frontmost app, reads live values, and applies the writes through the silent DDC
    /// funnels adaptive uses.
    private var appPresetActivation = AppPresetPolicy.ActivationState()
    /// NSWorkspace frontmost-app observer token, held while App Presets is on with ≥1 preset.
    private var appPresetObserver: NSObjectProtocol?
    /// One-shot re-evaluation armed by the policy's `rescheduleAfter` — the debounce timer.
    private var appPresetDebounceTask: Task<Void, Never>?
    /// Displays an app preset currently governs. Adaptive/Clock brightness and warmth skip these so
    /// the app preset stays the last writer (`AppPresetPolicy` precedence, documented + unit-tested).
    private var appPresetActiveDisplays: Set<DisplayRecordID> = []
    private let nightShift = NightShiftStatusReader()
    private let ambientLight = AmbientLightReader()
    /// Clock Mode (Issue #30): one-shot Core Location helper for the "Use current location" button.
    private let clockLocationProvider = ClockLocationProvider()
    /// EMA-smoothed ambient lux (α=0.4 toward the newest sample) so a hand shadow over the sensor
    /// doesn't ripple into DDC writes; nil when the sensor is unreadable (lid closed).
    private var ambientLuxEMA: Double?
    #endif
    /// Display Groups (Issue #39): the pure policy's per-group state (which member currently leads,
    /// at what level, and when it last fanned out). Keyed by `DisplayGroup.id`; session-only, since a
    /// leader event is an interaction, not a setting. The learned offsets it produces DO persist.
    private var groupSyncStates: [UUID: GroupSyncPolicy.GroupSyncState] = [:]
    /// Tags every write OpenDisplay issues itself (a group fan-out, a FaceLight restore) so it never
    /// re-enters `setBrightness` as a leader event — see `GroupSyncPolicy.SyncEcho`.
    private var groupSyncEcho = GroupSyncPolicy.SyncEcho()
    #if !PUBLIC_API_ONLY
    private var groupBrightnessLoop: Task<Void, Never>?
    private var nativeMonitors: [DisplayRecordID: BrightnessMonitor] = [:]
    private var nativeTargets: [DisplayRecordID: Float] = [:]
    private var nativeWriters: [DisplayRecordID: Task<Void, Never>] = [:]
    /// When the poll last saw a native member change — what switches it to the fast cadence.
    private var groupBrightnessLastChange: Date?
    private static let groupBrightnessIdleInterval: TimeInterval = 0.25
    private static let groupBrightnessTrackingInterval: TimeInterval = 0.05
    private static let groupBrightnessTrackingWindow: TimeInterval = 3
    #endif
    /// The coalescing timer behind `persistDisplayGroupsSoon` — one pending disk write for a whole
    /// slider drag, replaced on every tick and flushed on quit.
    private var groupPersistTask: Task<Void, Never>?
    private var hotKeys: [GlobalHotKey] = []
    private var registry: DisplayRegistry?
    private var sceneLibrary: SceneLibrary?
    /// Persisted user settings. Mutated only through the dedicated setters (which also persist and
    /// reconcile side effects), so the on-disk store and any derived state stay in lockstep.
    @Published private(set) var settings: OpenDisplaySettings
    /// On-disk settings store (Application Support); nil only if that directory can't be resolved.
    private let settingsStore: SettingsStore?
    /// Holds the "prevent display idle-sleep" power assertion while the toggle is on and an external
    /// display is present (Issue 3). Decision logic is the platform-independent `DisplaySleepGuard`.
    private let sleepGuard: DisplaySleepGuard
    /// Black click-through overlay windows for the overlay/combined dimming methods. Process-bound —
    /// every overlay disappears with the app, so quit teardown only has the gamma half to restore.
    private let dimOverlay = DimOverlayController()

    /// Pinned favourite resolutions per display (Batch-2 #3), persisted to favorites.json.
    @Published private(set) var favorites = FavoriteResolutions()
    private let favoritesStore: FavoritesStore?
    /// On-disk managed-offline list, shared with the CLI (see `ManagedOfflineStore`).
    private let managedOfflineStore: ManagedOfflineStore?

    /// Sparkle-backed one-click updater (check → download → verify → install → relaunch). Held for the
    /// lifetime of the app because Sparkle references its delegates weakly.
    private let softwareUpdater: SoftwareUpdater
    /// What the update affordances (menu row, About window) should currently say. Mirrored from the
    /// updater so the views observe one published property instead of two objects.
    @Published private(set) var updatePhase: SoftwareUpdatePhase = .idle

    /// Live "Keep these settings?" prompt for an arrangement-altering change (Issue 6), or nil when no
    /// revert window is open. Drives the countdown banner; the UI calls `confirmArrangementChange()` /
    /// `revertArrangementChange()`.
    @Published private(set) var modeChangeError: String?
    private var modeChangeInProgress = false
    @Published private(set) var pendingRevert: PendingRevert?
    /// UI state for the timed auto-revert banner.
    struct PendingRevert: Equatable { var message: String; var secondsRemaining: Int }
    /// Decision core for the open revert window; `before` is the arrangement to restore on timeout.
    private var revertGate: TimedRevertGate<[DisplayObservation]>?
    private var revertMessage = ""
    private var revertTask: Task<Void, Never>?

    /// Edge detector for "auto-disconnect the built-in when an external connects" (Issue 5). Seeded to
    /// the launch topology so a pre-attached external isn't treated as a fresh arrival.
    private var autoDisconnectPolicy = AutoDisconnectBuiltInPolicy()

    /// Native-looking OSD HUD for brightness/volume changes (Batch-3 #4).
    private let osdHUD = OSDHUDController()
    /// Active media-key event tap (Batch-3 #3) when interception is on AND Accessibility is granted.
    private var mediaKeyTap: MediaKeyTap?
    /// Re-arms the media-key tap once the Accessibility grant lands. TCC has no notification API, so
    /// without this poll the user must relaunch the app after granting — the #1 "keys don't work" trap.
    private var mediaKeyTapRetry: Task<Void, Never>?
    /// One system Accessibility prompt per launch, max — reconcile runs on every toggle change and at
    /// init, and re-prompting each time would nag.
    private var promptedForAccessibility = false
    /// Remembered pre-mute DDC volume per display, so a zero-volume mute (monitors without a readable
    /// discrete mute) can restore the prior level. Cleared on unmute and when the user picks a new
    /// level; absent means unmute has nothing truthful to restore (TB-03).
    private var preMuteVolume: [DisplayRecordID: Float] = [:]

    /// Protected Layout (Batch-4 #A): the pure policy's threaded state — which generation the
    /// suppression/debounce/retry counters belong to. Session-only; a relaunch starts clean.
    private var layoutProtectionState = LayoutProtectionPolicy.State()
    /// One-shot re-evaluation armed by the policy's `recheckAfter` — the stability debounce. A
    /// `RecheckTimer` rather than a bare `Task` because the work it fires begins by cancelling the
    /// pending re-check: the timer keeps waiting and working in separate tasks so a debounce-driven
    /// restore can never be running inside the task it just cancelled.
    private let layoutProtectionRecheck = RecheckTimer()

    /// Sleep/wake observer tokens. Held for the app's whole lifetime rather than with a feature
    /// toggle: the managed-offline ledger is re-asserted across a wake whatever else is switched on
    /// (see `WakeConvergencePolicy`), and Protected Layout's wake trigger rides along with them.
    private var sleepWakeObservers: [NSObjectProtocol] = []
    /// When the machine last woke. Inside `WakeConvergencePolicy.defaultWakeWindow` of this, a
    /// display that lights up did so because macOS relit it, not because the user asked.
    private var lastWakeAt: Date?
    /// True between `willSleep` and the matching `didWake` — the gap in which reconfiguration events
    /// arrive before macOS has said the machine woke.
    private var isBetweenSleepAndWake = false
    /// When the app first saw zero visible surfaces in the current dark spell, nil while it can see
    /// one. The always-one-active net's deadline is measured from here.
    private var displaysDarkSince: Date?
    /// Re-assert attempts spent per display in this wake, so the app never fights macOS indefinitely
    /// over one panel. Cleared on every wake.
    private var offlineReassertAttempts: [DisplayRecordID: Int] = [:]
    /// "Look again in a moment" for the always-one-active net, so a display still waking up isn't
    /// mistaken for one that left. A `RecheckTimer` for the same reason Protected Layout uses one:
    /// the work it fires begins by cancelling the pending re-check.
    private let activeSurfaceRecheck = RecheckTimer()
    /// The same, for putting a relit display back off once a real screen is available to cover it.
    private let offlineIntentRecheck = RecheckTimer()

    init() {
        let observer = CoreGraphicsProvider()
        self.observer = observer
        let checkpoints = AppModel.makeCheckpointStore()
        self.checkpoints = checkpoints
        let lifecycle = AppModel.makeLifecycleProvider(public: observer)
        self.lifecycle = lifecycle
        self.coordinator = TopologyCoordinator(
            observer: observer,
            lifecycleProvider: lifecycle,
            checkpoints: checkpoints,
            // A disconnect from the menu/CLI is an explicit user action, so confirm the SafetyEngine's
            // `.needsConfirmation` cases (e.g. turning off the current main). The engine's hard
            // `.blocked` cases — chiefly "this would leave no active display" — are NOT bypassable here.
            confirm: { _, _ in true }
        )
        let settingsStore = (try? SettingsStore.defaultDirectory()).map(SettingsStore.init(directory:))
        self.settingsStore = settingsStore
        let settings = settingsStore?.load() ?? .default
        self.settings = settings
        self.sleepGuard = DisplaySleepGuard(backend: IOKitPowerAssertions())
        let favoritesStore = (try? SettingsStore.defaultDirectory()).map(FavoritesStore.init(directory:))
        self.favoritesStore = favoritesStore
        self.favorites = favoritesStore?.load() ?? FavoriteResolutions()
        self.managedOfflineStore =
            (try? ManagedOfflineStore.defaultDirectory()).map(ManagedOfflineStore.init(directory:))
        // Start Sparkle with the user's saved preferences already in place: its first scheduled cycle
        // begins on the next runloop pass, so applying them later would let one check slip through
        // against the wrong settings.
        self.softwareUpdater = SoftwareUpdater(behavior: AppModel.automaticUpdateBehavior(for: settings))
        softwareUpdater.onPhaseChange = { [weak self] phase in self?.updatePhase = phase }
        softwareUpdater.onAutomaticDownloadPreferenceChange = { [weak self] enabled in
            self?.setAutomaticUpdateDownloadEnabled(enabled)
        }
        // Register the configurable global hotkeys (Batch-2 #4). Reconnect-All is always-available
        // (recovery hierarchy step 3) and reachable even when the menu bar isn't; the rest are unbound
        // by default. A chord that can't be claimed is simply skipped (menu-bar item remains).
        registerHotkeys()
        observeSleepAndWake()  // re-assert what the user turned off once macOS has woken the desk
        reconcileMediaKeyTap()  // Batch-3 #3: arm the media-key tap if enabled + Accessibility granted
        reconcileXDRPowerAutomation()  // Issue #35: watch power only if an XDR battery rule is armed
        if settings.displayNotificationsEnabled { NotificationDelivery.requestAuthorization() }  // Batch-2 #5
        #if DEBUG
        FileHandle.standardError.write(Data("Global hotkeys registered: \(hotKeys.count)\n".utf8))
        #endif
        Task {
            await setUpRegistry()
            await setUpScenes()
            await loadManagedOffline()
            logDisplayEvent("launch")
            await refresh()
            await restoreOwedFaceLightState()  // crash-safe recovery: relaunching mid-FaceLight restores it
            await enforceActiveSurfaceInvariant()  // recover if we launched into a stranded (0-active) state
            await reassertManagedOfflineIntent()  // a stamped owed-"off" survives a relaunch; pay it if covered
            reconcileDisplaySleepGuard()  // hold/release the keep-awake assertion for the launch topology
            #if !PUBLIC_API_ONLY
            reconcileAdaptiveLoop()  // start adaptive brightness/warmth if enabled for this topology
            await restoreOwedAppPresetState()  // crash-safe: relaunch mid-app-preset restores the baseline
            reconcileAppPresetObserver()  // observe the frontmost app if App Presets is enabled
            #endif
            autoDisconnectPolicy.seed(externalPresent: hasExternalDisplay)  // don't treat a pre-attached external as an arrival
            await evaluateLayoutProtection(trigger: .launch)  // Batch-4 #A: check the launch arrangement
            await writeBaselineCheckpoint()
            if let marker = Self.readRotationMarker() {
                // A prior experimental rotation didn't confirm — restore that display's safe angle and
                // a safe layout, then clear the marker.
                try? await rotationBackend.setRotation(marker.safeAngle, for: marker.cgID)
                _ = await coordinator.reconnectAll()
                Self.clearRotationMarker()
                await refresh()
            }
            if let priorArrangement = Self.readRevertMarker() {
                // An arrangement-revert window was open when the app last died — restore the prior
                // mode/origin/mirror/main so a bad resolution or mirror can't survive a crash/quit.
                await restoreArrangement(priorArrangement)
                Self.clearRevertMarker()
            }
            #if DEBUG
            if let token = ProcessInfo.processInfo.environment["OPENDISPLAY_DISCONNECT"] {
                await debugDisconnectCycle(token: token)
            }
            #endif
        }
        Task { await observeTopologyChanges() }
        // ColorSync announces profile assignments made anywhere (System Settings, another app) on
        // the distributed centre (`kColorSyncDeviceProfilesNotification`,
        // `kColorSyncDisplayDeviceProfilesNotification`); the custom-profile safeguard must hear
        // them, not wait for the next topology change.
        for name in ["com.apple.ColorSync.DeviceProfilesNotification", "com.apple.ColorSync.DisplayProfileNotification"] {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refreshCustomProfileGuard() }
            }
        }
        // A software gamma dim persists until logout; restore on quit so it never outlives the app.
        // The keep-awake assertion is process-bound, but release it explicitly so it's gone the instant
        // we quit rather than at process teardown.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            CoreGraphicsProvider.restoreGamma()
            MainActor.assumeIsolated {
                // A group offset learned or dragged in the last second is still only in memory —
                // write it before the process goes away (see `persistDisplayGroupsSoon`).
                self?.flushPendingGroupPersist()
                self?.sleepGuard.releaseAll()
                self?.xdrRampTask?.cancel()
                self?.xdrTrigger.disengage()  // process-bound anyway; one line for tidiness
                self?.xdrAutoOffTimer.cancel()
                self?.xdrPowerMonitor.stop()
                self?.mediaKeyTapRetry?.cancel()
                self?.mediaKeyTap?.stop()
                self?.layoutProtectionRecheck.cancel()
                self?.activeSurfaceRecheck.cancel()
                self?.offlineIntentRecheck.cancel()
                self?.stopObservingSleepAndWake()
                #if !PUBLIC_API_ONLY
                self?.groupBrightnessLoop?.cancel()
                self?.adaptiveLoop?.cancel()
                self?.stopAppPresetObserver()
                #endif
            }
        }
    }

    /// Builds the lifecycle provider: experimental-primary + public-fallback in the full build,
    /// the public provider alone in the public-API-only build.
    private static func makeLifecycleProvider(public publicProvider: CoreGraphicsProvider) -> any LifecycleProvider {
        #if PUBLIC_API_ONLY
        return publicProvider
        #else
        return RoutedLifecycleProvider(primary: ExperimentalLifecycleProvider(), fallback: publicProvider)
        #endif
    }

    /// Persistent, rescue-readable checkpoints in Application Support, falling back to in-memory
    /// only if that directory can't be resolved.
    private static func makeCheckpointStore() -> any CheckpointStoring {
        if let directory = try? DiskCheckpointStore.defaultDirectory() {
            return DiskCheckpointStore(directory: directory)
        }
        return InMemoryCheckpointStore()
    }

    /// Records the current arrangement as a last-known-safe baseline so the rescue utility has
    /// something to restore even before any disconnect runs (PRD §9.4).
    private func writeBaselineCheckpoint() async {
        let snapshot = await observer.currentSnapshot()
        let checkpoint = Checkpoint(
            transactionID: TransactionID(rawValue: "txn_baseline"),
            generation: snapshot.generation,
            observations: snapshot.observations,
            mainDisplayID: snapshot.observations.first(where: { $0.isMain })?.recordID,
            managedOffline: snapshot.managedOffline
        )
        try? await checkpoints.writeAtomic(checkpoint)
    }

    /// A human-readable name for a display: the OS-provided localized name when the display is live
    /// (e.g. "Built-in Retina Display", "S34J55x"), otherwise a class + resolution fallback, and
    /// finally the stable record ID. Identity-resolved aliases land later (PRD D-009).
    func displayName(for observation: DisplayObservation) -> String {
        if let alias = records[observation.recordID]?.alias, !alias.isEmpty {
            return alias
        }
        return osDisplayName(for: observation)
    }

    /// The OS-provided display name (the monitor's product name), ignoring any user alias. Used for
    /// audio-device→display matching: a CoreAudio HDMI/DP output carries the product name, never the
    /// user's OpenDisplay alias, so matching an aliased display ("Desk") against "Dell U2720Q" must go
    /// through this rather than `displayName(for:)`.
    private func osDisplayName(for observation: DisplayObservation) -> String {
        if let screen = observation.cgDisplayID.flatMap(Self.screen(for:)) {
            return screen.localizedName
        }
        if observation.displayClass == .builtIn { return String(localized: "Built-in Display") }
        if let mode = observation.mode {
            // The class word is a fixed English label per `DisplayClass`, looked up in the catalog.
            return "\(observation.displayClass.rawValue.capitalized.appLocalized) · \(mode.pixelWidth)×\(mode.pixelHeight)"
        }
        return observation.recordID.rawValue
    }

    /// The live NSScreen for a CG display id, or nil while it's offline / mid-reconfiguration.
    private static func screen(for cgID: CGDirectDisplayID) -> NSScreen? {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first {
            ($0.deviceDescription[screenNumberKey] as? NSNumber)?.uint32Value == cgID
        }
    }

    /// Where the rescue-readable checkpoints live, shown in Settings → Diagnostics & Recovery.
    var checkpointLocation: String {
        (try? DiskCheckpointStore.defaultDirectory().path) ?? String(localized: "(unavailable)")
    }

    /// The bound global recovery hotkey, shown in Settings.
    let reconnectAllHotkey = "⌃⌥⌘R"

    /// Probes the observation + lifecycle providers and publishes their status for Settings.
    func refreshDiagnostics() async {
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        let environment = ProviderEnvironment(
            osBuild: ProcessInfo.processInfo.operatingSystemVersionString,
            isAppleSilicon: appleSilicon, transport: .unknown, displayClass: .unknown
        )
        let observation = await observer.probe(environment)
        let lifecycleProbe = await lifecycle.probe(environment)
        // Probes are static for a given environment, so republish only when something actually changed
        // (this is read on every topology event to drive the menu-bar "degraded" banner via isDegraded).
        let updated = [
            DisplayDiagnostic(provider: String(localized: "Core Graphics (observation)"), status: observation.status.rawValue,
                              risk: observation.risk.rawValue, experimental: observer.isExperimental,
                              reasons: observation.reasons.map(\.rawValue)),
            DisplayDiagnostic(provider: String(localized: "Lifecycle (disconnect / reconnect)"), status: lifecycleProbe.status.rawValue,
                              risk: lifecycleProbe.risk.rawValue, experimental: lifecycle.isExperimental,
                              reasons: lifecycleProbe.reasons.map(\.rawValue))
        ]
        if diagnostics != updated { diagnostics = updated }
    }

    /// Loads the most recent audit-log entries for Settings → Recent Activity.
    func refreshActivity() async {
        guard let directory = try? DiskAuditLog.defaultDirectory() else { return }
        recentActivity = await DiskAuditLog(directory: directory).recent(limit: 8).reversed()
    }

    private func setUpRegistry() async {
        let store: any RegistryStoring =
            (try? DiskRegistryStore.defaultDirectory()).map { DiskRegistryStore(directory: $0) }
            ?? InMemoryRegistryStore()
        registry = await DisplayRegistry(store: store)
    }

    /// Resolves each live display's fingerprint into the registry (recognizing or minting), so the
    /// menu bar and Settings can show user aliases and remember them across reconnects.
    private func resolveRecords(_ snapshot: TopologySnapshot) async {
        guard let registry else { return }
        let observer = self.observer
        let observations = snapshot.observations.filter { $0.cgDisplayID != nil }
        guard !observations.isEmpty else {
            if !records.isEmpty { records = [:] }
            await refreshRegistryKnownRecords()
            return
        }
        // EDID fingerprint reads are nonisolated CG/IOKit accessors — gather them OFF the main actor,
        // then resolve the whole set in ONE batched (single disk-write) registry call.
        let prepared: [(DisplayRecordID, DisplayFingerprint, String?, DisplayClass)] =
            await Task.detached(priority: .utility) {
                observations.compactMap { obs -> (DisplayRecordID, DisplayFingerprint, String?, DisplayClass)? in
                    guard let cgID = obs.cgDisplayID else { return nil }
                    return (obs.recordID, observer.fingerprint(for: cgID), obs.cgUUID, obs.displayClass)
                }
            }.value
        let resolved = await registry.resolveAll(
            prepared.map { (fingerprint: $0.1, cgUUID: $0.2, displayClass: $0.3) }
        )
        var byID: [DisplayRecordID: DisplayRecord] = [:]
        for (input, record) in zip(prepared, resolved) { byID[input.0] = record }
        records = byID
        await refreshRegistryKnownRecords()
    }

    /// Reloads the remembered-display index (every display the registry has ever minted a record
    /// for, keyed by observation id). Refreshed with `records` and on an empty snapshot alike: a
    /// display that isn't here is precisely the one the Groups card needs this index to name.
    private func refreshRegistryKnownRecords() async {
        guard let registry else { return }
        registryKnownRecords = await registry.recordsByObservationID()
    }

    private func setUpScenes() async {
        let store: any SceneStoring =
            (try? DiskSceneStore.defaultDirectory()).map { DiskSceneStore(directory: $0) }
            ?? InMemorySceneStore()
        let library = await SceneLibrary(store: store)
        sceneLibrary = library
        scenes = await library.all()
    }

    /// Persists the managed-offline list so a turned-off display survives an app restart as a
    /// recoverable off-card (the in-memory-only list was lost on restart, stranding the display),
    /// and so the CLI can see — and reconnect — what the app turned off.
    private func persistManagedOffline() {
        try? managedOfflineStore?.save(managedOffline)
    }

    /// Loads persisted off-displays and reconciles them against the live topology: any that are back
    /// online + active are dropped (they returned on their own); the rest remain as off-cards.
    /// Entries stamped as relit by a wake are kept even while active — the "off" is still owed, the
    /// covering display just hasn't returned yet, and an app restart must not amnesty it.
    private func loadManagedOffline() async {
        guard let saved = managedOfflineStore?.load(), !saved.isEmpty else { return }
        let snapshot = await observer.currentSnapshot()
        let activeIDs = Set(snapshot.activeDisplays.map(\.recordID))
        managedOffline = saved.filter {
            $0.relitDuringWakeAt != nil || !activeIDs.contains($0.recordID)
        }
        if managedOffline != saved { persistManagedOffline() }
    }

    /// Captures the current arrangement as a named scene (upsert by name).
    func saveScene(named name: String) async {
        guard let sceneLibrary else { return }
        let snapshot = await observer.currentSnapshot()
        let id = await sceneLibrary.scene(named: name)?.id ?? "scene_\(UUID().uuidString.prefix(8))"
        let scene = SceneRecorder.capture(from: snapshot, name: name, id: String(id))
        await sceneLibrary.save(scene)
        scenes = await sceneLibrary.all()
    }

    /// Moves a single display to a new origin (used by the drag-to-arrange canvas), then re-reads
    /// the resulting topology (Core Graphics may adjust neighbours to keep the layout adjacent).
    ///
    /// The drop is checked against the topology as it is now, not as the tile was drawn: a display
    /// that has since become a mirror target (an origin write can change its mirror set) or left is
    /// not moved. A rejected write is reported in `arrangementError` instead of being dropped.
    func setPosition(_ origin: DisplayOrigin, for observation: DisplayObservation) async {
        arrangementError = nil
        let snapshot = await observer.currentSnapshot()
        guard ArrangementTiles.canMove(observation.recordID, in: snapshot),
              let cgID = snapshot.observation(for: observation.recordID)?.cgDisplayID else {
            arrangementError = String(localized: "The arrangement changed before the drop, so nothing was moved.")
            await refresh()
            return
        }
        let warnings = observer.applyArrangement([.init(displayID: cgID, origin: origin, mode: nil)])
        if !warnings.isEmpty {
            arrangementError = String(localized: "macOS didn’t accept the new position. The canvas shows the arrangement in effect.")
        }
        await refresh()
        await noteLayoutSelfChange()
    }

    /// Why the last drag on the arrangement canvas didn't move anything; nil after a clean drop.
    @Published private(set) var arrangementError: String?

    /// Mirrors a display onto the main display (both show the same content) or stops mirroring.
    /// Reversible (public Core Graphics mirroring).
    func setMirrored(_ on: Bool, for observation: DisplayObservation) async {
        guard let cgID = observation.cgDisplayID else { return }
        // Reversible and never unreadable, so (like set-main) it applies directly without the revert gate.
        _ = await observer.setMirroring(of: cgID, enabled: on)
        await refresh()
        await noteLayoutSelfChange()
    }

    /// Sets a display's software dim, 1 (none) down toward 0, expressed through the configured
    /// dimming method — gamma table, overlay window, or both. Works on any display.
    func setSoftwareDim(_ level: Float, for observation: DisplayObservation) {
        guard let cgID = observation.cgDisplayID else { return }
        softwareDim[observation.recordID] = level
        applyDim(level: level, id: observation.recordID, cgID: cgID)
    }

    /// Whether the custom-profile safeguard is blocking gamma writes right now: a user/shared
    /// custom ICC profile is assigned to a connected display and the user hasn't overridden it.
    var gammaBlockedByCustomProfile: Bool {
        !customProfileDisplays.isEmpty && !settings.allowGammaWithCustomProfiles
    }

    /// The dimming method in force: the configured one, or the overlay while the safeguard blocks
    /// gamma — the dim keeps working, and the UI says why (`gammaIssueText`).
    var effectiveDimmingMethod: DimmingMethod {
        GammaSlotPolicy.effectiveMethod(settings.dimmingMethod, gammaBlocked: gammaBlockedByCustomProfile)
    }

    /// Expresses one dim level through the effective method's gamma/overlay split. Returns whether
    /// the gamma half is on screen as requested (true when there was nothing to write).
    @discardableResult
    private func applyDim(level: Float, id: DisplayRecordID, cgID: CGDirectDisplayID) -> Bool {
        guard let split = DimmingComposer.application(method: effectiveDimmingMethod,
            desiredLevel: level, blackedOut: blackedOut.contains(id)) else { return true }
        let landed = writeGamma(level: split.gammaLevel, id: id, cgID: cgID)
        dimOverlay.setAlpha(split.overlayAlpha, for: cgID)
        return landed
    }

    /// The gamma half of a display's current software dim under the effective method.
    private func dimGammaLevel(for id: DisplayRecordID) -> Float {
        DimmingComposer.split(method: effectiveDimmingMethod, level: softwareDim[id] ?? 1).gammaLevel
    }

    /// Per-display software colour temperature in kelvin; absent = neutral (calibration untouched).
    /// Session-only, like the software dim — `restoreGamma` on quit clears both.
    @Published private(set) var colorTemperature: [DisplayRecordID: Float] = [:]

    /// Sets the display's software colour temperature and re-expresses the gamma slot, which the
    /// warmth gains share with the dim scale — one formula per display, so both go in together.
    func setColorTemperature(_ kelvin: Float, for observation: DisplayObservation) {
        guard let cgID = observation.cgDisplayID else { return }
        let id = observation.recordID
        // Snap to native near the neutral point so a slider drag can actually land on "untouched".
        colorTemperature[id] = abs(kelvin - ColorTemperatureCurve.neutralKelvin) < 100 ? nil : kelvin
        guard !blackedOut.contains(id) else { return }  // applied when the blackout lifts
        writeGamma(level: dimGammaLevel(for: id), id: id, cgID: cgID)
    }

    /// The one funnel for gamma writes: dim scale × the display's colour-temperature gains × the
    /// XDR boost (Issue #35 — read live here so no caller can silently clear an active boost).
    /// Direct `setGammaDim` calls would silently clear an active warmth — only Black Out (which
    /// wants the neutral floor) bypasses this, through `writeBlackOutGamma`.
    ///
    /// Makes no colour-table call when nothing needs gamma (an identity formula would still replace
    /// the ColorSync calibration — overlay-only dimming must leave it alone), hands the slot back to
    /// ColorSync when OpenDisplay's table is no longer wanted or allowed, and records a rejected
    /// write in `gammaWriteFailures` instead of discarding it. Returns whether the requested gamma
    /// state is on screen.
    @discardableResult
    private func writeGamma(level: Float, id: DisplayRecordID, cgID: CGDirectDisplayID) -> Bool {
        let gains = ColorTemperatureCurve.gains(
            kelvin: colorTemperature[id] ?? ColorTemperatureCurve.neutralKelvin)
        // Headroom is only read while a boost is set — a plain dim/warmth write skips the
        // NSScreen lookup and takes the provider's untouched formula path (boost 1).
        let fraction = xdrBoostFraction[id] ?? 0
        let boost = fraction > 0
            ? XDRBrightnessPolicy.boost(forFraction: fraction, headroom: xdrHeadroom(cgID: cgID))
            : 1
        let needsGamma = GammaSlotPolicy.needsGamma(dim: level, gains: gains, boost: boost)
        switch GammaSlotPolicy.action(needsGamma: needsGamma, owned: gammaOwned.contains(id),
                                      blocked: gammaBlockedByCustomProfile) {
        case .none:
            noteGammaWrite(.success, id: id)
            return true
        case .release:
            releaseGamma(id)
            return !needsGamma
        case .blocked:
            return false
        case .write:
            let result = observer.setGammaAdjustment(
                dim: level, red: gains.red, green: gains.green, blue: gains.blue, boost: boost, for: cgID)
            if result == .success { gammaOwned.insert(id) }
            noteGammaWrite(result, id: id)
            return result == .success
        }
    }

    /// Black Out's gamma half — the floor, which also darkens the menu-bar strip the overlay leaves
    /// visible. Not written (no colour-table call) when dimming is overlay-only or gamma is blocked;
    /// the opaque overlay does the blacking out either way.
    private func writeBlackOutGamma(id: DisplayRecordID, cgID: CGDirectDisplayID) {
        guard effectiveDimmingMethod != .overlay else {
            if gammaOwned.contains(id) { releaseGamma(id) }
            return
        }
        let result = observer.setGammaDim(0.0, for: cgID)
        if result == .success { gammaOwned.insert(id) }
        noteGammaWrite(result, id: id)
    }

    /// Records a gamma write's result: success clears a reported failure, anything else is
    /// surfaced. Republishes only on change — this runs per slider tick.
    private func noteGammaWrite(_ result: CGError, id: DisplayRecordID) {
        if result == .success {
            if gammaWriteFailures[id] != nil { gammaWriteFailures[id] = nil }
        } else if gammaWriteFailures[id] != result.rawValue {
            gammaWriteFailures[id] = result.rawValue
        }
    }

    /// Hands `id`'s gamma slot back to ColorSync — the recovery that restores the profile's own
    /// calibration without touching the user's ICC selection. Core Graphics can only restore every
    /// display at once, so the displays still holding an OpenDisplay table are re-expressed after.
    private func releaseGamma(_ id: DisplayRecordID) {
        gammaOwned.remove(id)
        if gammaWriteFailures[id] != nil { gammaWriteFailures[id] = nil }
        CoreGraphicsProvider.restoreGamma()
        for other in gammaOwned { reexpressSoftwareImage(other) }
    }

    /// Re-expresses a display's whole software image state — dim (gamma + overlay), warmth and
    /// boost, or Black Out — under the current method and safeguard. The overlay window is touched
    /// only when a dim is set: without one it may be FaceLight's warm wash, which a zero-alpha dim
    /// write would remove.
    private func reexpressSoftwareImage(_ id: DisplayRecordID) {
        guard let cgID = displays.first(where: { $0.recordID == id })?.cgDisplayID else {
            gammaOwned.remove(id)
            return
        }
        if blackedOut.contains(id) {
            writeBlackOutGamma(id: id, cgID: cgID)
        } else if let level = softwareDim[id], level < 1 {
            applyDim(level: level, id: id, cgID: cgID)
        } else {
            writeGamma(level: 1, id: id, cgID: cgID)  // warmth and boost only
        }
    }

    /// Re-expresses every display — after the dimming method or the custom-profile safeguard
    /// changed. A display with no software state gets no colour-table call.
    private func reexpressAllSoftwareImages() {
        for display in displays where display.cgDisplayID != nil {
            reexpressSoftwareImage(display.recordID)
        }
    }

    /// Switches the dimming method and re-expresses every display through it, so the slider
    /// positions keep meaning the same darkness — and a switch to overlay-only hands the gamma
    /// table (Black Out's included) back to ColorSync. (A software-brightness fallback dim migrates
    /// too — both layers read from the same per-display level.)
    func setDimmingMethod(_ method: DimmingMethod) {
        guard settings.dimmingMethod != method else { return }
        settings.dimmingMethod = method
        persistSettings()
        reexpressAllSoftwareImages()
    }

    /// The custom-profile safeguard override (Settings › Displays › Dimming). Off by default.
    func setAllowGammaWithCustomProfiles(_ allowed: Bool) {
        guard settings.allowGammaWithCustomProfiles != allowed else { return }
        let wasBlocked = gammaBlockedByCustomProfile
        settings.allowGammaWithCustomProfiles = allowed
        persistSettings()
        if wasBlocked != gammaBlockedByCustomProfile { gammaBlockChanged() }
    }

    /// The safeguard just engaged or lifted. An XDR boost is a gamma table, so an engaged guard
    /// drops it the way the Labs switch does rather than leave its toggle lit over nothing; then
    /// every display is re-expressed under the new rule.
    private func gammaBlockChanged() {
        if gammaBlockedByCustomProfile {
            for display in displays where (xdrBoostFraction[display.recordID] ?? 0) > 0 {
                setXDRBoost(0, for: display)
            }
        }
        reexpressAllSoftwareImages()
    }

    /// Re-reads every connected display's ColorSync assignment (off-main) and, when the safeguard's
    /// verdict changes, re-expresses every display under the new rule: engaging it hands gamma back
    /// to ColorSync and moves dims to the overlay; lifting it puts gamma back where it was wanted.
    func refreshCustomProfileGuard() async {
        // Refresh, profile changes and ColorSync notifications can overlap; only the newest read
        // may decide, or a slower stale one could land last and undo a newer verdict.
        customProfileGuardRead &+= 1
        let read = customProfileGuardRead
        let targets = displays.compactMap { display in display.cgDisplayID.map { (display.recordID, $0) } }
        let readings = await Task.detached(priority: .utility) {
            targets.map { id, cgID in (id, ColorProfileService.assignment(for: cgID)) }
        }.value
        guard read == customProfileGuardRead else { return }
        var classified: [DisplayRecordID: ColorProfileGuard.Assignment] = [:]
        var unreadable: Set<DisplayRecordID> = []
        for (id, assignment) in readings {
            guard let assignment else { unreadable.insert(id); continue }
            if colorProfileAssignment[id] != assignment { colorProfileAssignment[id] = assignment }
            classified[id] = ColorProfileGuard.classify(assignedPath: assignment.customURL?.path,
                                                        factoryPaths: assignment.factoryURLs.map(\.path))
        }
        let blocking = ColorProfileGuard.blockingDisplays(readings: classified, unreadable: unreadable,
                                                          previous: customProfileDisplays)
        guard blocking != customProfileDisplays else { return }
        let wasBlocked = gammaBlockedByCustomProfile
        customProfileDisplays = blocking
        if wasBlocked != gammaBlockedByCustomProfile { gammaBlockChanged() }
    }

    /// Why a display's software image (gamma dim, colour temperature, XDR boost) isn't on screen as
    /// set, or nil when it is: a rejected gamma write, or the custom-profile safeguard pausing gamma.
    func gammaIssueText(for observation: DisplayObservation) -> String? {
        if let code = gammaWriteFailures[observation.recordID] {
            return String(localized: "macOS rejected the gamma change (error \(code)), so it isn’t on screen.")
        }
        guard gammaBlockedByCustomProfile else { return nil }
        let names = displays.filter { customProfileDisplays.contains($0.recordID) }
            .map { displayName(for: $0) }.sorted().joined(separator: ", ")
        return String(localized: "Gamma is paused because \(names) uses a custom colour profile, which can turn a screen black or tinted. Dimming uses the overlay instead; colour temperature and XDR boost are off. Choose a factory profile, or allow gamma with custom profiles in Settings › Displays › Dimming.")
    }

    // MARK: - XDR Brightness (Labs, Issue #35)

    /// Per-display XDR boost fraction (the XDR slider's 0...1 position); absent = off. Session-only
    /// by design — like the software dim, it must never outlive the app, and sustained max
    /// brightness warms the panel, so a relaunch always starts at normal brightness.
    @Published private(set) var xdrBoostFraction: [DisplayRecordID: Float] = [:]
    /// The tiny EDR window that makes WindowServer raise the XDR backlight. Process-bound, like
    /// the dim overlays — a crash tears it down and the backlight relaxes back to SDR on its own.
    private let xdrTrigger = XDRBrightnessController()
    /// Follows the backlight ramp after the trigger engages, re-expressing gamma as headroom
    /// rises. Short-lived (≤ 8 s); replaced on every slider set.
    private var xdrRampTask: Task<Void, Never>?

    /// The power automations' pure state: the fraction a battery-family rule owes back, and when the
    /// live boost was engaged. Session-only like the boost itself — a relaunch starts at normal
    /// brightness, so there is never anything to restore across one.
    private var xdrPowerAutomation = XDRPowerAutomation()
    /// IOKit power-source + Low Power Mode watcher. Held only while XDR Brightness is on AND a
    /// battery-family rule is armed (see `reconcileXDRPowerAutomation`).
    private let xdrPowerMonitor = PowerSourceMonitor()
    /// The last power state read. Seeded on every monitor start, refreshed by the monitor's
    /// callback; while the monitor is stopped every rule that could read it is switched off.
    private var xdrPowerSnapshot = XDRPowerAutomation.PowerSnapshot.onWallPower
    /// Fires the auto-off deadline. A `RecheckTimer` for the reason Protected Layout uses one: the
    /// work it fires re-arms (and therefore cancels) the very timer that scheduled it.
    private let xdrAutoOffTimer = RecheckTimer()

    /// The user's automation settings as the pure policy's `Rules`. Read fresh on every evaluation
    /// so a toggle flipped mid-suspension takes effect on the next pass rather than the next boost.
    private var xdrAutomationRules: XDRPowerAutomation.Rules {
        XDRPowerAutomation.Rules(
            disableOnBattery: settings.xdrDisableOnBattery,
            lowBatteryCutoffPercent: settings.xdrLowBatteryCutoffPercent,
            disableInLowPowerMode: settings.xdrDisableInLowPowerMode,
            autoOffMinutes: settings.xdrAutoOffMinutes,
            restoreOnPower: settings.xdrRestoreOnPower)
    }

    /// Whether the XDR row is offered for `observation`: the Labs toggle is on, it's the built-in
    /// panel, and its screen reports EDR potential beyond SDR (only XDR-class panels do).
    func xdrCapable(_ observation: DisplayObservation) -> Bool {
        guard settings.xdrBrightnessEnabled, observation.displayClass == .builtIn,
              let screen = observation.cgDisplayID.flatMap(Self.screen(for:)) else { return false }
        return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
    }

    /// Sets the XDR boost fraction (0...1) the **user** asked for — the slider, the menu's one-tap
    /// toggle, and the Labs switch turning itself off. Applies it, then tells the power automations
    /// that this fraction is the user's own: their auto-off clock restarts from here, and anything
    /// they were owing is forgotten, so no automation can later overwrite a level the user just
    /// chose with a stale one it remembered.
    ///
    /// Automation writes deliberately do NOT come through here — they call `applyXDRBoost` directly,
    /// so a suspend can't erase the fraction it is saving.
    func setXDRBoost(_ fraction: Float, for observation: DisplayObservation) {
        applyXDRBoost(fraction, for: observation)
        // The applied fraction, not the requested one: a boost asked for on a display that turned
        // out to be offline lands as zero, and the automations must record what actually happened.
        xdrPowerAutomation.noteUserSet(fraction: xdrBoostFraction[observation.recordID] ?? 0, at: Date())
        evaluateXDRPowerAutomation()
    }

    /// The mechanical half of the boost funnel — every boost write, user or automation, ends here.
    /// A positive fraction shows the EDR trigger and starts the ramp follower: the backlight takes
    /// several seconds to reach full headroom, and each tick re-expresses gamma so brightness rides
    /// the ramp up. Zero cancels the follower, drops the trigger, and re-expresses neutral
    /// (boost-1) gamma.
    ///
    /// Zero must land display-or-not, which is why the two directions are split. A boosted panel can
    /// leave CG enumeration while its record lingers in `displays` — a lid-closed or managed-offline
    /// built-in keeps its `DisplayRecordID` with `cgDisplayID == nil`, and `pruneControlCaches` only
    /// forgets the fraction once the record itself goes — and that absence is precisely when the
    /// automation's cleanup rule fires a zero. So zero always clears the session state (fraction,
    /// ramp follower, EDR trigger) and skips only the gamma re-express, the one step that needs a
    /// display to write to; otherwise the stale fraction and its lit menu toggle would outlive the
    /// panel forever, every later evaluation re-deciding the same no-op suspend. A positive fraction
    /// still can't land on a panel that isn't there and returns having changed nothing — `setXDRBoost`
    /// records the *applied* fraction afterward, so the automations see the zero that really happened.
    private func applyXDRBoost(_ fraction: Float, for observation: DisplayObservation) {
        let id = observation.recordID
        let fraction = min(max(fraction, 0), 1)
        guard fraction > 0 else {
            xdrBoostFraction[id] = nil
            xdrRampTask?.cancel()
            xdrRampTask = nil
            xdrTrigger.disengage()
            // Black Out stays the last gamma writer; a departed panel has no gamma to re-express.
            guard let cgID = observation.cgDisplayID, !blackedOut.contains(id) else { return }
            writeGamma(level: dimGammaLevel(for: id), id: id, cgID: cgID)
            return
        }
        guard let cgID = observation.cgDisplayID else { return }  // gone from CG: nothing to boost
        // The boost IS a gamma table: with gamma blocked by the custom-profile safeguard, engaging
        // the EDR trigger would only raise the backlight for content WindowServer then attenuates.
        // Lands as zero, which `setXDRBoost` records; `gammaIssueText` says why.
        guard !gammaBlockedByCustomProfile else { return }
        xdrBoostFraction[id] = fraction
        xdrRampTask?.cancel()
        xdrRampTask = nil
        guard let screen = Self.screen(for: cgID) else {  // offline / mid-reconfig: nothing to boost
            xdrBoostFraction[id] = nil
            return
        }
        xdrTrigger.setEngaged(true, on: screen)
        xdrRampTask = Task { [weak self] in await self?.followXDRRamp(id: id, cgID: cgID) }
    }

    /// One ramp follow: re-express gamma through the funnel (which reads the live headroom) every
    /// 500 ms for the full 8 s window. No early exit on "headroom stopped changing": the OS ramps
    /// the backlight stepwise with flat spots longer than one tick, and bailing at the first
    /// plateau froze the boost at a fraction of the target (observed live: stuck at ×1.21 while
    /// the backlight went on to full headroom). Sixteen formula/table writes over 8 s are cheap.
    /// Skips (and keeps skipping) while Black Out holds the panel at gamma 0.
    private func followXDRRamp(id: DisplayRecordID, cgID: CGDirectDisplayID) async {
        for tick in 0..<16 {
            guard !Task.isCancelled, xdrBoostFraction[id] != nil else { return }
            // Self-heal: if EDR hasn't engaged after ~1.5s the trigger's first frame was lost
            // (e.g. presented mid-window-setup or mid-reconfiguration) — re-present it.
            if tick == 3, xdrHeadroom(cgID: cgID) <= 1.001, let screen = Self.screen(for: cgID) {
                xdrTrigger.setEngaged(true, on: screen)
            }
            if !blackedOut.contains(id) {
                writeGamma(level: dimGammaLevel(for: id), id: id, cgID: cgID)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// The display's live EDR headroom (1 = plain SDR) — what WindowServer is currently
    /// attenuating SDR content by, ramping over several seconds after the trigger engages.
    private func xdrHeadroom(cgID: CGDirectDisplayID) -> Float {
        guard let screen = Self.screen(for: cgID) else { return 1 }
        return Float(screen.maximumExtendedDynamicRangeColorComponentValue)
    }

    /// Toggle for XDR Brightness (Labs). Turning it OFF zeroes every active boost first — through
    /// `setXDRBoost`, so the trigger drops and gamma re-expresses — leaving nothing engaged behind
    /// a disabled toggle.
    func setXDRBrightnessEnabled(_ enabled: Bool) {
        guard settings.xdrBrightnessEnabled != enabled else { return }
        if !enabled {
            for id in xdrBoostFraction.keys {
                guard let observation = displays.first(where: { $0.recordID == id }) else { continue }
                setXDRBoost(0, for: observation)
            }
        }
        settings.xdrBrightnessEnabled = enabled
        persistSettings()
        reconcileXDRPowerAutomation()  // the automations are inert while the feature is off
    }

    // MARK: - XDR power automations (battery / Low Power Mode / auto-off)

    /// Runs the pure policy against the live power state, topology, and boost, and performs whatever
    /// it decides through the same funnel a user's slider uses. Idempotent, so it is safe (and
    /// intended) to call on every power change, Low Power Mode change, topology change, timer fire,
    /// settings change, and manual boost — missing an edge is the only real failure mode.
    private func evaluateXDRPowerAutomation() {
        let boosted = displays.first { xdrBoostFraction[$0.recordID] != nil }
        // "Active", not merely present: a lid-closed built-in can linger in enumeration with the
        // boost's fraction still set, which is exactly the stale state rule 6 exists to clear.
        let builtIn = displays.first { $0.displayClass == .builtIn && $0.isActive }
        let decision = xdrPowerAutomation.evaluate(
            rules: xdrAutomationRules,
            power: xdrPowerSnapshot,
            boostFraction: boosted.flatMap { xdrBoostFraction[$0.recordID] },
            builtInActive: builtIn != nil,
            now: Date())
        switch decision {
        case .none:
            break
        case .suspend(let reason):
            if let boosted { applyXDRBoost(0, for: boosted) }
            postXDRAutomationNotification(reason)
        case .restore(let fraction):
            // The panel has to still be there and still be XDR-capable (which also re-checks the
            // Labs toggle). If it isn't, the suspension is simply dropped — the policy has already
            // forgotten it, and a boost is never owed across a display's absence.
            guard let builtIn, xdrCapable(builtIn) else { break }
            applyXDRBoost(fraction, for: builtIn)
        }
        reconcileXDRPowerAutomation()
    }

    /// Starts or stops the power monitor and arms or cancels the auto-off deadline for the current
    /// settings. Pure setup — it never evaluates, so the evaluate → reconcile → evaluate cycle a
    /// self-refreshing monitor callback would create can't form.
    private func reconcileXDRPowerAutomation() {
        let rules = xdrAutomationRules
        if settings.xdrBrightnessEnabled, rules.needsPowerMonitoring {
            let wasRunning = xdrPowerMonitor.isRunning
            xdrPowerMonitor.start { [weak self] snapshot in
                guard let self else { return }
                self.xdrPowerSnapshot = snapshot
                self.evaluateXDRPowerAutomation()
            }
            // Seed from a fresh read on the way up: a rule enabled while already on battery must act
            // on that, not wait for the next power transition to tell it something it could look up.
            if !wasRunning { xdrPowerSnapshot = PowerSourceMonitor.currentSnapshot() }
        } else {
            xdrPowerMonitor.stop()
            xdrPowerSnapshot = .onWallPower  // no listeners, no readings — don't act on a stale one
        }
        if settings.xdrBrightnessEnabled, let deadline = xdrPowerAutomation.autoOffDeadline(rules: rules) {
            xdrAutoOffTimer.arm(after: deadline.timeIntervalSinceNow) { [weak self] in
                self?.evaluateXDRPowerAutomation()
            }
        } else {
            xdrAutoOffTimer.cancel()
        }
    }

    /// Tells the user why their screen just dimmed, through the existing notifications path and only
    /// when they've turned notifications on. A boost vanishing without explanation is the failure
    /// mode this whole feature would otherwise introduce. Reasons that carry no body (the built-in
    /// going away) stay silent by design — see `SuspensionReason.notificationBody`.
    private func postXDRAutomationNotification(_ reason: XDRPowerAutomation.SuspensionReason) {
        guard settings.displayNotificationsEnabled, reason.notificationBody != nil,
              let note = NotificationDelivery.notification(for: reason) else { return }
        NotificationDelivery.post(note)
    }

    /// Turn an active boost off when the Mac switches to battery power.
    func setXDRDisableOnBattery(_ enabled: Bool) {
        guard settings.xdrDisableOnBattery != enabled else { return }
        settings.xdrDisableOnBattery = enabled
        persistSettings()
        reconcileXDRPowerAutomation()  // start/stop the monitor before anything reads its snapshot
        evaluateXDRPowerAutomation()
    }

    /// Turn an active boost off below this battery percentage (nil = never).
    func setXDRLowBatteryCutoffPercent(_ percent: Int?) {
        let percent = percent.map { min(max($0, 1), 100) }
        guard settings.xdrLowBatteryCutoffPercent != percent else { return }
        settings.xdrLowBatteryCutoffPercent = percent
        persistSettings()
        reconcileXDRPowerAutomation()
        evaluateXDRPowerAutomation()
    }

    /// Turn an active boost off while macOS Low Power Mode is on.
    func setXDRDisableInLowPowerMode(_ enabled: Bool) {
        guard settings.xdrDisableInLowPowerMode != enabled else { return }
        settings.xdrDisableInLowPowerMode = enabled
        persistSettings()
        reconcileXDRPowerAutomation()
        evaluateXDRPowerAutomation()
    }

    /// Turn an active boost off this many minutes after it was engaged (nil = never). Changing it
    /// re-arms against the *existing* engagement, so shortening the limit can expire a boost at once.
    func setXDRAutoOffMinutes(_ minutes: Int?) {
        let minutes = minutes.map { max($0, 1) }
        guard settings.xdrAutoOffMinutes != minutes else { return }
        settings.xdrAutoOffMinutes = minutes
        persistSettings()
        evaluateXDRPowerAutomation()
    }

    /// Put a boost a battery-family rule suspended back when all of those conditions clear.
    func setXDRRestoreOnPower(_ enabled: Bool) {
        guard settings.xdrRestoreOnPower != enabled else { return }
        settings.xdrRestoreOnPower = enabled
        persistSettings()
        evaluateXDRPowerAutomation()  // enabling it can pay a restore that's already owed
    }

    /// Displays currently blacked out (gamma driven to zero — the panel stays logically connected so it
    /// can be restored instantly). Reversible and public-API-safe; gamma also resets on display
    /// reconfiguration, wake, and logout, so a blackout can never strand a surface.
    @Published private(set) var blackedOut: Set<DisplayRecordID> = []

    /// True when the display is currently blacked out.
    func isBlackedOut(_ observation: DisplayObservation) -> Bool {
        blackedOut.contains(observation.recordID)
    }

    /// Toggles Black Out: drive gamma to zero, or restore the display's effective dim level.
    func toggleBlackOut(for observation: DisplayObservation) {
        guard let cgID = observation.cgDisplayID else { return }
        let id = observation.recordID
        if blackedOut.contains(id) {
            blackedOut.remove(id)
            applyDim(level: softwareDim[id] ?? 1.0, id: id, cgID: cgID)
        } else {
            // Never black out the last visible screen: with every panel at gamma 0 there is nothing
            // left to click to undo it (any entry point — menu, hotkey, URL — goes through here).
            let anotherLit = displays.contains {
                $0.recordID != id && $0.isActive && !blackedOut.contains($0.recordID)
            }
            guard anotherLit else { return }
            blackedOut.insert(id)
            writeBlackOutGamma(id: id, cgID: cgID)
            // The provider floors gamma at 0.15 so a dim can never become unreadable; that floor
            // left Black Out at ~15 %. The click-through opaque overlay does the actual blacking
            // out, and lifting it goes through applyDim, which resets the overlay alpha.
            dimOverlay.setAlpha(1, for: cgID)
        }
    }

    /// Read-only display metadata (EDID-derived) for the menu's info panel.
    func displayInfo(for observation: DisplayObservation) -> [(label: String, value: String)] {
        guard let cgID = observation.cgDisplayID else { return [] }
        var info: [(String, String)] = [
            (String(localized: "Name"), displayName(for: observation)),
            (String(localized: "Type"), observation.displayClass == .builtIn
                ? String(localized: "Built-in") : String(localized: "External")),
        ]
        let vendor = CGDisplayVendorNumber(cgID)
        let model = CGDisplayModelNumber(cgID)
        let serial = CGDisplaySerialNumber(cgID)
        if vendor != 0, vendor != 0xFFFF_FFFF { info.append((String(localized: "Vendor"), String(vendor))) }
        if model != 0, model != 0xFFFF_FFFF { info.append((String(localized: "Model"), String(model))) }
        if serial != 0 { info.append((String(localized: "Serial"), String(serial))) }
        if let mode = observation.mode {
            info.append((String(localized: "Work area"),
                         String(localized: "\(mode.pointWidth) × \(mode.pointHeight) logical points")))
            info.append((String(localized: "Framebuffer"),
                         String(localized: "\(mode.pixelWidth) × \(mode.pixelHeight) pixels")))
            info.append((String(localized: "Refresh"), mode.refreshHz > 0
                ? String(format: String(localized: "%.2f Hz"), mode.refreshHz)
                : String(localized: "Not reported by macOS")))
            info.append((String(localized: "Density"), mode.isHiDPI ? "HiDPI" : String(localized: "No HiDPI")))
        }
        let size = CGDisplayScreenSize(cgID)
        if size.width > 0, size.height > 0 {
            let inches = (size.width * size.width + size.height * size.height).squareRoot() / 25.4
            info.append((String(localized: "Size"), String(format: String(localized: "%.1f-inch"), inches)))
        }
        return info
    }

    /// `DisplayModeChoices.label` in the interface language: the same fields in the same order. The
    /// package words it in English only (it also builds on Linux, without catalog lookups), and an
    /// interpolated runtime string can't be looked up afterwards.
    nonisolated static func modeLabel(_ mode: DisplayMode) -> String {
        let hz = mode.refreshHz.formatted(.number.precision(.fractionLength(0...2)))
        let refresh = mode.refreshHz > 0 ? String(localized: "\(hz) Hz") : String(localized: "refresh unknown")
        let density = mode.isHiDPI ? "HiDPI" : String(localized: "no HiDPI")
        let depth = mode.bitDepth.map { bits in " · " + String(localized: "\(bits)-bit") } ?? ""
        return String(localized: "\(mode.pointWidth) × \(mode.pointHeight) pt · framebuffer \(mode.pixelWidth) × \(mode.pixelHeight) px · \(refresh) · \(density)\(depth)")
    }

    /// Applies a saved scene's positions + modes to the current displays (user-triggered).
    func applyScene(_ scene: Scene) async {
        let snapshot = await observer.currentSnapshot()
        var targets: [CoreGraphicsProvider.ArrangementTarget] = []
        var rotationSkipped = false
        for member in scene.members {
            guard let observation = resolveSceneMember(member.selector, in: snapshot),
                  let cgID = observation.cgDisplayID else { continue }
            // Rotation writes aren't safely supported — skip the property but still apply the rest,
            // surfacing a non-fatal note (PRD: scenes apply everything they safely can).
            if let wanted = member.desired.rotation, wanted != observation.rotation { rotationSkipped = true }
            targets.append(.init(displayID: cgID, origin: member.desired.position, mode: member.desired.mode))
        }
        _ = observer.applyArrangement(targets)
        await refresh()
        await noteLayoutSelfChange()
        sceneWarning = rotationSkipped
            ? String(localized: "Applied. Rotation in this scene was skipped — not supported on this macOS version.")
            : nil
    }

    func deleteScene(_ scene: Scene) async {
        guard let sceneLibrary else { return }
        await sceneLibrary.delete(id: scene.id)
        scenes = await sceneLibrary.all()
    }

    /// Resolves a scene member selector to a current observation (id:/alias:/tag:/main/builtin).
    private func resolveSceneMember(_ selector: String, in snapshot: TopologySnapshot) -> DisplayObservation? {
        if selector.hasPrefix("id:") {
            return snapshot.observation(for: DisplayRecordID(rawValue: String(selector.dropFirst("id:".count))))
        }
        if selector.hasPrefix("alias:") {
            let alias = String(selector.dropFirst("alias:".count))
            if let id = records.first(where: { $0.value.alias == alias })?.key { return snapshot.observation(for: id) }
        }
        if selector.hasPrefix("tag:") {
            let tag = String(selector.dropFirst("tag:".count))
            if let id = records.first(where: { $0.value.tags.contains(tag) })?.key { return snapshot.observation(for: id) }
        }
        if selector == "main" { return snapshot.observations.first { $0.isMain } }
        if selector == "builtin" { return snapshot.observations.first { $0.displayClass == .builtIn } }
        return nil
    }

    /// Sets the user alias for a display and re-resolves so the change shows immediately.
    func setAlias(_ alias: String, for observation: DisplayObservation) async {
        guard let registry, let record = records[observation.recordID] else { return }
        await registry.setAlias(alias, for: record.id)
        await refresh()
    }

    /// Drops cached control values (brightness, DDC, ICC, dim) for displays that are no longer present,
    /// so a reconnected display re-reads fresh state instead of showing a stale cached value. Only
    /// reassigns a cache when it actually has a stale key, to avoid needless UI invalidation.
    private func pruneControlCaches(to ids: Set<DisplayRecordID>) {
        if !brightness.keys.allSatisfy(ids.contains) { brightness = brightness.filter { ids.contains($0.key) } }
        if !brightnessMethod.keys.allSatisfy(ids.contains) { brightnessMethod = brightnessMethod.filter { ids.contains($0.key) } }
        if !ddcControlLevel.keys.allSatisfy(ids.contains) { ddcControlLevel = ddcControlLevel.filter { ids.contains($0.key) } }
        if !colorPreset.keys.allSatisfy(ids.contains) { colorPreset = colorPreset.filter { ids.contains($0.key) } }
        if !inputSource.keys.allSatisfy(ids.contains) { inputSource = inputSource.filter { ids.contains($0.key) } }
        if !inputSwitch.keys.allSatisfy(ids.contains) { inputSwitch = inputSwitch.filter { ids.contains($0.key) } }
        if !colorProfileName.keys.allSatisfy(ids.contains) { colorProfileName = colorProfileName.filter { ids.contains($0.key) } }
        if !softwareDim.keys.allSatisfy(ids.contains) { softwareDim = softwareDim.filter { ids.contains($0.key) } }
        if !ddcWriteIgnored.keys.allSatisfy(ids.contains) { ddcWriteIgnored = ddcWriteIgnored.filter { ids.contains($0.key) } }
        if !ddcBindingRefusal.keys.allSatisfy(ids.contains) { ddcBindingRefusal = ddcBindingRefusal.filter { ids.contains($0.key) } }
        if !ddcWriteFailed.keys.allSatisfy(ids.contains) { ddcWriteFailed = ddcWriteFailed.filter { ids.contains($0.key) } }
        if !ddcAudioMuted.keys.allSatisfy(ids.contains) { ddcAudioMuted = ddcAudioMuted.filter { ids.contains($0.key) } }
        if !colorTemperature.keys.allSatisfy(ids.contains) {
            colorTemperature = colorTemperature.filter { ids.contains($0.key) }
        }
        if !xdrBoostFraction.keys.allSatisfy(ids.contains) {
            xdrBoostFraction = xdrBoostFraction.filter { ids.contains($0.key) }
        }
        dimOverlay.reconcile()  // drop overlays for departed displays, re-fit after mode/layout changes
        xdrTrigger.reconcile(screens: NSScreen.screens)  // re-fit / re-present the EDR trigger, drop if its display left
        if !colorProfileControllable.keys.allSatisfy(ids.contains) { colorProfileControllable = colorProfileControllable.filter { ids.contains($0.key) } }
        if !colorProfileAssignment.keys.allSatisfy(ids.contains) { colorProfileAssignment = colorProfileAssignment.filter { ids.contains($0.key) } }
        if !colorProfileError.keys.allSatisfy(ids.contains) { colorProfileError = colorProfileError.filter { ids.contains($0.key) } }
        if !gammaWriteFailures.keys.allSatisfy(ids.contains) { gammaWriteFailures = gammaWriteFailures.filter { ids.contains($0.key) } }
        gammaOwned.formIntersection(ids)  // a departed display's table went with it
        if !blackedOut.allSatisfy(ids.contains) { blackedOut = blackedOut.filter(ids.contains) }
        #if !PUBLIC_API_ONLY
        pruneDDCCaches(to: ids)
        #endif
    }

    #if !PUBLIC_API_ONLY
    /// Releases DDC infrastructure (controllers + their retained IOAVService handles, coalescing maps,
    /// and writer tasks) for displays no longer present, so handles don't accumulate across reconnect
    /// cycles. Writer tasks are cancelled before their controller is dropped so a draining task can't
    /// re-acquire and recreate a removed entry; controllers are lazily rebuilt on next use.
    private func pruneDDCCaches(to ids: Set<DisplayRecordID>) {
        for (id, task) in ddcWriters where !ids.contains(id) { task.cancel(); ddcWriters[id] = nil }
        for (id, task) in inputSourceWriter where !ids.contains(id) { task.cancel(); inputSourceWriter[id] = nil }
        for (id, task) in colorPresetWriter where !ids.contains(id) { task.cancel(); colorPresetWriter[id] = nil }
        for (key, task) in ddcControlWriter where !ids.contains(key.id) { task.cancel(); ddcControlWriter[key] = nil }
        for (id, task) in muteWriter where !ids.contains(id) { task.cancel(); muteWriter[id] = nil }
        muteTarget = muteTarget.filter { ids.contains($0.key) }
        for (id, task) in ddcBuilders where !ids.contains(id) { task.cancel(); ddcBuilders[id] = nil }
        ddc = ddc.filter { ids.contains($0.key) }
        brightnessMax = brightnessMax.filter { ids.contains($0.key) }
        ddcTarget = ddcTarget.filter { ids.contains($0.key) }
        inputSourceTarget = inputSourceTarget.filter { ids.contains($0.key) }
        colorPresetTarget = colorPresetTarget.filter { ids.contains($0.key) }
        ddcControlMax = ddcControlMax.filter { ids.contains($0.key.id) }
        ddcControlTarget = ddcControlTarget.filter { ids.contains($0.key.id) }
        ddcProbe = ddcProbe.filter { ids.contains($0.key) }
        if !adaptiveStates.keys.allSatisfy(ids.contains) {
            adaptiveStates = adaptiveStates.filter { ids.contains($0.key) }
        }
    }
    #endif

    func refresh() async {
        var snapshot = await observer.currentSnapshot()
        // Another display-manager app (e.g. BetterDisplay) holding a reconfiguration can make
        // enumeration transiently empty or error; a Mac running this app always has ≥1 display, so
        // re-poll briefly before trusting an empty list — otherwise the menu blanks out entirely.
        var attempts = 0
        while snapshot.observations.isEmpty && attempts < 8 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            snapshot = await observer.currentSnapshot()
            attempts += 1
        }
        displays = snapshot.observations.sorted { $0.recordID.rawValue < $1.recordID.rawValue }
        pruneControlCaches(to: Set(displays.map(\.recordID)))
        #if !PUBLIC_API_ONLY
        reconcileGroupBrightnessLoop()
        #endif
        // The trigger window has just been re-fitted (or dropped) for the new topology; the boost
        // FRACTION it was paired with is what the automations look after. A built-in that stopped
        // being an active surface — lid closed, clamshell — leaves the fraction set and the slider
        // up on a panel nobody is looking at, so it's cleared here through the normal funnel.
        evaluateXDRPowerAutomation()
        // The start of the current dark spell, stamped here because this is the one place the app
        // looks at the world. The safety net measures its "give up waiting and light something"
        // deadline from it, so it has to survive across the several events a wake emits.
        displaysDarkSince = WakeConvergencePolicy.visibleSurfaces(in: displays).isEmpty
            ? (displaysDarkSince ?? Date())
            : nil
        // A ledger display lit during the wake window gets the wake's stamp before anything can
        // judge it: the window can only attribute the relight while it is open, and the external
        // that must arrive before the "off" can be re-asserted routinely takes longer than the
        // window lasts (it often lights only after the user unlocks). The stamp is what keeps the
        // owed "off" alive past that edge — it decays when the re-assert pays it, not on the clock.
        let stamp = WakeConvergencePolicy.entriesToStampRelit(wakeConvergenceContext())
        if !stamp.isEmpty {
            for index in managedOffline.indices where stamp.contains(managedOffline[index].recordID) {
                managedOffline[index].relitDuringWakeAt = Date()
            }
            persistManagedOffline()
        }
        // Drop any tracked off-display that has come back on its own (e.g. re-enabled elsewhere) —
        // unless we are still inside the wake window, where the same observation means macOS relit
        // it and the entry is the only thing that remembers an "off" is owed.
        let forget = WakeConvergencePolicy.entriesToForget(wakeConvergenceContext())
        if !forget.isEmpty {
            managedOffline.removeAll { forget.contains($0.recordID) }
            persistManagedOffline()
        }
        // Guard against a no-op republish: the active/total count string is usually unchanged across
        // a refresh, and reassigning @Published fires objectWillChange and re-evaluates every view.
        let status = String(localized: "\(snapshot.activeDisplays.count) active · \(snapshot.observations.count) total")
        if statusText != status { statusText = status }
        phase = displays.isEmpty ? .empty : .ready
        await resolveRecords(snapshot)
        await refreshDiagnostics()
        // A display that arrived (or left) can carry a custom profile; the safeguard covers every
        // connected display, so it is re-judged whenever the set might have changed.
        await refreshCustomProfileGuard()
        #if DEBUG
        if ProcessInfo.processInfo.environment["OPENDISPLAY_DUMP"] != nil {
            Self.dump(snapshot)
            let names = displays.map { "cgID=\($0.cgDisplayID ?? 0) → \"\(displayName(for: $0))\"" }
                .joined(separator: ", ")
            FileHandle.standardError.write(Data("names: \(names)\n".utf8))
            if !managedOffline.isEmpty {
                let offline = managedOffline.map { "\($0.name)(cgid:\($0.cgID))" }.joined(separator: ", ")
                FileHandle.standardError.write(Data("managedOffline: \(offline)\n".utf8))
            }
        }
        #endif
    }

    // MARK: - Menu controls (Phase 1)

    /// Available resolutions for a display, de-duplicated per point-size — drives the resolution slider.
    func availableModes(for observation: DisplayObservation) -> [DisplayMode] {
        guard let cgID = observation.cgDisplayID else { return [] }
        return observer.availableModes(for: cgID)
    }

    /// Every mode (un-deduped) for a display — the detail view caches this once per display and filters
    /// it locally for the resolution list, refresh rates, and HiDPI toggle, avoiding three separate
    /// CGDisplayCopyAllDisplayModes enumerations per render.
    func allModes(for observation: DisplayObservation) -> [DisplayMode] {
        guard let cgID = observation.cgDisplayID else { return [] }
        return observer.allModes(for: cgID)
    }

    /// Resolves and caches the best brightness route for a display, then reads its current level:
    /// DisplayServices for the built-in and Apple's externals (`native`), DDC for other externals
    /// (`hardware`), or — when neither answers — software gamma (`software`), which works on any
    /// display including DDC-less externals.
    /// This is what lets the popover show a single, always-usable brightness slider.
    func refreshBrightness(for observation: DisplayObservation) async {
        guard let cgID = observation.cgDisplayID else { return }
        let id = observation.recordID
        if settings.softwareBrightnessDisplayIDs.contains(id.rawValue) {
            brightnessMethod[id] = .software
            brightness[id] = softwareDim[id] ?? 1
            return
        }
        #if !PUBLIC_API_ONLY
        // Apple's own externals (Pro Display XDR, Studio Display) have no DDC; their backlight is
        // driven through DisplayServices exactly like the built-in panel, so they take the native
        // route too. Third-party monitors do NOT, even when the framework claims them: an LG
        // ultrawide was measured answering "can change", accepting writes and reading them back
        // while its real backlight (DDC) never moved. Trusting that would take a working DDC
        // slider and make it do nothing.
        let control = brightnessControl
        let nativeCapable = observation.displayClass == .builtIn
            || (CGDisplayVendorNumber(cgID) == Self.appleDisplayVendorID
                && control.canChangeBrightness(for: cgID))
        if nativeCapable, let value = await Task.detached(priority: .userInitiated, operation: {
            control.brightness(for: cgID)
        }).value {
            guard !settings.softwareBrightnessDisplayIDs.contains(id.rawValue) else { return }
            clearBrightnessDim(id: id, cgID: cgID)
            brightness[id] = value
            brightnessMethod[id] = .native
            return
        }
        // An Apple display whose native read failed gets NO controller here unless the user overrode
        // it for this display (FB-08) — it falls through to software instead of generic DDC probing.
        if observation.displayClass != .builtIn, let controller = await ddcController(for: observation) {
            // The probe tracker keeps a DDC-less external from paying the full retried read
            // (~0.7s) on every refresh before falling back to gamma — after a couple of failures
            // it goes straight to software, rechecking hardware only occasionally. The controller
            // is resolved BEFORE admitProbe: admitProbe is mutating (it spends the periodic
            // recheck token), so consuming it and then bailing on a nil controller would silently
            // push hardware rediscovery a whole recheck interval further out.
            let vcp = ExternalDisplayDDC.Feature.brightness.rawValue
            if ddcProbe[id, default: DDCProbeTracker()].admitProbe(vcp) {
                if let reading = await controller.read(vcp: vcp), reading.max > 0 {
                    guard !settings.softwareBrightnessDisplayIDs.contains(id.rawValue) else { return }
                    ddcProbe[id, default: DDCProbeTracker()].recordSuccess(vcp)
                    // Hardware brightness just (re)appeared — lift any leftover software-gamma dim
                    // from the fallback era, or the two dimming layers stack and the panel stays
                    // dark no matter where the (now hardware) slider sits. Never while Black Out
                    // holds the panel at gamma 0 — a background refresh must not light it up.
                    clearBrightnessDim(id: id, cgID: cgID)
                    brightness[id] = Float(reading.current) / Float(reading.max)
                    brightnessMax[id] = reading.max
                    clearWriteIgnored(vcp, id: id)
                    brightnessMethod[id] = .hardware
                    return
                }
                ddcProbe[id, default: DDCProbeTracker()].recordFailure(vcp)
            }
        }
        #endif
        // Universal fallback: software gamma is public Core Graphics and works on every display.
        brightnessMethod[id] = .software
        brightness[id] = softwareDim[id] ?? 1.0
    }

    /// Apple's PNP vendor id ("APP") as `CGDisplayVendorNumber` reports it.
    private static let appleDisplayVendorID: UInt32 = 0x610

    /// Remove fallback dimming when real backlight control becomes available.
    private func clearBrightnessDim(id: DisplayRecordID, cgID: CGDirectDisplayID) {
        guard let dim = softwareDim[id], dim < 1.0, !blackedOut.contains(id) else { return }
        writeGamma(level: 1.0, id: id, cgID: cgID)
        dimOverlay.remove(for: cgID)
        softwareDim[id] = nil
    }

    /// The caption for a display's brightness slider ("Hardware · DDC", "Software · gamma"), or nil for
    /// native control where no qualifier is needed.
    ///
    /// For software brightness it names the method actually in force (the overlay while the
    /// custom-profile safeguard pauses gamma), says when the slider sits on the software floor —
    /// the lowest level this route applies — and when the gamma half isn't on screen.
    func brightnessCaption(for observation: DisplayObservation) -> String? {
        let id = observation.recordID
        guard brightnessMethod[id] == .software else {
            return brightnessMethod[id]?.caption
        }
        var parts: [String]
        switch effectiveDimmingMethod {
        case .gamma: parts = [String(localized: "Software · gamma")]
        case .overlay: parts = [String(localized: "Software · overlay")]
        case .combined: parts = [String(localized: "Software · combined")]
        }
        // Exactly the floor: that is where this route stops. A lower level can only come from the
        // dimming slider (overlay methods) and is applied as shown, so it gets no note.
        if brightness[id] == DimmingComposer.gammaFloor {
            let floorPercent = Int((DimmingComposer.gammaFloor * 100).rounded())
            parts.append(String(localized: "software minimum \(floorPercent)%"))
        }
        if gammaWriteFailures[id] != nil {
            parts.append(String(localized: "gamma change rejected"))
        } else if gammaBlockedByCustomProfile && settings.dimmingMethod != .overlay {
            parts.append(String(localized: "gamma paused: custom colour profile"))
        }
        return parts.joined(separator: " · ")
    }

    /// Sets a display's brightness (0...1) through whichever route was resolved for it, updating the
    /// cache optimistically. Native and DDC writes are coalesced so a fast slider drag settles in
    /// order without flooding the I2C bus; software uses gamma dimming with a usable floor.
    ///
    /// This is the USER funnel — sliders and media keys — so a write here is what makes a display
    /// its group's leader (Issue #39). `syncToken` marks the write as OpenDisplay's own hand instead
    /// (a group fan-out, a FaceLight restore); those never lead. `origin` says which gesture it was:
    /// only the slider can teach a group offset, keys always lead. `SetBrightnessIntent` does NOT
    /// come through here (it writes DisplayServices/DDC directly); on a natively controlled display
    /// the group picks that change up by observation instead (`pollGroupBrightness`).
    func setBrightness(_ value: Float, for observation: DisplayObservation,
                       syncToken: GroupSyncPolicy.SyncEcho.Token? = nil,
                       origin: GroupSyncPolicy.ManualWrite.Origin = .slider) {
        guard let cgID = observation.cgDisplayID else { return }
        let id = observation.recordID
        #if PUBLIC_API_ONLY
        let method = BrightnessMethod.software
        #else
        let method = settings.softwareBrightnessDisplayIDs.contains(id.rawValue)
            ? BrightnessMethod.software
            : brightnessMethod[id] ?? (observation.displayClass == .builtIn ? .native : .hardware)
        #endif
        // One cache write per tick: the software route stores its floored level below instead.
        if method != .software { brightness[id] = value }
        var onScreen = true
        switch method {
        case .native:
            #if !PUBLIC_API_ONLY
            writeNativeBrightness(value, for: observation)
            #endif
        case .hardware:
            #if !PUBLIC_API_ONLY
            // A user-initiated change on a synced display teaches Adaptive Display: learn the
            // offset (or the schedule adoption anchor in clamshell) and start the cooldown, so
            // adaptive yields instead of fighting the slider. The adaptive loop's own writes go
            // through `applyAdaptiveBrightness`, never here.
            noteManualBrightnessForAdaptive(value, id: id)
            ddcTarget[id] = Int((value * Float(brightnessMax[id] ?? 100)).rounded())
            if ddcWriters[id] == nil {
                ddcWriters[id] = Task { [weak self] in await self?.drainDDCWrites(id, observation) }
            }
            #endif
        case .software:
            // The cache holds what is applied, not the request: the route floors the level, and a
            // slider/OSD showing 5 % over a 15 % image (or keys stepping below the floor unseen)
            // would misreport it. The floor value itself is unchanged.
            let level = DimmingComposer.softwareBrightnessLevel(requested: value)
            brightness[id] = level
            softwareDim[id] = level
            let landed = applyDim(level: level, id: id, cgID: cgID)
            // With gamma as the only carrier a rejected write changed nothing on screen, so no HUD
            // may confirm it; the caption reports the failure instead.
            onScreen = landed || effectiveDimmingMethod != .gamma
        }
        // Batch-3 #4: the HUD confirms key presses; a slider already shows its own value.
        if origin != .slider, onScreen {
            presentOSD(kind: .brightness, value: brightness[id] ?? value, for: observation)
        }
        syncGroupBrightness(value, from: observation, token: syncToken, origin: origin)  // Issue #39
    }

    // MARK: - Display Groups (Issue #39): brightness/contrast fan-out

    #if !PUBLIC_API_ONLY
    /// Poll native group members even when the popover is closed. DisplayServices also sees
    /// brightness changes from macOS keys, System Settings, and automatic brightness.
    ///
    /// The cadence is two-speed: a held brightness key needs ~20 Hz for followers to track it
    /// smoothly, but a group can exist for weeks untouched and a private-IPC read per member twenty
    /// times a second forever is a standing wake-up cost for nothing. So the loop idles slowly and
    /// samples fast only for a short while after it last saw a change.
    private func reconcileGroupBrightnessLoop() {
        let members = Set(settings.displayGroups.filter(\.syncBrightness).flatMap(\.memberRecordIDs))
        let active = Set(displays.filter { $0.isActive && members.contains($0.recordID) }.map(\.recordID))
        nativeMonitors = nativeMonitors.filter { active.contains($0.key) || nativeWriters[$0.key] != nil }
        guard !active.isEmpty else {
            groupBrightnessLoop?.cancel()
            groupBrightnessLoop = nil
            return
        }
        guard groupBrightnessLoop == nil else { return }
        groupBrightnessLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollGroupBrightness()
                let tracking = self.groupBrightnessLastChange.map {
                    Date().timeIntervalSince($0) < Self.groupBrightnessTrackingWindow
                } ?? false
                let interval = tracking ? Self.groupBrightnessTrackingInterval
                                        : Self.groupBrightnessIdleInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func pollGroupBrightness() async {
        for observation in displays where observation.isActive {
            let id = observation.recordID
            guard DisplayGroupStore.isGroupGoverned(id, in: settings.displayGroups),
                  let cgID = observation.cgDisplayID, CGDisplayIsAsleep(cgID) == 0 else { continue }
            if brightnessMethod[id] == nil { await refreshBrightness(for: observation) }
            guard brightnessMethod[id] == .native else { continue }
            let revision = nativeMonitors[id, default: BrightnessMonitor()].revision
            let control = brightnessControl
            let sample = await Task.detached(priority: .utility) { control.brightness(for: cgID) }.value
            guard !Task.isCancelled,
                  displays.contains(where: { $0.recordID == id && $0.cgDisplayID == cgID && $0.isActive }),
                  DisplayGroupStore.isGroupGoverned(id, in: settings.displayGroups),
                  let sample else { continue }
            if nativeMonitors[id, default: BrightnessMonitor()].observe(sample, revision: revision) {
                brightness[id] = sample
                groupBrightnessLastChange = Date()
                // This is already a hardware change. Only write followers, with no duplicate OSD.
                // Observed changes always lead: auto-brightness or a key press is never the user
                // correcting one panel, so it must not teach an offset.
                syncGroupBrightness(sample, from: observation, token: nil, origin: .observed)
            }
        }
    }

    /// Serialize native writes and baseline their readback so polling never echoes our own work.
    private func writeNativeBrightness(_ value: Float, for observation: DisplayObservation) {
        guard let cgID = observation.cgDisplayID else { return }
        let id = observation.recordID
        nativeMonitors[id, default: BrightnessMonitor()].beginWrite()
        nativeTargets[id] = value
        guard nativeWriters[id] == nil else { return }
        nativeWriters[id] = Task { [weak self] in
            guard let self else { return }
            let control = brightnessControl
            var sample: Float?
            while let target = nativeTargets.removeValue(forKey: id) {
                sample = await Task.detached(priority: .userInitiated) {
                    control.setBrightness(target, for: cgID)
                    return control.brightness(for: cgID)
                }.value
            }
            nativeMonitors[id, default: BrightnessMonitor()].endWrite(value: sample)
            nativeWriters[id] = nil
        }
    }
    #endif

    /// Fans a leader's brightness out to the rest of its group, or re-learns a follower's offset when
    /// the write is the user correcting what sync just did. Everything is decided by the pure
    /// `GroupSyncPolicy`; this only reads the world, issues the follower writes through the SILENT
    /// path (no per-follower OSD — the leader already showed one — and no manual-cooldown teaching),
    /// and persists a re-learned offset.
    private func syncGroupBrightness(_ value: Float, from observation: DisplayObservation,
                                     token: GroupSyncPolicy.SyncEcho.Token?,
                                     origin: GroupSyncPolicy.ManualWrite.Origin) {
        let leader = observation.recordID
        guard let group = DisplayGroupStore.group(containing: leader, in: settings.displayGroups)
        else { return }
        let write = GroupSyncPolicy.ManualWrite(value: value, display: leader, token: token,
                                                now: Date(), world: groupSyncWorld(), origin: origin)
        let result = GroupSyncPolicy.classify(write, group: group,
                                              state: groupSyncStates[group.id] ?? .init(),
                                              echo: groupSyncEcho)
        groupSyncStates[group.id] = result.state
        switch result.outcome {
        case .echo, .governed, .syncDisabled:
            return
        case .followerCorrection:
            storeDisplayGroupOffsets(result.group)
        case .leader(let fanOut):
            applyFollowerBrightness(fanOut, leader: leader)
        }
    }

    /// Issues one fan-out's follower writes under an echo token, so a write that finds its way back
    /// into `setBrightness` (a cache-driven binding, a re-entrant slider) can't become a leader event
    /// of its own. The token closes as soon as the writes are queued — the coalescing DDC/gamma
    /// writers own them from there.
    private func applyFollowerBrightness(_ fanOut: GroupSyncPolicy.FanOut, leader: DisplayRecordID) {
        guard !fanOut.isEmpty else { return }
        let token = groupSyncEcho.begin(leader: leader, followers: fanOut.writes.map(\.member))
        for follower in fanOut.writes {
            guard let observation = displays.first(where: { $0.recordID == follower.member })
            else { continue }
            applySilentBrightness(follower.value, for: observation)
        }
        groupSyncEcho.end(token)
    }

    /// A follower's brightness write: same per-member method resolution the user funnel does
    /// (native DisplayServices, coalesced DDC, or software gamma), with no OSD and no adaptive note.
    private func applySilentBrightness(_ value: Float, for observation: DisplayObservation) {
        guard let cgID = observation.cgDisplayID else { return }
        let id = observation.recordID
        #if PUBLIC_API_ONLY
        let method = BrightnessMethod.software
        #else
        let method = settings.softwareBrightnessDisplayIDs.contains(id.rawValue)
            ? BrightnessMethod.software
            : brightnessMethod[id] ?? (observation.displayClass == .builtIn ? .native : .hardware)
        #endif
        // Keep the visible slider honest — the software route caches its floored level below.
        if method != .software { brightness[id] = value }
        switch method {
        case .native:
            #if !PUBLIC_API_ONLY
            writeNativeBrightness(value, for: observation)
            #endif
        case .hardware:
            #if !PUBLIC_API_ONLY
            applyAdaptiveBrightness(value, for: observation)  // the existing coalesced DDC writer
            #endif
        case .software:
            // Same as the user funnel: cache the floored level that is applied.
            let level = DimmingComposer.softwareBrightnessLevel(requested: value)
            brightness[id] = level
            softwareDim[id] = level
            applyDim(level: level, id: id, cgID: cgID)
        }
    }

    /// Fans a leader's contrast out to the rest of its group — a flat mirror with no offset learning
    /// (`GroupSyncPolicy.contrastFanOut`), skipping members whose panel reports no contrast channel.
    private func syncGroupContrast(_ value: Float, from observation: DisplayObservation) {
        #if !PUBLIC_API_ONLY
        let leader = observation.recordID
        guard let group = DisplayGroupStore.group(containing: leader, in: settings.displayGroups)
        else { return }
        let write = GroupSyncPolicy.ManualWrite(value: value, display: leader, now: Date(),
                                                world: groupSyncWorld())
        let fanOut = GroupSyncPolicy.contrastFanOut(write, group: group, echo: groupSyncEcho)
        guard !fanOut.isEmpty else { return }
        let token = groupSyncEcho.begin(leader: leader, followers: fanOut.writes.map(\.member))
        for follower in fanOut.writes {
            guard let target = displays.first(where: { $0.recordID == follower.member }) else { continue }
            setHardwareControl(.contrast, follower.value, for: target, isGroupSync: true)
        }
        groupSyncEcho.end(token)
        #endif
    }

    /// The world one group decision sees: which members are usable right now, which a
    /// higher-precedence writer owns (FaceLight, an app preset), and which have a contrast channel.
    private func groupSyncWorld() -> GroupSyncPolicy.World {
        let present = displays.filter(\.isActive).map(\.recordID)
        // The persisted FaceLight/app-preset ledgers (shared with the CLI's fan-out), plus the app's
        // own live preset set — which is ahead of the ledger for a preset applied this instant.
        var governed = GroupSyncPolicy.governedDisplays(in: settings)
        #if !PUBLIC_API_ONLY
        governed.formUnion(appPresetActiveDisplays)
        #endif
        // A contrast level in the cache IS the probe's verdict that the channel works — the same
        // signal `toggleFaceLight` uses to decide whether a display gets a contrast write at all.
        let contrastCapable = present.filter { ddcControlLevel[$0]?[HardwareControl.contrast.vcp] != nil }
        return GroupSyncPolicy.World(present: Set(present), governed: governed,
                                     contrastCapable: Set(contrastCapable))
    }

    /// Hands a display its own prior brightness back without leading its group. Restores (FaceLight,
    /// an app preset leaving) are the machine undoing itself, not the user reaching for a slider —
    /// fanning one out would drag the whole group to a value nobody asked for.
    private func restoreBrightnessWithoutLeading(_ value: Float, for observation: DisplayObservation) {
        let token = groupSyncEcho.begin(leader: observation.recordID)
        setBrightness(value, for: observation, syncToken: token)
        groupSyncEcho.end(token)
    }

    /// Stores one group's re-learned offsets back into settings (the offsets persist; the leader
    /// state that produced them is session-only). In memory immediately — the next fan-out reads the
    /// new offset — with the disk write coalesced, since a correction arrives once per slider tick.
    private func storeDisplayGroupOffsets(_ group: DisplayGroup) {
        settings.displayGroups = DisplayGroupStore.update(group, in: settings.displayGroups)
        persistDisplayGroupsSoon()
    }

    /// Coalesces the settings write behind a learned or hand-set group offset. Offsets change at
    /// slider-tick rate, and `persistSettings` is a synchronous whole-file JSON encode on the main
    /// actor — one per tick is disk spam mid-drag, the same reason the adaptive learned offsets
    /// persist at tick-time rather than per slider move. The in-memory value is authoritative the
    /// instant it is set; the disk catches up `groupPersistDelay` after the hand stops (or at quit,
    /// via the `willTerminate` flush).
    private func persistDisplayGroupsSoon() {
        groupPersistTask?.cancel()
        groupPersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.groupPersistDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flushPendingGroupPersist()
        }
    }

    /// Writes a pending coalesced group-offset change out now. Idempotent: with nothing pending it
    /// just re-saves the settings we already hold.
    private func flushPendingGroupPersist() {
        groupPersistTask?.cancel()
        groupPersistTask = nil
        persistSettings()
    }

    /// How long the coalescing timer waits. Comfortably longer than the gap between two slider ticks
    /// and short enough that a change is on disk before anyone reaches for the power button.
    private static let groupPersistDelay: TimeInterval = 1.5

    #if !PUBLIC_API_ONLY
    /// Returns (and caches) the DDC controller for an external display, building it OFF the main actor
    /// — `ExternalDisplayDDC.init` does `dlopen` + IOKit registry enumeration, which must not run on
    /// the UI thread when a display row first expands. Concurrent first-uses await one shared build,
    /// so a display can't end up with two bound IOAVService handles.
    ///
    /// A refused binding (Apple display without the override, or a service identity can't single
    /// out — TR-06/FB-08) yields nil like a missing channel, so every DDC path sends nothing; the
    /// reason is published in `ddcBindingRefusal` for the UI.
    private func ddcController(for observation: DisplayObservation) async -> ExternalDisplayDDC? {
        let id = observation.recordID
        if let existing = ddc[id] { return existing }
        if let building = ddcBuilders[id] { return await building.value.controller }
        guard let cgID = observation.cgDisplayID else { return nil }
        let allowApple = settings.ddcAppleDisplayOverrideIDs.contains(id.rawValue)
        let builder = Task.detached(priority: .utility) {
            ExternalDisplayDDC.bind(displayID: cgID, allowAppleDisplay: allowApple)
        }
        ddcBuilders[id] = builder
        let binding = await builder.value
        ddcBuilders[id] = nil
        // Built under an Apple-display override the user has since flipped: the result answers the
        // old question, so neither cache nor use it (FB-08 — turning the override off must stick).
        guard settings.ddcAppleDisplayOverrideIDs.contains(id.rawValue) == allowApple else { return nil }
        let refusal = binding.refusal
        if ddcBindingRefusal[id] != refusal { ddcBindingRefusal[id] = refusal }
        if let controller = binding.controller { ddc[id] = controller }
        return binding.controller
    }

    private func drainDDCWrites(_ id: DisplayRecordID, _ observation: DisplayObservation) async {
        guard let controller = await ddcController(for: observation) else { ddcWriters[id] = nil; return }
        let vcp = ExternalDisplayDDC.Feature.brightness.rawValue
        while !Task.isCancelled && !settings.softwareBrightnessDisplayIDs.contains(id.rawValue) {
            var lastTarget: Int?
            while !Task.isCancelled, !settings.softwareBrightnessDisplayIDs.contains(id.rawValue), let target = ddcTarget[id] {
                ddcTarget[id] = nil
                lastTarget = target
                await controller.write(.brightness, target)
            }
            guard let lastTarget else { break }
            switch await readBackAfterDrain(controller, vcp: vcp, settleNanos: Self.continuousSettleNanos,
                                            superseded: { [weak self] in self?.ddcTarget[id] != nil }) {
            case .cancelled: return  // pruned: the map entry is already gone, don't touch state
            case .superseded: continue  // a newer target arrived; write it, verify that one instead
            case .reading(let reading):
                let outcome = DDCWriteVerification.outcome(
                    target: lastTarget, readback: reading?.current, tolerance: 1)
                noteWriteVerification(outcome, vcp: vcp, id: id)
                if case .ignored(let actual) = outcome, let reading, reading.max > 0,
                   brightnessMethod[id] == .hardware {
                    brightness[id] = Float(actual) / Float(reading.max)
                }
            }
            break
        }
        ddcWriters[id] = nil
    }

    /// Settle time between a coalesced writer's LAST write and its verification read. Panels apply a
    /// Set-VCP asynchronously; reading back immediately can return the pre-write value and report a
    /// good write as ignored. Colour presets get longer — a mode switch reprograms the scaler's whole
    /// colour pipeline and some panels keep answering with the old code for a beat.
    private static let continuousSettleNanos: UInt64 = 250_000_000
    private static let presetSettleNanos: UInt64 = 1_000_000_000

    /// What the post-drain read-back saw.
    private enum DrainReadBack {
        /// The writer task was cancelled (display pruned) — abandon without touching any state.
        case cancelled
        /// A newer target was queued while settling/reading — the user is still moving; verify later.
        case superseded
        /// The panel's answer (nil = no reply, which `DDCWriteVerification` treats as unknown).
        case reading((current: Int, max: Int)?)
    }

    /// Verify-after-write for the coalesced DDC writers. Called once the target map is EMPTY (the user
    /// stopped dragging), never per tick, so a drag costs one read total — not one per step. The DDC
    /// actor serialises the read behind any in-flight write; `superseded` is re-checked on both sides
    /// of each await because the main actor is free to queue new targets while we're suspended.
    private func readBackAfterDrain(_ controller: ExternalDisplayDDC, vcp: UInt8, settleNanos: UInt64,
                                    superseded: () -> Bool) async -> DrainReadBack {
        try? await Task.sleep(nanoseconds: settleNanos)
        if Task.isCancelled { return .cancelled }
        if superseded() { return .superseded }
        let reading = await controller.read(vcp: vcp)
        if Task.isCancelled { return .cancelled }
        if superseded() { return .superseded }
        return .reading(reading)
    }

    /// Records a read-back verdict in `ddcWriteIgnored`. `.unknown` (no reply) changes nothing: a
    /// flaky read is not evidence either way, so neither a fresh nor a stale "ignored" note moves.
    private func noteWriteVerification(_ outcome: DDCWriteVerification, vcp: UInt8, id: DisplayRecordID) {
        switch outcome {
        case .applied: clearWriteIgnored(vcp, id: id)
        case .ignored: ddcWriteIgnored[id, default: []].insert(vcp)
        case .unknown: break
        }
    }

    /// Drops the "ignored" and "write failed" notes for one feature — a verified write or a fresh
    /// successful read means the cache reflects the panel again. Only touches a published map when
    /// there's a note to drop.
    private func clearWriteIgnored(_ vcp: UInt8, id: DisplayRecordID) {
        if ddcWriteFailed[id]?.contains(vcp) == true {
            ddcWriteFailed[id]?.remove(vcp)
            if ddcWriteFailed[id]?.isEmpty == true { ddcWriteFailed[id] = nil }
        }
        guard ddcWriteIgnored[id]?.contains(vcp) == true else { return }
        ddcWriteIgnored[id]?.remove(vcp)
        if ddcWriteIgnored[id]?.isEmpty == true { ddcWriteIgnored[id] = nil }
    }

    /// Records the transport result of a drain's LAST write next to its read-back verdict (TB-02).
    /// Only a failed write with no read-back is a failure note: when the panel answered, its answer
    /// (applied / ignored) is the better evidence and `noteWriteVerification` already recorded it.
    private func noteWriteTransport(sent: Bool, outcome: DDCWriteVerification, vcp: UInt8, id: DisplayRecordID) {
        if outcome != .unknown {
            if ddcWriteFailed[id]?.contains(vcp) == true {
                ddcWriteFailed[id]?.remove(vcp)
                if ddcWriteFailed[id]?.isEmpty == true { ddcWriteFailed[id] = nil }
            }
        } else if !sent {
            ddcWriteFailed[id, default: []].insert(vcp)
        }
    }
    #endif

    /// True when the last DDC write to `vcp` on this display failed at the transport (see `ddcWriteFailed`).
    func ddcWriteDidFail(_ vcp: UInt8, for observation: DisplayObservation) -> Bool {
        ddcWriteFailed[observation.recordID]?.contains(vcp) == true
    }

    /// True when the panel ignored the last DDC write to `vcp` on this display (see `ddcWriteIgnored`).
    func ddcWriteWasIgnored(_ vcp: UInt8, for observation: DisplayObservation) -> Bool {
        ddcWriteIgnored[observation.recordID]?.contains(vcp) == true
    }

    /// Cached level (0...1) of a DDC hardware control, or nil if the display doesn't report it.
    func ddcControl(_ control: HardwareControl, for observation: DisplayObservation) -> Float? {
        ddcControlLevel[observation.recordID]?[control.vcp]
    }

    /// Forgets the DDC negative-probe cache for one display (or all). Called when the world may have
    /// changed under the cache — a topology event (hotplug, wake, monitor power-cycle) or the user
    /// deliberately opening a display's detail pane — so a monitor whose DDC just came back (e.g.
    /// power-cycled out of a wedged scaler state) regains hardware control on the *next* refresh
    /// instead of waiting out the tracker's periodic recheck. The menu-bar popover keeps using the
    /// cache, so the cheap fast path stays cheap.
    func resetDDCProbeCache(for id: DisplayRecordID? = nil) {
        #if !PUBLIC_API_ONLY
        if let id { ddcProbe[id] = nil } else { ddcProbe = [:] }
        #endif
    }

    /// Pane-open variant of `resetDDCProbeCache`: forgets the negative cache ONLY when the display
    /// currently shows no working hardware control at all. A healthy display keeps its knowledge —
    /// wiping it on every pane open would re-pay the full probe ladder (~0.75s per absent feature,
    /// serially) each time; a fully-dead one is exactly the recovery case the reset exists for
    /// (monitor power-cycled out of a wedged state), and there the re-probe cost was being paid
    /// anyway. The tracker's periodic recheck covers the in-between (some controls lost, not all).
    func retryDDCDiscoveryIfDead(for observation: DisplayObservation) {
        #if !PUBLIC_API_ONLY
        let id = observation.recordID
        let hasWorkingControl = !(ddcControlLevel[id] ?? [:]).isEmpty || brightnessMethod[id] == .hardware
        if !hasWorkingControl { ddcProbe[id] = nil }
        #endif
    }

    /// Whether the display advertises a VCP feature in its DDC capabilities (Batch-2 #1). **Fail-open:**
    /// if capabilities haven't been read (or the panel didn't return any), returns true so nothing is
    /// hidden just because discovery hasn't happened — capabilities only ever *remove* dead controls.
    func ddcSupports(_ vcp: UInt8, for observation: DisplayObservation) -> Bool {
        guard let caps = ddcCapabilities[observation.recordID] else { return true }
        return caps.supports(vcp)
    }

    /// Reads + caches the display's DDC capabilities string (VCP 0xF3) once per external display.
    ///
    /// ⚠️ EXPLICIT / DIAGNOSTIC USE ONLY — do NOT call from the control-refresh path. The multi-chunk
    /// `0xF3` read desynchronizes DDC/CI on some panels (Samsung S34J55x: it leaves the panel replaying a
    /// stale reply buffer so every later read returns garbage and writes are ignored until a power-cycle).
    /// Controls are fail-open without it (`ddcSupports` returns true when uncached), so the only thing
    /// lost by not calling this is hiding genuinely-unsupported controls.
    func refreshCapabilities(for observation: DisplayObservation) async {
        #if !PUBLIC_API_ONLY
        guard observation.displayClass != .builtIn, ddcCapabilities[observation.recordID] == nil,
              let controller = await ddcController(for: observation),
              let raw = await controller.readCapabilitiesString(),
              let caps = DDCCapabilities.parse(raw) else { return }
        ddcCapabilities[observation.recordID] = caps
        #endif
    }

    /// Reads every hardware (DDC) control for an external display into the cache. Skips the built-in,
    /// anything the capabilities string says is unsupported (when known — `ddcSupports` is fail-open),
    /// and any feature the panel doesn't read back. No-op in the public-API-only build.
    ///
    /// NOTE: this deliberately does NOT auto-read the `0xF3` capabilities string. That multi-chunk read
    /// desynchronizes DDC/CI on some panels (e.g. Samsung S34J55x), wedging *all* subsequent reads — it
    /// is now an explicit, diagnostic-only path (CLI `ddc … caps`). See `refreshCapabilities`.
    func refreshHardwareControls(for observation: DisplayObservation) async {
        #if !PUBLIC_API_ONLY
        guard observation.displayClass != .builtIn, let controller = await ddcController(for: observation) else { return }
        for control in HardwareControl.allCases {
            await readHardwareControl(control, controller: controller, observation: observation)
        }
        await refreshDiscreteMute(controller, observation: observation)
        #endif
    }

    #if !PUBLIC_API_ONLY
    /// One probe-gated read of a hardware control into the cache (see `refreshHardwareControls`).
    private func readHardwareControl(_ control: HardwareControl, controller: ExternalDisplayDDC,
                                     observation: DisplayObservation) async {
        let id = observation.recordID
        let vcp = control.vcp
        guard ddcSupports(vcp, for: observation),
              ddcProbe[id, default: DDCProbeTracker()].admitProbe(vcp) else { return }
        if let reading = await controller.read(vcp: vcp), reading.max > 0 {
            ddcProbe[id, default: DDCProbeTracker()].recordSuccess(vcp)
            ddcControlLevel[id, default: [:]][vcp] = Float(reading.current) / Float(reading.max)
            ddcControlMax[DDCControlKey(id: id, vcp: vcp)] = reading.max
            clearWriteIgnored(vcp, id: id)
        } else {
            ddcProbe[id, default: DDCProbeTracker()].recordFailure(vcp)
        }
    }

    /// Reads the monitor's discrete mute (VCP 0x8D) — only for a monitor whose volume reads, since
    /// mute means nothing without speakers and every absent feature costs a retried read until the
    /// probe tracker caches it. A reply that isn't 1 (muted) / 2 (unmuted) is not a usable mute
    /// (TB-03); a failed read keeps the last known state (one flaky read isn't evidence).
    private func refreshDiscreteMute(_ controller: ExternalDisplayDDC, observation: DisplayObservation) async {
        let id = observation.recordID
        let vcp = Self.ddcAudioMuteVCP
        guard ddcControlLevel[id]?[HardwareControl.volume.vcp] != nil, muteWriter[id] == nil,
              ddcProbe[id, default: DDCProbeTracker()].admitProbe(vcp) else { return }
        guard let reading = await controller.read(vcp: vcp) else {
            ddcProbe[id, default: DDCProbeTracker()].recordFailure(vcp)
            return
        }
        if let muted = DDCAudioPolicy.discreteMuteState(fromVCPValue: reading.current) {
            ddcProbe[id, default: DDCProbeTracker()].recordSuccess(vcp)
            if ddcAudioMuted[id] != muted { ddcAudioMuted[id] = muted }
            clearWriteIgnored(vcp, id: id)
        } else {
            ddcProbe[id, default: DDCProbeTracker()].recordFailure(vcp)
            ddcAudioMuted[id] = nil
        }
    }
    #endif

    /// Sets a DDC hardware control (0...1), updating the cache optimistically and coalescing the
    /// I2C writes the same way brightness does. `isGroupSync` marks a write this model is fanning out
    /// on a group's behalf, so it doesn't mirror straight back (Issue #39).
    func setHardwareControl(_ control: HardwareControl, _ value: Float,
                            for observation: DisplayObservation, isGroupSync: Bool = false,
                            showsOSD: Bool = true) {
        #if !PUBLIC_API_ONLY
        guard observation.displayClass != .builtIn else { return }
        let id = observation.recordID
        let key = DDCControlKey(id: id, vcp: control.vcp)
        ddcControlLevel[id, default: [:]][control.vcp] = value
        // A level the user picks replaces the one a zero-volume mute remembered (TB-03): unmute must
        // not later jump back to a stale level.
        if control == .volume, value > 0 { preMuteVolume[id] = nil }
        ddcControlTarget[key] = Int((value * Float(ddcControlMax[key] ?? 100)).rounded())
        if ddcControlWriter[key] == nil {
            ddcControlWriter[key] = Task { [weak self] in await self?.drainHardwareWrites(key, control, observation) }
        }
        if control == .volume, showsOSD { presentOSD(kind: .volume, value: value, for: observation) }  // Batch-3 #4
        if control == .contrast, !isGroupSync { syncGroupContrast(value, from: observation) }  // Issue #39
        #endif
    }

    #if !PUBLIC_API_ONLY
    private func drainHardwareWrites(_ key: DDCControlKey, _ control: HardwareControl, _ observation: DisplayObservation) async {
        guard let controller = await ddcController(for: observation) else { ddcControlWriter[key] = nil; return }
        while true {
            var lastTarget: Int?
            var lastSent = true
            while let target = ddcControlTarget[key] {
                ddcControlTarget[key] = nil
                lastTarget = target
                lastSent = await controller.write(vcp: key.vcp, target)
            }
            guard let lastTarget else { break }
            switch await readBackAfterDrain(controller, vcp: key.vcp, settleNanos: Self.continuousSettleNanos,
                                            superseded: { [weak self] in self?.ddcControlTarget[key] != nil }) {
            case .cancelled: return
            case .superseded: continue
            case .reading(let reading):
                let outcome = DDCWriteVerification.outcome(
                    target: lastTarget, readback: reading?.current, tolerance: 1)
                noteWriteVerification(outcome, vcp: key.vcp, id: key.id)
                noteWriteTransport(sent: lastSent, outcome: outcome, vcp: key.vcp, id: key.id)
                // Snap the slider to where the panel actually is, so it stops showing a level the
                // monitor isn't at (LG: contrast 40 written, panel stays at 18/70).
                if case .ignored(let actual) = outcome, let reading, reading.max > 0 {
                    ddcControlLevel[key.id, default: [:]][key.vcp] = Float(actual) / Float(reading.max)
                    ddcControlMax[key] = reading.max
                }
            }
            break
        }
        ddcControlWriter[key] = nil
    }
    #endif

    /// Reads the external display's current DDC input source into the cache.
    func refreshInputSource(for observation: DisplayObservation) async {
        #if !PUBLIC_API_ONLY
        let id = observation.recordID
        let vcp = ExternalDisplayDDC.Feature.inputSource.rawValue
        // Controller before admitProbe — admitProbe spends the periodic recheck token (see
        // refreshBrightness), so it must only run when a probe can actually happen.
        guard observation.displayClass != .builtIn,
              let controller = await ddcController(for: observation),
              ddcProbe[id, default: DDCProbeTracker()].admitProbe(vcp) else { return }
        guard let reading = await controller.read(vcp: vcp) else {
            ddcProbe[id, default: DDCProbeTracker()].recordFailure(vcp)
            return
        }
        ddcProbe[id, default: DDCProbeTracker()].recordSuccess(vcp)
        inputSource[id] = reading.current
        // A fresh report supersedes the note about the last finished request; one still being
        // written keeps its "switching…" note.
        if let request = inputSwitch[id], request.status != .sending { inputSwitch[id] = nil }
        #endif
    }

    /// Switches the external display's DDC input source to `code` (e.g. HDMI/DisplayPort). User-driven.
    /// Coalesced through a single per-display writer (like brightness/contrast) so rapid selections
    /// settle the panel on the last choice and can't reorder on the shared I2C bus.
    ///
    /// The request is tracked in `inputSwitch`; `inputSource` (the reported input, i.e. the menu's
    /// checkmark) is NOT set to the request (AM-05): a rejected write would otherwise look like a
    /// confirmed switch. See `DDCInputSwitch.reportedInput` for what a finished write does to it.
    func setInputSource(_ code: Int, for observation: DisplayObservation) {
        #if !PUBLIC_API_ONLY
        guard observation.displayClass != .builtIn else { return }
        let id = observation.recordID
        inputSwitch[id] = DDCInputSwitch(requested: code, status: .sending)
        inputSourceTarget[id] = code
        if inputSourceWriter[id] == nil {
            inputSourceWriter[id] = Task { [weak self] in await self?.drainInputSourceWrites(id, observation) }
        }
        #endif
    }

    #if !PUBLIC_API_ONLY
    private func drainInputSourceWrites(_ id: DisplayRecordID, _ observation: DisplayObservation) async {
        guard let controller = await ddcController(for: observation) else {
            if let target = inputSourceTarget[id] { noteInputSwitch(.notSent, requested: target, id: id) }
            inputSourceTarget[id] = nil
            inputSourceWriter[id] = nil
            return
        }
        while let target = inputSourceTarget[id] {
            inputSourceTarget[id] = nil
            let outcome = DDCCommandOutcome(transportAccepted: await controller.write(.inputSource, target))
            if Task.isCancelled { return }  // pruned: the display is gone, don't touch its state
            noteInputSwitch(outcome, requested: target, id: id)
        }
        inputSourceWriter[id] = nil
    }

    /// Records a finished input write: the reported input per `DDCInputSwitch.reportedInput`, and the
    /// request note — unless a newer request is already queued, whose "switching…" note stays.
    private func noteInputSwitch(_ outcome: DDCCommandOutcome, requested: Int, id: DisplayRecordID) {
        let reported = DDCInputSwitch.reportedInput(after: outcome, requested: requested,
                                                    previouslyReported: inputSource[id])
        if inputSource[id] != reported { inputSource[id] = reported }
        if inputSourceTarget[id] == nil { inputSwitch[id] = DDCInputSwitch(requested: requested, outcome: outcome) }
    }
    #endif

    /// Fires an input-switch hotkey (todo 4: Lunar's "Input Hotkeys"). Resolves the bound display by
    /// its persistent identity, then writes the input code through the same DDC feature/controller
    /// `setInputSource` uses — hotkeys get no separate switching implementation. No-ops with a failure
    /// notification when the display is offline or the panel rejects the write; acknowledges a sent
    /// switch with the OSD. A sent switch is recorded as a request (`inputSwitch`), not as the
    /// monitor's reported input — nothing reads the new input back.
    func switchInputByHotkey(_ entry: InputSwitchBinding) async {
        #if !PUBLIC_API_ONLY
        guard let observation = displays.first(where: { $0.recordID == entry.displayID }) else {
            await notifyInputSwitchFailed(entry.displayID, reason: .offline)
            return
        }
        guard let controller = await ddcController(for: observation) else {
            noteInputSwitch(.notSent, requested: entry.inputCode, id: entry.displayID)
            await notifyInputSwitchFailed(entry.displayID, reason: .noDDC)
            return
        }
        guard await controller.write(.inputSource, entry.inputCode) else {
            noteInputSwitch(.failed, requested: entry.inputCode, id: entry.displayID)
            await notifyInputSwitchFailed(entry.displayID, reason: .rejected)
            return
        }
        // Sent, not confirmed (AM-05): the switch is recorded as a request, never as the reported input.
        noteInputSwitch(.sent, requested: entry.inputCode, id: entry.displayID)
        presentInputSwitchOSD(inputName: inputName(entry.inputCode), for: observation)
        #endif
    }

    #if !PUBLIC_API_ONLY
    /// Posts the "couldn't switch" notification (Batch-2 #5's delivery path) for a hotkey target
    /// that's offline or NAKed the write. Named from the persistent registry, not `records`, since an
    /// offline display has no live observation to read a name from.
    private enum InputSwitchFailure { case offline, noDDC, rejected }

    private func notifyInputSwitchFailed(_ displayID: DisplayRecordID, reason: InputSwitchFailure) async {
        let name = await registry?.record(for: displayID)?.displayName ?? displayID.rawValue
        // Whole sentences per reason: a name + predicate pasted together can't be translated.
        let body: String
        switch reason {
        case .offline: body = String(localized: "\(name) is offline.")
        case .noDDC: body = String(localized: "\(name) has no DDC control.")
        case .rejected: body = String(localized: "\(name) rejected the input switch.")
        }
        NotificationDelivery.post(NotificationPolicy.DisplayNotification(
            title: String(localized: "Input switch failed"), body: body
        ))
    }
    #endif

    /// Sends a DDC power-mode command (VCP 0xD6) to an external display (Issue 1) and reports what the
    /// transport said (AM-04/SD-03). `.sent` is NOT proof the monitor acted: many panels ignore 0xD6
    /// or can't be woken back On over DDC, and none of that can be read back once the picture is gone.
    /// Callers confirm Standby/Off first (`DDCPowerMode.needsConfirmation`, `ddcPowerRisk`). Returns
    /// `.notSent` on the built-in, without a usable binding, and in the public-API-only build (DDC uses
    /// private SPI) — whose UI doesn't offer the action. The arrangement safety path is untouched
    /// because a power command doesn't alter the logical arrangement; the attempt is audited.
    func setPowerMode(_ mode: DDCPowerMode, for observation: DisplayObservation) async -> DDCCommandOutcome {
        #if !PUBLIC_API_ONLY
        guard observation.displayClass != .builtIn,
              let controller = await ddcController(for: observation) else { return .notSent }
        let outcome = DDCCommandOutcome(transportAccepted: await controller.write(.power, mode.vcpValue))
        await appendAudit(AuditEntry(
            timestamp: Date(), actor: .ui, command: "ddcPower:\(mode.rawValue)",
            transactionId: "txn_ddcPower", status: outcome.auditStatus,
            targets: [observation.recordID.rawValue]))
        return outcome
        #else
        return .notSent
        #endif
    }

    /// How risky a DDC Standby/Off is for this display: whether it is the main display and whether
    /// any other screen would still show a picture (blacked-out screens and macOS's placeholder don't
    /// count). A DDC power command leaves the arrangement as it is, so the menu bar, Dock and the
    /// OpenDisplay menu stay on a screen that may be dark.
    func ddcPowerRisk(for observation: DisplayObservation) -> DDCPowerRisk {
        let others = WakeConvergencePolicy.visibleSurfaces(in: displays).filter {
            $0.recordID != observation.recordID && !blackedOut.contains($0.recordID)
        }
        return DDCPowerRisk.assess(isMain: observation.isMain, otherVisibleScreens: others.count)
    }

    /// Refreshes a display's cached ICC state — controllability, current profile (name and file),
    /// and (once) the installed-profile list — all OFF the main actor, since ColorSync iterates and
    /// parses profiles from disk. The menu reads only the published caches and never touches
    /// ColorSync in a view body.
    func refreshColorProfile(for observation: DisplayObservation) async {
        guard let cgID = observation.cgDisplayID else { return }
        let id = observation.recordID
        let needProfiles = availableColorProfilesCache.isEmpty
        let result = await Task.detached(priority: .userInitiated) {
            (controllable: ColorProfileService.isControllable(cgID),
             name: ColorProfileService.currentProfileName(for: cgID),
             assignment: ColorProfileService.assignment(for: cgID),
             profiles: needProfiles ? ColorProfileService.availableProfiles() : nil)
        }.value
        colorProfileControllable[id] = result.controllable
        colorProfileName[id] = result.name
        if let assignment = result.assignment { colorProfileAssignment[id] = assignment }
        if let profiles = result.profiles { availableColorProfilesCache = profiles }
    }

    /// Assigns an ICC profile to a display (validated by ColorSyncProfileVerify inside the service),
    /// then re-reads the assignment off-main ("verify, don't assume"). The change counts only when
    /// ColorSync accepted it AND the re-read shows that very file — a refusal used to be dropped,
    /// and the name check could not tell two same-named files apart. User-driven.
    func setColorProfile(_ profile: ICCProfile, for observation: DisplayObservation) async {
        guard FeatureFlags.iccProfileWrite, let cgID = observation.cgDisplayID else { return }
        let id = observation.recordID
        let result = await Task.detached(priority: .userInitiated) {
            (accepted: ColorProfileService.setProfile(profile, for: cgID),
             assignment: ColorProfileService.assignment(for: cgID),
             name: ColorProfileService.currentProfileName(for: cgID))
        }.value
        noteProfileChange(name: result.name, assignment: result.assignment, id: id,
                          landed: result.accepted && profile.isFile(result.assignment?.customURL),
                          failure: String(localized: "macOS didn’t apply “\(profile.name)”. The profile shown is the one in effect."))
        await afterProfileChange(observation)
    }

    /// Reverts a display to its factory ICC profile, then re-reads the assignment off-main; it
    /// counts only when ColorSync accepted it and no custom profile remains.
    func resetColorProfile(for observation: DisplayObservation) async {
        guard FeatureFlags.iccProfileWrite, let cgID = observation.cgDisplayID else { return }
        let id = observation.recordID
        let result = await Task.detached(priority: .userInitiated) {
            (accepted: ColorProfileService.resetToFactory(for: cgID),
             assignment: ColorProfileService.assignment(for: cgID),
             name: ColorProfileService.currentProfileName(for: cgID))
        }.value
        let landed = result.accepted && result.assignment?.isFactory == true
        noteProfileChange(name: result.name, assignment: result.assignment, id: id, landed: landed,
                          failure: String(localized: "macOS didn’t switch back to the factory profile. The profile shown is the one in effect."))
        await afterProfileChange(observation)
    }

    private func noteProfileChange(name: String?, assignment: ICCAssignment?, id: DisplayRecordID,
                                   landed: Bool, failure: String) {
        colorProfileName[id] = name
        if let assignment { colorProfileAssignment[id] = assignment }
        colorProfileError[id] = landed ? nil : failure
    }

    /// A profile change can engage or lift the custom-profile safeguard (which re-expresses every
    /// display itself), and ColorSync reinstalling the display's table wipes an OpenDisplay one.
    private func afterProfileChange(_ observation: DisplayObservation) async {
        await refreshCustomProfileGuard()
        reapplySoftwareDim(for: observation)
    }

    /// Re-asserts OpenDisplay's gamma table after a colour-profile change. Applying a profile can
    /// rebuild the display's transfer tables WindowServer-side, silently wiping a formula-based dim —
    /// the screen would jump to full brightness while the slider still shows the dimmed level. Only
    /// a display whose table is OpenDisplay's needs it; Black Out is re-expressed as Black Out, so
    /// it isn't lit by a dim level.
    private func reapplySoftwareDim(for observation: DisplayObservation) {
        guard gammaOwned.contains(observation.recordID) else { return }
        reexpressSoftwareImage(observation.recordID)
    }

    /// Current rotation of a display in degrees (0/90/180/270), read via public Core Graphics.
    func currentRotation(for observation: DisplayObservation) -> Int {
        guard let cgID = observation.cgDisplayID else { return 0 }
        return rotationBackend.currentRotation(for: cgID)
    }

    /// The reason rotation writes are unavailable (drives the read-only UI label), or nil if writable.
    var rotationUnavailableReason: String? {
        if case .unavailable(let reason) = rotationBackend.capability { return reason }
        return nil
    }

    /// Whether rotation writes are available (the experimental backend is enabled).
    var rotationWritable: Bool {
        if case .experimental = rotationBackend.capability { return true }
        return false
    }

    /// Rotates a display (experimental path). Writes a recovery marker first so a stranded layout is
    /// detected + recovered on next launch; on failure runs Reconnect All; clears the marker after.
    func setRotation(_ degrees: Int, for observation: DisplayObservation) async {
        guard let cgID = observation.cgDisplayID else { return }
        busy = true
        defer { busy = false }
        let safeAngle = rotationBackend.currentRotation(for: cgID)
        Self.writeRotationMarker(RotationMarker(cgID: cgID, safeAngle: safeAngle))
        do {
            try await rotationBackend.setRotation(degrees, for: cgID)
        } catch {
            // The helper validates + rolls back itself, but ensure the safe angle is restored and a
            // safe surface remains even if the helper died before its own rollback.
            try? await rotationBackend.setRotation(safeAngle, for: cgID)
            _ = await coordinator.reconnectAll()
        }
        Self.clearRotationMarker()
        await refresh()
        // Rotation is part of the topology signature, so this raised a generation like any other
        // arrangement write. Without the note, Protected Layout would fight the rotation the user
        // just asked for — and lose badly, since `applyScene` skips rotation writes: it would
        // re-apply the pre-rotation origins twice and then report that it couldn't restore.
        await noteLayoutSelfChange()
    }

    /// Pending-rotation marker: records which display was being rotated and the angle it was at before,
    /// so that if the app/helper dies mid-rotation, the next launch can restore that exact safe angle.
    private struct RotationMarker: Codable { let cgID: CGDirectDisplayID; let safeAngle: Int }

    private static func rotationMarkerURL() -> URL? {
        (try? DiskCheckpointStore.defaultDirectory())?.appendingPathComponent("rotation.pending")
    }
    private static func writeRotationMarker(_ marker: RotationMarker) {
        guard let url = rotationMarkerURL(), let data = try? JSONEncoder().encode(marker) else { return }
        try? data.write(to: url, options: .atomic)
    }
    private static func readRotationMarker() -> RotationMarker? {
        guard let url = rotationMarkerURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RotationMarker.self, from: data)
    }
    private static func clearRotationMarker() {
        if let url = rotationMarkerURL() { try? FileManager.default.removeItem(at: url) }
    }

    /// Opens System Settings → Displays — the supported way to rotate on this macOS.
    func openDisplaySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Displays-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.displays",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    /// The colour-preset codes to offer for a display. VCP 0x14 (Select Color Preset) is a
    /// **non-continuous** enum: the panel only honours the specific values it advertises in its DDC
    /// capabilities, so we offer those (when known) rather than a contiguous 1...max range — otherwise
    /// most selections are codes the monitor silently ignores and the control appears to "do nothing".
    /// Falls back to 1...max only when capabilities haven't been read, clamped to the MCCS-defined
    /// preset range (some panels report max = 65535 for this feature, which would build a 65,535-item
    /// menu and hang the app). The current preset is always included so the menu stays truthful.
    func colorPresetCodes(for observation: DisplayObservation) -> [Int] {
        DDCCapabilities.offeredValues(
            ddcCapabilities[observation.recordID], for: 0x14,
            fallbackMax: colorPresetMax[observation.recordID] ?? 5,
            current: colorPreset[observation.recordID])
    }

    /// Reads the external display's current DDC colour preset (VCP 0x14) + its max code into the cache.
    /// Does NOT auto-fetch the capabilities string (it wedges some panels — see `refreshHardwareControls`);
    /// `colorPresetCodes` falls back to a 1...max menu when capabilities aren't cached.
    func refreshColorPreset(for observation: DisplayObservation) async {
        #if !PUBLIC_API_ONLY
        let id = observation.recordID
        let vcp = ExternalDisplayDDC.Feature.colorPreset.rawValue
        // Controller before admitProbe — see refreshInputSource.
        guard observation.displayClass != .builtIn,
              let controller = await ddcController(for: observation),
              ddcProbe[id, default: DDCProbeTracker()].admitProbe(vcp) else { return }
        guard let reading = await controller.read(vcp: vcp) else {
            ddcProbe[id, default: DDCProbeTracker()].recordFailure(vcp)
            return
        }
        ddcProbe[id, default: DDCProbeTracker()].recordSuccess(vcp)
        colorPreset[id] = reading.current
        colorPresetMax[id] = max(reading.max, 1)
        clearWriteIgnored(vcp, id: id)
        #endif
    }

    /// Sets the external display's DDC colour preset (sRGB / colour-temperature / native). User-driven.
    /// Coalesced per display (like input source) so rapid taps settle on the last choice in order.
    func setColorPreset(_ code: Int, for observation: DisplayObservation) {
        #if !PUBLIC_API_ONLY
        guard observation.displayClass != .builtIn else { return }
        let id = observation.recordID
        // A user-picked preset during an adaptive evening is adopted for the rest of the phase
        // (one-night adoption) — the policy stops issuing preset writes until the next transition.
        if settings.adaptiveWarmthEnabled {
            adaptiveStates[id] = AdaptiveDisplayPolicy.noteManualPreset(
                state: adaptiveStates[id] ?? seededAdaptiveState(for: id))
        }
        colorPreset[id] = code
        colorPresetTarget[id] = code
        if colorPresetWriter[id] == nil {
            colorPresetWriter[id] = Task { [weak self] in await self?.drainColorPresetWrites(id, observation) }
        }
        #endif
    }

    /// Asks the monitor to restore its factory settings (MCCS VCP 0x04) and reports what the
    /// transport said. Hardware only (AM-06): OpenDisplay's own software dim and colour temperature
    /// are a separate choice (`resetSoftwareAdjustments`) the UI offers after a reset that went
    /// through — a failed reset must not silently wipe them, and a successful one doesn't decide
    /// for the user whether the app's layers should go too.
    ///
    /// Order matters: queued coalesced writes are dropped FIRST so a drag still draining can't land
    /// on top of the reset; the re-read waits ~2 s because panels take a moment to reload defaults
    /// (and some NAK reads meanwhile); the probe cache is forgotten before re-reading so a feature
    /// that had been negatively cached (e.g. one the old picture mode locked) gets probed again.
    /// External displays only — the built-in has no DDC.
    func resetToDefaults(for observation: DisplayObservation) async -> DDCCommandOutcome {
        #if !PUBLIC_API_ONLY
        guard observation.displayClass != .builtIn,
              let controller = await ddcController(for: observation) else { return .notSent }
        let id = observation.recordID
        ddcTarget[id] = nil
        colorPresetTarget[id] = nil
        inputSourceTarget[id] = nil
        if inputSwitch[id]?.status == .sending { inputSwitch[id] = nil }  // its queued write was just dropped
        ddcControlTarget = ddcControlTarget.filter { $0.key.id != id }
        let outcome = DDCCommandOutcome(transportAccepted: await controller.write(.restoreFactoryDefaults, 1))

        await appendAudit(AuditEntry(
            timestamp: Date(), actor: .ui, command: "factoryReset",
            transactionId: "txn_factoryReset", status: outcome.auditStatus,
            targets: [id.rawValue]))
        // Not sent → nothing on the panel changed, so neither do the caches describing it.
        guard outcome == .sent else { return outcome }
        ddcWriteIgnored[id] = nil
        ddcWriteFailed[id] = nil

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        resetDDCProbeCache(for: id)
        await refreshBrightness(for: observation)
        await refreshHardwareControls(for: observation)
        await refreshColorPreset(for: observation)
        await refreshInputSource(for: observation)
        return outcome
        #else
        return .notSent
        #endif
    }

    /// Whether OpenDisplay itself is dimming or tinting this display (software dim or temperature) —
    /// what `resetSoftwareAdjustments` would undo.
    func hasSoftwareAdjustments(_ observation: DisplayObservation) -> Bool {
        let id = observation.recordID
        return (softwareDim[id].map { $0 < 1 } ?? false) || colorTemperature[id] != nil
    }

    /// Returns OpenDisplay's own software layers for a display — dim (gamma + overlay) and colour
    /// temperature — to neutral. Independent of the monitor's factory reset (AM-06): the user picks it
    /// separately, so a monitor reset that failed (or a user who wants to keep the app's evening
    /// warmth) leaves them alone. Cleared in the cache first so `writeGamma` re-expresses a neutral
    /// slot. Under Black Out the panel is held at gamma 0 on purpose — the cache still resets, and
    /// lifting the blackout restores neutral.
    func resetSoftwareAdjustments(for observation: DisplayObservation) async {
        guard let cgID = observation.cgDisplayID else { return }
        let id = observation.recordID
        softwareDim[id] = nil
        colorTemperature[id] = nil
        if !blackedOut.contains(id) {
            writeGamma(level: 1.0, id: id, cgID: cgID)
            dimOverlay.remove(for: cgID)
        }
        // A software-brightness display's slider IS the dim level — re-derive it.
        await refreshBrightness(for: observation)
    }

    #if !PUBLIC_API_ONLY
    private func drainColorPresetWrites(_ id: DisplayRecordID, _ observation: DisplayObservation) async {
        guard let controller = await ddcController(for: observation) else { colorPresetWriter[id] = nil; return }
        let vcp = ExternalDisplayDDC.Feature.colorPreset.rawValue
        while true {
            var lastTarget: Int?
            while let target = colorPresetTarget[id] {
                colorPresetTarget[id] = nil
                lastTarget = target
                await controller.write(.colorPreset, target)
            }
            guard let lastTarget else { break }
            switch await readBackAfterDrain(controller, vcp: vcp, settleNanos: Self.presetSettleNanos,
                                            superseded: { [weak self] in self?.colorPresetTarget[id] != nil }) {
            case .cancelled: return
            case .superseded: continue
            case .reading(let reading):
                // Discrete enum: exact match only. A panel that doesn't implement the code stays on
                // its current one (LG honours only 5/8/11), so show that instead of the pick. The
                // adaptive warmth loop sees the snapped value too, and treats a refused evening
                // preset as drift — it stops re-sending a write the panel will never take.
                let outcome = DDCWriteVerification.outcome(target: lastTarget, readback: reading?.current)
                noteWriteVerification(outcome, vcp: vcp, id: id)
                if case .ignored(let actual) = outcome { colorPreset[id] = actual }
            }
            break
        }
        colorPresetWriter[id] = nil
    }

    // MARK: - Adaptive Display (Labs): brightness sync + evening warmth

    /// Idempotent start/stop of the adaptive sampling loop — runs only while a feature toggle is on
    /// AND an active external exists (mirrors `reconcileMediaKeyTap`/`reconcileDisplaySleepGuard`).
    /// 5s cadence: one cheap DisplayServices IPC per tick; slower would visibly lag the built-in
    /// panel animating right next to the external, faster buys nothing through the 0.02 hysteresis.
    func reconcileAdaptiveLoop() {
        let anyModeOn = settings.adaptiveBrightnessSyncEnabled || settings.adaptiveWarmthEnabled
            || settings.clockScheduleEnabled || settings.adaptiveLocationModeEnabled
        let wantRunning = anyModeOn
            && displays.contains { $0.isActive && $0.displayClass != .builtIn }
        if wantRunning {
            guard adaptiveLoop == nil else { return }
            adaptiveLoop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.adaptiveTick()
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        } else {
            adaptiveLoop?.cancel()
            adaptiveLoop = nil
        }
    }

    /// One adaptive pass: sample the world once (built-in brightness, Night Shift, clock), then let
    /// the pure `AdaptiveDisplayPolicy` decide per display and apply its Decision in the required
    /// order — persist the day-preset memory BEFORE the preset write (restore-owed invariant),
    /// then preset, then the memory clear, then brightness.
    private func adaptiveTick() async {
        let config = settings.adaptiveConfig
        let syncOn = settings.adaptiveBrightnessSyncEnabled
        let warmthOn = settings.adaptiveWarmthEnabled
        let clockOn = settings.clockScheduleEnabled && !settings.clockScheduleEntries.isEmpty
        let locationOn = settings.adaptiveLocationModeEnabled
        guard syncOn || warmthOn || clockOn || locationOn else { return }

        let now = Date()
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        // Clock Mode target for this tick (nil when disabled, no entries, or only solar entries
        // with no location). When present it governs brightness AND takes precedence over the
        // built-in mirror, so the mirror sampling is skipped entirely.
        let clockTarget = clockOn ? clockScheduleBrightness(atMinute: minuteOfDay, on: now) : nil
        let mirrorActive = syncOn && clockTarget == nil
        // Location Mode's sun-elevation reading, cheap pure math so it's always sampled when the
        // mode is on and a location is configured; the policy itself decides precedence against
        // the built-in mirror and ambient sensor (see `AdaptiveDisplayPolicy.brightnessDecision`).
        let locationElevation = locationElevationDegrees(at: now)
        let brightnessGoverned = mirrorActive || clockTarget != nil || locationElevation != nil

        let builtInObs = displays.first { $0.displayClass == .builtIn && $0.isActive }
        var builtInSample: Float?
        if mirrorActive, let builtIn = builtInObs, let builtInCG = builtIn.cgDisplayID {
            let control = brightnessControl
            builtInSample = await Task.detached(priority: .utility) { control.brightness(for: builtInCG) }.value
            // Keep the built-in's own slider live too — macOS auto-brightness moves it under us.
            if let sample = builtInSample, abs((brightness[builtIn.recordID] ?? -1) - sample) > 0.004 {
                brightness[builtIn.recordID] = sample
            }
        }
        if mirrorActive, builtInObs == nil {
            // Built-in off: read the ambient light sensor directly (lid-open-display-off setups —
            // the sensor keeps reporting even though macOS drives no panel from it). EMA-smoothed;
            // an unreadable sensor (lid actually closed) clears it → schedule mode.
            let reader = ambientLight
            if let sample = await Task.detached(priority: .utility, operation: { reader.lux() }).value {
                ambientLuxEMA = ambientLuxEMA.map { $0 * 0.6 + sample * 0.4 } ?? sample
            } else {
                ambientLuxEMA = nil
            }
        } else {
            ambientLuxEMA = nil  // built-in active (or sync off): ambient mode dormant
        }
        var nightShiftActive: Bool?
        if warmthOn {
            let reader = nightShift
            nightShiftActive = await Task.detached(priority: .utility) { reader.isActive() }.value
        }

        for observation in displays where observation.displayClass != .builtIn && observation.isActive {
            guard let cgID = observation.cgDisplayID else { continue }
            let id = observation.recordID
            // Resolve capabilities lazily, once — the caches are sticky and pruned on disconnect.
            if brightnessMethod[id] == nil { await refreshBrightness(for: observation) }
            guard brightnessMethod[id] == .hardware else { continue }  // DDC-safety gate
            // An active app preset is the last writer on this display (Issue #33 precedence) — leave it
            // alone so adaptive/clock never fights the preset it just applied.
            if appPresetActiveDisplays.contains(id) { continue }
            // A grouped display's brightness is driven by its group (Issue #39) — the two features
            // are mutually exclusive per display, so adaptive leaves brightness alone here. Warmth is
            // orthogonal (groups never touch the colour preset) and keeps running.
            let groupDrivesBrightness = DisplayGroupStore.isGroupGoverned(id, in: settings.displayGroups)
            if warmthOn, colorPreset[id] == nil { await refreshColorPreset(for: observation) }

            let state = adaptiveStates[id] ?? seededAdaptiveState(for: id)
            let input = AdaptiveDisplayPolicy.Input(
                now: now, minuteOfDay: minuteOfDay,
                // Only a candidate source when brightness sync itself is enabled — otherwise a lid-
                // open built-in would block Location Mode from ever reaching its elevation branch.
                builtInPresent: syncOn && builtInObs != nil,
                builtInBrightness: builtInSample,
                ambientLux: ambientLuxEMA,
                displayAsleep: CGDisplayIsAsleep(cgID) != 0,
                currentPreset: colorPreset[id],
                dayPreset: settings.adaptiveDayPresetByDisplay[id.rawValue],
                nightShiftActive: nightShiftActive,
                brightnessSyncEnabled: brightnessGoverned && !groupDrivesBrightness,
                warmthEnabled: warmthOn,
                scheduleOverride: clockTarget, locationElevationDegrees: locationElevation)
            let decision = AdaptiveDisplayPolicy.evaluate(input, config: config, state: state)

            if let dayPreset = decision.rememberDayPreset {
                settings.adaptiveDayPresetByDisplay[id.rawValue] = dayPreset
                persistSettings()  // BEFORE the evening write — a crash between must still owe a restore
            }
            if let preset = decision.presetWrite { applyAdaptivePreset(preset, for: observation) }
            if decision.clearDayPreset {
                settings.adaptiveDayPresetByDisplay[id.rawValue] = nil
                persistSettings()
            }
            if let value = decision.brightnessWrite { applyAdaptiveBrightness(value, for: observation) }
            // Learned offsets persist at tick-time, not per slider move — no disk spam mid-drag.
            if settings.adaptiveBrightnessOffsetByDisplay[id.rawValue] != decision.state.brightnessOffset {
                settings.adaptiveBrightnessOffsetByDisplay[id.rawValue] = decision.state.brightnessOffset
                persistSettings()
            }
            adaptiveStates[id] = decision.state
        }
    }

    /// First state for a display: carry the learned offset across relaunches.
    private func seededAdaptiveState(for id: DisplayRecordID) -> AdaptiveDisplayPolicy.DisplayState {
        AdaptiveDisplayPolicy.DisplayState(
            brightnessOffset: settings.adaptiveBrightnessOffsetByDisplay[id.rawValue] ?? 0)
    }

    /// The Clock Mode brightness owed at `minute` on `date`, resolving solar anchors from the
    /// configured location. Nil when the schedule can't govern (no entries, or only solar anchors
    /// with no location) — Clock Mode then does nothing and any other mode governs.
    private func clockScheduleBrightness(atMinute minute: Int, on date: Date) -> Float? {
        let solar = settings.clockManualLocation.map {
            SolarCalculator.events(on: date, in: .current, coordinate: $0)
        }
        return ClockSchedulePolicy.brightness(atMinute: minute,
                                              entries: settings.clockScheduleEntries, solar: solar)
    }

    /// The sun's elevation at `date` for Location Mode, or nil when the mode is off or no location
    /// is configured (manual lat/long, or a completed one-shot Core Location fetch — the same
    /// storage Clock Mode's solar anchors use).
    private func locationElevationDegrees(at date: Date) -> Double? {
        guard settings.adaptiveLocationModeEnabled, let coordinate = settings.clockManualLocation
        else { return nil }
        return SolarCalculator.elevationDegrees(at: date, in: .current, coordinate: coordinate)
    }

    /// OSD-silent adaptive brightness apply: cache + coalesced DDC write, NO OSD flash and NO
    /// manual-change note — this is the machine's hand, not the user's. (`setBrightness` is the
    /// user funnel and does both.)
    private func applyAdaptiveBrightness(_ value: Float, for observation: DisplayObservation) {
        let id = observation.recordID
        brightness[id] = value  // keep the visible slider honest
        ddcTarget[id] = Int((value * Float(brightnessMax[id] ?? 100)).rounded())
        if ddcWriters[id] == nil {
            ddcWriters[id] = Task { [weak self] in await self?.drainDDCWrites(id, observation) }
        }
    }

    /// OSD-silent adaptive preset apply. Updates the cache first so the policy's drift detection
    /// doesn't mistake our own write for a monitor-button change on the next tick.
    private func applyAdaptivePreset(_ code: Int, for observation: DisplayObservation) {
        let id = observation.recordID
        colorPreset[id] = code
        colorPresetTarget[id] = code
        if colorPresetWriter[id] == nil {
            colorPresetWriter[id] = Task { [weak self] in await self?.drainColorPresetWrites(id, observation) }
        }
    }

    /// Restores every owed daytime colour preset (quit / warmth-disable), awaited directly on the
    /// DDC controller so process exit can't race the fire-and-forget writers. Entries whose display
    /// isn't currently present stay persisted — the day-phase restore rule picks them up whenever
    /// the display returns.
    private func restoreOwedDayPresets() async {
        guard !settings.adaptiveDayPresetByDisplay.isEmpty else { return }
        var remaining = settings.adaptiveDayPresetByDisplay
        for (rawID, code) in settings.adaptiveDayPresetByDisplay {
            guard let observation = displays.first(where: { $0.recordID.rawValue == rawID }),
                  observation.isActive,
                  let controller = await ddcController(for: observation) else { continue }
            await controller.write(.colorPreset, code)
            colorPreset[observation.recordID] = code
            remaining[rawID] = nil
        }
        if remaining != settings.adaptiveDayPresetByDisplay {
            settings.adaptiveDayPresetByDisplay = remaining
            persistSettings()
        }
    }

    /// The manual-brightness note for `setBrightness`'s hardware branch (user slider/media keys on
    /// a synced external): learn the offset in sync/ambient/location mode, anchor the adoption in
    /// schedule mode.
    private func noteManualBrightnessForAdaptive(_ value: Float, id: DisplayRecordID) {
        let syncOn = settings.adaptiveBrightnessSyncEnabled
        let clockOn = settings.clockScheduleEnabled && !settings.clockScheduleEntries.isEmpty
        guard syncOn || clockOn || settings.adaptiveLocationModeEnabled else { return }
        let now = Date()
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let clockTarget = clockOn ? clockScheduleBrightness(atMinute: minute, on: now) : nil
        let locationLevel = (clockTarget == nil ? locationElevationDegrees(at: now) : nil)
            .map(AdaptiveDisplayPolicy.locationLevel(forElevationDegrees:))
        // The offset-teaching reference is whatever brightness is currently following: nothing when
        // Clock Mode governs (schedule-like adoption), else the built-in's level in sync mode, the
        // light-sensor curve in ambient mode, or the sun-elevation curve in Location Mode. The
        // adoption anchor is the governing schedule target.
        let builtIn = displays.first { $0.displayClass == .builtIn && $0.isActive }
        let reference: Float? = clockTarget != nil
            ? nil
            : (syncOn ? builtIn.flatMap { brightness[$0.recordID] }
                    ?? ambientLuxEMA.map(AdaptiveDisplayPolicy.ambientLevel(forLux:)) : nil)
                ?? locationLevel
        let scheduleTarget = clockTarget
            ?? locationLevel
            ?? AdaptiveDisplayPolicy.scheduleLevel(atMinute: minute, config: settings.adaptiveConfig)
        adaptiveStates[id] = AdaptiveDisplayPolicy.noteManualBrightness(
            value, reference: reference, scheduleTarget: scheduleTarget, at: now,
            state: adaptiveStates[id] ?? seededAdaptiveState(for: id))
    }

    /// One-line adaptive status for the display detail card, or nil when adaptive isn't acting on
    /// this display (built-in, features off, or no hardware brightness).
    func adaptiveStatusLine(for observation: DisplayObservation) -> String? {
        guard observation.displayClass != .builtIn,
              settings.adaptiveBrightnessSyncEnabled || settings.adaptiveWarmthEnabled
                || settings.clockScheduleEnabled || settings.adaptiveLocationModeEnabled,
              brightnessMethod[observation.recordID] == .hardware else { return nil }
        let id = observation.recordID
        let state = adaptiveStates[id]
        var parts: [String] = []
        let now = Date()
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let clockOn = settings.clockScheduleEnabled && !settings.clockScheduleEntries.isEmpty
        let clockTarget = clockOn ? clockScheduleBrightness(atMinute: minuteOfDay, on: now) : nil
        if let clockTarget {
            // Clock Mode governs brightness and outranks the adaptive mirror.
            parts.append(String(localized: "clock \(Int((clockTarget * 100).rounded()))%"))
        } else if settings.adaptiveBrightnessSyncEnabled || settings.adaptiveLocationModeEnabled {
            if let manualAt = state?.manualBrightnessAt,
               Date() < manualAt.addingTimeInterval(settings.adaptiveConfig.manualCooldown) {
                parts.append(String(localized: "brightness paused (manual)"))
            } else if settings.adaptiveBrightnessSyncEnabled,
                      displays.contains(where: { $0.displayClass == .builtIn && $0.isActive }) {
                let offset = Int(((state?.brightnessOffset ?? 0) * 100).rounded())
                parts.append(offset == 0 ? String(localized: "following built-in")
                                         : String(format: String(localized: "following built-in (%+d%%)"), offset))
            } else if settings.adaptiveBrightnessSyncEnabled, let lux = ambientLuxEMA {
                parts.append(String(localized: "following room light (\(Int(lux.rounded())) lx)"))
            } else if let elevation = locationElevationDegrees(at: now) {
                parts.append(String(localized: "following sun position (\(Int(elevation.rounded()))°)"))
            } else {
                parts.append(String(localized: "on schedule (no light sensor)"))
            }
        }
        if settings.adaptiveWarmthEnabled {
            parts.append(state?.warmthPhase == .evening ? String(localized: "evening warmth active")
                                                        : String(localized: "day colour"))
        }
        guard !parts.isEmpty else { return nil }
        let usesAdaptive = settings.adaptiveBrightnessSyncEnabled || settings.adaptiveWarmthEnabled
            || settings.adaptiveLocationModeEnabled
        let joined = parts.joined(separator: " · ")
        return usesAdaptive ? String(localized: "Adaptive: \(joined)") : String(localized: "Clock Mode: \(joined)")
    }

    func setAdaptiveBrightnessSyncEnabled(_ enabled: Bool) {
        guard settings.adaptiveBrightnessSyncEnabled != enabled else { return }
        settings.adaptiveBrightnessSyncEnabled = enabled
        persistSettings()
        reconcileAdaptiveLoop()
    }

    func setAdaptiveWarmthEnabled(_ enabled: Bool) {
        guard settings.adaptiveWarmthEnabled != enabled else { return }
        settings.adaptiveWarmthEnabled = enabled
        persistSettings()
        reconcileAdaptiveLoop()
        if !enabled { Task { [weak self] in await self?.restoreOwedDayPresets() } }
    }

    /// Toggles Location Mode: brightness follows the sun's elevation at `clockManualLocation` when
    /// neither the built-in mirror nor the ambient sensor is available (Issue #31).
    func setAdaptiveLocationModeEnabled(_ enabled: Bool) {
        guard settings.adaptiveLocationModeEnabled != enabled else { return }
        settings.adaptiveLocationModeEnabled = enabled
        persistSettings()
        reconcileAdaptiveLoop()
    }

    func setAdaptiveEveningPreset(_ code: Int) {
        guard settings.adaptiveEveningPreset != code else { return }
        settings.adaptiveEveningPreset = code
        persistSettings()
    }

    /// The schedule-fallback brightness plateaus (0.1...1) — what clamshell mode dims between.
    func setAdaptiveFallbackLevels(day: Float, night: Float) {
        let day = min(max(day, 0.1), 1)
        let night = min(max(night, 0.1), 1)
        guard settings.adaptiveFallbackDayLevel != day
            || settings.adaptiveFallbackNightLevel != night else { return }
        settings.adaptiveFallbackDayLevel = day
        settings.adaptiveFallbackNightLevel = night
        persistSettings()
    }

    func setAdaptiveSchedule(dayStartMinute: Int, nightStartMinute: Int, transitionMinutes: Int) {
        let day = min(max(dayStartMinute, 0), 1439)
        let night = min(max(nightStartMinute, 0), 1439)
        let ramp = min(max(transitionMinutes, 1), 180)
        guard settings.adaptiveDayStartMinute != day || settings.adaptiveNightStartMinute != night
            || settings.adaptiveTransitionMinutes != ramp else { return }
        settings.adaptiveDayStartMinute = day
        settings.adaptiveNightStartMinute = night
        settings.adaptiveTransitionMinutes = ramp
        persistSettings()
    }

    // MARK: - Clock Mode (Issue #30): user-authored brightness schedule

    func setClockScheduleEnabled(_ enabled: Bool) {
        guard settings.clockScheduleEnabled != enabled else { return }
        settings.clockScheduleEnabled = enabled
        persistSettings()
        reconcileAdaptiveLoop()
    }

    /// Inserts a new schedule entry or replaces the one with a matching id, then re-sorts by fire
    /// time for a stable list order in the editor.
    func upsertClockScheduleEntry(_ entry: ClockScheduleEntry) {
        if let index = settings.clockScheduleEntries.firstIndex(where: { $0.id == entry.id }) {
            settings.clockScheduleEntries[index] = entry
        } else {
            settings.clockScheduleEntries.append(entry)
        }
        settings.clockScheduleEntries.sort { $0.timeMinute < $1.timeMinute }
        persistSettings()
        reconcileAdaptiveLoop()
    }

    func deleteClockScheduleEntry(_ entry: ClockScheduleEntry) {
        guard let index = settings.clockScheduleEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        settings.clockScheduleEntries.remove(at: index)
        persistSettings()
        reconcileAdaptiveLoop()
    }

    func setClockManualLocation(_ coordinate: GeoCoordinate?) {
        guard settings.clockManualLocation != coordinate else { return }
        settings.clockManualLocation = coordinate
        persistSettings()
    }

    /// Best-effort one-shot Core Location fetch that fills the manual latitude/longitude. On denial
    /// or failure nothing changes and the user enters coordinates by hand.
    func useCurrentLocationForClock() {
        clockLocationProvider.requestOnce { [weak self] coordinate in
            guard let self, let coordinate else { return }
            self.setClockManualLocation(coordinate)
        }
    }

    // MARK: - App Presets (Issue #33): per-app brightness / colour-preset switching

    func setAppPresetsEnabled(_ enabled: Bool) {
        guard settings.appPresetsEnabled != enabled else { return }
        settings.appPresetsEnabled = enabled
        persistSettings()
        reconcileAppPresetObserver()
        if !enabled { Task { [weak self] in await self?.restoreOwedAppPresetState() } }
    }

    /// Inserts or replaces a preset — at most one per bundle identifier, since the frontmost app's
    /// bundle id is the lookup key — then re-evaluates so a live edit lands without an app switch.
    func upsertAppPreset(_ preset: AppPresetPolicy.AppPreset) {
        if let index = settings.appPresets.firstIndex(where: {
            $0.bundleIdentifier == preset.bundleIdentifier
        }) {
            settings.appPresets[index] = preset
        } else {
            settings.appPresets.append(preset)
        }
        persistSettings()
        reconcileAppPresetObserver()
        evaluateAppPresets()
    }

    func removeAppPreset(_ preset: AppPresetPolicy.AppPreset) {
        guard let index = settings.appPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        settings.appPresets.remove(at: index)
        persistSettings()
        reconcileAppPresetObserver()
        evaluateAppPresets()
    }

    /// Regular (Dock-visible) apps currently running, for the settings "add preset" picker. The bundle
    /// id is the stable key the policy matches on; the localized name is the label.
    func runningApplicationChoices() -> [(name: String, bundleID: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { application in
                guard let bundleID = application.bundleIdentifier else { return nil }
                return (application.localizedName ?? bundleID, bundleID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Starts or stops the frontmost-app observer — running only while App Presets is on with at least
    /// one preset (mirrors `reconcileAdaptiveLoop`). Idempotent.
    func reconcileAppPresetObserver() {
        let wantRunning = settings.appPresetsEnabled && !settings.appPresets.isEmpty
        guard wantRunning else {
            stopAppPresetObserver()
            return
        }
        guard appPresetObserver == nil else { return }
        appPresetObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateAppPresets() }
        }
        evaluateAppPresets()  // apply for whatever is already frontmost
    }

    private func stopAppPresetObserver() {
        if let observer = appPresetObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appPresetObserver = nil
        }
        appPresetDebounceTask?.cancel()
        appPresetDebounceTask = nil
    }

    /// One App-Preset evaluation: read the current frontmost app, prime the governed displays' live
    /// caches, then resolve and apply the pure policy's decision. Kicked by the frontmost-app observer,
    /// a live settings edit, a topology change, and the debounce re-check timer.
    func evaluateAppPresets() {
        guard settings.appPresetsEnabled, !settings.appPresets.isEmpty else { return }
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        Task { [weak self] in
            guard let self else { return }
            await self.primeAppPresetCaches(frontmostBundleID: frontmostBundleID)
            self.resolveAndApplyAppPresets(frontmostBundleID: frontmostBundleID)
        }
    }

    /// Reads the current brightness (and colour preset, when the incoming preset sets one) for every
    /// governed display whose cache is cold, so the captured baseline reflects what is really on screen
    /// rather than a nil placeholder. No-op when the frontmost app has no preset (a restore reads only
    /// the ledger).
    private func primeAppPresetCaches(frontmostBundleID: String?) async {
        guard let incoming = settings.appPresets.first(where: {
            $0.bundleIdentifier == frontmostBundleID
        }) else { return }
        for observation in displays where observation.displayClass != .builtIn && observation.isActive {
            let id = observation.recordID
            if brightnessMethod[id] == nil { await refreshBrightness(for: observation) }
            guard brightnessMethod[id] == .hardware else { continue }
            if brightness[id] == nil { await refreshBrightness(for: observation) }
            if incoming.colorPreset != nil, colorPreset[id] == nil {
                await refreshColorPreset(for: observation)
            }
        }
    }

    private func resolveAndApplyAppPresets(frontmostBundleID: String?) {
        let input = AppPresetPolicy.Input(
            frontmostBundleID: frontmostBundleID, now: Date(), presets: settings.appPresets,
            displays: appPresetDisplaySnapshots())
        let decision = AppPresetPolicy.resolve(input, state: appPresetActivation)
        applyAppPresetDecision(decision)
        scheduleAppPresetRecheck(after: decision.rescheduleAfter)
    }

    /// Live values for every active external the policy may govern. FaceLight-active displays are
    /// excluded — FaceLight is an explicit hotkey and outranks app presets, so the policy never targets
    /// one while its fill light is on.
    private func appPresetDisplaySnapshots() -> [AppPresetPolicy.DisplaySnapshot] {
        displays.compactMap { observation in
            let id = observation.recordID
            guard observation.displayClass != .builtIn, observation.isActive,
                  brightnessMethod[id] == .hardware,
                  settings.faceLightPriorStateByDisplay[id.rawValue] == nil else { return nil }
            return AppPresetPolicy.DisplaySnapshot(
                recordID: id.rawValue, brightness: brightness[id],
                contrast: ddcControl(.contrast, for: observation), colorPreset: colorPreset[id])
        }
    }

    /// Applies a policy decision in the crash-safe order the `Decision` documents: persist captures
    /// BEFORE their apply writes, issue the apply then restore writes, then persist the clears AFTER
    /// their restore writes. Finally adopt the new activation state and governed-display set.
    private func applyAppPresetDecision(_ decision: AppPresetPolicy.Decision) {
        if !decision.captures.isEmpty {
            for (rawID, prior) in decision.captures { settings.appPresetPriorStateByDisplay[rawID] = prior }
            persistSettings()
        }
        for write in decision.applyWrites { applyAppPresetWrite(write) }
        for write in decision.restoreWrites { applyAppPresetWrite(write) }
        if !decision.clears.isEmpty {
            for rawID in decision.clears { settings.appPresetPriorStateByDisplay[rawID] = nil }
            persistSettings()
        }
        appPresetActivation = decision.state
        appPresetActiveDisplays = decision.state.activeBundleID == nil
            ? []
            : Set(decision.state.priorStateByDisplay.keys.map(DisplayRecordID.init(rawValue:)))
    }

    /// Applies one display's preset (or restore) write through the SILENT adaptive funnels — no OSD and
    /// no manual-change note — so an app preset never trips Adaptive Display's manual-change cooldown.
    private func applyAppPresetWrite(_ write: AppPresetPolicy.DisplayWrite) {
        guard let observation = displays.first(where: { $0.recordID.rawValue == write.recordID }) else {
            return
        }
        // `isGroupSync` for the contrast write: app presets outrank group sync, so a preset must not
        // mirror itself across the group (brightness already avoids this by taking the silent funnel).
        if let brightness = write.brightness { applyAdaptiveBrightness(brightness, for: observation) }
        if let contrast = write.contrast {
            setHardwareControl(.contrast, contrast, for: observation, isGroupSync: true)
        }
        if let code = write.colorPreset { applyAdaptivePreset(code, for: observation) }
    }

    /// Arms the one-shot debounce re-check, replacing any prior timer. On fire it re-evaluates against
    /// the then-current frontmost app, so a fast Cmd-Tab through several apps commits only the one the
    /// user lands on.
    private func scheduleAppPresetRecheck(after delay: TimeInterval?) {
        appPresetDebounceTask?.cancel()
        guard let delay else { appPresetDebounceTask = nil; return }
        appPresetDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.evaluateAppPresets()
        }
    }

    /// Restores every owed app-preset prior state — crash-safe recovery at launch and the quit-teardown
    /// backstop. Mirrors `restoreOwedFaceLightState`: an entry clears only once its restore write is
    /// issued on the awaited controller, so quitting can't race the fire-and-forget writers.
    private func restoreOwedAppPresetState() async {
        guard !settings.appPresetPriorStateByDisplay.isEmpty else {
            appPresetActivation = AppPresetPolicy.ActivationState()
            appPresetActiveDisplays = []
            return
        }
        var remaining = settings.appPresetPriorStateByDisplay
        for (rawID, prior) in settings.appPresetPriorStateByDisplay {
            guard let observation = displays.first(where: { $0.recordID.rawValue == rawID }),
                  observation.isActive else { continue }
            await restoreAppPresetPrior(prior, for: observation)
            remaining[rawID] = nil
        }
        if remaining != settings.appPresetPriorStateByDisplay {
            settings.appPresetPriorStateByDisplay = remaining
            persistSettings()
        }
        appPresetActivation = AppPresetPolicy.ActivationState(
            priorStateByDisplay: settings.appPresetPriorStateByDisplay)
        appPresetActiveDisplays = []
    }

    /// Writes one display's pre-preset brightness/contrast/colour-preset back on the awaited DDC
    /// controller (like `restoreFaceLightPrior`), falling back to the software brightness route when
    /// the panel exposes no controller.
    private func restoreAppPresetPrior(_ prior: AppPresetPolicy.PriorState,
                                       for observation: DisplayObservation) async {
        let id = observation.recordID
        guard let controller = await ddcController(for: observation) else {
            if let brightness = prior.brightness {
                restoreBrightnessWithoutLeading(brightness, for: observation)
            }
            return
        }
        if let level = prior.brightness {
            let maxLevel = Float(brightnessMax[id] ?? 100)
            await controller.write(.brightness, Int((level * maxLevel).rounded()))
            brightness[id] = level
        }
        if let contrast = prior.contrast {
            await restoreFaceLightContrast(contrast, id: id, controller: controller)
        }
        if let code = prior.colorPreset {
            await controller.write(.colorPreset, code)
            colorPreset[id] = code
        }
    }
    #endif

    // MARK: - Display Groups (Issue #39): settings surface

    /// The group a display belongs to, or nil when it is ungrouped.
    func displayGroup(containing member: DisplayRecordID) -> DisplayGroup? {
        DisplayGroupStore.group(containing: member, in: settings.displayGroups)
    }

    /// The "synced with <group>" caption for a display's detail row, or nil when it isn't grouped.
    func groupSyncCaption(for observation: DisplayObservation) -> String? {
        displayGroup(containing: observation.recordID).map { String(localized: "Synced with \($0.name)") }
    }

    /// A name for a display that may not be present right now: its live/aliased name when the
    /// display is here, else the remembered registry record's friendly name (alias → model → class
    /// label). `records` only ever holds the displays of the current snapshot, so an absent display
    /// is named from the registry index instead — otherwise the row reads `cg:37D8832A-2D66-…`,
    /// which tells the user nothing about which monitor it means. The raw id survives only for a
    /// display the registry has never seen at all.
    ///
    /// Shared by the Groups card and the protected-layout rows, which have the same problem from
    /// opposite ends: the display you most want named is the one that isn't on the desk — or the one
    /// this app switched off.
    func rememberedDisplayName(for display: DisplayRecordID) -> String {
        if let observation = displays.first(where: { $0.recordID == display }) {
            return displayName(for: observation)
        }
        guard let record = records[display] ?? registryKnownRecords[display] else {
            return display.rawValue
        }
        // With no alias or model name the package falls back to a fixed English class label
        // ("Built-in Display", "External display"…), looked up in the catalog. A user's alias is
        // never looked up: it could collide with a catalog key.
        if (record.alias ?? "").isEmpty, (record.fingerprint.modelName ?? "").isEmpty {
            return record.friendlyName().appLocalized
        }
        return record.friendlyName()
    }

    /// The displays a group's membership list can offer: everything connected right now, plus every
    /// display the registry remembers (spec req 4). Without the remembered half, a monitor that is
    /// unplugged — or that the app itself turned off — simply cannot be added to a group until it
    /// comes back, which is the moment a user is most likely to be setting groups up.
    var groupMemberCandidates: [DisplayRecordID] {
        let connected = displays.map(\.recordID)
        let remembered = registryKnownRecords.keys.filter { !connected.contains($0) }
        // Dictionary order is not stable across reads; sort by the name shown so the rows don't
        // reshuffle under the user's cursor between refreshes.
        return connected + remembered.sorted { rememberedDisplayName(for: $0) < rememberedDisplayName(for: $1) }
    }

    /// Creates a group; false when the name is blank or already taken (names are the CLI's handle on
    /// a group, so they have to stay unambiguous).
    @discardableResult
    func createDisplayGroup(named name: String) -> Bool {
        guard let created = DisplayGroupStore.create(named: name, in: settings.displayGroups)
        else { return false }
        settings.displayGroups = created
        persistSettings()
        return true
    }

    func deleteDisplayGroup(_ group: DisplayGroup) {
        settings.displayGroups = DisplayGroupStore.delete(id: group.id, from: settings.displayGroups)
        groupSyncStates[group.id] = nil
        persistSettings()
    }

    @discardableResult
    func renameDisplayGroup(_ group: DisplayGroup, to name: String) -> Bool {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        let clash = DisplayGroupStore.group(named: cleaned, in: settings.displayGroups)
        guard clash == nil || clash?.id == group.id else { return false }
        var renamed = group
        renamed.name = cleaned
        updateDisplayGroup(renamed)
        return true
    }

    /// Adds or removes a member. Joining resets the group's leader state: the display that led before
    /// may no longer be in the group, and a stale base level would misread the next nudge as a
    /// correction against a level nobody is at.
    func setDisplayGroupMembership(_ member: DisplayRecordID, in group: DisplayGroup, isMember: Bool) {
        settings.displayGroups = isMember
            ? DisplayGroupStore.addMember(member, to: group.id, in: settings.displayGroups)
            : DisplayGroupStore.removeMember(member, from: group.id, in: settings.displayGroups)
        groupSyncStates.removeAll()
        persistSettings()
    }

    /// The settings ± slider. Dragging it is dozens of ticks, so the offset lands in memory per tick
    /// and the disk write is coalesced — same rule as an offset the group learns from a correction
    /// (see `storeDisplayGroupOffsets`).
    func setDisplayGroupOffset(_ offset: Float, for member: DisplayRecordID, in group: DisplayGroup) {
        // Edit the live group, not the caller's copy: a view's snapshot can predate an offset the
        // group learned since, and writing the whole snapshot back would undo it.
        guard var edited = settings.displayGroups.first(where: { $0.id == group.id }) else { return }
        edited.setOffset(offset, for: member)
        storeDisplayGroupOffsets(edited)
    }

    func setDisplayGroupSyncBrightness(_ enabled: Bool, for group: DisplayGroup) {
        var edited = group
        edited.syncBrightness = enabled
        updateDisplayGroup(edited)
    }

    func setDisplayGroupSyncContrast(_ enabled: Bool, for group: DisplayGroup) {
        var edited = group
        edited.syncContrast = enabled
        updateDisplayGroup(edited)
    }

    private func updateDisplayGroup(_ group: DisplayGroup) {
        settings.displayGroups = DisplayGroupStore.update(group, in: settings.displayGroups)
        persistSettings()
    }

    // MARK: - FaceLight: video-call fill light

    /// Toggles FaceLight for `observation`: DDC brightness/contrast to max plus a warm click-through
    /// overlay; the next press restores the exact prior brightness/contrast. The restore ledger is
    /// persisted BEFORE the max-out write and cleared only after a confirmed restore, so a crash or
    /// relaunch mid-FaceLight still restores correctly — see `FaceLightPolicy` and
    /// `restoreOwedFaceLightState`. Displays with no DDC contrast channel simply get no contrast
    /// write; the overlay alone carries the fill-light effect for them.
    func toggleFaceLight(for observation: DisplayObservation) {
        guard let cgID = observation.cgDisplayID else { return }
        let id = observation.recordID
        let owedPriorState = settings.faceLightPriorStateByDisplay[id.rawValue]
        let outcome = FaceLightPolicy.toggle(
            owedPriorState: owedPriorState, liveBrightness: brightness[id] ?? 1.0,
            liveContrast: ddcControl(.contrast, for: observation))

        settings.faceLightPriorStateByDisplay[id.rawValue] = outcome.priorStateToPersist
        persistSettings()

        // FaceLight outranks group sync, so neither its max-out nor its restore may lead the group
        // (a restore lands after the ledger clears, so the governed check alone wouldn't catch it).
        let token = groupSyncEcho.begin(leader: id)
        if let brightnessWrite = outcome.brightnessWrite {
            setBrightness(brightnessWrite, for: observation, syncToken: token)
        }
        if let contrastWrite = outcome.contrastWrite {
            setHardwareControl(.contrast, contrastWrite, for: observation, isGroupSync: true)
        }
        groupSyncEcho.end(token)
        applyFaceLightOverlay(isActive: outcome.isNowActive, cgID: cgID)
    }

    /// True while `observation` is currently FaceLight's fill light (ledger presence IS the flag,
    /// exactly like `adaptiveDayPresetByDisplay` doubles as the evening-warmth "is active" flag).
    func isFaceLightActive(_ observation: DisplayObservation) -> Bool {
        settings.faceLightPriorStateByDisplay[observation.recordID.rawValue] != nil
    }

    /// Shows or hides the warm-white overlay for FaceLight, reusing the same click-through window
    /// infrastructure the dim/combined methods use — crash-safe because the window is process-bound,
    /// so an app crash can never leave a warm overlay stuck on screen. The window opacity is
    /// `FaceLightPolicy.overlayAlpha` (a translucent wash), NOT full opacity: at alpha 1 the panel
    /// would go visually blind, hiding the very video call FaceLight is meant to light — the maxed
    /// brightness/contrast from `toggle` plus a strong (not opaque) wash is what keeps the call
    /// window legible while still throwing extra warm light off the panel.
    private func applyFaceLightOverlay(isActive: Bool, cgID: CGDirectDisplayID) {
        guard isActive else {
            dimOverlay.remove(for: cgID)
            return
        }
        let gains = ColorTemperatureCurve.gains(kelvin: FaceLightPolicy.overlayKelvin)
        let warmWhite = NSColor(red: CGFloat(gains.red), green: CGFloat(gains.green),
                                blue: CGFloat(gains.blue), alpha: 1)
        dimOverlay.setAlpha(FaceLightPolicy.overlayAlpha, color: warmWhite, for: cgID)
    }

    /// Restores every owed FaceLight prior state — crash-safe recovery at launch, and the
    /// quit-teardown backstop `needsQuitReversion` waits for. A ledger entry only clears once its
    /// restore write is confirmed landed, mirroring `restoreOwedDayPresets`'s ordering.
    private func restoreOwedFaceLightState() async {
        guard !settings.faceLightPriorStateByDisplay.isEmpty else { return }
        var remaining = settings.faceLightPriorStateByDisplay
        for (rawID, prior) in settings.faceLightPriorStateByDisplay {
            guard let observation = displays.first(where: { $0.recordID.rawValue == rawID }),
                  observation.isActive else { continue }
            await restoreFaceLightPrior(prior, for: observation)
            remaining[rawID] = nil
        }
        if remaining != settings.faceLightPriorStateByDisplay {
            settings.faceLightPriorStateByDisplay = remaining
            persistSettings()
        }
    }

    /// Writes one display's pre-FaceLight brightness/contrast back and drops its overlay. The DDC
    /// branch awaits the controller directly (bypassing the coalesced writer) so a caller that awaits
    /// this — quit teardown, launch-time crash recovery — knows the hardware write already landed.
    private func restoreFaceLightPrior(_ prior: FaceLightPolicy.PriorState,
                                       for observation: DisplayObservation) async {
        let id = observation.recordID
        #if !PUBLIC_API_ONLY
        if let controller = await ddcController(for: observation) {
            let maxLevel = Float(brightnessMax[id] ?? 100)
            await controller.write(.brightness, Int((prior.brightness * maxLevel).rounded()))
            brightness[id] = prior.brightness
            if let contrast = prior.contrast {
                await restoreFaceLightContrast(contrast, id: id, controller: controller)
            }
            removeFaceLightOverlay(for: observation)
            return
        }
        #endif
        restoreBrightnessWithoutLeading(prior.brightness, for: observation)
        removeFaceLightOverlay(for: observation)
    }

    #if !PUBLIC_API_ONLY
    private func restoreFaceLightContrast(_ contrast: Float, id: DisplayRecordID,
                                          controller: ExternalDisplayDDC) async {
        let key = DDCControlKey(id: id, vcp: HardwareControl.contrast.vcp)
        let contrastMax = Float(ddcControlMax[key] ?? 100)
        await controller.write(.contrast, Int((contrast * contrastMax).rounded()))
        ddcControlLevel[id, default: [:]][HardwareControl.contrast.vcp] = contrast
    }
    #endif

    private func removeFaceLightOverlay(for observation: DisplayObservation) {
        guard let cgID = observation.cgDisplayID else { return }
        dimOverlay.remove(for: cgID)
    }

    /// Applies a chosen resolution/mode behind the timed auto-revert gate (Issue 6), then re-reads the
    /// topology. A bad/blank resolution can leave a display unreadable, so the change is checkpointed
    /// and reverts itself unless confirmed within the window.
    func setMode(_ mode: DisplayMode, for observation: DisplayObservation) async {
        guard !modeChangeInProgress, pendingRevert == nil else {
            modeChangeError = String(localized: "Confirm or revert the previous mode change first.")
            return
        }
        modeChangeError = nil
        guard let cgID = observation.cgDisplayID, DisplayModeChoices.isValid(mode) else {
            modeChangeError = String(localized: "The display or the selected mode is unavailable.")
            return
        }
        modeChangeInProgress = true
        defer { modeChangeInProgress = false }
        let before = await observer.currentSnapshot().observations
        guard let prior = before.first(where: { $0.cgDisplayID == cgID && $0.recordID == observation.recordID }), prior.isActive else {
            modeChangeError = String(localized: "The display is no longer active. Refresh the display list.")
            return
        }
        if let actual = prior.mode, DisplayModeChoices.matches(actual, requested: mode) { return }
        guard observer.allModes(for: cgID).contains(where: { DisplayModeChoices.matches($0, requested: mode) }) else {
            modeChangeError = String(localized: "This exact mode is no longer available. A different framebuffer or refresh rate is never substituted automatically.")
            return
        }
        // Persist the original arrangement BEFORE the write so a crash during verification can recover.
        Self.writeRevertMarker(before)
        // CGCompleteDisplayConfiguration blocks until the displays are reconfigured (often 1–3 s on
        // HDMI). Off the main actor, so the menu and the rest of the app stay responsive meanwhile.
        let observer = self.observer
        let warnings = await Task.detached(priority: .userInitiated) {
            observer.applyArrangement([.init(displayID: cgID, origin: nil, mode: mode)])
        }.value
        await refresh()
        let actual = await observer.currentSnapshot().observations.first(where: { $0.cgDisplayID == cgID })?.mode
        guard !Task.isCancelled, DisplayModeChoices.verifiedApply(warnings: warnings, actual: actual, requested: mode) else {
            // Never offer Keep when the provider rejected the request or fresh readback differs.
            await restoreArrangement(before)
            let restored = await observer.currentSnapshot().observations.first(where: { $0.cgDisplayID == cgID })?.mode
            let restorationVerified = prior.mode.map { expected in
                restored.map { DisplayModeChoices.matches($0, requested: expected) } ?? false
            } ?? false
            if restorationVerified { Self.clearRevertMarker() }
            modeChangeError = restorationVerified
                ? String(localized: "macOS did not confirm the selected mode. The previous mode was restored.")
                : String(localized: "macOS confirmed neither the selected mode nor the restore. Use emergency recovery; a record of the previous settings was saved.")
            return
        }
        await noteLayoutSelfChange()
        beginRevertWindow(before: before, message: String(localized: "Resolution changed on \(displayName(for: observation))"))
    }

    /// Whether `mode` is a pinned favourite for this display (Batch-2 #3).
    func isFavoriteResolution(_ mode: DisplayMode, for observation: DisplayObservation) -> Bool {
        favorites.isFavorite(mode, for: observation.recordID)
    }

    /// Pins/unpins `mode` as a favourite for this display and persists. Every mode the display offers
    /// goes along so a favourite saved under the old rounded key — which covered a 59.94/60 Hz pair
    /// at once — is first split into exact keys: un-pinning one of the pair keeps the other.
    func toggleFavoriteResolution(_ mode: DisplayMode, for observation: DisplayObservation) {
        favorites.toggle(mode, among: allModes(for: observation), for: observation.recordID)
        try? favoritesStore?.save(favorites)
    }

    /// The display's favourite modes (newest first) among `stops`; favourites it doesn't offer right
    /// now are left out here but stay stored.
    func favoriteResolutions(among stops: [DisplayMode], for observation: DisplayObservation) -> [DisplayMode] {
        favorites.favoriteModes(among: stops, for: observation.recordID)
    }

    /// The display's favourites that none of `stops` matches — kept, listed apart, removable.
    func unavailableFavoriteKeys(among stops: [DisplayMode], for observation: DisplayObservation) -> [String] {
        favorites.unavailableKeys(among: stops, for: observation.recordID)
    }

    /// Removes a favourite by its stored key (one the display doesn't offer has no mode to toggle).
    func removeFavoriteKey(_ key: String, for observation: DisplayObservation) {
        favorites.removeKey(key, for: observation.recordID)
        try? favoritesStore?.save(favorites)
    }

    /// Switches the refresh rate at the current resolution.
    func setRefresh(_ hz: Double, for observation: DisplayObservation) async {
        guard var target = observation.mode else { return }
        target.refreshHz = hz
        await setMode(target, for: observation)
    }

    /// Switches the current resolution between HiDPI (Retina) and non-HiDPI, keeping the best refresh.
    func setHiDPI(_ on: Bool, for observation: DisplayObservation) async {
        guard let cgID = observation.cgDisplayID, let current = observation.mode else { return }
        let candidate = observer.allModes(for: cgID)
            .filter { $0.pointWidth == current.pointWidth && $0.pointHeight == current.pointHeight && $0.isHiDPI == on }
            .max(by: { $0.refreshHz < $1.refreshHz })
        guard let candidate else { return }
        await setMode(candidate, for: observation)
    }

    /// Makes a display the main display by re-anchoring every origin so this one sits at (0,0) — Core
    /// Graphics treats the display at the origin as main, and accepts the negative origins this gives
    /// the other displays, so the physical arrangement is preserved.
    ///
    /// Applies immediately and sticks — no timed auto-revert. Changing the main display never leaves a
    /// display unreadable (both stay usable), so the revert gate (which is for bad resolutions) would
    /// only undo the user's intended change and bounce the menu bar back.
    ///
    /// The shift is computed from a **fresh** snapshot, re-resolving the target by display id: the
    /// observation handed in by the menu can carry a stale origin (cached from before the last
    /// arrangement change), which would compute a zero/wrong shift and silently no-op — exactly the
    /// "set-main does nothing / the other screen stays main" symptom.
    func setMain(for observation: DisplayObservation) async {
        guard let cgID = observation.cgDisplayID else { return }
        let snapshot = await observer.currentSnapshot()
        guard let target = snapshot.observations.first(where: { $0.cgDisplayID == cgID }),
              !target.isMain else { return }
        let dx = -target.origin.x
        let dy = -target.origin.y
        let targets = snapshot.observations.compactMap { obs -> CoreGraphicsProvider.ArrangementTarget? in
            guard let id = obs.cgDisplayID else { return nil }
            return .init(displayID: id,
                         origin: DisplayOrigin(x: obs.origin.x + dx, y: obs.origin.y + dy),
                         mode: nil)
        }
        _ = observer.applyArrangement(targets)
        await refresh()
        await noteLayoutSelfChange()
    }

    // MARK: - Timed auto-revert safety gate (Issue 6)

    /// Countdown length for the resolution revert window (clamped to a sane minimum).
    private var arrangementRevertSeconds: Int { max(3, settings.arrangementAutoRevertSeconds) }

    private func beginRevertWindow(before: [DisplayObservation], message: String) {
        let seconds = arrangementRevertSeconds
        revertGate = TimedRevertGate(before: before, deadline: Date().addingTimeInterval(Double(seconds)))
        revertMessage = message
        // Crash recovery: a marker (same Application Support dir the checkpoints/rotation marker use)
        // lets the next launch restore the prior arrangement if the app dies mid-window.
        Self.writeRevertMarker(before)
        pendingRevert = PendingRevert(message: message, secondsRemaining: seconds)
        // The confirmation renders in-context (menu-bar pop-out and the Settings window), both of which
        // observe `pendingRevert`. The AppKit status item ensures the pop-out is on the right screen.
        revertTask?.cancel()
        revertTask = Task { [weak self] in await self?.driveRevertCountdown() }
    }

    /// Ticks the open window ~5×/second: updates the countdown label and, at the deadline, restores
    /// the prior arrangement. Self-cancels once the gate resolves (keep or revert).
    private func driveRevertCountdown() async {
        while !Task.isCancelled {
            guard var gate = revertGate, gate.isPending else { return }
            let now = Date()
            if let before = gate.tick(now: now) {
                revertGate = gate
                await restoreArrangement(before)
                clearRevertWindow()
                return
            }
            revertGate = gate
            pendingRevert = PendingRevert(message: revertMessage, secondsRemaining: gate.secondsRemaining(now: now))
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// User accepted the change — keep it and close the window.
    func confirmArrangementChange() {
        guard var gate = revertGate, gate.confirm() else { return }
        revertGate = gate
        clearRevertWindow()
    }

    /// User asked to revert now — restore the prior arrangement and close the window.
    func revertArrangementChange() async {
        guard var gate = revertGate, let before = gate.revert() else { return }
        revertGate = gate
        await restoreArrangement(before)
        clearRevertWindow()
    }

    private func clearRevertWindow() {
        revertTask?.cancel()
        revertTask = nil
        revertGate = nil
        pendingRevert = nil
        Self.clearRevertMarker()
    }

    /// Restores each display's exact prior mode + origin (origins also restore which display is main,
    /// since Core Graphics treats the display at (0,0) as main), then its prior mirror state.
    private func restoreArrangement(_ observations: [DisplayObservation]) async {
        let targets = observations.compactMap { obs -> CoreGraphicsProvider.ArrangementTarget? in
            guard let cgID = obs.cgDisplayID else { return nil }
            return .init(displayID: cgID, origin: obs.origin, mode: obs.mode)
        }
        if !targets.isEmpty {
            let observer = self.observer
            _ = await Task.detached(priority: .userInitiated) { observer.applyArrangement(targets) }.value
        }
        // Back to each display's exact prior source (or independence) — not "onto main", which put a
        // display that mirrored a non-main source onto the wrong one.
        let current = await observer.currentSnapshot()
        let steps = MirrorRestorePlan.steps(
            wanted: observations.map { MirrorRestorePlan.Step(target: $0.recordID, source: $0.mirrorSourceID) },
            current: current)
        _ = await applyMirrorSteps(steps, in: current)
        await refresh()
        await noteLayoutSelfChange()
    }

    /// Pending-revert marker (mirrors the rotation marker): the prior arrangement, persisted so a
    /// crash/quit during the window doesn't strand a bad layout — the next launch restores it.
    private static func revertMarkerURL() -> URL? {
        (try? DiskCheckpointStore.defaultDirectory())?.appendingPathComponent("revert.pending")
    }
    private static func writeRevertMarker(_ observations: [DisplayObservation]) {
        guard let url = revertMarkerURL(), let data = try? JSONEncoder().encode(observations) else { return }
        try? data.write(to: url, options: .atomic)
    }
    private static func readRevertMarker() -> [DisplayObservation]? {
        guard let url = revertMarkerURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([DisplayObservation].self, from: data)
    }
    private static func clearRevertMarker() {
        if let url = revertMarkerURL() { try? FileManager.default.removeItem(at: url) }
    }

    /// Turns a live display off (flagship). Routes through the coordinator, which preflights and
    /// refuses to remove the last active surface; on success the display is remembered as
    /// managed-offline so it keeps an "off" card in the menu. Works on any display, the built-in
    /// included, as long as another stays active. Returns whether the disconnect committed, so the
    /// automatic callers (wake re-assert, auto-disconnect) can audit their outcome truthfully.
    @discardableResult
    func setDisplayActive(_ active: Bool, for observation: DisplayObservation,
                          as actor: Actor = .ui) async -> Bool {
        guard !active else { return false }  // turning back on is handled by reconnectOffline
        busy = true
        defer { busy = false }
        let offline = OfflineDisplay(
            recordID: observation.recordID,
            cgID: observation.cgDisplayID ?? 0,
            name: displayName(for: observation),
            displayClass: observation.displayClass)
        backUpWindowServerConfig(before: offline.name)
        let result = try? await coordinator.disconnect(
            observation.recordID,
            options: DisconnectOptions(actor: actor, identityConfidence: 1.0))
        var committed = false
        if case .committed? = result {
            committed = true
            managedOffline.removeAll { $0.recordID == offline.recordID }
            managedOffline.append(offline)
            persistManagedOffline()
        }
        await refresh()
        logDisplayEvent("disconnect:\(committed ? "committed" : "failed") \(offline.name)")
        return committed
    }

    /// Turns a previously turned-off display back on because the user asked for it — from the menu,
    /// a hotkey, or Protected Layout deciding the arrangement wants it lit. Reconnects by raw
    /// display id (a disabled display drops off the online list, so UUID resolution can fail), then
    /// drops it from the managed-offline list and re-reads the topology.
    func reconnectOffline(_ offline: OfflineDisplay) async {
        await reconnectOffline(offline, forgettingIntent: true)
    }

    /// The reconnect above, plus the one question the callers disagree about: does bringing this
    /// display back cancel the standing decision that it should be off?
    ///
    /// From the menu, yes — the user just said so. From the always-one-active safety net, no: that
    /// reconnect is an emergency screen, not a change of mind, and forgetting the entry is precisely
    /// what left the built-in lit with nothing left that remembered why it shouldn't be. The ledger
    /// entry survives, and `WakeConvergencePolicy` puts the display away again once a real screen is
    /// back to cover it — or drops the entry itself once the wake window closes with no rescue.
    ///
    /// The user's own reconnect is also VERIFIED (issue #40): the window server accepting the
    /// request is not a display coming back, and forgetting the entry on acceptance alone is how a
    /// stranded monitor lost its only record. The entry goes when the display is observed lit; if
    /// it never is, the entry stays, stamped, and the off card says what happened.
    @discardableResult
    private func reconnectOffline(_ offline: OfflineDisplay, forgettingIntent: Bool) async -> Bool {
        busy = true
        defer { busy = false }
        if forgettingIntent { stampReconnectFailure(nil, for: offline) }  // a fresh attempt
        do {
            try await lifecycle.reconnect(offline.reconnectID, deadline: Date().addingTimeInterval(10))
        } catch {
            // Keep the ledger entry: it is the ONLY record that this display exists and is owed a
            // reconnect. Forgetting it on a failed attempt orphans the display permanently — the
            // safety net would have nothing left to restore the next time nothing is active.
            #if DEBUG
            Self.err("reconnect failed for \(offline.name): \(error) — keeping it owed")
            #endif
            await refresh()
            logDisplayEvent("reconnect:rejected \(offline.name)")
            if forgettingIntent { await noteReconnectFailure(of: offline) }
            return false
        }
        guard forgettingIntent else {
            await refresh()
            return true
        }
        guard await verifyReconnect(of: offline) else {
            logDisplayEvent("reconnect:notLit \(offline.name)")
            await noteReconnectFailure(of: offline)
            return false
        }
        managedOffline.removeAll { $0.recordID == offline.recordID }
        persistManagedOffline()
        logDisplayEvent("reconnect:lit \(offline.name)")
        return true
    }

    /// Watches the topology until the display is really lit, per `ReconnectVerification`: a patient
    /// wait, one escalation to the public permanent-configuration restore, a second wait.
    private func verifyReconnect(of offline: OfflineDisplay) async -> Bool {
        var phaseStart = Date()
        var escalated = false
        while true {
            await refresh()
            let step = ReconnectVerification.next(
                isLit: ReconnectVerification.isLit(offline, in: displays),
                waited: Date().timeIntervalSince(phaseStart), escalated: escalated)
            switch step {
            case .confirmed:
                return true
            case .failed:
                return false
            case .lookAgain(let delay):
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            case .escalate:
                escalated = true
                phaseStart = Date()
                await appendAudit(ReconnectVerification.escalateAudit(of: offline, actor: .ui, at: Date()))
                logDisplayEvent("reconnect:escalating \(offline.name)")
                CoreGraphicsProvider.restorePermanentConfiguration()
            }
        }
    }

    /// Records a reconnect that produced no display: stamps the ledger entry (which is what the
    /// off card reads), writes the audit entry, and notifies if the user has notifications on.
    private func noteReconnectFailure(of offline: OfflineDisplay) async {
        stampReconnectFailure(Date(), for: offline)
        await appendAudit(ReconnectVerification.failureAudit(of: offline, actor: .ui, at: Date()))
        if settings.displayNotificationsEnabled {
            NotificationDelivery.post(NotificationDelivery.reconnectFailureNotification(for: offline))
        }
    }

    private func stampReconnectFailure(_ date: Date?, for offline: OfflineDisplay) {
        guard let index = managedOffline.firstIndex(where: { $0.recordID == offline.recordID }),
              managedOffline[index].reconnectFailedAt != date else { return }
        managedOffline[index].reconnectFailedAt = date
        persistManagedOffline()
    }

    // MARK: - Diagnostics (display event timeline + exportable bundle)

    /// Adds one line to the display event timeline: what Core Graphics reports right now, and why
    /// we looked. Cheap (a handful of CG calls) and written off the main actor.
    func logDisplayEvent(_ reason: String) {
        let entry = DisplayEventLog.Entry(at: Date(), reason: reason, owed: managedOffline.map(\.name),
                                          displays: DisplayTruth.rows())
        Task.detached(priority: .utility) {
            guard let directory = try? DiskDisplayEventLog.defaultDirectory() else { return }
            await DiskDisplayEventLog(directory: directory).append(entry)
        }
    }

    /// Builds the diagnostics bundle on the Desktop and returns it, or nil if it couldn't be
    /// written. Nothing is sent anywhere — the user attaches the file themselves.
    func exportDiagnostics() async -> URL? {
        logDisplayEvent("export")
        let info = Bundle.main.infoDictionary
        #if PUBLIC_API_ONLY
        let flavor = "public-api-only"
        #else
        let flavor = "full"
        #endif
        let app = DiagnosticsBundle.AppInfo(
            version: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?", flavor: flavor)
        return await Task.detached(priority: .userInitiated) {
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return try? DiagnosticsBundle.export(to: desktop, app: app)
        }.value
    }

    /// Copies macOS's saved display configuration aside before a disconnect, off the main actor
    /// (`WindowServerConfigBackup` explains why). Best-effort; never delays or blocks the disconnect.
    private func backUpWindowServerConfig(before name: String) {
        Task.detached(priority: .utility) {
            guard let root = try? WindowServerConfigBackup.defaultDirectory() else { return }
            WindowServerConfigBackup.snapshot(
                sources: WindowServerConfigBackup.defaultSources(), into: root, label: name, now: Date())
        }
    }

    /// Long-lived subscription to the observer's reconfiguration events: every hotplug, unplug,
    /// sleep, or enable/disable refreshes the UI and re-checks the always-one-active invariant.
    private func observeTopologyChanges() async {
        let stream = await observer.changes()
        for await _ in stream {
            let prior = displays
            // A reconfiguration can mean a monitor was re-plugged or power-cycled — its DDC may have
            // just come back (or gone away), so any negative probe knowledge is stale.
            resetDDCProbeCache()
            await refresh()
            logDisplayEvent("topology")
            await enforceActiveSurfaceInvariant()
            reconcileDisplaySleepGuard()  // external arrived/left → acquire or release the keep-awake assertion
            #if !PUBLIC_API_ONLY
            reconcileAdaptiveLoop()  // externals may have arrived/left → start or stop adaptive
            reconcileAppPresetObserver()  // and start/stop the frontmost-app observer to match
            evaluateAppPresets()  // govern a newly-arrived external (or release a departed one)
            #endif
            let autoDisconnected = await applyAutoDisconnectBuiltInIfNeeded()  // external arrived → built-in off
            postDisplayNotifications(prior: prior, builtInAutoDisconnected: autoDisconnected)  // Batch-2 #5
            // The externals coming back is the event the wake re-assert has been waiting for: only
            // now is there a screen to take over from the display macOS relit.
            await reassertManagedOfflineIntent()
            await evaluateLayoutProtection(trigger: .topologyChange)  // Batch-4 #A: put a drifted layout back
        }
    }

    /// Posts user notifications for a topology transition, per the pure `NotificationPolicy` (Batch-2 #5).
    private func postDisplayNotifications(prior: [DisplayObservation], builtInAutoDisconnected: Bool) {
        let names = Dictionary(
            (prior + displays).map { ($0.recordID, displayName(for: $0)) }, uniquingKeysWith: { _, b in b }
        )
        let events = NotificationPolicy.events(
            prior: prior, current: displays, names: names,
            builtInAutoDisconnected: builtInAutoDisconnected,
            enabled: settings.displayNotificationsEnabled
        )
        for event in events { NotificationDelivery.post(NotificationDelivery.notification(for: event)) }
    }

    /// Toggle for display notifications (Batch-2 #5). Persists and, when turned on, requests
    /// notification authorization (the one-time system prompt).
    func setDisplayNotificationsEnabled(_ enabled: Bool) {
        guard settings.displayNotificationsEnabled != enabled else { return }
        settings.displayNotificationsEnabled = enabled
        persistSettings()
        if enabled { NotificationDelivery.requestAuthorization() }
    }

    /// True when at least one REAL external display is currently present. The `.virtual` exclusion
    /// matters: macOS's placeholder is not a monitor arriving, and treating it as one would make
    /// auto-disconnect turn the built-in off at the exact moment it is the only screen left.
    var hasExternalDisplay: Bool {
        displays.contains { $0.displayClass != .builtIn && $0.displayClass != .virtual }
    }

    /// On an external-arrival edge (and only then), turn the built-in panel off through the gated
    /// coordinator path (Issue 5). The built-in returns when the last external leaves — that's the
    /// existing always-one-active safety net (`enforceActiveSurfaceInvariant`), not duplicated here.
    @discardableResult
    private func applyAutoDisconnectBuiltInIfNeeded() async -> Bool {
        let fire = autoDisconnectPolicy.onTopologyChange(
            enabled: settings.autoDisconnectBuiltInOnExternal,
            externalPresent: hasExternalDisplay
        )
        guard fire, !busy,
              let builtIn = displays.first(where: { $0.displayClass == .builtIn && $0.isActive })
        else { return false }
        #if DEBUG
        Self.err("AUTO-DISCONNECT firing: turning off \(displayName(for: builtIn))")
        #endif
        let committed = await setDisplayActive(false, for: builtIn, as: .system)
        await appendAudit(AutoDisconnectBuiltInPolicy.auditEntry(
            builtIn: builtIn.recordID, committed: committed, at: Date()))
        return true
    }

    /// Toggle for "auto-disconnect the built-in when an external connects" (Issue 5). Persists the
    /// setting; takes effect on the next external arrival (it never disconnects retroactively).
    func setAutoDisconnectBuiltInOnExternal(_ enabled: Bool) {
        guard settings.autoDisconnectBuiltInOnExternal != enabled else { return }
        settings.autoDisconnectBuiltInOnExternal = enabled
        persistSettings()
    }

    /// Toggle for "prevent display sleep while an external is connected" (Issue 3). Persists the
    /// setting and immediately reconciles the power assertion against the current topology.
    func setPreventDisplaySleepWithExternal(_ enabled: Bool) {
        guard settings.preventDisplaySleepWithExternal != enabled else { return }
        settings.preventDisplaySleepWithExternal = enabled
        persistSettings()
        reconcileDisplaySleepGuard()
    }

    /// Toggle for "check for updates automatically". Also re-applies the pair to Sparkle, which
    /// re-schedules its own cycle shortly afterwards.
    func setUpdateCheckEnabled(_ enabled: Bool) {
        guard settings.updateCheckEnabled != enabled else { return }
        settings.updateCheckEnabled = enabled
        persistSettings()
        reconcileAutomaticUpdates()
    }

    /// Toggle for "download and install updates automatically" (opt-in). Inert while automatic checks
    /// are off — the policy decides that, so the setting is remembered rather than silently rewritten.
    func setAutomaticUpdateDownloadEnabled(_ enabled: Bool) {
        guard settings.automaticUpdateDownloadEnabled != enabled else { return }
        settings.automaticUpdateDownloadEnabled = enabled
        persistSettings()
        reconcileAutomaticUpdates()
    }

    /// The one action behind every update affordance: Sparkle checks, downloads, verifies the EdDSA
    /// signature, installs, and relaunches — the app only asks it to start.
    func checkForUpdates() {
        softwareUpdater.checkForUpdates()
    }

    private func reconcileAutomaticUpdates() {
        softwareUpdater.apply(Self.automaticUpdateBehavior(for: settings))
    }

    /// The two update settings as the one value Sparkle is configured from — used at launch (before
    /// `self` exists) and on every toggle, so both paths can't disagree.
    private static func automaticUpdateBehavior(
        for settings: OpenDisplaySettings
    ) -> AutomaticUpdateBehavior {
        SoftwareUpdatePolicy.automaticBehavior(
            checkEnabled: settings.updateCheckEnabled,
            downloadEnabled: settings.automaticUpdateDownloadEnabled)
    }

    /// Acquire or release the keep-awake assertion for the current (toggle, external-presence) state.
    /// Idempotent — safe to call on every topology change and every settings change.
    private func reconcileDisplaySleepGuard() {
        sleepGuard.update(
            enabled: settings.preventDisplaySleepWithExternal,
            externalPresent: hasExternalDisplay
        )
    }

    /// Persists `settings` to the on-disk store (best-effort; a write failure leaves the in-memory
    /// value authoritative for this session).
    private func persistSettings() {
        #if !PUBLIC_API_ONLY
        reconcileGroupBrightnessLoop()
        #endif
        try? settingsStore?.save(settings)
    }

    /// The "one display is always active" safety net. If a topology change leaves nothing the user
    /// can see — e.g. the last external is physically unplugged while the built-in is logically off —
    /// re-enable the built-in (or the most-recently disabled display) so nobody is left staring at a
    /// dark Mac.
    ///
    /// The waiting half is the wake correction. A wake looks identical to an unplug for the second
    /// or two while an external re-negotiates its link, and firing into that window lit the built-in
    /// the user had deliberately turned off — the exact opposite of what they asked for, on every
    /// single wake. `WakeConvergencePolicy` tells the two apart and still bounds the wait, so the
    /// guarantee itself is unchanged: within `defaultRecoveryDeadline` seconds there is a screen,
    /// whatever the display list claims.
    private func enforceActiveSurfaceInvariant() async {
        guard !busy else {
            // A write is in flight, so the world is half-applied and not worth judging. While the
            // screen is dark this re-arms rather than returning: the deadline must never be able to
            // expire in a gap where nothing is scheduled to look again.
            if displaysDarkSince != nil {
                armActiveSurfaceRecheck(after: WakeConvergencePolicy.defaultRecheckStep)
            }
            return
        }
        switch WakeConvergencePolicy.surfaceDecision(wakeConvergenceContext()) {
        case .satisfied:
            activeSurfaceRecheck.cancel()
        case .waitForWakingDisplay(let delay):
            #if DEBUG
            Self.err("ACTIVE-SURFACE GUARD: nothing lit yet, but a display is on its way back — waiting")
            #endif
            armActiveSurfaceRecheck(after: delay)
        case .stranded:
            activeSurfaceRecheck.cancel()
            #if DEBUG
            // The full per-display + gamma dump only where it is worth reading — being stranded is
            // what made this class of bug diagnosable in the first place.
            Self.err(Self.diagnosticState(displays: displays, busy: busy, managedOffline: managedOffline))
            Self.err("ACTIVE-SURFACE GUARD: 0 active displays but NOTHING to restore — stranded!")
            #endif
        case .restore(let fallback):
            activeSurfaceRecheck.cancel()
            #if DEBUG
            Self.err(Self.diagnosticState(displays: displays, busy: busy, managedOffline: managedOffline))
            Self.err("ACTIVE-SURFACE GUARD: 0 active displays — re-enabling \(fallback.name)")
            #endif
            // The ledger entry stays: this is an emergency screen, not the user changing their mind.
            // Outside a wake the next refresh drops it anyway (the display really is back for good);
            // inside one it survives, and the re-assert below puts the display away again.
            let committed = await reconnectOffline(fallback, forgettingIntent: false)
            await appendAudit(
                WakeConvergencePolicy.netActivateAudit(of: fallback, committed: committed, at: Date()))
            await escalateIfStillStranded()
        }
    }

    /// Schedules the next look, re-reading the topology first — the whole question is whether the
    /// world has changed since the last one.
    private func armActiveSurfaceRecheck(after delay: TimeInterval) {
        activeSurfaceRecheck.arm(after: delay) { [weak self] in
            guard let self else { return }
            await self.refresh()
            await self.enforceActiveSurfaceInvariant()
        }
    }

    /// Verifies the rescue actually produced a screen, and escalates if it did not.
    ///
    /// A logical re-enable can report success and still leave nothing on screen — most reliably
    /// when the disable was made by a *different* process (the CLI, or a previous run of this app),
    /// whose app-scoped transaction this process cannot reverse. Reporting "recovered" while the
    /// user stares at a dark panel is the worst possible outcome for this safety net, so the result
    /// is checked against the live topology and, if still stranded, escalated to the public
    /// permanent-configuration restore, which is not bound to any one process's transaction.
    private func escalateIfStillStranded() async {
        await refresh()
        guard WakeConvergencePolicy.visibleSurfaces(in: displays).isEmpty else { return }
        #if DEBUG
        Self.err("ACTIVE-SURFACE GUARD: still no real display — escalating to permanent-config restore")
        #endif
        await appendAudit(WakeConvergencePolicy.netEscalateAudit(at: Date()))
        CoreGraphicsProvider.restorePermanentConfiguration()
        try? await Task.sleep(nanoseconds: 1_500_000_000)  // let the window server settle
        await refresh()
    }

    /// Emergency recovery — always available (PRD LIF-010). `coordinator.reconnectAll()` only sees
    /// the provider snapshot's offline list, which CoreGraphicsProvider never fills, so displays this
    /// app turned off (the persisted `managedOffline` ledger) are reconnected the same verified way
    /// as their own off-card button.
    func reconnectAll() async {
        busy = true
        defer { busy = false }
        _ = await coordinator.reconnectAll()
        for offline in managedOffline {
            await reconnectOffline(offline, forgettingIntent: true)
            busy = true  // the per-display path clears it on return; the batch is still running
        }
        await refresh()
    }

    // MARK: - Wake convergence

    /// Watches the sleep/wake pair, for the app's whole lifetime.
    ///
    /// Deliberately not tied to any toggle. A display the user turned off through OpenDisplay is
    /// already an explicit, per-display instruction — the ledger *is* the saved configuration for
    /// that display — and re-asserting it after macOS relights the panel on wake is the app keeping
    /// the promise it already made, not a new feature that has to be switched on. Protected Layout
    /// sits one rung above (it restores the whole arrangement: origins, modes, main) and stays
    /// opt-in; its wake trigger rides along here rather than owning a second observer.
    ///
    /// Both halves of the pair are observed because the display list moves on both sides of it: the
    /// sleep marks the start of a transition in which nothing a display does is the user's doing,
    /// and the wake is what puts a bound on how long that stays true.
    private func observeSleepAndWake() {
        guard sleepWakeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepWakeObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isBetweenSleepAndWake = true
                    self?.logDisplayEvent("sleep")
                }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.convergeAfterWake() }
                }
            }
        ]
    }

    /// Drops the sleep/wake subscriptions so they can't outlive the app.
    private func stopObservingSleepAndWake() {
        for observer in sleepWakeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        sleepWakeObservers.removeAll()
    }

    /// Everything the app owes the user the moment the machine comes back.
    ///
    /// Order matters and follows the lifecycle precedence ladder in `WakeConvergencePolicy`: make
    /// sure something is lit first, then put back what the user turned off, then — if Protected
    /// Layout is on — restore the rest of the arrangement around it. Each step is separately
    /// re-armed by the topology events that keep arriving as displays finish waking, so a display
    /// that takes ten seconds to light up is still converged on when it does.
    private func convergeAfterWake() async {
        logDisplayEvent("wake")
        lastWakeAt = Date()
        isBetweenSleepAndWake = false  // the transition is over; the bounded window starts now
        offlineReassertAttempts.removeAll()  // a new wake is a fresh world; prior attempts don't count
        // A dark spell stamped as the machine went down must not count against the recovery
        // deadline: measured from a pre-sleep stamp, the net would light its fallback on the very
        // first post-wake look instead of giving returning displays their eight seconds. The
        // refresh below re-stamps "now" if the screens really are still dark.
        displaysDarkSince = nil
        await refresh()
        await enforceActiveSurfaceInvariant()
        await reassertManagedOfflineIntent()
        await evaluateLayoutProtection(trigger: .wake)
    }

    /// Puts back off every display the ledger owns that woke up with the machine.
    ///
    /// This is the fix for the reported bug in one function: macOS relights the built-in on wake
    /// (its own display-configuration transactions don't survive a sleep), the app used to read that
    /// as "the user turned it back on", drop the ledger entry, and leave the laptop panel glowing
    /// next to the externals for the rest of the session. Now the return is recognised for what it
    /// is and undone — but only once something else is lit to take over, and only a bounded number
    /// of times, so the safety net's guarantee is never the thing being argued with.
    private func reassertManagedOfflineIntent() async {
        offlineIntentRecheck.cancel()
        let intent = WakeConvergencePolicy.offlineIntent(wakeConvergenceContext())
        // "Ask again" either because the policy said so (nothing lit yet to take over) or because a
        // write is already in flight — an owed "off" must never be dropped on the floor for want of
        // something scheduled to notice it again.
        let isDeferredByAWriteInFlight = busy && !intent.reassert.isEmpty
        if let delay = isDeferredByAWriteInFlight
            ? WakeConvergencePolicy.defaultReassertRecheckStep
            : intent.recheckAfter {
            offlineIntentRecheck.arm(after: delay) { [weak self] in
                guard let self else { return }
                await self.refresh()
                await self.reassertManagedOfflineIntent()
            }
        }
        guard !busy, !intent.reassert.isEmpty else { return }
        for offline in intent.reassert {
            guard let live = displays.first(where: { $0.recordID == offline.recordID && $0.isActive })
            else { continue }
            offlineReassertAttempts[offline.recordID, default: 0] += 1
            #if DEBUG
            Self.err("WAKE: \(offline.name) came back with the machine — turning it off again")
            #endif
            let committed = await setDisplayActive(false, for: live, as: .wakeConvergence)
            await appendAudit(
                WakeConvergencePolicy.reassertAudit(of: offline, committed: committed, at: Date()))
            // Convergence pays the owed "off", so the wake's stamp comes off with it. Leaving it
            // would make a later re-enable in System Settings read as still-owed and be undone.
            if committed,
               let index = managedOffline.firstIndex(where: { $0.recordID == offline.recordID }) {
                managedOffline[index].relitDuringWakeAt = nil
                persistManagedOffline()
            }
        }
    }

    /// The observed world both wake-convergence decisions reason over.
    private func wakeConvergenceContext() -> WakeConvergencePolicy.Context {
        WakeConvergencePolicy.Context(
            now: Date(), observations: displays, managedOffline: managedOffline,
            lastWakeAt: lastWakeAt, isBetweenSleepAndWake: isBetweenSleepAndWake,
            darkSince: displaysDarkSince, reassertAttempts: offlineReassertAttempts)
    }

    /// Appends one entry to the shared on-disk audit trail — the same file the CLI and App Intents
    /// write through the gateway — so "why did my display just switch?" is answerable from Settings →
    /// Recent Activity rather than guessed at. Every automatic display write in this file (wake
    /// re-assert, safety net, auto-disconnect, Protected Layout) reports through here.
    private func appendAudit(_ entry: AuditEntry) async {
        guard let directory = try? DiskAuditLog.defaultDirectory() else { return }
        await DiskAuditLog(directory: directory).append(entry)
    }

    // MARK: - Protected Layout (Batch-4 #A)

    /// The display-set key the current topology protects under (`LayoutProtectionPolicy`).
    /// Published so the Arrange tab's status line follows a hotplug without a reopen.
    @Published private(set) var currentLayoutFingerprint = ""
    /// The protected layout for the display set that is on the desk right now, or nil when this set
    /// isn't protected. Drives the Arrange tab's status line and its Update/Remove buttons.
    var protectedLayoutForCurrentSet: ProtectedConfig? {
        settings.protectedLayouts[currentLayoutFingerprint]
    }

    /// Marks the live arrangement as the one to keep for this display set. Re-protecting overwrites,
    /// so the same button serves as "Update".
    func protectCurrentLayout() async {
        let snapshot = await observer.currentSnapshot()
        // The ledger goes in with it: "and the built-in is off" is part of this arrangement, and on
        // the experimental path it is the only place that fact survives — a logically disabled
        // display leaves nothing behind in the enumeration to capture.
        let captured = LayoutProtectionPolicy.capture(snapshot, managedOffline: managedOffline,
                                                      at: Date())
        settings.protectedLayouts[captured.fingerprint] = captured.config
        persistSettings()
        currentLayoutFingerprint = captured.fingerprint
        // The freshly captured arrangement IS the protected one, so nothing is owed a restore —
        // clear the retry budget a previous failure may have spent.
        layoutProtectionState = LayoutProtectionPolicy.State()
    }

    /// Forgets one stored layout (the current set's, or another set's from the list).
    func removeProtectedLayout(fingerprint: String) {
        guard settings.protectedLayouts.removeValue(forKey: fingerprint) != nil else { return }
        persistSettings()
    }

    /// Master toggle for Protected Layout. Turning it on checks the current arrangement straight
    /// away; turning it off drops any pending re-check. The wake trigger itself belongs to
    /// `observeSleepAndWake`, which runs whatever this toggle says — the ledger is re-asserted on
    /// wake with or without whole-arrangement protection.
    func setLayoutProtectionEnabled(_ enabled: Bool) {
        guard settings.layoutProtectionEnabled != enabled else { return }
        settings.layoutProtectionEnabled = enabled
        persistSettings()
        guard enabled else {
            layoutProtectionRecheck.cancel()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.evaluateLayoutProtection(trigger: .launch)
        }
    }

    /// One protection check: measure the live arrangement against this display set's protected one
    /// and put it back when it has drifted. Driven by every topology event, by wake, and once at
    /// launch. All the deciding — which drifts matter, the managed-offline rule, suppression,
    /// debounce, retry cap — is the pure `LayoutProtectionPolicy`; this only reads the world and
    /// performs the writes.
    func evaluateLayoutProtection(trigger: LayoutProtectionPolicy.Trigger) async {
        layoutProtectionRecheck.cancel()
        let snapshot = await observer.currentSnapshot()
        // The ledger is part of the key. Without it the fingerprint changes the instant macOS
        // relights a display the user turned off — so on wake the app would look up a display set
        // it had never protected and conclude, correctly and uselessly, that there is nothing to
        // restore. That miss is why protection did nothing at the one moment it was needed.
        let fingerprint = LayoutProtectionPolicy.fingerprint(
            for: snapshot,
            managedOffline: LayoutProtectionPolicy.switchedOffIDs(in: snapshot,
                                                                  ledger: managedOffline))
        // Republish only on a real change: this runs on every topology event, and reassigning a
        // @Published value re-evaluates every observing view.
        if currentLayoutFingerprint != fingerprint { currentLayoutFingerprint = fingerprint }
        guard settings.layoutProtectionEnabled else { return }
        let protected = settings.protectedLayouts[currentLayoutFingerprint]
        let evaluation = LayoutProtectionPolicy.decide(
            current: snapshot, protected: protected, trigger: trigger,
            context: layoutProtectionContext(), state: layoutProtectionState)
        layoutProtectionState = evaluation.state
        if evaluation.shouldNotifyFailure,
           let note = NotificationDelivery.layoutRestoreFailureNotification(
            enabled: settings.displayNotificationsEnabled) {
            NotificationDelivery.post(note)
        }
        if let delay = evaluation.recheckAfter {
            layoutProtectionRecheck.arm(after: delay) { [weak self] in
                await self?.evaluateLayoutProtection(trigger: trigger)
            }
            return
        }
        guard case .restore(let analysis) = evaluation.decision, let protected else { return }
        layoutProtectionState = LayoutProtectionPolicy.noteRestoreAttempt(state: layoutProtectionState)
        await restoreProtectedLayout(protected, analysis: analysis, before: snapshot.generation)
    }

    /// Marks whatever the app just wrote as OpenDisplay's own doing, so Protected Layout never
    /// undoes a change the user asked *this app* for. The CG generation is recomputed on read and
    /// covers origin/mode/rotation/mirror/main, so the fresh snapshot already carries the generation
    /// our write raised — no waiting needed.
    private func noteLayoutSelfChange() async {
        guard settings.layoutProtectionEnabled else { return }
        let snapshot = await observer.currentSnapshot()
        layoutProtectionState = LayoutProtectionPolicy.noteSelfChange(
            generation: snapshot.generation, state: layoutProtectionState)
    }

    /// The observed world the policy reasons over.
    private func layoutProtectionContext() -> LayoutProtectionPolicy.Context {
        LayoutProtectionPolicy.Context(
            now: Date(),
            isEnabled: settings.layoutProtectionEnabled,
            asleepDisplayIDs: sleepingDisplayIDs(),
            managedOfflineIDs: Set(managedOffline.map(\.recordID)),
            // Read-only rotation backend (default, and the only one in the public build): rotation
            // drift is excluded rather than "restored" by a scene apply that cannot rotate.
            canRestoreRotation: rotationWritable)
    }

    /// Displays macOS reports as asleep right now. The observer already folds sleep into `isActive`
    /// (`DisplayActivity.isActiveSurface`); passing the set explicitly keeps the policy correct even
    /// for a snapshot that came from somewhere else, and makes the 0.8.2 rule impossible to lose.
    private func sleepingDisplayIDs() -> Set<DisplayRecordID> {
        Set(displays.filter { observation in
            observation.cgDisplayID.map { CGDisplayIsAsleep($0) != 0 } ?? false
        }.map(\.recordID))
    }

    /// Puts the protected arrangement back: geometry through the existing `applyScene` path, on/off
    /// differences through the same lifecycle calls the menu uses, and mirror state alongside (the
    /// scene model has no mirror field). Audits the attempt and its outcome, suppresses the
    /// generation our own writes raise, and tells the user what moved.
    private func restoreProtectedLayout(_ config: ProtectedConfig,
                                        analysis: DisplayConfigDrifter.DriftAnalysis,
                                        before generation: TopologyGeneration) async {
        await appendLayoutProtectionAudit(status: "attempted", analysis: analysis)
        await restoreProtectedActiveState(config, analysis: analysis)
        // Before the scene: the saved origins were captured with the saved rotation.
        await restoreProtectedRotation(config, analysis: analysis)
        await applyScene(LayoutProtectionPolicy.restoreScene(for: config))
        await restoreProtectedMirroring(config, analysis: analysis)

        let settled = await observer.awaitStableGeneration(after: generation)
        // Suppress the generation our writes raised — or, when they raised none, clear the
        // suppression `applyScene` optimistically took, so a restore that didn't land can be retried
        // instead of silencing the drift it failed to fix.
        layoutProtectionState = LayoutProtectionPolicy.noteRestoreOutcome(
            before: generation, after: settled.generation, state: layoutProtectionState)
        let residual = LayoutProtectionPolicy.actionableDrift(
            protected: config.snapshot, current: settled, context: layoutProtectionContext())
        let restored = !(residual?.hasDrifted ?? false)
        await appendLayoutProtectionAudit(status: restored ? "committed" : "partial", analysis: analysis)
        guard restored, let note = NotificationDelivery.layoutRestoreNotification(
            for: analysis, names: layoutProtectionDisplayNames(), enabled: settings.displayNotificationsEnabled)
        else { return }
        NotificationDelivery.post(note)
    }

    /// Restores the on/off differences the policy asked for through the paths the menu already uses —
    /// `reconnectOffline` to bring one back, the gated coordinator disconnect to put one away — so
    /// the safety net, the ledger, and the audit trail behave exactly as they always do.
    ///
    /// `appeared` counts as an activity change here, and it is the shape the reported wake bug takes
    /// on the experimental path: the arrangement was captured with the built-in truly disabled, so
    /// the built-in is absent from the stored snapshot entirely, and macOS relighting it reads as a
    /// display that appeared out of nowhere rather than one that switched on. The policy only marks
    /// it actionable when the arrangement says that display must be off, so the wanted state for
    /// every id reaching here is simply "off unless the arrangement lists it as lit".
    private func restoreProtectedActiveState(_ config: ProtectedConfig,
                                             analysis: DisplayConfigDrifter.DriftAnalysis) async {
        let wantsOff = LayoutProtectionPolicy.desiredOff(in: config.snapshot)
        for change in analysis.changes {
            let id: DisplayRecordID
            switch change {
            case .activeChanged(let changed), .appeared(let changed): id = changed
            default: continue
            }
            let wanted = !wantsOff.contains(id)
            if wanted, let offline = managedOffline.first(where: { $0.recordID == id }) {
                await reconnectOffline(offline)
            } else if !wanted, let live = displays.first(where: { $0.recordID == id && $0.isActive }) {
                await setDisplayActive(false, for: live)
            }
        }
    }

    /// Puts back a rotation the policy marked actionable — which it does only while the gated
    /// experimental rotation backend is on (`Context.canRestoreRotation`). Goes through
    /// `setRotation`, the one rotation writer with the recovery marker and the safe-angle rollback;
    /// `applyScene` cannot rotate at all.
    private func restoreProtectedRotation(_ config: ProtectedConfig,
                                          analysis: DisplayConfigDrifter.DriftAnalysis) async {
        guard rotationWritable else { return }
        for change in analysis.changes {
            guard case .rotationChanged(let id) = change,
                  let wanted = config.snapshot.observation(for: id)?.rotation,
                  let live = displays.first(where: { $0.recordID == id && $0.isActive }),
                  currentRotation(for: live) != wanted.rawValue else { continue }
            await setRotation(wanted.rawValue, for: live)
        }
    }

    /// Re-applies the protected mirror relationships. `DesiredState` carries no mirror field, so this
    /// rides alongside the scene apply exactly as the arrangement-revert path does.
    ///
    /// Driven strictly by the changes the policy marked actionable, never by a fresh comparison
    /// against the stored snapshot: a display the user turned off is mirrored onto main by the
    /// public lifecycle provider, so comparing mirror state directly would un-mirror — turn back
    /// on — exactly the display that must stay off. The policy filters those out; reading its
    /// answer is what keeps that guarantee from being quietly re-derived here.
    ///
    /// Each target goes back to the exact source it was saved with (`mirrorRestoreSteps`), not to
    /// "mirrored onto whatever is main" — a C→A arrangement that drifted to C→B is put back to C→A.
    private func restoreProtectedMirroring(_ config: ProtectedConfig,
                                           analysis: DisplayConfigDrifter.DriftAnalysis) async {
        let current = await observer.currentSnapshot()
        let steps = LayoutProtectionPolicy.mirrorRestoreSteps(
            protected: config.snapshot, current: current, analysis: analysis)
        if await applyMirrorSteps(steps, in: current) { await refresh() }
    }

    /// Performs mirror steps against fresh Core Graphics IDs from `snapshot`. A step whose display or
    /// source has no live ID is skipped rather than substituted. Returns whether anything was written.
    /// A rejected write isn't retried here: Protected Layout's residual check reports it, and the
    /// keep/revert path (like before) relies on the refreshed topology the menus then show.
    private func applyMirrorSteps(_ steps: [MirrorRestorePlan.Step], in snapshot: TopologySnapshot) async -> Bool {
        var wrote = false
        for step in steps {
            guard let target = snapshot.observation(for: step.target)?.cgDisplayID else { continue }
            var source: CGDirectDisplayID?
            if let sourceID = step.source {
                guard let live = snapshot.observation(for: sourceID)?.cgDisplayID else { continue }
                source = live
            }
            _ = await observer.setMirrorSource(of: target, to: source)
            wrote = true
        }
        return wrote
    }

    /// Display names for the restore notification, covering displays that have since left.
    private func layoutProtectionDisplayNames() -> [DisplayRecordID: String] {
        Dictionary(displays.map { ($0.recordID, displayName(for: $0)) },
                   uniquingKeysWith: { _, latest in latest })
    }

    /// Records a protected-layout restore in the shared audit trail. `command: "layoutProtection"`
    /// with the `system` actor — the app acted on its own, on the user's standing instruction.
    private func appendLayoutProtectionAudit(status: String,
                                             analysis: DisplayConfigDrifter.DriftAnalysis) async {
        await appendAudit(AuditEntry(
            timestamp: Date(), actor: .system, command: "layoutProtection",
            transactionId: "txn_layoutProtection", status: status,
            targets: analysis.changes.compactMap(\.displayID).map(\.rawValue)))
    }

    // MARK: - Quit-time revert

    /// True when the app has put the system into a non-default state whose reversal needs async work
    /// before the process exits — currently, a display it logically turned off. Gamma dim and the
    /// keep-awake assertion are restored synchronously by the `willTerminate` backstop, so they don't
    /// gate termination on their own.
    var needsQuitReversion: Bool {
        if !managedOffline.isEmpty { return true }
        #if !PUBLIC_API_ONLY
        // An applied evening colour preset owes the monitor its daytime preset back — quitting
        // must wait for that DDC write (the willTerminate backstop can't do async I2C).
        if !settings.adaptiveDayPresetByDisplay.isEmpty { return true }
        // An active app preset owes its governed displays their pre-preset state back (Issue #33) —
        // the DDC restore must land before the process exits, same as the evening-preset case.
        if !settings.appPresetPriorStateByDisplay.isEmpty { return true }
        #endif
        // An active FaceLight owes the display its pre-fill-light brightness/contrast back — same
        // reasoning as the evening-preset case above.
        if !settings.faceLightPriorStateByDisplay.isEmpty { return true }
        return false
    }

    /// Reverts every app-made system change so quitting returns the Mac to a clean default: reconnect
    /// any display we turned off, lift any software dim/blackout, and drop keep-awake assertions. The
    /// delegate's `applicationShouldTerminate` defers termination until this completes so the
    /// reconnect actually lands before the process exits.
    func teardownForQuit() async {
        #if !PUBLIC_API_ONLY
        // Stop adaptive first, then hand back the monitor's daytime colour preset if the evening
        // one is applied — awaited directly (the coalesced writers are fire-and-forget; quitting
        // must not race them).
        adaptiveLoop?.cancel()
        adaptiveLoop = nil
        stopAppPresetObserver()
        await restoreOwedDayPresets()
        await restoreOwedAppPresetState()  // hand each governed display its pre-preset state back
        #endif
        await restoreOwedFaceLightState()
        // Reconnect each off-card the way `reconnectOffline(_:)` does — by raw display id, since a
        // disabled display drops off the online list. `coordinator.reconnectAll()` only sees the
        // observer snapshot's offline list, which doesn't include this persisted `managedOffline`
        // set, so it would no-op here and leave the display off.
        for offline in managedOffline {
            try? await lifecycle.reconnect(offline.reconnectID, deadline: Date().addingTimeInterval(10))
        }
        if !managedOffline.isEmpty {
            managedOffline.removeAll()
            persistManagedOffline()
        }
        CoreGraphicsProvider.restoreGamma()
        gammaOwned.removeAll()  // every table is ColorSync's again
        softwareDim.removeAll()
        dimOverlay.removeAll()
        xdrRampTask?.cancel()
        xdrBoostFraction.removeAll()
        xdrTrigger.disengage()  // process-bound anyway; dropped now so the backlight relaxes at once
        // A user-driven "put everything back" is the user setting the boost to zero: it disarms the
        // auto-off deadline and cancels any restore the automations were still owing.
        xdrPowerAutomation.noteUserSet(fraction: 0, at: Date())
        reconcileXDRPowerAutomation()
        sleepGuard.releaseAll()
    }

    // MARK: - Global keyboard shortcuts (Batch-2 #4)

    /// Registers a Carbon global hotkey for every bound action in the (defaults-merged) shortcut
    /// registry, mapping each to its handler. Reconnect-All honours the existing enable toggle.
    private func registerHotkeys() {
        hotKeys.removeAll()
        let registry = settings.hotkeyShortcuts.mergedWithDefaults()
        var nextID: UInt32 = 1
        for action in HotkeyAction.allCases {
            guard let binding = registry.binding(for: action) else { continue }
            if action == .reconnectAll && !settings.reconnectAllHotkeyEnabled { continue }
            if let hotkey = GlobalHotKey(keyCode: binding.keyCode, modifiers: binding.modifiers,
                                         id: nextID, action: hotkeyHandler(for: action)) {
                hotKeys.append(hotkey)
            }
            nextID += 1
        }
        for entry in registry.inputSwitchBindings {
            if let hotkey = GlobalHotKey(keyCode: entry.binding.keyCode, modifiers: entry.binding.modifiers,
                                         id: nextID, action: inputSwitchHotkeyHandler(for: entry)) {
                hotKeys.append(hotkey)
            }
            nextID += 1
        }
    }

    private func inputSwitchHotkeyHandler(for entry: InputSwitchBinding) -> () -> Void {
        { [weak self] in Task { await self?.switchInputByHotkey(entry) } }
    }

    private func hotkeyHandler(for action: HotkeyAction) -> () -> Void {
        switch action {
        case .reconnectAll:
            return { [weak self] in
                #if DEBUG
                AppModel.debugMarkHotKeyFired()
                #endif
                Task { await self?.reconnectAll() }
            }
        case .cycleMainDisplay:
            return { [weak self] in Task { await self?.cycleMainDisplay() } }
        case .brightnessUp:
            return { [weak self] in Task { await self?.adjustMainBrightness(by: 0.1) } }
        case .brightnessDown:
            return { [weak self] in Task { await self?.adjustMainBrightness(by: -0.1) } }
        case .faceLight:
            return { [weak self] in
                guard let self, let main = self.displays.first(where: \.isMain) else { return }
                self.toggleFaceLight(for: main)
            }
        }
    }

    /// Adds (or replaces, matching by id) an input-switch hotkey binding (todo 4), persists it, and
    /// re-registers every hotkey immediately so the new chord takes effect without a relaunch.
    func addInputSwitchHotkey(_ entry: InputSwitchBinding) {
        var updatedRegistry = settings.hotkeyShortcuts
        updatedRegistry.addInputSwitchBinding(entry)
        settings.hotkeyShortcuts = updatedRegistry
        persistSettings()
        registerHotkeys()
    }

    /// Removes an input-switch hotkey binding, persists, and re-registers.
    func removeInputSwitchHotkey(id: String) {
        var updatedRegistry = settings.hotkeyShortcuts
        updatedRegistry.removeInputSwitchBinding(id: id)
        settings.hotkeyShortcuts = updatedRegistry
        persistSettings()
        registerHotkeys()
    }

    /// True if `combo` is already claimed by any registered hotkey (fixed action or input-switch)
    /// other than `excludingInputSwitchID` — the settings UI's pre-save conflict check.
    func inputSwitchHotkeyConflicts(_ combo: KeyBinding, excludingInputSwitchID: String?) -> Bool {
        settings.hotkeyShortcuts.inputSwitchBindingConflicts(combo, excludingInputSwitchID: excludingInputSwitchID)
    }

    /// Makes the next active display the main display (wraps around).
    func cycleMainDisplay() async {
        let actives = displays.filter(\.isActive)
        guard actives.count > 1 else { return }
        let idx = actives.firstIndex(where: { $0.isMain }) ?? 0
        await setMain(for: actives[(idx + 1) % actives.count])
    }

    /// Nudges the configured brightness-key target, clamped to 0...1.
    func adjustMainBrightness(by delta: Float) async {
        guard let main = MediaKeyTargetPolicy.target(
            for: .brightnessUp, in: displays, cursor: cursorInCGCoordinates(),
            mode: settings.mediaKeyTargetMode, volumeCapable: [], audioTarget: nil) else { return }
        if brightnessMethod[main.recordID] == nil { await refreshBrightness(for: main) }
        let current = brightness[main.recordID] ?? 0.5
        setBrightness(max(0, min(1, current + delta)), for: main, origin: .keys)
    }

    // MARK: - OSD HUD + media keys (Batch-3)

    /// Show the OSD HUD for a brightness/volume change and (when enabled) broadcast it for external/
    /// notch HUDs (Batch-3 #4/#6). The single funnel that `setBrightness` / `setHardwareControl(.volume)`
    /// call, so the HUD fires for every in-app source (menu slider, media keys).
    func presentOSD(kind: OSDContent.Kind, value: Float, for observation: DisplayObservation,
                    source: String = "app") {
        let content = OSDContent(kind: kind, value: value)
        if settings.osdEnabled && settings.osdStyle != .external {
            osdHUD.present(content, cgDisplayID: observation.cgDisplayID,
                           style: settings.osdStyle, position: settings.osdPosition)
        }
        if settings.publishOSDEventsEnabled {
            OSDBroadcaster.publish(kind: kind, value: Double(value),
                                   displayID: observation.recordID.rawValue,
                                   displayName: displayName(for: observation), source: source)
        }
    }

    /// Confirms a hotkey-driven input switch with the OSD HUD (todo 4) — the same on-screen
    /// confirmation brightness/volume changes get, so a KVM-style input jump is never silent. Not
    /// broadcast: the external/notch HUD schema (Batch-3 #6) only understands the level-based kinds
    /// today.
    private func presentInputSwitchOSD(inputName: String, for observation: DisplayObservation) {
        guard settings.osdEnabled, settings.osdStyle != .external else { return }
        let content = OSDContent(kind: .input, value: 0, label: inputName)
        osdHUD.present(content, cgDisplayID: observation.cgDisplayID,
                       style: settings.osdStyle, position: settings.osdPosition)
    }

    /// Handle a captured media key (Batch-3 #1/#3). Resolves the target display via the pure
    /// `MediaKeyTargetPolicy`, applies the change through the existing brightness/volume sinks (which
    /// raise the OSD), and returns whether it acted — so the tap can swallow handled keys and let
    /// others (e.g. volume on the built-in) pass through to macOS.
    @discardableResult
    func handleMediaKey(_ action: MediaKeyAction, fineStep: Bool, shiftPressed: Bool = false) -> Bool {
        guard action.acceptsModifiers(shiftPressed: shiftPressed,
            brightnessRequiresShift: settings.brightnessMediaKeysRequireShift) else { return false }
        // Volume/mute follow the system's default audio output (resolved at keypress); brightness
        // follows the configured target mode and ignores this.
        let audioTarget = action.isVolume ? audioOutputDisplayID() : nil
        guard let target = MediaKeyTargetPolicy.target(
            for: action, in: displays, cursor: cursorInCGCoordinates(),
            mode: settings.mediaKeyTargetMode, volumeCapable: volumeCapableDisplayIDs(for: action),
            audioTarget: audioTarget)
        else {
            // The sound goes to a display whose DDC audio isn't confirmed: macOS handles this key,
            // and a background read establishes whether the next one can be taken (TB-02).
            if let audioTarget { probeAudioControls(for: audioTarget) }
            return false
        }
        let id = target.recordID

        switch action {
        case .brightnessUp, .brightnessDown:
            let current = brightness[id] ?? 0.5
            setBrightness(min(1, max(0, current + action.signedDelta(fineStep: fineStep))), for: target,
                          origin: .keys)
        case .volumeUp, .volumeDown:
            // Eligibility guarantees a read-back level; nothing is invented here.
            guard let current = ddcControl(.volume, for: target) else { return false }
            setHardwareControl(.volume, min(1, max(0, current + action.signedDelta(fineStep: fineStep))),
                               for: target)
        case .muteToggle:
            return toggleMute(for: target)
        }
        return true
    }

    /// How a mute toggle would be carried out on this display right now (TB-03): the monitor's own
    /// mute when it reads back, else volume 0 (remembering the level), else nothing.
    func muteAction(for observation: DisplayObservation) -> DDCAudioPolicy.MuteAction {
        DDCAudioPolicy.muteAction(audioCapability(for: observation), remembered: preMuteVolume[observation.recordID])
    }

    /// Mute toggle shared by the mute key and the menu's speaker icon. Returns whether anything was
    /// done, so the key passes to macOS when there is nothing truthful to do (TB-03): no working
    /// audio control, or volume already 0 with no remembered level — an unmute never invents one.
    @discardableResult
    func toggleMute(for observation: DisplayObservation) -> Bool {
        let id = observation.recordID
        switch muteAction(for: observation) {
        case .discrete(let mute):
            setDiscreteMute(mute, for: observation)
        case .zeroVolume(let level):
            preMuteVolume[id] = level
            setHardwareControl(.volume, 0, for: observation)
        case .restore(let level):
            setHardwareControl(.volume, level, for: observation)  // clears `preMuteVolume`
            preMuteVolume[id] = nil
        case .unavailable:
            return false
        }
        return true
    }

    /// What the app knows about a display's DDC audio, for `DDCAudioPolicy`.
    private func audioCapability(for observation: DisplayObservation) -> DDCAudioPolicy.Capability {
        let id = observation.recordID
        let volumeVCP = HardwareControl.volume.vcp
        return DDCAudioPolicy.Capability(
            volume: ddcControl(.volume, for: observation),
            volumeAdvertised: ddcSupports(volumeVCP, for: observation),
            volumeWriteFailed: ddcWriteFailed[id]?.contains(volumeVCP) == true,
            discreteMuted: ddcAudioMuted[id],
            muteWriteFailed: ddcWriteFailed[id]?.contains(Self.ddcAudioMuteVCP) == true)
    }

    /// External displays the volume/mute keys may be consumed for (TB-02). Requires a CONFIRMED DDC
    /// audio control — a read-back volume (or discrete mute, for the mute key) whose last write didn't
    /// fail — not merely "capabilities unread, so maybe": the tap swallows a consumed key, so a
    /// guessed target would leave the user with no volume control at all. The built-in is never
    /// included, so its keys always reach macOS.
    private func volumeCapableDisplayIDs(for action: MediaKeyAction) -> Set<DisplayRecordID> {
        Set(displays.filter { observation in
            guard observation.displayClass != .builtIn else { return false }
            let capability = audioCapability(for: observation)
            return action == .muteToggle
                ? DDCAudioPolicy.muteKeyUsable(capability, remembered: preMuteVolume[observation.recordID])
                : DDCAudioPolicy.volumeKeysUsable(capability)
        }.map(\.recordID))
    }

    /// Starts a background read of a display's volume and mute when a key arrived for it before
    /// they were confirmed. Goes through the probe tracker, so a monitor without DDC audio is not
    /// re-read on every key press, and skips displays OpenDisplay refuses to talk DDC to.
    private func probeAudioControls(for id: DisplayRecordID) {
        #if !PUBLIC_API_ONLY
        guard !audioProbes.contains(id), ddcBindingRefusal[id] == nil,
              ddcProbe[id]?.unsupportedCodes.contains(HardwareControl.volume.vcp) != true,
              let observation = displays.first(where: {
                  $0.recordID == id && $0.isActive && $0.displayClass != .builtIn
              }) else { return }
        audioProbes.insert(id)
        Task { [weak self] in
            guard let self else { return }
            if let controller = await self.ddcController(for: observation) {
                await self.readHardwareControl(.volume, controller: controller, observation: observation)
                await self.refreshDiscreteMute(controller, observation: observation)
            }
            self.audioProbes.remove(id)
        }
        #endif
    }

    /// Requests the monitor's own mute state (VCP 0x8D) through a coalescing writer. The cached state
    /// flips at once — like every DDC control's cache — and the drain's read-back corrects it.
    private func setDiscreteMute(_ mute: Bool, for observation: DisplayObservation) {
        #if !PUBLIC_API_ONLY
        let id = observation.recordID
        ddcAudioMuted[id] = mute
        muteTarget[id] = mute
        if muteWriter[id] == nil {
            muteWriter[id] = Task { [weak self] in await self?.drainMuteWrites(id, observation) }
        }
        #endif
    }

    #if !PUBLIC_API_ONLY
    private func drainMuteWrites(_ id: DisplayRecordID, _ observation: DisplayObservation) async {
        let vcp = Self.ddcAudioMuteVCP
        guard let controller = await ddcController(for: observation) else {
            // Nothing was sent: the monitor is where it was before the toggle.
            if let target = muteTarget[id] { ddcAudioMuted[id] = !target }
            muteTarget[id] = nil
            muteWriter[id] = nil
            return
        }
        while true {
            var lastTarget: Bool?
            var lastSent = true
            while let target = muteTarget[id] {
                muteTarget[id] = nil
                lastTarget = target
                lastSent = await controller.write(vcp: vcp, DDCAudioPolicy.discreteMuteValue(mute: target))
            }
            guard let lastTarget else { break }
            switch await readBackAfterDrain(controller, vcp: vcp, settleNanos: Self.continuousSettleNanos,
                                            superseded: { [weak self] in self?.muteTarget[id] != nil }) {
            case .cancelled: return
            case .superseded: continue
            case .reading(let reading):
                let outcome = DDCWriteVerification.outcome(
                    target: DDCAudioPolicy.discreteMuteValue(mute: lastTarget), readback: reading?.current)
                noteWriteVerification(outcome, vcp: vcp, id: id)
                noteWriteTransport(sent: lastSent, outcome: outcome, vcp: vcp, id: id)
                switch outcome {
                case .applied: ddcAudioMuted[id] = lastTarget
                case .ignored(let actual): ddcAudioMuted[id] = DDCAudioPolicy.discreteMuteState(fromVCPValue: actual)
                case .unknown: if !lastSent { ddcAudioMuted[id] = !lastTarget }  // never reached the panel
                }
            }
            break
        }
        muteWriter[id] = nil
    }
    #endif

    /// The display the system's default audio output is routing through, or nil when the sound isn't
    /// going to a display (built-in speakers, AirPods, USB DAC, aggregate) or can't be matched to one.
    /// Reads CoreAudio at call time and resolves the device→display via the pure matcher, using each
    /// display's OS/hardware name. Volume keys pass through unless this returns a real display.
    private func audioOutputDisplayID() -> DisplayRecordID? {
        guard let output = AudioOutputInfo.currentDefaultOutput() else { return nil }
        // Match on the hardware/OS name, not the alias — the CoreAudio device name carries the product
        // name, so an aliased display would otherwise never match.
        let names = Dictionary(uniqueKeysWithValues: displays.map { ($0.recordID, osDisplayName(for: $0)) })
        return AudioOutputDisplayMatcher.match(
            deviceName: output.name, transport: output.transport, displays: displays, names: names)
    }

    /// The pointer location in Core Graphics (top-left origin) coordinates, to match `observation.origin`
    /// (which comes from `CGDisplayBounds`). `NSEvent.mouseLocation` is bottom-left, so flip about the
    /// primary display's height.
    private func cursorInCGCoordinates() -> DisplayOrigin? {
        let mouse = NSEvent.mouseLocation
        guard let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main)?.frame.height else { return nil }
        return DisplayOrigin(x: Int(mouse.x.rounded()), y: Int((primaryHeight - mouse.y).rounded()))
    }

    /// Create/tear down the media-key tap to match the setting (Batch-3 #3). Idempotent.
    ///
    /// Owns the Accessibility flow end-to-end: when the feature is enabled but the grant is missing,
    /// it shows the system prompt (once per launch) and then polls until the grant appears, arming the
    /// tap the moment it does — the user grants in System Settings and the keys just start working,
    /// no relaunch. (The Debug build is adhoc-signed, so a rebuild can invalidate a previous grant;
    /// this same path recovers that case at next launch.)
    private func reconcileMediaKeyTap() {
        if settings.mediaKeyInterceptionEnabled {
            guard mediaKeyTap == nil else { return }
            let tap = MediaKeyTap { [weak self] action, fineStep, shiftPressed in
                self?.handleMediaKey(action, fineStep: fineStep, shiftPressed: shiftPressed) ?? false
            }
            mediaKeyTap = tap
            if !tap.start() {
                if !promptedForAccessibility {
                    promptedForAccessibility = true
                    MediaKeyTap.promptForAccessibility()
                }
                armMediaKeyTapWhenTrusted(tap)
            }
        } else {
            mediaKeyTapRetry?.cancel()
            mediaKeyTapRetry = nil
            mediaKeyTap?.stop()
            mediaKeyTap = nil
        }
    }

    /// Polls for the Accessibility grant and arms `tap` when it lands. 2s cadence: TCC grants are a
    /// one-time manual act in System Settings, so the window between grant and pickup stays invisible.
    private func armMediaKeyTapWhenTrusted(_ tap: MediaKeyTap) {
        mediaKeyTapRetry?.cancel()
        mediaKeyTapRetry = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.settings.mediaKeyInterceptionEnabled else { return }
                if MediaKeyTap.isAccessibilityTrusted && tap.start() && tap.isActive {
                    self.mediaKeyTapRetry = nil
                    self.objectWillChange.send()
                    return
                }
                self.objectWillChange.send()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Whether the media-key tap is currently capturing keys (true only with the toggle on AND the
    /// Accessibility grant present). Drives the Settings status row.
    var mediaKeysActive: Bool { mediaKeyTap?.isActive == true }

    func retryMediaKeyCapture() {
        mediaKeyTap?.stop()
        mediaKeyTap = nil
        reconcileMediaKeyTap()
    }

    func setBrightnessMediaKeysRequireShift(_ required: Bool) {
        settings.brightnessMediaKeysRequireShift = required
        persistSettings()
    }

    func setSoftwareBrightness(_ enabled: Bool, for observation: DisplayObservation) async {
        let id = observation.recordID
        if enabled {
            settings.softwareBrightnessDisplayIDs.insert(id.rawValue)
            #if !PUBLIC_API_ONLY
            ddcWriters[id]?.cancel()
            ddcWriters[id] = nil
            ddcTarget[id] = nil
            #endif
            brightnessMethod[id] = .software
            brightness[id] = softwareDim[id] ?? 1
        } else {
            settings.softwareBrightnessDisplayIDs.remove(id.rawValue)
        }
        persistSettings()
        await refreshBrightness(for: observation)
    }

    /// Whether an external display is Apple-made — generic DDC is withheld from those unless the
    /// user turned on `setAppleDisplayDDCOverride` for that display (FB-08).
    func isAppleDisplay(_ observation: DisplayObservation) -> Bool {
        guard observation.displayClass != .builtIn, let cgID = observation.cgDisplayID else { return false }
        return DDCEligibility.isAppleDisplay(vendorNumber: Int(CGDisplayVendorNumber(cgID)))
    }

    func appleDisplayDDCOverride(for observation: DisplayObservation) -> Bool {
        settings.ddcAppleDisplayOverrideIDs.contains(observation.recordID.rawValue)
    }

    /// Expert override (FB-08): let generic DDC reach this one Apple display. Scoped to the display's
    /// record, never to Apple displays in general. Either way the cached binding and DDC state for
    /// the display are dropped, so turning it off stops DDC traffic at once instead of after the next
    /// replug, and turning it on probes from scratch.
    func setAppleDisplayDDCOverride(_ allowed: Bool, for observation: DisplayObservation) async {
        let id = observation.recordID
        if allowed {
            settings.ddcAppleDisplayOverrideIDs.insert(id.rawValue)
        } else {
            settings.ddcAppleDisplayOverrideIDs.remove(id.rawValue)
        }
        persistSettings()
        #if !PUBLIC_API_ONLY
        pruneDDCCaches(to: Set(displays.map(\.recordID)).subtracting([id]))
        #endif
        ddcControlLevel[id] = nil
        colorPreset[id] = nil
        inputSource[id] = nil
        ddcWriteIgnored[id] = nil
        ddcWriteFailed[id] = nil
        ddcAudioMuted[id] = nil
        brightnessMethod[id] = nil
        await refreshBrightness(for: observation)
    }

    /// Toggle media-key interception (Batch-3 #3). Persists; prompts for Accessibility when enabling
    /// without the grant; reconciles the tap.
    func setMediaKeyInterceptionEnabled(_ enabled: Bool) {
        guard settings.mediaKeyInterceptionEnabled != enabled else { return }
        settings.mediaKeyInterceptionEnabled = enabled
        persistSettings()
        reconcileMediaKeyTap()  // owns the Accessibility prompt + grant-poll when needed
    }

    func setMediaKeyTargetMode(_ mode: MediaKeyTargetMode) {
        guard settings.mediaKeyTargetMode != mode else { return }
        settings.mediaKeyTargetMode = mode
        persistSettings()
    }

    func setOSDEnabled(_ enabled: Bool) {
        guard settings.osdEnabled != enabled else { return }
        settings.osdEnabled = enabled
        persistSettings()
    }

    func setOSDStyle(_ style: OSDStyle) {
        guard settings.osdStyle != style else { return }
        settings.osdStyle = style
        persistSettings()
    }

    func setOSDPosition(_ position: OSDPosition) {
        guard settings.osdPosition != position else { return }
        settings.osdPosition = position
        persistSettings()
    }

    func setPublishOSDEventsEnabled(_ enabled: Bool) {
        guard settings.publishOSDEventsEnabled != enabled else { return }
        settings.publishOSDEventsEnabled = enabled
        persistSettings()
    }

    #if DEBUG
    /// Diagnostic dump of the observed topology to stderr, gated on `OPENDISPLAY_DUMP` so it is
    /// silent in normal runs. Run the app binary directly with the env var set to verify live
    /// enumeration without needing the menu-bar UI. DEBUG-only (excluded from release / App Store).
    private static func dump(_ snapshot: TopologySnapshot) {
        var out = "OpenDisplay topology \(snapshot.generation):\n"
        for o in snapshot.observations.sorted(by: { $0.recordID.rawValue < $1.recordID.rawValue }) {
            let mode = o.mode.map { "\($0.pixelWidth)x\($0.pixelHeight)@\(Int($0.refreshHz.rounded()))" } ?? "—"
            out += "  \(o.isActive ? "●" : "○") \(o.recordID.rawValue)"
            out += " cgID=\(o.cgDisplayID ?? 0)\(o.isMain ? " [main]" : "")"
            out += " \(o.displayClass.rawValue) \(mode) origin=(\(o.origin.x),\(o.origin.y))"
            out += o.isMirrored ? " mirrors=\(o.mirrorSourceID?.rawValue ?? "")" : ""
            out += "\n"
        }
        FileHandle.standardError.write(Data(out.utf8))
    }

    /// M0 live-test harness (DEBUG only, gated on `OPENDISPLAY_DISCONNECT=<cgID|recordID>`): runs
    /// one real disconnect through the full coordinator transaction, logs the result + stage path
    /// to stderr, then **always reconnects after 3s** so a live test can never strand a display.
    /// Never target the main display — the coordinator blocks removing the last safe surface.
    private func debugDisconnectCycle(token: String) async {
        let snapshot = await observer.currentSnapshot()
        guard let observation = snapshot.observations.first(where: {
            $0.cgDisplayID.map(String.init) == token || $0.recordID.rawValue == token
        }) else {
            Self.err("DISCONNECT: no display matches \(token)")
            return
        }
        let target = observation.recordID
        // Reconnect by raw display ID so restore can't fail on UUID resolution after the display
        // drops off the online list while logically disabled.
        let reconnectID = observation.cgDisplayID.map { DisplayRecordID(rawValue: "cgid:\($0)") } ?? target

        Self.err("DISCONNECT target \(target.rawValue) (cgID \(observation.cgDisplayID ?? 0)) — running coordinator transaction…")
        do {
            let result = try await coordinator.disconnect(
                target, options: DisconnectOptions(actor: .cli, identityConfidence: 1.0)
            )
            let stages = await coordinator.lastTransition.map { "\($0)" }.joined(separator: " → ")
            Self.err("DISCONNECT result: \(result)\n  stages: \(stages)")
        } catch {
            Self.err("DISCONNECT error: \(error)")
        }
        // Proof of mechanism: with the private disable, the target drops out of the online list
        // (or is inactive with NO mirror source). The public mirror fallback would instead leave it
        // online with mirrorSourceID set. Captured during the offline window, before reconnect.
        let post = await observer.currentSnapshot()
        let summary = post.observations
            .map { "\($0.recordID.rawValue) active=\($0.isActive) mirror=\($0.mirrorSourceID?.rawValue ?? "none")" }
            .joined(separator: " | ")
        Self.err("POST-DISCONNECT online=\(post.observations.count): \(summary)")
        // Restore unconditionally so the test is self-healing. The hold is configurable (default
        // 3s) so a cross-process test can re-enable the display from another process meanwhile;
        // forAppOnly also reverts the disable if this process exits first.
        let holdSeconds = ProcessInfo.processInfo.environment["OPENDISPLAY_HOLD_SECONDS"]
            .flatMap(Double.init) ?? 3
        try? await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000))
        do {
            try await lifecycle.reconnect(reconnectID, deadline: Date().addingTimeInterval(10))
            Self.err("RECONNECT \(reconnectID.rawValue): done")
        } catch {
            Self.err("RECONNECT \(reconnectID.rawValue) error: \(error)")
        }
        await refresh()
    }

    private static func err(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Full per-display truth at a guard decision: what the app believes AND what Core Graphics
    /// reports, side by side. Counts alone hid the real failure — "1 active display" can mean a
    /// panel that is listed but showing nothing.
    private static func diagnosticState(displays: [DisplayObservation], busy: Bool,
                                        managedOffline: [OfflineDisplay]) -> String {
        var onlineCount: UInt32 = 0
        CGGetOnlineDisplayList(16, nil, &onlineCount)
        var onlineIDs = [CGDirectDisplayID](repeating: 0, count: Int(onlineCount))
        CGGetOnlineDisplayList(onlineCount, &onlineIDs, &onlineCount)
        var activeCount: UInt32 = 0
        CGGetActiveDisplayList(16, nil, &activeCount)

        let stamp = ISO8601DateFormatter().string(from: Date())
        var out = "\n[\(stamp)] GUARD busy=\(busy) appDisplays=\(displays.count) "
        out += "appActive=\(displays.filter(\.isActive).count) "
        out += "owed=\(managedOffline.map(\.name))\n"
        out += "  CG: online=\(Int(onlineCount)) active=\(Int(activeCount))\n"
        for id in onlineIDs.prefix(Int(onlineCount)) {
            out += "  cgID \(id): CGActive=\(CGDisplayIsActive(id) != 0)"
            out += " CGAsleep=\(CGDisplayIsAsleep(id) != 0)"
            out += " CGOnline=\(CGDisplayIsOnline(id) != 0)"
            out += " CGMain=\(CGDisplayIsMain(id) != 0)"
            out += " builtIn=\(CGDisplayIsBuiltin(id) != 0)"
            out += " bounds=\(CGDisplayBounds(id).width)x\(CGDisplayBounds(id).height)\n"
        }
        for observation in displays {
            out += "  app \(observation.cgDisplayID ?? 0): isActive=\(observation.isActive)"
            out += " class=\(observation.displayClass.rawValue) main=\(observation.isMain)\n"
        }
        // A panel can be listed, active, and still show nothing — gamma driven to black (Black Out,
        // a software dim, a stale XDR boost) or the backlight at zero. Counts can't see that.
        for id in onlineIDs.prefix(Int(onlineCount)) {
            var capacity: UInt32 = 0
            var red = [CGGammaValue](repeating: 0, count: 1024)
            var green = [CGGammaValue](repeating: 0, count: 1024)
            var blue = [CGGammaValue](repeating: 0, count: 1024)
            if CGGetDisplayTransferByTable(id, 1024, &red, &green, &blue, &capacity) == .success,
               capacity > 1 {
                let n = Int(capacity)
                out += "  gamma \(id): mid=\(red[n / 2]) top=\(red[n - 1]) (0 ⇒ black screen)\n"
            }
        }
        return out
    }

    /// Records a global-hotkey activation to stderr AND a fixed file, so a manual keypress test can
    /// be confirmed even when the app is launched via LaunchServices (which doesn't inherit stderr).
    private static func debugMarkHotKeyFired() {
        let message = Data("HOTKEY: Reconnect All triggered\n".utf8)
        FileHandle.standardError.write(message)
        let url = URL(fileURLWithPath: "/tmp/opendisplay_hotkey_fired.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(message)
            try? handle.close()
        } else {
            try? message.write(to: url)
        }
    }
    #endif
}

/// Prefers a primary lifecycle provider and falls back to a public one only when the primary
/// reports the operation `.unsupported` (e.g. the private SkyLight symbols are absent on this OS).
/// Other failures propagate — a real OS rejection must not silently retry by another mechanism.
private struct RoutedLifecycleProvider: LifecycleProvider {
    let primary: any LifecycleProvider
    let fallback: any LifecycleProvider

    let providerID = "routed.lifecycle.v1"
    var isExperimental: Bool { primary.isExperimental }

    func probe(_ environment: ProviderEnvironment) async -> ProviderProbe {
        let probe = await primary.probe(environment)
        return probe.status == .supported ? probe : await fallback.probe(environment)
    }

    func disconnect(_ target: DisplayRecordID, deadline: Date) async throws {
        try await active().disconnect(target, deadline: deadline)
    }

    func reconnect(_ target: DisplayRecordID, deadline: Date) async throws {
        try await active().reconnect(target, deadline: deadline)
    }

    func recover(to checkpoint: Checkpoint) async throws {
        try await active().recover(to: checkpoint)
    }

    /// Pick the provider by probe status — a forward capability check, so an unsupported primary
    /// never even attempts the operation. (`catch as ProviderFailure` is now also boundary-safe: the
    /// shared core ships as dynamic frameworks — see project.yml — so `ProviderFailure` has exactly
    /// one runtime type across all images. Error-based fallback would work too; probe-based routing is
    /// kept because deciding up front beats reacting to a thrown failure.)
    private func active() async -> any LifecycleProvider {
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        let environment = ProviderEnvironment(
            osBuild: "", isAppleSilicon: appleSilicon, transport: .unknown, displayClass: .unknown
        )
        return await primary.probe(environment).status == .supported ? primary : fallback
    }
}

/// Coarse menu-bar load state (a subset of the designed states: scanning → ready/empty).
enum DisplayLoadPhase: Equatable {
    case scanning
    case ready
    case empty
}

/// A provider status row shown in Settings → Diagnostics & Recovery.
struct DisplayDiagnostic: Identifiable, Hashable {
    var id: String { provider }
    var provider: String
    var status: String
    var risk: String
    var experimental: Bool
    var reasons: [String]
}
#endif
