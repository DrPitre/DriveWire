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
    public var lastPrintedTo: String?
    public var previewText: String = ""
    public var lastError: String?
}

/// Where completed printer jobs go when the guest flushes the printer.
public struct DriveWirePrinterOutputSettings: Equatable {
    public enum Format: String, CaseIterable, Identifiable {
        /// Line endings converted to the host's, control codes other than tab
        /// and form feed dropped
        case text
        /// The guest's bytes unchanged, for printers that understand its codes
        case raw

        public var id: String { rawValue }
    }

    public var saveToFolder = false
    public var folderPath = Self.defaultFolderPath
    public var sendToPrinter = false
    /// The CUPS destination name, or empty for the system default printer.
    public var printerName = ""
    public var format = Format.text

    public static let defaultFolderPath = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/DriveWire Printouts")

    public enum Keys {
        public static let saveToFolder = "printerSaveToFolder"
        public static let folderPath = "printerFolderPath"
        public static let sendToPrinter = "printerSendToPrinter"
        public static let printerName = "printerName"
        public static let format = "printerFormat"
    }

    public init() {
    }

    public init(userDefaults: UserDefaults) {
        saveToFolder = userDefaults.bool(forKey: Keys.saveToFolder)
        if let path = userDefaults.string(forKey: Keys.folderPath), !path.isEmpty {
            folderPath = path
        }
        sendToPrinter = userDefaults.bool(forKey: Keys.sendToPrinter)
        printerName = userDefaults.string(forKey: Keys.printerName) ?? ""
        format = Format(rawValue: userDefaults.string(forKey: Keys.format) ?? "") ?? .text
    }

    public static func current() -> DriveWirePrinterOutputSettings {
        DriveWirePrinterOutputSettings(userDefaults: .standard)
    }
}

enum DriveWirePrintJob {
    /// Converts guest printer bytes to host text: CR, LF and CR LF each end a
    /// line, tab and form feed are kept, and other control codes are dropped.
    static func plainText(from data: Data) -> Data {
        var text = Data()
        text.reserveCapacity(data.count)
        var previousByteWasCarriageReturn = false
        for byte in data {
            switch byte {
            case 0x0D:
                text.append(0x0A)
                previousByteWasCarriageReturn = true
                continue
            case 0x0A:
                if !previousByteWasCarriageReturn {
                    text.append(0x0A)
                }
            case 0x09, 0x0C, 0x20...0x7E:
                text.append(byte)
            default:
                break
            }
            previousByteWasCarriageReturn = false
        }
        return text
    }

    /// Writes a job to a new, timestamped file in `folder`, creating the folder if needed.
    static func save(_ data: Data, toFolder folder: String, format: DriveWirePrinterOutputSettings.Format, date: Date = Date()) throws -> URL {
        let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stem = "DriveWire-print-" + formatter.string(from: date)
        let fileExtension = format == .raw ? "prn" : "txt"

        var url = folderURL.appendingPathComponent(stem).appendingPathExtension(fileExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folderURL.appendingPathComponent("\(stem)-\(suffix)").appendingPathExtension(fileExtension)
            suffix += 1
        }

        try data.write(to: url, options: .withoutOverwriting)
        return url
    }
}

/// Sends jobs to macOS printers through CUPS.
enum DriveWireSystemPrinter {
    static let lpPath = "/usr/bin/lp"
    static let lpstatPath = "/usr/bin/lpstat"

