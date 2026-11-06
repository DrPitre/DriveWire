import Foundation
import XCTest
import DriveWireCore

final class RFMReceiveBoundaryTests: XCTestCase {
    private final class Capture: DriveWireDelegate {
        var parts: [(Data, Bool)] = []
        func dataAvailable(host: DriveWireHost, data: Data) { parts.append((data, false)) }
        func dataAvailableAfterReceiveBoundary(host: DriveWireHost, data: Data) { parts.append((data, true)) }
        func transactionCompleted(opCode: UInt8) {}
    }

    func testSplitRepliesMarkOnlyGuestReceiveBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Y0"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("hello\r".utf8)
        try payload.write(to: root.appendingPathComponent("Y0/hello"))
        let capture = Capture()
        let host = DriveWireHost(delegate: capture)
        host.rfmRootPath = root.path
        func request(_ bytes: [UInt8]) {
            capture.parts.removeAll()
            var data = Data(bytes)
            host.send(data: &data)
        }
        request([0xd6, 0x14, 1, 1, 0, 0, 0, 0x81] + Array("/Y0\r".utf8))
        XCTAssertEqual(capture.parts.map { $0.0.count }, [1, 3])
        XCTAssertEqual(capture.parts.map { $0.1 }, [false, true])
        XCTAssertEqual(capture.parts.first?.0, Data([0]))
        request([0xd6, 0x14, 1, 1, 0, 0, 0, 0x81] + Array("/missing\r".utf8))
        XCTAssertEqual(capture.parts.map { $0.0 }, [Data([216])])
        XCTAssertEqual(capture.parts.map { $0.1 }, [false])
        for opcode: UInt8 in [7, 9] {
            request([0xd6, 0x12, 1, 1, 0, 0, 0, 1] + Array("/Y0/hello\r".utf8))
            XCTAssertEqual(capture.parts.map { $0.0 }, [Data([0])])
            request([0xd6, opcode, 1, 0, 32])
            XCTAssertEqual(capture.parts.map { $0.0 }, [Data([0, 6]), payload])
            XCTAssertEqual(capture.parts.map { $0.1 }, [false, true])
            request([0xd6, opcode, 1, 0, 32])
            XCTAssertEqual(capture.parts.map { $0.0 }, [Data([0, 0])])
            XCTAssertEqual(capture.parts.map { $0.1 }, [false])
            request([0xd6, 0x0d, 1])
        }
    }
}
