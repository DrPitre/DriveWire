//
//  DriveWireSwiftTests.swift
//  DriveWireSwiftTests
//
//  Created by Boisy Pitre on 9/29/23.
//

import XCTest
import Network

final class DriveWireSwiftTests: XCTestCase, DriveWireDelegate {
    var host : DriveWireHost?

    func transactionCompleted(opCode: UInt8) {
    }
    
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
        host = DriveWireHost(delegate: self)
        host?.bridgeChannels(Set(0...15))
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testInsert() throws {
        do {
            try host!.insertVirtualDisk(driveNumber: 0, imagePath: "/Users/boisy/test.dsk")
            try host!.insertVirtualDisk(driveNumber: 0, imagePath: "/Users/boisy/test.dsk")
        } catch DriveWireHostError.driveAlreadyExists {
            host!.ejectVirtualDisk(driveNumber: 0)
        }
    }
    
    func testNOP() throws {
        var s = Data([host!.OPNOP])
        host!.send(data: &s)
    }

    func testDWINIT() throws {
        var s = Data([host!.OPDWINIT, 0x01])
        expectation = XCTestExpectation(description: "Waiting for response")
        host!.send(data: &s)
        let _ = XCTWaiter.wait(for: [expectation!], timeout: 5.0)
        // A non-zero response is required: the NitrOS-9 driver treats a zero
        // (or missing) response as a DW3 server and disables its DW4
        // extensions, including the virtual serial channel poller.
        let expectedResult = 0xFF
        let actualResult = read(bytes: 1)[0]
        XCTAssert(actualResult == expectedResult, "Error: result should be \(expectedResult), but was \(actualResult)")
    }

    func testTIME() throws {
        var s = Data([host!.OPTIME])
        host!.send(data: &s)
    }

    func testREAD() throws {
        do {
            // Read LSN1 of drive 0 (should not return error)
            var (error, sector) = try READ(drive: 0, lsn: 1)
            var expectedResult = 0
            XCTAssert(error == expectedResult, "Error: error should be \(expectedResult), but was \(error)")

            // Read a sector beyond the capacity of drive 0 (should not return error)
            (error, sector) = try READEX(drive: 0, lsn: 10000)
            expectedResult = 0
            XCTAssert(error == expectedResult, "Error: error should be \(expectedResult), but was \(error)")

            // Read a sector beyond the capacity of non-existent 500 (should return error)
            (error, sector) = try READEX(drive: 255, lsn: 10000)
            expectedResult = 240
            XCTAssert(error == expectedResult, "Error: error should be \(expectedResult), but was \(error)")
        } catch {
            
        }
    }
    
    func testREADEX() throws {
        do {
            // Read LSN1 of drive 0 (should not return error)
            var (error, sector) = try READEX(drive: 0, lsn: 1)
            XCTAssert(error == 0 && sector.count == 256, "Error: error should be 0, but was \(error)")

            // Read a sector beyond the capacity of drive 0 (should not return error)
            (error, sector) = try READEX(drive: 0, lsn: 10000)
            XCTAssert(error == 0 && sector.count == 256, "Error: error should be 0, but was \(error)")

            // Read a sector beyond the capacity of non-existent 500 (should return error)
            (error, sector) = try READEX(drive: 255, lsn: 10000)
            XCTAssert(error == 240, "Error: error should be 0, but was \(error)")
        } catch {
            
        }
    }
    
    var expectation : XCTestExpectation?
    var responseData : Data = Data()
    
    func dataAvailable(host : DriveWireHost, data : Data) {
        data.dump()
        responseData.append(data)
        expectation?.fulfill()
    }
    
    func read(bytes : Int) -> Data {
        let result = responseData.subdata(in: 0..<bytes)
        responseData.removeSubrange(0..<bytes)
//        responseData.removeFirst(bytes)
        return result
    }
    
    func READEX(drive : Int, lsn : Int) throws -> (UInt8, Data) {
        let host = DriveWireHost(delegate: self)
        do {
            try host.insertVirtualDisk(driveNumber: 0, imagePath: "/Users/boisy/test.dsk")
            var readTransaction = Data([host.OPREADEX, UInt8(drive), UInt8((lsn & 0xFF000) >> 16), UInt8((lsn & 0xFF00) >> 8), UInt8(lsn & 0xFF)])
            expectation = XCTestExpectation(description: "Waiting for sector data")
            host.send(data: &readTransaction)
            let _ = XCTWaiter.wait(for: [expectation!], timeout: 5.0)
            let sector = read(bytes: 256)
            // respond with checksum
            let myChecksum = host.compute16BitChecksum(data: sector)
            var checksum = Data([UInt8(myChecksum / 256), UInt8(myChecksum & 255)])
            expectation = XCTestExpectation(description: "Waiting for error response")
            host.send(data: &checksum)
            let _ = XCTWaiter.wait(for: [expectation!], timeout: 5.0)
            let errorCode = read(bytes: 1)[0]
            return (errorCode, sector)
        } catch {
            return (244, Data())

        }
    }

