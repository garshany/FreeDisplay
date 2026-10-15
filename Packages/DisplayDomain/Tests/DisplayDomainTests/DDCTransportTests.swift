import XCTest
@testable import DisplayDomain

/// R4 P1 (FB-08): a DDC transaction already waiting for the bus, or waiting out the pacing gap,
/// must not reach the wire once its binding is withdrawn — cancelling the task that queued it and
/// dropping the cached controller can't reach it there.
final class DDCTransportTests: XCTestCase {
    /// An in-memory I2C channel: records what is sent and answers reads with `reply`.
    private final class RecordingWire: DDCWire, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [[UInt8]] = []
        private var readCount = 0
        private let reply: [UInt8]?

        init(reply: [UInt8]? = nil) { self.reply = reply }

        func write(_ bytes: [UInt8]) -> Bool {
            lock.lock(); defer { lock.unlock() }
            sent.append(bytes)
            return true
        }

        func read(count: Int) -> [UInt8]? {
            lock.lock(); defer { lock.unlock() }
            readCount += 1
            return reply.map { $0 + [UInt8](repeating: 0, count: max(0, count - $0.count)) }
        }

        var writes: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return sent }
        var reads: Int { lock.lock(); defer { lock.unlock() }; return readCount }
    }

    private static func setVCP(_ code: UInt8, _ value: Int) -> [UInt8] {
        let high = UInt8((value >> 8) & 0xff), low = UInt8(value & 0xff)
        return [0x84, 0x03, code, high, low, UInt8(0x6e ^ 0x51 ^ 0x84 ^ 0x03) ^ code ^ high ^ low]
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        while !(await condition()) { await Task.yield() }
    }

    /// The finding: the write was already queued behind the bus when the override was revoked, and
    /// went out anyway once the bus was free.
    func testAWriteQueuedForTheBusSendsNothingOnceRevoked() async {
        let wire = RecordingWire()
        let transport = DDCTransport(wire: wire)
        await transport.lockBus()  // another transaction holds the bus
        let writing = Task { await transport.write(vcp: 0x10, 40) }
        await waitUntil { await transport.transactionsWaitingForBus == 1 }
        transport.invalidate()
        await transport.unlockBus()
        let wrote = await writing.value
        XCTAssertFalse(wrote)
        XCTAssertEqual(wire.writes, [], "nothing reaches the wire through a withdrawn binding")
        XCTAssertTrue(transport.isInvalidated)
    }

    /// Holding the bus, a write still waits out the gap since the previous transaction; a
    /// revocation landing in that wait stops it too.
    func testAWriteWaitingOutThePacingSendsNothingOnceRevoked() async {
        let wire = RecordingWire()
        let transport = DDCTransport(wire: wire, interTransactionGapNanos: 300_000_000)
        let first = await transport.write(vcp: 0x10, 30)
        XCTAssertTrue(first)
        let writing = Task { await transport.write(vcp: 0x10, 40) }
        // Holding the bus with nobody queued: the second write is asleep in the pacing wait.
        await waitUntil { await transport.isBusHeld }
        transport.invalidate()
        let wrote = await writing.value
        XCTAssertFalse(wrote)
        XCTAssertEqual(wire.writes, [Self.setVCP(0x10, 30)], "only the write before the revocation")
        let busHeld = await transport.isBusHeld
        XCTAssertFalse(busHeld, "a refused write still hands the bus on")
    }

    func testAQueuedReadAndCapabilitiesReadSendNothingOnceRevoked() async {
        let wire = RecordingWire(reply: [0x6e, 0x88])
        let transport = DDCTransport(wire: wire)
        await transport.lockBus()
        let reading = Task { await transport.read(vcp: 0x10) }
        let capabilities = Task { await transport.readCapabilitiesString() }
        await waitUntil { await transport.transactionsWaitingForBus == 2 }
        transport.invalidate()
        await transport.unlockBus()
        let read = await reading.value
        let caps = await capabilities.value
        XCTAssertNil(read)
        XCTAssertNil(caps)
        XCTAssertEqual(wire.writes, [])
        XCTAssertEqual(wire.reads, 0, "no retries through a withdrawn binding either")
    }

    /// The transport as moved out of the provider: same Set-VCP framing, same Get-VCP reply scan.
    func testAnOpenTransportFramesWritesAndReadsReplies() async {
        var frame: [UInt8] = [0x6e, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x28]
        frame.append(frame.reduce(0x50 as UInt8, ^))
        let wire = RecordingWire(reply: frame)
        let transport = DDCTransport(wire: wire)
        let wrote = await transport.write(vcp: 0x10, 0x0128)
        XCTAssertTrue(wrote)
        let reading = await transport.read(vcp: 0x10)
        XCTAssertEqual(reading?.current, 40)
        XCTAssertEqual(reading?.max, 100)
        XCTAssertEqual(wire.writes, [Self.setVCP(0x10, 0x0128),
                                     [0x82, 0x01, 0x10, UInt8(0x6e ^ 0x51 ^ 0x82 ^ 0x01) ^ 0x10]])
        XCTAssertEqual(wire.reads, 1)
    }
}
