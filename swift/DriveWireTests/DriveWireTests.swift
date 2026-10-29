//
//  DriveWireSwiftTests.swift
//  DriveWireSwiftTests
//
//  Created by Boisy Pitre on 9/29/23.
//

import XCTest

final class DriveWireSwiftTests: XCTestCase, DriveWireDelegate {
    var host : DriveWireHost?

    func transactionCompleted(opCode: UInt8) {
    }
    
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
        host = DriveWireHost(delegate: self)
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testInsert() throws {
        do {
            try host!.insertVirtualDisk(driveNumber: 0, imagePath: "/Users/boisy/test.dsk")
            try host!.insertVirtualDisk(driveNumber: 0, imagePath: "/Users/boisy/test.dsk")
        } catch {
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
        let expectedResult = 0x00
        let actualResult = read(bytes: 1)[0]
        XCTAssert(actualResult == expectedResult, "Error: result should be \(expectedResult), but was \(actualResult)")
    }

    func testTIME() throws {
        var s = Data([host!.OPTIME])
        host!.send(data: &s)
    }

    func testTelnetServiceOptionParsing() throws {
        XCTAssertFalse(DriveWireHost.VirtualSerialTCPServiceOptions().telnet)
        XCTAssertTrue(DriveWireHost.VirtualSerialTCPServiceOptions(arguments: ["TELNET", "protect", "banner"]).telnet)
    }

    func testTelnetInitialNegotiationRequestsCharacterMode() throws {
        XCTAssertEqual(
            DriveWireHost.TelnetCodec.initialNegotiation,
            Data([255, 251, 1, 255, 251, 3, 255, 253, 3, 255, 254, 34])
        )
    }

    func testTelnetCodecFiltersCommandsAndNormalizesInput() throws {
        var codec = DriveWireHost.TelnetCodec()

        let first = codec.decode(Data([0x68, 0x69, 255, 253, 1, 0x0D]))
        XCTAssertEqual(first.payload, Data([0x68, 0x69, 0x0D]))
        XCTAssertTrue(first.replies.isEmpty)

        let second = codec.decode(Data([0x0A, 255, 251, 31, 255, 255]))
        XCTAssertEqual(second.payload, Data([0xFF]))
        XCTAssertEqual(second.replies, Data([255, 254, 31]))
    }

    func testTelnetCodecConsumesSubnegotiationAcrossReads() throws {
        var codec = DriveWireHost.TelnetCodec()

        let first = codec.decode(Data([0x41, 255, 250, 24, 1, 255]))
        XCTAssertEqual(first.payload, Data([0x41]))
        XCTAssertTrue(first.replies.isEmpty)

        let second = codec.decode(Data([240, 0x42]))
        XCTAssertEqual(second.payload, Data([0x42]))
        XCTAssertTrue(second.replies.isEmpty)
    }

    func testTelnetCodecEscapesOutgoingIAC() throws {
        let codec = DriveWireHost.TelnetCodec()
        XCTAssertEqual(codec.encode(Data([0x41, 0xFF, 0x42])), Data([0x41, 0xFF, 0xFF, 0x42]))
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

    func testPrinterPlainTextConvertsLineEndingsAndDropsControlCodes() throws {
        let job = Data([0x41, 0x0D, 0x42, 0x0D, 0x0A, 0x43, 0x0A, 0x09, 0x1B, 0x45, 0x0C, 0x44, 0x80, 0x0D])
        XCTAssertEqual(DriveWirePrintJob.plainText(from: job), Data("A\nB\nC\n\tE\u{0C}D\n".utf8))
    }

    func testPrinterSaveUsesUniqueTimestampedNames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let date = Date(timeIntervalSince1970: 0)

        let first = try DriveWirePrintJob.save(Data("one".utf8), toFolder: folder, format: .text, date: date)
        let second = try DriveWirePrintJob.save(Data("two".utf8), toFolder: folder, format: .text, date: date)
        let raw = try DriveWirePrintJob.save(Data([0x1B]), toFolder: folder, format: .raw, date: date)

        XCTAssertTrue(first.lastPathComponent.hasPrefix("DriveWire-print-"))
        XCTAssertEqual(first.pathExtension, "txt")
        XCTAssertEqual(second.lastPathComponent, first.deletingPathExtension().lastPathComponent + "-2.txt")
        XCTAssertEqual(raw.pathExtension, "prn")
        XCTAssertEqual(try Data(contentsOf: first), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("two".utf8))
    }

    func testPrinterLPArguments() throws {
        XCTAssertEqual(
            DriveWireSystemPrinter.lpArguments(printerName: "", format: .text),
            ["-t", "DriveWire", "-o", "document-format=text/plain"]
        )
        XCTAssertEqual(
            DriveWireSystemPrinter.lpArguments(printerName: "Epson_FX", format: .raw),
            ["-d", "Epson_FX", "-t", "DriveWire", "-o", "raw"]
        )
    }

    func testPrinterSubmitReportsUnknownPrinter() throws {
        let done = XCTestExpectation(description: "lp finished")
        var outcome: Result<String, Error>?
        DriveWireSystemPrinter.submit(Data("x".utf8), printerName: "DriveWire_No_Such_Printer", format: .text) { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        guard case .failure(let error) = try XCTUnwrap(outcome) else {
            return XCTFail("lp accepted a job for a printer that does not exist")
        }
        XCTAssertFalse(error.localizedDescription.isEmpty)
    }

    func testPrinterFlushSavesJobToFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: folder) }
        var settings = DriveWirePrinterOutputSettings()
        settings.saveToFolder = true
        settings.folderPath = folder
        host!.printerOutputSettingsProvider = { settings }

        for byte in Array("HI\r".utf8) {
            var s = Data([host!.OPPRINT, byte])
            host!.send(data: &s)
        }
        var flush = Data([host!.OPPRINTFLUSH])
        host!.send(data: &flush)

        let path = try XCTUnwrap(host!.printerStatus.lastOutputPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("HI\n".utf8))
        XCTAssertEqual(host!.printerStatus.flushedJobs, 1)
        XCTAssertEqual(host!.printerStatus.pendingBytes, 0)
        XCTAssertEqual(host!.printerStatus.previewText, "HI\r")
    }

    func testPrinterFlushWithoutOutputSettingsSavesNothing() throws {
        host!.printerOutputSettingsProvider = { DriveWirePrinterOutputSettings() }

        var s = Data([host!.OPPRINT, 0x41])
        host!.send(data: &s)
        var flush = Data([host!.OPPRINTFLUSH])
        host!.send(data: &flush)

        XCTAssertNil(host!.printerStatus.lastOutputPath)
        XCTAssertEqual(host!.printerStatus.flushedJobs, 1)
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        measure {
            // Put the code you want to measure the time of here.
        }
    }

}
