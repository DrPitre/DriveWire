//
//  DriveWireHost+Printer.swift
//  DriveWireSwift
//

import Foundation

public struct DriveWirePrinterStatus: Equatable {
    public var state: String = "Idle"
    public var backendName: String = "Raw Memory Printer"
    public var bytesReceived: Int = 0
    public var pendingBytes: Int = 0
    public var flushedJobs: Int = 0
    public var lastFlushedAt: Date?
    public var lastOutputPath: String?
    public var previewText: String = ""
    public var lastError: String?
}

protocol DriveWirePrinterBackend: AnyObject {
    var name: String { get }
    var state: String { get }
    var bytesReceived: Int { get }
    var pendingBytes: Int { get }
    var flushedJobs: Int { get }
    var lastFlushedAt: Date? { get }
    var lastOutputURL: URL? { get }
    var previewText: String { get }
    var lastError: String? { get }

    func write(_ data: Data)
    func flush()
    func reset()
}

extension DriveWirePrinterBackend {
    func write(_ byte: UInt8) {
        write(Data([byte]))
    }
}

final class RawDriveWirePrinterBackend: DriveWirePrinterBackend {
    let name = "Raw Memory Printer"
    private var buffer = Data()
    private(set) var bytesReceived = 0
    private(set) var flushedJobs = 0
    private(set) var lastFlushedAt: Date?
    private(set) var lastOutputURL: URL?
    private(set) var lastError: String?

    var state: String {
        buffer.isEmpty ? "Idle" : "Receiving"
    }

    var pendingBytes: Int {
        buffer.count
    }

    var previewText: String {
        Self.preview(from: buffer)
    }

    func write(_ data: Data) {
        bytesReceived += data.count
        buffer.append(data)
        lastError = nil
    }

    func flush() {
        guard !buffer.isEmpty else {
            lastFlushedAt = Date()
            return
        }

        flushedJobs += 1
        lastFlushedAt = Date()
        buffer.removeAll(keepingCapacity: true)
        lastError = nil
    }

    func reset() {
        buffer.removeAll(keepingCapacity: true)
        bytesReceived = 0
        flushedJobs = 0
        lastFlushedAt = nil
        lastOutputURL = nil
        lastError = nil
    }

    private static func preview(from data: Data) -> String {
        guard !data.isEmpty else {
            return ""
        }

        let limited = data.prefix(4096)
        let scalars = limited.map { byte -> UInt8 in
            switch byte {
            case 0x09, 0x0A, 0x0D:
                return byte
            case 0x20...0x7E:
                return byte
            default:
                return 0x2E
            }
        }
        return String(bytes: scalars, encoding: .ascii) ?? ""
    }
}

final class TextDriveWirePrinterBackend: DriveWirePrinterBackend {
    let name = "Text Memory Printer"
    private var text = ""
    private var previousByteWasCarriageReturn = false
    private(set) var bytesReceived = 0
    private(set) var flushedJobs = 0
    private(set) var lastFlushedAt: Date?
    private(set) var lastOutputURL: URL?
    private(set) var lastError: String?

    var state: String {
        text.isEmpty ? "Idle" : "Receiving"
    }

    var pendingBytes: Int {
        text.utf8.count
    }

    var previewText: String {
        String(text.suffix(4096))
    }

    func write(_ data: Data) {
        bytesReceived += data.count
        for byte in data {
            append(byte)
        }
        lastError = nil
    }

    func flush() {
        guard !text.isEmpty else {
            lastFlushedAt = Date()
            return
        }

        flushedJobs += 1
        lastFlushedAt = Date()
        text.removeAll(keepingCapacity: true)
        previousByteWasCarriageReturn = false
        lastError = nil
    }

    func reset() {
        text.removeAll(keepingCapacity: true)
        previousByteWasCarriageReturn = false
        bytesReceived = 0
        flushedJobs = 0
        lastFlushedAt = nil
        lastOutputURL = nil
        lastError = nil
    }

    private func append(_ byte: UInt8) {
        switch byte {
        case 0x0D:
            text.append("\n")
            previousByteWasCarriageReturn = true
        case 0x0A:
            if !previousByteWasCarriageReturn {
                text.append("\n")
            }
            previousByteWasCarriageReturn = false
        case 0x09:
            text.append("\t")
            previousByteWasCarriageReturn = false
        case 0x20...0x7E:
            text.append(Character(UnicodeScalar(byte)))
            previousByteWasCarriageReturn = false
        default:
            previousByteWasCarriageReturn = false
        }
    }
}

extension DriveWireHost {
    func refreshPrinterStatus() {
        printerStatus = DriveWirePrinterStatus(
            state: printerBackend.state,
            backendName: printerBackend.name,
            bytesReceived: printerBackend.bytesReceived,
            pendingBytes: printerBackend.pendingBytes,
            flushedJobs: printerBackend.flushedJobs,
            lastFlushedAt: printerBackend.lastFlushedAt,
            lastOutputPath: printerBackend.lastOutputURL?.path,
            previewText: printerBackend.previewText,
            lastError: printerBackend.lastError
        )
    }

    func writePrinterData(_ data: Data) {
        guard !data.isEmpty else {
            return
        }

        printerBackend.write(data)
        reportActivity("Printer <- \(data.count) byte\(data.count == 1 ? "" : "s")", isFrequent: true)
        refreshPrinterStatus()
    }

    func resetPrinterState() {
        printerBackend.reset()
        refreshPrinterStatus()
    }

    func OP_PRINT(data : Data) -> Int {
        var result = 0
        let expectedCount = 2
        currentTransaction = OPPRINT

        if data.count >= expectedCount {
            resetState()
            result = expectedCount
            writePrinterData(Data([data[1]]))
            delegate?.transactionCompleted(opCode: currentTransaction)
        }

        return result
    }

    func OP_PRINTFLUSH(data : Data) -> Int {
        currentTransaction = OPPRINTFLUSH
        resetState()
        printerBackend.flush()
        refreshPrinterStatus()
        reportActivity("Printer flush")
        delegate?.transactionCompleted(opCode: currentTransaction)

        return 1
    }
}
