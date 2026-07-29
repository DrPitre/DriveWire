//
//  DriveWireTCPServerDriverTests.swift
//  DriveWireTests
//
//  Regression coverage for the queue the TCP server driver drives the host on.
//

import XCTest
import Network

/// Holds the Becker-port listener to the queue contract `DriveWireHost` is
/// written against.
///
/// The host is not thread-safe and does not pretend to be: it takes guest input
/// on whatever queue the driver calls `send(data:)` from, while its own
/// virtual-serial paths append input and refresh channel status via
/// `DispatchQueue.main.async`, and its idle `watchdog` is a `Timer` that needs a
/// running run loop. `DriveWireTCPDriver` already hops to the main queue before
/// calling `send(data:)`. A driver that does not leaves two queues reading and
/// mutating the same dictionaries: Thread Sanitizer flags it, and in practice
/// `drivewire-cli` segfaults inside `pollVirtualSerial()`.
final class DriveWireTCPServerDriverTests: XCTestCase {

    /// Base for the fixed, unusual ports the tests listen on. Each test binds
    /// its own port (base + its offset) so one test's still-cancelling listener
    /// can never collide with the next test's bind.
    private let portBase: UInt16 = 45_411

    private var driver: DriveWireTCPServerDriver?
    private var connection: NWConnection?

    override func tearDownWithError() throws {
        connection?.cancel()
        connection = nil
        driver?.stop()
        driver = nil
    }

    /// Sanity: the listener answers a well-formed opcode at all. If this fails
    /// the harness is broken, not the driver.
    func testOpTimeAnswersOverTheListener() throws {
        let port = portBase
        let driver = DriveWireTCPServerDriver(port: port)
        self.driver = driver
        try driver.start()

        let connection = try connectToDriver(port: port)
        let received = Inbox()
        listen(on: connection, into: received)

        let reply = XCTestExpectation(description: "OP_TIME reply")
        received.expect(6, fulfilling: reply)
        send(Data([driver.host.OPTIME]), on: connection)

        let outcome = XCTWaiter.wait(for: [reply], timeout: 5.0)
        XCTAssertEqual(outcome, .completed,
                       "No OP_TIME reply at all; got \(received.data.count) byte(s).")
    }

    func testGuestTrafficReachesTheHostOnTheMainQueue() throws {
        let port = portBase + 1
        let driver = DriveWireTCPServerDriver(port: port)
        self.driver = driver
        try driver.start()

        // Stand in for the driver as the host's delegate so the queue the host
        // is actually driven on can be observed. The reply going nowhere is
        // fine; this test is about where the work happens, not what comes back.
        let recorder = QueueRecorder()
        driver.host.delegate = recorder

        let connection = try connectToDriver(port: port)
        send(Data([driver.host.OPTIME]), on: connection)   // one byte in, a reply out

        let outcome = XCTWaiter.wait(for: [recorder.called], timeout: 5.0)
        XCTAssertEqual(outcome, .completed, "The host never processed OP_TIME.")
        XCTAssertEqual(recorder.wasMainThread, true,
                       "The host was driven on \(recorder.queueLabel ?? "an unknown queue") "
                       + "instead of the main queue. DriveWireHost's state is also "
                       + "mutated from the main queue (virtual-serial input, "
                       + "channel status), so anything else races it, and its "
                       + "watchdog Timer needs a running run loop.")
    }

    /// Records which queue `DriveWireHost` called its delegate back on.
    private final class QueueRecorder: DriveWireDelegate {
        let called = XCTestExpectation(description: "host called its delegate")
        private(set) var wasMainThread: Bool?
        private(set) var queueLabel: String?

        func dataAvailable(host: DriveWireHost, data: Data) {
            guard wasMainThread == nil else { return }
            wasMainThread = Thread.isMainThread
            queueLabel = String(cString: __dispatch_queue_get_label(nil))
            called.fulfill()
        }

        func transactionCompleted(opCode: UInt8) {}
    }

    // MARK: - Plumbing

    /// Reference-typed accumulator: `Data` is a value type, so the assertion
    /// needs somewhere the receive callbacks and the test both see.
    ///
    /// The reply can land while `send` is pumping the run loop, so the wanted
    /// count is armed before the send and the expectation is fulfilled at most
    /// once -- never cleared, so the caller's own reference stays valid.
    private final class Inbox {
        private(set) var data = Data()
        private var wanted = 0
        private var expectation: XCTestExpectation?
        private var fulfilled = false

        func expect(_ count: Int, fulfilling expectation: XCTestExpectation) {
            wanted = count
            self.expectation = expectation
            fulfilled = false
            checkComplete()
        }

        func append(_ bytes: Data) {
            data.append(bytes)
            checkComplete()
        }

        private func checkComplete() {
            guard !fulfilled, wanted > 0, data.count >= wanted else { return }
            fulfilled = true
            expectation?.fulfill()
        }
    }

    private func connectToDriver(port: UInt16) throws -> NWConnection {
        let endpoint = try XCTUnwrap(NWEndpoint.Port(rawValue: port))
        let connection = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
        self.connection = connection

        let ready = XCTestExpectation(description: "connection ready")
        connection.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        connection.start(queue: .main)
        wait(for: [ready], timeout: 5.0)
        return connection
    }

    private func send(_ data: Data, on connection: NWConnection) {
        let sent = XCTestExpectation(description: "sent \(data.count) byte(s)")
        connection.send(content: data, completion: .contentProcessed { _ in
            sent.fulfill()
        })
        wait(for: [sent], timeout: 5.0)
    }

    /// Reads continuously into `inbox`, which fulfils its expectation once the
    /// wanted byte count arrives. Started before anything is sent, so a reply
    /// that arrives while `send` is pumping the run loop cannot be missed.
    private func listen(on connection: NWConnection, into inbox: Inbox) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64) {
            [weak self] content, _, isComplete, error in
            if let content, !content.isEmpty { inbox.append(content) }
            guard !isComplete, error == nil else { return }
            self?.listen(on: connection, into: inbox)
        }
    }
}
