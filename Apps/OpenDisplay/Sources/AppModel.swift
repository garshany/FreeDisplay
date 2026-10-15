#if os(macOS)
import AppKit
import ApplicationServices
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
    lazy var integrationService = IntegrationService(model: self)
    private let contrastReceipts = CoalescedBrightnessReceipts<DisplayRecordID>()
    private let brightnessReceipts = CoalescedBrightnessReceipts<DisplayRecordID>()
    @Published private(set) var displays: [DisplayObservation] = []
    @Published private(set) var statusText = String(localized: "Scanning…")
    @Published private(set) var busy = false
    @Published private(set) var diagnostics: [DisplayDiagnostic] = []
    @Published private(set) var phase: DisplayLoadPhase = .scanning
    @Published private(set) var recentActivity: [AuditEntry] = []
    /// Identity records for the current displays, keyed by the observation's record id.
    @Published private(set) var records: [DisplayRecordID: DisplayRecord] = [:]
    private var liveDisplayIdentities = LiveDisplayIdentityState()
    /// Every display the registry remembers — including ones that aren't plugged in right now —
    /// keyed by the same observation record id `records` uses. This is what lets the Groups card
    /// offer (and name) a display that is currently unplugged or turned off.
    @Published private(set) var registryKnownRecords: [DisplayRecordID: DisplayRecord] = [:]
    /// Every persisted registry record with the observation ids pointing at it — the raw material of
    /// `rememberedDisplays` (Settings → Displays → Remembered). Refreshed with `registryKnownRecords`.
    @Published private(set) var registryInventory: [(record: DisplayRecord, observationIDs: [DisplayRecordID])] = []
    /// A remembered display Settings should show in its Remembered list (set by the tray's
    /// "didn't reconnect" card); the Displays section switches to that list when it is non-nil.
    @Published var rememberedDisplayFocus: String?
    /// How each live display was matched to a remembered record at the last refresh (TB-09), keyed
    /// by observation id — the very decision the registry took, with every record's verdict.
    @Published private(set) var identityExplanations: [DisplayRecordID: IdentityMatchExplanation] = [:]
    /// Automatic forgetting (`RememberedDisplayRetention`) waits for launch to have loaded the
    /// registry and the ledger, and never runs twice at once.
    private var retentionReady = false
    private var retentionRunning = false
    @Published private(set) var scenes: [Scene] = []
    /// Non-fatal note from the last scene apply (e.g. rotation skipped) — shown in the Scenes tab.
    @Published var sceneWarning: String?
    /// Displays the app has logically turned off. The OS drops them from the online list, so we track
    /// them here to keep an "off" card in the menu (with a way back on) and to feed the safety net.
    @Published private(set) var managedOffline: [OfflineDisplay] = []
    /// Cached brightness (0...1) for displays we can control — built-in via DisplayServices, externals
    /// via DDC, or software gamma as a universal fallback. A missing key means "not yet read".
    @Published private(set) var brightness: [DisplayRecordID: Float] = [:] {
        didSet {
            // Dates each entry by its last change, whether a read-back or a requested write put it
            // there, so automation can report how old the cached level is (IN-05) without claiming
            // the device was just read.
            let now = Date()
            for (id, value) in brightness where oldValue[id] != value { brightnessCachedSince[id] = now }
            for id in brightnessCachedSince.keys where brightness[id] == nil { brightnessCachedSince[id] = nil }
        }
    }
    /// When each `brightness` entry last changed value. Not published: it only annotates reads.
    private(set) var brightnessCachedSince: [DisplayRecordID: Date] = [:]
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
    /// What each display's hand-paired DDC channel did at its last binding (TR-06, owner decision
    /// #4): in use, not needed, or not applicable and why. Absent for a display with no pairing.
    @Published private(set) var ddcPairingStatus: [DisplayRecordID: DDCChannelMappingPolicy.Status] = [:]
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
    /// Sequence number of the newest installed-profile scan (`reloadInstalledColorProfiles`).
    private var installedProfilesRead = 0
    /// What ColorSync reports each display is assigned — the profile FILE, so the menus mark the
    /// actual current profile even when two installed files share a name. Absent = not read yet.
    @Published private(set) var colorProfileAssignment: [DisplayRecordID: ICCAssignment] = [:]
    /// Why the last profile change on a display didn't land (ColorSync refused it, or the re-read
    /// shows a different profile); cleared by the next change that does.
    @Published private(set) var colorProfileError: [DisplayRecordID: String] = [:]
    /// Connected displays with a user/shared custom ICC profile assigned — or whose assignment
    /// ColorSync has never reported, which may be one (`ColorProfileGuard`). Only those displays
    /// block gamma unless the user overrode the safeguard; every other display keeps its controls.
    @Published private(set) var customProfileDisplays: Set<DisplayRecordID> = []
    /// The part of `customProfileDisplays` that is there because its assignment couldn't be read,
    /// not because it is custom — so the message can say which.
    @Published private(set) var unverifiedProfileDisplays: Set<DisplayRecordID> = []
    /// What the safeguard last verified about each connected display (`ColorProfileGuard.knowledge`).
    private var colorProfileKnowledge: [DisplayRecordID: ColorProfileGuard.Knowledge] = [:]
    /// Per display, the Core Graphics error of the last gamma write that was rejected; nil once a
    /// write lands. Surfaced next to the software brightness, dimming and temperature controls,
    /// whose cached values are the request — this says the request isn't on screen.
    @Published private(set) var gammaWriteFailures: [DisplayRecordID: Int32] = [:]
    /// Displays whose gamma table currently holds OpenDisplay's formula/table rather than
    /// ColorSync's. Only these ever need handing back, so a display nothing has dimmed or warmed
    /// gets no colour-table call at all.
    private var gammaOwned = GammaWriteTracker()
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

    /// Count of currently-lit PHYSICAL displays. Excludes macOS's placeholder and every virtual or
    /// unverified screen (ours, other apps', DisplayLink, Sidecar), none of which is a surface the
    /// user can be left on; the predicate is `WakeConvergencePolicy`'s so the menu, the safety net,
    /// and the ledger can never disagree about what counts as a screen.
    var activeDisplayCount: Int {
        WakeConvergencePolicy.recoverySurfaces(in: displays).count
    }

    /// Whether turning `display` off would still leave a physical screen to recover from — the
    /// same candidates `SafetyEngine` will accept, so the switch is never offered for a request the
    /// coordinator is bound to refuse (a blacked-out screen is no such surface, there or here).
    func canTurnOff(_ display: DisplayObservation) -> Bool {
        display.isActive
            && !RecoverySurfacePolicy.safeSurfaceCandidates(in: safetyObservations,
                                                            excluding: [display.recordID]).isEmpty
    }

    /// What turning a display off does with the lifecycle provider in use — published from the
    /// provider probe so the menu never promises power-off for what is really a mirror.
    @Published private(set) var logicalOffMethod: LogicalOffMethod = {
        #if PUBLIC_API_ONLY
        return .mirror
        #else
        return .disconnect
        #endif
    }()

    /// True when any provider isn't fully supported — drives the menu-bar caution banner.
    var isDegraded: Bool { diagnostics.contains { $0.status != "supported" } }

    private let observer: CoreGraphicsProvider
    /// The coordinator's observer: `observer` with Black Out stamped in, so disconnect preflight
    /// never takes a blacked-out screen for the one the user is left on (`blackedOut` feeds it).
    private let safetyObserver: BlackOutAwareObserver
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
    /// build instead of each spinning up (and binding) a duplicate IOAVService. Each carries the
    /// token every caller awaiting it re-checks on resumption (`ddcBindingTokens`).
    private var ddcBuilders: [DisplayRecordID: (task: Task<ExternalDisplayDDC.BindingReport, Never>,
                                                build: DDCBindingTokens.Build)] = [:]
    /// A pairing test flash is on the wire; a second one waits for the user to try again.
    private var ddcPairingTestRunning = false
    private let ddcPairingTestSession = DDCChannelTestSession()
    private var testedDDCMapping: DDCChannelMapping?
    private var testedDDCMappingContext: [DDCChannelMapping]?
    private var ddcPairingEpoch: UInt64 = 0
    /// Which build each display's binding answers to; pruning a display forgets it (FB-08).
    private var ddcBindingTokens = DDCBindingTokens()
    private var brightnessMax: [DisplayRecordID: Int] = [:]
    private var ddcTarget: [DisplayRecordID: Int] = [:]
    private var brightnessBeforeDDCWrite: [DisplayRecordID: Float] = [:]
    private var presetBeforeDDCWrite: [DisplayRecordID: Int] = [:]
    private var ddcWriters: [DisplayRecordID: Task<Void, Never>] = [:]
    private let ddcWriterOwnership = CoalescedWriterOwnership<DisplayRecordID>()
    private let ddcControlWriterOwnership = CoalescedWriterOwnership<DDCControlKey>()
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
    private var audioProbes: [DisplayRecordID: (token: UUID, task: Task<Void, Never>)] = [:]
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
    /// Delta-group followers whose unknown level is being read (`refreshUnknownGroupLevels`).
    private var groupLevelReads: Set<DisplayRecordID> = []
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
    var clockModeSession = ClockModeSession()
    var clockModeTask: Task<Void, Never>?
    var clockModeTickInProgress = false
    var clockModeLifecycleSuspended = false
    var clockModeLastRequests: [DisplayRecordID: AutomationRequest] = [:]
    @Published var clockModeConfigurationError: String?
    @Published var clockModeResults: [DisplayRecordID: AutomationResult] = [:]
    @Published var clockModeHolds: [DisplayRecordID: ClockModeSession.Hold] = [:]
    /// Persisted user settings. Mutated only through setters so on-disk and derived state agree.
    @Published private(set) var settings: OpenDisplaySettings
    /// On-disk settings store (Application Support); nil only if that directory can't be resolved.
    private let settingsStore: SettingsStore?
    private var settingsTransferInProgress = false
    /// Holds the "prevent display idle-sleep" power assertion while the toggle is on and an external
    /// display is present (Issue 3). Decision logic is the platform-independent `DisplaySleepGuard`.
    private let sleepGuard: DisplaySleepGuard
    /// Who keeps the displays awake right now, and what macOS granted (FB-12/AM-42) — for Settings.
    @Published private(set) var displaySleepPrevention = DisplaySleepPrevention.Snapshot()
    /// Black click-through overlay windows for the overlay/combined dimming methods. Process-bound —
    /// every overlay disappears with the app, so quit teardown only has the gamma half to restore.
    private let dimOverlay = DimOverlayController()

    /// Pinned favourite resolutions per display (Batch-2 #3), persisted to favorites.json.
    @Published private(set) var favorites = FavoriteResolutions()
    private let favoritesStore: FavoritesStore?
    /// On-disk managed-offline list, shared with the CLI (see `ManagedOfflineStore`).
    private let managedOfflineStore: ManagedOfflineStore?
    /// The launch-time load of the registry, the scenes and the managed-offline ledger
    /// (`awaitStartupLoad`). Set once, in `init`.
    private var startupLoad: Task<Void, Never>?
    /// How the tray is laid out (Settings → Menu): item placement, per-display visibility, icon and
    /// order. Kept in its own file so "Reset menu layout" can't reach a display setting.
    @Published private(set) var menuLayout: MenuLayoutSettings
    private let menuLayoutStore: MenuLayoutStore?

    /// Owns release checks and bridges their state to the app for its lifetime.
    private let softwareUpdater: SoftwareUpdater
    /// What the update affordances (menu rows, About surfaces, Settings sidebar) should currently
    /// say. Mirrored from the updater so the views observe one published property instead of two
    /// objects.
    @Published private(set) var updateStatus = SoftwareUpdateStatus()
    /// The phase alone, for the surfaces that only need that.
    var updatePhase: SoftwareUpdatePhase { updateStatus.phase }
    var updatePresentation: SoftwareUpdatePresentation { softwareUpdater.presentation }
    var checksGitHubReleases: Bool { softwareUpdater.checksGitHubReleases }
    /// Why this build's updater is off, or nil when it runs (`UpdateDistribution`): a source build,
    /// or a build without FreeDisplay's own feed and signing key.
    var updateDistributionRefusal: UpdateDistribution.Refusal? { softwareUpdater.distributionRefusal }

    /// Live "Keep these settings?" prompt for an arrangement-altering change (Issue 6), or nil when no
    /// revert window is open. Drives the countdown banner; the UI calls `confirmArrangementChange()` /
    /// `revertArrangementChange()`.
    @Published private(set) var modeChangeError: String?
    private var modeChangeInProgress = false
    /// A scene's arrangement transaction is being applied (`applyScene`).
    private var sceneApplying = false
    /// A keep/revert rollback (or the launch-time restore of its record) is being written.
    private var arrangementRestoring = false
    /// Whether a mode, canvas, scene or rollback transaction is being written right now.
    private var displayTransactionInFlight: Bool {
        modeChangeInProgress || arrangementApplying || sceneApplying || arrangementRestoring
    }
    /// Whether a Core Graphics display transaction is in flight or a keep/revert window is open.
    /// They run one at a time: a second transaction would race the first one's readback, and a
    /// change written under an open window would be undone by its rollback.
    var displayConfigurationBusy: Bool {
        displayTransactionInFlight || pendingRevert != nil
    }
    @Published private(set) var revertRecordPresentation: RevertRecordPresentation?
    @Published private(set) var revertRecordError: String?
    @Published private(set) var pendingRevert: PendingRevert?
    /// UI state for the timed auto-revert banner. `kind` says what the window protects, so the prompt
    /// names it and a further canvas move knows whether it may keep the previous step.
    struct PendingRevert: Equatable {
        enum Kind: Equatable { case mode, arrangement, mainDisplay }
        var message: String
        var secondsRemaining: Int
        var kind: Kind = .mode
    }
    /// Decision core for the open revert window; `before` is the arrangement to restore on timeout.
    private var revertGate: TimedRevertGate<[DisplayObservation]>?
    private var revertMessage = ""
    private var revertKind: PendingRevert.Kind = .mode
    private var revertTask: Task<Void, Never>?

    /// Edge detector for "auto-disconnect the built-in when an external connects" (Issue 5). Seeded to
    /// the launch topology so a pre-attached external isn't treated as a fresh arrival.
    private var autoDisconnectPolicy = AutoDisconnectBuiltInPolicy()

    /// Native-looking OSD HUD for brightness/volume changes (Batch-3 #4).
    private let osdHUD = OSDHUDController()
    /// Answers receiver apps' OSD settings handshake (IN-16) for the app's lifetime.
    private var osdHandshake: OSDReceiverHandshakeListener?
    /// Active media-key event tap (Batch-3 #3) when interception is on AND Accessibility is granted.
    private var mediaKeyTap: MediaKeyTap?
    /// Re-arms the media-key tap once the Accessibility grant lands. TCC has no notification API, so
    /// without this poll the user must relaunch the app after granting — the #1 "keys don't work" trap.
    private var mediaKeyTapRetry: Task<Void, Never>?
    /// One system Accessibility prompt per launch, max — reconcile runs on every toggle change and at
    /// init, and re-prompting each time would nag.
    private var promptedForAccessibility = false
    /// macOS's sound outputs through public CoreAudio (TR-16): identities, controls and writes.
    private let audioOutputs = CoreAudioOutputs()
    /// The outputs as last read, for Settings and the menu; a key press reads CoreAudio afresh.
    @Published private(set) var audioSnapshot = AudioOutputSnapshot()
    /// The feedback sound owed for a held volume key, played once on its release (FA-20).
    private var releaseFeedback = KeyReleaseFeedback()
    private var shortcutFeedback = ShortcutReleaseFeedback()
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
    /// The one timer behind the configuration and wake delays (SO-10, `ConfiguredReactionSchedule`):
    /// every display event re-arms it, so the user's rules run once, after the last event.
    private let configuredReactionTimer = RecheckTimer()
    private var configuredReactionGeneration = ConfiguredReactionGeneration()
    /// The trigger the pending run reports. A wake outranks the changes that follow it.
    private var pendingReactionTrigger: ConfiguredReactionSchedule.Trigger?
    private var appManagementIsQuitting = false

    /// Safe startup (FA-09): Shift was held at launch, or the app was started with `--safe-mode`.
    let integrationSession = IntegrationSession()

    /// For this whole session OpenDisplay changes nothing on its own (`SafeStartup`); explicit
    /// requests and the recovery safety nets still work, and no setting is altered, so an ordinary
    /// relaunch is all it takes to resume. Read once, here: the key state is only meaningful at launch.
    let safeStartup = SafeStartup.isRequested(arguments: ProcessInfo.processInfo.arguments,
                                              shiftHeld: NSEvent.modifierFlags.contains(.shift))

    init() {
        let observer = CoreGraphicsProvider()
        self.observer = observer
        let checkpoints = AppModel.makeCheckpointStore()
        self.checkpoints = checkpoints
        let lifecycle = AppModel.makeLifecycleProvider(public: observer)
        self.lifecycle = lifecycle
        let safetyObserver = BlackOutAwareObserver(base: observer)
        self.safetyObserver = safetyObserver
        self.coordinator = TopologyCoordinator(
            observer: safetyObserver,
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
        let menuLayoutStore = (try? SettingsStore.defaultDirectory()).map(MenuLayoutStore.init(directory:))
        self.menuLayoutStore = menuLayoutStore
        self.menuLayout = menuLayoutStore?.load() ?? .default
        // Start Sparkle with the user's saved preferences already in place: its first scheduled cycle
        // begins on the next runloop pass, so applying them later would let one check slip through
        // against the wrong settings.
        self.softwareUpdater = SoftwareUpdater(behavior: AppModel.automaticUpdateBehavior(for: settings))
        updateStatus = softwareUpdater.status
        softwareUpdater.onStatusChange = { [weak self] status in self?.updateStatus = status }
        softwareUpdater.onAutomaticDownloadPreferenceChange = { [weak self] enabled in
            self?.setAutomaticUpdateDownloadEnabled(enabled)
        }
        // Register the configurable global hotkeys (Batch-2 #4). Reconnect-All is always-available
        // (recovery hierarchy step 3) and reachable even when the menu bar isn't; the rest are unbound
        // by default. A chord that can't be claimed is simply skipped (menu-bar item remains).
        registerHotkeys()
        observeSleepAndWake()  // re-assert what the user turned off once macOS has woken the desk
        reconcileMediaKeyTap()  // Batch-3 #3: arm the media-key tap if enabled + Accessibility granted
        // TR-16: read-only CoreAudio listeners keep Settings' picture of the outputs current.
        audioOutputs.onChange = { [weak self] snapshot in
            guard let self, self.audioSnapshot != snapshot else { return }
            self.audioSnapshot = snapshot
        }
        audioOutputs.startListening()
        audioSnapshot = audioOutputs.snapshot()
        reconcileXDRPowerAutomation()  // Issue #35: watch power only if an XDR battery rule is armed
        // SO-35: the interactive HUD's bar goes through the same funnels as the menu's sliders.
        osdHUD.foregroundFocusedScreen = { [weak self] in
            guard let self else { return nil }
            return OSDScreenPolicy.focusedScreen(self.focusedWindowDisplayID(), in: self.displays)
        }
        osdHUD.onAdjust = { [weak self] id, kind, level, bypassSync in
            self?.adjustFromOSD(id, kind: kind, level: level, bypassSync: bypassSync)
        }
        // IN-16: always listening, so a receiver asking while the handshake is off hears "disabled"
        // rather than nothing; what a request may change is decided by `OSDReceiverHandshake`.
        osdHandshake = OSDReceiverHandshakeListener { [weak self] incoming in
            self?.answerOSDHandshake(incoming) ?? .init(result: .disabled)
        }
        NotificationDelivery.style = settings.notificationStyle  // SO-12: where notices go
        TrayMotion.animationDuration = settings.applicationTiming.animationDuration  // SO-10
        if settings.displayNotificationsEnabled, settings.notificationStyle == .notificationCenter {
            NotificationDelivery.requestAuthorization()  // Batch-2 #5
        }
        #if DEBUG
        FileHandle.standardError.write(Data("Global hotkeys registered: \(hotKeys.count)\n".utf8))
        #endif
        // Its own task so anything that needs the ledger can wait for exactly this part of launch
        // (`awaitStartupLoad`); the rest of the launch sequence below runs after it, as before.
        let startupLoad = Task {
            await setUpRegistry()
            await setUpScenes()
            await loadManagedOffline()
        }
        self.startupLoad = startupLoad
        Task {
            await startupLoad.value
            retentionReady = true
            logDisplayEvent("launch")
            await refresh()
            integrationSession.start(model: self)
            // Safe startup (FA-09) leaves owed restores in their ledgers rather than writing to the
            // displays unasked; quitting still pays them, as every quit does (`teardownForQuit`).
            if !safeStartup { await restoreOwedFaceLightState() }  // crash-safe: relaunching mid-FaceLight restores it
            await enforceActiveSurfaceInvariant()  // recover if we launched into a stranded (0-active) state
            await reassertManagedOfflineIntent()  // a stamped owed-"off" survives a relaunch; pay it if covered
            reconcileClockMode()
            reconcileDisplaySleepGuard()  // hold/release the keep-awake assertion for the launch topology
            #if !PUBLIC_API_ONLY
            reconcileAdaptiveLoop()  // start adaptive brightness/warmth if enabled for this topology
            if !safeStartup { await restoreOwedAppPresetState() }  // crash-safe: relaunch mid-app-preset restores the baseline
            reconcileAppPresetObserver()  // observe the frontmost app if App Presets is enabled
            #endif
            autoDisconnectPolicy.seed(externalPresent: AutoDisconnectBuiltInPolicy.eligibleExternalPresent(in: displays))  // don't treat a pre-attached external as an arrival
            await evaluateLayoutProtection(trigger: .launch)  // Batch-4 #A: check the launch arrangement
            await writeBaselineCheckpoint()
            if let marker = Self.readRotationMarker() {
                // A prior experimental rotation didn't confirm — restore that display's safe angle and
                // a safe layout, then clear the marker.
                try? await rotationBackend.setRotation(marker.safeAngle, for: marker.cgID)
                _ = await coordinator.reconnectAll(beforeRequest: { [weak self] id in
                    await self?.integrationSession.soft(.softReconnect, display: id, attempt: UUID())
                })
                Self.clearRotationMarker()
                await refresh()
            }
            // A display change started from the menu while launch was still under way has written
            // a record of its own, replacing this one — and its window owns it now.
            if !displayConfigurationBusy, let priorArrangement = Self.readRevertMarker() {
                // An arrangement-revert window was open when the app last died — or its rollback
                // never verified — so restore the prior mode/origin/mirror/main: a bad resolution or
                // mirror must not survive a crash/quit. The record goes only once the restore shows —
                // a recorded display that isn't connected keeps it for the launch after this one.
                let outcome = await restoreArrangement(priorArrangement)
                if RevertMarkerPolicy.mayClearMarker(after: outcome) {
                    Self.clearRevertMarker()
                    refreshRevertRecord()
                } else {
                    Self.retainRevertMarker(after: outcome)
                    refreshRevertRecord()
                    reportUnverifiedRestore(kind: .mode, after: outcome)
                }
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
            MainActor.assumeIsolated {
                self?.releaseAllGamma()
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
                self?.configuredReactionTimer.cancel()
                self?.configuredReactionGeneration.invalidate()
                self?.stopObservingSleepAndWake()
                self?.clockModeTask?.cancel()
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

    /// The bound global recovery hotkey, shown in Settings — whatever chord is in force now, or nil
    /// when Reconnect All has none.
    var reconnectAllHotkey: String? {
        effectiveHotkeyRegistry.binding(for: .reconnectAll).map(KeyBindingFormatter.string(for:))
    }

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
        // The router answers with the probe of the provider it would route to, so its id says which
        // operation "off" is: the Core Graphics fallback mirrors, the SkyLight provider disconnects.
        let method: LogicalOffMethod = lifecycleProbe.providerID == observer.providerID ? .mirror : .disconnect
        if logicalOffMethod != method { logicalOffMethod = method }
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
    private func resolveRecords(_ snapshot: TopologySnapshot, generation: UUID) async -> Bool {
        guard let registry else { return false }
        let observer = self.observer
        let observations = snapshot.observations.filter { $0.cgDisplayID != nil }
        guard !observations.isEmpty else {
            guard liveDisplayIdentities.complete([:], generation: generation) else { return false }
            if !records.isEmpty { records = [:] }
            if !identityExplanations.isEmpty { identityExplanations = [:] }
            await refreshRegistryKnownRecords()
            return true
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
        let resolved = await registry.resolveAllExplained(
            prepared.map { (fingerprint: $0.1, cgUUID: $0.2, displayClass: $0.3) },
            newRecordStrategy: settings.newDisplayIdentityStrategy
        )
        var byID: [DisplayRecordID: DisplayRecord] = [:]
        var explanations: [DisplayRecordID: IdentityMatchExplanation] = [:]
        for (input, result) in zip(prepared, resolved) {
            byID[input.0] = result.record
            explanations[input.0] = result.explanation
        }
        guard liveDisplayIdentities.complete(byID, generation: generation) else { return false }
        records = byID
        if identityExplanations != explanations { identityExplanations = explanations }
        await refreshRegistryKnownRecords()
        return true
    }

    /// Reloads the remembered-display index (every display the registry has ever minted a record
    /// for, keyed by observation id). Refreshed with `records` and on an empty snapshot alike: a
    /// display that isn't here is precisely the one the Groups card needs this index to name.
    private func refreshRegistryKnownRecords() async {
        guard let registry else { return }
        registryKnownRecords = await registry.recordsByObservationID()
        let known = registryKnownRecords.merging(records) { _, live in live }
        TVControlStore.shared.updateVerifiedDisplays(Set(known.keys.filter(canPersistDisplaySettings)))
        // Republish only on a change: every view observing the model re-evaluates on a publish. While a
        // display is present its `lastSeen` moves on every resolve, so this mainly spares the refreshes
        // of a registry with nothing live — comparing without `lastSeen` would leave "last seen" stale.
        let inventory = await registry.rememberedDisplays()
        if !inventory.elementsEqual(registryInventory, by: {
            $0.record == $1.record && $0.observationIDs == $1.observationIDs
        }) { registryInventory = inventory }
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

    /// Applies an arrangement planned on the drag-to-arrange canvas (a drop, or a new main display)
    /// in one Core Graphics transaction, then opens the usual keep/revert window for it.
    ///
    /// The plan is checked against the topology as it is now, not as the canvas drew it: if a
    /// display came, went, changed mode or joined a mirror set meanwhile, nothing is moved. Only
    /// mirror-set sources are positioned — a target is not a desktop of its own, and an origin write
    /// aimed at it can change its mirror set. The readback must keep every mirror set and the planned
    /// main display; otherwise the previous arrangement is restored and Keep is never offered.
    func applyArrangement(_ planned: ArrangementLayout, drawnFrom drawn: ArrangementLayout) async {
        guard !arrangementApplying else { return }
        guard !modeChangeInProgress else {
            arrangementError = String(localized: "A mode change is still being applied. Try again when it’s done.")
            return
        }
        arrangementError = nil
        arrangementNote = nil
        arrangementApplying = true
        defer { arrangementApplying = false }

        let snapshot = await observer.currentSnapshot()
        let live = Self.arrangementLayout(snapshot.observations)
        guard live == drawn else {
            arrangementError = String(localized: "The displays changed in the meantime, so nothing was moved.")
            await refresh()
            return
        }
        let changes = live.originChanges(to: planned)
        guard !changes.isEmpty else { return }
        var targets: [CoreGraphicsProvider.ArrangementTarget] = []
        for (id, origin) in changes {
            guard ArrangementTiles.canMove(id, in: snapshot), let cgID = snapshot.observation(for: id)?.cgDisplayID else {
                arrangementError = String(localized: "The displays changed in the meantime, so nothing was moved.")
                await refresh()
                return
            }
            targets.append(.init(displayID: cgID, origin: origin, mode: nil))
        }
        // Judged only now, after the last suspension point: a countdown can expire (and start
        // restoring) while the snapshot is read. Another canvas move while the previous one still
        // waits means the user is looking at a usable desktop, so that step is kept and this one
        // gets its own window (as the tray does for repeated mode changes). A pending mode change,
        // or a window that is already restoring, has to finish first — as does a scene or a launch
        // restore, refused before anything (keeping the previous step included) is done.
        guard !sceneApplying, !arrangementRestoring else {
            arrangementError = String(localized: "Another display change is still being applied. Try again when it’s done.")
            return
        }
        if let pending = pendingRevert {
            guard pending.kind == .arrangement, revertGate?.isPending == true else {
                arrangementError = pending.kind == .arrangement
                    ? String(localized: "The previous arrangement is being put back. Try again in a moment.")
                    : String(localized: "Confirm or revert the previous change first.")
                return
            }
            confirmArrangementChange()
        }

        let before = snapshot.observations
        // Persist the original arrangement BEFORE the write so a crash during verification can
        // recover. It replaces a record an earlier rollback couldn't confirm (`RevertMarkerPolicy`).
        Self.writeRevertMarker(before)
        refreshRevertRecord()
        let observer = self.observer
        let warnings = await Task.detached(priority: .userInitiated) {
            observer.applyArrangement(targets)
        }.value
        await refresh()
        let after = Self.arrangementLayout(await observer.currentSnapshot().observations)
        let outcome = ArrangementLayout.outcome(planned: planned, before: live, after: after)
        switch (warnings.isEmpty, outcome) {
        case (true, .applied), (true, .adjusted):
            if outcome == .adjusted {
                arrangementNote = String(localized: "macOS placed the displays a little differently to keep them together. The canvas shows the arrangement in effect.")
            }
            await noteLayoutSelfChange()
            beginRevertWindow(before: before, message: String(localized: "Display arrangement changed"),
                              kind: .arrangement)
        default:
            // Rejected, or the readback broke a mirror set or moved the menu bar elsewhere: put back
            // whatever landed. Never offer Keep for an arrangement macOS didn't make as planned.
            // With nothing moved there is nothing to write back, only the record to judge.
            let restoreOutcome: RevertMarkerPolicy.Outcome
            if outcome != .nothingMoved {
                restoreOutcome = await restoreArrangement(before)
            } else {
                let current = await observer.currentSnapshot().observations
                restoreOutcome = .restored(providerWarnings: [],
                                           mismatches: RevertMarkerPolicy.mismatches(wanted: before, current: current))
            }
            switch RevertMarkerPolicy.disposition(after: restoreOutcome) {
            case .clear:
                Self.clearRevertMarker()
                refreshRevertRecord()
                arrangementError = String(localized: "macOS didn’t accept the new arrangement, so the previous one is in effect.")
            case .awaitingDisplays:
                // Not a success: a recorded display isn't connected, so what it is owed stays on
                // record for the next launch.
                Self.retainRevertMarker(after: restoreOutcome)
                refreshRevertRecord()
                arrangementError = String(localized: "macOS didn’t accept the new arrangement. Not every display in the previous one is connected, so it can’t be confirmed as restored yet; a record of it was saved and is restored at the next launch.")
            case .unverified:
                arrangementError = String(localized: "macOS didn’t accept the new arrangement, and the previous one couldn’t be confirmed. The canvas shows the arrangement in effect; a record of the previous one was saved for recovery.")
            }
        }
    }

    /// The canvas arrangement of `observations`, sized by `CGDisplayBounds` — the rectangles Core
    /// Graphics actually lays out, rotation included — so the canvas and the drop check measure
    /// displays the same way, and neither relies on how a mode reports a rotated size.
    static func arrangementLayout(_ observations: [DisplayObservation]) -> ArrangementLayout {
        ArrangementLayout(observations: observations) { observation in
            guard let cgID = observation.cgDisplayID else { return nil }
            let bounds = CGDisplayBounds(cgID)
            guard bounds.width >= 1, bounds.height >= 1 else { return nil }
            return (Int(bounds.width.rounded()), Int(bounds.height.rounded()))
        }
    }

    /// Why the last change on the arrangement canvas didn't land; nil after a clean one.
    @Published private(set) var arrangementError: String?
    /// What macOS did differently from the canvas plan, when it still moved things; nil otherwise.
    @Published private(set) var arrangementNote: String?
    /// A canvas change is being applied; the canvas takes no new drops meanwhile.
    @Published private(set) var arrangementApplying = false

    /// The menu and native-key actions share the arrangement Keep/Revert transaction.
    func setMirrored(_ on: Bool, for observation: DisplayObservation) async {
        guard let plan = MirroringChangePlan(targets: [observation],
            source: on ? displays.first(where: \.isMain) : nil),
              !on || displays.contains(where: \.isMain) else { return }
        await applyMirroringChange(plan)
    }

    private func applyMirroringChange(_ plan: MirroringChangePlan) async {
        guard !displayConfigurationBusy else {
            arrangementError = String(localized: "Confirm or revert the previous change first.")
            return
        }
        arrangementApplying = true
        arrangementError = nil
        defer { arrangementApplying = false }
        let before = await observer.currentSnapshot().observations
        guard plan.isResolvable(in: before) else {
            arrangementError = String(localized: "The displays changed in the meantime, so nothing was moved.")
            return
        }
        Self.writeRevertMarker(before)
        refreshRevertRecord()
        let accepted = await observer.applyMirroringChange(plan)
        await refresh()
        let current = await observer.currentSnapshot().observations
        switch plan.outcome(accepted: accepted && !Task.isCancelled, current: current) {
        case .awaitingConfirmation:
            await noteLayoutSelfChange()
            beginRevertWindow(before: before, message: String(localized: "Display mirroring changed"), kind: .arrangement)
        case .restorePrevious:
            let outcome = await restoreArrangement(before)
            if RevertMarkerPolicy.mayClearMarker(after: outcome) {
                Self.clearRevertMarker()
                refreshRevertRecord()
                arrangementError = String(localized: "macOS did not confirm the mirroring change. The previous settings were restored.")
            } else {
                Self.retainRevertMarker(after: outcome)
                refreshRevertRecord()
                reportUnverifiedRestore(kind: .arrangement, after: outcome)
            }
        }
    }

    /// Sets a display's software dim, 1 (none) down toward 0, expressed through the configured
    /// dimming method — gamma table, overlay window, or both. Works on any display.
    func setSoftwareDim(_ level: Float, for observation: DisplayObservation) {
        guard let cgID = observation.cgDisplayID else { return }
        softwareDim[observation.recordID] = level
        applyDim(level: level, id: observation.recordID, cgID: cgID)
    }

    /// Unknown includes the pending first read: fail closed for this display only. The explicit
    /// override still permits gamma on custom-profile displays.
    func gammaBlockedByCustomProfile(for id: DisplayRecordID) -> Bool {
        ColorProfileGuard.blocksGamma(for: id, knowledge: colorProfileKnowledge,
                                      allowGammaWithCustomProfiles: settings.allowGammaWithCustomProfiles)
    }

    private var gammaBlockedDisplays: Set<DisplayRecordID> {
        // Include pending entries even before refreshCustomProfileGuard seeds its first read.
        Set(displays.filter { $0.cgDisplayID != nil && gammaBlockedByCustomProfile(for: $0.recordID) }
            .map(\.recordID))
    }

    /// Dimming falls back to the overlay only on the protected display.
    func effectiveDimmingMethod(for id: DisplayRecordID) -> DimmingMethod {
        GammaSlotPolicy.effectiveMethod(settings.dimmingMethod, gammaBlocked: gammaBlockedByCustomProfile(for: id))
    }

    /// Expresses one dim level through the effective method's gamma/overlay split. Returns whether
    /// the gamma half is on screen as requested (true when there was nothing to write).
    @discardableResult
    private func applyDim(level: Float, id: DisplayRecordID, cgID: CGDirectDisplayID) -> Bool {
        guard let split = DimmingComposer.application(method: effectiveDimmingMethod(for: id),
            desiredLevel: level, blackedOut: blackedOut.contains(id)) else { return true }
        let landed = writeGamma(level: split.gammaLevel, id: id, cgID: cgID)
        dimOverlay.setAlpha(split.overlayAlpha, for: cgID)
        return landed
    }

    /// The gamma half of a display's current software dim under the effective method.
    private func dimGammaLevel(for id: DisplayRecordID) -> Float {
        DimmingComposer.split(method: effectiveDimmingMethod(for: id), level: softwareDim[id] ?? 1).gammaLevel
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

    /// Per-display software contrast factor (`SoftwareContrast`); absent = neutral, the display's own
    /// picture. Session-only like the dim and the temperature (SD-21: nothing of the colour table is
    /// restored at launch) — `restoreGamma` on quit clears it with them.
    @Published private(set) var softwareContrast: [DisplayRecordID: Float] = [:]

    /// Sets the display's software contrast (TR-14) and re-expresses the gamma slot it shares with
    /// the dim, warmth and boost — composed into one transfer, so none of them is lost.
    func setSoftwareContrast(_ factor: Float, for observation: DisplayObservation) {
        guard let cgID = observation.cgDisplayID else { return }
        let id = observation.recordID
        softwareContrast[id] = SoftwareContrast.normalized(factor)
        guard !blackedOut.contains(id) else { return }  // applied when the blackout lifts
        writeGamma(level: dimGammaLevel(for: id), id: id, cgID: cgID)
    }

    /// Displays whose software image adjustments are suspended (AM-18): colour temperature and
    /// contrast are kept but not applied, while brightness — software dimming and XDR boost
    /// included — keeps working. Lifting it puts back exactly what was set. Session-only, like the
    /// adjustments it pauses.
    @Published private(set) var softwareAdjustmentsSuspended: Set<DisplayRecordID> = []

    func setSoftwareAdjustmentsSuspended(_ suspended: Bool, for observation: DisplayObservation) {
        guard let cgID = observation.cgDisplayID else { return }
        let id = observation.recordID
        guard softwareAdjustmentsSuspended.contains(id) != suspended else { return }
        if suspended { softwareAdjustmentsSuspended.insert(id) } else { softwareAdjustmentsSuspended.remove(id) }
        guard !blackedOut.contains(id) else { return }
        writeGamma(level: dimGammaLevel(for: id), id: id, cgID: cgID)
    }

    /// Whether `observation` shows HDR-capable output, where colour-table changes can look different
    /// and highlights can clip — said next to the contrast control rather than discovered.
    func isHDRCapable(_ observation: DisplayObservation) -> Bool {
        guard let screen = observation.cgDisplayID.flatMap(Self.screen(for:)) else { return false }
        return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0
    }

    /// The one funnel for gamma writes: dim scale × the display's colour-temperature gains × its
    /// software contrast × the XDR boost (Issue #35 — read live here so no caller can silently clear
    /// an active boost), composed by `SoftwareImageTransfer`. A suspended display (AM-18) writes its
    /// dim and boost with neutral temperature and contrast.
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
        // Headroom is only read while a boost is set — a plain dim/warmth write skips the
        // NSScreen lookup and takes the provider's untouched formula path (boost 1).
        let fraction = xdrBoostFraction[id] ?? 0
        let boost = fraction > 0
            ? XDRBrightnessPolicy.boost(forFraction: fraction, headroom: xdrHeadroom(cgID: cgID))
            : 1
        let transfer = SoftwareImageTransfer.composed(
            dim: level, kelvin: colorTemperature[id], contrast: softwareContrast[id], boost: boost,
            suspended: softwareAdjustmentsSuspended.contains(id))
        let needsGamma = transfer.needsGamma
        switch GammaSlotPolicy.action(needsGamma: needsGamma, owned: gammaOwned.contains(id),
                                      blocked: gammaBlockedByCustomProfile(for: id)) {
        case .none:
            noteGammaWrite(.success, id: id)
            return true
        case .release:
            return releaseGamma(id) && !needsGamma
        case .blocked:
            return false
        case .write:
            let result = observer.setGammaAdjustment(transfer, for: cgID)
            gammaOwned.recordWrite(for: id, displayID: cgID, succeeded: result == .success)
            noteGammaWrite(result, id: id)
            return result == .success
        }
    }

    /// Black Out's gamma half — the floor, which also darkens the menu-bar strip the overlay leaves
    /// visible. Not written (no colour-table call) when dimming is overlay-only or gamma is blocked;
    /// the opaque overlay does the blacking out either way.
    private func writeBlackOutGamma(id: DisplayRecordID, cgID: CGDirectDisplayID) {
        guard effectiveDimmingMethod(for: id) != .overlay else {
            if gammaOwned.contains(id) { releaseGamma(id) }
            return
        }
        let result = observer.setGammaDim(0.0, for: cgID)
        gammaOwned.recordWrite(for: id, displayID: cgID, succeeded: result == .success)
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

    /// Clear only a table this process wrote. The global ColorSync restore also resets f.lux,
    /// Lunar and every untouched display. An identity transfer releases our adjustment on this
    /// display without changing its ICC assignment; it does not reapply a profile's calibration.
    /// Normally custom-profile displays have no owned table (the guard prevented the first write).
    /// Cleanup is still needed if the profile changed after a write or the override was enabled.
    @discardableResult
    private func releaseGamma(_ id: DisplayRecordID) -> Bool {
        let current = displays.first(where: { $0.recordID == id })?.cgDisplayID
        guard let cgID = gammaOwned.displayToRestore(for: id, currentDisplayID: current) else { return true }
        let result = CoreGraphicsProvider.restoreGamma(for: cgID)
        gammaOwned.recordRestore(for: id, succeeded: result == .success)
        noteGammaWrite(result, id: id)
        return result == .success
    }

    /// Safe startup owns no gamma slots. Quit and explicit recovery use the same selection and
    /// never infer ownership from connected displays, saved settings or a prior process.
    private func releaseAllGamma() {
        for display in displays { releaseGamma(display.recordID) }
    }

    /// Re-expresses a display's whole software image state — dim (gamma + overlay), warmth,
    /// contrast and boost, or Black Out — under the current method and safeguard. The overlay window
    /// is touched only when a dim is set: without one it may be FaceLight's warm wash, which a
    /// zero-alpha dim write would remove.
    private func reexpressSoftwareImage(_ id: DisplayRecordID) {
        guard let cgID = displays.first(where: { $0.recordID == id })?.cgDisplayID else {
            return
        }
        if blackedOut.contains(id) {
            writeBlackOutGamma(id: id, cgID: cgID)
        } else if let level = softwareDim[id], level < 1 {
            applyDim(level: level, id: id, cgID: cgID)
        } else {
            writeGamma(level: 1, id: id, cgID: cgID)  // warmth, contrast and boost only
        }
    }

    /// Re-expresses every display after the dimming method changed. Guard changes use only their
    /// affected displays instead. A display with no software state gets no colour-table call.
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
        let wasBlocked = gammaBlockedDisplays
        settings.allowGammaWithCustomProfiles = allowed
        persistSettings()
        gammaBlockChanged(wasBlocked.symmetricDifference(gammaBlockedDisplays))
    }

    /// Only displays whose verdict changed are re-expressed. In particular, a second custom
    /// profile must engage its own guard even while another display is already blocked, and must
    /// never stop an unaffected XDR boost or rewrite another app's table on an unaffected display.
    private func gammaBlockChanged(_ changed: Set<DisplayRecordID>) {
        for display in displays where changed.contains(display.recordID) {
            if gammaBlockedByCustomProfile(for: display.recordID), (xdrBoostFraction[display.recordID] ?? 0) > 0 {
                setXDRBoost(0, for: display)
            }
            reexpressSoftwareImage(display.recordID)
        }
    }

    /// Re-read each assignment off-main. Pending/failed first reads protect only their display;
    /// lifting its guard puts gamma back where wanted without disturbing other displays.
    func refreshCustomProfileGuard() async {
        // Refresh, profile changes and ColorSync notifications can overlap; only the newest read
        // may decide, or a slower stale one could land last and undo a newer verdict.
        customProfileGuardRead &+= 1
        let read = customProfileGuardRead
        let targets = displays.compactMap { display in display.cgDisplayID.map { (display.recordID, $0) } }
        // Until this read lands, a display never verified counts as unverified — blocking — so a
        // dim or warmth write racing startup or a hot-plug can't reach gamma before its custom
        // assignment is known. Verified displays keep what was verified.
        applyColorProfileKnowledge(ColorProfileGuard.knowledge(connected: Set(targets.map(\.0)), readings: [:],
                                                               previous: colorProfileKnowledge))
        let readings = await Task.detached(priority: .utility) {
            targets.map { id, cgID in (id, ColorProfileService.guardReading(for: cgID)) }
        }.value
        guard read == customProfileGuardRead else { return }
        var classified: [DisplayRecordID: ColorProfileGuard.Assignment] = [:]
        for (id, reading) in readings {
            let assignment: ICCAssignment
            switch reading {
            case .assignment(let read):
                assignment = read
            case .noDevice:
                // ColorSync registers no device for the display, so no profile can be assigned to
                // it: unless an earlier read verified something (a gap must not lift a known
                // block), it holds none. An absent ColorSync device is different from an unreadable
                // assignment, which remains unverified for this display only.
                if case .verified? = colorProfileKnowledge[id] {} else { classified[id] = .factory }
                continue
            case .unreadable:
                continue  // no UUID to ask with: the guard keeps what it verified, else unknown
            }
            if colorProfileAssignment[id] != assignment { colorProfileAssignment[id] = assignment }
            classified[id] = ColorProfileGuard.classify(assignedPath: assignment.customURL?.path,
                                                        factoryPaths: assignment.factoryURLs.map(\.path))
        }
        // Judged against the displays connected NOW: one that arrived during the read has no
        // reading yet, so it counts as unverified — blocking — until its own refresh reads it.
        let connected = Set(displays.filter { $0.cgDisplayID != nil }.map(\.recordID))
        applyColorProfileKnowledge(ColorProfileGuard.knowledge(connected: connected, readings: classified,
                                                               previous: colorProfileKnowledge))
    }

    /// Installs both the pending first-read seed and completed reads through the same per-display policy.
    private func applyColorProfileKnowledge(_ knowledge: [DisplayRecordID: ColorProfileGuard.Knowledge]) {
        let wasBlocked = gammaBlockedDisplays
        colorProfileKnowledge = knowledge
        let unverified = ColorProfileGuard.unverifiedDisplays(knowledge)
        if unverifiedProfileDisplays != unverified { unverifiedProfileDisplays = unverified }
        let blocking = ColorProfileGuard.blockingDisplays(knowledge)
        if blocking != customProfileDisplays { customProfileDisplays = blocking }
        gammaBlockChanged(wasBlocked.symmetricDifference(gammaBlockedDisplays))
    }

    /// Why a display's software image (gamma dim, colour temperature, contrast, XDR boost) isn't on
    /// screen as set, or nil when it is: a rejected gamma write, or the custom-profile safeguard
    /// pausing gamma.
    func gammaIssueText(for observation: DisplayObservation) -> String? {
        if let code = gammaWriteFailures[observation.recordID] {
            return String(localized: "macOS rejected the gamma change (error \(code)), so it isn’t on screen.")
        }
        guard gammaBlockedByCustomProfile(for: observation.recordID) else { return nil }
        let name = displayName(for: observation)
        if colorProfileKnowledge[observation.recordID] == nil || unverifiedProfileDisplays.contains(observation.recordID) {
            return String(localized: "Gamma is paused on \(name) because macOS couldn’t report its colour profile, and a custom profile can turn a screen black or tinted. Dimming on this display uses the overlay; colour temperature, contrast and XDR boost are off. Gamma resumes once macOS reports the profile, or allow gamma with custom profiles in Settings › Displays › Dimming.")
        }
        return String(localized: "Gamma is paused on \(name) because it uses a custom colour profile, which can turn a screen black or tinted. Dimming on this display uses the overlay; colour temperature, contrast and XDR boost are off. Choose a factory profile, or allow gamma with custom profiles in Settings › Displays › Dimming.")
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
        guard !gammaBlockedByCustomProfile(for: id) else { return }
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
            now: Date(), safeStartup: safeStartup)
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
        guard !safeStartup else {
            xdrPowerMonitor.stop()
            xdrAutoOffTimer.cancel()
            return
        }
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
    /// reconfiguration, wake, and logout. The opaque overlay does not reset with them, so the
    /// safeguards see it instead: the coordinator's preflight through `safetyObserver`, the
    /// always-one-active net and the off switch through `safetyObservations` — and the net, Reconnect
    /// All and quit lift it (`liftBlackOuts`).
    @Published private(set) var blackedOut: Set<DisplayRecordID> = [] {
        didSet { safetyObserver.setBlackedOut(blackedOut) }
    }

    /// True when the display is currently blacked out.
    func isBlackedOut(_ observation: DisplayObservation) -> Bool {
        blackedOut.contains(observation.recordID)
    }

    /// The displays as the "keep a usable screen" safeguards must judge them: Black Out stamped in,
    /// since no provider can report it.
    private var safetyObservations: [DisplayObservation] {
        BlackOutPolicy.stamping(blackedOut, into: displays)
    }

    /// Whether Black Out may be switched on for `observation`: another lit, physical, unmirrored
    /// screen must stay visible (`BlackOutPolicy`). A virtual or unverified screen doesn't count —
    /// it can be lit and enumerated while showing the user nothing on the desk.
    func canBlackOut(_ observation: DisplayObservation) -> Bool {
        BlackOutPolicy.mayBlackOut(observation.recordID, in: displays, blackedOut: blackedOut)
    }

    /// Toggles Black Out: drive gamma to zero, or restore the display's effective dim level.
    func toggleBlackOut(for observation: DisplayObservation) {
        guard let cgID = observation.cgDisplayID else { return }
        let id = observation.recordID
        if blackedOut.contains(id) {
            liftBlackOuts([id])
        } else {
            // Never black out the last screen the user can be left on: with it covered there is
            // nothing left to click to undo it (any entry point — menu, hotkey, URL — goes through
            // here).
            guard canBlackOut(observation) else { return }
            blackedOut.insert(id)
            writeBlackOutGamma(id: id, cgID: cgID)
            // The provider floors gamma at 0.15 so a dim can never become unreadable; that floor
            // left Black Out at ~15 %. The click-through opaque overlay does the actual blacking
            // out, and lifting it goes through applyDim, which resets the overlay alpha.
            dimOverlay.setAlpha(1, for: cgID)
        }
    }

    /// Lifts Black Out from `ids`, putting each display's own dim level back (which resets the
    /// overlay alpha). A display that has left Core Graphics only leaves the set — its overlay
    /// went with its screen (`DimOverlayController.reconcile`).
    private func liftBlackOuts(_ ids: Set<DisplayRecordID>) {
        for id in ids where blackedOut.contains(id) {
            blackedOut.remove(id)
            guard let cgID = displays.first(where: { $0.recordID == id })?.cgDisplayID else { continue }
            applyDim(level: softwareDim[id] ?? 1.0, id: id, cgID: cgID)
        }
    }

    /// Read-only display metadata (EDID-derived) for the menu's info panel.
    func displayInfo(for observation: DisplayObservation) -> [(label: String, value: String)] {
        guard let cgID = observation.cgDisplayID else { return [] }
        var info: [(String, String)] = [
            (String(localized: "Name"), displayName(for: observation)),
            // Not a blanket "External": without hardware evidence the screen may be virtual,
            // Sidecar, AirPlay or DisplayLink (SD-14).
            (String(localized: "Type"), DisplayInformationReport.classLabel(
                observation.displayClass, presence: observation.physicalPresence, .app)),
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
        if let physical = DisplayPhysicalSize(widthMM: Double(size.width), heightMM: Double(size.height)) {
            info.append((String(localized: "Size"), String(format: String(localized: "%.1f-inch"), physical.diagonalInches)))
            // macOS estimates a size at 72 dpi when the display gives none; only a screen with
            // display hardware gets its millimetres stated (TR-12). Pixel density is added by the
            // Settings card, which can afford the mode enumeration it needs.
            if observation.physicalPresence == .physical {
                info.append((String(localized: "Physical size"),
                             String(localized: "\(Int(physical.widthMM.rounded())) × \(Int(physical.heightMM.rounded())) mm")))
            }
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

    /// Applies a saved scene's positions + modes to the current displays (user-triggered), then
    /// checks the result (TB-04): every field is judged against the topology read after the write,
    /// so a mode macOS rejected or a field scenes don't execute (rotation, on/off, brightness…) is
    /// reported instead of an apparently clean apply. A missing required member blocks the apply.
    @discardableResult
    func applyScene(_ scene: Scene, reaction: UUID? = nil) async -> SceneApplyReport {
        // One display transaction at a time (`displayConfigurationBusy`): judged and claimed before
        // the first suspension point, so nothing can start in between. A scene that would have to
        // write meanwhile writes nothing; its report judges the topology as it is, and says why.
        let busy = displayConfigurationBusy
        if !busy { sceneApplying = true }
        defer { if !busy { sceneApplying = false } }
        let before = await observer.currentSnapshot()
        var resolution: ScenePlanner.Resolution = [:]
        for member in scene.members {
            if let observation = resolveSceneMember(member.selector, in: before) {
                resolution[member.selector] = observation.recordID
            }
        }
        let preparation = SceneApplication.prepare(scene: scene, resolution: resolution, before: before)
        var warnings: [String] = []
        var refused = false
        if !preparation.isBlocked {
            let targets = preparation.writes.compactMap { write -> CoreGraphicsProvider.ArrangementTarget? in
                guard let cgID = before.observation(for: write.target)?.cgDisplayID else { return nil }
                return .init(displayID: cgID, origin: write.origin, mode: write.mode)
            }
            if !targets.isEmpty, busy || !configuredReactionIsCurrent(reaction) {
                refused = true
                warnings = ["another display change is in progress"]
            } else if !targets.isEmpty {
                // CGCompleteDisplayConfiguration blocks until the displays are reconfigured — off the
                // main actor, like the mode and canvas paths, so the menus, the recovery hotkeys and
                // an open revert countdown keep running meanwhile.
                let observer = self.observer
                warnings = await Task.detached(priority: .userInitiated) {
                    observer.applyArrangement(targets)
                }.value
            }
        }
        let after = refused ? before : await observer.currentSnapshot()
        let report = SceneApplication.report(scene: scene, preparation: preparation, resolution: resolution,
                                             before: before, after: after, providerWarnings: warnings)
        guard !refused else {
            sceneWarning = String(localized: "Not applied: another display change is still in progress. Nothing was changed.")
            return report
        }
        await refresh()
        await noteLayoutSelfChange()
        sceneWarning = sceneApplySummary(report)
        return report
    }

    /// The Scenes banner for a report, or nil when everything the scene asks for is in place.
    /// Field names, not values: the CLI (`scene apply`) prints the per-field detail.
    private func sceneApplySummary(_ report: SceneApplyReport) -> String? {
        func names(_ outcome: SceneApplyReport.Outcome) -> String {
            var fields: [SceneApplyReport.Field] = []
            for entry in report.entries where entry.outcome == outcome && !fields.contains(entry.field) {
                fields.append(entry.field)
            }
            return fields.map(Self.sceneFieldName).formatted(.list(type: .and))
        }
        switch report.status {
        case .applied, .noChange:
            return nil
        case .blocked where !report.invalidValues.isEmpty:
            var fields: [SceneApplyReport.Field] = []
            for invalid in report.invalidValues where !fields.contains(invalid.field) { fields.append(invalid.field) }
            let list = fields.map(Self.sceneFieldName).formatted(.list(type: .and))
            return String(localized: "Not applied: this scene holds a value FreeDisplay can’t use (\(list)). Nothing was changed.")
        case .blocked:
            let missing = report.missingRequired.formatted(.list(type: .and))
            return String(localized: "Not applied: required displays aren’t connected (\(missing)). Nothing was changed.")
        case .failed where report.entries.isEmpty:
            return String(localized: "Not applied: none of this scene’s displays are connected.")
        case .partial, .failed:
            var parts: [String] = []
            let notApplied = names(.notApplied)
            if !notApplied.isEmpty {
                parts.append(String(localized: "macOS didn’t apply: \(notApplied)."))
            }
            let skipped = names(.skipped)
            if !skipped.isEmpty {
                parts.append(String(localized: "Scenes can’t set yet, so skipped: \(skipped)."))
            }
            let lead = report.status == .partial
                ? String(localized: "Applied in part.") : String(localized: "Not applied.")
            return ([lead] + parts).joined(separator: " ")
        }
    }

    private static func sceneFieldName(_ field: SceneApplyReport.Field) -> String {
        switch field {
        case .connected: return String(localized: "on/off state")
        case .main: return String(localized: "main display")
        case .position: return String(localized: "position")
        case .relativePosition: return String(localized: "relative placement")
        case .mode: return String(localized: "resolution")
        case .rotation: return String(localized: "rotation")
        case .brightness: return String(localized: "brightness")
        case .colorProfile: return String(localized: "color profile")
        case .hdr: return String(localized: "HDR")
        }
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
        do {
            try await registry.setAlias(alias, for: record.id)
            await refresh()
        } catch {
            statusText = String(localized: "Couldn’t rename the display: \(error.localizedDescription)")
        }
    }

    // MARK: - Remembered displays (SD-09, FB-13)

    /// Every display OpenDisplay remembers — connected, switched off by OpenDisplay, or only saved —
    /// one entry each (`RememberedDisplayInventory`).
    var rememberedDisplays: [RememberedDisplay] {
        RememberedDisplayInventory.build(
            registry: registryInventory,
            live: displays.map { .init(observationID: $0.recordID, record: records[$0.recordID]) },
            offline: managedOffline)
    }

    /// The name a remembered entry is shown under: the live name while connected, else the record's
    /// (alias → model → class label, localized like `rememberedDisplayName`), else the ledger's.
    func rememberedName(of entry: RememberedDisplay) -> String {
        if let live = displays.first(where: { entry.observationIDs.contains($0.recordID) }) {
            return displayName(for: live)
        }
        if let record = entry.record {
            if let alias = record.alias, !alias.isEmpty { return alias }
            if let model = record.fingerprint.modelName, !model.isEmpty { return model }
        }
        if let name = entry.offline?.name, !name.isEmpty { return name }
        return entry.record?.friendlyName().appLocalized ?? entry.id
    }

    /// The display class of an entry, for its glyph: live, then record, then ledger.
    func rememberedClass(of entry: RememberedDisplay) -> DisplayClass {
        displays.first(where: { entry.observationIDs.contains($0.recordID) })?.displayClass
            ?? entry.record?.displayClass ?? entry.offline?.displayClass ?? .unknown
    }

    /// What forgetting (or, for a connected display, resetting) this entry would change.
    func cleanupPlan(for entry: RememberedDisplay) -> RememberedDisplayCleanup.Plan? {
        try? RememberedDisplayCleanup.plan(
            for: entry, mode: entry.cleanupMode, settings: settings, favorites: favorites,
            menuLayout: menuLayout, ledger: managedOffline)
    }

    enum RememberedDisplayCleanupOutcome: Equatable {
        case done
        /// The display was connected or disconnected between the confirmation and the action, so
        /// what was confirmed no longer applies; nothing was changed.
        case stateChanged
        /// Forgetting isn't allowed for it now (`RememberedDisplay.forgetRefusal`); nothing changed.
        case refused(RememberedDisplayCleanup.Refusal)
        /// Nothing by that id is remembered any more (already forgotten elsewhere).
        case notFound
    }

    /// Forgets a display that isn't connected, or resets a connected one's saved settings — whichever
    /// the confirmation showed (`mode`). The topology is read afresh and the entry looked up again
    /// first, because the display can have come back while the sheet was open: a forget confirmed
    /// for an absent display is never carried out on a present one. After that read, the forget
    /// path changes every store without suspending, so nothing can slip in between check and write.
    /// No monitor or macOS setting is written either way.
    @discardableResult
    func performCleanup(of entryID: String, confirmed mode: RememberedDisplayCleanup.Mode) async
        -> RememberedDisplayCleanupOutcome {
        await refresh()
        guard let entry = rememberedDisplays.first(where: { $0.id == entryID }) else { return .notFound }
        guard entry.cleanupMode == mode else { return .stateChanged }
        let plan: RememberedDisplayCleanup.Plan
        do {
            plan = try RememberedDisplayCleanup.plan(
                for: entry, mode: mode, settings: settings, favorites: favorites,
                menuLayout: menuLayout, ledger: managedOffline)
        } catch {
            return .refused(error)
        }

        if mode == .reset {
            // These two change how a live display is driven, so they go through their own setters,
            // which also drop the DDC state and re-read brightness on the new route. The Apple-DDC
            // override goes first: dropping software brightness re-reads over DDC, and that read
            // must not reach an Apple display whose override is about to be withdrawn (FB-08).
            for observation in displays where plan.observationIDs.contains(observation.recordID) {
                if settings.ddcAppleDisplayOverrideIDs.contains(observation.recordID.rawValue) {
                    await setAppleDisplayDDCOverride(false, for: observation)
                }
                if settings.softwareBrightnessDisplayIDs.contains(observation.recordID.rawValue) {
                    await setSoftwareBrightness(false, for: observation)
                }
            }
        }
        await applyCleanup(plan, of: entry, actor: .ui,
                           command: mode == .forget ? "forgetDisplay" : "resetDisplaySettings")
        await refresh()
        return .done
    }

    /// Applies a forget or reset plan to every store, then the registry, and records it. Every store
    /// changes before the first suspension, so nothing can slip in between the caller's check and
    /// the writes. A live display's driving routes are the caller's business (see `performCleanup`).
    private func applyCleanup(_ plan: RememberedDisplayCleanup.Plan, of entry: RememberedDisplay,
                              actor: DisplayDomain.Actor, command: String) async {
        #if !PUBLIC_API_ONLY
        pruneDDCCaches(to: Set(displays.map(\.recordID)).subtracting(plan.observationIDs))
        #endif
        let updatedSettings = RememberedDisplayCleanup.applying(plan, to: settings)
        if updatedSettings != settings {
            if updatedSettings.displayGroups != settings.displayGroups
                || updatedSettings.defaultDisplayGroup != settings.defaultDisplayGroup { groupSyncStates.removeAll() }
            let clockChanged = updatedSettings.clockMode != settings.clockMode
            settings = updatedSettings
            if clockChanged {
                for id in plan.observationIDs {
                    clockModeLastRequests[id] = nil
                    clockModeHolds[id] = nil
                    clockModeResults[id] = nil
                }
            }
            persistSettings()
            #if !PUBLIC_API_ONLY
            if clockChanged { reconcileAdaptiveLoop() }
            #endif
        }
        let updatedFavorites = RememberedDisplayCleanup.applying(plan, to: favorites)
        if updatedFavorites != favorites {
            favorites = updatedFavorites
            try? favoritesStore?.save(favorites)
        }
        let updatedLayout = RememberedDisplayCleanup.applying(plan, to: menuLayout)
        if updatedLayout != menuLayout {
            menuLayout = updatedLayout
            persistMenuLayout()
        }
        let updatedLedger = RememberedDisplayCleanup.applying(plan, to: managedOffline)
        if updatedLedger != managedOffline {
            managedOffline = updatedLedger
            persistManagedOffline()
        }
        let name = rememberedName(of: entry)
        if let recordID = plan.registryRecordID, let registry {
            if plan.mode == .forget { await registry.forget(recordID) } else { await registry.clearUserData(for: recordID) }
        }
        NotificationCenter.default.post(name: .openDisplayForgetTrayState, object: plan.observationIDs.map(\.rawValue))
        await appendAudit(AuditEntry(
            timestamp: Date(), actor: actor, command: command,
            transactionId: "txn_\(plan.mode.rawValue)_\(UUID().uuidString.prefix(8))", status: "committed",
            targets: plan.observationIDs.map(\.rawValue).sorted()))
        logDisplayEvent(actor == .system ? "\(plan.mode.rawValue) (retention) \(name)" : "\(plan.mode.rawValue) \(name)")
        if rememberedDisplayFocus == entry.id { rememberedDisplayFocus = nil }
    }

    // MARK: - Automatic forgetting (SD-09, FB-13)

    /// Settings → Displays → Remembered: forget a display once it has gone this many days unseen.
    /// Nil (or anything below one day) turns automatic forgetting off — the default.
    func setRememberedDisplayRetention(days: Int?) async {
        let normalized = RememberedDisplayRetention.normalizedDays(days)
        guard settings.rememberedDisplayRetentionDays != normalized else { return }
        settings.rememberedDisplayRetentionDays = normalized
        persistSettings()
        await applyRememberedDisplayRetention()
    }

    /// What automatic forgetting will do with an entry.
    func retentionVerdict(for entry: RememberedDisplay, now: Date = Date()) -> RememberedDisplayRetention.Verdict {
        RememberedDisplayRetention.verdict(for: entry, days: settings.rememberedDisplayRetentionDays, now: now)
    }

    /// Forgets every remembered display that has gone unseen for the configured period, exactly as a
    /// confirmed Forget would, and records each in the audit trail. Runs after every refresh (the
    /// display list just changed, and `lastSeen` was just brought up to date for everything present)
    /// and when the period changes. Never during launch's load, never in safe startup, and each
    /// entry is judged again from the current state right before it goes.
    private func applyRememberedDisplayRetention() async {
        guard retentionReady, !safeStartup, !retentionRunning, registry != nil,
              settings.rememberedDisplayRetentionDays != nil else { return }
        let due = RememberedDisplayRetention.dueEntries(rememberedDisplays, days: settings.rememberedDisplayRetentionDays,
                                                        now: Date())
        guard !due.isEmpty else { return }
        retentionRunning = true
        defer { retentionRunning = false }
        for candidate in due {
            guard let entry = rememberedDisplays.first(where: { $0.id == candidate.id }),
                  case .due = retentionVerdict(for: entry),
                  let plan = try? RememberedDisplayCleanup.plan(
                      for: entry, mode: .forget, settings: settings, favorites: favorites,
                      menuLayout: menuLayout, ledger: managedOffline)
            else { continue }
            await applyCleanup(plan, of: entry, actor: .system, command: "forgetDisplayAfterRetention")
            await refreshRegistryKnownRecords()
        }
    }

    // MARK: - Identity and settings transfer (SD-10, FA-11, TB-09)

    func setNewDisplayIdentityStrategy(_ strategy: DisplayIdentityStrategy) {
        settings.newDisplayIdentityStrategy = strategy
        persistSettings()
    }

    func setIdentityStrategy(_ strategy: DisplayIdentityStrategy, for record: DisplayRecord) async {
        guard let registry else { return }
        await registry.setIdentityStrategy(strategy, for: record.id)
        await refresh()
    }

    /// The id a remembered entry is connected under right now, if it is connected.
    func liveObservationID(of entry: RememberedDisplay) -> DisplayRecordID? {
        displays.first { entry.observationIDs.contains($0.recordID) }?.recordID
    }

    /// How a connected entry was matched at the last refresh.
    func identityExplanation(for entry: RememberedDisplay) -> IdentityMatchExplanation? {
        liveObservationID(of: entry).flatMap { identityExplanations[$0] }
    }

    /// The name of the remembered display a registry record id belongs to (explanations name records).
    func rememberedName(forRecordID id: DisplayRecordID) -> String {
        if let entry = rememberedDisplays.first(where: { $0.record?.id == id }) { return rememberedName(of: entry) }
        return id.rawValue
    }

    /// The remembered displays a connected entry could take settings from.
    func settingsTransferSources(for entry: RememberedDisplay) -> [RememberedDisplay] {
        DisplaySettingsTransfer.sources(for: entry, among: rememberedDisplays)
    }

    /// The connected displays an absent entry's settings could move to.
    func settingsTransferDestinations(for source: RememberedDisplay) -> [RememberedDisplay] {
        rememberedDisplays.filter { destination in
            guard let live = liveObservationID(of: destination) else { return false }
            return (try? DisplaySettingsTransfer.transferPlan(
                from: source, to: destination, destinationLiveID: live, settings: settings, favorites: favorites,
                menuLayout: menuLayout, ledger: managedOffline)) != nil
        }
    }

    func settingsTransferPlan(from source: RememberedDisplay, to destination: RememberedDisplay)
        -> Result<DisplaySettingsTransfer.Plan, DisplaySettingsTransfer.Refusal> {
        guard let live = liveObservationID(of: destination) else { return .failure(.destinationNotConnected) }
        do {
            return .success(try DisplaySettingsTransfer.transferPlan(
                from: source, to: destination, destinationLiveID: live, settings: settings, favorites: favorites,
                menuLayout: menuLayout, ledger: managedOffline))
        } catch {
            return .failure(error)
        }
    }

    /// Settings a connected entry has under an earlier identifier that its live one lacks, if any.
    func settingsMigrationPlan(for entry: RememberedDisplay, sourceID: DisplayRecordID? = nil) -> DisplaySettingsTransfer.Plan? {
        guard entry.isRegistered, let live = liveObservationID(of: entry) else { return nil }
        return try? DisplaySettingsTransfer.migrationPlan(for: entry, liveID: live, settings: settings,
                                                          favorites: favorites, menuLayout: menuLayout, sourceID: sourceID)
    }

    func selectingMigrationSource(_ sourceID: DisplayRecordID?, in plan: DisplaySettingsTransfer.Plan)
        -> DisplaySettingsTransfer.Plan? {
        guard let entry = rememberedDisplays.first(where: { $0.id == plan.destinationEntryID }) else { return nil }
        return settingsMigrationPlan(for: entry, sourceID: sourceID)
    }

    enum SettingsTransferOutcome: Equatable {
        case done
        /// Something the preview showed changed before the action (a display came or went, a
        /// setting was edited); nothing was changed.
        case stateChanged
        case refused(DisplaySettingsTransfer.Refusal)
        /// Two different displays and the user didn't confirm it is a replacement; nothing changed.
        case notAcknowledged
        case persistenceFailed(recoveryPath: String?, restored: Bool)
    }

    /// Carries out a previewed transfer or migration — only if the plan worked out afresh from the
    /// current state is exactly the one the user confirmed, so what was shown is what happens.
    /// A durable recovery snapshot precedes store writes, and registry removal is last. Cached driving routes are
    /// revoked, so subsequent control uses the selected preference and fresh identity evidence.
    /// Nothing is written to a monitor or to macOS's display configuration.
    @discardableResult
    func performSettingsTransfer(_ confirmed: DisplaySettingsTransfer.Plan,
                                 selection: Set<DisplaySettingsTransfer.Category>,
                                 acknowledgedDifferentDisplays: Bool) async -> SettingsTransferOutcome {
        guard !settingsTransferInProgress else { return .stateChanged }
        await refresh()
        guard !settingsTransferInProgress else { return .stateChanged }
        settingsTransferInProgress = true
        defer { settingsTransferInProgress = false }
        let entries = rememberedDisplays
        let current: DisplaySettingsTransfer.Plan
        switch confirmed.kind {
        case .transfer:
            guard let source = entries.first(where: { $0.id == confirmed.sourceEntryID }),
                  let destination = entries.first(where: { $0.id == confirmed.destinationEntryID }),
                  liveObservationID(of: destination) == confirmed.destinationLiveID else { return .stateChanged }
            switch settingsTransferPlan(from: source, to: destination) {
            case .success(let plan): current = plan
            case .failure(let refusal): return .refused(refusal)
            }
        case .migrate:
            guard let entry = entries.first(where: { $0.id == confirmed.destinationEntryID }),
                  liveObservationID(of: entry) == confirmed.destinationLiveID else { return .stateChanged }
            do {
                current = try DisplaySettingsTransfer.migrationPlan(
                    for: entry, liveID: confirmed.destinationLiveID, settings: settings, favorites: favorites,
                    menuLayout: menuLayout, sourceID: confirmed.migrationSourceID)
            } catch {
                return .refused(error)
            }
        }
        guard current == confirmed else { return .stateChanged }
        if current.needsDifferentDisplayAcknowledgement, !acknowledgedDifferentDisplays { return .notAcknowledged }
        let chosen = current.chosen(selection)
        let sourceName = current.kind == .transfer
            ? entries.first(where: { $0.id == current.sourceEntryID }).map(rememberedName(of:)) ?? current.sourceEntryID
            : entries.first(where: { $0.id == current.destinationEntryID }).map(rememberedName(of:)) ?? current.destinationEntryID

        let live = current.destinationLiveID
        #if !PUBLIC_API_ONLY
        pruneDDCCaches(to: Set(displays.map(\.recordID)).subtracting(current.sourceIDs + current.destinationIDs))
        #endif
        brightnessMethod[live] = nil

        guard let settingsStore, let favoritesStore, let menuLayoutStore, let managedOfflineStore,
              let registry else { return .persistenceFailed(recoveryPath: nil, restored: true) }
        let checkedSettings = settings, checkedFavorites = favorites, checkedLayout = menuLayout
        let checkedLedger = managedOffline
        let registryLease = await registry.beginMutationLease()
        let registrySnapshot = await registry.mutationSnapshot(lease: registryLease)
        let previousRegistry = registrySnapshot.persistentState
        guard settings == checkedSettings, favorites == checkedFavorites, menuLayout == checkedLayout,
              managedOffline == checkedLedger else {
            await registry.endMutationLease(registryLease)
            return .stateChanged
        }
        let previous = DisplaySettingsRecoverySnapshot(settings: checkedSettings, favorites: checkedFavorites,
            menuLayout: checkedLayout, managedOffline: checkedLedger, registry: previousRegistry)
        let updatedSettings = DisplaySettingsTransfer.applying(current, selection: selection, to: settings)
        let updatedFavorites = DisplaySettingsTransfer.applying(current, selection: selection, to: favorites)
        let updatedLayout = DisplaySettingsTransfer.applying(current, selection: selection, to: menuLayout)
        let updatedLedger = DisplaySettingsTransfer.applying(current, to: managedOffline)
        let provenance = DisplayRecordProvenance(
            kind: current.kind == .transfer ? .transferredFrom : .migratedFrom, date: Date(),
            sourceName: sourceName, sourceRecordID: current.sourceRecordID,
            sourceObservationIDs: current.sourceIDs, categories: chosen.map(\.rawValue).sorted())
        let clockChanged = updatedSettings.clockMode != settings.clockMode
        do {
            let recoveryURL = try SettingsBackupStore.defaultDirectory()
                .appendingPathComponent("display-transfer-\(UUID().uuidString).json")
            try await DisplaySettingsTransaction.run(snapshot: previous, recoveryURL: recoveryURL,
                write: { step in
                    switch step {
                    case .settings: try settingsStore.save(updatedSettings)
                    case .favorites: try favoritesStore.save(updatedFavorites)
                    case .menuLayout: try menuLayoutStore.save(updatedLayout)
                    case .managedOffline: try managedOfflineStore.save(updatedLedger)
                    case .registry:
                        let change = DisplaySettingsTransfer.registryChange(current, selection: selection)
                        if current.kind == .transfer {
                            if let destination = change.destinationRecordID {
                                guard try await registry.transferUserDataPersisting(from: change.sourceRecordID,
                                    to: destination, alias: change.alias, tags: change.tags, provenance: provenance,
                                    lease: registryLease) != nil
                                else { throw CocoaError(.fileWriteUnknown) }
                            } else if let source = change.sourceRecordID {
                                var state = previousRegistry
                                state.records.removeAll { $0.id == source }
                                state.cgUUIDIndex = state.cgUUIDIndex.filter { $0.value != source }
                                try await registry.replaceState(state, lease: registryLease)
                            }
                        } else if let destination = current.destinationRecordID {
                            try await registry.appendProvenancePersisting(provenance, to: destination, lease: registryLease)
                        }
                    }
                }, commit: {
                    let latest = DisplaySettingsRecoverySnapshot(settings: settings, favorites: favorites,
                        menuLayout: menuLayout, managedOffline: managedOffline, registry: previousRegistry)
                    try DisplaySettingsTransaction.commitIfUnchanged(expected: previous, current: latest,
                        persist: {
                            try settingsStore.save(updatedSettings)
                            try favoritesStore.save(updatedFavorites)
                            try menuLayoutStore.save(updatedLayout)
                            try managedOfflineStore.save(updatedLedger)
                        }, publish: {
                            settings = updatedSettings
                            favorites = updatedFavorites
                            menuLayout = updatedLayout
                            managedOffline = updatedLedger
                        })
                }, restore: { step in
                    // Memory was never staged: preserve any edit made while registry I/O yielded.
                    switch step {
                    case .settings: try settingsStore.save(settings)
                    case .favorites: try favoritesStore.save(favorites)
                    case .menuLayout: try menuLayoutStore.save(menuLayout)
                    case .managedOffline: try managedOfflineStore.save(managedOffline)
                    case .registry: try await registry.restoreMutationSnapshot(registrySnapshot, lease: registryLease)
                    }
                })
        } catch let failure as DisplaySettingsTransaction.Failure {
            await registry.endMutationLease(registryLease)
            if failure.restored, failure.underlying is DisplaySettingsTransaction.StateChanged { return .stateChanged }
            return .persistenceFailed(recoveryPath: failure.recoveryURL.path, restored: failure.restored)
        } catch {
            await registry.endMutationLease(registryLease)
            return .persistenceFailed(recoveryPath: nil, restored: true)
        }
        await registry.endMutationLease(registryLease)
        groupSyncStates.removeAll()
        if clockChanged {
            for id in current.sourceIDs {
                clockModeLastRequests[id] = nil
                clockModeHolds[id] = nil
                clockModeResults[id] = nil
            }
            #if !PUBLIC_API_ONLY
            reconcileAdaptiveLoop()
            #endif
        }
        if current.kind == .transfer {
            NotificationCenter.default.post(name: .openDisplayForgetTrayState, object: current.sourceIDs.map(\.rawValue))
        }
        await appendAudit(AuditEntry(
            timestamp: Date(), actor: .ui,
            command: current.kind == .transfer ? "transferDisplaySettings" : "migrateDisplaySettings",
            transactionId: "txn_\(current.kind.rawValue)_\(UUID().uuidString.prefix(8))", status: "committed",
            targets: (current.sourceIDs + [live]).map(\.rawValue)))
        logDisplayEvent("\(current.kind.rawValue) settings \(sourceName) → \(live.rawValue)")
        settingsTransferInProgress = false
        await refresh()
        return .done
    }

    #if !PUBLIC_API_ONLY
    // Manual pairing uses the existing DDC transport, only after the user requests a test.
    func pairingChannels() async -> [DDCChannel] {
        await Task.detached(priority: .utility) { ExternalDisplayDDC.channels() }.value
    }

    func testDDCChannel(_ channel: DDCChannel, for display: DisplayObservation,
                        parameters: DDCChannelTest.Parameters) async -> (DDCChannelMapping?, String) {
        guard !ddcPairingTestRunning, !appManagementIsQuitting, !safeStartup, !busy,
              DDCChannelMappingPolicy.canPair(display.recordID),
              displays.contains(where: { $0.recordID == display.recordID }),
              let cgID = display.cgDisplayID,
              !isAppleDisplay(display) || appleDisplayDDCOverride(for: display) else {
            return (nil, String(localized: "The display cannot be tested now. Nothing was changed."))
        }
        ddcPairingTestRunning = true
        testedDDCMapping = nil
        let epoch = ddcPairingEpoch
        let target = ExternalDisplayDDC.ddcIdentity(of: cgID)
        let mappingContext = settings.ddcChannelMappings
        let allowApple = appleDisplayDDCOverride(for: display)
        // Ordinary app writes cannot overlap the diagnostic flash, including pending writers.
        pruneDDCCaches(to: [])
        defer { ddcPairingTestRunning = false }
        guard let controller = ExternalDisplayDDC.bindForPairingTest(channelPath: channel.path,
                                                                      allowAppleDisplay: allowApple),
              await pairingChannels().contains(channel), !appManagementIsQuitting, ddcPairingEpoch == epoch,
              settings.ddcChannelMappings == mappingContext,
              ExternalDisplayDDC.ddcIdentity(of: cgID) == target else {
            return (nil, String(localized: "The selected channel is unavailable or its identity changed."))
        }
        defer { controller.invalidate() }
        guard let outcome = await ddcPairingTestSession.run({
            await DDCChannelTest.run(parameters: parameters,
                read: { await controller.read(.brightness).map { (current: $0.current, max: $0.max) } },
                write: { value in
                    // An unstructured restore/write is not cancelled with the diagnostic hold.
                    await Task { await controller.write(.brightness, value) }.value
                },
                hold: { try? await Task.sleep(for: parameters.duration) })
        }), !appManagementIsQuitting else {
            return (nil, String(localized: "The brightness test was cancelled. The original value was sent back if it had been changed."))
        }
        switch outcome {
        case .flashed(_, _, true):
            guard ddcPairingEpoch == epoch, settings.ddcChannelMappings == mappingContext,
                  displays.contains(where: { $0.recordID == display.recordID && $0.cgDisplayID == cgID }),
                  ExternalDisplayDDC.ddcIdentity(of: cgID) == target,
                  await pairingChannels().contains(channel), ddcPairingEpoch == epoch,
                  settings.ddcChannelMappings == mappingContext,
                  ExternalDisplayDDC.ddcIdentity(of: cgID) == target,
                  allowApple == appleDisplayDDCOverride(for: display),
                  let mapping = DDCChannelMappingPolicy.confirm(displayID: display.recordID,
                      displayIdentity: target, channel: channel, at: Date()) else {
                return (nil, String(localized: "Identity changed during the test. Test the channel again."))
            }
            testedDDCMapping = mapping
            testedDDCMappingContext = mappingContext
            return (mapping, String(localized: "The brightness test completed and the original value was sent back. Confirm only if this physical monitor responded."))
        case .flashed(_, _, false), .flashWriteFailed(_, false):
            return (nil, String(localized: "Restoring brightness failed. Use the monitor controls to restore it. Pairing was not saved."))
        case .flashWriteFailed(_, true):
            return (nil, String(localized: "The test write failed. The original brightness was sent back. Pairing was not saved."))
        case .noReply:
            return (nil, String(localized: "The channel did not report a valid brightness. Nothing was written."))
        }
    }

    func confirmDDCChannel(_ mapping: DDCChannelMapping) async -> Bool {
        guard testedDDCMapping == mapping, testedDDCMappingContext == settings.ddcChannelMappings, !ddcPairingTestRunning,
              let display = displays.first(where: { $0.recordID == mapping.displayID }),
              let cgID = display.cgDisplayID,
              !isAppleDisplay(display) || appleDisplayDDCOverride(for: display) else { return false }
        let epoch = ddcPairingEpoch
        let channels = await pairingChannels()
        guard testedDDCMapping == mapping, testedDDCMappingContext == settings.ddcChannelMappings, epoch == ddcPairingEpoch,
              ExternalDisplayDDC.ddcIdentity(of: cgID) == mapping.displayIdentity,
              channels.contains(DDCChannel(path: mapping.channelPath, attributes: mapping.channelAttributes)) else { return false }
        // Channel reassignment is shown in the confirmation. Old owners lose the mapping and cache.
        pruneDDCCaches(to: [])
        settings.ddcChannelMappings = DDCChannelMappingPolicy.saving(mapping, into: settings.ddcChannelMappings)
        testedDDCMapping = nil
        persistSettings()
        await refresh()
        return true
    }

    func removeDDCChannelMapping(for id: DisplayRecordID) {
        testedDDCMapping = nil
        pruneDDCCaches(to: Set(displays.map(\.recordID)).subtracting([id]))
        settings.ddcChannelMappings.removeAll { $0.displayID == id }
        ddcPairingStatus[id] = nil
        persistSettings()
    }
    #endif

    // MARK: - Menu layout (AM-11, SO-23, FA-12, FA-13, FA-14, SD-11)

    private func persistMenuLayout() {
        try? menuLayoutStore?.save(menuLayout)
    }

    /// Applies one change to the menu layout and saves it. Presentation only: nothing here reaches a
    /// display.
    func updateMenuLayout(_ change: (inout MenuLayoutSettings) -> Void) {
        var updated = menuLayout
        change(&updated)
        guard updated != menuLayout else { return }
        menuLayout = updated
        persistMenuLayout()
    }

    func menuPlacement(_ family: MenuItemFamily) -> MenuPlacement { menuLayout.placement(of: family) }

    /// "Reset menu layout": every item family back to its default placement and every open section
    /// in the tray closed. Names, icons, hidden displays, order and the behaviour switches stay; no
    /// display is touched.
    func resetMenuLayout() {
        updateMenuLayout { $0 = $0.resettingMenuContents() }
        NotificationCenter.default.post(name: .openDisplayCollapseTray, object: nil)
    }

    /// The ids a per-display menu preference is written under: every observation id of the remembered
    /// display, so it holds whichever of its UUIDs the display turns up with next.
    func menuPreferenceIDs(for display: DisplayRecordID) -> [DisplayRecordID] {
        rememberedDisplays.first { $0.observationIDs.contains(display) }?.observationIDs ?? [display]
    }

    func setHiddenInMenu(_ hidden: Bool, for ids: [DisplayRecordID]) {
        updateMenuLayout { $0.setHidden(hidden, for: ids) }
    }

    func setMenuIcon(_ symbol: String?, for ids: [DisplayRecordID]) {
        updateMenuLayout { $0.setIconSymbol(symbol, for: ids) }
    }

    /// The custom tray icon for a display, if one is set and this macOS has the symbol; otherwise nil
    /// and the caller uses the class glyph, so a symbol from a newer macOS never draws as blank.
    func menuIconSymbol(for ids: [DisplayRecordID]) -> String? {
        for id in ids {
            if let symbol = menuLayout.iconSymbol(for: id), NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
                return symbol
            }
        }
        return nil
    }

    /// One section of the tray: a live display, or the card of a display OpenDisplay switched off.
    enum TrayEntry: Identifiable {
        case live(DisplayObservation)
        case offline(OfflineDisplay)

        var id: String {
            switch self {
            case .live(let display): return "live:\(display.recordID.rawValue)"
            case .offline(let offline): return "off:\(offline.recordID.rawValue)"
            }
        }

        var recordID: DisplayRecordID {
            switch self {
            case .live(let display): return display.recordID
            case .offline(let offline): return offline.recordID
            }
        }
    }

    /// The tray's display sections in menu order (`MenuDisplayOrder`), hidden displays left out —
    /// except where the tray is the way back: a switched-off display's card, and a blacked-out
    /// display's section. Visibility and order are read under every id the display is remembered by,
    /// the same ids Settings writes, so the two never disagree after it turns up on another port.
    var trayEntries: [TrayEntry] {
        let remembered = rememberedDisplays
        func ids(of id: DisplayRecordID) -> [DisplayRecordID] {
            remembered.first { $0.observationIDs.contains(id) }?.observationIDs ?? [id]
        }
        let entries = displays.map(TrayEntry.live) + managedOffline.map(TrayEntry.offline)
        var candidates: [MenuDisplayOrder.Candidate] = []
        var byID: [String: TrayEntry] = [:]
        for entry in entries where byID[entry.id] == nil {
            let known = ids(of: entry.recordID)
            switch entry {
            case .live(let display):
                guard menuLayout.showsInTray(known, keptForRecovery: isBlackedOut(display)) else { continue }
                candidates.append(.init(id: entry.id, orderKeys: known.map(\.rawValue), name: displayName(for: display),
                                        isMain: display.isMain, isBuiltIn: display.displayClass == .builtIn))
            case .offline(let offline):
                guard menuLayout.showsInTray(known, keptForRecovery: true) else { continue }
                let name = remembered.first { $0.observationIDs.contains(offline.recordID) }.map(rememberedName(of:))
                    ?? offline.name
                candidates.append(.init(id: entry.id, orderKeys: known.map(\.rawValue), name: name,
                                        isBuiltIn: offline.displayClass == .builtIn))
            }
            byID[entry.id] = entry
        }
        return MenuDisplayOrder.sorted(candidates, manualOrder: menuLayout.displayOrder,
                                       mainFirst: menuLayout.mainDisplayFirst).compactMap { byID[$0.id] }
    }

    /// Where the tray draws a family (`MenuLayoutSettings.trayPlacement`): the stored choice, except
    /// that Toggles never vanish entirely.
    func trayPlacement(_ family: MenuItemFamily) -> MenuPlacement { menuLayout.trayPlacement(of: family) }

    /// The remembered displays in tray order — the list Settings → Menu reorders.
    var rememberedDisplaysInMenuOrder: [RememberedDisplay] {
        let entries = rememberedDisplays
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return MenuDisplayOrder.sorted(entries.map(menuOrderCandidate), manualOrder: menuLayout.displayOrder,
                                       mainFirst: menuLayout.mainDisplayFirst).compactMap { byID[$0.id] }
    }

    /// Pins the given sequence as the manual tray order.
    func setMenuOrder(_ sequence: [RememberedDisplay]) {
        updateMenuLayout { $0.displayOrder = MenuDisplayOrder.manualOrder(pinning: sequence.map(menuOrderCandidate)) }
    }

    /// Back to automatic order (built-in first, then by name).
    func resetMenuOrder() {
        updateMenuLayout { $0.displayOrder = [] }
    }

    private func menuOrderCandidate(_ entry: RememberedDisplay) -> MenuDisplayOrder.Candidate {
        let live = displays.first { entry.observationIDs.contains($0.recordID) }
        return .init(id: entry.id, orderKeys: entry.observationIDs.map(\.rawValue), name: rememberedName(of: entry),
                     isMain: live?.isMain ?? false, isBuiltIn: rememberedClass(of: entry) == .builtIn)
    }

    /// Renames a remembered display, connected or not (an empty name restores the model name).
    func setAlias(_ alias: String, forRemembered entry: RememberedDisplay) async {
        guard let registry else { return }
        if let live = displays.first(where: { entry.observationIDs.contains($0.recordID) }) {
            await setAlias(alias, for: live)
        } else if entry.isRegistered, let record = entry.record {
            do {
                try await registry.setAlias(alias, for: record.id)
                await refreshRegistryKnownRecords()
            } catch {
                statusText = String(localized: "Couldn’t rename the display: \(error.localizedDescription)")
            }
        }
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
        if !ddcPairingStatus.keys.allSatisfy(ids.contains) { ddcPairingStatus = ddcPairingStatus.filter { ids.contains($0.key) } }
        if !ddcWriteFailed.keys.allSatisfy(ids.contains) { ddcWriteFailed = ddcWriteFailed.filter { ids.contains($0.key) } }
        if !ddcAudioMuted.keys.allSatisfy(ids.contains) { ddcAudioMuted = ddcAudioMuted.filter { ids.contains($0.key) } }
        if !colorTemperature.keys.allSatisfy(ids.contains) {
            colorTemperature = colorTemperature.filter { ids.contains($0.key) }
        }
        if !softwareContrast.keys.allSatisfy(ids.contains) {
            softwareContrast = softwareContrast.filter { ids.contains($0.key) }
        }
        if !softwareAdjustmentsSuspended.allSatisfy(ids.contains) {
            softwareAdjustmentsSuspended = softwareAdjustmentsSuspended.filter(ids.contains)
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
        gammaOwned.retainConnected(Dictionary(uniqueKeysWithValues: displays.compactMap { display in
            display.cgDisplayID.map { (display.recordID, $0) }
        }))  // a departed or renumbered surface must not authorize a later reset
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
        for (id, task) in ddcWriters where !ids.contains(id) { task.cancel(); ddcWriterOwnership.invalidate(id); ddcWriters[id] = nil }
        for (id, task) in inputSourceWriter where !ids.contains(id) { task.cancel(); inputSourceWriter[id] = nil }
        for (id, task) in colorPresetWriter where !ids.contains(id) { task.cancel(); colorPresetWriter[id] = nil }
        for (key, task) in ddcControlWriter where !ids.contains(key.id) { task.cancel(); ddcControlWriterOwnership.invalidate(key); ddcControlWriter[key] = nil }
        for (id, task) in muteWriter where !ids.contains(id) { task.cancel(); muteWriter[id] = nil }
        for (id, probe) in audioProbes where !ids.contains(id) {
            probe.task.cancel()
            audioProbes[id] = nil
        }
        muteTarget = muteTarget.filter { ids.contains($0.key) }
        brightnessBeforeDDCWrite = brightnessBeforeDDCWrite.filter { ids.contains($0.key) }
        presetBeforeDDCWrite = presetBeforeDDCWrite.filter { ids.contains($0.key) }
        // The bind itself can't be interrupted: forgetting its token is what keeps its result — and
        // every caller still awaiting it — from being used (see `ddcController`).
        for (id, builder) in ddcBuilders where !ids.contains(id) { builder.task.cancel(); ddcBuilders[id] = nil }
        ddcBindingTokens.retain(only: ids)
        // Cancelling a writer can't reach a transaction it already queued for the bus or that is
        // waiting out the pacing gap; withdrawing the binding at the transport does (FB-08), so
        // nothing more goes on the wire through a dropped controller.
        for (id, controller) in ddc where !ids.contains(id) { controller.invalidate() }
        ddc = ddc.filter { ids.contains($0.key) }
        brightnessMax = brightnessMax.filter { ids.contains($0.key) }
        brightnessReceipts.retain(only: ids)
        contrastReceipts.retain(only: ids)
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
        guard !settingsTransferInProgress else { return }
        let identityGeneration = liveDisplayIdentities.begin(connected: displays.map(\.recordID))
        TVControlStore.shared.updateVerifiedDisplays(Set(registryKnownRecords.keys.filter(canPersistDisplaySettings)))
        #if !PUBLIC_API_ONLY
        ddcPairingEpoch &+= 1
        testedDDCMapping = nil
        // A paired route must be rechecked against current evidence after every topology refresh.
        // Revoke old handles too, including work queued behind the transport pacing gap.
        pruneDDCCaches(to: Set(displays.map(\.recordID)).subtracting(settings.ddcChannelMappings.map(\.displayID)))
        #endif
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
        guard liveDisplayIdentities.updateConnected(snapshot.observations.map(\.recordID),
                                                   generation: identityGeneration) else { return }
        displays = snapshot.observations.sorted { $0.recordID.rawValue < $1.recordID.rawValue }
        TVControlStore.shared.updateVerifiedDisplays(Set(registryKnownRecords.keys.filter(canPersistDisplaySettings)))
        // Discovery may yield to key-capture settings changes: no previous registry answer can
        // authorize hardware reads while the new topology's identity is still being resolved.
        records = [:]
        guard await resolveRecords(snapshot, generation: identityGeneration) else { return }
        observeAutoDisconnectArrival()
        reconcileDisplaySleepGuard()
        refreshRevertRecord()
        pruneControlCaches(to: Set(displays.map(\.recordID)))
        // Owner #6: establish audio eligibility during discovery, before diagnostics/UI work.
        await confirmDisplayAudioForKeys()
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
        displaysDarkSince = WakeConvergencePolicy.recoverySurfaces(in: safetyObservations).isEmpty
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
        await applyRememberedDisplayRetention()
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
        switch effectiveDimmingMethod(for: id) {
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
        } else if gammaBlockedByCustomProfile(for: id) && settings.dimmingMethod != .overlay {
            parts.append(unverifiedProfileDisplays.contains(id)
                ? String(localized: "gamma paused: colour profile unread")
                : String(localized: "gamma paused: custom colour profile"))
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
    /// only the slider can teach a group offset, keys always lead. `SetBrightnessIntent` comes
    /// through here too, like the HTTP route (TB-05).
    ///
    /// `eventSource` names the origin in the published OSD event when the gesture alone can't (HTTP
    /// and hotkeys look like a slider and a key press to group sync); nil derives it.
    ///
    /// `syncBypass` is the one-operation bypass (AM-17/TB-14): Shift held on a slider changes this
    /// display alone — the group neither follows nor learns anything from it.
    func setBrightness(_ value: Float, for observation: DisplayObservation,
                       syncToken: GroupSyncPolicy.SyncEcho.Token? = nil,
                       origin: GroupSyncPolicy.ManualWrite.Origin = .slider,
                       eventSource: OSDBroadcast.Source? = nil,
                       syncBypass: Bool = false, policyWrite: Bool = false,
                       keyboardEligible: Set<DisplayRecordID>? = nil, receipt: BrightnessWriteReceipt? = nil) {
        guard let cgID = observation.cgDisplayID else { receipt?.reject("Display is unavailable"); return }
        let id = observation.recordID
        // What a delta-mode group measures this change from: the level before this write.
        let previous = brightness[id]
        if !policyWrite { noteManualClockBrightness(id) }
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
            writeNativeBrightness(value, for: observation, receipt: receipt)
            #endif
        case .hardware:
            #if !PUBLIC_API_ONLY
            // A user-initiated change on a synced display teaches Adaptive Display: learn the
            // offset (or the schedule adoption anchor in clamshell) and start the cooldown, so
            // adaptive yields instead of fighting the slider. The adaptive loop's own writes go
            // through `applyAdaptiveBrightness`, never here.
            if !policyWrite { noteManualBrightnessForAdaptive(value, id: id) }
            brightnessReceipts.enqueue(receipt, for: id)
            if ddcWriters[id] == nil { brightnessBeforeDDCWrite[id] = previous }
            ddcTarget[id] = Int((value * Float(brightnessMax[id] ?? 100)).rounded())
            if ddcWriters[id] == nil {
                let writer = ddcWriterOwnership.begin(id)
                ddcWriters[id] = Task { [weak self] in await self?.drainDDCWrites(id, observation, writer: writer) }
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
            onScreen = landed || effectiveDimmingMethod(for: id) != .gamma
            receipt?.complete(accepted: onScreen, readback: onScreen ? .applied(Double(level)) : .none)
        }
        // Batch-3 #4: the HUD confirms key presses; a slider already shows its own value. The event
        // goes out for every change regardless (IN-04) — a slider, HTTP or restore draws no HUD,
        // but `listen` and external HUD apps still have to hear about it. Both carry the level that
        // is applied (the software floor included), and neither goes out for a rejected software
        // write that changed nothing on screen.
        if onScreen {
            let source = eventSource ?? (syncToken != nil ? .app : origin == .keys ? .mediaKey : .menu)
            presentOSD(kind: .brightness, value: brightness[id] ?? value, for: observation, source: source,
                       showsLocalHUD: origin != .slider, assurance: Self.osdAssurance(method),
                       control: Self.osdControl(method))
        } else if eventSource == .osd {
            // A gamma guard refusal must not leave the interactive HUD claiming an applied level.
            osdHUD.noteAdjustment(OSDContent(kind: .brightness, value: brightness[id] ?? value,
                                             assurance: .notConfirmed),
                                  display: id, verificationTarget: nil)
        }
        syncGroupBrightness(value, applied: brightness[id], previous: previous, from: observation,
                            token: syncToken, origin: origin, bypass: syncBypass,
                            keyboardEligible: keyboardEligible, receipt: receipt)  // Issue #39
    }

    func updateClockMode(_ configuration: ClockModeConfiguration?, enabled: Bool? = nil) {
        if let configuration {
            let old = settings.clockMode?.displays ?? []
            guard configuration.displays.allSatisfy({ schedule in
                canPersistDisplaySettings(schedule.displayID) || old.contains(schedule)
            }) else {
                clockModeConfigurationError = String(localized: "A verified persistent display identity is required. Earlier provisional associations remain saved but inactive.")
                return
            }
        }
        settings.clockMode = configuration
        if let enabled { settings.clockScheduleEnabled = enabled }
        clockModeLastRequests.removeAll()
        clockModeHolds.removeAll()
        clockModeConfigurationError = nil
        clockModeSession.resume()
        persistSettings()
        #if !PUBLIC_API_ONLY
        reconcileAdaptiveLoop()
        #endif
    }

    func updateClockModeLocation(_ coordinate: GeoCoordinate?) {
        settings.clockManualLocation = coordinate
        clockModeConfigurationError = nil
        clockModeLastRequests.removeAll()
        persistSettings()
    }

    var clockModeIsSleeping: Bool { isBetweenSleepAndWake }

    func clockModeHasCompetitor(_ id: DisplayRecordID) -> Bool {
        #if !PUBLIC_API_ONLY
        if appPresetActiveDisplays.contains(id) { return true }
        #endif
        return isBrightnessGroupGoverned(id)
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
        // Named groups' members plus the Default group's live ones, when each syncs brightness. A
        // group that ignores outside changes is still polled: a delta needs each member's real level.
        let active = Set(displays.filter { $0.isActive && isBrightnessGroupGoverned($0.recordID) }
            .map(\.recordID))
        nativeMonitors = nativeMonitors.filter { active.contains($0.key) || nativeWriters[$0.key] != nil }
        // Safe startup (FA-09) fans nothing out, so there is nothing for the poll to feed.
        guard !active.isEmpty, !safeStartup else {
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
            guard isBrightnessGroupGoverned(id),
                  let cgID = observation.cgDisplayID, CGDisplayIsAsleep(cgID) == 0 else { continue }
            if brightnessMethod[id] == nil { await refreshBrightness(for: observation) }
            guard brightnessMethod[id] == .native else { continue }
            let revision = nativeMonitors[id, default: BrightnessMonitor()].revision
            let control = brightnessControl
            let sample = await Task.detached(priority: .utility) { control.brightness(for: cgID) }.value
            guard !Task.isCancelled,
                  displays.contains(where: { $0.recordID == id && $0.cgDisplayID == cgID && $0.isActive }),
                  isBrightnessGroupGoverned(id),
                  let sample else { continue }
            // The monitor's own last level, not the cache: a menu refresh or the adaptive tick may
            // already have put `sample` in the cache, and a delta group would then see no change.
            let previous = nativeMonitors[id]?.baseline
            if nativeMonitors[id, default: BrightnessMonitor()].observe(sample, revision: revision) {
                brightness[id] = sample
                groupBrightnessLastChange = Date()
                // This is already a hardware change. Only write followers, with no duplicate OSD.
                // Observed changes always lead (unless the group ignores outside changes):
                // auto-brightness or a key press is never the user correcting one panel, so it must
                // not teach an offset.
                syncGroupBrightness(sample, applied: sample, previous: previous, from: observation,
                                    token: nil, origin: .observed, bypass: false)
            }
        }
    }

    /// Serialize native writes and baseline their readback so polling never echoes our own work.
    private func writeNativeBrightness(_ value: Float, for observation: DisplayObservation,
                                       receipt: BrightnessWriteReceipt? = nil) {
        guard let cgID = observation.cgDisplayID else { return }
        let id = observation.recordID
        nativeMonitors[id, default: BrightnessMonitor()].beginWrite()
        brightnessReceipts.enqueue(receipt, for: id)
        nativeTargets[id] = value
        guard nativeWriters[id] == nil else { return }
        nativeWriters[id] = Task { [weak self] in
            guard let self else { return }
            let control = brightnessControl
            var sample: Float?
            while let target = nativeTargets.removeValue(forKey: id) {
                let requestReceipt = brightnessReceipts.take(id)
                guard requestReceipt?.admitDispatch() != false else { continue }
                let authorization = requestReceipt?.authorization
                let receipt = await Task.detached(priority: .userInitiated) {
                    guard authorization?.isAuthorized != false else { return (false, Optional<Float>.none) }
                    let accepted = control.setBrightness(target, for: cgID)
                    return (accepted, control.brightness(for: cgID))
                }.value
                requestReceipt?.complete(accepted: receipt.0, readback: receipt.1.map { .level(Double($0)) } ?? .none)
                sample = receipt.1
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
    ///
    /// `value` is what the funnel was asked for, `applied` what the leader now shows (the software
    /// route floors a request) and `previous` its level before — absolute and delta groups use the
    /// latter two, the offsets mode keeps reading `value` exactly as before. The group is the
    /// display's named group or, failing that, the Default group (SO-05/AM-17).
    private func syncGroupBrightness(_ value: Float, applied: Float?, previous: Float?,
                                     from observation: DisplayObservation,
                                     token: GroupSyncPolicy.SyncEcho.Token?,
                                     origin: GroupSyncPolicy.ManualWrite.Origin, bypass: Bool,
                                     keyboardEligible: Set<DisplayRecordID>? = nil, receipt: BrightnessWriteReceipt? = nil) {
        // Safe startup (FA-09): the display the user (or macOS) changed changes; the rest of its
        // group is left alone, and no offset is learned from it.
        guard !safeStartup else { return }
        let leader = observation.recordID
        guard let group = brightnessSyncGroup(containing: leader) else { return }
        var world = groupSyncWorld()
        if let keyboardEligible { world.present.formIntersection(keyboardEligible) }
        let write = GroupSyncPolicy.ManualWrite(value: value, display: leader, token: token,
                                                now: Date(), world: world, origin: origin,
                                                appliedValue: applied, previousValue: previous,
                                                bypass: bypass)
        let result = GroupSyncPolicy.classify(write, group: group,
                                              state: groupSyncStates[group.id] ?? .init(),
                                              echo: groupSyncEcho)
        groupSyncStates[group.id] = result.state
        switch result.outcome {
        case .echo, .governed, .syncDisabled, .bypassed, .outsideChangeIgnored:
            return
        case .followerCorrection:
            storeDisplayGroupOffsets(result.group)
        case .leader(let fanOut):
            applyFollowerBrightness(fanOut, leader: leader, receipt: receipt)
            refreshUnknownGroupLevels(fanOut.unknownLevel)
        }
    }

    /// The displays the Default group can include right now: every present one except virtual
    /// screens — OpenDisplay's own (which Core Graphics reports as external; the presence
    /// classifier knows better), macOS's placeholder and headless adapters — which have no panel
    /// whose brightness is worth matching. Only present displays count, so a group left with a
    /// single one stops governing it (`DisplayGroupStore.syncGroup`).
    private var defaultGroupEligible: [DisplayRecordID] {
        displays.filter {
            $0.isActive && $0.physicalPresence != .virtual
                && $0.displayClass != .virtual && $0.displayClass != .headlessAdapter
        }.map(\.recordID)
    }

    /// The group whose brightness rules apply to `member`: its named group, else the Default group
    /// when the display is one of its live members.
    private func brightnessSyncGroup(containing member: DisplayRecordID) -> DisplayGroup? {
        DisplayGroupStore.syncGroup(containing: member, in: settings.displayGroups,
                                    defaultGroup: settings.defaultDisplayGroup, eligible: defaultGroupEligible)
    }

    /// Whether a group — named, or the Default group switched on — drives this display's brightness.
    /// Such a display is left out of Adaptive Display (the two never write against each other).
    private func isBrightnessGroupGoverned(_ member: DisplayRecordID) -> Bool {
        DisplayGroupStore.isGroupGoverned(member, in: settings.displayGroups,
                                          defaultGroup: settings.defaultDisplayGroup, eligible: defaultGroupEligible)
    }

    /// The Default group's members right now (Settings shows them; nothing is stored).
    var defaultGroupMembers: [DisplayRecordID] {
        DisplayGroupStore.resolvedDefaultGroup(settings.defaultDisplayGroup, eligible: defaultGroupEligible,
                                               groups: settings.displayGroups).memberRecordIDs
    }

    /// Delta followers skipped because their level was never read: read it now, so the leader's next
    /// change reaches them instead of skipping them again. One read in flight per display.
    private func refreshUnknownGroupLevels(_ members: [DisplayRecordID]) {
        for member in members where !groupLevelReads.contains(member) {
            guard let observation = displays.first(where: { $0.recordID == member }) else { continue }
            groupLevelReads.insert(member)
            Task { [weak self] in
                await self?.refreshBrightness(for: observation)
                self?.groupLevelReads.remove(member)
            }
        }
    }

    /// Issues one fan-out's follower writes under an echo token, so a write that finds its way back
    /// into `setBrightness` (a cache-driven binding, a re-entrant slider) can't become a leader event
    /// of its own. The token closes as soon as the writes are queued — the coalescing DDC/gamma
    /// writers own them from there.
    private func applyFollowerBrightness(_ fanOut: GroupSyncPolicy.FanOut, leader: DisplayRecordID,
                                         receipt: BrightnessWriteReceipt? = nil) {
        guard !fanOut.isEmpty else { return }
        let token = groupSyncEcho.begin(leader: leader, followers: fanOut.writes.map(\.member))
        for follower in fanOut.writes {
            guard let observation = displays.first(where: { $0.recordID == follower.member })
            else { continue }
            let write = applySilentBrightness(follower.value, for: observation,
                receipt: receipt?.follower(.init(clamping: Double(follower.value))))
            // Owner decision #8: each follower's change is published as its own event, once, with
            // no HUD; a rejected software write that changed nothing on screen is not.
            if let write, write.onScreen, OSDFeedbackPolicy.groupFollowerRoute(settings: settings).publishesEvent {
                publishOSDEvent(OSDContent(kind: .brightness, value: brightness[follower.member] ?? follower.value,
                                           assurance: Self.osdAssurance(write.method)),
                                for: observation, source: .groupSync, control: Self.osdControl(write.method))
            }
        }
        groupSyncEcho.end(token)
    }

    /// A follower's brightness write: same per-member method resolution the user funnel does
    /// (native DisplayServices, coalesced DDC, or software gamma), with no OSD and no adaptive note.
    /// Returns the route used and whether the change can be on screen (a rejected gamma write, with
    /// gamma the only carrier, changed nothing); nil when the display has no screen to write to.
    @discardableResult
    private func applySilentBrightness(_ value: Float, for observation: DisplayObservation, receipt: BrightnessWriteReceipt? = nil)
        -> (method: BrightnessMethod, onScreen: Bool)? {
        guard receipt?.admitDispatch() != false else { return nil }
        guard let cgID = observation.cgDisplayID else { receipt?.reject("Display is unavailable"); return nil }
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
            writeNativeBrightness(value, for: observation, receipt: receipt)
            #endif
        case .hardware:
            #if !PUBLIC_API_ONLY
            applyAdaptiveBrightness(value, for: observation, receipt: receipt)  // the existing coalesced DDC writer
            #endif
        case .software:
            // Same as the user funnel: cache the floored level that is applied.
            let level = DimmingComposer.softwareBrightnessLevel(requested: value)
            brightness[id] = level
            softwareDim[id] = level
            let landed = applyDim(level: level, id: id, cgID: cgID)
            let accepted = landed || effectiveDimmingMethod(for: id) != .gamma
            receipt?.complete(accepted: accepted, readback: accepted ? .applied(Double(level)) : .none)
            return (method, accepted)
        }
        return (method, true)
    }

    /// Fans a leader's contrast out to the rest of its group — a flat mirror with no offset learning
    /// (`GroupSyncPolicy.contrastFanOut`), skipping members whose panel reports no contrast channel.
    private func syncGroupContrast(_ value: Float, from observation: DisplayObservation, receipt: BrightnessWriteReceipt? = nil) {
        #if !PUBLIC_API_ONLY
        guard !safeStartup else { return }  // FA-09, as for brightness above
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
            setHardwareControl(.contrast, follower.value, for: target, isGroupSync: true,
                receipt: receipt?.follower(.init(clamping: Double(follower.value))))
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
        // The brightness cache holds each display's applied (or read-back) level — what a delta
        // group adds the leader's change to.
        return GroupSyncPolicy.World(present: Set(present), governed: governed,
                                     contrastCapable: Set(contrastCapable), levels: brightness)
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
    ///
    /// Every caller re-validates after the await — the one that started the build and each one that
    /// joined it: a display pruned meanwhile (it left, or its Apple-display override changed) or an
    /// override that no longer matches the one the build ran under means the result answers an old
    /// question, so it is neither cached nor used (FB-08 — turning the override off must stick, also
    /// for a power or input command that was already waiting on the build).
    private func ddcController(for observation: DisplayObservation) async -> ExternalDisplayDDC? {
        guard !ddcPairingTestRunning else { return nil }
        let id = observation.recordID
        if let existing = ddc[id] { return existing }
        let builder: (task: Task<ExternalDisplayDDC.BindingReport, Never>, build: DDCBindingTokens.Build)
        if let inFlight = ddcBuilders[id] {
            builder = inFlight
        } else {
            guard let cgID = observation.cgDisplayID else { return nil }
            let allowApple = settings.ddcAppleDisplayOverrideIDs.contains(id.rawValue)
            // A hand-paired channel (TR-06, owner decision #4) is consulted only where identity
            // refuses; the other connected displays' pairings keep two displays off one channel.
            let pairing = settings.ddcChannelMappings.first { $0.displayID == id }
            let present = Set(displays.map(\.recordID))
            let otherPairings = settings.ddcChannelMappings.filter { $0.displayID != id && present.contains($0.displayID) }
            let task = Task.detached(priority: .utility) {
                ExternalDisplayDDC.bind(displayID: cgID, allowAppleDisplay: allowApple, recordID: id,
                                        pairing: pairing, otherPairings: otherPairings)
            }
            builder = (task, ddcBindingTokens.begin(id, allowAppleDisplay: allowApple))
            ddcBuilders[id] = builder
        }
        let report = await builder.task.value
        let binding = report.binding
        // Only this build's own entry: a newer one may have been started after a prune.
        if ddcBuilders[id]?.build == builder.build { ddcBuilders[id] = nil }
        guard ddcBindingTokens.isCurrent(
            builder.build, for: id,
            allowAppleDisplay: settings.ddcAppleDisplayOverrideIDs.contains(id.rawValue)) else { return nil }
        let refusal = binding.refusal
        if ddcBindingRefusal[id] != refusal { ddcBindingRefusal[id] = refusal }
        if ddcPairingStatus[id] != report.pairing { ddcPairingStatus[id] = report.pairing }
        if case .invalid = report.pairing {
            // A failed evidence check revokes consent; it cannot revive silently on a later replug.
            settings.ddcChannelMappings.removeAll { $0.displayID == id }
            persistSettings()
        }
        // The same controller for every caller of one build; whoever resumes first caches it.
        if let controller = binding.controller { ddc[id] = controller }
        return binding.controller
    }

    /// Whether `controller` is still the binding held for `id`. Pruning drops it (the display left,
    /// or its Apple-display override changed), so a coalesced writer or a multi-step read that
    /// fetched the controller earlier checks this before each further transaction and stops —
    /// leaving the display's state alone, which the prune already reset — instead of sending through
    /// a binding the user has withdrawn (FB-08).
    private func ddcBindingIsCurrent(_ controller: ExternalDisplayDDC, for id: DisplayRecordID) -> Bool {
        ddc[id] === controller
    }

    private func drainDDCWrites(_ id: DisplayRecordID, _ observation: DisplayObservation, writer: UUID) async {
        var inFlight: BrightnessWriteReceipt?
        defer {
            inFlight?.reject("Request cancelled before readback")
            ddcWriterOwnership.finish(writer, for: id) {
                brightnessReceipts.invalidate(id)
                brightnessBeforeDDCWrite[id] = nil
                ddcWriters[id] = nil
            }
        }
        guard let controller = await ddcController(for: observation) else {
            guard !Task.isCancelled, ddcWriterOwnership.isCurrent(writer, for: id) else { return }
            brightness[id] = brightnessBeforeDDCWrite.removeValue(forKey: id)
            ddcWriteFailed[id, default: []].insert(0x10)
            ddcTarget[id] = nil
            return
        }
        guard !Task.isCancelled, ddcWriterOwnership.isCurrent(writer, for: id) else { return }
        let vcp = ExternalDisplayDDC.Feature.brightness.rawValue
        while !Task.isCancelled && !settings.softwareBrightnessDisplayIDs.contains(id.rawValue) {
            var lastTarget: Int?
            var lastSent = true
            while !Task.isCancelled, !settings.softwareBrightnessDisplayIDs.contains(id.rawValue), let target = ddcTarget[id] {
                guard ddcWriterOwnership.isCurrent(writer, for: id),
                      ddcBindingIsCurrent(controller, for: id) else { return }
                inFlight?.reject()
                inFlight = brightnessReceipts.take(id)
                ddcTarget[id] = nil
                guard inFlight?.admitDispatch() != false else { continue }
                lastTarget = target
                lastSent = await controller.write(.brightness, target, authorization: inFlight?.authorization)
                if !lastSent { inFlight?.complete(accepted: false, readback: .none) }
            }
            guard ddcWriterOwnership.isCurrent(writer, for: id), let lastTarget else { break }
            let readback = await readBackAfterDrain(controller, vcp: vcp, settleNanos: Self.continuousSettleNanos,
                                            superseded: { [weak self] in self?.ddcTarget[id] != nil })
            guard ddcWriterOwnership.isCurrent(writer, for: id) else { return }
            switch readback {
            case .cancelled: return  // pruned: the map entry is already gone, don't touch state
            case .superseded: inFlight?.reject(); inFlight = nil; continue  // a newer target arrived; write it, verify that one instead
            case .reading(let reading):
                inFlight?.complete(accepted: lastSent, readback: reading.map { .ddc(current: $0.current, max: $0.max) } ?? .none)
                inFlight = nil
                let outcome = DDCWriteVerification.outcome(
                    target: lastTarget, readback: reading?.current, tolerance: DDCReadbackPolicy.tolerance(.continuous))
                noteWriteVerification(outcome, vcp: vcp, id: id)
                noteWriteTransport(sent: lastSent, outcome: outcome, vcp: vcp, id: id)
                // No reply after a rejected transport write cannot support the optimistic value.
                if !lastSent, outcome == .unknown { brightness[id] = brightnessBeforeDDCWrite[id] }
                // TR-17: a HUD still showing this change now says whether the display took it.
                osdHUD.noteVerification(outcome, maxValue: reading?.max, display: id, kind: .brightness, target: lastTarget)
                if case .ignored(let actual) = outcome, let reading, reading.max > 0,
                   brightnessMethod[id] == .hardware {
                    brightness[id] = Float(actual) / Float(reading.max)
                }
            }
            break
        }
    }

    /// Settle time between a coalesced writer's LAST write and its verification read. Panels apply a
    /// Set-VCP asynchronously; reading back immediately can return the pre-write value and report a
    /// good write as ignored. Colour presets get longer — a mode switch reprograms the scaler's whole
    /// colour pipeline and some panels keep answering with the old code for a beat.
    private static let continuousSettleNanos = DDCReadbackPolicy.continuousSettleNanoseconds
    private static let presetSettleNanos = DDCReadbackPolicy.colorPresetSettleNanoseconds

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
        // One read of a sequence over a controller fetched earlier: not after the binding was dropped.
        guard ddcBindingIsCurrent(controller, for: id), ddcSupports(vcp, for: observation),
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
        guard ddcBindingIsCurrent(controller, for: id),
              ddcControlLevel[id]?[HardwareControl.volume.vcp] != nil, muteWriter[id] == nil,
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
                            showsOSD: Bool = true, eventSource: OSDBroadcast.Source = .menu,
                            receipt: BrightnessWriteReceipt? = nil) {
        #if !PUBLIC_API_ONLY
        guard observation.displayClass != .builtIn else { receipt?.reject("Hardware contrast is unavailable"); return }
        let id = observation.recordID
        if control == .contrast {
            contrastReceipts.enqueue(receipt, for: id)
        }
        let key = DDCControlKey(id: id, vcp: control.vcp)
        ddcControlLevel[id, default: [:]][control.vcp] = value
        // A level the user picks replaces the one a zero-volume mute remembered (TB-03): unmute must
        // not later jump back to a stale level.
        if control == .volume, value > 0 { preMuteVolume[id] = nil }
        ddcControlTarget[key] = Int((value * Float(ddcControlMax[key] ?? 100)).rounded())
        if ddcControlWriter[key] == nil {
            let writer = ddcControlWriterOwnership.begin(key)
            ddcControlWriter[key] = Task { [weak self] in await self?.drainHardwareWrites(key, control, observation, writer: writer) }
        }
        // Batch-3 #4 local HUD only when asked; the volume event is published either way (IN-04).
        if control == .volume {
            presentOSD(kind: .volume, value: value, for: observation, source: eventSource, showsLocalHUD: showsOSD,
                       control: "ddc")
        }
        if control == .contrast, !isGroupSync { syncGroupContrast(value, from: observation, receipt: receipt) }  // Issue #39
        #else
        receipt?.reject("Hardware contrast is unavailable in this build")
        #endif
    }

    #if !PUBLIC_API_ONLY
    private func drainHardwareWrites(_ key: DDCControlKey, _ control: HardwareControl, _ observation: DisplayObservation, writer: UUID) async {
        var inFlight: BrightnessWriteReceipt?
        defer {
            inFlight?.reject("Request cancelled before readback")
            ddcControlWriterOwnership.finish(writer, for: key) {
                if control == .contrast { contrastReceipts.invalidate(key.id) }
                ddcControlWriter[key] = nil
            }
        }
        guard let controller = await ddcController(for: observation),
              !Task.isCancelled, ddcControlWriterOwnership.isCurrent(writer, for: key) else { return }
        while true {
            var lastTarget: Int?
            var lastSent = true
            while !Task.isCancelled, let target = ddcControlTarget[key] {
                guard ddcControlWriterOwnership.isCurrent(writer, for: key),
                      ddcBindingIsCurrent(controller, for: key.id) else { return }
                if control == .contrast { inFlight?.reject(); inFlight = contrastReceipts.take(key.id) }
                ddcControlTarget[key] = nil
                guard inFlight?.admitDispatch() != false else { continue }
                lastTarget = target
                lastSent = await controller.write(vcp: key.vcp, target, authorization: inFlight?.authorization)
                if !lastSent { inFlight?.complete(accepted: false, readback: .none) }
            }
            guard ddcControlWriterOwnership.isCurrent(writer, for: key), let lastTarget else { break }
            let readback = await readBackAfterDrain(controller, vcp: key.vcp, settleNanos: Self.continuousSettleNanos,
                                            superseded: { [weak self] in self?.ddcControlTarget[key] != nil })
            guard ddcControlWriterOwnership.isCurrent(writer, for: key) else { return }
            switch readback {
            case .cancelled: return
            case .superseded: inFlight?.reject(); inFlight = nil; continue
            case .reading(let reading):
                inFlight?.complete(accepted: lastSent, readback: reading.map { .ddc(current: $0.current, max: $0.max) } ?? .none)
                inFlight = nil
                let outcome = DDCWriteVerification.outcome(
                    target: lastTarget, readback: reading?.current, tolerance: DDCReadbackPolicy.tolerance(.continuous))
                noteWriteVerification(outcome, vcp: key.vcp, id: key.id)
                noteWriteTransport(sent: lastSent, outcome: outcome, vcp: key.vcp, id: key.id)
                if control == .volume {  // TR-17, as for brightness
                    osdHUD.noteVerification(outcome, maxValue: reading?.max, display: key.id, kind: .volume, target: lastTarget)
                }
                // Snap the slider to where the panel actually is, so it stops showing a level the
                // monitor isn't at (LG: contrast 40 written, panel stays at 18/70).
                if case .ignored(let actual) = outcome, let reading, reading.max > 0 {
                    ddcControlLevel[key.id, default: [:]][key.vcp] = Float(actual) / Float(reading.max)
                    ddcControlMax[key] = reading.max
                }
            }
            break
        }
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
            guard ddcBindingIsCurrent(controller, for: id) else { return }
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

    /// Re-enumerates the installed profiles and re-reads every display's assignment — after an
    /// import, a removal or its undo, or when the user asks — so the choosers list files that
    /// appeared and drop ones that went, and the custom-profile safeguard judges the current files.
    func reloadInstalledColorProfiles() async {
        // Reloads can overlap (Refresh during an import); only the newest scan may land.
        installedProfilesRead &+= 1
        let read = installedProfilesRead
        let profiles = await Task.detached(priority: .userInitiated) { ColorProfileService.availableProfiles() }.value
        guard read == installedProfilesRead else { return }
        availableColorProfilesCache = profiles
        for display in displays { await refreshColorProfile(for: display) }
        await refreshCustomProfileGuard()
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

    /// A profile change can engage or lift this display's guard (which re-expresses only changed
    /// displays), and ColorSync reinstalling its table wipes an OpenDisplay one.
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
            _ = await coordinator.reconnectAll(beforeRequest: { [weak self] id in
                await self?.integrationSession.soft(.softReconnect, display: id, attempt: UUID())
            })
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
        if colorPresetWriter[id] == nil { presetBeforeDDCWrite[id] = colorPreset[id] }
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
        brightnessReceipts.invalidate(id); contrastReceipts.invalidate(id)
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

    /// Whether OpenDisplay itself is dimming, tinting or re-toning this display (software dim,
    /// temperature or contrast) — what `resetSoftwareAdjustments` would undo.
    func hasSoftwareAdjustments(_ observation: DisplayObservation) -> Bool {
        let id = observation.recordID
        return (softwareDim[id].map { $0 < 1 } ?? false) || colorTemperature[id] != nil
            || softwareContrast[id] != nil
    }

    /// Returns OpenDisplay's own software layers for a display — dim (gamma + overlay), colour
    /// temperature and contrast — to neutral. Independent of the monitor's factory reset (AM-06): the
    /// user picks it separately, so a monitor reset that failed (or a user who wants to keep the app's
    /// evening warmth) leaves them alone. Cleared in the cache first so `writeGamma` re-expresses a
    /// neutral slot. Under Black Out the panel is held at gamma 0 on purpose — the cache still resets,
    /// and lifting the blackout restores neutral. A suspension (AM-18) is the user's switch, not an
    /// adjustment: it stays as it is, as do the dimming method and the XDR boost.
    func resetSoftwareAdjustments(for observation: DisplayObservation) async {
        guard let cgID = observation.cgDisplayID else { return }
        let id = observation.recordID
        softwareDim[id] = nil
        colorTemperature[id] = nil
        softwareContrast[id] = nil
        if !blackedOut.contains(id) {
            writeGamma(level: 1.0, id: id, cgID: cgID)
            dimOverlay.remove(for: cgID)
        }
        // A software-brightness display's slider IS the dim level — re-derive it.
        await refreshBrightness(for: observation)
    }

    #if !PUBLIC_API_ONLY
    private func drainColorPresetWrites(_ id: DisplayRecordID, _ observation: DisplayObservation) async {
        guard let controller = await ddcController(for: observation) else {
            guard !Task.isCancelled else { return }
            colorPreset[id] = presetBeforeDDCWrite.removeValue(forKey: id)
            ddcWriteFailed[id, default: []].insert(0x14)
            colorPresetTarget[id] = nil
            colorPresetWriter[id] = nil
            return
        }
        defer { presetBeforeDDCWrite[id] = nil }
        let vcp = ExternalDisplayDDC.Feature.colorPreset.rawValue
        while true {
            var lastTarget: Int?
            var lastSent = true
            while let target = colorPresetTarget[id] {
                guard ddcBindingIsCurrent(controller, for: id) else { return }
                colorPresetTarget[id] = nil
                lastTarget = target
                lastSent = await controller.write(.colorPreset, target)
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
                noteWriteTransport(sent: lastSent, outcome: outcome, vcp: vcp, id: id)
                // No reply after a rejected transport write cannot support the optimistic value.
                if !lastSent, outcome == .unknown { colorPreset[id] = presetBeforeDDCWrite[id] }
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
        let wantRunning = anyModeOn && !safeStartup  // FA-09: no automatic brightness in safe startup
            && displays.contains { $0.isActive && $0.displayClass != .builtIn }
        if wantRunning {
            guard adaptiveLoop == nil else { return }
            adaptiveLoop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.adaptiveTick()
                    try? await Task.sleep(nanoseconds: ClockSchedulePolicy.samplingNanoseconds)
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
        let clockOn = settings.clockMode == nil && settings.clockScheduleEnabled && !settings.clockScheduleEntries.isEmpty
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
            let groupDrivesBrightness = isBrightnessGroupGoverned(id)
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
                brightnessSyncEnabled: brightnessGoverned && !groupDrivesBrightness
                    && !clockModeOwnsBrightness(id),
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
    private func applyAdaptiveBrightness(_ value: Float, for observation: DisplayObservation, receipt: BrightnessWriteReceipt? = nil) {
        brightnessReceipts.enqueue(receipt, for: observation.recordID)
        let id = observation.recordID
        if ddcWriters[id] == nil { brightnessBeforeDDCWrite[id] = brightness[id] }
        brightness[id] = value  // keep the visible slider honest
        ddcTarget[id] = Int((value * Float(brightnessMax[id] ?? 100)).rounded())
        if ddcWriters[id] == nil {
            let writer = ddcWriterOwnership.begin(id)
            ddcWriters[id] = Task { [weak self] in await self?.drainDDCWrites(id, observation, writer: writer) }
        }
    }

    /// OSD-silent adaptive preset apply. Updates the cache first so the policy's drift detection
    /// doesn't mistake our own write for a monitor-button change on the next tick.
    private func applyAdaptivePreset(_ code: Int, for observation: DisplayObservation) {
        let id = observation.recordID
        if colorPresetWriter[id] == nil { presetBeforeDDCWrite[id] = colorPreset[id] }
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
        guard !clockModeOwnsBrightness(id) else { return }
        let syncOn = settings.adaptiveBrightnessSyncEnabled
        let clockOn = settings.clockMode == nil && settings.clockScheduleEnabled && !settings.clockScheduleEntries.isEmpty
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
        let clockOn = settings.clockMode == nil && settings.clockScheduleEnabled && !settings.clockScheduleEntries.isEmpty
        let clockTarget = clockOn ? clockScheduleBrightness(atMinute: minuteOfDay, on: now) : nil
        if let clockTarget {
            // Clock Mode governs brightness and outranks the adaptive mirror.
            parts.append(String(localized: "clock \(Int((clockTarget * 100).rounded()))%"))
        } else if !clockModeOwnsBrightness(id)
                    && (settings.adaptiveBrightnessSyncEnabled || settings.adaptiveLocationModeEnabled) {
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
        let wantRunning = settings.appPresetsEnabled && !settings.appPresets.isEmpty && !safeStartup  // FA-09
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
        guard settings.appPresetsEnabled, !settings.appPresets.isEmpty, !safeStartup else { return }
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
    /// A Default-group member gets one only while that group syncs and has someone to sync with.
    func groupSyncCaption(for observation: DisplayObservation) -> String? {
        if let named = displayGroup(containing: observation.recordID) {
            return String(localized: "Synced with \(named.name)")
        }
        // The Default group resolves only while it has someone to sync with.
        guard let group = brightnessSyncGroup(containing: observation.recordID), group.syncBrightness
        else { return nil }
        return String(localized: "Brightness synced with the other displays")
    }

    /// Whether this display's brightness moves with a group right now — what offers the Shift
    /// bypass hint on its sliders.
    func brightnessIsGroupSynced(_ observation: DisplayObservation) -> Bool {
        isBrightnessGroupGoverned(observation.recordID)
    }

    /// Switches the Default group's brightness sync on or off (SO-05/AM-17). Its leader state starts
    /// fresh either way, and the native-brightness poll follows the new membership.
    func setDefaultGroupSyncBrightness(_ enabled: Bool) {
        guard settings.defaultDisplayGroup.syncBrightness != enabled else { return }
        settings.defaultDisplayGroup.syncBrightness = enabled
        groupSyncStates[DisplayGroup.defaultGroupID] = nil
        persistSettings()
    }

    /// Picks how a group's brightness reaches its followers (TR-15). Edits the live group, so a
    /// learned offset is never overwritten by a stale view copy, and starts its leader state fresh:
    /// a correction window opened under one mode means nothing under another. Offsets are kept.
    func setDisplayGroupBrightnessMode(_ mode: BrightnessSyncMode, for group: DisplayGroup) {
        editLiveDisplayGroup(group) { $0.brightnessMode = mode }
    }

    /// Whether changes made outside OpenDisplay that the app observes (macOS keys, System Settings,
    /// auto-brightness) lead the group.
    func setDisplayGroupFollowsOutsideChanges(_ follows: Bool, for group: DisplayGroup) {
        editLiveDisplayGroup(group) { $0.followsOutsideChanges = follows }
    }

    /// Applies `edit` to the stored copy of `group` — the Default group or a named one — and persists.
    private func editLiveDisplayGroup(_ group: DisplayGroup, _ edit: (inout DisplayGroup) -> Void) {
        if group.isDefaultGroup {
            edit(&settings.defaultDisplayGroup)
        } else {
            guard var edited = settings.displayGroups.first(where: { $0.id == group.id }) else { return }
            edit(&edited)
            settings.displayGroups = DisplayGroupStore.update(edited, in: settings.displayGroups)
        }
        groupSyncStates[group.id] = nil
        persistSettings()
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
    func setMode(_ mode: DisplayMode, for observation: DisplayObservation,
                 beforeMutation: (() -> AutomationIssue?)? = nil) async {
        // An arrangement apply in flight is a Core Graphics transaction too; a second one would
        // capture a half-applied "before" and race its readback.
        guard !displayConfigurationBusy else {
            if sceneApplying || arrangementRestoring {
                modeChangeError = String(localized: "Another display change is still being applied. Try again when it’s done.")
            } else {
                modeChangeError = arrangementApplying || pendingRevert?.kind == .arrangement
                    ? String(localized: "Confirm or revert the arrangement change first.")
                    : String(localized: "Confirm or revert the previous mode change first.")
            }
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
        // Persist the original arrangement BEFORE the write so a crash during verification can
        // recover. It replaces a record an earlier rollback couldn't confirm (`RevertMarkerPolicy`).
        if let issue = AutomationMutationPolicy.cancellationIssue ?? beforeMutation?() {
            modeChangeError = issue.message.appLocalized
            return
        }
        Self.writeRevertMarker(before)
        refreshRevertRecord()
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
            let restoreOutcome = await restoreArrangement(before)
            switch RevertMarkerPolicy.disposition(after: restoreOutcome) {
            case .clear:
                Self.clearRevertMarker()
                refreshRevertRecord()
                modeChangeError = String(localized: "macOS did not confirm the selected mode. The previous mode was restored.")
            case .awaitingDisplays:
                // The display can drop out under a mode it can't show: its restore is unconfirmed,
                // not done, and what it is owed stays on record for the next launch.
                Self.retainRevertMarker(after: restoreOutcome)
                refreshRevertRecord()
                modeChangeError = String(localized: "macOS did not confirm the selected mode. Not every display in the previous settings is connected, so they can’t be confirmed as restored yet; a record of them was saved and is restored at the next launch.")
            case .unverified:
                modeChangeError = String(localized: "macOS confirmed neither the selected mode nor the restore. Use emergency recovery; a record of the previous settings was saved.")
            }
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

    /// Re-anchor a fresh, identity-matched topology off the main actor. Every entry point shares
    /// this keep/revert transaction, so automation cannot bypass the owner's confirmation rule.
    @discardableResult
    func setMain(for observation: DisplayObservation, beforeMutation: (() -> AutomationIssue?)? = nil) async -> Bool {
        guard !displayConfigurationBusy else {
            modeChangeError = String(localized: "Confirm or revert the previous change first.")
            return false
        }
        modeChangeError = nil
        modeChangeInProgress = true
        defer { modeChangeInProgress = false }
        let before = await observer.currentSnapshot().observations
        guard let target = before.first(where: { $0.recordID == observation.recordID }),
              target.isActive, target.mirrorSourceID == nil, target.cgDisplayID != nil else {
            modeChangeError = String(localized: "The display is no longer active. Refresh the display list.")
            return false
        }
        if target.isMain { return true }
        let targets = before.compactMap { obs -> CoreGraphicsProvider.ArrangementTarget? in
            guard let id = obs.cgDisplayID, obs.mirrorSourceID == nil else { return nil }
            return .init(displayID: id,
                         origin: DisplayOrigin(x: obs.origin.x - target.origin.x, y: obs.origin.y - target.origin.y),
                         mode: nil)
        }
        if let issue = AutomationMutationPolicy.cancellationIssue ?? beforeMutation?() {
            modeChangeError = issue.message.appLocalized
            return false
        }
        Self.writeRevertMarker(before)
        refreshRevertRecord()
        let observer = self.observer
        let warnings = await Task.detached(priority: .userInitiated) { observer.applyArrangement(targets) }.value
        await refresh()
        let after = await observer.currentSnapshot().observations
        guard !Task.isCancelled, warnings.isEmpty,
              after.first(where: { $0.recordID == target.recordID })?.isMain == true else {
            let outcome = await restoreArrangement(before)
            if RevertMarkerPolicy.mayClearMarker(after: outcome) {
                Self.clearRevertMarker()
                refreshRevertRecord()
                modeChangeError = String(localized: "macOS did not confirm the main display change. The previous settings were restored.")
            } else {
                Self.retainRevertMarker(after: outcome)
                refreshRevertRecord()
                reportUnverifiedRestore(kind: .mainDisplay, after: outcome)
            }
            return false
        }
        await noteLayoutSelfChange()
        beginRevertWindow(before: before, message: String(localized: "Main display changed to \(displayName(for: target))"),
                          kind: .mainDisplay)
        return true
    }

    // MARK: - Timed auto-revert safety gate (Issue 6)

    /// Countdown length for the resolution revert window (clamped to a sane minimum).
    private var arrangementRevertSeconds: Int { max(3, settings.arrangementAutoRevertSeconds) }

    private func beginRevertWindow(before: [DisplayObservation], message: String,
                                   kind: PendingRevert.Kind = .mode) {
        let seconds = arrangementRevertSeconds
        revertGate = TimedRevertGate(before: before, deadline: Date().addingTimeInterval(Double(seconds)))
        revertMessage = message
        revertKind = kind
        // Crash recovery: a marker (same Application Support dir the checkpoints/rotation marker use)
        // lets the next launch restore the prior arrangement if the app dies mid-window.
        Self.writeRevertMarker(before)
        refreshRevertRecord()
        pendingRevert = PendingRevert(message: message, secondsRemaining: seconds, kind: kind)
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
                closeRevertWindow(after: await restoreArrangement(before))
                return
            }
            revertGate = gate
            pendingRevert = PendingRevert(message: revertMessage, secondsRemaining: gate.secondsRemaining(now: now),
                                          kind: revertKind)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// User accepted the change — keep it and close the window.
    func confirmArrangementChange() {
        guard var gate = revertGate, gate.confirm() else { return }
        revertGate = gate
        closeRevertWindow(after: .kept)
    }

    /// User asked to revert now — restore the prior arrangement and close the window.
    func revertArrangementChange() async {
        guard var gate = revertGate, let before = gate.revert() else { return }
        revertGate = gate
        closeRevertWindow(after: await restoreArrangement(before))
    }

    /// Closes the window. Its recovery record goes only when `outcome` allows it
    /// (`RevertMarkerPolicy`): a rollback that didn't verify keeps the record, and says so where the
    /// change was made.
    private func closeRevertWindow(after outcome: RevertMarkerPolicy.Outcome) {
        // "macOS placed the displays differently" describes an arrangement that's gone once reverted.
        if revertKind == .arrangement, revertGate?.resolution == .reverted { arrangementNote = nil }
        revertTask?.cancel()
        revertTask = nil
        revertGate = nil
        pendingRevert = nil
        guard RevertMarkerPolicy.mayClearMarker(after: outcome) else {
            Self.retainRevertMarker(after: outcome)
            refreshRevertRecord()
            reportUnverifiedRestore(kind: revertKind, after: outcome)
            return
        }
        Self.clearRevertMarker()
        refreshRevertRecord()
    }

    /// Says that a rollback couldn't be confirmed and its record was kept, where the change came
    /// from: the canvas for an arrangement, the mode controls otherwise. A restore that only lacks a
    /// disconnected display says that — it is not yet verified, not refused.
    private func reportUnverifiedRestore(kind: PendingRevert.Kind, after outcome: RevertMarkerPolicy.Outcome) {
        let message: String
        if case .awaitingDisplays = RevertMarkerPolicy.disposition(after: outcome) {
            message = String(localized: "Not every display in the previous display settings is connected, so their restore can’t be confirmed yet. FreeDisplay kept a record of them and restores it at the next launch; the next display change you make replaces that record.")
        } else {
            message = String(localized: "macOS didn’t confirm that the previous display settings were restored. FreeDisplay kept a record of them and restores it at the next launch; the next display change you make replaces that record.")
        }
        if kind == .arrangement { arrangementError = message } else { modeChangeError = message }
    }

    /// Restores each display's exact prior mode + origin (origins also restore which display is main,
    /// since Core Graphics treats the display at (0,0) as main), then its prior mirror state.
    /// A display that was a mirror target gets no origin of its own: it sits where its source is, and
    /// an origin write aimed at a target can change its mirror set (AM-09); the mirror step below
    /// puts it back with its source.
    ///
    /// Returns what the restore achieved, for `RevertMarkerPolicy` to judge: the arrangement write's
    /// warnings and what the topology read back afterwards still shows wrong — a request macOS
    /// accepted is not a restore that landed.
    private func restoreArrangement(_ recorded: [DisplayObservation]) async -> RevertMarkerPolicy.Outcome {
        arrangementRestoring = true
        defer { arrangementRestoring = false }
        // A display turned off since the recording keeps its "off" (`RevertMarkerPolicy.restorable`).
        let ledger = Set(managedOffline.map(\.recordID))
        let observations = RevertMarkerPolicy.restorable(recorded, ledger: ledger)
        // Core Graphics ids are re-resolved by record: the recording can be older than this session
        // (the launch-time restore), and a stale id may name another display by now.
        let live = await observer.currentSnapshot()
        let targets = observations.compactMap { obs -> CoreGraphicsProvider.ArrangementTarget? in
            guard let cgID = live.observation(for: obs.recordID)?.cgDisplayID else { return nil }
            return .init(displayID: cgID, origin: obs.mirrorSourceID == nil ? obs.origin : nil, mode: obs.mode)
        }
        var warnings: [String] = []
        if !targets.isEmpty {
            let observer = self.observer
            warnings = await Task.detached(priority: .userInitiated) { observer.applyArrangement(targets) }.value
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
        let after = RevertMarkerPolicy.restorable(await observer.currentSnapshot().observations, ledger: ledger)
        return .restored(providerWarnings: warnings,
                         mismatches: RevertMarkerPolicy.mismatches(wanted: observations, current: after))
    }

    /// Pending-revert marker (mirrors the rotation marker): the prior arrangement, persisted so a
    /// crash/quit during the window doesn't strand a bad layout — the next launch restores it.
    private static func revertMarkerURL() -> URL? {
        (try? DiskCheckpointStore.defaultDirectory())?.appendingPathComponent("revert.pending")
    }
    private static func writeRevertMarker(_ observations: [DisplayObservation]) {
        if let previous = readRevertRecord(), previous.observations == observations {
            writeRevertRecord(previous)
        } else {
            writeRevertRecord(RevertRecord(observations: observations, createdAt: Date()))
        }
    }
    private static func writeRevertRecord(_ record: RevertRecord) {
        guard let url = revertMarkerURL(), let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }
    private static func readRevertRecord() -> RevertRecord? {
        guard let url = revertMarkerURL(), let data = try? Data(contentsOf: url) else { return nil }
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return RevertRecord.decode(data, legacyDate: date)
    }
    private static func readRevertMarker() -> [DisplayObservation]? { readRevertRecord()?.observations }
    private static func clearRevertMarker() {
        if let url = revertMarkerURL() { try? FileManager.default.removeItem(at: url) }
    }
    private static func retainRevertMarker(after outcome: RevertMarkerPolicy.Outcome) {
        guard let record = readRevertRecord(), let kept = record.retaining(after: outcome) else { return }
        writeRevertRecord(kept)
    }

    private func refreshRevertRecord() {
        guard let url = Self.revertMarkerURL(), FileManager.default.fileExists(atPath: url.path) else {
            if revertRecordPresentation != nil { revertRecordPresentation = nil }
            return
        }
        let presentation = RevertRecordPresentation(record: Self.readRevertRecord(), current: displays)
        if presentation != revertRecordPresentation { revertRecordPresentation = presentation }
    }

    /// Called only after Diagnostics confirms. A live keep/revert transaction owns its record and
    /// must finish first; forgetting deletes no settings and performs no display write.
    func forgetPendingRevert() {
        guard !displayConfigurationBusy, let url = Self.revertMarkerURL() else { return }
        revertRecordError = nil
        do { try FileManager.default.removeItem(at: url) }
        catch { revertRecordError = String(localized: "Couldn’t forget the pending revert record.") }
        refreshRevertRecord()
    }

    /// Turns a live display off (flagship). Routes through the coordinator, which preflights and
    /// refuses to remove the last active surface; on success the display is remembered as
    /// managed-offline so it keeps an "off" card in the menu. Works on any display, the built-in
    /// included, as long as another stays active. Returns whether the disconnect committed, so the
    /// automatic callers (wake re-assert, auto-disconnect) can audit their outcome truthfully.
    @discardableResult
    func setDisplayActive(_ active: Bool, for observation: DisplayObservation,
                          as actor: Actor = .ui, reaction: UUID? = nil) async -> Bool {
        guard configuredReactionIsCurrent(reaction) else { return false }
        let authorization = reaction.map { configuredReactionGeneration.admission(for: $0) }
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
            options: DisconnectOptions(actor: actor, identityConfidence: 1.0, authorization: authorization))
        if authorization?.isAuthorized == false, case .cancelled? = result { return false }
        integrationSession.soft(.softDisconnect, display: observation.recordID, attempt: UUID())
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
    private func reconnectOffline(_ offline: OfflineDisplay, forgettingIntent: Bool, reaction: UUID? = nil) async -> Bool {
        guard configuredReactionIsCurrent(reaction) else { return false }
        busy = true
        defer { busy = false }
        if forgettingIntent { stampReconnectFailure(nil, for: offline) }  // a fresh attempt
        do {
            // By raw number only while it still names this display (`ReconnectIdentity`): the
            // number may have been handed to another monitor since the entry was written.
            let observations = await observer.currentSnapshot().observations
            guard configuredReactionIsCurrent(reaction) else { return false }
            try await ManagedOfflineRecovery.requestReconnect(
                offline, lifecycle: lifecycle, observations: observations,
                ledger: managedOffline, uuidForDisplayNumber: { CoreGraphicsProvider.persistentUUID(for: $0) },
                deadline: Date().addingTimeInterval(10), beforeRequest: { [weak self] in
                    await self?.integrationSession.soft(.softReconnect, display: offline.recordID, attempt: UUID())
                })
        } catch {
            // Keep the ledger entry: it is the ONLY record that this display exists and is owed a
            // reconnect. Forgetting it on a failed attempt orphans the display permanently — the
            // safety net would have nothing left to restore the next time nothing is active.
            #if DEBUG
            Self.err("reconnect failed for \(offline.name): \(error) — keeping it owed")
            #endif
            await refresh()
            // Our own refusal is not macOS's: nothing was sent, and the timeline says why.
            let refusal = error as? ReconnectIdentity.Conflict
            logDisplayEvent(refusal.map { "reconnect:refused \(offline.name): \($0)" }
                            ?? "reconnect:rejected \(offline.name)")
            if forgettingIntent { await noteReconnectFailure(of: offline, refusedBecause: refusal) }
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
    /// `refusedBecause`: the request was never sent, because the display number now names another
    /// display (`ReconnectIdentity`) — said as such, not as macOS failing to bring it back.
    private func noteReconnectFailure(of offline: OfflineDisplay,
                                      refusedBecause refusal: ReconnectIdentity.Conflict? = nil) async {
        stampReconnectFailure(Date(), for: offline)
        await appendAudit(ReconnectVerification.failureAudit(of: offline, actor: .ui, at: Date()))
        if settings.displayNotificationsEnabled {
            NotificationDelivery.post(refusal == nil
                ? NotificationDelivery.reconnectFailureNotification(for: offline, method: logicalOffMethod)
                : NotificationDelivery.reconnectRefusedNotification(for: offline))
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
        AppDiagnostics.shared.record("display event: \(reason)")
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
        let privacy = AppDiagnostics.exportPrivacy
        let diagnosticLog = AppDiagnostics.shared.buffer.records.map(\.line).joined(separator: "\n")
        let app = DiagnosticsBundle.AppInfo(
            version: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?", flavor: flavor)
        return await Task.detached(priority: .userInitiated) {
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return try? DiagnosticsBundle.export(to: desktop, app: app, privacy: privacy, diagnosticLog: diagnosticLog)
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
            configuredReactionGeneration.invalidate()
            let prior = displays
            // A reconfiguration can mean a monitor was re-plugged or power-cycled — its DDC may have
            // just come back (or gone away), so any negative probe knowledge is stale.
            resetDDCProbeCache()
            await refresh()
            clockModeLastRequests.removeAll()
            integrationSession.synchronize()
            logDisplayEvent("topology")
            await enforceActiveSurfaceInvariant()
            reconcileDisplaySleepGuard()  // external arrived/left → acquire or release the keep-awake assertion
            #if !PUBLIC_API_ONLY
            reconcileAdaptiveLoop()  // externals may have arrived/left → start or stop adaptive
            reconcileAppPresetObserver()  // and start/stop the frontmost-app observer to match
            evaluateAppPresets()  // govern a newly-arrived external (or release a departed one)
            #endif
            // SO-10: the user's own rules below wait out the configuration and wake delays; with
            // both blank (the default) nothing is deferred and they run now, as they always have.
            if deferConfiguredReactions(.topologyChange) {
                postDisplayNotifications(prior: prior, builtInAutoDisconnected: false)  // Batch-2 #5
                continue
            }
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
        if enabled, settings.notificationStyle == .notificationCenter { NotificationDelivery.requestAuthorization() }
    }

    /// Where notices go (SO-12). Choosing Notification Center while notices are on asks for the
    /// permission it needs; OpenDisplay's own window needs none. Confirmations and the OSD are
    /// separate presentations and don't follow this.
    func setNotificationStyle(_ style: NotificationStyle) {
        guard settings.notificationStyle != style else { return }
        settings.notificationStyle = style
        NotificationDelivery.style = style
        persistSettings()
        if settings.displayNotificationsEnabled, style == .notificationCenter {
            NotificationDelivery.requestAuthorization()
        }
    }

    /// Routine protection notices on/off (FA-16). Protection and its failure notices are unaffected.
    func setRoutineProtectionNoticesEnabled(_ enabled: Bool) {
        guard settings.routineProtectionNoticesEnabled != enabled else { return }
        settings.routineProtectionNoticesEnabled = enabled
        persistSettings()
    }

    /// Dock icon policy (SO-13). The app delegate observes `settings` and applies it at once.
    func setDockIconPolicy(_ policy: DockIconPolicy) {
        guard settings.dockIconPolicy != policy else { return }
        settings.dockIconPolicy = policy
        persistSettings()
    }

    /// True when an external display other than macOS's virtual placeholder is present. Automatic
    /// disconnect uses the stricter shared PhysicalPresence evidence instead, and the keep-awake
    /// assertion has its own reading (`DisplaySleepPrevention`).
    var hasExternalDisplay: Bool {
        displays.contains { $0.displayClass != .builtIn && $0.displayClass != .virtual }
    }

    /// On an external-arrival edge (and only then), turn the built-in panel off through the gated
    /// coordinator path (Issue 5). The built-in returns when the last external leaves — that's the
    /// existing always-one-active safety net (`enforceActiveSurfaceInvariant`), not duplicated here.
    private func observeAutoDisconnectArrival() {
        autoDisconnectPolicy.observe(enabled: settings.autoDisconnectBuiltInOnExternal,
            externalPresent: AutoDisconnectBuiltInPolicy.eligibleExternalPresent(in: displays), suppressed: safeStartup)
    }

    @discardableResult
    private func applyAutoDisconnectBuiltInIfNeeded(reaction: UUID? = nil) async -> Bool {
        observeAutoDisconnectArrival()
        guard configuredReactionIsCurrent(reaction), !safeStartup, !busy else { return false }
        guard let arrival = autoDisconnectPolicy.pendingArrival else { return false }
        guard let builtIn = displays.first(where: { $0.displayClass == .builtIn && $0.isActive }) else {
            autoDisconnectPolicy.consumeArrival(arrival)
            return false
        }
        #if DEBUG
        Self.err("AUTO-DISCONNECT firing: turning off \(displayName(for: builtIn))")
        #endif
        let committed = await setDisplayActive(false, for: builtIn, as: .system, reaction: reaction)
        if committed || configuredReactionIsCurrent(reaction) { autoDisconnectPolicy.consumeArrival(arrival) }
        guard committed || configuredReactionIsCurrent(reaction) else { return false }
        await appendAudit(AutoDisconnectBuiltInPolicy.auditEntry(
            builtIn: builtIn.recordID, committed: committed, at: Date()))
        return true
    }

    /// Toggle for "auto-disconnect the built-in when an external connects" (Issue 5). Persists the
    /// setting; takes effect on the next external arrival (it never disconnects retroactively).
    func setAutoDisconnectBuiltInOnExternal(_ enabled: Bool) {
        guard settings.autoDisconnectBuiltInOnExternal != enabled else { return }
        settings.autoDisconnectBuiltInOnExternal = enabled
        observeAutoDisconnectArrival()
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

    func canPersistDisplaySettings(_ id: DisplayRecordID) -> Bool {
        liveDisplayIdentities.isVerified(id, remembered: registryKnownRecords[id])
    }

    func keyboardAudioPreferences(for id: DisplayRecordID) -> DisplayKeyboardAudioPreferences {
        guard canPersistDisplaySettings(id) else { return .default }
        return settings.keyboardAudioPreferences(for: id)
    }

    /// Whether `display` itself keeps the displays awake while it is connected and lit (AM-42).
    func preventsDisplaySleep(_ display: DisplayRecordID) -> Bool {
        canPersistDisplaySettings(display) && settings.preventsDisplaySleep(for: display)
    }

    /// This display's own "keep the displays awake while connected" (AM-42). Turning it off affects
    /// only this display: another display, or the "any external" setting, may still hold the
    /// assertion — `displaySleepPrevention` says which.
    func setPreventsDisplaySleep(_ enabled: Bool, for display: DisplayRecordID) {
        guard canPersistDisplaySettings(display), preventsDisplaySleep(display) != enabled else { return }
        if enabled {
            guard let live = displays.first(where: { $0.recordID == display }),
                  DisplaySleepPrevention.ineligibility(of: .init(live)) == nil else { return }
            settings.preventDisplaySleepDisplayIDs.insert(display.rawValue)
        } else {
            settings.preventDisplaySleepDisplayIDs.remove(display.rawValue)
        }
        persistSettings()
        reconcileDisplaySleepGuard()
    }

    /// Configuration and wake delays and the menu's animation duration (SO-10). The delays are read
    /// at each display event; the animation duration takes effect at the next transition.
    func setApplicationTiming(_ timing: ApplicationTimingPreferences) {
        guard timing.unusableFieldKey == nil, settings.applicationTiming != timing else { return }
        settings.applicationTiming = timing
        persistSettings()
        TrayMotion.animationDuration = timing.animationDuration
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

    /// What a click on an update affordance does (`SoftwareUpdatePresentation.Action`): check or
    /// retry, cancel what is in flight, or bring the waiting offer forward.
    func performUpdateAction(_ action: SoftwareUpdatePresentation.Action) {
        softwareUpdater.perform(action)
    }

    /// A surface showing the update state again: a check result older than the configured threshold
    /// is cleared, an offer no longer newer than this build is dropped. The threshold is the
    /// `FreeDisplayUpdateResultStaleSeconds` default; unset, results stay until the next check.
    func updateSurfaceAppeared() {
        softwareUpdater.clearStaleResult(staleAfter: Self.updateResultStaleAfter)
    }

    /// The owner-configurable threshold behind `updateSurfaceAppeared` (none by default).
    private static var updateResultStaleAfter: TimeInterval? {
        guard let seconds = (UserDefaults.standard.object(forKey: "FreeDisplayUpdateResultStaleSeconds") as? NSNumber)?
            .doubleValue, seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
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

    /// Acquire or release the keep-awake assertion for the current settings and displays, per
    /// `DisplaySleepPrevention`: only lit, non-virtual displays own it, so a display that was
    /// switched off or unplugged stops holding it at the next topology change. Idempotent — safe to
    /// call on every topology change and every settings change.
    private func reconcileDisplaySleepGuard() {
        guard !appManagementIsQuitting else { return }
        let decision = DisplaySleepPrevention.decide(
            // Shift safe startup (FA-09) holds no keep-awake assertion.
            anyExternal: settings.preventDisplaySleepWithExternal && !safeStartup,
            perDisplay: safeStartup ? [] : Set(settings.preventDisplaySleepDisplayIDs.filter {
                canPersistDisplaySettings(DisplayRecordID(rawValue: $0))
            }),
            candidates: displays.map(DisplaySleepPrevention.Candidate.init))
        sleepGuard.apply(decision)
        let snapshot = DisplaySleepPrevention.Snapshot(decision: decision, status: sleepGuard.status)
        if displaySleepPrevention != snapshot { displaySleepPrevention = snapshot }
    }

    /// Persists `settings` to the on-disk store (best-effort; a write failure leaves the in-memory
    /// value authoritative for this session).
    private func persistSettings() {
        #if !PUBLIC_API_ONLY
        reconcileGroupBrightnessLoop()
        #endif
        try? settingsStore?.save(settings)
        reconcileClockMode()
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
        // The cheapest rescue first: when the only screens left are blacked out (the other one was
        // unplugged, or turned off from another process) and nothing is on its way back, the user's
        // own overlay is what hides them.
        switch WakeConvergencePolicy.blackOutRescue(wakeConvergenceContext(), blackedOut: blackedOut) {
        case .none:
            break
        case .wait(let delay):
            // Lighting a turned-off display meanwhile would be the wrong rescue: the blackout is.
            armActiveSurfaceRecheck(after: delay)
            return
        case .lift(let lift):
            #if DEBUG
            Self.err("ACTIVE-SURFACE GUARD: only blacked-out screens are left — lifting Black Out")
            #endif
            liftBlackOuts(lift)
            logDisplayEvent("blackout:lifted \(lift.count)")
            await appendAudit(WakeConvergencePolicy.netLiftBlackOutAudit(of: lift, at: Date()))
            displaysDarkSince = WakeConvergencePolicy.recoverySurfaces(in: safetyObservations).isEmpty
                ? (displaysDarkSince ?? Date())
                : nil
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
        guard WakeConvergencePolicy.recoverySurfaces(in: safetyObservations).isEmpty else { return }
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
    ///
    /// Every in-process surface — buttons, ⌃⌥⌘R, the local HTTP server, `opendisplay://` URLs and the
    /// Reconnect All intent — comes here, because only this model holds the live ledger: a fresh
    /// `CommandGateway` sees nothing to reconnect. Returns the shared reconnect-all envelope (a
    /// display counts only once it was seen lit) and audits it under the calling surface's actor.
    ///
    /// Waits for the launch-time ledger load first: an intent or a link can launch the app and
    /// arrive before it, and against the still-empty ledger this answered "nothing to reconnect".
    @discardableResult
    func reconnectAll(actor: Actor = .ui) async -> ResultEnvelope {
        await awaitStartupLoad()
        busy = true
        defer { busy = false }
        let requestedAt = Date()
        // "Give me my screens back" includes the ones this app is covering itself.
        if !blackedOut.isEmpty {
            logDisplayEvent("blackout:lifted \(blackedOut.count) (reconnect all)")
            liftBlackOuts(blackedOut)
        }
        var results = await coordinator.reconnectAll(beforeRequest: { [weak self] id in
            await self?.integrationSession.soft(.softReconnect, display: id, attempt: UUID())
        })
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { (displayId: $0.key.rawValue, reconnected: $0.value) }
        for offline in managedOffline {
            let lit = await reconnectOffline(offline, forgettingIntent: true)
            results.append((offline.recordID.rawValue, lit))
            busy = true  // the per-display path clears it on return; the batch is still running
        }
        await refresh()
        let envelope = ResultEnvelope.reconnectAll(
            results: results, actor: actor, requestedAt: requestedAt,
            topologyGeneration: await observer.currentSnapshot().generation.value)
        await appendAudit(AuditEntry(
            timestamp: requestedAt, actor: actor, command: "reconnectAll",
            transactionId: envelope.transactionId, status: envelope.status.rawValue,
            targets: envelope.targets.map(\.displayId)))
        return envelope
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
                    self?.configuredReactionTimer.cancel()
                    self?.configuredReactionGeneration.invalidate()
                    self?.pendingReactionTrigger = nil
                    self?.integrationSession.sleep()
                    self?.isBetweenSleepAndWake = true
                    self?.clockModeLastRequests.removeAll()
                    self?.logDisplayEvent("sleep")
                }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.integrationSession.wake()
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
        configuredReactionGeneration.invalidate()
        logDisplayEvent("wake")
        lastWakeAt = Date()
        clockModeSession.didWake(policy: settings.clockMode?.resumePolicy ?? .currentInterval)
        clockModeLastRequests.removeAll()
        isBetweenSleepAndWake = false  // the transition is over; the bounded window starts now
        offlineReassertAttempts.removeAll()  // a new wake is a fresh world; prior attempts don't count
        // A dark spell stamped as the machine went down must not count against the recovery
        // deadline: measured from a pre-sleep stamp, the net would light its fallback on the very
        // first post-wake look instead of giving returning displays their eight seconds. The
        // refresh below re-stamps "now" if the screens really are still dark.
        displaysDarkSince = nil
        await refresh()
        await enforceActiveSurfaceInvariant()
        // SO-10: the wake delay holds back the user's rules — never the safety net above.
        if deferConfiguredReactions(.wake) { return }
        await reassertManagedOfflineIntent()
        await evaluateLayoutProtection(trigger: .wake)
        await clockModeTick()
    }

    /// Defers the user's rules (built-in off on arrival, owed "off"s, Protected Layout) when the
    /// configuration or wake delay asks for a wait, or a deferred run is already pending — every
    /// event re-arms the one timer, so the rules run once, after the last event. Returns false when
    /// they should run now, which is always the case with both delays blank.
    private func deferConfiguredReactions(_ trigger: ConfiguredReactionSchedule.Trigger) -> Bool {
        guard !appManagementIsQuitting, !isBetweenSleepAndWake else { return false }
        let delay = ConfiguredReactionSchedule.delay(
            for: trigger, now: Date(), lastWakeAt: lastWakeAt, timing: settings.applicationTiming)
        guard delay > 0 || configuredReactionTimer.isArmed else { return false }
        layoutProtectionRecheck.cancel()
        offlineIntentRecheck.cancel()
        pendingReactionTrigger = ConfiguredReactionSchedule.merged(pendingReactionTrigger, with: trigger)
        let generation = configuredReactionGeneration.invalidate()
        configuredReactionTimer.arm(after: delay) { [weak self] in
            await self?.runDeferredReactions(generation: generation)
        }
        return true
    }

    /// The deferred run: the same rules, in the same order, against the topology as it is now.
    private func configuredReactionIsCurrent(_ generation: UUID?) -> Bool {
        guard let generation else { return true }
        return !appManagementIsQuitting && !isBetweenSleepAndWake
            && configuredReactionGeneration.isCurrent(generation)
    }

    private func runDeferredReactions(generation: UUID) async {
        guard configuredReactionIsCurrent(generation) else { return }
        let trigger = pendingReactionTrigger ?? .topologyChange
        await refresh()
        guard configuredReactionIsCurrent(generation) else { return }
        pendingReactionTrigger = nil
        let before = displays
        if await applyAutoDisconnectBuiltInIfNeeded(reaction: generation) {
            postDisplayNotifications(prior: before, builtInAutoDisconnected: true)
        }
        guard configuredReactionIsCurrent(generation) else { return }
        await reassertManagedOfflineIntent(reaction: generation)
        guard configuredReactionIsCurrent(generation) else { return }
        await evaluateLayoutProtection(trigger: trigger == .wake ? .wake : .topologyChange, reaction: generation)
    }

    /// Puts back off every display the ledger owns that woke up with the machine.
    ///
    /// This is the fix for the reported bug in one function: macOS relights the built-in on wake
    /// (its own display-configuration transactions don't survive a sleep), the app used to read that
    /// as "the user turned it back on", drop the ledger entry, and leave the laptop panel glowing
    /// next to the externals for the rest of the session. Now the return is recognised for what it
    /// is and undone — but only once something else is lit to take over, and only a bounded number
    /// of times, so the safety net's guarantee is never the thing being argued with.
    private func reassertManagedOfflineIntent(reaction: UUID? = nil) async {
        guard configuredReactionIsCurrent(reaction) else { return }
        offlineIntentRecheck.cancel()
        // Safe startup (FA-09): nothing is turned off automatically. The ledger itself is left as
        // it is, so the off cards stay and switching a display back on by hand works as usual.
        guard !safeStartup else { return }
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
                await self.reassertManagedOfflineIntent(reaction: reaction)
            }
        }
        guard !busy, !intent.reassert.isEmpty else { return }
        for offline in intent.reassert {
            guard configuredReactionIsCurrent(reaction) else { return }
            guard let live = displays.first(where: { $0.recordID == offline.recordID && $0.isActive })
            else { continue }
            #if DEBUG
            Self.err("WAKE: \(offline.name) came back with the machine — turning it off again")
            #endif
            let committed = await setDisplayActive(false, for: live, as: .wakeConvergence, reaction: reaction)
            guard committed || configuredReactionIsCurrent(reaction) else { return }
            offlineReassertAttempts[offline.recordID, default: 0] += 1
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

    /// The observed world both wake-convergence decisions reason over, Black Out stamped in.
    private func wakeConvergenceContext() -> WakeConvergencePolicy.Context {
        WakeConvergencePolicy.Context(
            now: Date(), observations: safetyObservations, managedOffline: managedOffline,
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
    func evaluateLayoutProtection(trigger: LayoutProtectionPolicy.Trigger, reaction: UUID? = nil) async {
        guard configuredReactionIsCurrent(reaction) else { return }
        layoutProtectionRecheck.cancel()
        let snapshot = await observer.currentSnapshot()
        guard configuredReactionIsCurrent(reaction) else { return }
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
        // Safe startup (FA-09) still tracks which display set is on the desk — the Arrange card
        // needs it — but restores nothing.
        guard settings.layoutProtectionEnabled, !safeStartup else { return }
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
                await self?.evaluateLayoutProtection(trigger: trigger, reaction: reaction)
            }
            return
        }
        guard case .restore(let analysis) = evaluation.decision, let protected else { return }
        // A display change of the user's is being written or awaits Keep/Revert: its scene write
        // would be refused (`applyScene`), and the lifecycle and mirror writes around it would land
        // in the middle of that transaction. Its own self-change note, or the next topology event,
        // decides what protection makes of the result — no attempt is spent on it.
        guard !displayConfigurationBusy else { return }
        layoutProtectionState = LayoutProtectionPolicy.noteRestoreAttempt(state: layoutProtectionState)
        await restoreProtectedLayout(protected, analysis: analysis, before: snapshot.generation, reaction: reaction)
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
                                        before generation: TopologyGeneration, reaction: UUID? = nil) async {
        guard configuredReactionIsCurrent(reaction) else { return }
        await appendLayoutProtectionAudit(status: "attempted", analysis: analysis)
        guard configuredReactionIsCurrent(reaction) else { return }
        await restoreProtectedActiveState(config, analysis: analysis, reaction: reaction)
        // Before the scene: the saved origins were captured with the saved rotation.
        guard configuredReactionIsCurrent(reaction) else { return }
        await restoreProtectedRotation(config, analysis: analysis, reaction: reaction)
        guard configuredReactionIsCurrent(reaction) else { return }
        await applyScene(LayoutProtectionPolicy.restoreScene(for: config), reaction: reaction)
        guard configuredReactionIsCurrent(reaction) else { return }
        await restoreProtectedMirroring(config, analysis: analysis, reaction: reaction)

        let settled = await observer.awaitStableGeneration(after: generation)
        guard configuredReactionIsCurrent(reaction) else { return }
        // Suppress the generation our writes raised — or, when they raised none, clear the
        // suppression `applyScene` optimistically took, so a restore that didn't land can be retried
        // instead of silencing the drift it failed to fix.
        layoutProtectionState = LayoutProtectionPolicy.noteRestoreOutcome(
            before: generation, after: settled.generation, state: layoutProtectionState)
        let residual = LayoutProtectionPolicy.actionableDrift(
            protected: config.snapshot, current: settled, context: layoutProtectionContext())
        let restored = !(residual?.hasDrifted ?? false)
        await appendLayoutProtectionAudit(status: restored ? "committed" : "partial", analysis: analysis)
        // A successful restore is a routine protection notice — the one kind the user can mute
        // without losing failure notices (FA-16); the failure path above is never muted that way.
        guard restored, let note = NotificationDelivery.layoutRestoreNotification(
            for: analysis, names: layoutProtectionDisplayNames(),
            enabled: NotificationPolicy.shouldDeliver(.routineProtection, settings: settings))
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
                                             analysis: DisplayConfigDrifter.DriftAnalysis, reaction: UUID? = nil) async {
        guard configuredReactionIsCurrent(reaction) else { return }
        let wantsOff = LayoutProtectionPolicy.desiredOff(in: config.snapshot)
        for change in analysis.changes {
            guard configuredReactionIsCurrent(reaction) else { return }
            let id: DisplayRecordID
            switch change {
            case .activeChanged(let changed), .appeared(let changed): id = changed
            default: continue
            }
            let wanted = !wantsOff.contains(id)
            if wanted, let offline = managedOffline.first(where: { $0.recordID == id }) {
                await reconnectOffline(offline, forgettingIntent: true, reaction: reaction)
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
                                          analysis: DisplayConfigDrifter.DriftAnalysis, reaction: UUID? = nil) async {
        guard configuredReactionIsCurrent(reaction) else { return }
        guard rotationWritable else { return }
        for change in analysis.changes {
            guard configuredReactionIsCurrent(reaction) else { return }
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
                                           analysis: DisplayConfigDrifter.DriftAnalysis, reaction: UUID? = nil) async {
        guard configuredReactionIsCurrent(reaction) else { return }
        let current = await observer.currentSnapshot()
        guard configuredReactionIsCurrent(reaction) else { return }
        let steps = LayoutProtectionPolicy.mirrorRestoreSteps(
            protected: config.snapshot, current: current, analysis: analysis)
        if await applyMirrorSteps(steps, in: current, reaction: reaction) { await refresh() }
    }

    /// Performs mirror steps against fresh Core Graphics IDs from `snapshot`. A step whose display or
    /// source has no live ID is skipped rather than substituted. Returns whether anything was written.
    /// A rejected write isn't retried here: Protected Layout's residual check reports it, and the
    /// keep/revert path reads the topology back and keeps its record (`RevertMarkerPolicy`).
    private func applyMirrorSteps(_ steps: [MirrorRestorePlan.Step], in snapshot: TopologySnapshot, reaction: UUID? = nil) async -> Bool {
        var wrote = false
        for step in steps {
            guard configuredReactionIsCurrent(reaction) else { return wrote }
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
        if ddcPairingTestRunning || ddcPairingTestSession.isRunning { return true }
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
        appManagementIsQuitting = true
        #if !PUBLIC_API_ONLY
        testedDDCMapping = nil
        await ddcPairingTestSession.cancelAndRestore()
        #endif
        configuredReactionTimer.cancel()
        configuredReactionGeneration.invalidate()
        pendingReactionTrigger = nil
        sleepGuard.releaseAll()
        displaySleepPrevention = .init()

        clockModeLifecycleSuspended = true
        clockModeTask?.cancel()
        clockModeTask = nil
        integrationSession.stop()
        // Black Out goes first: the reconnects below can leave a blacked-out screen as the only lit
        // one, and the overlay would otherwise stay up for as long as teardown takes.
        liftBlackOuts(blackedOut)
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
        // A request is not a display coming back, so the ledger keeps every entry the live topology
        // doesn't show lit afterwards, stamped as a failed reconnect: it is the only record of a
        // display that stayed dark, and the next launch's off card and safety net work from it.
        if !managedOffline.isEmpty {
            for offline in managedOffline {
                // Refused when the number now names another display — that entry is kept below.
                try? await ManagedOfflineRecovery.requestReconnect(
                    offline, lifecycle: lifecycle, observations: await observer.currentSnapshot().observations,
                    ledger: managedOffline, uuidForDisplayNumber: { CoreGraphicsProvider.persistentUUID(for: $0) },
                    deadline: Date().addingTimeInterval(10))
            }
            // One look, straight after the requests: quit doesn't wait out a slow link. A display still
            // training its link is therefore kept too — and dropped by the next launch, which forgets
            // entries whose display is back — so nothing is audited as failed from here.
            let observed = await observer.currentSnapshot().observations
            managedOffline = ReconnectVerification.ledgerAfterQuitReconnect(managedOffline, observations: observed,
                                                                            at: Date())
            persistManagedOffline()
        }
        releaseAllGamma()
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

    // MARK: - Luminance anchors (SD-13/TB-13)

    /// The luminance anchors stored for a display, nil when nothing is stored.
    func luminanceAnchors(for observation: DisplayObservation) -> LuminanceAnchorSettings? {
        guard canPersistDisplaySettings(observation.recordID) else { return nil }
        return settings.savedLuminanceAnchors(for: observation.recordID)
    }

    /// Stores a display's luminance anchors. Labels only: nothing here reaches the display. A
    /// record back at its first-run state (manual values on, nothing entered) is dropped rather
    /// than kept empty.
    func setLuminanceAnchors(_ anchors: LuminanceAnchorSettings, for observation: DisplayObservation) {
        guard canPersistDisplaySettings(observation.recordID) else { return }
        let key = observation.recordID.rawValue
        let stored: LuminanceAnchorSettings? = anchors.isDefault ? nil : anchors
        guard settings.luminanceAnchorsByDisplay[key] != stored else { return }
        settings.setLuminanceAnchors(stored, for: observation.recordID)
        persistSettings()
    }

    // MARK: - App settings archive (SO-11/FA-10): export, import, reset

    /// What an import confirmation shows, worked out before anything changes.
    struct SettingsImportPreview: Identifiable {
        let id = UUID()
        let fileName: String
        let archive: SettingsArchive
        /// Displays the archive's preferences are keyed to that this Mac doesn't know (yet).
        let unmatchedDisplays: [SettingsArchive.ArchivedDisplay]
    }

    /// Where every import and reset writes its backup first.
    var settingsBackupDirectory: URL? { try? SettingsBackupStore.defaultDirectory() }

    /// The app's configuration as it stands, as an archive: what Export writes and what a backup
    /// holds. Taken from the live model (a pending group-offset write is flushed first), falling
    /// back to the files when the registry or scene library hasn't finished loading.
    func currentSettingsArchive() async -> SettingsArchive {
        flushPendingGroupPersist()
        let registryState: RegistryState
        if let registry {
            registryState = await registry.currentState()
        } else if let directory = try? DiskRegistryStore.defaultDirectory() {
            registryState = await DiskRegistryStore(directory: directory).load()
        } else {
            registryState = RegistryState()
        }
        let savedScenes: [Scene]
        if let sceneLibrary {
            savedScenes = await sceneLibrary.all()
        } else if let directory = try? DiskSceneStore.defaultDirectory() {
            savedScenes = await DiskSceneStore(directory: directory).load()
        } else {
            savedScenes = []
        }
        return SettingsArchive(
            createdAt: Date(), appVersion: Self.archiveAppVersion, settings: settings, favorites: favorites,
            registry: registryState, scenes: savedScenes,
            defaults: ArchivedDefaults(experimentalRotationEnabled: experimentalRotationEnabled),
            menuLayout: menuLayout,
            integrations: integrationSession.configuration)
    }

    /// Writes the current configuration to `url` (a user-chosen file).
    func exportSettings(to url: URL) async throws {
        try await currentSettingsArchive().write(to: url)
    }

    /// Reads and validates `url` and lists the displays its settings point at that this Mac
    /// doesn't remember. Changes nothing; throws `SettingsArchiveError` for a refused file.
    func previewSettingsImport(from url: URL) async throws -> SettingsImportPreview {
        let archive = try SettingsArchive.read(from: url)
        await refreshRegistryKnownRecords()
        let known = Set(registryKnownRecords.keys)
            .union(displays.map(\.recordID))
            .union(managedOffline.map(\.recordID))
        return SettingsImportPreview(fileName: url.lastPathComponent, archive: archive,
                                     unmatchedDisplays: archive.unmatchedDisplays(known: known))
    }

    /// Replaces OpenDisplay's configuration with `incoming` — an imported archive, or the factory
    /// defaults for a reset — after writing a backup of the current one, and returns the backup's
    /// location. Throws, changing nothing, if the backup can't be written. Only app-owned stores
    /// change: the macOS display configuration, the managed-offline list, checkpoints and logs are
    /// not written, and the restore ledgers carry over so a display FaceLight or a preset holds is
    /// still owed its values. The caller relaunches afterwards, which is what re-arms hotkeys,
    /// loops and observers from the new settings — and, being a quit, reconnects the displays the
    /// app turned off, as every quit does.
    ///
    /// A store that can't be written fails the whole replacement (`installFailed`), never a
    /// silent success: the stores written up to that point are put back to the current state,
    /// and the error says whether that worked, so the caller doesn't relaunch onto half an import.
    func replaceSettings(with incoming: SettingsArchive) async throws -> URL {
        let current = await currentSettingsArchive()
        let replacement: SettingsBackupStore.Replacement
        do {
            let backups = SettingsBackupStore(directory: try SettingsBackupStore.defaultDirectory())
            replacement = try backups.prepareReplacement(current: current, live: settings, incoming: incoming)
        } catch {
            throw SettingsReplaceError.backupFailed(underlying: error)
        }
        // What a failed install puts back: the live state, restore ledgers included (an archive
        // never carries them, so `current` has them stripped).
        var previous = current
        previous.settings = settings
        var reached: [InstallStep] = []
        do {
            try await install(replacement.archive, reached: &reached)
        } catch {
            let restored = await restore(previous, afterFailedInstallOf: reached)
            throw SettingsReplaceError.installFailed(underlying: error, backup: replacement.backupURL,
                                                     restored: restored)
        }
        return replacement.backupURL
    }

    /// Which half of `replaceSettings` failed: before anything changed, or part-way through
    /// writing. `restored` says whether every store the install had reached was put back; when it
    /// is false, some of them hold the incoming state and the backup is the way back.
    enum SettingsReplaceError: Error {
        case backupFailed(underlying: Error)
        case installFailed(underlying: Error, backup: URL, restored: Bool)
    }

    /// The archive used for "Reset to Defaults".
    func factoryDefaultSettingsArchive() -> SettingsArchive {
        .factoryDefaults(createdAt: Date(), appVersion: Self.archiveAppVersion)
    }

    /// The stores an archive installs into, in the order `install` writes them.
    private enum InstallStep: CaseIterable {
        case settings, favorites, registry, scenes, defaults, menuLayout, integrations
    }

    /// Puts `archive` into memory and on disk together. The in-memory half matters as much as the
    /// files: anything that saves before the relaunch (the quit-time group flush, a topology event
    /// re-resolving the registry) must save the new state, not write the old one back. Stops at
    /// the first store that can't be written; `reached` lists the steps it got to, the failing one
    /// included — what a rollback has to put back.
    private func install(_ archive: SettingsArchive, reached: inout [InstallStep]) async throws {
        clockModeLifecycleSuspended = true
        clockModeTask?.cancel()
        clockModeTask = nil
        groupPersistTask?.cancel()
        groupPersistTask = nil
        // The loops and observers were armed from the old settings; stop them rather than let one
        // act on the new ones in the moment before the relaunch re-arms everything properly. Owed
        // restores stay in their ledgers, which the quit pays as always.
        layoutProtectionRecheck.cancel()
        #if !PUBLIC_API_ONLY
        adaptiveLoop?.cancel()
        adaptiveLoop = nil
        stopAppPresetObserver()  // and its debounce re-check
        groupBrightnessLoop?.cancel()
        groupBrightnessLoop = nil
        #endif
        for step in InstallStep.allCases {
            reached.append(step)
            try await write(step, from: archive)
        }
        await refreshRegistryKnownRecords()
    }

    /// Writes one store of `archive`, memory first. Every disk store is written atomically, so a
    /// write that throws has left that store's file as it was.
    private func write(_ step: InstallStep, from archive: SettingsArchive) async throws {
        switch step {
        case .integrations:
            try integrationSession.install(archive.integrations)
        case .settings:
            settings = archive.settings
            NotificationDelivery.style = settings.notificationStyle
            try settingsStore?.save(settings)
        case .favorites:
            favorites = archive.favorites
            try favoritesStore?.save(favorites)
        case .registry:
            if let registry {
                try await registry.replaceState(archive.registry)
            } else if let directory = try? DiskRegistryStore.defaultDirectory() {
                try await DiskRegistryStore(directory: directory).save(archive.registry)
            }
        case .scenes:
            if let sceneLibrary {
                do {
                    try await sceneLibrary.replaceAll(with: archive.scenes)
                } catch {
                    scenes = await sceneLibrary.all()  // the library's memory moved either way
                    throw error
                }
                scenes = await sceneLibrary.all()
            } else if let directory = try? DiskSceneStore.defaultDirectory() {
                try await DiskSceneStore(directory: directory).save(archive.scenes)
            }
        case .defaults:
            experimentalRotationEnabled = archive.defaults.experimentalRotationEnabled
        case .menuLayout:
            menuLayout = archive.menuLayout
            try menuLayoutStore?.save(menuLayout)
        }
    }

    /// After an install failed part-way: writes `previous` back into every store it reached (the
    /// one that failed too — its memory already holds the incoming state), each independently, so
    /// one store that still can't be written doesn't stop the rest. Returns whether every store is
    /// back. When it is, the app carries on with its previous settings, so the loops and observers
    /// `install` stopped for the relaunch are re-armed.
    private func restore(_ previous: SettingsArchive, afterFailedInstallOf steps: [InstallStep]) async -> Bool {
        var restored = true
        for (index, step) in steps.enumerated().reversed() {
            do { try await write(step, from: previous) } catch {
                // The store that failed the install never changed its file (atomic writes) and
                // `write` puts its memory back before touching the disk, so a second failure there
                // leaves it as it was. Any earlier store did take the incoming state on disk.
                if index != steps.count - 1 { restored = false }
            }
        }
        await refreshRegistryKnownRecords()
        if restored {
            clockModeLifecycleSuspended = false
            clockModeLastRequests.removeAll()
            reconcileClockMode()
            #if !PUBLIC_API_ONLY
            reconcileAdaptiveLoop()
            reconcileAppPresetObserver()
            reconcileGroupBrightnessLoop()
            #endif
        }
        return restored
    }

    /// "0.11.5 (24)" — the version an archive records as its writer.
    private static var archiveAppVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    // MARK: - Global keyboard shortcuts (Batch-2 #4, SO-30)

    /// The shortcuts in force: persisted choices over the shipped defaults, with the older
    /// Reconnect-All switch applied. Registration, Settings and every conflict check read this one.
    var effectiveHotkeyRegistry: KeyboardShortcutRegistry {
        settings.hotkeyShortcuts.effective(reconnectAllEnabled: settings.reconnectAllHotkeyEnabled)
    }

    /// Registers a Carbon global hotkey for every slot the registration plan keeps, mapping each to
    /// its handler, and publishes each action's outcome for Settings. A chord a slot shares with an
    /// earlier one is reported as a conflict and not registered; one macOS refuses is reported as
    /// failed. While a shortcut is being recorded nothing is registered (`hotkeysPaused`).
    private func registerHotkeys() {
        shortcutFeedback.cancel()
        hotKeys.removeAll()  // unregisters the old chords first, or re-registering them would fail
        let registry = effectiveHotkeyRegistry
        let plan = HotkeyRegistrationPlan(registry: registry)
        var failed: Set<HotkeySlot> = []
        if !hotkeysPaused {
            var nextID: UInt32 = 1
            for registration in plan.registrations {
                let handler: () -> Void
                switch registration.slot {
                case .action(let action):
                    handler = hotkeyHandler(for: action)
                case .inputSwitch(let id):
                    guard let entry = registry.inputSwitchBindings.first(where: { $0.id == id }) else { continue }
                    handler = inputSwitchHotkeyHandler(for: entry)
                }
                if let hotkey = GlobalHotKey(keyCode: registration.binding.keyCode,
                                             modifiers: registration.binding.modifiers,
                                             id: nextID,
                                             repeats: { if case .action(let action) = registration.slot {
                                                 return ShortcutActionPolicy.repeats(action)
                                             }; return false }(),
                                             onRelease: { [weak self] in
                                                 if case .action(let action) = registration.slot {
                                                     self?.shortcutReleased(action)
                                                 }
                                             }, action: handler) {
                    hotKeys.append(hotkey)
                } else {
                    failed.insert(registration.slot)
                }
                nextID += 1
            }
        }
        var statuses: [HotkeyAction: HotkeyRegistrationStatus] = [:]
        for action in HotkeyAction.allCases {
            statuses[action] = plan.status(for: action, failed: failed, paused: hotkeysPaused)
        }
        if hotkeyStatus != statuses { hotkeyStatus = statuses }
        var inputStatuses: [String: HotkeyRegistrationStatus] = [:]
        for entry in registry.inputSwitchBindings {
            inputStatuses[entry.id] = plan.status(forInputSwitch: entry.id, failed: failed, paused: hotkeysPaused)
        }
        if inputHotkeyStatus != inputStatuses { inputHotkeyStatus = inputStatuses }
    }

    private func inputSwitchHotkeyHandler(for entry: InputSwitchBinding) -> () -> Void {
        { [weak self] in Task { await self?.switchInputByHotkey(entry) } }
    }

    private func hotkeyHandler(for action: HotkeyAction) -> () -> Void {
        if ShortcutActionPolicy.repeats(action) {
            return { [weak self] in
                guard let self, let adjustment = ShortcutActionPolicy.adjustment(for: action, steps: self.settings.adjustmentSteps) else { return }
                self.performShortcutAdjustment(action, adjustment: adjustment)
            }
        }
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
        case .brightnessUp, .brightnessDown, .brightnessUpFine, .brightnessDownFine,
             .softwareContrastUp, .softwareContrastDown, .softwareContrastUpFine, .softwareContrastDownFine,
             .warmer, .cooler, .volumeUp, .volumeDown, .volumeUpFine, .volumeDownFine:
            return {} // Continuous actions are dispatched by ShortcutActionPolicy above.
        case .faceLight:
            return { [weak self] in
                guard let self, let main = self.displays.first(where: \.isMain) else { return }
                self.toggleFaceLight(for: main)
            }
        case .toggleSoftwareAdjustments, .resetSoftwareAdjustments:
            return { [weak self] in
                guard let self else { return }
                for observation in self.shortcutVideoTargets() {
                    if action == .toggleSoftwareAdjustments {
                        self.setSoftwareAdjustmentsSuspended(!self.softwareAdjustmentsSuspended.contains(observation.recordID), for: observation)
                    } else {
                        Task { await self.resetSoftwareAdjustments(for: observation) }
                    }
                }
            }
        case .toggleMute, .mute, .unmute:
            return { [weak self] in self?.performAudioShortcut(action, delta: nil) }
        case .toggleConsole:
            return { (NSApp.delegate as? AppDelegate)?.toggleCommandConsole() }
        case .restart:
            return { AppLanguage.relaunch(reopeningSettings: false) }
        // SO-38: the app delegate owns the panel and the Settings window.
        case .toggleMenu:
            return { NotificationCenter.default.post(name: .openDisplayToggleMenu, object: nil) }
        case .openSettings:
            return { NotificationCenter.default.post(name: .openDisplayShowSettings, object: nil) }
        case .quit:
            // The ordinary termination path, so `applicationShouldTerminate` still restores what
            // quitting owes (offline displays, gamma, FaceLight) before the process exits.
            return { NSApp.terminate(nil) }
        }
    }

    private func shortcutVideoTargets() -> [DisplayObservation] {
        let ids = shortcutBrightnessDecision(softwareImage: true).targets.map(\.display)
        return ids.compactMap { id in displays.first { $0.recordID == id } }
    }

    private func shortcutBrightnessDecision(softwareImage: Bool = false) -> BrightnessKeyRouter.Decision {
        let mode = settings.mediaKeyTargetMode
        return ShortcutActionPolicy.videoDecision(candidates: brightnessKeyCandidates(softwareImage: softwareImage),
            context: .init(mode: mode, pointer: cursorInCGCoordinates(),
                           focusedDisplay: mode == .focusedWindow ? focusedWindowDisplayID() : nil),
            softwareImage: softwareImage)
    }

    private func performShortcutAdjustment(_ action: HotkeyAction, adjustment: ShortcutActionPolicy.Adjustment) {
        switch adjustment {
        case .brightness(let delta):
            Task { await adjustMainBrightness(fine: action == .brightnessUpFine || action == .brightnessDownFine,
                                              sign: delta < 0 ? -1 : 1) }
        case .contrast(let delta):
            for observation in shortcutVideoTargets() {
                guard !gammaBlockedByCustomProfile(for: observation.recordID) else {
                    statusText = String(localized: "Software image shortcuts are unavailable while this display’s color profile protects gamma.")
                    continue
                }
                setSoftwareContrast(ShortcutActionPolicy.contrast(softwareContrast[observation.recordID], delta: delta), for: observation)
            }
        case .temperature(let delta):
            for observation in shortcutVideoTargets() {
                guard !gammaBlockedByCustomProfile(for: observation.recordID) else {
                    statusText = String(localized: "Software image shortcuts are unavailable while this display’s color profile protects gamma.")
                    continue
                }
                setColorTemperature(ShortcutActionPolicy.temperature(colorTemperature[observation.recordID], delta: delta), for: observation)
            }
        case .volume(let delta): performAudioShortcut(action, delta: delta)
        }
    }

    private func performAudioShortcut(_ action: HotkeyAction, delta: Float?) {
        let snapshot = audioOutputs.snapshot()
        audioSnapshot = snapshot
        let mediaAction: MediaKeyAction = delta.map { $0 < 0 ? .volumeDown : .volumeUp } ?? .muteToggle
        let target = settings.nativeKeys.audioTarget
        let decision = ShortcutActionPolicy.audioDecision(mediaAction, preferences: settings.nativeKeys,
            candidates: audioKeyCandidates(devices: snapshot.devices), currentOutput: snapshot.currentOutput,
            pointer: cursorInCGCoordinates(),
            focusedDisplay: target == .focusedWindow ? focusedWindowDisplayID() : nil)
        var handled = false
        var unavailable = decision.recipients.isEmpty
        for recipient in decision.recipients {
            let device: AudioOutputDevice
            let observation: DisplayObservation?
            switch recipient {
            case .hardware: unavailable = true; continue
            case .native(let id, let output):
                device = output
                observation = displays.first { $0.recordID == id }
            case .currentOutput(let output): device = output; observation = nil
            }
            let outcome: NativeAudioAdjustment.Outcome
            if let delta {
                outcome = NativeAudioAdjustment.apply(mediaAction, uid: device.uid, delta: delta, controller: audioOutputs)
            } else if action == .toggleMute {
                outcome = NativeAudioAdjustment.apply(.muteToggle, uid: device.uid, delta: 0, controller: audioOutputs)
            } else {
                outcome = NativeAudioAdjustment.setMuted(action == .mute, uid: device.uid, controller: audioOutputs)
            }
            handled = outcome.handled || handled
            if case .accepted(let after?) = outcome {
                reportNativeAudio(after, for: observation, source: .hotkey, showsOSD: true)
            } else { unavailable = true }
        }
        refreshAudioOutputs()
        if unavailable {
            statusText = String(localized: "A shortcut audio target is unavailable. CoreAudio shortcuts require a writable native output; they do not use DDC or toggle-only mute.")
        }
        if delta != nil {
            let plays = VolumeFeedbackPolicy.plays(settings.nativeKeys.volumeFeedbackSound,
                systemPreference: VolumeFeedbackSoundPlayer.systemPreference, inverted: false)
            if handled, plays, case .adjust(_, let uid) = decision {
                shortcutFeedback.pressHandled(action, request: .init(outputUID: uid))
            } else { shortcutFeedback.pressHandled(action, request: nil) }
        }
    }

    private func shortcutReleased(_ action: HotkeyAction) {
        if let feedback = shortcutFeedback.released(action) {
            VolumeFeedbackSoundPlayer.play(on: feedback.outputUID)
        }
    }

    /// Whether each action's shortcut is live (SO-30), as of the last registration.
    @Published private(set) var hotkeyStatus: [HotkeyAction: HotkeyRegistrationStatus] = [:]
    /// The same for each input-switch hotkey, keyed by its id.
    @Published private(set) var inputHotkeyStatus: [String: HotkeyRegistrationStatus] = [:]
    /// True while Settings records a shortcut: every chord is unregistered so the keys being typed
    /// reach the recorder instead of firing actions (an app's own Carbon hotkey would swallow them).
    @Published private(set) var hotkeysPaused = false

    /// Sets an action's chord — or, with nil, leaves it explicitly without one (SO-01) — then saves
    /// and re-registers. Choosing a Reconnect-All chord also turns the older on/off switch back on:
    /// picking a chord is asking for it to work.
    func setHotkeyBinding(_ binding: KeyBinding?, for action: HotkeyAction) {
        // Owner decision #26: the recorder refuses the recovery chord with a message; this keeps any
        // other path from saving it anyway.
        if let binding, effectiveHotkeyRegistry.isReservedForRecovery(binding, slot: .action(action)) { return }
        var registry = settings.hotkeyShortcuts
        registry.setBinding(binding, for: action)
        settings.hotkeyShortcuts = registry
        if action == .reconnectAll, binding != nil { settings.reconnectAllHotkeyEnabled = true }
        persistSettings()
        registerHotkeys()
    }

    /// Puts one action back on its shipped chord (or none, for actions without one).
    func restoreDefaultHotkey(for action: HotkeyAction) {
        var registry = settings.hotkeyShortcuts
        registry.restoreDefault(for: action)
        settings.hotkeyShortcuts = registry
        if action == .reconnectAll { settings.reconnectAllHotkeyEnabled = true }
        persistSettings()
        registerHotkeys()
    }

    /// Every fixed action back on its shipped chord; input hotkeys are the user's own and stay.
    func restoreDefaultHotkeys() {
        settings.hotkeyShortcuts = settings.hotkeyShortcuts.restoringDefaults()
        settings.reconnectAllHotkeyEnabled = true
        persistSettings()
        registerHotkeys()
    }

    /// The slot already using `binding`, other than `action` itself — Settings refuses to save a
    /// chord twice rather than leave one of the two silently dead.
    func hotkeySlot(using binding: KeyBinding, excluding action: HotkeyAction) -> HotkeySlot? {
        effectiveHotkeyRegistry.slot(using: binding, excluding: .action(action))
    }

    /// Why the recorder won't save `binding` for `action`, or nil when it may: the reserved
    /// recovery chord (owner decision #26), or a chord another shortcut already uses.
    func hotkeyRefusal(for binding: KeyBinding, action: HotkeyAction) -> String? {
        let chord = KeyBindingFormatter.string(for: binding)
        if effectiveHotkeyRegistry.isReservedForRecovery(binding, slot: .action(action)) {
            return String(localized: "\(chord) is reserved for Reconnect All Displays, the recovery shortcut that works when the screens can’t be used. To use these keys for something else, remove the Reconnect All Displays shortcut first.")
        }
        if let holder = hotkeySlot(using: binding, excluding: action) {
            return String(localized: "\(chord) is already used by \(hotkeySlotName(holder)).")
        }
        return nil
    }

    /// The display name Settings uses for a slot that holds a chord.
    func hotkeySlotName(_ slot: HotkeySlot) -> String {
        switch slot {
        case .action(let action):
            return action.localizedTitle
        case .inputSwitch(let id):
            guard let entry = settings.hotkeyShortcuts.inputSwitchBindings.first(where: { $0.id == id }) else {
                return String(localized: "an input hotkey")
            }
            return String(localized: "the input hotkey for \(rememberedDisplayName(for: entry.displayID))")
        }
    }

    /// Unregisters every chord while a shortcut is recorded (SO-30). Idempotent.
    func pauseHotkeys() {
        guard !hotkeysPaused else { return }
        hotkeysPaused = true
        releaseFeedback.cancel()
        shortcutFeedback.cancel()
        registerHotkeys()
    }

    /// Registers the chords again once recording ends. Idempotent.
    func resumeHotkeys() {
        guard hotkeysPaused else { return }
        hotkeysPaused = false
        registerHotkeys()
    }

    /// Saves new adjustment steps (SO-29); the next key press or shortcut uses them.
    func setAdjustmentSteps(_ steps: AdjustmentSteps) {
        guard settings.adjustmentSteps != steps else { return }
        settings.adjustmentSteps = steps
        persistSettings()
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
        // Checked against what `registerHotkeys` actually registers: defaults filled in, cleared
        // shortcuts left out (SO-01) — not the raw persisted map, which may lack either.
        let registry = effectiveHotkeyRegistry
        return registry.inputSwitchBindingConflicts(combo, excludingInputSwitchID: excludingInputSwitchID)
            || registry.isReservedForRecovery(combo, slot: .inputSwitch(id: excludingInputSwitchID ?? ""))
    }

    /// Makes the next active display the main display (wraps around).
    func cycleMainDisplay() async {
        let actives = displays.filter(\.isActive)
        guard actives.count > 1 else { return }
        let idx = actives.firstIndex(where: { $0.isMain }) ?? 0
        await setMain(for: actives[(idx + 1) % actives.count])
    }

    /// Nudges the brightness-key targets one standard or fine step (SO-29: the steps the native keys
    /// use), clamped to 0...1. `sign` is +1 to brighten, -1 to dim. The custom shortcuts choose
    /// their displays exactly as a plain brightness key does (SO-27), but never hand the press to
    /// macOS: a recorded shortcut is OpenDisplay's own.
    func adjustMainBrightness(fine: Bool, sign: Float) async {
        let decision = shortcutBrightnessDecision()
        let delta = sign * settings.adjustmentSteps.fraction(fine: fine)
        for target in decision.targets {
            guard let observation = displays.first(where: { $0.recordID == target.display }) else { continue }
            if brightnessMethod[target.display] == nil { await refreshBrightness(for: observation) }
            let current = brightness[target.display] ?? 0.5
            setBrightness(max(0, min(1, current + delta)), for: observation, origin: .keys, eventSource: .hotkey,
                          syncBypass: target.bypassesSync)
        }
    }

    // MARK: - OSD HUD + media keys (Batch-3)

    /// Reports one brightness/volume change to its two independent audiences (Batch-3 #4/#6,
    /// IN-04): OpenDisplay's own HUD, only when `showsLocalHUD` and the HUD settings allow, and —
    /// when broadcasting is on — the external event for every change, whether or not anything was
    /// drawn here. The single funnel `setBrightness` / `setHardwareControl(.volume)` call.
    ///
    /// `assurance` says how far the level is known to be true (TR-17) and `control` what carried it;
    /// both travel with the event. The feedback switches, the per-display volume switch and an open
    /// menu only decide the local HUD (SO-35) — the event goes out whatever they say.
    func presentOSD(kind: OSDContent.Kind, value: Float, for observation: DisplayObservation,
                    source: OSDBroadcast.Source, showsLocalHUD: Bool = true,
                    assurance: OSDContent.Assurance = .requested, control: String? = nil) {
        let content = OSDContent(kind: kind, value: value, assurance: assurance)
        let verificationTarget: Int?
        #if !PUBLIC_API_ONLY
        switch kind {
        case .brightness: verificationTarget = control == "ddc" ? ddcTarget[observation.recordID] : nil
        case .volume: verificationTarget = control == "ddc"
            ? ddcControlTarget[DDCControlKey(id: observation.recordID, vcp: HardwareControl.volume.vcp)] : nil
        case .mute, .input: verificationTarget = nil
        }
        #else
        verificationTarget = nil
        #endif
        deliverOSD(content, for: observation, affected: observation.cgDisplayID, source: source,
                   showsLocalHUD: showsLocalHUD, control: control, verificationTarget: verificationTarget,
                   adjustable: osdAdjustable(kind, observation))
    }

    /// Native fallback audio has no display identity: it shares local feedback policy and placement,
    /// but must not publish a display event or offer a bar that adjusts an unrelated monitor.
    private func deliverOSD(_ content: OSDContent, for observation: DisplayObservation?,
                            affected: CGDirectDisplayID?, source: OSDBroadcast.Source,
                            showsLocalHUD: Bool, control: String?, verificationTarget: Int? = nil,
                            adjustable: Bool = false) {
        let route = OSDFeedbackPolicy.route(
            .init(kind: content.kind, displayID: observation?.recordID.rawValue, localHUDWanted: showsLocalHUD,
                  menuOpen: osdHUD.environment().menuOpen), settings: settings)
        if route.drawsLocalHUD {
            osdHUD.present(content, display: observation?.recordID,
                           affected: affected, appearance: osdAppearance,
                           verificationTarget: verificationTarget, adjustable: adjustable)
        } else if source == .osd, let observation {
            osdHUD.noteAdjustment(content, display: observation.recordID, verificationTarget: verificationTarget)
        }
        if route.publishesEvent, let observation {
            publishOSDEvent(content, for: observation, source: source, control: control)
        }
    }

    /// Posts one change's event, with the screen OpenDisplay would draw feedback on as a hint.
    private func publishOSDEvent(_ content: OSDContent, for observation: DisplayObservation,
                                 source: OSDBroadcast.Source, control: String?) {
        OSDBroadcaster.publish(content, displayID: observation.recordID.rawValue,
                               displayName: displayName(for: observation), source: source.rawValue,
                               screenID: osdHUD.screenID(for: osdAppearance, affected: observation.cgDisplayID),
                               control: control)
    }

    /// The OSD settings as the HUD reads them.
    private var osdAppearance: OSDHUDAppearance {
        let feedback = settings.osdFeedback
        return OSDHUDAppearance(style: settings.osdStyle, position: settings.osdPosition, screen: feedback.screen,
                                showsValue: feedback.showsValue, segmentedBar: feedback.segmentedBar,
                                rounded: feedback.rounded, adaptiveBackground: feedback.adaptiveBackground,
                                shadow: feedback.shadow,
                                interactive: feedback.interactive,
                                volumeCompletionSound: feedback.volumeCompletionSound,
                                step: settings.adjustmentSteps.fraction(fine: false))
    }

    /// The HUD uses the same volume sink as the display's slider, including native audio bindings.
    private func osdAdjustable(_ kind: OSDContent.Kind, _ observation: DisplayObservation) -> Bool {
        switch kind {
        case .brightness: return true
        case .volume: return displayVolumeAdjustable(for: observation)
        case .mute, .input: return false
        }
    }

    /// The interactive HUD's bar (SO-35): the menu sliders' funnels, so groups, routes and events
    /// behave exactly as for a slider. Shift is the one-operation bypass of group sync.
    private func adjustFromOSD(_ id: DisplayRecordID, kind: OSDContent.Kind, level: Float, bypassSync: Bool) {
        guard let observation = displays.first(where: { $0.recordID == id && $0.isActive }),
              osdAdjustable(kind, observation) else { return }
        switch kind {
        case .brightness:
            setBrightness(level, for: observation, origin: .slider, eventSource: .osd, syncBypass: bypassSync)
        case .volume:
            setDisplayVolume(level, for: observation, eventSource: .osd)
        case .mute, .input:
            break
        }
    }

    /// TR-17: software dimming is OpenDisplay's own doing; a native or DDC write is a request.
    private static func osdAssurance(_ method: BrightnessMethod) -> OSDContent.Assurance {
        method == .software ? .applied : .requested
    }

    /// The `control` an event names for a brightness route.
    private static func osdControl(_ method: BrightnessMethod) -> String {
        switch method {
        case .native: return "native"
        case .hardware: return "ddc"
        case .software: return "software"
        }
    }

    /// Where the menu is and whether it is open, for the HUD (SO-35). Set by the app delegate.
    func setOSDEnvironment(_ provider: @escaping @MainActor () -> OSDHUDEnvironment) {
        osdHUD.environment = provider
    }

    /// Confirms a hotkey-driven input switch (todo 4) — the same on-screen confirmation
    /// brightness/volume changes get, so a KVM-style input jump is never silent. Custom feedback,
    /// with its own switch (SO-35), and published as an `input` event with the input's name
    /// (IN-16/T30): sent, not confirmed — nothing reads the input back.
    private func presentInputSwitchOSD(inputName: String, for observation: DisplayObservation) {
        let content = OSDContent(kind: .input, value: 0, label: inputName, assurance: .requested)
        let route = OSDFeedbackPolicy.route(
            .init(kind: .input, displayID: observation.recordID.rawValue, localHUDWanted: true,
                  menuOpen: osdHUD.environment().menuOpen), settings: settings)
        if route.drawsLocalHUD {
            osdHUD.present(content, display: nil, affected: observation.cgDisplayID, appearance: osdAppearance)
        }
        if route.publishesEvent { publishOSDEvent(content, for: observation, source: .hotkey, control: "ddc") }
    }

    /// Handle a captured native key event (Batch-3 #1/#3, SO-25–SO-28, FA-19, FA-20). Resolves the
    /// chord, then the displays through the pure `BrightnessKeyRouter` / `AudioKeyRouter`, applies
    /// the change through the existing brightness/volume sinks (which raise the OSD), and returns
    /// whether it acted — so the tap swallows handled keys and lets every other one reach macOS.
    /// A release arrives only for a press that was taken; it plays the owed volume feedback.
    @discardableResult
    func handleNativeKey(_ event: NativeKeyEvent) -> Bool {
        // The recorder must see F14/F15 before the native brightness mapping can consume them.
        guard !hotkeysPaused else { return false }
        let keys = settings.nativeKeys
        guard event.isDown else {
            if event.action == .volumeUp || event.action == .volumeDown,
               let request = releaseFeedback.released(event.action) {
                VolumeFeedbackSoundPlayer.play(on: request.outputUID)
            }
            return true
        }
        if event.action.isBrightness {
            guard keys.brightnessKeysEnabled else { return false }
            if let keyCode = event.functionKeyCode {
                let registry = effectiveHotkeyRegistry
                guard AlternativeBrightnessKey.isMapped(
                    keyCode: keyCode, carbonModifiers: event.carbonModifiers, enabled: keys.alternativeBrightnessKeys,
                    shortcutInUse: { registry.slot(using: $0) != nil }) else { return false }
            }
        } else {
            guard keys.volumeKeysEnabled else { return false }
        }
        if let auxiliary = NativeKeyChordPolicy.auxiliaryAction(
            for: event.action, modifiers: event.modifiers,
            brightnessRequiresShift: settings.brightnessMediaKeysRequireShift) {
            guard !event.isRepeat else { return true }
            switch auxiliary {
            case .displaysSettings, .soundSettings:
                let pane = auxiliary == .displaysSettings ? "com.apple.preference.displays" : "com.apple.preference.sound"
                guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return false }
                return NSWorkspace.shared.open(url)
            case .startMirroring, .stopMirroring:
                let ids = NativeKeyChordPolicy.mirrorTargets(for: auxiliary, in: displays)
                let targets = ids.compactMap { id in displays.first { $0.recordID == id } }
                let starting = auxiliary == .startMirroring
                let source = starting ? displays.first(where: \.isMain) : nil
                guard !starting || source != nil,
                      let plan = MirroringChangePlan(targets: targets, source: source) else { return false }
                Task { [weak self] in await self?.applyMirroringChange(plan) }
                return true
            }
        }
        guard let intent = NativeKeyChordPolicy.intent(
            for: event.action, modifiers: event.modifiers,
            brightnessRequiresShift: settings.brightnessMediaKeysRequireShift) else { return false }
        return event.action.isBrightness
            ? handleBrightnessKey(event.action, intent: intent)
            : handleAudioKey(event.action, intent: intent)
    }

    private func handleBrightnessKey(_ action: MediaKeyAction, intent: NativeKeyIntent) -> Bool {
        let candidates = brightnessKeyCandidates()
        let decision = brightnessKeyDecision(intent: intent, takeover: settings.nativeKeys.brightnessTakeover)
        guard case .adjust(let targets) = decision else { return false }
        let eligible = BrightnessKeyRouter.syncEligibleDisplays(candidates)
        let delta = action.sign * settings.nativeKeys.stepFraction(for: action, modifierRequestsFine: intent.modifierRequestsFine,
                                                              steps: settings.adjustmentSteps)
        for target in targets {
            guard let observation = displays.first(where: { $0.recordID == target.display }) else { continue }
            let current = brightness[target.display] ?? 0.5
            setBrightness(min(1, max(0, current + delta)), for: observation, origin: .keys, eventSource: .mediaKey,
                          syncBypass: target.bypassesSync, keyboardEligible: eligible)
        }
        return true
    }

    /// The displays a brightness press would change right now.
    private func brightnessKeyDecision(intent: NativeKeyIntent,
                                       takeover: BrightnessKeyTakeover) -> BrightnessKeyRouter.Decision {
        let mode = settings.mediaKeyTargetMode
        return BrightnessKeyRouter.decide(
            intent: intent, candidates: brightnessKeyCandidates(),
            context: .init(mode: mode, takeover: takeover, pointer: cursorInCGCoordinates(),
                           focusedDisplay: mode == .focusedWindow ? focusedWindowDisplayID() : nil))
    }

    /// What the brightness keys may do with each display: its keyboard preference, whether a
    /// route shows on it, whether macOS adjusts it natively, and the sync group carrying its changes.
    private func brightnessKeyCandidates(softwareImage: Bool = false) -> [BrightnessKeyRouter.Candidate] {
        displays.map { observation in
            let id = observation.recordID
            #if PUBLIC_API_ONLY
            let method = BrightnessMethod.software
            let macOSControllable = observation.displayClass == .builtIn
            #else
            let method = settings.softwareBrightnessDisplayIDs.contains(id.rawValue)
                ? BrightnessMethod.software
                : brightnessMethod[id] ?? (observation.displayClass == .builtIn ? .native : .hardware)
            let macOSControllable = method == .native
            #endif
            // A mirror member shows its source's picture: an overlay window drawn for it is never seen.
            let invisible = observation.mirrorSourceID != nil && method == .software && effectiveDimmingMethod(for: id) == .overlay
            // Safe startup (FA-09) syncs no group, so every display must then be written itself.
            let group = safeStartup ? nil
                : brightnessSyncGroup(containing: id).flatMap { $0.syncBrightness ? $0.id : nil }
            return BrightnessKeyRouter.Candidate(
                observation: observation,
                keyboardEnabled: keyboardAudioPreferences(for: id).keyboardControl,
                controllable: observation.cgDisplayID != nil && (softwareImage || !invisible),
                macOSControllable: macOSControllable, syncGroup: group)
        }
    }

    private func handleAudioKey(_ action: MediaKeyAction, intent: NativeKeyIntent) -> Bool {
        // CoreAudio is read at the press: an output switch a moment ago must count.
        let snapshot = audioOutputs.snapshot()
        if audioSnapshot != snapshot { audioSnapshot = snapshot }
        let candidates = audioKeyCandidates(devices: snapshot.devices)
        let decision = audioKeyDecision(action, intent: intent, candidates: candidates, snapshot: snapshot)
        guard case .adjust(let recipients, let feedbackOutputUID) = decision else {
            // A display the output belongs to whose DDC audio isn't confirmed: macOS handles this
            // key, and a background read establishes whether the next one can be taken (TB-02).
            let targets = DisplayAudioInitialRead.keyPressTargets(action: action, candidates: candidates,
                currentOutput: snapshot.currentOutput, confirmedVolume: confirmedAudioVolume,
                captureEnabled: settings.mediaKeyInterceptionEnabled && settings.nativeKeys.volumeKeysEnabled,
                safeStartup: safeStartup, muteLeftToMacOS: settings.nativeKeys.muteKeyLeftToMacOS)
            for id in targets { probeAudioControls(for: id) }
            return false
        }
        let delta = action.sign * settings.nativeKeys.stepFraction(for: action, modifierRequestsFine: intent.modifierRequestsFine,
                                                              steps: settings.adjustmentSteps)
        var handled = false
        for recipient in recipients {
            switch recipient {
            case .hardware(let id):
                guard let observation = displays.first(where: { $0.recordID == id }) else { continue }
                let showsOSD = keyboardAudioPreferences(for: id).showsVolumeOSD
                if action == .muteToggle {
                    handled = toggleMute(for: observation, eventSource: .mediaKey, showsOSD: showsOSD) || handled
                } else if let current = ddcControl(.volume, for: observation) {
                    // Eligibility guarantees a read-back level; nothing is invented here.
                    setHardwareControl(.volume, min(1, max(0, current + delta)), for: observation,
                                       showsOSD: showsOSD, eventSource: .mediaKey)
                    handled = true
                }
            case .native(let id, let device):
                let observation = displays.first { $0.recordID == id }
                handled = applyNativeAudio(action, to: device, delta: delta, feedbackDisplay: observation,
                                           showsOSD: keyboardAudioPreferences(for: id).showsVolumeOSD) || handled
            case .currentOutput(let device):
                handled = applyNativeAudio(action, to: device, delta: delta, feedbackDisplay: nil, showsOSD: true) || handled
            }
        }
        if handled, action != .muteToggle {
            let plays = VolumeFeedbackPolicy.plays(settings.nativeKeys.volumeFeedbackSound,
                                                   systemPreference: VolumeFeedbackSoundPlayer.systemPreference,
                                                   inverted: intent.invertsFeedbackSound)
            releaseFeedback.pressHandled(action, request: plays ? .init(outputUID: feedbackOutputUID) : nil)
        }
        return handled
    }

    private func audioKeyDecision(_ action: MediaKeyAction, intent: NativeKeyIntent,
                                  candidates: [AudioKeyCandidate], snapshot: AudioOutputSnapshot) -> AudioKeyRouter.Decision {
        let target = settings.nativeKeys.audioTarget
        return AudioKeyRouter.decide(
            action, intent: intent, candidates: candidates,
            context: .init(settings.nativeKeys, currentOutput: snapshot.currentOutput,
                           pointer: cursorInCGCoordinates(),
                           focusedDisplay: target == .focusedWindow ? focusedWindowDisplayID() : nil))
    }

    /// Every display as the volume keys see it, against the outputs in `devices`.
    private func audioKeyCandidates(devices: [AudioOutputDevice]) -> [AudioKeyCandidate] {
        displays.map { observation in
            let preferences = keyboardAudioPreferences(for: observation.recordID)
            let matchOverride = observation.displayClass == .builtIn ? AudioDeviceResolution.unset
                : AudioDeviceSelector.resolve(preferences.audioMatch, in: devices, strictness: .allowsFragment)
            return AudioKeyCandidate(observation: observation, productName: osDisplayName(for: observation),
                                     keyboardEnabled: preferences.keyboardControl,
                                     sink: audioSink(for: observation, preferences: preferences, devices: devices),
                                     matchOverride: matchOverride)
        }
    }

    /// Where a display's volume and mute go (SD-16): its bound macOS output when native association
    /// is on — and nowhere when that binding names no single present output — otherwise the
    /// monitor's own DDC audio, with what has been confirmed of it. The built-in display has neither:
    /// its speakers are macOS's.
    private func audioSink(for observation: DisplayObservation, preferences: DisplayKeyboardAudioPreferences,
                           devices: [AudioOutputDevice]) -> DisplayAudioSink {
        let capability = audioCapability(for: observation)
        return DisplayAudioSink.resolve(observation: observation, record: records[observation.recordID],
            preferences: preferences, devices: devices,
            hardwareVolume: DDCAudioPolicy.volumeKeysUsable(capability),
            hardwareMute: DDCAudioPolicy.muteKeyUsable(capability, remembered: preMuteVolume[observation.recordID]))
    }

    /// Steps or toggles a macOS output through CoreAudio, then reports what the output reads back —
    /// not the request — on the display it belongs to, or (the native fallback, which belongs to no
    /// display) as a local HUD under the pointer without a display event.
    @discardableResult
    private func applyNativeAudio(_ action: MediaKeyAction, to device: AudioOutputDevice, delta: Float,
                                  feedbackDisplay: DisplayObservation?, showsOSD: Bool) -> Bool {
        let outcome = NativeAudioAdjustment.apply(action, uid: device.uid, delta: delta, controller: audioOutputs)
        refreshAudioOutputs()
        if case .failed = outcome {
            statusText = String(localized: "FreeDisplay couldn’t change the sound output. Check its volume and mute controls in Sound settings.")
        }
        guard case .accepted(let after?) = outcome else { return outcome.handled }
        reportNativeAudio(after, for: feedbackDisplay, source: .mediaKey, showsOSD: showsOSD)
        return true
    }

    private func reportNativeAudio(_ after: AudioOutputDevice, for observation: DisplayObservation?,
                                   source: OSDBroadcast.Source, showsOSD: Bool) {
        guard let content = NativeAudioAdjustment.feedback(after) else { return }
        if let observation {
            presentOSD(kind: content.kind, value: content.value, for: observation, source: source,
                       showsLocalHUD: showsOSD, assurance: content.assurance, control: "nativeAudio")
        } else {
            let place = cursorInCGCoordinates().flatMap { PointerScreen.display(at: $0, in: displays) }
                ?? displays.first(where: { $0.isActive && $0.isMain })
            deliverOSD(content, for: nil, affected: place?.cgDisplayID, source: source,
                       showsLocalHUD: showsOSD, control: "nativeAudio")
        }
    }

    /// Accessibility supplies the actual focused window, including dialogs; frontmost window-list
    /// order is not focus and could silently select an unrelated display.
    private func focusedWindowDisplayID() -> DisplayRecordID? {
        guard MediaKeyTap.isAccessibilityTrusted,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let application = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(window, to: AXUIElement.self)
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return FocusedWindowScreen.display(
            for: .init(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height), in: displays)
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
    func toggleMute(for observation: DisplayObservation, eventSource: OSDBroadcast.Source = .menu,
                    showsOSD: Bool = true) -> Bool {
        let id = observation.recordID
        switch muteAction(for: observation) {
        case .discrete(let mute):
            setDiscreteMute(mute, for: observation)
            // The monitor's own mute changes no level, so it had no feedback at all (SO-35): mute
            // shows as muted, unmute as the volume it returns to — both requested, not confirmed.
            presentOSD(kind: mute ? .mute : .volume, value: mute ? 0 : ddcControl(.volume, for: observation) ?? 0,
                       for: observation, source: eventSource, showsLocalHUD: showsOSD, control: "ddc")
        case .zeroVolume(let level):
            preMuteVolume[id] = level
            setHardwareControl(.volume, 0, for: observation, showsOSD: showsOSD, eventSource: eventSource)
        case .restore(let level):
            // clears `preMuteVolume`
            setHardwareControl(.volume, level, for: observation, showsOSD: showsOSD, eventSource: eventSource)
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

    /// Confirms the DDC volume of every monitor the volume keys could take, as soon as that can
    /// matter — at launch, when a display connects, and when volume-key capture is switched on —
    /// so the first press already finds a confirmed control instead of going to macOS while a
    /// background read catches up (owner decision #6). Reuses the per-key probe: one at a time per
    /// display, through the probe tracker, never for a display OpenDisplay refuses DDC to. Not in a
    /// safe startup (FA-09), which starts no DDC traffic of its own accord.
    private func confirmDisplayAudioForKeys() async {
        #if !PUBLIC_API_ONLY
        let candidates = audioKeyCandidates(devices: audioSnapshot.devices)
        let confirmed = confirmedAudioVolume
        let targets = DisplayAudioInitialRead.targets(
            candidates: candidates, confirmedVolume: confirmed,
            captureEnabled: settings.mediaKeyInterceptionEnabled && settings.nativeKeys.volumeKeysEnabled,
            safeStartup: safeStartup)
        for id in targets { await probeAudioControls(for: id)?.value }
        #endif
    }

    private var confirmedAudioVolume: Set<DisplayRecordID> {
        Set(displays.filter { ddcControl(.volume, for: $0) != nil }.map(\.recordID))
    }

    private func canProbeAudioControls(for id: DisplayRecordID) -> Bool {
        DisplayAudioInitialRead.targets(candidates: audioKeyCandidates(devices: audioSnapshot.devices),
            confirmedVolume: confirmedAudioVolume,
            captureEnabled: settings.mediaKeyInterceptionEnabled && settings.nativeKeys.volumeKeysEnabled,
            safeStartup: safeStartup).contains(id)
    }

    /// Starts a background read of a display's volume and mute when a key arrived for it before
    /// they were confirmed. Goes through the probe tracker, so a monitor without DDC audio is not
    /// re-read on every key press, and skips displays OpenDisplay refuses to talk DDC to.
    @discardableResult
    private func probeAudioControls(for id: DisplayRecordID) -> Task<Void, Never>? {
        #if !PUBLIC_API_ONLY
        guard canProbeAudioControls(for: id) else { return nil }
        if let probe = audioProbes[id] { return probe.task }
        guard ddcBindingRefusal[id] == nil,
              ddcProbe[id]?.unsupportedCodes.contains(HardwareControl.volume.vcp) != true,
              let observation = displays.first(where: {
                  $0.recordID == id && $0.isActive && $0.displayClass != .builtIn
              }) else { return nil }
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            if !Task.isCancelled, self.canProbeAudioControls(for: id),
               let controller = await self.ddcController(for: observation),
               !Task.isCancelled, self.canProbeAudioControls(for: id) {
                await self.readHardwareControl(.volume, controller: controller, observation: observation)
                if !Task.isCancelled, !self.safeStartup, self.canPersistDisplaySettings(id),
                   !self.keyboardAudioPreferences(for: id).nativeAudioEnabled {
                    await self.refreshDiscreteMute(controller, observation: observation)
                }
            }
            if self.audioProbes[id]?.token == token { self.audioProbes[id] = nil }
        }
        audioProbes[id] = (token, task)
        return task
        #else
        return nil
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
                guard ddcBindingIsCurrent(controller, for: id) else { return }
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
    ///
    /// The tap exists only while some key is captured (SO-25): with both brightness and volume
    /// capture off the feature needs no permission and nothing is prompted. Ordinary key events are
    /// watched only while F14/F15 are mapped.
    private func reconcileMediaKeyTap() {
        if NativeKeyListening.needsCapture(featureEnabled: settings.mediaKeyInterceptionEnabled,
                                           preferences: settings.nativeKeys) {
            let wantsFunctionKeys = settings.nativeKeys.brightnessKeysEnabled
                && settings.nativeKeys.alternativeBrightnessKeys
            if let mediaKeyTap {
                mediaKeyTap.brightnessWanted = settings.nativeKeys.brightnessKeysEnabled
                mediaKeyTap.volumeWanted = settings.nativeKeys.volumeKeysEnabled
                mediaKeyTap.functionKeysWanted = wantsFunctionKeys
                if !mediaKeyTap.isActive { armMediaKeyTapWhenTrusted(mediaKeyTap) }
                return
            }
            let tap = MediaKeyTap { [weak self] event in self?.handleNativeKey(event) ?? false }
            tap.brightnessWanted = settings.nativeKeys.brightnessKeysEnabled
            tap.volumeWanted = settings.nativeKeys.volumeKeysEnabled
            tap.functionKeysWanted = wantsFunctionKeys
            tap.onCancel = { [weak self] in self?.releaseFeedback.cancel() }
            mediaKeyTap = tap
            if !tap.start() {
                if !promptedForAccessibility {
                    promptedForAccessibility = true
                    MediaKeyTap.promptForAccessibility()
                }
            }
            armMediaKeyTapWhenTrusted(tap)
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
                guard let self, NativeKeyListening.needsCapture(
                    featureEnabled: self.settings.mediaKeyInterceptionEnabled,
                    preferences: self.settings.nativeKeys) else { return }
                if MediaKeyTap.isAccessibilityTrusted {
                    _ = tap.start()
                } else {
                    tap.stop()
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

    // MARK: - Display audio and keyboard preferences (SD-11, SD-16, TB-08, TR-16)

    func setShowsVolumeFeedback(_ show: Bool, for id: DisplayRecordID) {
        guard canPersistDisplaySettings(id) else { return }
        settings.setShowsVolumeFeedback(show, for: id)
        persistSettings()
    }

    /// Where this display's volume and mute go right now, against the outputs last read.
    func audioSink(for observation: DisplayObservation) -> DisplayAudioSink {
        audioSink(for: observation, preferences: keyboardAudioPreferences(for: observation.recordID),
                  devices: audioSnapshot.devices)
    }

    /// What the display's native-association text names among the present outputs.
    func nativeAudioResolution(for observation: DisplayObservation) -> AudioDeviceResolution {
        AudioDeviceSelector.resolve(keyboardAudioPreferences(for: observation.recordID).nativeAudioDevice,
                                    in: audioSnapshot.devices, strictness: .exact)
    }

    /// What the display's volume-key matching text names among the present outputs.
    func audioMatchResolution(for observation: DisplayObservation) -> AudioDeviceResolution {
        AudioDeviceSelector.resolve(keyboardAudioPreferences(for: observation.recordID).audioMatch,
                                    in: audioSnapshot.devices, strictness: .allowsFragment)
    }

    /// Re-reads CoreAudio for Settings (the listeners keep it current afterwards).
    func refreshAudioOutputs() {
        let snapshot = audioOutputs.snapshot()
        if audioSnapshot != snapshot { audioSnapshot = snapshot }
    }

    /// The display's volume level for its slider: the bound output's when native association is on,
    /// else the monitor's DDC volume. Nil = no level to show.
    func displayVolumeLevel(for observation: DisplayObservation) -> Float? {
        switch audioSink(for: observation) {
        case .native(let device): return device.volume == .absent ? nil : device.volumeLevel
        case .unresolvedNative, .none: return nil
        case .hardware: return ddcControl(.volume, for: observation)
        }
    }

    /// Whether the display's audio is muted as far as is known.
    func displayIsMuted(for observation: DisplayObservation) -> Bool {
        switch audioSink(for: observation) {
        case .native(let device): return device.isMuted == true
        case .unresolvedNative, .none: return false
        case .hardware:
            return ddcAudioMuted[observation.recordID] == true || (ddcControl(.volume, for: observation) ?? 1) <= 0
        }
    }

    /// Whether a mute toggle has something truthful to do on this display.
    func displayMuteAvailable(for observation: DisplayObservation) -> Bool {
        switch audioSink(for: observation) {
        case .native(let device): return device.muteIsToggleable
        case .unresolvedNative, .none: return false
        case .hardware: return muteAction(for: observation) != .unavailable
        }
    }

    /// Whether the display's volume slider can be moved.
    func displayVolumeAdjustable(for observation: DisplayObservation) -> Bool {
        switch audioSink(for: observation) {
        case .native(let device): return device.volume.isSettable
        case .unresolvedNative, .none: return false
        case .hardware: return ddcControl(.volume, for: observation) != nil
        }
    }

    /// Slider/menu volume for a display, through its own route. A bound output is unmuted when
    /// raised above its minimum, as macOS's own slider does.
    func setDisplayVolume(_ value: Float, for observation: DisplayObservation,
                          eventSource: OSDBroadcast.Source = .menu) {
        switch audioSink(for: observation) {
        case .native(let device):
            let outcome = NativeAudioAdjustment.setLevel(value, uid: device.uid, controller: audioOutputs)
            refreshAudioOutputs()
            if case .failed = outcome {
                statusText = String(localized: "FreeDisplay couldn’t change the sound output. Check its volume and mute controls in Sound settings.")
            }
            if case .accepted(let after?) = outcome {
                reportNativeAudio(after, for: observation, source: eventSource, showsOSD: false)
            }
        case .unresolvedNative, .none:
            return
        case .hardware:
            setHardwareControl(.volume, value, for: observation, showsOSD: false, eventSource: eventSource)
        }
    }

    /// Menu/slider mute toggle for a display, through its own route.
    @discardableResult
    func toggleDisplayMute(for observation: DisplayObservation) -> Bool {
        switch audioSink(for: observation) {
        case .native(let device):
            let outcome = NativeAudioAdjustment.apply(.muteToggle, uid: device.uid, delta: 0, controller: audioOutputs)
            refreshAudioOutputs()
            if case .failed = outcome {
                statusText = String(localized: "FreeDisplay couldn’t change the sound output. Check its volume and mute controls in Sound settings.")
            }
            if case .accepted(let after?) = outcome {
                reportNativeAudio(after, for: observation, source: .menu, showsOSD: false)
            }
            return outcome.handled
        case .unresolvedNative, .none:
            return false
        case .hardware:
            return toggleMute(for: observation)
        }
    }

    /// A volume slider drag ended (FA-20): one feedback sound, on the display's own output when it
    /// is known, following the preference — inverted while ⇧ (without ⌥) is held.
    func volumeSliderReleased(for observation: DisplayObservation) {
        let flags = NSEvent.modifierFlags
        let inverted = flags.contains(.shift) && !flags.contains(.option)
        guard VolumeFeedbackPolicy.plays(settings.nativeKeys.volumeFeedbackSound,
                                         systemPreference: VolumeFeedbackSoundPlayer.systemPreference,
                                         inverted: inverted) else { return }
        var outputUID: String?
        switch audioSink(for: observation) {
        case .native(let device):
            outputUID = device.uid
        case .hardware:
            let match = AudioOutputAssociation.displays(matching: audioSnapshot.currentOutput,
                                                        candidates: audioKeyCandidates(devices: audioSnapshot.devices))
            if match.displays == [observation.recordID] { outputUID = audioSnapshot.currentOutput?.uid }
        case .unresolvedNative, .none:
            return
        }
        VolumeFeedbackSoundPlayer.play(on: outputUID)
    }

    /// Updates one display's keyboard/audio preferences (saved at once, like every display setting).
    func updateKeyboardAudioPreferences(for observation: DisplayObservation,
                                        _ change: (inout DisplayKeyboardAudioPreferences) -> Void) {
        guard canPersistDisplaySettings(observation.recordID) else { return }
        var preferences = keyboardAudioPreferences(for: observation.recordID)
        change(&preferences)
        guard preferences.normalized != keyboardAudioPreferences(for: observation.recordID).normalized else { return }
        settings.setKeyboardAudioPreferences(preferences, for: observation.recordID)
        persistSettings()
        Task { [weak self] in await self?.confirmDisplayAudioForKeys() }
    }

    // MARK: - Native keyboard control state (SO-25)

    /// Permission, tap and capture as separate facts, for the Settings status line.
    var nativeKeyListeningState: NativeKeyListening.State {
        NativeKeyListening.state(featureEnabled: settings.mediaKeyInterceptionEnabled, preferences: settings.nativeKeys,
                                 permissionGranted: MediaKeyTap.isAccessibilityTrusted, tapActive: mediaKeysActive)
    }

    /// What the volume and mute keys would do right now, against the outputs last read.
    var audioKeyStatus: AudioKeyStatus {
        let captureOn = settings.mediaKeyInterceptionEnabled && settings.nativeKeys.volumeKeysEnabled
        guard captureOn else { return .off }
        guard nativeKeyListeningState == .listening else { return .disengaged }
        let candidates = audioKeyCandidates(devices: audioSnapshot.devices)
        return AudioKeyStatus.evaluate(
            captureEnabled: captureOn,
            volume: audioKeyDecision(.volumeUp, intent: .plain, candidates: candidates, snapshot: audioSnapshot),
            mute: audioKeyDecision(.muteToggle, intent: .plain, candidates: candidates, snapshot: audioSnapshot))
    }

    /// Updates the native-key policies, then re-arms the tap for what they now need.
    func updateNativeKeyPreferences(_ change: (inout NativeKeyPreferences) -> Void) {
        var updated = settings.nativeKeys
        change(&updated)
        guard updated != settings.nativeKeys else { return }
        settings.nativeKeys = updated
        releaseFeedback.cancel()
        shortcutFeedback.cancel()
        persistSettings()
        reconcileMediaKeyTap()
        Task { [weak self] in await self?.confirmDisplayAudioForKeys() }
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
            brightnessReceipts.invalidate(id)
            ddcWriters[id]?.cancel()
            ddcWriterOwnership.invalidate(id)
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
        Task { [weak self] in await self?.confirmDisplayAudioForKeys() }
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

    /// Changes the newer OSD preferences (SO-35, IN-16) and saves them.
    func updateOSDFeedback(_ change: (inout OSDFeedbackSettings) -> Void) {
        var feedback = settings.osdFeedback
        change(&feedback)
        guard feedback != settings.osdFeedback else { return }
        settings.osdFeedback = feedback
        if !feedback.receiverHandshakeEnabled { OSDReceiverHandshake.release(&settings) }
        persistSettings()
    }

    /// Gives the feedback settings back from the receiver app holding them (IN-16) — what the
    /// receiver's own release does, for one that quit or crashed without it.
    func restoreOSDSettingsFromReceiver() {
        var updated = settings
        OSDReceiverHandshake.release(&updated)
        guard updated != settings else { return }
        settings = updated
        persistSettings()
    }

    /// One handshake request from a receiver app (IN-16).
    private func answerOSDHandshake(_ incoming: OSDSettingsHandshake.Incoming) -> OSDSettingsHandshake.Response {
        var updated = settings
        let response = OSDReceiverHandshake.handle(incoming, settings: &updated)
        if updated != settings {
            settings = updated
            persistSettings()
        }
        return response
    }

    #if DEBUG
    /// Diagnostic dump of the observed topology to stderr, gated on `OPENDISPLAY_DUMP` so it is
    /// silent in normal runs. Run the app binary directly with the env var set to verify live
    /// enumeration without needing the menu-bar UI. DEBUG-only (excluded from release / App Store).
    private static func dump(_ snapshot: TopologySnapshot) {
        var out = "FreeDisplay topology \(snapshot.generation):\n"
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

// MARK: - App Intents support (IN-07, TB-05, TB-06, FB-14)

extension AppModel {
    /// Every display automation can name right now — the Shortcuts display picker.
    var automationDisplayEntries: [AutomationDisplayEntry] {
        AutomationDisplayCatalog.entries(displays: displays, offline: managedOffline, name: displayName(for:))
    }

    /// The name of a display the app remembers but doesn't see now, so a shortcut saved with it still
    /// shows the right display; nil for an identifier the app has never known.
    func automationRememberedName(_ id: DisplayRecordID) -> String? {
        guard records[id] != nil || registryKnownRecords[id] != nil else { return nil }
        return rememberedDisplayName(for: id)
    }

    /// Lets the launch-time display read finish before automation looks at the displays: an intent
    /// that starts the app would otherwise see an empty list and call every display missing.
    func prepareForAutomation() async {
        await awaitStartupLoad()
        if phase == .scanning { await refresh() }
    }

    /// Returns once launch has loaded the registry, the scenes and the managed-offline ledger —
    /// at once after that. The readiness barrier every recovery and automation entry shares: what
    /// the app turned off is only known from the ledger, and until it is loaded there is nothing
    /// to reconnect. No deadline of its own: the load is three small local files and one display
    /// snapshot.
    func awaitStartupLoad() async {
        await startupLoad?.value
    }

    /// The shared automation candidates (FD-066): the current displays, the ones OpenDisplay turned
    /// off, their registry records and groups, and the display under the pointer.
    func automationDisplaySet(pointerDisplayID: UInt32?) -> AutomationDisplaySet {
        AutomationDisplayCatalog.displaySet(
            displays: displays, offline: managedOffline, name: displayName(for:),
            record: { [records, registryKnownRecords] in records[$0] ?? registryKnownRecords[$0] },
            groups: settings.displayGroups, pointerDisplayID: pointerDisplayID,
            generation: displays.map(\.generation.value).max() ?? 0, remembered: registryKnownRecords)
    }

    /// The brightness routes a display offers automation (FD-066): the route its slider uses, and why
    /// the others can't carry a request. The app doesn't switch a display's route for one request,
    /// so only the current route is available; a display the user set to software dimming refuses
    /// hardware routes (a hardware-only request then fails instead of overriding that choice).
    func automationBrightnessRoutes(for id: DisplayRecordID) -> BrightnessRouteAvailability {
        let current: BrightnessRoute? = brightnessMethod[id].map {
            switch $0 {
            case .native: return .native
            case .hardware: return .ddc
            case .software: return .software
            }
        }
        #if PUBLIC_API_ONLY
        let publicAPIOnly = true
        #else
        let publicAPIOnly = false
        #endif
        return .appRoutes(current: current, publicAPIOnly: publicAPIOnly,
                          softwarePreferred: settings.softwareBrightnessDisplayIDs.contains(id.rawValue),
                          ddcRefusal: ddcBindingRefusal[id].map { "DDC withheld: \($0)" })
    }

    /// A display's ICC assignment as automation reports it (FD-067), from the caches
    /// `refreshColorProfile` fills.
    func automationColorProfileState(for id: DisplayRecordID) -> AutomationColorProfileState {
        let assignment = colorProfileAssignment[id]
        let custom = assignment.flatMap { $0.isFactory ? nil : $0.customURL?.standardizedFileURL.path }
        return AutomationColorProfileState(name: colorProfileName[id], customProfilePath: custom,
                                           isFactory: assignment?.isFactory ?? false,
                                           controllable: colorProfileControllable[id] ?? false)
    }

    func automationGroupBrightness(_ level: AutomationLevel, groupName: String, dryRun: Bool,
                                   actor: Actor) async throws(AutomationIssue) -> ResultEnvelope {
        guard let group = DisplayGroupStore.group(named: groupName, in: settings.displayGroups) else {
            throw AutomationIssue(.unknownGroup, "unknown display group", subject: groupName)
        }
        let fanOut = GroupSyncPolicy.groupWrites(level.float, group: group, world: groupSyncWorld())
        var targets: [ResultEnvelope.TargetResult] = []
        for member in fanOut.absent + fanOut.governed {
            let reason = fanOut.absent.contains(member) ? "absent" : "FaceLight or an app preset owns it"
            targets.append(.init(displayId: member.rawValue, alias: nil, identityConfidence: 1,
                operations: [.init(field: "brightness", verification: .notApplicable, warnings: [reason], outcome: .skipped)]))
        }
        // Queue the whole base operation before awaiting receipts; follower writes do not become
        // leader events and cannot re-learn offsets or fan back through another group.
        var queued: [(DisplayObservation, BrightnessWriteReceipt)] = []
        for write in fanOut.writes {
            guard let observation = displays.first(where: { $0.recordID == write.member }) else { continue }
            let receipt = BrightnessWriteReceipt(AutomationLevel(clamping: Double(write.value)))
            if !dryRun { applySilentBrightness(write.value, for: observation, receipt: receipt) }
            queued.append((observation, receipt))
        }
        var outcomes: [OperationOutcome] = []
        for (observation, receipt) in queued {
            let requested = receipt.requested
            let report = dryRun ? nil : await receipt.report()
            let verdict = report.map(BrightnessSettlement.settle)
            let outcome = verdict?.outcome ?? .alreadySatisfied
            outcomes.append(outcome)
            targets.append(.init(displayId: observation.recordID.rawValue, alias: records[observation.recordID]?.alias,
                identityConfidence: 1, operations: [.init(field: "brightness", requested: .double(requested.normalized),
                    observed: verdict?.observed.map { .double($0.normalized) },
                    verification: outcome == .verified ? .verified : .readBackUnavailable,
                    warnings: verdict?.note.map { [$0] } ?? [], outcome: outcome)]))
        }
        return ResultEnvelope(transactionId: "txn_brightness", status: outcomes.isEmpty ? .failed : .aggregate(outcomes),
                              actor: actor, requestedAt: Date(), topologyGeneration: displays.map(\.generation.value).max() ?? 0,
                              targets: targets)
    }

    func automationContrastReadback(for observation: DisplayObservation) async -> BrightnessReadback {
        #if !PUBLIC_API_ONLY
        let key = DDCControlKey(id: observation.recordID, vcp: HardwareControl.contrast.vcp)
        if let writer = ddcControlWriter[key] { await writer.value }
        guard observation.displayClass != .builtIn, ddcSupports(key.vcp, for: observation),
              let controller = await ddcController(for: observation),
              let reading = await controller.read(vcp: key.vcp), reading.max > 0 else { return .none }
        ddcControlMax[key] = reading.max
        ddcControlLevel[key.id, default: [:]][key.vcp] = Float(reading.current) / Float(reading.max)
        return .ddc(current: reading.current, max: reading.max)
        #else
        return .none
        #endif
    }

    /// The display's brightness as read back once every write already queued for it has run (TB-05):
    /// a fresh DisplayServices or DDC read for hardware routes, and the level OpenDisplay put on
    /// screen for software dimming (unless macOS rejected that change). Never the requested value.
    func automationBrightnessReadback(for observation: DisplayObservation) async -> BrightnessReadback {
        let id = observation.recordID
        #if !PUBLIC_API_ONLY
        // Native and DDC writes are coalesced on one task per display; the request just made is on it.
        if let writer = nativeWriters[id] { await writer.value }
        if let writer = ddcWriters[id] { await writer.value }
        #endif
        switch brightnessMethod[id] {
        case .native?:
            #if !PUBLIC_API_ONLY
            guard let cgID = observation.cgDisplayID else { return .none }
            let control = brightnessControl
            let level = await Task.detached(priority: .userInitiated) { control.brightness(for: cgID) }.value
            return level.map { .level(Double($0)) } ?? .none
            #else
            return .none
            #endif
        case .hardware?:
            #if !PUBLIC_API_ONLY
            guard let controller = await ddcController(for: observation),
                  let reading = await controller.read(vcp: ExternalDisplayDDC.Feature.brightness.rawValue)
            else { return .none }
            return .ddc(current: reading.current, max: reading.max)
            #else
            return .none
            #endif
        case .software?:
            // With gamma as the only carrier, a rejected table write changed nothing on screen.
            if gammaWriteFailures[id] != nil && effectiveDimmingMethod(for: id) == .gamma { return .none }
            return brightness[id].map { .applied(Double($0)) } ?? .none
        case nil:
            return .none
        }
    }
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
