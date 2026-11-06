import Foundation
import XCTest
import DriveWireNetworking
@testable import DriveWireServer
@testable import DriveWireCore

final class ServerTests: XCTestCase {
    @MainActor
    private func connect(_ port: UInt16) async -> TCPConnection {
        let ready = expectation(description: "TCP connected")
        let client = TCPConnection(host: "127.0.0.1", port: port)
        client.onReady = { ready.fulfill() }
        client.start()
        await fulfillment(of: [ready], timeout: 5)
        return client
    }

    @MainActor
    private func response(_ client: TCPConnection, bytes: Int, sending: () -> Void) async -> Data {
        let reply = expectation(description: "TCP response")
        var received = Data()
        var completed = false
        client.onReceive = { data in
            received.append(data)
            if received.count >= bytes && !completed {
                completed = true
                reply.fulfill()
            }
        }
        sending()
        await fulfillment(of: [reply], timeout: 5)
        client.onReceive = nil
        return received
    }

    @MainActor
    func testFragmentedAndCoalescedProtocolRequests() async throws {
        let server = DriveWireServer(port: 0)
        try server.start()
        defer { server.stop() }
        let client = await connect(server.port)
        defer { client.cancel() }
        client.send(Data([0x5a]))
        try await Task.sleep(nanoseconds: 20_000_000)
        let reply = await response(client, bytes: 2) {
            client.send(Data([1, 0, 0x5a, 2])) // finish DWINIT, NOP, next DWINIT
        }
        XCTAssertEqual(reply, Data([255,255]))
    }

    @MainActor
    func testReplacementRetiresPartialRequestHandlesAndCookies() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("DD"), withIntermediateDirectories: true)
        let server = DriveWireServer(port: 0)
        server.host.rfmRootPath = folder.path
        try server.start()
        defer { server.stop(); try? FileManager.default.removeItem(at: folder) }
        let first = await connect(server.port)
        let chd = Data([0xd6,0x14,1,1,0,0,0,0x85] + Array("/DD".utf8) + [13])
        let cookieReply = await response(first, bytes: 4) { first.send(chd) }
        XCTAssertEqual(cookieReply.count, 4)
        guard cookieReply.count == 4 else { return }
        let cookie = Array(cookieReply.dropFirst())
        let create = Data([0xd6,0x11,1,1] + cookie + [3] + Array("file".utf8) + [13])
        let created = await response(first, bytes: 1) { first.send(create) }
        XCTAssertEqual(created, Data([0]))
        XCTAssertEqual(server.host.rfmPaths.count, 1)
        first.send(Data([0xd6,0x12,2,1] + cookie + [1] + Array("unfinished".utf8)))
        let next = await connect(server.port)
        defer { first.cancel(); next.cancel() }
        let stale = Data([0xd6,0x12,1,2] + cookie + [0x81,46,13])
        let staleReply = await response(next, bytes: 1) { next.send(stale) }
        XCTAssertEqual(staleReply, Data([216]))
        XCTAssertTrue(server.host.rfmPaths.isEmpty)
        // Especially on Windows, an old open handle would prevent removal.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("DD/file"))
        let initialized = await response(next, bytes: 1) { next.send(Data([0x5a,1])) }
        XCTAssertEqual(initialized, Data([255]))
    }

    @MainActor
    func testBindConflictIsReported() throws {
        let first = DriveWireServer(port: 0)
        try first.start()
        defer { first.stop() }
        let conflict = DriveWireServer(port: first.port)
        XCTAssertThrowsError(try conflict.start())
        conflict.stop()
    }

    @MainActor
    func testVirtualSerialConnectUsesPortableTransport() async throws {
        let listener = TCPListener(port: 0)
        let accepted = expectation(description: "virtual serial connection")
        let sent = expectation(description: "guest bytes received")
        var remote: TCPConnection?
        try listener.start { connection in
            remote = connection
            connection.onReady = { connection.send(Data("hello".utf8)) }
            connection.onReceive = { data in
                XCTAssertEqual(data, Data([0,255,13]))
                sent.fulfill()
            }
            connection.start()
            accepted.fulfill()
        }
        let host = DriveWireHost()
        defer { host.disconnectGuest(); remote?.cancel(); listener.cancel() }
        XCTAssertTrue(host.tcpConnect(["127.0.0.1", String(listener.port)], channel: 1).hasPrefix("SUCCESS"))
        await fulfillment(of: [accepted], timeout: 5)
        for _ in 0..<100 where host.virtualSerialInput[1] != Data("hello".utf8) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(host.virtualSerialInput[1], Data("hello".utf8))
        host.virtualSerialTCPConnections[1]?.send(Data([0,255,13]))
        await fulfillment(of: [sent], timeout: 5)
    }

    @MainActor
    func testVirtualSerialReplacementSurvivesDeferredClose() async throws {
        let listener = TCPListener(port: 0)
        var peers = [TCPConnection]()
        try listener.start { connection in
            peers.append(connection)
            connection.onReady = { connection.send(Data([42])) }
            connection.start()
        }
        let host = DriveWireHost()
        defer { host.disconnectGuest(); peers.forEach { $0.cancel() }; listener.cancel() }
        let arguments = ["127.0.0.1", String(listener.port)]
        _ = host.tcpConnect(arguments, channel: 1)
        for _ in 0..<100 where host.virtualSerialInput[1]?.count != 1 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let previous = try XCTUnwrap(host.virtualSerialTCPConnections[1])
        _ = host.tcpConnect(arguments, channel: 1)
        for _ in 0..<100 where host.virtualSerialInput[1]?.count != 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(host.virtualSerialTCPConnections[1])
        XCTAssertFalse(host.virtualSerialTCPConnections[1] === previous)
        XCTAssertEqual(host.virtualSerialInput[1], Data([42,42]))
    }

    @MainActor
    func testVirtualSerialListenJoinAndTelnet() async throws {
        let reservation = TCPListener(port: 0)
        try reservation.start { $0.cancel() }
        let port = reservation.port
        reservation.cancel()
        let host = DriveWireHost()
        defer { host.disconnectGuest() }
        XCTAssertTrue(host.tcpListen([String(port), "telnet"], channel: 1).hasPrefix("SUCCESS"))
        let client = await connect(port)
        defer { client.cancel() }
        for _ in 0..<100 where host.pendingVirtualSerialTCPConnections.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let id = try XCTUnwrap(host.pendingVirtualSerialTCPConnections.keys.first)
        let negotiation = await response(client, bytes: 12) {
            XCTAssertTrue(host.tcpJoin([String(id)], channel: 2).hasPrefix("SUCCESS"))
        }
        XCTAssertEqual(negotiation, DriveWireHost.TelnetCodec.initialNegotiation)
        client.send(Data([104,105,13,10,255,255]))
        for _ in 0..<100 where host.virtualSerialInput[2] != Data([104,105,13,255]) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(host.virtualSerialInput[2], Data([104,105,13,255]))
    }
}
