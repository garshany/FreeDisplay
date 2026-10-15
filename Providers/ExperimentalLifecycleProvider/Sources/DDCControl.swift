#if os(macOS)
import CoreGraphics
import DisplayDomain
import Foundation
import IOKit

/// DDC/CI control of an external display over its private `IOAVService` I2C channel (Apple Silicon).
/// VCP feature codes follow the DDC/CI + MCCS spec: 0x10 brightness, 0x12 contrast, 0x62 audio
/// volume, 0x60 input source. The `IOAVService*` symbols are undocumented IOKit SPI resolved with
/// `dlsym` at runtime — so this links cleanly and is excluded from the public-API-only build, like
/// the SkyLight lifecycle and DisplayServices brightness paths. This type finds and binds the
/// display's service by identity; the transactions themselves — framing, reply validation, the
/// FIFO bus turnstile, pacing, and revocation — run in `DDCTransport` over that service, with
/// non-blocking sleeps for the DDC inter-message delays, so the slow I2C never touches the UI.
public actor ExternalDisplayDDC {
    /// Common VCP feature codes (Monitor Control Command Set). Any other code a panel implements is
    /// reachable through the raw `read(vcp:)` / `write(vcp:_:)` overloads.
    public enum Feature: UInt8, Sendable {
        /// Restore Factory Defaults (MCCS). Write-only, any non-zero value triggers it; the panel
        /// decides what "factory" covers (typically brightness, contrast, colour mode and gains).
        case restoreFactoryDefaults = 0x04
        case brightness = 0x10
        case contrast = 0x12
        case volume = 0x62
        case inputSource = 0x60
        case colorPreset = 0x14
        case redGain = 0x16
        case greenGain = 0x18
        case blueGain = 0x1A
        case sharpness = 0x87
        /// Audio mute. Discrete per MCCS: 1 = muted, 2 = unmuted.
        case audioMute = 0x8D
        /// Power mode (DPM). Values: 0x01 On, 0x04 Off (DPMS, usually wakeable), 0x05 Off (hard).
        case power = 0xD6
    }

    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
    private typealias WriteFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafePointer<UInt8>?, UInt32) -> Int32
    private typealias ReadFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutablePointer<UInt8>?, UInt32) -> Int32

    private let transport: DDCTransport

    /// Outcome of trying to bind a display's DDC channel.
    public enum Binding: Sendable {
        case bound(ExternalDisplayDDC)
        /// A channel may exist, but OpenDisplay won't use it — see `DDCBindingRefusal`.
        case refused(DDCBindingRefusal)
        /// No DDC channel: the built-in, OpenDisplay's own virtual screen, no external AV service,
        /// or the SPI is missing.
        case unavailable

        public var controller: ExternalDisplayDDC? {
            if case .bound(let controller) = self { return controller }
            return nil
        }

        public var refusal: DDCBindingRefusal? {
            if case .refused(let reason) = self { return reason }
            return nil
        }
    }

    /// A bound I2C channel: the display's `IOAVService` and the SPI that talks I2C through it.
    /// `@unchecked Sendable` because the service object isn't marked Sendable; it is only ever used
    /// by the one `DDCTransport` that owns this channel, one call at a time on its actor.
    private struct Channel: DDCWire, @unchecked Sendable {
        let service: AnyObject
        let writeFn: WriteFn
        let readFn: ReadFn

        func write(_ bytes: [UInt8]) -> Bool {
            var packet = bytes
            return writeFn(service, DDCTransport.i2cChip, DDCTransport.i2cSource, &packet, UInt32(packet.count)) == 0
        }

        func read(count: Int) -> [UInt8]? {
            var buffer = [UInt8](repeating: 0, count: count)
            guard readFn(service, DDCTransport.i2cChip, DDCTransport.i2cSource, &buffer, UInt32(count)) == 0
            else { return nil }
            return buffer
        }
    }
    private enum Lookup { case channel(Channel), refused(DDCBindingRefusal), unavailable }

    private init(channel: Channel) {
        transport = DDCTransport(wire: channel)
    }

    /// Withdraws this binding (FB-08): no further I/O goes through it — not even for a transaction
    /// already queued for the bus or waiting out the pacing gap, which cancelling its task can't
    /// reach (`DDCTransport.invalidate`). Synchronous, so it has taken effect by the time the
    /// revoking caller (the Apple-display override turned off, the display gone) moves on. A
    /// withdrawn controller stays withdrawn; the next use binds a fresh one.
    public nonisolated func invalidate() {
        transport.invalidate()
    }

    /// Binds to the external display's IOAVService, or fails if the display is the built-in, has no
    /// AV service, the SPI is unavailable, or the binding is refused (see `bind`).
    public init?(displayID: CGDirectDisplayID, allowAppleDisplay: Bool = false) {
        guard case .channel(let channel) = Self.lookup(displayID, allowAppleDisplay: allowAppleDisplay)
        else { return nil }
        self.init(channel: channel)
    }

    /// Binds to the external display's IOAVService, explaining a refusal. Refuses Apple-made
    /// displays unless `allowAppleDisplay` (the user's explicit per-display override — see
    /// `DDCEligibility`) and any service the identity evidence can't single out (`DDCServiceMatcher`):
    /// a guessed binding would send commands to a different monitor.
    public static func bind(displayID: CGDirectDisplayID, allowAppleDisplay: Bool = false) -> Binding {
        switch lookup(displayID, allowAppleDisplay: allowAppleDisplay) {
        case .channel(let channel): return .bound(ExternalDisplayDDC(channel: channel))
        case .refused(let reason): return .refused(reason)
        case .unavailable: return .unavailable
        }
    }

    private static func lookup(_ displayID: CGDirectDisplayID, allowAppleDisplay: Bool) -> Lookup {
        guard CGDisplayIsBuiltin(displayID) == 0 else { return .unavailable }
        let vendor = CGDisplayVendorNumber(displayID)
        // OpenDisplay's own virtual screens have no I2C channel; without this they would score zero
        // against the real monitor's service and could only ever borrow it.
        guard vendor != VirtualDisplaySafetyPolicy.providerVendorID else { return .unavailable }
        guard DDCEligibility.allowsGenericDDC(vendorNumber: Int(vendor), appleOverride: allowAppleDisplay)
        else { return .refused(.appleDisplay) }
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let createPtr = dlsym(iokit, "IOAVServiceCreateWithService"),
              let writePtr = dlsym(iokit, "IOAVServiceWriteI2C"),
              let readPtr = dlsym(iokit, "IOAVServiceReadI2C")
        else { return .unavailable }
        let create = unsafeBitCast(createPtr, to: CreateFn.self)
        let svc: io_service_t
        switch avService(for: displayID) {
        case .found(let found): svc = found
        case .refused(let reason): return .refused(reason)
        case .none: return .unavailable
        }
        defer { IOObjectRelease(svc) }
        guard let av = create(kCFAllocatorDefault, svc) else { return .unavailable }
        return .channel(Channel(service: av.takeRetainedValue(),
                                writeFn: unsafeBitCast(writePtr, to: WriteFn.self),
                                readFn: unsafeBitCast(readPtr, to: ReadFn.self)))
    }

    /// Reads a VCP feature: (current, max) in the display's native units (brightness/contrast 0...100
    /// on most panels), or nil if the display never answered with a well-formed reply.
    /// See `DDCTransport.read(vcp:)` for the framing/validation story.
    public func read(_ feature: Feature) async -> (current: Int, max: Int)? {
        await read(vcp: feature.rawValue)
    }

    /// Raw-VCP variant of `read(_:)` for codes outside the `Feature` enum — panels implement far
    /// more of MCCS than we name (KVM toggles, OSD language, colour temperature…), and the CLI/UI
    /// shouldn't need a source change to reach them.
    public func read(vcp code: UInt8) async -> (current: Int, max: Int)? {
        await transport.read(vcp: code)
    }

    /// Sets a VCP feature to a value in the display's native units. Returns false if the write failed.
    @discardableResult
    public func write(_ feature: Feature, _ value: Int) async -> Bool {
        await write(vcp: feature.rawValue, value)
    }

    /// Raw-VCP variant of `write(_:_:)` — see `read(vcp:)`. False also when the binding was
    /// withdrawn (`invalidate`) while the write waited for the bus.
    @discardableResult
    public func write(vcp code: UInt8, _ value: Int) async -> Bool {
        await transport.write(vcp: code, value)
    }

    /// Reads the display's DDC/CI capabilities string (the response to VCP `0xF3`, MCCS spec) by
    /// requesting it in chunks and concatenating the replies until the display returns an empty chunk.
    /// Returns nil if the display doesn't answer. Best-effort: a NAK or a malformed reply just ends the
    /// read with whatever was gathered so far. Parse the result with `DDCCapabilities.parse`.
    ///
    /// ⚠️ This long multi-chunk read can DESYNCHRONIZE DDC/CI on some panels (Samsung S34J55x), leaving
    /// the panel replaying a stale reply buffer so later reads return garbage and writes are ignored
    /// until a power-cycle. Probed live on a wedged S34J55x: the scaler cycles a ~192-byte ring of old
    /// capabilities-reply bytes, drops new replies, and neither read-draining nor a display sleep/wake
    /// clears it — only the panel's own power switch does. Treat it as an explicit, diagnostic-only
    /// call (CLI `ddc … caps`) — never run it on the normal control-refresh path.
    public func readCapabilitiesString() async -> String? {
        await transport.readCapabilitiesString()
    }

    /// Maps a `CGDirectDisplayID` to its external `IOAVService` by **identity**, not order.
    ///
    /// One recursive IORegistry walk collects every external `DCPAVServiceProxy` together with the
    /// `ProductAttributes` (manufacturer / product id / serial) of the display node most recently
    /// seen before it — on Apple Silicon the panel's `AppleCLCD2` node precedes its AV proxy in
    /// service-plane order, so "most recent display attributes" is that proxy's panel. Each
    /// candidate is then scored against the CG display's vendor/model/serial
    /// (`DDCServiceMatcher`), which keeps DDC bound to the *right* monitor across dock re-plugs,
    /// mixed HDMI/DP topologies, and IOKit-vs-CG ordering disagreements. Enumeration order is NOT
    /// a fallback: when identity can't single out one service (identical serial-less monitors,
    /// attribute-less services next to several displays) the lookup is refused — order is exactly
    /// what changes across a dock replug, so a guess could silently retarget writes. A lone
    /// attribute-less service for a lone external monitor still binds.
    private enum ServiceLookup { case found(io_service_t), refused(DDCBindingRefusal), none }

    private static func avService(for displayID: CGDirectDisplayID) -> ServiceLookup {
        var iterator = io_iterator_t()
        guard IORegistryCreateIterator(
            kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator
        ) == KERN_SUCCESS else { return .none }
        defer { IOObjectRelease(iterator) }

        var externals: [io_service_t] = []
        var candidates: [DDCServiceMatcher.Candidate?] = []
        // Up to two walks: IOKit invalidates a live iterator when the registry mutates mid-walk
        // (exactly what happens during display hotplug, which is when we run), and an invalidated
        // iterator just stops early — silently truncating the candidate list. Retry once from a
        // reset iterator rather than binding a display to a partial view of the registry.
        for _ in 0..<2 {
            var pendingAttributes: DDCServiceMatcher.Candidate?
            var entry = IOIteratorNext(iterator)
            while entry != 0 {
                if let attributes = productAttributes(entry) {
                    pendingAttributes = attributes
                } else if IOObjectConformsTo(entry, "DCPAVServiceProxy") != 0 {
                    let location = IORegistryEntryCreateCFProperty(
                        entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                    if location == "External" {
                        externals.append(entry)
                        candidates.append(pendingAttributes)
                        pendingAttributes = nil
                        entry = IOIteratorNext(iterator)
                        continue  // kept — don't release
                    }
                    // A non-external proxy (the built-in's "Embedded") still closes out its
                    // display's subtree. Without this, the built-in's Apple attributes would leak
                    // onto the next attribute-less external and could out-score the real match.
                    pendingAttributes = nil
                }
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            if IOIteratorIsValid(iterator) != 0 { break }
            for kept in externals { IOObjectRelease(kept) }
            externals.removeAll()
            candidates.removeAll()
            IOIteratorReset(iterator)
        }
        let index: Int
        switch DDCServiceMatcher.resolve(candidates, against: identity(of: displayID),
                                         among: externalDisplayIDs().map(identity(of:))) {
        case .matched(let found), .sole(let found): index = found
        case .refused(let reason):
            for kept in externals { IOObjectRelease(kept) }
            return .refused(reason)
        case .none:
            return .none
        }
        let chosen = externals[index]
        for candidate in externals where candidate != chosen { IOObjectRelease(candidate) }
        return .found(chosen)
    }

    private static func identity(of displayID: CGDirectDisplayID) -> DDCServiceMatcher.Target {
        DDCServiceMatcher.Target(
            vendorNumber: Int(CGDisplayVendorNumber(displayID)),
            productNumber: Int(CGDisplayModelNumber(displayID)),
            serialNumber: Int(CGDisplaySerialNumber(displayID)))
    }

    /// The EDID-derived identity a display-service node advertises (`DisplayAttributes` →
    /// `ProductAttributes` on e.g. `AppleCLCD2`), or nil for nodes that aren't displays. Field
    /// names are the IOKit-published ones; every one is optional in the wild.
    private static func productAttributes(_ entry: io_registry_entry_t) -> DDCServiceMatcher.Candidate? {
        guard let raw = IORegistryEntryCreateCFProperty(
            entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let attributes = raw as? [String: Any],
              let product = attributes["ProductAttributes"] as? [String: Any]
        else { return nil }
        return DDCServiceMatcher.Candidate(
            legacyManufacturerID: product["LegacyManufacturerID"] as? Int,
            manufacturerID: product["ManufacturerID"] as? String,
            productID: product["ProductID"] as? Int,
            serialNumber: product["SerialNumber"] as? Int)
    }

    /// Online external displays that could own an AV service. OpenDisplay's own virtual screens are
    /// left out: they never have one, and counting them would make a lone monitor look ambiguous.
    private static func externalDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).filter {
            CGDisplayIsBuiltin($0) == 0 && CGDisplayVendorNumber($0) != VirtualDisplaySafetyPolicy.providerVendorID
        }.sorted()
    }
}
#endif