    func READ(drive : Int, lsn : Int) throws -> (UInt8, Data) {
        var sector = Data(repeating: 0, count: 256)
        let host = DriveWireHost(delegate: self)
        do {
            try host.insertVirtualDisk(driveNumber: 0, imagePath: "/Users/boisy/test.dsk")
            var readTransaction = Data([host.OPREAD, UInt8(drive), UInt8((lsn & 0xFF000) >> 16), UInt8((lsn & 0xFF00) >> 8), UInt8(lsn & 0xFF)])
            expectation = XCTestExpectation(description: "Waiting for response code data")
            host.send(data: &readTransaction)
            let _ = XCTWaiter.wait(for: [expectation!], timeout: 5.0)
            let errorCode = read(bytes: 1)[0]
            if errorCode == 0 {
                let checksumBytes = read(bytes: 2)
                let checksum = UInt16(checksumBytes[0]) * 256 + UInt16(checksumBytes[1])
                sector = read(bytes: 256)
            }
            return (errorCode, sector)
        } catch {
            return (244, Data())
        }
    }

    func testSerialChannelOpensAndCloses() throws {
        var open = Data([host!.OPSERINIT, 1])
        host!.send(data: &open)
        XCTAssertTrue(host!.isChannelOpen(1))
        var close = Data([host!.OPSERTERM, 1])
        host!.send(data: &close)
        XCTAssertFalse(host!.isChannelOpen(1))
    }

    func testSerialSetStatOpensAndCloses() throws {
        var open = Data([host!.OPSERSETSTAT, 2, 0x29])
        host!.send(data: &open)
        XCTAssertTrue(host!.isChannelOpen(2))
        var close = Data([host!.OPSERSETSTAT, 2, 0x2A])
        host!.send(data: &close)
        XCTAssertFalse(host!.isChannelOpen(2))
    }

    func testSerialSetStatComStConsumes29Bytes() throws {
        // SS.ComSt carries a 26-byte device descriptor. If the processor
        // miscounts, the trailing SERINIT below lands mid-stream and channel 3
        // never opens -- this asserts the stream stays in sync.
        var payload = Data([host!.OPSERSETSTAT, 0, 0x28])
        payload.append(Data(repeating: 0xAA, count: 26))
        payload.append(Data([host!.OPSERINIT, 3]))
        host!.send(data: &payload)
        XCTAssertTrue(host!.isChannelOpen(3))
    }

    var channelData : [UInt8: Data] = [:]

    func channelDataAvailable(host: DriveWireHost, channel: UInt8, data: Data) {
        channelData[channel, default: Data()].append(data)
    }

    func testSerialWriteDeliversByte() throws {
        var s = Data([host!.OPSERINIT, 1, host!.OPSERWRITE, 1, 0x42])
        host!.send(data: &s)
        XCTAssertEqual(channelData[1], Data([0x42]))
    }

    func testSerialWriteMultipleDeliversBytes() throws {
        var s = Data([host!.OPSERINIT, 5, host!.OPSERWRITEM, 5, 3, 0x41, 0x42, 0x43])
        host!.send(data: &s)
        XCTAssertEqual(channelData[5], Data([0x41, 0x42, 0x43]))
    }

    func testFastwriteDeliversByte() throws {
        var s = Data([host!.OPSERINIT, 0, 0x80, 0x43])
        host!.send(data: &s)
        XCTAssertEqual(channelData[0], Data([0x43]))
    }

    func testFastwriteSplitAcrossSends() throws {
        // The opcode and its operand arriving in separate reads must not desync.
        var first = Data([host!.OPSERINIT, 0, 0x80])
        host!.send(data: &first)
        var second = Data([0x44])
        host!.send(data: &second)
        XCTAssertEqual(channelData[0], Data([0x44]))
    }

    func testWriteToClosedChannelIsDropped() throws {
        var s = Data([host!.OPSERWRITE, 9, 0x42])
        host!.send(data: &s)
        XCTAssertNil(channelData[9])
    }

    func testSerialReadNothingWaiting() throws {
        var s = Data([host!.OPSERREAD])
        host!.send(data: &s)
        XCTAssertEqual(read(bytes: 2), Data([0, 0]))
    }

    func testSerialReadSingleByte() throws {
        var open = Data([host!.OPSERINIT, 1])
        host!.send(data: &open)
        host!.writeToChannel(Data([0x21]), channel: 1)
        var s = Data([host!.OPSERREAD])
        host!.send(data: &s)
        // Response byte 1 = channel + 1, byte 2 = the data byte.
        XCTAssertEqual(read(bytes: 2), Data([2, 0x21]))
    }

