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
        // Must be non-zero: OP_DWINIT's own comment records that a zero here
        // makes the NitrOS-9 driver take the host for a DW3 server and disable
        // every DW4 extension, the virtual serial poller included. The 0x00 this
        // expected predates that.
        let expectedResult = 0xFF
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

    // Exercise complete wire transactions so framing and per-handle state are
    // checked along with the directory resolver and live file contents.
    private func rfmRequest(_ operation: UInt8, _ payload: [UInt8]) -> Data {
        expectation = nil
        responseData.removeAll()
        var packet = Data([host!.OPRFM, operation] + payload)
        host!.send(data: &packet)
        return responseData
    }

    private func rfmPathRequest(_ operation: UInt8, _ path: String,
                                pid: UInt8, owner: UInt8, mode: UInt8, number: UInt8 = 1) -> Data {
        rfmRequest(operation, [number, pid, owner, mode] + Array(path.utf8) + [13])
    }

    private func rfmFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for path in ["y0/data/child", "y0/bin/child"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(path),
                                                    withIntermediateDirectories: true)
        }
        host!.rfmRootPath = folder.path
        return folder
    }

    private func contextPath(_ op: UInt8, _ path: String, pid: UInt8,
                             cookie: Data, mode: UInt8, number: UInt8 = 1) -> Data {
        rfmRequest(op | 0x10, [number, pid] + Array(cookie) + [mode] + Array(path.utf8) + [13])
    }

    func testRFMForkCookiesSurviveParentChangesBeforeChildFirstIO() throws {
        let folder = try rfmFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let zero = Data([0, 0, 0])
        for mode: UInt8 in [0x81, 0x84] {
            let base = mode == 0x81 ? "/y0/data" : "/y0/bin"
            let reply = contextPath(4, base, pid: 4, cookie: zero, mode: mode)
            XCTAssertEqual(reply.count, 4)
            XCTAssertEqual(reply.first, 0)
            let inherited = Data(reply.dropFirst()) // exactly what F$Fork copies
            let changed = contextPath(4, "child", pid: 4, cookie: inherited, mode: mode)
            XCTAssertEqual(changed.first, 0)
            XCTAssertNotEqual(Data(changed.dropFirst()), inherited)
            // Child has made no request before the parent's change.
            XCTAssertEqual(contextPath(2, ".", pid: 5, cookie: inherited, mode: mode), Data([0]))
            XCTAssertEqual(host!.rfmPaths[1]?.pathname, base)
            _ = rfmRequest(13, [1])
            // Child changes independently; parent and sibling still hold their cookies.
            XCTAssertEqual(contextPath(4, "child", pid: 5, cookie: inherited, mode: mode).first, 0)
            XCTAssertEqual(contextPath(2, ".", pid: 4, cookie: Data(changed.dropFirst()), mode: mode), Data([0]))
            XCTAssertEqual(host!.rfmPaths[1]?.pathname, base + "/child")
            _ = rfmRequest(13, [1])
            XCTAssertEqual(contextPath(2, ".", pid: 5, cookie: inherited, mode: mode), Data([0]))
            XCTAssertEqual(host!.rfmPaths[1]?.pathname, base)
            _ = rfmRequest(13, [1])
            XCTAssertEqual(contextPath(4, "missing", pid: 5, cookie: inherited, mode: mode), Data([216]))
            XCTAssertEqual(contextPath(2, ".", pid: 5, cookie: Data([255,255,255]), mode: mode), Data([216]))
            XCTAssertEqual(contextPath(2, ".", pid: 5, cookie: zero, mode: mode), Data([216]))
        }
    }

    func testRFMDeviceRootParentStaysOnDeviceDuringBoot() throws {
        let folder = try rfmFolder()
        defer { host!.resetRFMState(); try? FileManager.default.removeItem(at: folder) }
        let cmds = folder.appendingPathComponent("DD/CMDS")
        try FileManager.default.createDirectory(at: cmds, withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: cmds.appendingPathComponent("grfdrv"))
        let zero = Data([0,0,0])
        let reply = contextPath(4, "/DD", pid: 1, cookie: zero, mode: 0x85)
        XCTAssertEqual(reply.first, 0)
        let cookie = Data(reply.dropFirst())
        for path in ["../CMDS/grfdrv", ".../CMDS/grfdrv", "../../CMDS/grfdrv"] {
            XCTAssertEqual(contextPath(2, path, pid: 1, cookie: cookie, mode: 4), Data([0]), path)
            XCTAssertEqual(rfmRequest(7, [1,0,3]), Data([0,3,1,2,3]))
            _ = rfmRequest(13,[1])
        }
        // Root chd .. must return a usable cookie for DD, not the export root.
        let parent = contextPath(4, "..", pid: 1, cookie: cookie, mode: 0x85)
        XCTAssertEqual(parent, reply)
        XCTAssertEqual(contextPath(2, "CMDS/grfdrv", pid: 2, cookie: Data(parent.dropFirst()), mode: 4), Data([0]))
        _ = rfmRequest(13,[1])
        XCTAssertEqual(contextPath(3, "../created", pid: 1, cookie: cookie, mode: 3), Data([0]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("DD/created").path))
        XCTAssertEqual(contextPath(5, "../created", pid: 1, cookie: cookie, mode: 2), Data([0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("DD/created").path))
    }

    func testRFMOwnerContextOverridesReusedPID() {
        host!.rfmCurrentDir = [4: "/y0/data", 5: "/y0/stale"]
        host!.rfmCurrentExecDir = [4: "/y0/bin", 5: "/y0/stale-bin"]
        XCTAssertEqual(host!.resolveRFMPathname("marker", processID: 5, parentProcessID: 4), "/y0/data/marker")
        XCTAssertEqual(host!.resolveRFMPathname("tool", processID: 5, parentProcessID: 4, isExec: true), "/y0/bin/tool")
        XCTAssertEqual(host!.resolveRFMPathname("/y0/absolute", processID: 5, parentProcessID: 4), "/y0/absolute")
        // Preserve the fallback used by callers without a known owner context.
        XCTAssertEqual(host!.resolveRFMPathname("marker", processID: 5, parentProcessID: 0), "/y0/stale/marker")
    }

    func testRFMSelfOwnerDotAndRelativeDirectoryChanges() throws {
        let folder = try rfmFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for (mode, base) in [(UInt8(0x81), "/y0/data"), (UInt8(0x84), "/y0/bin")] {
            XCTAssertEqual(rfmPathRequest(4, base, pid: 7, owner: 0, mode: mode), Data([0]))
            for path in [".", "child", "..", "./child", ".."] {
                XCTAssertEqual(rfmPathRequest(4, path, pid: 7, owner: 7, mode: mode), Data([0]), path)
            }
            let actual = mode == 0x81 ? host!.rfmCurrentDir[7] : host!.rfmCurrentExecDir[7]
            XCTAssertEqual(actual, base)
            XCTAssertEqual(rfmPathRequest(4, "missing", pid: 7, owner: 7, mode: mode), Data([216]))
            let afterError = mode == 0x81 ? host!.rfmCurrentDir[7] : host!.rfmCurrentExecDir[7]
            XCTAssertEqual(afterError, base)
        }
        XCTAssertEqual(host!.rfmCurrentDir[7], "/y0/data")
        XCTAssertEqual(host!.rfmCurrentExecDir[7], "/y0/bin")
    }

    func testRFMDirectoryContextSnapshotAndCombinedMode() throws {
        let folder = try rfmFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(rfmPathRequest(4, "/y0/data", pid: 4, owner: 0, mode: 0x81), Data([0]))
        XCTAssertEqual(rfmPathRequest(4, ".", pid: 5, owner: 4, mode: 0x81), Data([0]))
        XCTAssertEqual(host!.rfmCurrentDir[5], "/y0/data")
        XCTAssertEqual(rfmPathRequest(4, "child", pid: 4, owner: 4, mode: 0x81), Data([0]))
        XCTAssertEqual(host!.resolveRFMPathname("marker", processID: 8, parentProcessID: 5), "/y0/data/marker")
        XCTAssertEqual(rfmPathRequest(4, "/y0/bin", pid: 7, owner: 0, mode: 0x85), Data([0]))
        XCTAssertEqual(host!.rfmCurrentDir[7], "/y0/bin")
        XCTAssertEqual(host!.rfmCurrentExecDir[7], "/y0/bin")
    }

    func testRFMLiveReadWriteSizeEOFAndIndependentHandles() throws {
        let folder = try rfmFolder()
        defer {
            host!.resetRFMState()
            try? FileManager.default.removeItem(at: folder)
        }
        XCTAssertEqual(rfmPathRequest(1, "/y0/file", pid: 9, owner: 0, mode: 3), Data([0]))
        XCTAssertTrue(rfmRequest(8, [1, 0, 3] + Array("ABC".utf8)).isEmpty)
        XCTAssertEqual(rfmRequest(11, [1, 2]), Data([0, 0, 0, 3]))
        XCTAssertEqual(rfmRequest(6, [1, 0, 0, 0, 0]), Data([0]))
        XCTAssertEqual(rfmRequest(11, [1, 6]), Data([0]))
        XCTAssertEqual(rfmRequest(7, [1, 0, 3]), Data([0, 3] + Array("ABC".utf8)))
        XCTAssertEqual(rfmRequest(11, [1, 6]), Data([211]))
        XCTAssertEqual(rfmPathRequest(2, "/y0/file", pid: 9, owner: 0, mode: 1, number: 2), Data([0]))
        XCTAssertEqual(rfmRequest(6, [1, 0, 0, 0, 1]), Data([0]))
        XCTAssertTrue(rfmRequest(8, [1, 0, 1, 90]).isEmpty)
        XCTAssertEqual(rfmRequest(7, [2, 0, 3]), Data([0, 3] + Array("AZC".utf8)))
        XCTAssertEqual(rfmRequest(6, [1, 0, 0, 0, 5]), Data([0]))
        XCTAssertTrue(rfmRequest(8, [1, 0, 1, 81]).isEmpty)
        XCTAssertEqual(rfmRequest(11, [2, 6]), Data([0])) // other handle sees growth
        XCTAssertEqual(rfmRequest(11, [2, 2]), Data([0, 0, 0, 6]))
        XCTAssertEqual(rfmRequest(7, [2, 0, 3]), Data([0, 3, 0, 0, 81]))
        XCTAssertEqual(rfmRequest(6, [1, 0, 0, 0, 8]), Data([0]))
        XCTAssertTrue(rfmRequest(8, [1, 0, 0]).isEmpty) // empty write must not extend
        XCTAssertEqual(rfmRequest(11, [1, 2]), Data([0, 0, 0, 6]))
        let fd = rfmRequest(11, [2, 15, 0, 16])
        XCTAssertEqual(fd.count, 16)
        XCTAssertEqual(Data(fd[9..<13]), Data([0, 0, 0, 6]))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("y0/file")), Data([65, 90, 67, 0, 0, 81]))
    }

    func testRFMLiveReadLineKeepsCursorAndTextTranslation() throws {
        let folder = try rfmFolder()
        defer {
            host!.resetRFMState()
            try? FileManager.default.removeItem(at: folder)
        }
        XCTAssertEqual(rfmPathRequest(1, "/y0/lines", pid: 9, owner: 0, mode: 3), Data([0]))
        XCTAssertTrue(rfmRequest(10, [1, 0, 3, 65, 13, 90]).isEmpty)
        XCTAssertTrue(rfmRequest(10, [1, 0, 2, 66, 13]).isEmpty)
        XCTAssertEqual(rfmRequest(11, [1, 2]), Data([0, 0, 0, 4]))
        XCTAssertEqual(rfmRequest(6, [1, 0, 0, 0, 0]), Data([0]))
        XCTAssertEqual(rfmRequest(9, [1, 0, 16]), Data([0, 2, 65, 13]))
        XCTAssertEqual(rfmRequest(11, [1, 5]), Data([0, 0, 0, 2]))
        XCTAssertEqual(rfmRequest(9, [1, 0, 16]), Data([0, 2, 66, 13]))
        XCTAssertEqual(rfmRequest(9, [1, 0, 16]), Data([0, 0]))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("y0/lines")), Data([65, 10, 66, 10]))
    }

}
