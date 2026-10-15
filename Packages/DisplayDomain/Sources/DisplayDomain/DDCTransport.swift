import Dispatch
import Foundation

/// The wire under a `DDCTransport`: one I2C write or read on a display's DDC/CI channel, at the
/// DDC/CI device address (`DDCTransport.i2cChip`) from the host source address
/// (`DDCTransport.i2cSource`). The macOS provider implements it over the private `IOAVService`
/// I2C calls; tests implement it in memory. Calls arrive one at a time, from the transport's actor.
public protocol DDCWire: Sendable {
    /// Writes `bytes`; true when the bus accepted them.
    func write(_ bytes: [UInt8]) -> Bool
    /// Reads `count` bytes, or nil when the bus refused.
    func read(count: Int) -> [UInt8]?
}

/// DDC/CI transactions over one display's I2C channel: the framing and reply validation, the FIFO
/// bus turnstile (`lockBus`) making each multi-step transaction exclusive — the actor alone is NOT
/// enough, since it is reentrant at the awaits inside a transaction — the pacing between
/// transactions, and revocation (`invalidate`). Non-blocking sleeps throughout, so the slow I2C
/// never touches the UI. Platform-independent: `ExternalDisplayDDC` supplies the wire.
///
/// Revocation is checked at the transport boundary, after the bus is held and paced and
/// immediately before each I/O (FB-08). A transaction can wait a long time for the bus — behind a
/// five-attempt read, a multi-chunk capabilities read — and cancelling the task that queued it, or
/// dropping the cached binding, cannot reach it there. So once the binding is withdrawn (the
/// Apple-display override turned off, the display gone), nothing more goes on the wire through it.
public actor DDCTransport {
    /// DDC/CI 7-bit I2C address.
    public static let i2cChip: UInt32 = 0x37
    /// Host source address (the "dataAddress" argument), which the DDC/CI checksums include.
    public static let i2cSource: UInt32 = 0x51

    private let wire: any DDCWire
    private let revocation = Revocation()

    public init(wire: any DDCWire) {
        self.init(wire: wire, interTransactionGapNanos: Self.defaultInterTransactionGapNanos)
    }

    /// Tests stretch the gap to make "a transaction is waiting out the pacing" observable.
    init(wire: any DDCWire, interTransactionGapNanos: UInt64) {
        self.wire = wire
        self.interTransactionGapNanos = interTransactionGapNanos
    }

    // MARK: - Revocation

    /// Withdraws the binding: every I/O that would start after this is refused, including that of
    /// a transaction already queued for the bus or waiting out the pacing gap. (A single I2C call
    /// already under way can't be recalled.) Synchronous and callable from any context, so the
    /// revocation path doesn't wait behind the transactions it is revoking.
    public nonisolated func invalidate() {
        revocation.revoke()
    }

    public nonisolated var isInvalidated: Bool {
        revocation.isRevoked
    }

    /// One flag, set once from whichever thread revokes and read on the actor right before I/O.
    private final class Revocation: @unchecked Sendable {
        private let lock = NSLock()
        private var revoked = false
        func revoke() { lock.lock(); revoked = true; lock.unlock() }
        var isRevoked: Bool { lock.lock(); defer { lock.unlock() }; return revoked }
    }

    /// The wire, if the binding still stands. Called only with the bus held and paced.
    private func send(_ bytes: [UInt8]) -> Bool? {
        guard !revocation.isRevoked else { return nil }
        return wire.write(bytes)
    }

    private func receive(count: Int) -> [UInt8]?? {
        guard !revocation.isRevoked else { return nil }
        return .some(wire.read(count: count))
    }

    // MARK: - Bus

    // DDC/CI reads are flaky and easily desynchronized (a previous reply can linger in the panel's
    // buffer). Retry a few times, validate strictly, and give the panel time to prepare each reply.
    // The first attempt uses the shorter delay (proven sufficient on healthy panels); retries wait
    // longer since a slow panel is the main reason a first attempt fails.
    private static let readRetries = 5
    private static let readReplyFirstNanos: UInt64 = 60_000_000  // 60ms on the first attempt
    private static let readReplyNanos: UInt64 = 100_000_000      // 100ms on retries

    /// Minimum quiet gap between DDC transactions on the same panel. Enforced by *pacing* (sleep
    /// only the unelapsed remainder before the next transaction) rather than a blanket sleep after
    /// every operation — so a lone write returns as soon as the I2C call does, while back-to-back
    /// operations still never hit the panel faster than it can digest (the desync trigger).
    private static let defaultInterTransactionGapNanos: UInt64 = 50_000_000
    private let interTransactionGapNanos: UInt64
    private var lastTransactionUptime: UInt64 = 0

    /// Waits out the inter-transaction gap since the last bus operation. Loops rather than sleeping
    /// once: actors are reentrant during `Task.sleep`, so another task may transact while we sleep,
    /// moving the deadline — a single fixed sleep would then hit the bus too early.
    private func paceBus() async {
        while lastTransactionUptime != 0 {
            let elapsed = DispatchTime.now().uptimeNanoseconds &- lastTransactionUptime
            if elapsed >= interTransactionGapNanos { return }
            try? await Task.sleep(nanoseconds: interTransactionGapNanos - elapsed)
        }
    }

    private func markTransaction() {
        lastTransactionUptime = DispatchTime.now().uptimeNanoseconds
    }

    // The actor alone does NOT make a DDC transaction atomic: a read suspends between writing the
    // request and reading the reply, and Swift actors are reentrant at suspension points — so a
    // coalesced slider write could land on the bus inside another read's reply window, invalidating
    // the pending reply (and reproducing the rapid-fire traffic that desyncs panels). This FIFO
    // turnstile makes each transaction exclusive: lock around request→delay→reply, not just around
    // individual I2C calls.
    private var busLocked = false
    private var busWaiters: [CheckedContinuation<Void, Never>] = []

    // Internal rather than private so tests can hold the bus and queue a transaction behind it.
    func lockBus() async {
        if !busLocked { busLocked = true; return }
        await withCheckedContinuation { busWaiters.append($0) }
    }

    func unlockBus() {
        if busWaiters.isEmpty { busLocked = false } else { busWaiters.removeFirst().resume() }
    }

    /// For tests: how many transactions are queued behind the one holding the bus, and whether one
    /// holds it.
    var transactionsWaitingForBus: Int { busWaiters.count }
    var isBusHeld: Bool { busLocked }

    // MARK: - Transactions

    /// Reads a VCP feature: (current, max) in the display's native units, or nil if the display
    /// never answered with a well-formed reply — or the binding was withdrawn.
    ///
    /// Reads a WIDE buffer and scans it for the reply frame instead of demanding it at offset 0:
    /// mildly desynchronized scalers commonly return the valid frame prefixed by a few stale bytes
    /// (observed live on a Samsung S34J55x — `… d8 6c 6f | 6e 88 02 00 12 …`), and an offset-0-only
    /// check reads those panels as "unsupported" forever. A scanned match must echo *our* VCP code
    /// AND carry a valid DDC/CI reply checksum (`0x50 ^ frame bytes` — verified against captured
    /// hardware replies), so stale garbage can't masquerade as a value.
    public func read(vcp code: UInt8) async -> (current: Int, max: Int)? {
        for attempt in 0..<Self.readRetries {
            await lockBus()
            let value = await readAttempt(code, attempt: attempt)
            unlockBus()
            if let value { return value }
            if revocation.isRevoked { return nil }  // no retry through a withdrawn binding
        }
        return nil
    }

    /// One bus-exclusive Get-VCP transaction: request → reply delay → wide read → frame scan.
    /// Caller holds the bus lock, so nothing can interleave between the request and its reply.
    private func readAttempt(_ code: UInt8, attempt: Int) async -> (current: Int, max: Int)? {
        let checksum = UInt8(0x6e ^ Int(Self.i2cSource) ^ 0x82 ^ 0x01) ^ code
        await paceBus()
        guard let wrote = send([0x82, 0x01, code, checksum]) else { return nil }
        markTransaction()
        guard wrote else { return nil }  // paceBus() spaces the retry
        try? await Task.sleep(nanoseconds: attempt == 0 ? Self.readReplyFirstNanos : Self.readReplyNanos)
        guard let reply = receive(count: Self.readWindow) else { return nil }
        markTransaction()
        guard let buffer = reply else { return nil }
        return Self.scanReply(in: buffer, vcp: code)
    }

    /// Bytes fetched per Get-VCP reply read. The frame itself is 11; the extra window is what lets
    /// `scanReply` recover replies that arrive behind stale prefix bytes. Reading beyond the reply
    /// is harmless on I2C (the device pads) — the capabilities path has always read 64 this way.
    private static let readWindow = 48

    /// Finds a well-formed Get-VCP reply for `code` anywhere in `buffer`: source `0x6e`, length
    /// `0x88`, Get-reply opcode `0x02`, result OK, echoed code, and a valid reply checksum
    /// (XOR of `0x50` and the 10 frame bytes must equal the 11th).
    ///
    /// Falls back to the structural offset-0 check WITHOUT the length/checksum requirements when no
    /// checksummed frame is found: some panels ship malformed length bytes or wrong checksums, and
    /// those exact replies were accepted by every previous version of this reader — the stricter
    /// validation must only ever ADD recoveries, never regress a panel that used to work.
    ///
    /// Known gap (backlog SD-04, owner decision pending): this relaxation applies to every panel,
    /// not to an explicit per-device compatibility list. It is kept unconditional on purpose until
    /// there is hardware evidence of which panels rely on it — defaulting to strict without that list
    /// would silently turn working DDC controls into "no response" on exactly those panels.
    static func scanReply(in buffer: [UInt8], vcp code: UInt8) -> (current: Int, max: Int)? {
        guard buffer.count >= 11 else { return nil }
        for offset in 0...(buffer.count - 11) {
            guard buffer[offset] == 0x6e, buffer[offset + 1] == 0x88, buffer[offset + 2] == 0x02,
                  buffer[offset + 3] == 0x00, buffer[offset + 4] == code else { continue }
            let frame = buffer[offset..<(offset + 10)]
            guard frame.reduce(0x50 as UInt8, ^) == buffer[offset + 10] else { continue }
            let maxValue = Int(buffer[offset + 6]) << 8 | Int(buffer[offset + 7])
            let current = Int(buffer[offset + 8]) << 8 | Int(buffer[offset + 9])
            return (current, maxValue)
        }
        // Legacy-compat fallback: exactly the old validation, offset 0 only.
        if buffer[0] == 0x6e, buffer[2] == 0x02, buffer[3] == 0x00, buffer[4] == code {
            return (Int(buffer[8]) << 8 | Int(buffer[9]), Int(buffer[6]) << 8 | Int(buffer[7]))
        }
        return nil
    }

    /// Sets a VCP feature to a value in the display's native units. Returns false if the write
    /// failed or the binding was withdrawn while it waited for the bus. Returns as soon as the I2C
    /// call does; the mandatory settle time before the *next* transaction is enforced by pacing,
    /// not by sleeping here, so a single slider tick doesn't pay 50ms of dead latency.
    @discardableResult
    public func write(vcp code: UInt8, _ value: Int, authorization: WriteAuthorization? = nil) async -> Bool {
        let high = UInt8((value >> 8) & 0xff)
        let low = UInt8(value & 0xff)
        let checksum = UInt8(0x6e ^ Int(Self.i2cSource) ^ 0x84 ^ 0x03) ^ code ^ high ^ low
        await lockBus()
        defer { unlockBus() }
        await paceBus()
        // Judged here, not on entry: the wait for the bus and the pacing are where a revocation
        // lands while this write is already queued.
        guard !Task.isCancelled, authorization?.isAuthorized != false,
              let ok = send([0x84, 0x03, code, high, low, checksum]) else { return false }
        markTransaction()
        return ok
    }

    /// Reads the display's DDC/CI capabilities string (the response to VCP `0xF3`, MCCS spec) by
    /// requesting it in chunks and concatenating the replies until the display returns an empty chunk.
    /// Returns nil if the display doesn't answer. Best-effort: a NAK, a malformed reply or a withdrawn
    /// binding just ends the read with whatever was gathered so far.
    ///
    /// ⚠️ This long multi-chunk read can DESYNCHRONIZE DDC/CI on some panels — see
    /// `ExternalDisplayDDC.readCapabilitiesString`. Diagnostic-only.
    public func readCapabilitiesString() async -> String? {
        // Hold the bus for the whole multi-chunk sequence: an interleaved transaction between
        // chunks breaks the offset continuation and is the likeliest wedge trigger.
        await lockBus()
        let result = await readCapabilitiesLocked()
        unlockBus()
        return result
    }

    private func readCapabilitiesLocked() async -> String? {
        var bytes: [UInt8] = []
        var offset: UInt16 = 0
        // Safety cap: 96 chunks × ~32 bytes ≈ 3 KB, far beyond any real capabilities string.
        for _ in 0..<96 {
            let high = UInt8(offset >> 8)
            let low = UInt8(offset & 0xff)
            // Capabilities Request: length 0x83 (3 data bytes), opcode 0xF3, 16-bit offset.
            let checksum = UInt8(0x6e ^ Int(Self.i2cSource) ^ 0x83 ^ 0xf3) ^ high ^ low
            await paceBus()
            guard let wrote = send([0x83, 0xf3, high, low, checksum]) else { break }
            markTransaction()
            guard wrote else { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let reply = receive(count: 64) else { break }
            markTransaction()
            guard let buffer = reply,
                  buffer.count >= 5, buffer[0] == 0x6e, buffer[2] == 0xe3 else { break }  // 0xE3 = Capabilities Reply
            let length = Int(buffer[1] & 0x7f)
            // length covers opcode (0xE3) + 2 offset bytes + the data; fewer means a malformed reply.
            guard length >= 3 else { break }
            let replyOffset = UInt16(buffer[3]) << 8 | UInt16(buffer[4])
            guard replyOffset == offset else { break }  // out of sync — stop
            let dataLen = length - 3
            if dataLen == 0 { break }  // empty chunk = end of string
            let end = min(5 + dataLen, buffer.count)
            bytes.append(contentsOf: buffer[5..<end])
            offset += UInt16(end - 5)
        }
        guard !bytes.isEmpty else { return nil }
        return String(bytes: bytes, encoding: .ascii) ?? String(bytes: bytes, encoding: .utf8)
    }
}