    func testSerialReadBulkThenReadM() throws {
        var open = Data([host!.OPSERINIT, 1])
        host!.send(data: &open)
        host!.writeToChannel(Data("mdir\r".utf8), channel: 1)
        var poll = Data([host!.OPSERREAD])
        host!.send(data: &poll)
        // Byte 1 = channel + 17, byte 2 = waiting count.
        XCTAssertEqual(read(bytes: 2), Data([18, 5]))
        var readm = Data([host!.OPSERREADM, 1, 5])
        host!.send(data: &readm)
        XCTAssertEqual(read(bytes: 5), Data("mdir\r".utf8))
        var poll2 = Data([host!.OPSERREAD])
        host!.send(data: &poll2)
        XCTAssertEqual(read(bytes: 2), Data([0, 0]))
    }

    func testSerialReadMOverRequestReturnsAvailable() throws {
        var open = Data([host!.OPSERINIT, 1])
        host!.send(data: &open)
        host!.writeToChannel(Data([0x01]), channel: 1)
        var readm = Data([host!.OPSERREADM, 1, 200])
        host!.send(data: &readm)
        XCTAssertEqual(responseData, Data([0x01]))
    }

    func testHostCloseReportedInPoll() throws {
        var open = Data([host!.OPSERINIT, 4])
        host!.send(data: &open)
        host!.closeChannel(4)
        var poll = Data([host!.OPSERREAD])
        host!.send(data: &poll)
        // Byte 1 = 16 (status), byte 2 high nibble 0 = closed, low nibble = channel.
        XCTAssertEqual(read(bytes: 2), Data([16, 4]))
        XCTAssertFalse(host!.isChannelOpen(4))
    }

    func testWriteToChannelBeforeOpenIsBuffered() throws {
        // Host-side input is deliberate type-ahead: bytes queued before the
        // guest opens the channel are delivered once its polls begin.
        host!.writeToChannel(Data([0x55]), channel: 1)
        var open = Data([host!.OPSERINIT, 1])
        host!.send(data: &open)
        var poll = Data([host!.OPSERREAD])
        host!.send(data: &poll)
        XCTAssertEqual(read(bytes: 2), Data([2, 0x55]))
    }

    func testHostCloseOfUnopenedChannelIsIgnored() throws {
        host!.closeChannel(9)
        var poll = Data([host!.OPSERREAD])
        host!.send(data: &poll)
        XCTAssertEqual(read(bytes: 2), Data([0, 0]))
    }

    func testSerialReadRoundRobinFairness() throws {
        var open = Data([host!.OPSERINIT, 1, host!.OPSERINIT, 2])
        host!.send(data: &open)
        host!.writeToChannel(Data([0x41]), channel: 1)
        host!.writeToChannel(Data([0x42]), channel: 2)
        var poll = Data([host!.OPSERREAD])
        host!.send(data: &poll)
        let first = read(bytes: 2)
        var poll2 = Data([host!.OPSERREAD])
        host!.send(data: &poll2)
        let second = read(bytes: 2)
        XCTAssertEqual(Set([first[0], second[0]]), Set([UInt8(2), UInt8(3)]))
    }

    func testTCPServerLoopback() throws {
        let driver = DriveWireTCPServerDriver(beckerPort: 62504, channelPortBase: 62810, bridgedChannelCount: 2)
        driver.logging = false
        try driver.start()

        let guest = NWConnection(host: "127.0.0.1", port: 62504, using: .tcp)
        let responded = XCTestExpectation(description: "OP_DWINIT answered over TCP")
        guest.stateUpdateHandler = { state in
            if case .ready = state {
                guest.send(content: Data([0x5A, 0x01]), completion: .contentProcessed { _ in })
                guest.receive(minimumIncompleteLength: 1, maximumLength: 16) { content, _, _, _ in
                    XCTAssertEqual(content?.first, 0xFF)
                    responded.fulfill()
                }
            }
        }
        guest.start(queue: .global())
        wait(for: [responded], timeout: 5.0)
        guest.cancel()
        driver.stop()
    }

    func testSerialWriteMBootNoiseStaysInSync() throws {
        // The NitrOS-9 EOU boot emits bare $64 $00 pairs (SERWRITEM naming
        // never-opened channel 0, with no count or payload). Servers must
        // consume exactly 2 bytes for these; reading a count byte desyncs
        // the whole stream on every boot.
        var noise = Data()
        for _ in 0..<20 {
            noise.append(contentsOf: [host!.OPSERWRITEM, 0])
        }
        noise.append(contentsOf: [host!.OPSERINIT, 1])
        host!.send(data: &noise)
        XCTAssertTrue(host!.isChannelOpen(1))
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        measure {
            // Put the code you want to measure the time of here.
        }
    }

}