    /// The CUPS destination names, as `lpstat -e` lists them.
    static func availablePrinters() -> [String] {
        guard let output = try? run(lpstatPath, arguments: ["-e"]), output.status == 0 else {
            return []
        }
        return String(decoding: output.standardOutput, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// The `lp` arguments for a job. Raw jobs bypass the CUPS filters so the
    /// printer gets the guest's bytes; text jobs are laid out by CUPS.
    static func lpArguments(printerName: String, format: DriveWirePrinterOutputSettings.Format) -> [String] {
        var arguments: [String] = []
        if !printerName.isEmpty {
            arguments += ["-d", printerName]
        }
        arguments += ["-t", "DriveWire"]
        switch format {
        case .raw:
            arguments += ["-o", "raw"]
        case .text:
            arguments += ["-o", "document-format=text/plain"]
        }
        return arguments
    }

    /// Submits a job without blocking the caller, then reports `lp`'s result on the main queue.
    static func submit(_ data: Data, printerName: String, format: DriveWirePrinterOutputSettings.Format, completion: @escaping (Result<String, Error>) -> Void) {
        let arguments = lpArguments(printerName: printerName, format: format)
        DispatchQueue.global(qos: .utility).async {
            let result: Result<String, Error>
            do {
                let output = try run(lpPath, arguments: arguments, input: data)
                let message = String(decoding: output.standardOutput + output.standardError, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if output.status == 0 {
                    result = .success(message)
                } else {
                    result = .failure(PrintError.lpFailed(message.isEmpty ? "lp exited with status \(output.status)" : message))
                }
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    enum PrintError: LocalizedError {
        case lpFailed(String)

        var errorDescription: String? {
            switch self {
            case .lpFailed(let message):
                return message
            }
        }
    }

    private struct Output {
        let status: Int32
        let standardOutput: Data
        let standardError: Data
    }

    private static func run(_ path: String, arguments: [String], input: Data? = nil) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()

        // Feed the job on its own queue so a large job can't deadlock against
        // lp filling its output pipes
        DispatchQueue.global(qos: .utility).async {
            if let input {
                standardInput.fileHandleForWriting.write(input)
            }
            try? standardInput.fileHandleForWriting.close()
        }

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, standardOutput: outputData, standardError: errorData)
    }
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
    /// Ends the current job and returns its bytes, or `nil` if it was empty.
    func flush() -> Data?
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
    private var lastJob = Data()
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
        Self.preview(from: buffer.isEmpty ? lastJob : buffer)
    }

    func write(_ data: Data) {
        bytesReceived += data.count
        buffer.append(data)
        lastError = nil
    }

    func flush() -> Data? {
        guard !buffer.isEmpty else {
            lastFlushedAt = Date()
            return nil
        }

        flushedJobs += 1
        lastFlushedAt = Date()
        let job = buffer
        lastJob = job
        buffer.removeAll(keepingCapacity: true)
        lastError = nil
        return job
    }

    func reset() {
        buffer.removeAll(keepingCapacity: true)
        lastJob.removeAll()
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

    func flush() -> Data? {
        guard !text.isEmpty else {
            lastFlushedAt = Date()
            return nil
        }

        flushedJobs += 1
        lastFlushedAt = Date()
        let job = Data(text.utf8)
        text.removeAll(keepingCapacity: true)
        previousByteWasCarriageReturn = false
        lastError = nil
        return job
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
            lastOutputPath: printerOutputPath ?? printerBackend.lastOutputURL?.path,
            lastPrintedTo: printerLastPrintedTo,
            previewText: printerBackend.previewText,
            lastError: printerOutputError ?? printerBackend.lastError
        )
    }

    /// Saves and prints a completed job as the printer output settings ask.
    func deliverPrintJob(_ job: Data) {
        let settings = printerOutputSettingsProvider()
        guard settings.saveToFolder || settings.sendToPrinter else {
            return
        }

        printerOutputError = nil
        let payload = settings.format == .text ? DriveWirePrintJob.plainText(from: job) : job

        if settings.saveToFolder {
            do {
                let url = try DriveWirePrintJob.save(payload, toFolder: settings.folderPath, format: settings.format)
                printerOutputPath = url.path
                reportActivity("Printer job saved to \(url.path)")
            } catch {
                printerOutputError = "Could not save printer job: \(error.localizedDescription)"
                reportActivity(printerOutputError!, isError: true)
            }
        }

        if settings.sendToPrinter {
            let destination = settings.printerName.isEmpty ? "the default printer" : settings.printerName
            DriveWireSystemPrinter.submit(payload, printerName: settings.printerName, format: settings.format) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let message):
                    self.printerLastPrintedTo = destination
                    self.reportActivity("Printer job sent to \(destination)" + (message.isEmpty ? "" : ": \(message)"))
                case .failure(let error):
                    self.printerOutputError = "Could not print to \(destination): \(error.localizedDescription)"
                    self.reportActivity(self.printerOutputError!, isError: true)
                }
                self.refreshPrinterStatus()
            }
        }
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
        printerOutputPath = nil
        printerOutputError = nil
        printerLastPrintedTo = nil
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
        if let job = printerBackend.flush() {
            deliverPrintJob(job)
        }
        refreshPrinterStatus()
        reportActivity("Printer flush")
        delegate?.transactionCompleted(opCode: currentTransaction)

        return 1
    }
}
