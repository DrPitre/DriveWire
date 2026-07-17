//
//  DriveWireHost.swift
//  DriveWireSwift
//
//  Created by Boisy Pitre on 9/29/23.
//

import Foundation
import AppKit
import AppIntents
import Network

/// An interface for receiving information from the DriveWire host.
public protocol DriveWireDelegate {
    /// Informs the delegate that there is available data.
    ///
    /// - Parameters:
    ///     - host: The DriveWire host object.
    ///     - data: The data available for the delegate.
    func dataAvailable(host : DriveWireHost, data : Data)
    
    /// Informs the delegate that a DriveWire transaction completed.
    func transactionCompleted(opCode : UInt8)
}

/// Statistical information about the host.
public struct DriveWireStatistics {
    var lastOpCode : UInt8 = 0
    var lastDriveNumber : UInt8 = 0
    var lastLSN : Int = 0
    var readCount : Int = 0
    var writeCount : Int = 0
    var reReadCount : Int = 0
    var reWriteCount : Int = 0
    var lastGetStat : UInt8 = 0
    var lastSetStat : UInt8 = 0
    var lastCheckSum : UInt16 = 0
    var lastError : UInt8 = 0
    var percentReadsOK = 0
    var percentWritesOK = 0
}

/// Errors that the DriveWire host throws.
public enum DriveWireHostError : Error {
    /// There's a virtual drive currently mounted in this slot.
    case driveAlreadyExists
    /// A virtual disk with that name doesn't exist.
    case nameNotFound
}

/// Error codes that the DriveWire protocol returns.
///
/// These error codes are identical to the errors that OS-9 uses.
public enum DriveWireProtocolError : Int {
    case E_NONE = 0x00
    case E_UNIT = 0xF0
    case E_CRC = 0xF4
}

public struct DriveWireVirtualWindow: Identifiable, Equatable {
    public let channel: UInt8
    public var title: String
    public var text: String
    public var isOpen: Bool

    public var id: UInt8 { channel }
    public var displayNumber: Int { Int(channel - 0x80) }
}

/// Manages communication with a DriveWire guest.
///
/// DriveWire is a connectivity standard that defines virtual disk drive, virtual printer, and virtual serial port services. A DriveWire *host* provides these services to a *guest*. Connectivity between the host and guest occurs over a physical connection, such as a serial cable. To the guest, it appears that the host's devices are local, when they are actually virtual.
///
/// The basis of communication between the guest and host is a documented set of uni- and bi-directional messages called *transactions*. A transaction is a series of one or more packets that the guest and host pass to each other.
///
@Observable
public class DriveWireHost : Codable {
    private static let maximumLogCharacters = 24_000
    private static let trimmedLogPrefix = "... older log entries trimmed ...\n"
    private static let emitConsoleOutput = false

    public var detailedOpcodeLogging = false

    private var logStorage = ""

    var log: String {
        get { logStorage }
        set { logStorage = Self.trimmedLog(from: newValue) }
    }

    init() {
        setupTransactions()
    }
    
    func reloadVirtualDrives() {
        for vd in virtualDrives {
            vd.reload()
        }
    }

    private static func trimmedLog(from value: String) -> String {
        guard value.count > maximumLogCharacters else {
            return value
        }

        let retainedCount = maximumLogCharacters - trimmedLogPrefix.count
        guard retainedCount > 0 else {
            return String(value.suffix(maximumLogCharacters))
        }

        return trimmedLogPrefix + value.suffix(retainedCount)
    }

    private func reportActivity(_ message: String, isFrequent: Bool = false, isError: Bool = false) {
        let shouldRecord = isError || !isFrequent || detailedOpcodeLogging
        if shouldRecord {
            logStorage = Self.trimmedLog(from: logStorage + message + "\n")
        }

        if isError || (Self.emitConsoleOutput && shouldRecord) {
            print(message)
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case virtualDrives
    }

    /// Statistical information about the host.
    public var statistics = DriveWireStatistics()
    private var serialBuffer = Data()
    public var delegate : DriveWireDelegate?
    /// The DriveWire transaction code of the transaction that the host is currently executing.
    ///
    /// Inspect this property to determine which transaction the host is currently executing.
    public var currentTransaction : UInt8 = 0
    public var currentSubTransaction : UInt8 = 0
    /// An array of virtual drives.
    public var virtualDrives : [VirtualDrive] = []
    public private(set) var virtualWindows: [DriveWireVirtualWindow] = []
    
    /// The guest's capability byte sent from ``OPDWINIT``.
    private var guestCapabilityByte : UInt8 = 0x00
    
    private struct DWOp {
        var opcode : UInt8 = 0
        var processor : ((Data) -> Int)
    }
    
    private var dwTransaction : Array<DWOp> = []
    private var validateWithCRC = false
    private var fastwriteChannel : UInt8 = 0
    private var processor : ((Data) -> Int)?
    private var openVirtualSerialChannels = Set<UInt8>()
    private var virtualSerialInput = [UInt8: Data]()
    private var virtualSerialCommandBuffers = [UInt8: String]()
    private var pendingClosedVirtualSerialChannels: [UInt8] = []
    private var clientRestartRequested = false
    private var virtualSerialTCPConnections = [UInt8: VirtualSerialTCPConnection]()
    private var virtualSerialTCPListeners = [UInt16: NWListener]()
    private var pendingVirtualSerialTCPConnections = [Int: PendingVirtualSerialTCPConnection]()
    private var nextVirtualSerialTCPConnectionID = 1
    private var driveWireAPIConfig = [String: String]()
    private var virtualDriveParameters = [Int: [String: String]]()
    private var midiBackend: DriveWireMIDIBackend = DriveWireMIDIBackendFactory.makeDefault()

    private struct PendingVirtualSerialTCPConnection {
        let connection: NWConnection
        let localPort: UInt16
        let remoteAddress: String
    }

    private final class VirtualSerialTCPConnection {
        private let connection: NWConnection
        private let queue: DispatchQueue
        private let onReceive: (Data) -> Void
        private let onClose: () -> Void

        let host: String
        let port: UInt16

        init(host: String, port: UInt16, onReceive: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
            self.host = host
            self.port = port
            self.onReceive = onReceive
            self.onClose = onClose
            self.queue = DispatchQueue(label: "DriveWire.VirtualSerialTCP.\(host).\(port)")
            self.connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        }

        init(connection: NWConnection, host: String, port: UInt16, onReceive: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
            self.host = host
            self.port = port
            self.onReceive = onReceive
            self.onClose = onClose
            self.queue = DispatchQueue(label: "DriveWire.VirtualSerialTCP.Accepted.\(host).\(port)")
            self.connection = connection
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    self?.onClose()
                } else if case .cancelled = state {
                    self?.onClose()
                }
            }
            receiveNext()
            connection.start(queue: queue)
        }

        func send(_ data: Data) {
            guard !data.isEmpty else { return }
            connection.send(content: data, completion: .contentProcessed { _ in })
        }

        func close() {
            connection.cancel()
        }

        private func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.onReceive(data)
                }
                if isComplete || error != nil {
                    self.onClose()
                } else {
                    self.receiveNext()
                }
            }
        }
    }
    
    struct RFMPathDescriptor {
        var processID = 0
        var parentProcessID = 0
        var pathNumber = 0
        var pathDescriptorAddress = 0
        var mode = 0
        var filePosition = 0
        var pathname = ""
        var localFile : FileHandle? = nil
        var fileContents : Data = Data()
        var attributes = [FileAttributeKey : Any]()

        mutating func openLocalFile(rootPath: String, shouldCreate: Bool = false) -> UInt8 {
            guard !pathname.isEmpty && !pathname.contains("\0") else { return 216 }

            let expanded = RFMPathDescriptor.expandMultiDots(pathname)
            let localPathname: String
            if (expanded as NSString).isAbsolutePath {
                localPathname = rootPath + expanded
            } else {
                localPathname = rootPath + "/" + expanded
            }
            let resolvedPath = URL(filePath: localPathname).standardized.path
            let normalizedRoot = URL(filePath: rootPath).standardized.path
            guard resolvedPath == normalizedRoot || resolvedPath.hasPrefix(normalizedRoot + "/") else {
                return 214  // E$FNA — escaped above rfmRootPath (or above device root)
            }

            do {
                let fileExists = FileManager.default.fileExists(atPath: localPathname)
                if mode & 0x80 != 0 {
                    // Directory open — clamp '..' at the device root.
                    let effectiveLocalPath: String
                    if resolvedPath == normalizedRoot {
                        // Resolved to rfmRootPath itself — not a valid CoCo device directory.
                        // This happens when "." is opened with no CWD set (e.g. before any chd).
                        return 216
                    } else {
                        effectiveLocalPath = resolvedPath
                    }
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: effectiveLocalPath, isDirectory: &isDir), isDir.boolValue else {
                        return 216
                    }
                    attributes = (try? FileManager.default.attributesOfItem(atPath: effectiveLocalPath)) ?? [:]
                    // Store the effective path so DriveWireHost can synthesize directory entries with proper LSNs.
                    self.pathname = effectiveLocalPath.hasPrefix(rootPath)
                        ? String(effectiveLocalPath.dropFirst(rootPath.count))
                        : effectiveLocalPath
                } else {
                    if !fileExists {
                        guard shouldCreate else { return 216 }
                        // Check parent directory is writable before creating
                        let parent = (localPathname as NSString).deletingLastPathComponent
                        guard FileManager.default.isWritableFile(atPath: parent) else { return 214 }
                        guard FileManager.default.createFile(atPath: localPathname, contents: nil) else {
                            return 216
                        }
                    } else {
                        attributes = try FileManager.default.attributesOfItem(atPath: localPathname)
                        if attributes[.type] as? FileAttributeType == .typeDirectory {
                            return 214  // E$FNA — path is a directory, not a file
                        }
                        let needsWrite = (mode & 0x0A) != 0 || shouldCreate
                        if needsWrite && !FileManager.default.isWritableFile(atPath: localPathname) {
                            return 214  // E$FNA — write access denied
                        }
                        if !FileManager.default.isReadableFile(atPath: localPathname) {
                            return 214  // E$FNA — read access denied
                        }
                    }
                    let url = URL(filePath: localPathname)
                    let needsWrite = (mode & 0x0A) != 0 || shouldCreate
                    localFile = needsWrite
                        ? try FileHandle(forUpdating: url)
                        : try FileHandle(forReadingFrom: url)
                    if let f = localFile {
                        fileContents = f.availableData
                    }
                }
            } catch {
                return 216
            }
            return 0
        }

        // Build one 32-byte OS-9 directory entry: name[0..28] with last char | 0x80, then 3-byte LSN.
        static func makeOS9DirEntry(_ name: String, lsn: Int) -> Data {
            var entry = Data(repeating: 0, count: 32)
            let bytes = Array(name.utf8.prefix(29))
            for (i, b) in bytes.enumerated() {
                entry[i] = i == bytes.count - 1 ? (b | 0x80) : b
            }
            entry[29] = UInt8((lsn >> 16) & 0xFF)
            entry[30] = UInt8((lsn >> 8) & 0xFF)
            entry[31] = UInt8(lsn & 0xFF)
            return entry
        }

        // Expand OS-9 multi-dot path components: N dots = N-1 parent-dir references.
        static func expandMultiDots(_ path: String) -> String {
            return path.components(separatedBy: "/").map { c in
                guard !c.isEmpty, c.allSatisfy({ $0 == "." }), c.count >= 2 else { return c }
                return Array(repeating: "..", count: c.count - 1).joined(separator: "/")
            }.joined(separator: "/")
        }

        // Synthesize an OS-9 file descriptor sector from host file attributes.
        // Layout: FD.ATT(1) FD.OWN(2) FD.DAT(5) FD.LNK(1) FD.SIZ(4) FD.Creat(3) FD.SEG(zeros...)
        func synthesizeFD(count: Int) -> Data {
            var fd = Data(repeating: 0, count: max(count, 16))
            let isDir = attributes[.type] as? FileAttributeType == .typeDirectory

            // FD.ATT: DIR=0x80, owner R/W/E = 0x07, public R = 0x08
            var att: UInt8 = isDir ? 0x8F : 0x0F
            if let posix = attributes[.posixPermissions] as? Int {
                att = isDir ? 0x80 : 0x00
                if posix & 0o400 != 0 { att |= 0x01 }  // owner read
                if posix & 0o200 != 0 { att |= 0x02 }  // owner write
                if posix & 0o100 != 0 { att |= 0x04 }  // owner exec
                if posix & 0o004 != 0 { att |= 0x08 }  // public read
                if posix & 0o002 != 0 { att |= 0x10 }  // public write
                if posix & 0o001 != 0 { att |= 0x20 }  // public exec
            }
            fd[0] = att

            // FD.OWN (bytes 1-2): owner — 0
            // FD.DAT (bytes 3-7): modification date YYMMDDHHMM
            if let mod = attributes[.modificationDate] as? Date {
                let c = Calendar.current
                fd[3] = UInt8(max(0, min(255, c.component(.year, from: mod) - 1900)))
                fd[4] = UInt8(c.component(.month, from: mod))
                fd[5] = UInt8(c.component(.day, from: mod))
                fd[6] = UInt8(c.component(.hour, from: mod))
                fd[7] = UInt8(c.component(.minute, from: mod))
            }
            // FD.LNK (byte 8): link count
            fd[8] = 1
            // FD.SIZ (bytes 9-12): file size, big-endian
            let sz = attributes[.size] as? Int ?? 0
            fd[9]  = UInt8((sz >> 24) & 0xFF)
            fd[10] = UInt8((sz >> 16) & 0xFF)
            fd[11] = UInt8((sz >> 8) & 0xFF)
            fd[12] = UInt8(sz & 0xFF)
            // FD.Creat (bytes 13-15): creation date YYMMDD
            if let cr = attributes[.creationDate] as? Date {
                let c = Calendar.current
                fd[13] = UInt8(max(0, min(255, c.component(.year, from: cr) - 1900)))
                fd[14] = UInt8(c.component(.month, from: cr))
                fd[15] = UInt8(c.component(.day, from: cr))
            }
            // FD.SEG (bytes 16+): segment list — all zeros for RFM (no physical sectors)
            return Data(fd.prefix(count))
        }

        mutating func readLineFromFile(maximumCount: Int) -> (UInt8, Data) {
            guard filePosition < fileContents.count else { return (211, Data()) }
            var data = Data()
            while filePosition < fileContents.count && data.count < maximumCount {
                var byte = fileContents[filePosition]
                filePosition += 1
                if byte == 0x0A { byte = 0x0D }
                data.append(byte)
                if byte == 0x0D { break }
            }
            return (0, data)
        }

        mutating func readFromFile(maximumCount: Int) -> (UInt8, Data) {
            guard filePosition < fileContents.count else { return (211, Data()) }
            let end = min(filePosition + maximumCount, fileContents.count)
            let data = Data(fileContents[filePosition..<end])
            filePosition = end
            return (0, data)
        }

        mutating func writeToFile(data: Data, translateCR: Bool = false) -> UInt8 {
            guard let file = localFile else { return 216 }
            let bytesToWrite: Data
            if translateCR {
                // Content ends at first $0D (everything after is stale buffer data).
                // Convert $0D → $0A, discard remainder. Also stop at $FF (OS-9 padding).
                var out = Data()
                for byte in data {
                    if byte == 0xFF { break }
                    if byte == 0x0D { out.append(0x0A); break }
                    out.append(byte)
                }
                bytesToWrite = out
            } else {
                bytesToWrite = data
            }
            file.seek(toFileOffset: UInt64(filePosition))
            file.write(bytesToWrite)
            file.synchronizeFile()
            filePosition += bytesToWrite.count
            return 0
        }
    }

    var rfmRootPath: String = NSHomeDirectory()
    private var rfmPaths: [Int: RFMPathDescriptor] = [:]
    private var rfmCurrentDir: [Int: String] = [:]      // data directory per process
    private var rfmCurrentExecDir: [Int: String] = [:] // execution directory per process
    // Maps host path ↔ unique LSN for synthesized RFM directory entries.
    // LSNs start above a typical NitrOS-9 DW image (~524k sectors for DW format).
    private var rfmLSNByPath: [String: Int] = [:]
    private var rfmLSNToPath: [Int: String] = [:]
    private var rfmLSNCounter: Int = 0x600000
    
    /// The no-operation transaction code.
    ///
    /// This transaction does nothing.
    public let OPNOP : UInt8 = 0x00
    /// The time transaction code.
    ///
    /// This is a bi-directional transaction that requests the date and time from the host. The format of the response is a 6-byte packet.
    ///
    /// | Byte | Value | Range | Notes |
    /// | ------- | ------- | ------- | ------- |
    /// | 0 | Year | 0-255 | Represents years 1900 to 2155. |
    /// | 1 | Month | 1-12 | Represents January to December. |
    /// | 2 | Day | 1-31 | Represents the day of the month. |
    /// | 3 | Hour | 0-23 | Represents the hour. |
    /// | 4 | Minute | 0-59 | Represents the minute. |
    /// | 5 | Second | 0-59 | Represents the second. |
    public let OPTIME : UInt8 = 0x23
    /// The named object mount transaction code.
    public let OPNAMEOBJMOUNT : UInt8 = 0x01
    /// The named object create transaction code.
    public let OPNAMEOBJCREATE : UInt8 = 0x02
    /// The initialization transaction code.
    ///
    /// This is a bi-directional transaction that informs the guest and host of each other's version and capabilities.
    /// The exact meaning of the version byte isn't defined. The OS-9 driver currently uses this transaction to determine whether it should load DriveWire 4-specific extensions
    /// such as the virtual channel polling routine.
    ///
    /// The guest initiates the transaction with this 2-byte packet.
    ///
    /// | Offset | Value |
    /// | ------- | ------- |
    /// | 0 | The transaction code ($5A). |
    /// | 1 | The guest's version/capabilities byte. |
    ///
    /// The host responds with its own version/capabilities byte.
    ///
    /// | Offset | Value |
    /// | ------- | ------- |
    /// | 0 | The host version/capabilities byte. |
    public let OPDWINIT : UInt8 = 0x5A
    /// The read transaction code.
    ///
    /// This transaction provides 256-byte sectors of binary data to the guest from a virtual disk. The guest provides a virtual drive number from 0 - 255 and a 24-bit logical sector number (LSN) that represents the offset from the beginning of the virtual disk to the desired sector.
    ///
    /// The guest initiates the transaction with this 5-byte packet.
    ///
    /// | Offset | Value |
    /// | ------- | ------- |
    /// | 0 | The trransaction code ($52). |
    /// | 1 | The virtual drive number from 0 - 255. |
    /// | 2 | Bits 23-16 of the 24 bit logical sector number |
    /// | 3 | Bits 15-8 of the 24 bit logical sector number |
    /// | 4 | Bits 7-0 of the 24 bit logical sector number |
    ///
    /// If the transaction is successful, the host responds with the following packet,
    ///
    /// | Offset | Value |
    /// | ------- | ------- |
    /// | 0 | A value of $00 indicating the transaction was successful. |
    /// | 1 | Bits 15-8 of the checksum of the 256-byte sector. |
    /// | 2 | Bits 7-0 of the checksum of the 256-byte sector. |
    /// | 3 - 258 | The 256-byte sector data. |
    ///
    /// If the transaction is not successful, the host responds with the following packet.
    ///
    /// | Offset | Value |
    /// | ------- | ------- |
    /// | 0 | The error code greater than zero indicating the transaction failed. |
    ///
    /// If the guest receives an error code that isn't zero, it may choose to retry the transaction using ``OPREREAD``.
    public let OPREAD : UInt8 = 0x52
    /// The read extended transaction code.
    ///
    /// This is an extended version of the ``OPREAD``.
    public let OPREADEX : UInt8 = 0xD2
    /// The initialization transaction code.
    ///
    /// This is a uni-directional transaction that indicates the guest is ready to use DriveWire. It doesn't cause any action on the host.
    /// Use ``OPDWINIT`` instead.
    @available(*, deprecated, message: "This is a historical transaction code that you should no longer use.")
    public let OPINIT : UInt8 = 0x49
    /// The termination transaction code.
    ///
    /// This is a uni-directional transaction that the guest can initiate to indicate it's ready to stop using DriveWire. It doesn't cause any action on the host.
    @available(*, deprecated, message: "This is a historical transaction code that you should no longer use.")
    public let OPTERM : UInt8 = 0x54
    /// The re-read transaction code.
    public let OPREREAD : UInt8 = 0x72
    /// The extended re-read transaction code.
    public let OPREREADEX : UInt8 = 0xF2
    /// The write transaction code.
    public let OPWRITE : UInt8 = 0x57
    /// The re-write transaction code.
    public let OPREWRITE : UInt8 = 0x77
    /// The virtual drive  get status transaction code.
    public let OPGETSTAT : UInt8 = 0x47
    /// The virtual drive set status transaction code.
    public let OPSETSTAT : UInt8 = 0x53
    /// The reset transaction code.
    ///
    /// This is a uni-directional transaction that the guest sends to the host to indicate that it completed a reset condition.
    @available(*, deprecated, message: "This is a historical transaction code that you should no longer use.")
    public let OPRESET3 : UInt8 = 0xF8
    /// The reset transaction code.
    ///
    /// This is a uni-directional transaction that the guest sends to the host to indicate that it completed a reset condition.
    @available(*, deprecated, message: "This is a historical transaction code that you should no longer use.")
    public let OPRESET2 : UInt8 = 0xFE
    /// The reset transaction code.
    ///
    /// This is a uni-directional transaction that the guest sends to the host to indicate that it completed a reset condition.
    public let OPRESET : UInt8 = 0xFF
    /// The WireBug transaction code.
    public let OPWIREBUG : UInt8 = 0x42
    /// The print flush transaction code.
    ///
    /// This is a uni-directional transaction that the guest sends to the host to indicate that the print buffer is ready for printing.
    ///
    /// Upon receipt, the host sends the contents of the print buffer to the configured printer, then it clears the print buffer.
    public let OPPRINTFLUSH : UInt8 = 0x46
    /// The print transaction code.
    ///
    /// This is a uni-directional transaction that the guest sends to the host to add a byte of data to the print queue.
    ///
    /// The guest initiates the transaction with this 2-byte packet.
    ///
    /// | Offset | Value |
    /// | ------- | ------- |
    /// | 0 | The transaction code ($5A). |
    /// | 1 | The byte of data to add to the queue. |
    ///
    /// Upon receiving this packet, the host adds the passed byte to its internal print buffer. To start the print transaction, see ``OPPRINTFLUSH``.
    public let OPPRINT : UInt8 = 0x50
    /// The serial initialization transaction code.
    public let OPSERINIT : UInt8 = 0x45
    /// The serial termination transaction code.
    public let OPSERTERM : UInt8 = 0xC5
    /// The serial get status transaction code.
    public let OPSERGETSTAT : UInt8 = 0x44
    /// The serial set status transaction code.
    public let OPSERSETSTAT : UInt8 = 0xC4
    /// The serial read transaction code.
    public let OPSERREAD : UInt8 = 0x43
    /// The serial read multiple transaction code.
    public let OPSERREADM : UInt8 = 0x63
    /// The serial write transaction code.
    public let OPSERWRITE : UInt8 = 0xC3
    /// The serial write multiple transaction code.
    public let OPSERWRITEM : UInt8 = 0x64
    /// The RFM transaction code.
    public let OPRFM : UInt8 = 0xD6

    /// A set of operations that control debugging on the guest.
    enum DWWirebugOpCode : UInt8 {
        /// The code for reading a guest's CPU registers.
        case OP_WIREBUG_READREGS = 82
        /// The code for writing a guest's CPU registers.
        case OP_WIREBUG_WRITEREGS = 114
        /// The code for reading a guest's memory.
        case OP_WIREBUG_READMEM = 77
        /// The code for writing a guest's memory.
        case OP_WIREBUG_WRITEMEM = 109
        /// The code for enforcing a guest's execution path.
        case OP_WIREBUG_GO = 71
    }
    
    /// A set of operations for Remote File Manager functionality.
    enum DWRFMTransaction : UInt8 {
        /// The create transaction code.
        case OP_RFM_CREATE = 0x01
        /// The open transaction code.
        case OP_RFM_OPEN = 0x02
        /// The make directory transaction code.
        case OP_RFM_MAKDIR = 0x03
        /// The change directory transaction code.
        case OP_RFM_CHGDIR = 0x04
        /// The delete transaction code.
        case OP_RFM_DELETE = 0x05
        /// The seek transaction code.
        case OP_RFM_SEEK = 0x06
        /// The read transaction code.
        case OP_RFM_READ = 0x07
        /// The write transaction code.
        case OP_RFM_WRITE = 0x08
        /// The read line transaction code.
        case OP_RFM_READLN = 0x09
        /// The write line transaction code.
        case OP_RFM_WRITLN = 0x0A
        /// The get status transaction code.
        case OP_RFM_GETSTT = 0x0B
        /// The set status transaction code.
        case OP_RFM_SETSTT = 0x0C
        /// The close transaction code.
        case OP_RFM_CLOSE = 0x0D
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(virtualDrives, forKey:.virtualDrives)
    }
    
    private func setupTransactions() {
        dwTransaction.append(DWOp(opcode:OPDWINIT, processor: self.OP_DWINIT))
        dwTransaction.append(DWOp(opcode:OPNAMEOBJMOUNT, processor: self.OP_NAMEOBJ_MOUNT))
        dwTransaction.append(DWOp(opcode:OPNAMEOBJCREATE, processor: self.OP_NAMEOBJ_CREATE))
        dwTransaction.append(DWOp(opcode:OPNOP, processor: self.OP_NOP))
        dwTransaction.append(DWOp(opcode:OPTIME, processor: self.OP_TIME))
        dwTransaction.append(DWOp(opcode:0x49, processor: self.OP_INIT))   // OPINIT (historical)
        dwTransaction.append(DWOp(opcode:0x54, processor: self.OP_TERM))   // OPTERM (historical)
        dwTransaction.append(DWOp(opcode:OPREAD, processor: self.OP_READ))
        dwTransaction.append(DWOp(opcode:OPREADEX, processor: self.OP_READEX))
        dwTransaction.append(DWOp(opcode:OPREREAD, processor: self.OP_REREAD))
        dwTransaction.append(DWOp(opcode:OPREREADEX, processor: self.OP_REREADEX))
        dwTransaction.append(DWOp(opcode:OPWRITE, processor: self.OP_WRITE))
        dwTransaction.append(DWOp(opcode:OPREWRITE, processor: self.OP_REWRITE))
        dwTransaction.append(DWOp(opcode:OPGETSTAT, processor: self.OP_GETSTAT))
        dwTransaction.append(DWOp(opcode:OPSETSTAT, processor: self.OP_SETSTAT))
        dwTransaction.append(DWOp(opcode:0xF8, processor: self.OP_RESET))  // OPRESET3 (historical)
        dwTransaction.append(DWOp(opcode:0xFE, processor: self.OP_RESET))  // OPRESET2 (historical)
        dwTransaction.append(DWOp(opcode:OPRESET, processor: self.OP_RESET))
        dwTransaction.append(DWOp(opcode:OPWIREBUG, processor: self.OP_WIREBUG))
        dwTransaction.append(DWOp(opcode:OPPRINTFLUSH, processor: self.OP_PRINTFLUSH))
        dwTransaction.append(DWOp(opcode:OPPRINT, processor: self.OP_PRINT))
        dwTransaction.append(DWOp(opcode:OPSERINIT, processor: self.OP_SERINIT))
        dwTransaction.append(DWOp(opcode:OPSERTERM, processor: self.OP_SERTERM))
        dwTransaction.append(DWOp(opcode:OPSERGETSTAT, processor: self.OP_SERGETSTAT))
        dwTransaction.append(DWOp(opcode:OPSERSETSTAT, processor: self.OP_SERSETSTAT))
        dwTransaction.append(DWOp(opcode:OPSERREAD, processor: self.OP_SERREAD))
        dwTransaction.append(DWOp(opcode:OPSERREADM, processor: self.OP_SERREADM))
        dwTransaction.append(DWOp(opcode:OPSERWRITE, processor: self.OP_SERWRITE))
        dwTransaction.append(DWOp(opcode:OPSERWRITEM, processor: self.OP_SERWRITEM))
        dwTransaction.append(DWOp(opcode:OPRFM, processor: self.OP_RFM))
        processor = OP_OPCODE
    }

    public required init(from decoder: Decoder) throws {
        do {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.virtualDrives = try values.decode([VirtualDrive].self, forKey: .virtualDrives)
            setupTransactions()
        } catch {
            print("\(error)")
        }
    }
    
    /// Creates a DriveWire host.
    ///
    /// - Parameters:
    ///     - delegate: The delegate that receives messages.
    init(delegate : DriveWireDelegate) {
        self.delegate = delegate
        
        setupTransactions()
    }
    
    /// Inserts a virtual disk into the virtual drive.
    ///
     /// - Parameters:
    ///     - driveNumber: The drive number to insert the virtual disk into.
    ///     - imagePath: The page the virtual disk image to insert.
    public func insertVirtualDisk(driveNumber : Int, imagePath : String) throws {
        if let _ = virtualDrives.first(where: { $0.driveNumber == driveNumber }) {
            ejectVirtualDisk(driveNumber: driveNumber)
            // A drive with this number already exists... disallow it.
//            throw DriveWireHostError.driveAlreadyExists
        }

        virtualDrives.append(try VirtualDrive(driveNumber: driveNumber, imagePath: imagePath))
    }
    
    /// Ejects a virtual disk from the virtual drive.
    /// - Parameters:
    ///     - driveNumber: The drive number to remove the virtual disk image from.ds
    public func ejectVirtualDisk(driveNumber : Int) {
        virtualDrives.removeAll { $0.driveNumber == driveNumber }
    }
    
    /// Find a virtual disk with a specific name.
    /// - Parameters:
    ///     - name: The name of the virtual disk. This is the last component of a pathlsit.
    /// - Returns:The `VirtualDrive` object, if found; otherwise it throws an error.
    public func findVirtualDisk(name : String) -> VirtualDrive? {
        if let foundDrive = virtualDrives.first(where: {($0.imagePath as NSString).lastPathComponent == name}) {
            return foundDrive
        }
        return nil
    }
    
    /// Find a free virtual drive.
    /// - Returns:A virtual drive number.
    public func findAvailableVirtualDrive() -> Int {
        var candidate = 0
        var tryAgain = false
        
        repeat {
            tryAgain = false
            for v in virtualDrives {
                if v.driveNumber == candidate {
                    candidate = candidate + 1
                    tryAgain = true
                    break
                }
            }
        } while tryAgain == true
        
        return candidate
    }
     
    /// Provides data to the DriveWire host.
    ///
    /// Call this function with the data you want to send to the host.
    ///
    /// - Parameters:
    ///     - data: Data to provide to the host.
    public func send(data : inout Data) {
        var bytesConsumed = 0
        
        serialBuffer.append(data)
        
        repeat
        {
            bytesConsumed = self.processor!(serialBuffer)

            if bytesConsumed > 0  && serialBuffer.count >= bytesConsumed {
                // Bytes were consumed — cancel the idle watchdog while mid-transaction.
                invalidateWatchdog()
                serialBuffer.replaceSubrange(0..<bytesConsumed, with: Data([]))
            }
        } while bytesConsumed > 0 && serialBuffer.count > 0
    }
    
    private var watchdog : Timer?
    
    private func setupWatchdog() {
        invalidateWatchdog()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false, block: { time in
            self.resetState()
        })
    }
    
    private func invalidateWatchdog() {
        watchdog?.invalidate()
    }
    
    /// Computes a simple checksum of the passed data.
    ///
    /// - Parameters:
    ///     - data: The data payload to compute the checksum over.
    ///
    ///  - Returns: A 16-bit checksum value.
    public func compute16BitChecksum(data : Data) -> UInt16
    {
        var lastChecksum : UInt16 = 0x0000
        for d in data {
            lastChecksum += UInt16(d)
        }
        return lastChecksum;
    }
    
    private func resetState() {
        processor = OP_OPCODE
        invalidateWatchdog()
    }

    func resetRFMState() {
        for descriptor in rfmPaths.values {
            descriptor.localFile?.closeFile()
        }
        rfmPaths.removeAll()
        rfmCurrentDir.removeAll()
        rfmCurrentExecDir.removeAll()
        rfmLSNByPath.removeAll()
        rfmLSNToPath.removeAll()
        rfmLSNCounter = 0x600000
        print("RFM state reset")
    }

    private func resetGuestSessionState() {
        resetState()
        statistics = DriveWireStatistics()
        serialBuffer.removeAll()
        currentSubTransaction = 0
        guestCapabilityByte = 0
        validateWithCRC = false
        fastwriteChannel = 0
        openVirtualSerialChannels.removeAll()
        virtualSerialInput.removeAll()
        virtualSerialCommandBuffers.removeAll()
        pendingClosedVirtualSerialChannels.removeAll()
        clientRestartRequested = false
        for connection in virtualSerialTCPConnections.values {
            connection.close()
        }
        virtualSerialTCPConnections.removeAll()
        for listener in virtualSerialTCPListeners.values {
            listener.cancel()
        }
        virtualSerialTCPListeners.removeAll()
        for pending in pendingVirtualSerialTCPConnections.values {
            pending.connection.cancel()
        }
        pendingVirtualSerialTCPConnections.removeAll()
        nextVirtualSerialTCPConnectionID = 1
        virtualWindows.removeAll()
        printBuffer.removeAll()
        resetRFMState()
    }
    
    private func OP_DWINIT(data : Data) -> Int {
        var result = 0
        let expectedCount = 2
        currentTransaction = OPDWINIT
        
        if data.count >= expectedCount {
            // Save capabilities byte.
            guestCapabilityByte = data[1]
            
            // Send the host capabilities byte. This must be non-zero: the
            // NitrOS-9 driver treats zero as a DW3 server and disables DW4
            // extensions, including the virtual serial poller.
            delegate?.dataAvailable(host: self, data: Data([0xFF]))
            result = expectedCount
            
            // Reset the state machine.
            resetState()
        }
        
        return result
    }
    
    private var nameLength = 0

    private static func decodedNameObjectPath(from data: Data, length: Int) -> String? {
        guard length > 0, data.count >= length else {
            return nil
        }

        let nameBytes = Array(data.prefix(length)).map { $0 & 0x7F }
        guard nameBytes.allSatisfy({ $0 >= 0x20 && $0 != 0x7F }) else {
            return nil
        }

        let name = String(bytes: nameBytes, encoding: .ascii) ?? ""
        return name.isEmpty ? nil : name
    }
    
    private func OP_NAMEOBJ_MOUNT(data : Data) -> Int {
        var result = 0
        let expectedCount = 2
        var response : UInt8 = 0
        currentTransaction = OPNAMEOBJMOUNT
        if data.count >= expectedCount {
            nameLength = Int(data[1])
            
            // We read 2 bytes into this buffer (OP_NAMEOBJ_MOUNT, 1 byte name length)
            result = expectedCount;
            
            processor = OP_NAMEOBJ_MOUNT2
        }
        
        return result
        
        func OP_NAMEOBJ_MOUNT2(data : Data) -> Int {
            if data.count >= nameLength {
                resetState()
                result = nameLength;

                // determine if a named object with this name already exists
                if let name = Self.decodedNameObjectPath(from: data, length: nameLength),
                   let vd = findVirtualDisk(name: name) {
                    response = UInt8(vd.driveNumber)
                } else if let name = Self.decodedNameObjectPath(from: data, length: nameLength) {
                    do {
                        let nextFreeDrive = findAvailableVirtualDrive()
                        try insertVirtualDisk(driveNumber: nextFreeDrive, imagePath: name)
                        response = UInt8(nextFreeDrive);
                    } catch {
                        response = 0
                    }
                }
                delegate?.dataAvailable(host: self, data: Data([response]))
                delegate?.transactionCompleted(opCode: currentTransaction)
            }

            return result
        }
    }

    private func OP_NAMEOBJ_CREATE(data : Data) -> Int {
        var nameLength = 0
        var result = 0
        let expectedCount = 2
        var response : UInt8 = 0
        currentTransaction = OPNAMEOBJCREATE
        if data.count >= expectedCount {
            nameLength = Int(data[1])
            
            // We read 2 bytes into this buffer (OP_NAMEOBJ_MOUNT, 1 byte name length)
            result = expectedCount;
            
            processor = OP_NAMEOBJ_MOUNT2
        }
        
        return result
        
        func OP_NAMEOBJ_MOUNT2(data : Data) -> Int {
            if data.count >= nameLength {
                resetState()
                result = nameLength;

                // Create fails if the object already exists, whether or not it's currently mounted.
                if let name = Self.decodedNameObjectPath(from: data, length: nameLength) {
                    if findVirtualDisk(name: name) != nil || FileManager.default.fileExists(atPath: name) {
                        response = 0
                    } else if FileManager.default.createFile(atPath: name, contents: nil) {
                        let nextFreeDrive = findAvailableVirtualDrive()
                        do {
                            try insertVirtualDisk(driveNumber: nextFreeDrive, imagePath: name)
                            response = UInt8(nextFreeDrive);
                        } catch {
                            try? FileManager.default.removeItem(atPath: name)
                            response = 0
                        }
                    } else {
                        response = 0
                    }
                }
                delegate?.dataAvailable(host: self, data: Data([response]))
                delegate?.transactionCompleted(opCode: currentTransaction)
            }

            return result
        }
    }
    
    private func OP_NOP(data : Data) -> Int {
        currentTransaction = OPNOP
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        return 1
    }
    
    private func OP_TIME(data : Data) -> Int {
        currentTransaction = OPTIME
        let currentDate = Date()
        let calendar = Calendar.current
        let year = UInt8(calendar.component(.year, from: currentDate) - 1900)
        let month = UInt8(calendar.component(.month, from: currentDate))
        let day = UInt8(calendar.component(.day, from: currentDate))
        let hour = UInt8(calendar.component(.hour, from: currentDate))
        let minute = UInt8(calendar.component(.minute, from: currentDate))
        let second = UInt8(calendar.component(.second, from: currentDate))
        resetState()
        delegate?.dataAvailable(host: self, data: Data([year, month, day, hour, minute, second]))
        delegate?.transactionCompleted(opCode: currentTransaction)
        let msg = "OP_TIME -> \(1900 + Int(year))/\(month)/\(day) \(hour):\(String(format:"%02d",minute)):\(String(format:"%02d",second))"
        log += msg + "\n"; print(msg)
        return 1
    }

    private func OP_INIT(data : Data) -> Int {
        currentTransaction = 0x49   // OPINIT (historical)
        resetState()
        statistics = DriveWireStatistics()
        resetRFMState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        log += "OP_INIT\n"; print("OP_INIT")
        return 1
    }

    private func OP_TERM(data : Data) -> Int {
        currentTransaction = 0x54   // OPTERM (historical)
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        log += "OP_TERM\n"; print("OP_TERM")
        return 1
    }
    
    private func OP_WRITE_CORE(data : Data, operation: UInt8) -> Int {
        var result = 0
        var error = DriveWireProtocolError.E_NONE.rawValue
        let expectedCount = 263
        currentTransaction = OPWRITE
        
        if data.count >= expectedCount {
            resetState()
            result = expectedCount;
            
            let driveNumber = data[1]
            statistics.lastDriveNumber = driveNumber
            let vLSN = Int(data[2]) << 16 + Int(data[3]) << 8 + Int(data[4])
            statistics.lastLSN = vLSN
            let sectorBuffer = data[5..<261]
            let checksum = Int(data[261])*256+Int(data[262])

            result = expectedCount;
            
            // Check if the drive number exists in our virtual drive list.
            if let virtualDrive = virtualDrives.first(where: { $0.driveNumber == driveNumber }) {
                // It exists! Verify checksum.
                let computedChecksum = compute16BitChecksum(data: sectorBuffer)
                if computedChecksum == checksum {
                    // All good. Write sector to disk image.
                    statistics.lastDriveNumber = driveNumber
                    statistics.writeCount = statistics.writeCount + 1
                    statistics.percentWritesOK = (1 - statistics.reWriteCount / statistics.writeCount) * 100
                    error = virtualDrive.writeSector(lsn: vLSN, sector: sectorBuffer)
                } else {
                    error = DriveWireProtocolError.E_CRC.rawValue
                }
            } else {
                // It doesn't exist. Set the error code.
                error = DriveWireProtocolError.E_UNIT.rawValue
            }
            
            statistics.lastDriveNumber = driveNumber
            delegate?.dataAvailable(host: self, data: Data([UInt8(error)]))
            delegate?.transactionCompleted(opCode: currentTransaction)
            let msg = "OP_WRITE(drive=\(driveNumber), lsn=0x\(String(vLSN, radix: 16))) -> \(error)"
            reportActivity(msg, isFrequent: true, isError: error != DriveWireProtocolError.E_NONE.rawValue)
        }
        
        return result
    }
    
    private func OP_WRITE(data : Data) -> Int {
        return OP_WRITE_CORE(data: data, operation: OPWRITE)
    }
    
    private func OP_REWRITE(data : Data) -> Int {
        statistics.reWriteCount = statistics.reWriteCount + 1
        return OP_WRITE_CORE(data: data, operation: OPREWRITE)
    }
    
    private func OP_GETSTAT(data : Data) -> Int {
        var result = 0
        let expectedCount = 3
        currentTransaction = OPGETSTAT
        
        if data.count >= expectedCount {
            resetState()
            result = expectedCount;
            
            statistics.lastDriveNumber = data[1]
            statistics.lastGetStat = data[2]
            delegate?.transactionCompleted(opCode: currentTransaction)
        }
        
        reportActivity("OP_GETSTAT(drive=\(statistics.lastDriveNumber), \(DriveWireHost.ssCodeName(Int(statistics.lastGetStat))))", isFrequent: true)
        return result
    }
    
    private func OP_SETSTAT(data : Data) -> Int {
        var result = 0
        let expectedCount = 3
        currentTransaction = OPSETSTAT
        
        if data.count >= expectedCount {
            resetState()
            result = expectedCount;
            
            statistics.lastDriveNumber = data[1]
            statistics.lastSetStat = data[2]
            delegate?.transactionCompleted(opCode: currentTransaction)
        }
        
        reportActivity("OP_SETSTAT(drive=\(statistics.lastDriveNumber), \(DriveWireHost.ssCodeName(Int(statistics.lastSetStat))))", isFrequent: true)
        return result
    }
    
    private func OP_RESET(data : Data) -> Int {
        currentTransaction = OPRESET
        resetGuestSessionState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        log = "OP_RESET\n"
        print("OP_RESET")
        return 1
    }
    
    private func OP_WIREBUG(data : Data) -> Int {
        var result = 0
        let expectedCount = 24
        currentTransaction = OPWIREBUG
        
        if data.count >= expectedCount {
            resetState()
            result = expectedCount;
            delegate?.transactionCompleted(opCode: currentTransaction)
        }
        
        return result
    }
    
    /// The print buffer.
    private var printBuffer = Data()
    
    private func OP_PRINT(data : Data) -> Int {
        var result = 0
        let expectedCount = 2
        currentTransaction = OPPRINT
        
        if data.count >= expectedCount {
            resetState()
            result = expectedCount
            let printerByte = data[1]
            printBuffer.append(printerByte)
            delegate?.transactionCompleted(opCode: currentTransaction)
        }
        
        return result
    }
    
    private func OP_PRINTFLUSH(data : Data) -> Int {
        currentTransaction = OPPRINTFLUSH
        resetState()
        
        // For now, just clear the print buffer
        printBuffer.removeAll()
        delegate?.transactionCompleted(opCode: currentTransaction)
        
        return 1
    }
    
    private func OP_SERINIT(data : Data) -> Int {
        currentTransaction = OPSERINIT
        guard data.count >= 2 else { return 0 }
        let ch = data[1]
        openVirtualSerialChannels.insert(ch)
        if isVirtualWindowChannel(ch) {
            openVirtualWindow(channel: ch)
        }
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        let msg = "OP_SERINIT(ch=\(ch))"; log += msg + "\n"; print(msg)
        return 2
    }

    private func OP_SERTERM(data : Data) -> Int {
        currentTransaction = OPSERTERM
        guard data.count >= 2 else { return 0 }
        let ch = data[1]
        openVirtualSerialChannels.remove(ch)
        if isVirtualWindowChannel(ch) {
            closeVirtualWindow(channel: ch)
        }
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        let msg = "OP_SERTERM(ch=\(ch))"; log += msg + "\n"; print(msg)
        return 2
    }

    private func OP_SERREAD(data : Data) -> Int {
        currentTransaction = OPSERREAD
        guard data.count >= 1 else { return 0 }
        resetState()
        let response = pollVirtualSerial()
        delegate?.dataAvailable(host: self, data: response)
        delegate?.transactionCompleted(opCode: currentTransaction)
        reportActivity("OP_SERREAD -> \(response[0]),\(response[1])", isFrequent: true)
        return 1
    }

    private func OP_SERREADM(data : Data) -> Int {
        currentTransaction = OPSERREADM
        guard data.count >= 3 else { return 0 }
        let ch = data[1]
        let count = Int(data[2])
        let response = readVirtualSerial(channel: virtualSerialInputChannel(forGuestChannel: ch), count: count)
        resetState()
        delegate?.dataAvailable(host: self, data: response)
        delegate?.transactionCompleted(opCode: currentTransaction)
        reportActivity("OP_SERREADM(ch=\(ch), bytes=\(count))", isFrequent: true)
        return 3
    }

    private func OP_SERWRITE(data : Data) -> Int {
        currentTransaction = OPSERWRITE
        guard data.count >= 3 else { return 0 }
        let ch = data[1]; let byte = data[2]
        writeVirtualSerial(channel: ch, data: Data([byte]))
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        let msg = "OP_SERWRITE(ch=\(ch), byte=0x\(String(byte, radix: 16)))"; log += msg + "\n"; print(msg)
        return 3
    }

    private func OP_SERWRITEM(data : Data) -> Int {
        currentTransaction = OPSERWRITEM
        guard data.count >= 2 else { return 0 }
        let ch = data[1]
        if !openVirtualSerialChannels.contains(ch) {
            resetState()
            delegate?.transactionCompleted(opCode: currentTransaction)
            reportActivity("OP_SERWRITEM(ch=\(ch)) ignored for unopened channel", isFrequent: true)
            return 2
        }
        guard data.count >= 3 else { return 0 }
        let count = Int(data[2])
        let total = 3 + count
        guard data.count >= total else { return 0 }
        writeVirtualSerial(channel: ch, data: data.subdata(in: 3..<total))
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        reportActivity("OP_SERWRITEM(ch=\(ch), bytes=\(count))", isFrequent: true)
        return total
    }

    private func OP_SERGETSTAT(data : Data) -> Int {
        currentTransaction = OPSERGETSTAT
        guard data.count >= 3 else { return 0 }
        let ch = data[1]; let code = data[2]
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        let msg = "OP_SERGETSTAT(ch=\(ch), \(DriveWireHost.ssCodeName(Int(code))))"; log += msg + "\n"; print(msg)
        return 3
    }

    private func OP_SERSETSTAT(data : Data) -> Int {
        currentTransaction = OPSERSETSTAT
        guard data.count >= 3 else { return 0 }
        let ch = data[1]; let code = data[2]
        let expectedCount = code == 0x28 ? 29 : 3
        guard data.count >= expectedCount else { return 0 }
        switch code {
        case 0x29:
            openVirtualSerialChannels.insert(ch)
            if isVirtualWindowChannel(ch) {
                openVirtualWindow(channel: ch)
            }
        case 0x2A:
            virtualSerialTCPConnections[ch]?.close()
            virtualSerialTCPConnections[ch] = nil
            openVirtualSerialChannels.remove(ch)
            if isVirtualWindowChannel(ch) {
                closeVirtualWindow(channel: ch)
            }
        default:
            break
        }
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        let msg = "OP_SERSETSTAT(ch=\(ch), \(DriveWireHost.ssCodeName(Int(code))))"; log += msg + "\n"; print(msg)
        return expectedCount
    }

    private func pollVirtualSerial() -> Data {
        if clientRestartRequested {
            clientRestartRequested = false
            return Data([16, 255])
        }

        if let channel = pendingClosedVirtualSerialChannels.first,
           virtualSerialInput[channel]?.isEmpty ?? true {
            pendingClosedVirtualSerialChannels.removeFirst()
            openVirtualSerialChannels.remove(channel)
            return Data([16, channel])
        }

        if let channel = virtualSerialInput.keys.sorted().first(where: {
            isVirtualWindowChannel($0) && !(virtualSerialInput[$0]?.isEmpty ?? true)
        }) {
            let byte = readVirtualSerial(channel: channel, count: 1).first ?? 0
            return Data([virtualWindowGuestChannel(forInternalChannel: channel), byte])
        }

        if let channel = virtualSerialInput.keys.sorted().first(where: {
            !isVirtualWindowChannel($0) && !(virtualSerialInput[$0]?.isEmpty ?? true)
        }) {
            let waiting = virtualSerialInput[channel]?.count ?? 0
            if waiting >= 3 {
                return Data([channel &+ 17, UInt8(min(waiting, 255))])
            }
            let byte = readVirtualSerial(channel: channel, count: 1).first ?? 0
            return Data([channel &+ 1, byte])
        }

        return Data([0x00, 0x00])
    }

    private func readVirtualSerial(channel: UInt8, count: Int) -> Data {
        guard count > 0, var queued = virtualSerialInput[channel], !queued.isEmpty else {
            return Data()
        }

        let readCount = min(count, queued.count)
        let response = queued.prefix(readCount)
        queued.removeFirst(readCount)
        virtualSerialInput[channel] = queued
        return Data(response)
    }

    private func writeVirtualSerial(channel: UInt8, data: Data) {
        if let connection = virtualSerialTCPConnections[channel] {
            connection.send(data)
            return
        }

        if isVirtualWindowChannel(channel) {
            appendVirtualWindowOutput(data, channel: channel)
            return
        }

        for byte in data {
            if byte == 0x0D {
                let command = virtualSerialCommandBuffers[channel, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
                virtualSerialCommandBuffers[channel] = ""
                processVirtualSerialCommand(command, channel: channel)
            } else if byte == 0x08 || byte == 0x7F {
                var command = virtualSerialCommandBuffers[channel, default: ""]
                if !command.isEmpty {
                    command.removeLast()
                }
                virtualSerialCommandBuffers[channel] = command
            } else if byte >= 0x20 {
                virtualSerialCommandBuffers[channel, default: ""].append(Character(UnicodeScalar(byte)))
            }
        }
    }

    public func sendVirtualWindowInput(_ text: String, channel: UInt8) {
        guard isVirtualWindowChannel(channel), !text.isEmpty else {
            return
        }
        let normalized = text.replacingOccurrences(of: "\n", with: "\r")
        let bytes = normalized.compactMap { character -> UInt8? in
            guard let scalar = character.unicodeScalars.first else { return nil }
            if scalar.value == 0x08 || scalar.value == 0x09 || scalar.value == 0x0D || scalar.value == 0x1B || (scalar.value >= 0x20 && scalar.value <= 0x7E) {
                return UInt8(scalar.value)
            }
            return nil
        }
        guard !bytes.isEmpty else { return }
        virtualSerialInput[channel, default: Data()].append(contentsOf: bytes)
        openVirtualWindow(channel: channel)
    }

    public func clearVirtualWindow(channel: UInt8) {
        guard let index = virtualWindowIndex(for: channel, createIfNeeded: false) else {
            return
        }
        virtualWindows[index].text = ""
    }

    private func openVirtualWindow(channel: UInt8) {
        guard let index = virtualWindowIndex(for: channel, createIfNeeded: true) else {
            return
        }
        virtualWindows[index].isOpen = true
    }

    private func closeVirtualWindow(channel: UInt8) {
        guard let index = virtualWindowIndex(for: channel, createIfNeeded: false) else {
            return
        }
        virtualWindows[index].isOpen = false
    }

    private func appendVirtualWindowOutput(_ data: Data, channel: UInt8) {
        guard let index = virtualWindowIndex(for: channel, createIfNeeded: true) else {
            return
        }
        virtualWindows[index].isOpen = true

        var text = virtualWindows[index].text
        for byte in data {
            switch byte {
            case 0x08, 0x7F:
                if !text.isEmpty {
                    text.removeLast()
                }
            case 0x09:
                text += "    "
            case 0x0A:
                continue
            case 0x0C:
                text = ""
            case 0x0D:
                text += "\n"
            case 0x20...0x7E:
                text.append(Character(UnicodeScalar(byte)))
            default:
                continue
            }
        }

        let maximumCharacters = 12_000
        if text.count > maximumCharacters {
            text = String(text.suffix(maximumCharacters))
        }
        virtualWindows[index].text = text
    }

    private func virtualWindowIndex(for channel: UInt8, createIfNeeded: Bool) -> Int? {
        guard isVirtualWindowChannel(channel) else {
            return nil
        }
        if let index = virtualWindows.firstIndex(where: { $0.channel == channel }) {
            return index
        }
        guard createIfNeeded else {
            return nil
        }
        let window = DriveWireVirtualWindow(
            channel: channel,
            title: virtualWindowTitle(for: channel),
            text: "",
            isOpen: openVirtualSerialChannels.contains(channel)
        )
        let insertionIndex = virtualWindows.firstIndex(where: { $0.channel > channel }) ?? virtualWindows.endIndex
        virtualWindows.insert(window, at: insertionIndex)
        return insertionIndex
    }

    private func processVirtualSerialCommand(_ command: String, channel: UInt8) {
        guard !command.isEmpty else {
            return
        }

        if command.lowercased().hasPrefix("dw ") || command.lowercased() == "dw" {
            let response = processDriveWireAPICommand(command)
            enqueueVirtualSerialResponse(response, channel: channel)
            if response.hasPrefix("OK ") {
                pendingClosedVirtualSerialChannels.append(channel)
            }
        } else if command.lowercased().hasPrefix("tcp ") || command.lowercased() == "tcp" {
            enqueueVirtualSerialResponse(processVirtualSerialTCPCommand(command, channel: channel), channel: channel)
        } else {
            enqueueVirtualSerialResponse(driveWireAPIFailure(code: 10, text: "Unknown command '\(command)'"), channel: channel)
        }
        let msg = "VSerial(ch=\(channel)) command: \(command)"
        log += msg + "\n"; print(msg)
    }

    private func enqueueVirtualSerialResponse(_ response: String, channel: UInt8) {
        virtualSerialInput[channel, default: Data()].append(contentsOf: response.data(using: .ascii) ?? Data())
    }

    private func enqueueDriveWireUtilityResponse(_ text: String, channel: UInt8) {
        enqueueVirtualSerialResponse(driveWireAPISuccess(text), channel: channel)
        pendingClosedVirtualSerialChannels.append(channel)
    }

    private func driveWireAPISuccess(_ text: String) -> String {
        "OK command successful\n\r" + text
    }

    private func driveWireAPIFailure(code: UInt8, text: String) -> String {
        String(format: "FAIL %03d %@\r", Int(code), text)
    }

    private func virtualSerialTCPSuccess(_ text: String = "") -> String {
        text.isEmpty ? "SUCCESS\n\r" : "SUCCESS\n\r" + text
    }

    private func virtualSerialTCPFailure(_ text: String = "") -> String {
        text.isEmpty ? "FAIL\n\r" : "FAIL\n\r" + text
    }

    private func processVirtualSerialTCPCommand(_ command: String, channel: UInt8) -> String {
        let arguments = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard arguments.count >= 2 else {
            return "tcp commands:\n\r    connect <server> <port>\n\r    listen <port>\n\r    join <con#>\n\r    kill <con#>\n\r"
        }

        switch arguments[1].lowercased() {
        case "connect":
            return tcpConnect(Array(arguments.dropFirst(2)), channel: channel)
        case "listen":
            return tcpListen(Array(arguments.dropFirst(2)), channel: channel)
        case "join":
            return tcpJoin(Array(arguments.dropFirst(2)), channel: channel)
        case "kill":
            return tcpKill(Array(arguments.dropFirst(2)))
        default:
            return virtualSerialTCPFailure()
        }
    }

    private func tcpConnect(_ arguments: [String], channel: UInt8) -> String {
        guard arguments.count >= 2, let tcpPort = UInt16(arguments[1]), tcpPort > 0 else {
            return virtualSerialTCPFailure()
        }

        let host = arguments[0]
        virtualSerialTCPConnections[channel]?.close()
        openVirtualSerialChannels.insert(channel)

        let connection = makeVirtualSerialTCPConnection(channel: channel, host: host, port: tcpPort)
        virtualSerialTCPConnections[channel] = connection
        connection.start()
        return virtualSerialTCPSuccess()
    }

    private func tcpListen(_ arguments: [String], channel: UInt8) -> String {
        guard let portText = arguments.first, let tcpPort = UInt16(portText), tcpPort > 0 else {
            return virtualSerialTCPFailure()
        }

        do {
            virtualSerialTCPListeners[tcpPort]?.cancel()
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: tcpPort)!)
            listener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async {
                    self?.acceptVirtualSerialTCPConnection(connection, localPort: tcpPort, announceOn: channel)
                }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    print("Virtual serial TCP listen failed on \(tcpPort): \(error)")
                }
            }
            listener.start(queue: .main)
            virtualSerialTCPListeners[tcpPort] = listener
            openVirtualSerialChannels.insert(channel)
            return virtualSerialTCPSuccess()
        } catch {
            return virtualSerialTCPFailure()
        }
    }

    private func tcpJoin(_ arguments: [String], channel: UInt8) -> String {
        guard let idText = arguments.first, let connectionID = Int(idText),
              let pending = pendingVirtualSerialTCPConnections.removeValue(forKey: connectionID) else {
            return virtualSerialTCPFailure()
        }

        virtualSerialTCPConnections[channel]?.close()
        openVirtualSerialChannels.insert(channel)
        let connection = makeVirtualSerialTCPConnection(
            channel: channel,
            connection: pending.connection,
            host: pending.remoteAddress,
            port: pending.localPort
        )
        virtualSerialTCPConnections[channel] = connection
        connection.start()
        return virtualSerialTCPSuccess()
    }

    private func tcpKill(_ arguments: [String]) -> String {
        guard let idText = arguments.first, let connectionID = Int(idText),
              let pending = pendingVirtualSerialTCPConnections.removeValue(forKey: connectionID) else {
            return virtualSerialTCPFailure()
        }

        pending.connection.cancel()
        return virtualSerialTCPSuccess()
    }

    private func acceptVirtualSerialTCPConnection(_ connection: NWConnection, localPort: UInt16, announceOn channel: UInt8) {
        let connectionID = nextVirtualSerialTCPConnectionID
        nextVirtualSerialTCPConnectionID += 1
        let remoteAddress = remoteAddressDescription(for: connection.endpoint)
        pendingVirtualSerialTCPConnections[connectionID] = PendingVirtualSerialTCPConnection(
            connection: connection,
            localPort: localPort,
            remoteAddress: remoteAddress
        )
        enqueueVirtualSerialResponse("\(connectionID) \(localPort) \(remoteAddress)\n\r", channel: channel)
    }

    private func remoteAddressDescription(for endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _):
            return "\(host)"
        default:
            return "\(endpoint)"
        }
    }

    private func makeVirtualSerialTCPConnection(channel: UInt8, host: String, port: UInt16) -> VirtualSerialTCPConnection {
        VirtualSerialTCPConnection(host: host, port: port, onReceive: { [weak self] data in
            DispatchQueue.main.async {
                self?.virtualSerialInput[channel, default: Data()].append(data)
            }
        }, onClose: { [weak self] in
            DispatchQueue.main.async {
                self?.virtualSerialTCPConnections[channel] = nil
                self?.openVirtualSerialChannels.remove(channel)
            }
        })
    }

    private func makeVirtualSerialTCPConnection(channel: UInt8, connection: NWConnection, host: String, port: UInt16) -> VirtualSerialTCPConnection {
        VirtualSerialTCPConnection(connection: connection, host: host, port: port, onReceive: { [weak self] data in
            DispatchQueue.main.async {
                self?.virtualSerialInput[channel, default: Data()].append(data)
            }
        }, onClose: { [weak self] in
            DispatchQueue.main.async {
                self?.virtualSerialTCPConnections[channel] = nil
                self?.openVirtualSerialChannels.remove(channel)
            }
        })
    }

    private func processDriveWireAPICommand(_ command: String) -> String {
        let arguments = Array(command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init).dropFirst())
        let result = parseDriveWireAPI(arguments)
        switch result {
        case .success(let text):
            return driveWireAPISuccess(text)
        case .failure(let code, let text):
            return driveWireAPIFailure(code: code, text: text)
        }
    }

    private enum DriveWireAPIResult {
        case success(String)
        case failure(UInt8, String)
    }

    private struct DriveWireAPICommand {
        let name: String
        let help: String
    }

    private enum DriveWireAPICommandMatch {
        case success(String)
        case failure(String)
    }

    private func parseDriveWireAPI(_ arguments: [String]) -> DriveWireAPIResult {
        guard let command = arguments.first else {
            return .success(shortHelp(for: [
                DriveWireAPICommand(name: "client", help: "Commands that manage the attached client device"),
                DriveWireAPICommand(name: "config", help: "Commands to manipulate the config"),
                DriveWireAPICommand(name: "disk", help: "Manage disks and disksets"),
                DriveWireAPICommand(name: "instance", help: "Commands to control instances"),
                DriveWireAPICommand(name: "log", help: "View server logs"),
                DriveWireAPICommand(name: "midi", help: "Manage MIDI"),
                DriveWireAPICommand(name: "net", help: "Show network information"),
                DriveWireAPICommand(name: "port", help: "Manage virtual serial ports"),
                DriveWireAPICommand(name: "server", help: "Various server based tools")
            ]))
        }

        switch match(command, in: ["client", "config", "disk", "instance", "log", "midi", "net", "port", "server"]) {
        case .success("client"):
            return parseClientCommand(Array(arguments.dropFirst()))
        case .success("config"):
            return parseConfigCommand(Array(arguments.dropFirst()))
        case .success("disk"):
            return parseDiskCommand(Array(arguments.dropFirst()))
        case .success("instance"):
            return parseInstanceCommand(Array(arguments.dropFirst()))
        case .success("log"):
            return parseLogCommand(Array(arguments.dropFirst()))
        case .success("midi"):
            return parseMIDICommand(Array(arguments.dropFirst()))
        case .success("net"):
            return parseNetCommand(Array(arguments.dropFirst()))
        case .success("port"):
            return parsePortCommand(Array(arguments.dropFirst()))
        case .success("server"):
            return parseServerCommand(Array(arguments.dropFirst()))
        case .success(let name):
            return .failure(204, "Command 'dw \(name)' is not implemented yet.")
        case .failure(let message):
            return .failure(10, message)
        }
    }

    private func parseClientCommand(_ arguments: [String]) -> DriveWireAPIResult {
        guard let command = arguments.first else {
            return .success(shortHelp(for: [
                DriveWireAPICommand(name: "restart", help: "Restart client device")
            ]))
        }

        switch match(command, in: ["restart"]) {
        case .success("restart"):
            clientRestartRequested = true
            return .success("Restart pending\r\n")
        case .success(let name):
            return .failure(204, "Command 'dw client \(name)' is not implemented yet.")
        case .failure(let message):
            return .failure(10, message)
        }
    }

    private func parseConfigCommand(_ arguments: [String]) -> DriveWireAPIResult {
        guard let command = arguments.first else {
            return .success(shortHelp(for: [
                DriveWireAPICommand(name: "save", help: "Save current configuration"),
                DriveWireAPICommand(name: "set", help: "Set config item"),
                DriveWireAPICommand(name: "show", help: "Show current instance config (or item)")
            ]))
        }

        switch match(command, in: ["save", "set", "show"]) {
        case .success("save"):
            return .success("Configuration saved.\r\n")
        case .success("set"):
            return configSet(Array(arguments.dropFirst()))
        case .success("show"):
            return configShow(Array(arguments.dropFirst()))
        case .success(let name):
            return .failure(204, "Command 'dw config \(name)' is not implemented yet.")
        case .failure(let message):
            return .failure(10, message)
        }
    }

    private func parseDiskCommand(_ arguments: [String]) -> DriveWireAPIResult {
        guard let command = arguments.first else {
            return .success(shortHelp(for: [
                DriveWireAPICommand(name: "create", help: "Create disk image"),
                DriveWireAPICommand(name: "dos", help: "Manage DOS disk images"),
                DriveWireAPICommand(name: "eject", help: "Eject disk from drive #"),
                DriveWireAPICommand(name: "insert", help: "Load disk into drive #"),
                DriveWireAPICommand(name: "dump", help: "Dump sector from disk"),
                DriveWireAPICommand(name: "reload", help: "Reload disk in drive #"),
                DriveWireAPICommand(name: "set", help: "Set disk parameter"),
                DriveWireAPICommand(name: "show", help: "Show current disk details"),
                DriveWireAPICommand(name: "write", help: "Write dirty sectors")
            ]))
        }

        switch match(command, in: ["create", "dos", "dump", "eject", "insert", "reload", "set", "show", "write"]) {
        case .success("create"):
            return diskCreate(Array(arguments.dropFirst()))
        case .success("dump"):
            return diskDump(Array(arguments.dropFirst()))
        case .success("eject"):
            return diskEject(Array(arguments.dropFirst()))
        case .success("insert"):
            return diskInsert(Array(arguments.dropFirst()))
        case .success("reload"):
            return diskReload(Array(arguments.dropFirst()))
        case .success("set"):
            return diskSet(Array(arguments.dropFirst()))
        case .success("show"):
            return diskShow(Array(arguments.dropFirst()))
        case .success("write"):
            return diskWrite(Array(arguments.dropFirst()))
        case .success(let name):
            return .failure(204, "Command 'dw disk \(name)' is not implemented yet.")
        case .failure(let message):
            return .failure(10, message)
        }
    }

    private func parseInstanceCommand(_ arguments: [String]) -> DriveWireAPIResult {
        guard let command = arguments.first else {
            return .success(shortHelp(for: [
                DriveWireAPICommand(name: "restart", help: "Restart instance #"),
                DriveWireAPICommand(name: "show", help: "Show instance status"),
                DriveWireAPICommand(name: "start", help: "Start instance #"),
                DriveWireAPICommand(name: "stop", help: "Stop instance #")
            ]))
        }

        switch match(command, in: ["restart", "show", "start", "stop"]) {
        case .success("show"):
            return instanceShow()
        case .success("start"):
            return instanceLifecycle(arguments: Array(arguments.dropFirst()), action: "start")
        case .success("stop"):
            return instanceLifecycle(arguments: Array(arguments.dropFirst()), action: "stop")
        case .success("restart"):
            return instanceLifecycle(arguments: Array(arguments.dropFirst()), action: "restart")
        case .success(let name):
            return .failure(204, "Command 'dw instance \(name)' is not implemented yet.")
        case .failure(let message):
            return .failure(10, message)
        }
    }

    private func parseLogCommand(_ arguments: [String]) -> DriveWireAPIResult {
        guard let command = arguments.first else {
            return .success(shortHelp(for: [
                DriveWireAPICommand(name: "show", help: "Show last 20 (or #) log entries")
            ]))
        }

        switch match(command, in: ["show"]) {
        case .success("show"):
            return logShow(Array(arguments.dropFirst()))
        case .success(let name):
            return .failure(204, "Command 'dw log \(name)' is not implemented yet.")
        case .failure(let message):
            return .failure(10, message)
        }
    }

    private func parseMIDICommand(_ arguments: [String]) -> DriveWireAPIResult {
        guard let command = arguments.first else {
            return .success(shortHelp(for: [
                DriveWireAPICommand(name: "output", help: "Set midi output to device #"),
                DriveWireAPICommand(name: "status", help: "Show MIDI status"),
                DriveWireAPICommand(name: "synth", help: "Manage the MIDI synthesizer")
            ]))
        }

        switch match(command, in: ["output", "status", "synth"]) {
        case .success("output"):
            return midiOutput(Array(arguments.dropFirst()))
        case .success("status"):
            return midiStatus()
        case .success("synth"):
            return midiSynth(Array(arguments.dropFirst()))
        case .success(let name):
            return .failure(204, "Command 'dw midi \(name)' is not implemented yet.")
        case .failure(let message):
            return .failure(10, message)
        }
    }

    private func parseNetCommand(_ arguments: [String]) -> DriveWireAPIResult {
        guard let command = arguments.first else {
            return .success(shortHelp(for: [
                DriveWireAPICommand(name: "show", help: "Show networking status")
            ]))
        }

        switch match(command, in: ["show"]) {
        case .success("show"):
            return netShow()
        case .success(let name):
            return .failure(204, "Command 'dw net \(name)' is not implemented yet.")
        case .failure(let message):
            return .failure(10, message)
        }
    }

    private func parsePortCommand(_ arguments: [String]) -> DriveWireAPIResult {
        guard let command = arguments.first else {
            return .success(shortHelp(for: [
                DriveWireAPICommand(name: "close", help: "Close port #"),
                DriveWireAPICommand(name: "open", help: "Open port #"),
                DriveWireAPICommand(name: "show", help: "Show port status")
            ]))
        }

        switch match(command, in: ["close", "open", "show"]) {
        case .success("close"):
            return portClose(Array(arguments.dropFirst()))
        case .success("open"):
            return portOpen(Array(arguments.dropFirst()))
        case .success("show"):
            return portShow()
        case .success(let name):
            return .failure(204, "Command 'dw port \(name)' is not implemented yet.")
        case .failure(let message):
            return .failure(10, message)
        }
    }

    private func parseServerCommand(_ arguments: [String]) -> DriveWireAPIResult {
        guard let command = arguments.first else {
            return .success(shortHelp(for: [
                DriveWireAPICommand(name: "dir", help: "List files on server"),
                DriveWireAPICommand(name: "help", help: "Show help"),
                DriveWireAPICommand(name: "list", help: "List contents of file on server"),
                DriveWireAPICommand(name: "print", help: "Print file on server"),
                DriveWireAPICommand(name: "show", help: "Show various server information"),
                DriveWireAPICommand(name: "status", help: "Show server status information"),
                DriveWireAPICommand(name: "turbo", help: "Show turbo status")
            ]))
        }

        switch match(command, in: ["dir", "help", "list", "print", "show", "status", "turbo"]) {
        case .success("dir"):
            return serverDir(Array(arguments.dropFirst()))
        case .success("list"):
            return serverList(Array(arguments.dropFirst()))
        case .success("help"):
            return serverHelp(Array(arguments.dropFirst()))
        case .success("print"):
            return serverPrint(Array(arguments.dropFirst()))
        case .success("status"):
            return serverStatus()
        case .success("show"):
            return serverShow(Array(arguments.dropFirst()))
        case .success("turbo"):
            return serverTurbo()
        case .success(let name):
            return .failure(204, "Command 'dw server \(name)' is not implemented yet.")
        case .failure(let message):
            return .failure(10, message)
        }
    }

    private func match(_ input: String, in commands: [String]) -> DriveWireAPICommandMatch {
        let matches = commands.filter { $0.hasPrefix(input.lowercased()) }
        if matches.count == 1 {
            return .success(matches[0])
        } else if matches.isEmpty {
            return .failure("Unknown command '\(input)'")
        } else {
            return .failure("Ambiguous command, '\(input)' matches \(matches.joined(separator: " or "))")
        }
    }

    private func shortHelp(for commands: [DriveWireAPICommand]) -> String {
        let names = commands.map(\.name).sorted()
        return "Possible commands:\r\n\r\n" + columnLayout(names) + "\r\n"
    }

    private func columnLayout(_ values: [String], columns: Int = 80) -> String {
        guard !values.isEmpty else { return "" }
        let width = (values.map(\.count).max() ?? 1) + 2
        let perLine = max(1, (columns - 1) / width)
        var lines: [String] = []
        var current = ""
        for (index, value) in values.enumerated() {
            if index > 0 && index % perLine == 0 {
                lines.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
            current += value.padding(toLength: width, withPad: " ", startingAt: 0)
        }
        if !current.isEmpty {
            lines.append(current.trimmingCharacters(in: .whitespaces))
        }
        return lines.joined(separator: "\r\n")
    }

    private func currentDriveWireAPIConfig() -> [String: String] {
        var items = [
            "CMDCols": "80",
            "DeviceType": "swift",
            "DetailedOpcodeLogging": detailedOpcodeLogging ? "true" : "false",
            "HostCapabilityByte": "255",
            "MountedDrives": "\(virtualDrives.count)",
            "ProtectedMode": "false"
        ]
        for (key, value) in driveWireAPIConfig {
            items[key] = value
        }
        return items
    }

    private func configShow(_ arguments: [String]) -> DriveWireAPIResult {
        let items = currentDriveWireAPIConfig()

        if let key = arguments.first {
            if let value = items.first(where: { $0.key.lowercased() == key.lowercased() }) {
                return .success("\(value.key) = \(value.value)\r\n")
            }
            return .failure(142, "Key '\(key)' is not set.")
        }

        let text = items.keys.sorted()
            .map { "\($0) = \(items[$0] ?? "")" }
            .joined(separator: "\r\n")
        return .success("Current protocol handler configuration:\r\n\n\(text)\r\n")
    }

    private func configSet(_ arguments: [String]) -> DriveWireAPIResult {
        guard let item = arguments.first else {
            return .failure(10, "Syntax error: dw config set requires an item and value as arguments")
        }

        if arguments.count == 1 {
            driveWireAPIConfig.removeValue(forKey: item)
            return .success("Item '\(item)' removed from config\r\n")
        }

        let value = arguments.dropFirst().joined(separator: " ")
        driveWireAPIConfig[item] = value
        return .success("Item '\(item)' set to '\(value)'\r\n")
    }

    private func instanceShow() -> DriveWireAPIResult {
        var text = "DriveWire protocol handler instances:\r\n\n"
        text += "#0  (Ready)     "
        text += String(format: "Proto: %-11@", "DriveWire")
        text += String(format: "Type: %-11@", "swift")
        text += "Drives: \(virtualDrives.count) Ports: \(openVirtualSerialChannels.count)\r\n"
        return .success(text)
    }

    private func instanceLifecycle(arguments: [String], action: String) -> DriveWireAPIResult {
        guard let argument = arguments.first, arguments.count == 1 else {
            return .failure(10, "Syntax error: dw instance \(action) requires an instance # as an argument")
        }
        guard let instanceNumber = Int(argument) else {
            return .failure(10, "dw instance \(action) requires a numeric instance # as an argument")
        }
        guard instanceNumber == 0 else {
            return .failure(218, "Invalid instance number.")
        }
        return .failure(204, "Instance \(action) is not supported by the single-instance Swift server.")
    }

    private func logShow(_ arguments: [String]) -> DriveWireAPIResult {
        let lineCount: Int
        if let argument = arguments.first {
            guard arguments.count == 1, let parsed = Int(argument), parsed >= 0 else {
                return .failure(10, "Syntax error: non numeric # of log lines")
            }
            lineCount = parsed
        } else {
            lineCount = 20
        }

        let lines = logStorage.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let selected = lines.suffix(lineCount).joined(separator: "\r\n")
        var text = "\r\nDriveWire Server Log (\(lines.count) events in buffer):\r\n\n"
        if !selected.isEmpty {
            text += selected
            if !text.hasSuffix("\r\n") {
                text += "\r\n"
            }
        }
        return .success(text)
    }

    private func midiStatus() -> DriveWireAPIResult {
        var text = "\r\nDriveWire MIDI status:\r\n\n"
        for line in midiBackend.statusLines() {
            text += line + "\r\n"
        }
        text += "\r\n"
        return .success(text)
    }

    private func midiOutput(_ arguments: [String]) -> DriveWireAPIResult {
        if let argument = arguments.first {
            guard arguments.count == 1, let outputIndex = Int(argument) else {
                return .failure(10, "Syntax error: dw midi output requires a numeric device #")
            }

            do {
                try midiBackend.selectOutput(index: outputIndex)
                return .success("MIDI output set to \(midiBackend.selectedOutputName ?? "device #\(outputIndex)").\r\n")
            } catch {
                return .failure(204, error.localizedDescription)
            }
        }

        var text = "\r\nDriveWire MIDI output devices:\r\n\n"
        let devices = midiBackend.outputDevices()
        if devices.isEmpty {
            text += "No MIDI output devices available.\r\n"
        } else {
            for device in devices {
                let marker = device.isSelected ? "*" : " "
                text += String(format: "%@%3d  %@\r\n", marker, device.index, device.name)
            }
        }
        text += "\r\n"
        return .success(text)
    }

    private func midiSynth(_ arguments: [String]) -> DriveWireAPIResult {
        guard let command = arguments.first else {
            return .success(shortHelp(for: [
                DriveWireAPICommand(name: "reset", help: "Reset the selected MIDI output"),
                DriveWireAPICommand(name: "status", help: "Show MIDI synthesizer status")
            ]))
        }

        switch match(command, in: ["reset", "status"]) {
        case .success("reset"):
            do {
                try midiBackend.reset()
                return .success("MIDI synthesizer reset sent.\r\n")
            } catch {
                return .failure(204, error.localizedDescription)
            }
        case .success("status"):
            return midiStatus()
        case .success(let name):
            return .failure(204, "Command 'dw midi synth \(name)' is not implemented yet.")
        case .failure(let message):
            return .failure(10, message)
        }
    }

    private func netShow() -> DriveWireAPIResult {
        var text = "\r\nDriveWire Network Connections:\r\n\n"
        let connections = virtualSerialTCPConnections.sorted { $0.key < $1.key }
        if connections.isEmpty {
            text += "No active network connections.\r\n"
        } else {
            for (index, item) in connections.enumerated() {
                let channel = Int(item.key)
                let connection = item.value
                text += "Connection \(index): \(connection.host):\(connection.port) (connected to port /N\(channel + 1))\r\n"
            }
        }
        text += "\r\n"
        return .success(text)
    }

    private func diskCreate(_ arguments: [String]) -> DriveWireAPIResult {
        guard let driveArgument = arguments.first else {
            return .failure(10, "Syntax error")
        }
        guard let driveNumber = parseDriveNumber(driveArgument) else {
            return .failure(101, "Invalid drive number '\(driveArgument)'")
        }

        if arguments.count == 1 {
            ejectVirtualDisk(driveNumber: driveNumber)
            let drive = VirtualDrive(driveNumber: driveNumber)
            virtualDrives.append(drive)
            return .success("New image created for drive \(driveNumber).\r\n")
        }

        let path = arguments.dropFirst().joined(separator: " ")
        let url = serverFileURL(from: path)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return .failure(202, "File already exists")
        }

        do {
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
                return .failure(202, "Unable to create file")
            }
            ejectVirtualDisk(driveNumber: driveNumber)
            try insertVirtualDisk(driveNumber: driveNumber, imagePath: url.path)
            return .success("New disk image created for drive \(driveNumber).\r\n")
        } catch {
            return .failure(202, error.localizedDescription)
        }
    }

    private func diskShow(_ arguments: [String]) -> DriveWireAPIResult {
        guard let driveArgument = arguments.first else {
            var text = "\r\nCurrent DriveWire disks:\r\n\r\n"
            for drive in virtualDrives.sorted(by: { $0.driveNumber < $1.driveNumber }) {
                text += String(format: "X%-3d ", drive.driveNumber)
                text += shortenedPath(drive.imagePath) + "\r\n"
            }
            return .success(text)
        }

        guard let driveNumber = parseDriveNumber(driveArgument) else {
            return .failure(101, "Invalid drive number '\(driveArgument)'")
        }
        guard let drive = virtualDrives.first(where: { $0.driveNumber == driveNumber }) else {
            return .failure(102, "Drive \(driveNumber) is not loaded.")
        }

        var text = "Details for disk in drive #\(driveNumber):\r\n\r\n"
        text += shortenedPath(drive.imagePath) + "\r\n\r\n"
        text += "System params:\r\n"
        text += "path: \(drive.imagePath)\r\n"
        let params = virtualDriveParameters[driveNumber] ?? [:]
        if !params.isEmpty {
            text += columnLayout(params.keys.sorted().map { "\($0): \(params[$0] ?? "")" }) + "\r\n"
        }
        text += "User params:\r\n"
        return .success(text)
    }

    private func diskInsert(_ arguments: [String]) -> DriveWireAPIResult {
        guard arguments.count >= 2 else {
            return .failure(10, "Syntax error")
        }
        guard let driveNumber = parseDriveNumber(arguments[0]) else {
            return .failure(101, "Invalid drive number '\(arguments[0])'")
        }
        let path = arguments.dropFirst().joined(separator: " ")
        do {
            try insertVirtualDisk(driveNumber: driveNumber, imagePath: path)
            return .success("Disk inserted in drive \(driveNumber).\r\n")
        } catch {
            return .failure(216, error.localizedDescription)
        }
    }

    private func diskEject(_ arguments: [String]) -> DriveWireAPIResult {
        guard let argument = arguments.first, arguments.count == 1 else {
            return .failure(10, "Syntax error")
        }
        if argument.lowercased() == "all" {
            virtualDrives.removeAll()
            return .success("Ejected all disks.\r\n")
        }
        guard let driveNumber = parseDriveNumber(argument) else {
            return .failure(101, "Invalid drive number '\(argument)'")
        }
        guard virtualDrives.contains(where: { $0.driveNumber == driveNumber }) else {
            return .failure(102, "Drive \(driveNumber) is not loaded.")
        }
        ejectVirtualDisk(driveNumber: driveNumber)
        return .success("Disk ejected from drive \(driveNumber).\r\n")
    }

    private func diskReload(_ arguments: [String]) -> DriveWireAPIResult {
        guard let argument = arguments.first, arguments.count == 1 else {
            return .failure(10, "dw disk reload requires a drive # or 'all' as an argument")
        }
        if argument.lowercased() == "all" {
            reloadVirtualDrives()
            return .success("All disks reloaded.\r\n")
        }
        guard let driveNumber = parseDriveNumber(argument) else {
            return .failure(10, "Syntax error: non numeric drive #")
        }
        guard virtualDrives.contains(where: { $0.driveNumber == driveNumber }) else {
            return .failure(102, "Drive \(driveNumber) is not loaded.")
        }
        virtualDrives.first(where: { $0.driveNumber == driveNumber })?.reload()
        return .success("Disk in drive #\(driveNumber) reloaded.\r\n")
    }

    private func diskDump(_ arguments: [String]) -> DriveWireAPIResult {
        guard arguments.count >= 2 else {
            return .failure(10, "dw disk dump requires a drive # and sector # as arguments")
        }
        guard let driveNumber = parseDriveNumber(arguments[0]),
              let sectorNumber = Int(arguments[1]) else {
            return .failure(10, "Syntax error: non numeric drive # or sector #")
        }
        guard let drive = virtualDrives.first(where: { $0.driveNumber == driveNumber }) else {
            return .failure(102, "Drive \(driveNumber) is not loaded.")
        }

        let (_, sector) = drive.readSector(lsn: sectorNumber)
        return .success(hexDump(sector, baseAddress: sectorNumber * 256))
    }

    private func diskSet(_ arguments: [String]) -> DriveWireAPIResult {
        guard arguments.count >= 3 else {
            return .failure(10, "dw disk set requires 3 arguments.")
        }
        guard let driveNumber = parseDriveNumber(arguments[0]) else {
            return .failure(101, "Invalid drive number '\(arguments[0])'")
        }
        guard virtualDrives.contains(where: { $0.driveNumber == driveNumber }) else {
            return .failure(102, "Drive \(driveNumber) is not loaded.")
        }

        let parameter = arguments[1]
        let value = arguments.dropFirst(2).joined(separator: " ")
        virtualDriveParameters[driveNumber, default: [:]][parameter] = value
        return .success("Param '\(parameter)' set for disk \(driveNumber).\r\n")
    }

    private func diskWrite(_ arguments: [String]) -> DriveWireAPIResult {
        guard !arguments.isEmpty else {
            return .failure(10, "Syntax error")
        }
        guard let driveNumber = parseDriveNumber(arguments[0]) else {
            return .failure(101, "Invalid drive number.")
        }
        guard let drive = virtualDrives.first(where: { $0.driveNumber == driveNumber }) else {
            return .failure(102, "Drive \(driveNumber) is not loaded.")
        }

        let path = arguments.count > 1 ? arguments.dropFirst().joined(separator: " ") : nil
        do {
            try drive.save(to: path)
            if let path {
                return .success("Wrote disk #\(driveNumber) to '\(path)'\r\n")
            }
            return .success("Wrote disk #\(driveNumber) to source image.\r\n")
        } catch {
            return .failure(202, error.localizedDescription)
        }
    }

    private func portOpen(_ arguments: [String]) -> DriveWireAPIResult {
        guard arguments.count >= 2 else {
            return .failure(10, "dw port open requires a port # and tcphost:port as an argument")
        }
        guard let portNumber = Int(arguments[0]), portNumber >= 0, portNumber < 15 else {
            return .failure(10, "Syntax error: non numeric port #")
        }

        let hostPort = arguments[1]
        guard let separator = hostPort.lastIndex(of: ":") else {
            return .failure(10, "Syntax error: expected tcphost:port")
        }
        let host = String(hostPort[..<separator])
        let portText = String(hostPort[hostPort.index(after: separator)...])
        guard !host.isEmpty, let tcpPort = UInt16(portText), tcpPort > 0 else {
            return .failure(10, "Syntax error: non numeric tcp port")
        }

        let channel = UInt8(portNumber)
        virtualSerialTCPConnections[channel]?.close()
        openVirtualSerialChannels.insert(channel)

        let connection = makeVirtualSerialTCPConnection(channel: channel, host: host, port: tcpPort)
        virtualSerialTCPConnections[channel] = connection
        connection.start()

        return .success("Port #\(portNumber) open.\r\n")
    }

    private func portClose(_ arguments: [String]) -> DriveWireAPIResult {
        guard let portArgument = arguments.first else {
            return .failure(10, "dw port close requires a port # as an argument")
        }
        guard arguments.count == 1, let portNumber = Int(portArgument), portNumber >= 0, portNumber < 15 else {
            return .failure(10, "Syntax error: non numeric port #")
        }

        let channel = UInt8(portNumber)
        virtualSerialTCPConnections[channel]?.close()
        virtualSerialTCPConnections[channel] = nil
        openVirtualSerialChannels.remove(channel)
        virtualSerialInput[channel]?.removeAll()
        virtualSerialCommandBuffers[channel] = ""
        return .success("Port #\(portNumber) closed.\r\n")
    }

    private func portShow() -> DriveWireAPIResult {
        var text = "\r\nCurrent port status:\r\n\n"
        for port in 0..<15 {
            let channel = UInt8(port)
            text += "/N\(port + 1)".padding(toLength: 6, withPad: " ", startingAt: 0)
            if openVirtualSerialChannels.contains(channel) {
                let waiting = virtualSerialInput[channel]?.count ?? 0
                text += " "
                text += "open".padding(toLength: 8, withPad: " ", startingAt: 0)
                text += " "
                text += "buf: \(waiting)".padding(toLength: 9, withPad: " ", startingAt: 0)
                if let connection = virtualSerialTCPConnections[channel] {
                    text += " tcp: \(connection.host):\(connection.port)"
                }
            } else {
                text += " closed"
            }
            text += "\r\n"
        }
        return .success(text)
    }

    private func serverStatus() -> DriveWireAPIResult {
        var text = "DriveWire Swift status:\r\n\n"
        text += "Device:        Swift host\r\n"
        text += "DW4 support:   enabled\r\n"
        text += "Virtual disks: \(virtualDrives.count)\r\n"
        text += "Open ports:    \(openVirtualSerialChannels.count)\r\n"
        text += "Last opcode:   0x\(String(statistics.lastOpCode, radix: 16))\r\n"
        text += "Reads:         \(statistics.readCount)\r\n"
        text += "Writes:        \(statistics.writeCount)\r\n"
        return .success(text)
    }

    private func serverShow(_ arguments: [String]) -> DriveWireAPIResult {
        guard let command = arguments.first else {
            return .success(shortHelp(for: [
                DriveWireAPICommand(name: "serial", help: "Show serial status"),
                DriveWireAPICommand(name: "threads", help: "Show thread information"),
                DriveWireAPICommand(name: "timers", help: "Show instance timers")
            ]))
        }

        switch match(command, in: ["serial", "threads", "timers"]) {
        case .success("serial"):
            return serverShowSerial()
        case .success("threads"):
            return serverShowThreads()
        case .success("timers"):
            return serverShowTimers()
        case .success(let name):
            return .failure(204, "Command 'dw server show \(name)' is not implemented yet.")
        case .failure(let message):
            return .failure(10, message)
        }
    }

    private func serverHelp(_ arguments: [String]) -> DriveWireAPIResult {
        guard let command = arguments.first else {
            return .success(shortHelp(for: [
                DriveWireAPICommand(name: "reload", help: "Reload help topics"),
                DriveWireAPICommand(name: "show", help: "Show help topic")
            ]))
        }

        switch match(command, in: ["reload", "show"]) {
        case .success("show"):
            return serverHelpShow(Array(arguments.dropFirst()))
        case .success("reload"):
            return .success("Help topics reloaded.\r\n")
        case .success(let name):
            return .failure(204, "Command 'dw server help \(name)' is not implemented yet.")
        case .failure(let message):
            return .failure(10, message)
        }
    }

    private func serverHelpShow(_ arguments: [String]) -> DriveWireAPIResult {
        let topics = [
            "config": "View and update DriveWire protocol handler configuration.",
            "disk": "Create, insert, eject, inspect, and write DriveWire disk images.",
            "log": "View recent Swift server log entries.",
            "midi": "Show MIDI status, select an output device, and reset the selected synthesizer.",
            "net": "Show TCP connections used by virtual serial ports.",
            "port": "Show, close, or connect virtual serial ports.",
            "server": "Show server status and access host-side files."
        ]

        if let topic = arguments.first {
            if let text = topics[topic.lowercased()] {
                return .success("Help for \(topic):\r\n\r\n\(text)\r\n")
            }
            return .failure(142, "Help topic '\(topic)' not found.")
        }

        return .success("Help Topics:\r\n\r\n" + topics.keys.sorted().joined(separator: "\r\n") + "\r\n")
    }

    private func serverShowSerial() -> DriveWireAPIResult {
        var text = "\r\nDriveWire serial status:\r\n\n"
        text += "Open virtual channels: \(openVirtualSerialChannels.sorted().map { "/N\(Int($0) + 1)" }.joined(separator: ", "))\r\n"
        text += "TCP-backed channels: \(virtualSerialTCPConnections.count)\r\n"
        text += "Pending close notifications: \(pendingClosedVirtualSerialChannels.count)\r\n"
        text += "Client restart pending: \(clientRestartRequested ? "true" : "false")\r\n"
        return .success(text)
    }

    private func serverShowThreads() -> DriveWireAPIResult {
        var text = "\r\nDriveWire Server Threads:\r\n\n"
        text += String(format: "%40@ %3d %-8@ %-14@\r\n", "main", 0, "Swift", Thread.isMainThread ? "RUNNABLE" : "UNKNOWN")
        text += String(format: "%40@ %3d %-8@ %-14@\r\n", "virtual-serial-tcp", 0, "Swift", virtualSerialTCPConnections.isEmpty ? "IDLE" : "RUNNABLE")
        return .success(text)
    }

    private func serverShowTimers() -> DriveWireAPIResult {
        var text = "DriveWire instance timers (not shown == 0):\r\n\r\n"
        text += "No active instance timers.\r\n"
        return .success(text)
    }

    private func serverTurbo() -> DriveWireAPIResult {
        .success("Failed to enable DATurbo mode: active device does not support serial baud-rate switching.\r\n")
    }

    private func serverDir(_ arguments: [String]) -> DriveWireAPIResult {
        guard !arguments.isEmpty else {
            return .failure(10, "dw server dir requires a URI or path as an argument")
        }

        let path = arguments.joined(separator: " ")
        let url = serverFileURL(from: path)
        do {
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .map { $0.lastPathComponent }
                .sorted()
            var text = "Directory of \(url.path)\r\n\n"
            let width = (children.map(\.count).max() ?? 1) + 2
            let perLine = max(1, 80 / max(width, 1))
            for (index, child) in children.enumerated() {
                text += child.padding(toLength: width, withPad: " ", startingAt: 0)
                if (index + 1) % perLine == 0 {
                    text += "\r\n"
                }
            }
            if !text.hasSuffix("\r\n") {
                text += "\r\n"
            }
            return .success(text)
        } catch {
            return .failure(201, error.localizedDescription)
        }
    }

    private func serverList(_ arguments: [String]) -> DriveWireAPIResult {
        guard !arguments.isEmpty else {
            return .failure(10, "dw server list requires a URI or local file path as an argument")
        }

        let path = arguments.joined(separator: " ")
        do {
            let data = try Data(contentsOf: serverFileURL(from: path))
            let text: String
            if let utf8 = String(data: data, encoding: .utf8) {
                text = utf8
            } else if let ascii = String(data: data, encoding: .ascii) {
                text = ascii
            } else {
                text = data.map { byte -> String in
                    if byte == 0x0A {
                        return "\r\n"
                    }
                    return String(UnicodeScalar(Int(byte)) ?? ".")
                }.joined()
            }
            return .success(text.hasSuffix("\r") || text.hasSuffix("\n") ? text : text + "\r\n")
        } catch {
            return .failure(202, error.localizedDescription)
        }
    }

    private func serverPrint(_ arguments: [String]) -> DriveWireAPIResult {
        guard !arguments.isEmpty else {
            return .failure(10, "dw server print requires a URI or local file path as an argument")
        }

        let path = arguments.joined(separator: " ")
        do {
            printBuffer.append(try Data(contentsOf: serverFileURL(from: path)))
            return .success("Sent item to printer\r\n")
        } catch {
            return .failure(202, error.localizedDescription)
        }
    }

    private func parseDriveNumber(_ value: String) -> Int? {
        let trimmed = value.uppercased().hasPrefix("X") ? String(value.dropFirst()) : value
        guard let number = Int(trimmed), number >= 0, number <= 255 else {
            return nil
        }
        return number
    }

    private func serverFileURL(from path: String) -> URL {
        let normalized = path.replacingOccurrences(of: "*", with: "!")
        if let url = URL(string: normalized), url.isFileURL {
            return url
        }
        if normalized.hasPrefix("~/") {
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(String(normalized.dropFirst(2)))
        }
        if (normalized as NSString).isAbsolutePath {
            return URL(fileURLWithPath: normalized)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(normalized)
    }

    private func hexDump(_ data: Data, baseAddress: Int) -> String {
        var lines: [String] = []
        let bytes = Array(data)
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let chunk = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
                .padding(toLength: 47, withPad: " ", startingAt: 0)
            let ascii = chunk.map { byte -> String in
                byte >= 0x20 && byte < 0x7F ? String(UnicodeScalar(byte)) : "."
            }.joined()
            lines.append(String(format: "%06X  %@  %@", baseAddress + offset, hex, ascii))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private func shortenedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func isVirtualWindowChannel(_ channel: UInt8) -> Bool {
        channel >= 0x81 && channel <= 0x8F
    }

    private func virtualWindowTitle(for channel: UInt8) -> String {
        "/Z\(Int(channel & 0x0F))"
    }

    private func virtualWindowGuestChannel(forInternalChannel channel: UInt8) -> UInt8 {
        0x40 | (channel & 0x0F)
    }

    private func virtualSerialInputChannel(forGuestChannel channel: UInt8) -> UInt8 {
        if channel & 0xC0 == 0x40 {
            let virtualWindowChannel = 0x80 | (channel & 0x0F)
            if isVirtualWindowChannel(virtualWindowChannel), virtualSerialInput[virtualWindowChannel] != nil {
                return virtualWindowChannel
            }
        }
        return channel
    }

    private func OP_FASTWRITE_Serial(data : Data) -> Int {
        guard data.count >= 2 else { return 0 }
        writeVirtualSerial(channel: fastwriteChannel, data: Data([data[1]]))
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        return 2
    }
    
    private func OP_FASTWRITE_Screen(data : Data) -> Int {
        guard data.count >= 2 else { return 0 }
        writeVirtualSerial(channel: 0x81 &+ fastwriteChannel, data: Data([data[1]]))
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        return 2
    }
    
    private func OP_RFM(data : Data) -> Int {
        var result = 0
        let expectedCount = 2
        currentTransaction = OPRFM

        if data.count >= expectedCount {
            result = expectedCount
            let rfmSubOp = data[1]
            currentSubTransaction = rfmSubOp
            switch currentSubTransaction {
            case DWRFMTransaction.OP_RFM_CREATE.rawValue:
                processor = OPRFMCREATE
            case DWRFMTransaction.OP_RFM_OPEN.rawValue:
                processor = OPRFMOPEN
            case DWRFMTransaction.OP_RFM_MAKDIR.rawValue:
                processor = OPRFMMAKDIR
            case DWRFMTransaction.OP_RFM_CHGDIR.rawValue:
                processor = OPRFMCHGDIR
            case DWRFMTransaction.OP_RFM_DELETE.rawValue:
                processor = OPRFMDELETE
            case DWRFMTransaction.OP_RFM_SEEK.rawValue:
                processor = OPRFMSEEK
            case DWRFMTransaction.OP_RFM_READ.rawValue:
                processor = OPRFMREAD
            case DWRFMTransaction.OP_RFM_WRITE.rawValue:
                processor = OPRFMWRITE
            case DWRFMTransaction.OP_RFM_READLN.rawValue:
                processor = OPRFMREADLN
            case DWRFMTransaction.OP_RFM_WRITLN.rawValue:
                processor = OPRFMWRITLN
            case DWRFMTransaction.OP_RFM_GETSTT.rawValue:
                processor = OPRFMGETSTT
            case DWRFMTransaction.OP_RFM_SETSTT.rawValue:
                processor = OPRFMSETSTT
            case DWRFMTransaction.OP_RFM_CLOSE.rawValue:
                processor = OPRFMCLOSE
            default:
                resetState()
                delegate?.transactionCompleted(opCode: currentTransaction)
            }
        }
        
        return result
    }
    
    private func OPRFMCREATE(data : Data) -> Int {
        return rfmOpen(data: data, shouldCreate: true)
    }

    // Receives: path#(1) + processID(1) + mode(1), then pathname terminated by CR ($0D).
    // Sends back: 1-byte error code.
    private func OPRFMOPEN(data : Data) -> Int {
        return rfmOpen(data: data, shouldCreate: false)
    }

    private func rfmOpen(data: Data, shouldCreate: Bool) -> Int {
        var result = 0
        let expectedCount = 4
        var capturedPathNumber = 0

        if data.count >= expectedCount {
            capturedPathNumber = Int(data[0])
            var descriptor = RFMPathDescriptor()
            descriptor.pathNumber = capturedPathNumber
            descriptor.processID = Int(data[1])
            descriptor.parentProcessID = Int(data[2])
            descriptor.mode = Int(data[3])
            rfmPaths[capturedPathNumber] = descriptor
            result = expectedCount
            processor = OPRFMGETPATH
        }

        return result

        func OPRFMGETPATH(data: Data) -> Int {
            guard let crOffset = data.firstIndex(of: 0x0D) else { return 0 }
            let pathBytes = data[data.startIndex..<crOffset].map { $0 & 0x7F }
            let pid = rfmPaths[capturedPathNumber]?.processID ?? 0
            let ppid = rfmPaths[capturedPathNumber]?.parentProcessID ?? 0
            let mode = rfmPaths[capturedPathNumber]?.mode ?? 0
            let isExec = (mode & 0x04) != 0
            let pathname = resolveRFMPathname(String(bytes: pathBytes, encoding: .ascii) ?? "",
                                              processID: pid, parentProcessID: ppid, isExec: isExec)
            rfmPaths[capturedPathNumber]?.pathname = pathname
            let errorCode = rfmPaths[capturedPathNumber]?.openLocalFile(rootPath: rfmRootPath, shouldCreate: shouldCreate) ?? 0xFF
            if errorCode != 0 {
                // Failed open — remove the descriptor so the slot is clean for reuse.
                rfmPaths.removeValue(forKey: capturedPathNumber)
            }
            // For directory opens, synthesize OS-9 directory entries with stable LSNs.
            if errorCode == 0, let descriptor = rfmPaths[capturedPathNumber], descriptor.mode & 0x80 != 0 {
                rfmPaths[capturedPathNumber]?.fileContents = synthesizeDirectoryEntries(for: descriptor)
            }
            delegate?.dataAvailable(host: self, data: Data([errorCode]))
            let dirLabel = isExec ? "execDir" : "dataDir"
            let dirVal = isExec
                ? (rfmCurrentExecDir[pid] ?? rfmCurrentExecDir[ppid] ?? "none")
                : (rfmCurrentDir[pid] ?? rfmCurrentDir[ppid] ?? "none")
            let msg = "OP_RFM_\(shouldCreate ? "CREATE" : "OPEN")(path#\(capturedPathNumber), pid=\(pid), ppid=\(ppid), mode=0x\(String(mode, radix: 16)), \(dirLabel)=\(dirVal), resolved=\(pathname)) -> \(errorCode)"
            log += msg + "\n"
            print(msg)
            resetState()
            return crOffset - data.startIndex + 1
        }
    }

    private func resolveRFMPathname(_ pathname: String, processID: Int, parentProcessID: Int, isExec: Bool = false) -> String {
        guard !(pathname as NSString).isAbsolutePath else { return pathname }
        let dirMap = isExec ? rfmCurrentExecDir : rfmCurrentDir
        let base: String
        if let cwd = dirMap[processID] {
            base = cwd
        } else if let cwd = dirMap[parentProcessID] {
            base = cwd
        } else {
            return pathname
        }
        if pathname == "." { return base }
        return (base as NSString).appendingPathComponent(pathname)
    }

    // Expand OS-9 multi-dot path components: N dots = N-1 parent-dir references.
    private func expandOS9MultiDots(_ path: String) -> String {
        RFMPathDescriptor.expandMultiDots(path)
    }

    private static func ssCodeName(_ code: Int) -> String {
        switch code {
        case 0x00: return "SS.Opt"
        case 0x01: return "SS.Ready"
        case 0x02: return "SS.Size"
        case 0x03: return "SS.Reset"
        case 0x04: return "SS.WTrk"
        case 0x05: return "SS.Pos"
        case 0x06: return "SS.EOF"
        case 0x07: return "SS.Link"
        case 0x08: return "SS.ULink"
        case 0x09: return "SS.Feed"
        case 0x0A: return "SS.Frz"
        case 0x0B: return "SS.SPT"
        case 0x0C: return "SS.SQD"
        case 0x0D: return "SS.DCmd"
        case 0x0E: return "SS.DevNm"
        case 0x0F: return "SS.FD"
        case 0x10: return "SS.Ticks"
        case 0x11: return "SS.Lock"
        case 0x12: return "SS.DStat"
        case 0x13: return "SS.Joy"
        case 0x14: return "SS.BlkRd"
        case 0x15: return "SS.BlkWr"
        case 0x16: return "SS.Reten"
        case 0x17: return "SS.WFM"
        case 0x18: return "SS.RFM"
        case 0x19: return "SS.ELog"
        case 0x1A: return "SS.SSig"
        case 0x1B: return "SS.Relea"
        case 0x1C: return "SS.AlfaS"
        case 0x1D: return "SS.Break"
        case 0x1E: return "SS.RsBit"
        case 0x1F: return "SS.DirEnt"
        case 0x20: return "SS.FDInf"
        case 0x21: return "SS.Cursr"
        case 0x22: return "SS.ScSiz"
        case 0x23: return "SS.KySns"
        case 0x24: return "SS.DevNm"
        case 0x25: return "SS.FD"
        case 0x26: return "SS.Ticks"
        case 0x27: return "SS.Lock"
        case 0x28: return "SS.ComSt"
        case 0x29: return "SS.Open"
        case 0x2A: return "SS.Close"
        case 0x2B: return "SS.HngUp"
        case 0x2C: return "SS.FSig"
        default:   return "0x\(String(code, radix: 16, uppercase: false))"
        }
    }

    // Returns a stable LSN for the given absolute host path, allocating a new one if needed.
    private func lsnForPath(_ path: String) -> Int {
        if let existing = rfmLSNByPath[path] { return existing }
        let lsn = rfmLSNCounter
        rfmLSNByPath[path] = lsn
        rfmLSNToPath[lsn] = path
        rfmLSNCounter += 1
        return lsn
    }

    // Builds OS-9 directory contents for the open directory descriptor, registering each entry in the LSN map.
    private func synthesizeDirectoryEntries(for descriptor: RFMPathDescriptor) -> Data {
        let dirPath = rfmRootPath + descriptor.pathname
        var entries = Data()

        // '..' and '.' entries — point to parent and self
        let parentPath: String
        let selfPath = (URL(fileURLWithPath: dirPath).standardized.path)
        let deviceRoot = rfmRootPath + "/" + (descriptor.pathname.split(separator: "/").first.map(String.init) ?? "")
        if selfPath == URL(fileURLWithPath: deviceRoot).standardized.path {
            parentPath = selfPath   // at device root: '..' loops back to self
        } else {
            parentPath = URL(fileURLWithPath: dirPath + "/..").standardized.path
        }
        entries.append(contentsOf: RFMPathDescriptor.makeOS9DirEntry("..", lsn: lsnForPath(parentPath)))
        entries.append(contentsOf: RFMPathDescriptor.makeOS9DirEntry(".",  lsn: lsnForPath(selfPath)))

        if let contents = try? FileManager.default.contentsOfDirectory(atPath: dirPath) {
            for name in contents.sorted() {
                let childPath = dirPath + "/" + name
                entries.append(contentsOf: RFMPathDescriptor.makeOS9DirEntry(name, lsn: lsnForPath(childPath)))
            }
        }
        return entries
    }

    private func OPRFMMAKDIR(data: Data) -> Int {
        var result = 0
        let expectedCount = 4
        var capturedPathNumber = 0
        var capturedProcessID = 0
        var capturedParentProcessID = 0
        var capturedMode = 0

        if data.count >= expectedCount {
            capturedPathNumber = Int(data[0])
            capturedProcessID = Int(data[1])
            capturedParentProcessID = Int(data[2])
            capturedMode = Int(data[3])
            result = expectedCount
            processor = OPRFMGETMKDIRPATH
        }

        return result

        func OPRFMGETMKDIRPATH(data: Data) -> Int {
            guard let crOffset = data.firstIndex(of: 0x0D) else { return 0 }
            let pathBytes = data[data.startIndex..<crOffset].map { $0 & 0x7F }
            let isExec = (capturedMode & 0x04) != 0
            let pathname = resolveRFMPathname(String(bytes: pathBytes, encoding: .ascii) ?? "",
                                              processID: capturedProcessID,
                                              parentProcessID: capturedParentProcessID,
                                              isExec: isExec)
            var errorCode: UInt8 = 216
            if !pathname.isEmpty && !pathname.contains("\0") {
                let localPath = (pathname as NSString).isAbsolutePath
                    ? rfmRootPath + pathname : rfmRootPath + "/" + pathname
                let resolved = URL(filePath: localPath).standardized.path
                let normalizedRoot = URL(filePath: rfmRootPath).standardized.path
                if resolved == normalizedRoot || resolved.hasPrefix(normalizedRoot + "/") {
                    do {
                        try FileManager.default.createDirectory(
                            atPath: resolved, withIntermediateDirectories: true)
                        errorCode = 0
                        log += "OP_RFM_MAKDIR(path#\(capturedPathNumber), pid=\(capturedProcessID), ppid=\(capturedParentProcessID), path=\(pathname)) -> 0\n"
                        print("OP_RFM_MAKDIR(path#\(capturedPathNumber), pid=\(capturedProcessID), ppid=\(capturedParentProcessID), path=\(pathname)) -> 0")
                    } catch { errorCode = 216 }
                } else { errorCode = 214 }
            }
            delegate?.dataAvailable(host: self, data: Data([errorCode]))
            resetState()
            return crOffset - data.startIndex + 1
        }
    }

    private func OPRFMCHGDIR(data: Data) -> Int {
        var result = 0
        let expectedCount = 4
        var capturedPathNumber = 0
        var capturedProcessID = 0
        var capturedParentProcessID = 0
        var capturedMode = 0

        if data.count >= expectedCount {
            capturedPathNumber = Int(data[0])
            capturedProcessID = Int(data[1])
            capturedParentProcessID = Int(data[2])
            capturedMode = Int(data[3])
            result = expectedCount
            processor = OPRFMGETCHGDIRPATH
        }

        return result

        func OPRFMGETCHGDIRPATH(data: Data) -> Int {
            guard let crOffset = data.firstIndex(of: 0x0D) else { return 0 }
            let pathBytes = data[data.startIndex..<crOffset].map { $0 & 0x7F }
            let isExec = (capturedMode & 0x04) != 0
            let pathname = resolveRFMPathname(String(bytes: pathBytes, encoding: .ascii) ?? "",
                                              processID: capturedProcessID,
                                              parentProcessID: capturedParentProcessID,
                                              isExec: isExec)
            let expandedPathname = expandOS9MultiDots(pathname)
            var errorCode: UInt8 = 216
            if !expandedPathname.isEmpty && !expandedPathname.contains("\0") {
                let localPath = (expandedPathname as NSString).isAbsolutePath
                    ? rfmRootPath + expandedPathname : rfmRootPath + "/" + expandedPathname
                let resolved = URL(filePath: localPath).standardized.path
                let normalizedRoot = URL(filePath: rfmRootPath).standardized.path
                // Accept paths within rfmRootPath, OR above it (will be clamped to device root).
                let deviceRoot = "/" + (expandedPathname.split(separator: "/").first.map(String.init) ?? "")
                let effectiveResolved = (resolved == normalizedRoot || resolved.hasPrefix(normalizedRoot + "/"))
                    ? resolved : normalizedRoot + deviceRoot
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: effectiveResolved, isDirectory: &isDir), isDir.boolValue {
                    var relativePath = String(effectiveResolved.dropFirst(normalizedRoot.count))
                    if relativePath.isEmpty { relativePath = deviceRoot }
                    // Only store this process's CWD when it differs from the parent's.
                    // If it matches, remove any stale entry so the parent lookup always wins.
                    if isExec {
                        if relativePath == rfmCurrentExecDir[capturedParentProcessID] {
                            rfmCurrentExecDir.removeValue(forKey: capturedProcessID)
                        } else {
                            rfmCurrentExecDir[capturedProcessID] = relativePath
                        }
                    } else {
                        if relativePath == rfmCurrentDir[capturedParentProcessID] {
                            rfmCurrentDir.removeValue(forKey: capturedProcessID)
                        } else {
                            rfmCurrentDir[capturedProcessID] = relativePath
                        }
                    }
                    errorCode = 0
                    let dirLabel = isExec ? "execDir" : "dataDir"
                    let line = "OP_RFM_CHGDIR(path#\(capturedPathNumber), pid=\(capturedProcessID), ppid=\(capturedParentProcessID), \(dirLabel)=\(relativePath)) -> 0\n"
                    log += line
                    print(line)
                } else {
                    errorCode = 216  // E$PNNF — directory not found
                    let line = "OP_RFM_CHGDIR(path#\(capturedPathNumber), pid=\(capturedProcessID), ppid=\(capturedParentProcessID)) -> \(errorCode)\n"
                    log += line
                    print(line)
                }
            }
            delegate?.dataAvailable(host: self, data: Data([errorCode]))
            resetState()
            return crOffset - data.startIndex + 1
        }
    }

    private func OPRFMDELETE(data: Data) -> Int {
        var result = 0
        let expectedCount = 4
        var capturedPathNumber = 0
        var capturedProcessID = 0
        var capturedParentProcessID = 0
        var capturedMode = 0

        if data.count >= expectedCount {
            capturedPathNumber = Int(data[0])
            capturedProcessID = Int(data[1])
            capturedParentProcessID = Int(data[2])
            capturedMode = Int(data[3])
            result = expectedCount
            processor = OPRFMGETDELETEPATH
        }

        return result

        func OPRFMGETDELETEPATH(data: Data) -> Int {
            guard let crOffset = data.firstIndex(of: 0x0D) else { return 0 }
            let pathBytes = data[data.startIndex..<crOffset].map { $0 & 0x7F }
            let isExec = (capturedMode & 0x04) != 0
            let pathname = resolveRFMPathname(String(bytes: pathBytes, encoding: .ascii) ?? "",
                                              processID: capturedProcessID,
                                              parentProcessID: capturedParentProcessID,
                                              isExec: isExec)
            var errorCode: UInt8 = 216
            if !pathname.isEmpty && !pathname.contains("\0") {
                let localPath = (pathname as NSString).isAbsolutePath
                    ? rfmRootPath + pathname : rfmRootPath + "/" + pathname
                let resolved = URL(filePath: localPath).standardized.path
                let normalizedRoot = URL(filePath: rfmRootPath).standardized.path
                if resolved == normalizedRoot || resolved.hasPrefix(normalizedRoot + "/") {
                    do {
                        let attrs = try FileManager.default.attributesOfItem(atPath: resolved)
                        if attrs[.type] as? FileAttributeType == .typeDirectory {
                            // Only delete if empty (deldir path)
                            let contents = try FileManager.default.contentsOfDirectory(atPath: resolved)
                            if contents.isEmpty {
                                try FileManager.default.removeItem(atPath: resolved)
                                errorCode = 0
                            } else {
                                errorCode = 215  // E$DNE — directory not empty
                            }
                        } else {
                            try FileManager.default.removeItem(atPath: resolved)
                            errorCode = 0
                        }
                        if errorCode == 0 {
                            log += "OP_RFM_DELETE(path#\(capturedPathNumber), pid=\(capturedProcessID), ppid=\(capturedParentProcessID), path=\(pathname)) -> 0\n"
                        print("OP_RFM_DELETE(path#\(capturedPathNumber), pid=\(capturedProcessID), ppid=\(capturedParentProcessID), path=\(pathname)) -> 0")
                        }
                    } catch { errorCode = 216 }
                } else { errorCode = 214 }
            }
            delegate?.dataAvailable(host: self, data: Data([errorCode]))
            resetState()
            return crOffset - data.startIndex + 1
        }
    }

    // Receives: path#(1) + X(2) + U(2) where X:U is the 32-bit seek position.
    // Sends back: 1-byte error code.
    private func OPRFMSEEK(data: Data) -> Int {
        var result = 0
        let expectedCount = 5
        let errorCode: UInt8 = 0

        if data.count >= expectedCount {
            let pathNumber = Int(data[0])
            let position = Int(data[1]) * 16777216 + Int(data[2]) * 65536 + Int(data[3]) * 256 + Int(data[4])
            rfmPaths[pathNumber]?.filePosition = position
            result = expectedCount
            resetState()
            delegate?.dataAvailable(host: self, data: Data([errorCode]))
            log += "OP_RFM_SEEK(path#\(pathNumber), pos=\(position)) -> \(errorCode)\n"
            print("OP_RFM_SEEK(path#\(pathNumber), pos=\(position)) -> \(errorCode)")
        }

        return result
    }

    // Receives: path#(1) then maxBytes(2). Sends: count(1) then count bytes.
    // count=0 signals EOF; rfm.asm treats it as E$EOF.
    private func OPRFMREAD(data: Data) -> Int {
        var result = 0
        let expectedCount = 3

        if data.count >= expectedCount {
            let pathNumber = Int(data[0])
            let maxBytes = Int(data[1]) * 256 + Int(data[2])
            result = expectedCount

            if var descriptor = rfmPaths[pathNumber] {
                let (errorCode, lineData) = descriptor.readFromFile(maximumCount: maxBytes)
                rfmPaths[pathNumber] = descriptor
                let ec = errorCode != 0 ? Int(errorCode) : Int(lineData.count)
                log += "OP_RFM_READ(path#\(pathNumber), max=\(maxBytes)) -> \(ec)\n"
                print("OP_RFM_READ(path#\(pathNumber), max=\(maxBytes)) -> \(ec)")
                if errorCode != 0 {
                    delegate?.dataAvailable(host: self, data: Data([0x00, 0x00]))
                } else {
                    delegate?.dataAvailable(host: self, data: Data([UInt8(lineData.count >> 8), UInt8(lineData.count & 0xFF)]))
                    if !lineData.isEmpty {
                        Thread.sleep(forTimeInterval: 0.002)
                        delegate?.dataAvailable(host: self, data: lineData)
                    }
                }
            } else {
                delegate?.dataAvailable(host: self, data: Data([0x00, 0x00]))
            }
            resetState()
        }

        return result
    }

    // Receives: path#(1) then count(2) then count bytes. No response.
    // Receives: path#(1) then count(2) then count bytes. No response.
    private func OPRFMWRITE(data: Data) -> Int {
        var result = 0
        let headerCount = 3

        if data.count >= headerCount {
            let pathNumber = Int(data[0])
            let byteCount = Int(data[1]) * 256 + Int(data[2])
            let totalCount = headerCount + byteCount
            if data.count >= totalCount {
                let key = rfmPaths[pathNumber] != nil ? pathNumber
                    : rfmPaths.first { $0.value.localFile != nil }?.key
                if let k = key, var descriptor = rfmPaths[k] {
                    _ = descriptor.writeToFile(data: Data(data[headerCount..<totalCount]))
                    rfmPaths[k] = descriptor
                }
                log += "OP_RFM_WRITE(path#\(pathNumber), bytes=\(byteCount))\n"
                print("OP_RFM_WRITE(path#\(pathNumber), bytes=\(byteCount))")
                result = totalCount
                resetState()
            }
        }

        return result
    }

    // Receives: path#(1) then maxBytes(2). Sends: count(1) then count bytes.
    private func OPRFMREADLN(data: Data) -> Int {
        var result = 0
        let expectedCount = 3

        if data.count >= expectedCount {
            let pathNumber = Int(data[0])
            let maxBytes = Int(data[1]) * 256 + Int(data[2])
            result = expectedCount

            if var descriptor = rfmPaths[pathNumber] {
                let (errorCode, lineData) = descriptor.readLineFromFile(maximumCount: maxBytes)
                rfmPaths[pathNumber] = descriptor
                let ec = errorCode != 0 ? Int(errorCode) : Int(lineData.count)
                log += "OP_RFM_READLN(path#\(pathNumber), max=\(maxBytes)) -> \(ec)\n"
                print("OP_RFM_READLN(path#\(pathNumber), max=\(maxBytes)) -> \(ec)")
                if errorCode != 0 {
                    delegate?.dataAvailable(host: self, data: Data([0x00, 0x00]))
                } else {
                    delegate?.dataAvailable(host: self, data: Data([UInt8(lineData.count >> 8), UInt8(lineData.count & 0xFF)]))
                    if !lineData.isEmpty {
                        Thread.sleep(forTimeInterval: 0.002)
                        delegate?.dataAvailable(host: self, data: lineData)
                    }
                }
            } else {
                delegate?.dataAvailable(host: self, data: Data([0x00, 0x00]))
            }
            resetState()
        }

        return result
    }

    // Receives: path#(1) then count(2) then count bytes. No response.
    private func OPRFMWRITLN(data: Data) -> Int {
        var result = 0
        let headerCount = 3

        if data.count >= headerCount {
            let pathNumber = Int(data[0])
            let byteCount = Int(data[1]) * 256 + Int(data[2])
            let totalCount = headerCount + byteCount
            if data.count >= totalCount {
                let key = rfmPaths[pathNumber] != nil ? pathNumber
                    : rfmPaths.first { $0.value.localFile != nil }?.key
                if let k = key, var descriptor = rfmPaths[k] {
                    _ = descriptor.writeToFile(data: Data(data[headerCount..<totalCount]), translateCR: true)
                    rfmPaths[k] = descriptor
                }
                log += "OP_RFM_WRITLN(path#\(pathNumber), bytes=\(byteCount))\n"
                print("OP_RFM_WRITLN(path#\(pathNumber), bytes=\(byteCount))")
                result = totalCount
                resetState()
            }
        }

        return result
    }

    // Receives: path#(1) + SS.code(1). SS.FD additionally receives 2-byte count then sends FD.
    private func OPRFMGETSTT(data: Data) -> Int {
        var result = 0
        let expectedCount = 2
        var capturedPathNumber = 0

        if data.count >= expectedCount {
            capturedPathNumber = Int(data[0])
            let statCode = Int(data[1])
            result = expectedCount
            log += "OP_RFM_GETSTT(path#\(capturedPathNumber), \(DriveWireHost.ssCodeName(statCode)))\n"
            print("OP_RFM_GETSTT(path#\(capturedPathNumber), \(DriveWireHost.ssCodeName(statCode)))")
            if statCode == 0x02 {  // SS.Size — send 4-byte file size
                let size = rfmPaths[capturedPathNumber]?.fileContents.count ?? 0
                let msg = "OP_RFM_GETSTT(path#\(capturedPathNumber), SS.Size) -> \(size)"
                log += msg + "\n"; print(msg)
                delegate?.dataAvailable(host: self, data: Data([
                    UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF),
                    UInt8((size >> 8) & 0xFF),  UInt8(size & 0xFF)]))
                resetState()
            } else if statCode == 0x05 {  // SS.Pos — send 4-byte current position
                let pos = rfmPaths[capturedPathNumber]?.filePosition ?? 0
                let msg = "OP_RFM_GETSTT(path#\(capturedPathNumber), SS.Pos) -> \(pos)"
                log += msg + "\n"; print(msg)
                delegate?.dataAvailable(host: self, data: Data([
                    UInt8((pos >> 24) & 0xFF), UInt8((pos >> 16) & 0xFF),
                    UInt8((pos >> 8) & 0xFF),  UInt8(pos & 0xFF)]))
                resetState()
            } else if statCode == 0x06 {  // SS.EOF — send 0 (not EOF) or E$EOF (211)
                let isEOF = rfmPaths[capturedPathNumber].map { $0.filePosition >= $0.fileContents.count } ?? true
                let response: UInt8 = isEOF ? 211 : 0
                let msg = "OP_RFM_GETSTT(path#\(capturedPathNumber), SS.EOF) -> \(isEOF ? "EOF" : "OK")"
                log += msg + "\n"; print(msg)
                delegate?.dataAvailable(host: self, data: Data([response]))
                resetState()
            } else if statCode == 0x0F {  // SS.FD
                processor = OPRFMGETSSFD
            } else if statCode == 0x20 {  // SS.FDInf
                processor = OPRFMGETSSFDINF
            } else {
                resetState()
            }
        }

        return result

        func OPRFMGETSSFD(data: Data) -> Int {
            guard data.count >= 2 else { return 0 }
            let count = min(Int(data[0]) * 256 + Int(data[1]), 256)
            let fd = rfmPaths[capturedPathNumber]?.synthesizeFD(count: count)
                ?? Data(repeating: 0, count: count)
            delegate?.dataAvailable(host: self, data: fd)
            log += "OP_RFM_GETSTT_FD(path#\(capturedPathNumber), bytes=\(count))\n"
            print("OP_RFM_GETSTT_FD(path#\(capturedPathNumber), bytes=\(count))")
            resetState()
            return 2
        }

        func OPRFMGETSSFDINF(data: Data) -> Int {
            guard data.count >= 4 else { return 0 }
            // data[0]=Y_hi=LSN[0], data[1]=Y_lo=length, data[2]=U_hi=LSN[1], data[3]=U_lo=LSN[2]
            let lsn = Int(data[0]) << 16 | Int(data[2]) << 8 | Int(data[3])
            var tempDesc = RFMPathDescriptor()
            if let hostPath = rfmLSNToPath[lsn] {
                tempDesc.attributes = (try? FileManager.default.attributesOfItem(atPath: hostPath)) ?? [:]
            }
            let fd = tempDesc.synthesizeFD(count: 256)
            delegate?.dataAvailable(host: self, data: fd)
            let path = rfmLSNToPath[lsn] ?? "unknown"
            log += "OP_RFM_GETSTT_FDInf(lsn=0x\(String(lsn, radix: 16)), path=\(path))\n"
            print("OP_RFM_GETSTT_FDInf(lsn=0x\(String(lsn, radix: 16)), path=\(path))")
            resetState()
            return 4
        }
    }

    // Receives nothing (rfm.asm sendit only sends the sub-op). No response.
    private func OPRFMSETSTT(data: Data) -> Int {
        print("OP_RFM_SETSTT")
        resetState()
        return 0
    }

    // Receives: path#(1). Sends back: 1-byte error code.
    // Receives: path#(1). Sends back: 1-byte error code.
    // If the path was opened via CREATE, the shell closes its reference after
    // forking the child writer — keep the descriptor alive for incoming writes.
    private func OPRFMCLOSE(data: Data) -> Int {
        var result = 0
        let expectedCount = 1

        if data.count >= expectedCount {
            let pathNumber = Int(data[0])
            rfmPaths[pathNumber]?.localFile?.closeFile()
            rfmPaths.removeValue(forKey: pathNumber)
            result = expectedCount
            delegate?.dataAvailable(host: self, data: Data([0x00]))
            resetState()
            log += "OP_RFM_CLOSE(path#\(pathNumber))\n"
            print("OP_RFM_CLOSE(path#\(pathNumber))")
        }

        return result
    }

    private func OP_OPCODE(data: Data) -> Int {
        var result = 1
        
        setupWatchdog()
        
        let byte = data[0]
        
        statistics.lastOpCode = byte
        
        if byte >= 0x80 && byte <= 0x8E {
            // FASTWRITE serial
            fastwriteChannel = byte & 0x0F;
            result = OP_FASTWRITE_Serial(data: data)
        }
        else if byte >= 0x91 && byte <= 0x9E {
            // FASTWRITE virtual screen
            self.fastwriteChannel = (byte & 0x0F) - 1;
            result = OP_FASTWRITE_Screen(data: data)
        } else {
            for e in dwTransaction {
                if e.opcode == byte {
                    processor = e.processor
                    result = processor!(data)
                    break
                }
            }
        }
        
        return result;
    }
}

extension DriveWireHost {
    private func OP_REREADEX(data : Data) -> Int {
        statistics.reReadCount = statistics.reReadCount + 1
        return OP_READEX(data: data)
    }
    
    private func OP_READEX(data : Data) -> Int {
        currentTransaction = OPREADEX
        var result = 0
        var error = DriveWireProtocolError.E_NONE.rawValue
        var sectorBuffer = Data(repeating: 0, count: 256)
        var readexChecksum : UInt16 = 0
        
        if data.count >= 5 {
            let driveNumber = data[1]
            statistics.lastDriveNumber = driveNumber
            let vLSN = Int(data[2]) << 16 + Int(data[3]) << 8 + Int(data[4])
            statistics.lastLSN = vLSN

            // We read 5 bytes into this buffer (OP_READEX, 1 byte drive number, 3 byte LSN)
            result = 5;
            
            // Check if the drive number exists in our virtual drive list.
            if let virtualDrive = virtualDrives.first(where: { $0.driveNumber == driveNumber }) {
                // It exists! Read sector from disk image.
                statistics.lastDriveNumber = driveNumber
                statistics.readCount = statistics.readCount + 1
                statistics.percentReadsOK = (1 - statistics.reReadCount / statistics.readCount) * 100
                (error, sectorBuffer) = virtualDrive.readSector(lsn: vLSN)
            } else {
                // It doesn't exist. Set the error code.
                error = DriveWireProtocolError.E_UNIT.rawValue
            }

            // Respond with the sector.
            delegate?.dataAvailable(host: self, data: sectorBuffer)
            
            // Compute Checksum from sector.
            readexChecksum = compute16BitChecksum(data: sectorBuffer)
            
            processor = OP_READEXP2
        }
        
        return result
        
        func OP_READEXP2(data : Data) -> Int {
            var result = 0
            
            if data.count >= 2 {
                // We read 2 bytes into this buffer (guest's checksum).
                // Here we're expecting the checksum from the guest.
                result = 2;
                
                let guestChecksum = UInt16(data[0]) * 256 + UInt16(data[1])
                if readexChecksum != guestChecksum {
                    error = DriveWireProtocolError.E_CRC.rawValue
                }
                
                // Send the response code to the guest.
                delegate?.dataAvailable(host: self, data: Data([UInt8(error)]))
                let msg = "OP_READEX(drive=\(statistics.lastDriveNumber), lsn=0x\(String(statistics.lastLSN, radix: 16))) -> \(error)"
                reportActivity(msg, isFrequent: true, isError: error != DriveWireProtocolError.E_NONE.rawValue)
                // Reset the state machine.
                resetState()
            }
            
            return result
        }
    }
    
    private func OP_REREAD(data : Data) -> Int {
        statistics.reReadCount = statistics.reReadCount + 1
        return OP_READ(data: data)
    }
    
    private func OP_READ(data : Data) -> Int {
        currentTransaction = OPREADEX
        var result = 0
        var error = DriveWireProtocolError.E_NONE.rawValue
        var sectorBuffer = Data(repeating: 0, count: 256)
        var readexChecksum : UInt16 = 0
        
        if data.count >= 5 {
            let driveNumber = data[1]
            statistics.lastDriveNumber = driveNumber
            let vLSN = Int(data[2]) << 16 + Int(data[3]) << 8 + Int(data[4])
            statistics.lastLSN = vLSN

            // We read 5 bytes into this buffer (OP_READEX, 1 byte drive number, 3 byte LSN)
            result = 5;

            // Check if this LSN belongs to a synthesized RFM file descriptor.
            if let hostPath = rfmLSNToPath[vLSN] {
                var tempDesc = RFMPathDescriptor()
                tempDesc.attributes = (try? FileManager.default.attributesOfItem(atPath: hostPath)) ?? [:]
                sectorBuffer = tempDesc.synthesizeFD(count: 256)
            } else if let virtualDrive = virtualDrives.first(where: { $0.driveNumber == driveNumber }) {
                // It exists! Read sector from disk image.
                statistics.lastDriveNumber = driveNumber
                statistics.readCount = statistics.readCount + 1
                statistics.percentReadsOK = (1 - statistics.reReadCount / statistics.readCount) * 100
                (error, sectorBuffer) = virtualDrive.readSector(lsn: vLSN)
            } else {
                // It doesn't exist. Set the error code.
                error = DriveWireProtocolError.E_UNIT.rawValue
            }
            delegate?.dataAvailable(host: self, data: Data([UInt8(error)]))
            
            // If we have an OK response, we send the sector and checksum.
            if error == DriveWireProtocolError.E_NONE.rawValue {
                // Compute checksum from sector.
                readexChecksum = compute16BitChecksum(data: sectorBuffer)

                // Send the checksum.
                delegate?.dataAvailable(host: self, data: Data([UInt8(readexChecksum >> 8),UInt8(readexChecksum & 0xFF)]))

                // Send the sector.
                delegate?.dataAvailable(host: self, data: sectorBuffer)

            }

            resetState()
        }
        
        return result        
    }
}

extension Data {
    func dump() {
        dump(prefix: "")
    }
    
    func dump(prefix : String) {
        let prefix : String = prefix
        var line : String = ""
        var asciiLine : String = ""
        var asciiByte : String
        var count = 0
        let c = {
            print("\(prefix)\(line)", terminator: "")
            let s = String.init(repeating: " ", count: 40 - line.count)
            print(s, terminator: "")
            print(asciiLine, terminator: "\n")
            line = ""
            asciiLine = ""
        }
        for byte in self {
            line.append(String(format: "%02x", byte))
            if byte > 0x1f && byte < 0x7f {
                asciiByte = String(format: "%c", byte)
            } else {
                asciiByte = "."
            }
            asciiLine.append(asciiByte)
            if count % 2 == 1 {
                line.append(" ")
            }
            count = count + 1
            if count % 16 == 0 {
                c()
            }
        }
        
        if line != "" {
            c()
        }
    }
}

extension DriveWireHost {
    /// A representation of a storage device.
    public class VirtualDrive : Codable {
        enum CodingKeys: String, CodingKey {
            case driveNumber
            case imagePath
            case bookmarkData
        }

        func didReceive(changes: String) {
            reload()
        }
        
        /// The drive number for this drive.
        var driveNumber = 0
        
        /// A path to a file that contains the drive's data.
        var imagePath = ""
        
        private var bookmarkData = Data()
        private var storageContainer = Data()
        private var isStorageLoaded = false
        
        /// Creates an empty in-memory virtual drive.
        ///
        /// - Parameters:
        ///     - driveNumber: The number to assign to this virtual drive.
        init(driveNumber: Int) {
            self.driveNumber = driveNumber
            self.imagePath = ""
            self.storageContainer = Data()
            self.isStorageLoaded = true
        }

        /// Creates a new virtual drive.
        ///
        /// - Parameters:
        ///     - driveNumber: The number to assign to this virtual drive.
        ///     - imagePath: A path to a file that contains the drive's data.
        init(driveNumber : Int, imagePath : String) throws {
            self.driveNumber = driveNumber
            self.imagePath = imagePath

            reload()
        }
        
        public func reload() {
            do {
                let u = URL(fileURLWithPath: self.imagePath)
                self.storageContainer = try Data(contentsOf: u)
                self.isStorageLoaded = true
            } catch {
                self.storageContainer = Data()
                self.isStorageLoaded = false
                print(error)
            }
        }

        private func ensureStorageLoaded() {
            guard !isStorageLoaded, !imagePath.isEmpty else {
                return
            }
            reload()
        }
        
        /// Reads a 256 byte sector from a virtual disk.
        ///
        /// Call this method to obtain the contents of a 256-byte sector in the virtual disk. If you pass a logical sector number that
        /// is greater than what the virtual disk contains, the function returns a 256-byte sector filled with zeros.
        ///
        /// - Parameters:
        ///     - lsn: The logical sector number to read.
        public func readSector(lsn : Int) -> (Int, Data) {
            ensureStorageLoaded()

            // Seek to the offset in the file represented by the URL.
            let offsetStart = lsn * 256
            let offsetEnd = offsetStart + 256
            if storageContainer.count >= offsetEnd {
                let range: Range<Data.Index> = offsetStart..<offsetEnd
                let sector = storageContainer[range]
                // Send a 256 byte sector of zeros with no error
                return(DriveWireProtocolError.E_NONE.rawValue, sector)
            } else {
                // LSN is past point of capacity of source.
                // Send a 256 byte sector of zeros with no error
                return(DriveWireProtocolError.E_NONE.rawValue, Data(repeating: 0, count: 256))
            }
        }

        /// Writes a 256 byte sector to a virtual disk.
        ///
        /// Call this method to modify a 256-byte sector in the virtual disk. If you pass a logical sector number that
        /// is greater than what the virtual disk contains, it increases to accomodate the new sector.
        ///
        /// - Parameters:
        ///     - lsn: The logical sector number to write.
        ///     - sector: The 256-byte sector to write.
        public func writeSector(lsn : Int, sector : Data) -> Int {
            ensureStorageLoaded()

            // Seek to the offset in the file represented by the URL.
            let offsetStart = lsn * 256
            let offsetEnd = offsetStart + 256
            let range: Range<Data.Index> = offsetStart..<offsetEnd
            if storageContainer.count >= offsetEnd {
                storageContainer[range] = sector
            } else {
                // LSN is past point of capacity of source.
                storageContainer.append(Data(repeating: 0xFF, count: offsetEnd - storageContainer.count))
                storageContainer[range] = sector
            }

            isStorageLoaded = true
            return DriveWireProtocolError.E_NONE.rawValue
        }

        public func save(to path: String? = nil) throws {
            ensureStorageLoaded()
            let destination = path ?? imagePath
            guard !destination.isEmpty else {
                throw CocoaError(.fileNoSuchFile)
            }
            try storageContainer.write(to: URL(fileURLWithPath: destination), options: .atomic)
            if let path {
                imagePath = path
            }
        }

        public required init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.driveNumber = try values.decode(Int.self, forKey: .driveNumber)
            self.imagePath = try values.decode(String.self, forKey: .imagePath)
            self.bookmarkData = try values.decodeIfPresent(Data.self, forKey: .bookmarkData) ?? Data()
            self.storageContainer = Data()
            self.isStorageLoaded = false
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(driveNumber, forKey: .driveNumber)
            try container.encode(imagePath, forKey: .imagePath)
            try container.encode(bookmarkData, forKey: .bookmarkData)
        }
    }
}

protocol FileMonitorDelegate: AnyObject {
    func didReceive(changes: String)
}

class FileMonitor : Codable {
    enum CodingKeys: String, CodingKey {
        case url
    }

    let url: URL
    let fileHandle: FileHandle
    weak var delegate: FileMonitorDelegate?
    let source: DispatchSourceFileSystemObject

    public required init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try values.decode(URL.self, forKey: .url)
        self.fileHandle = try FileHandle(forReadingFrom: self.url)
        self.delegate = nil
        self.source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileHandle.fileDescriptor,
            eventMask: .extend,
            queue: DispatchQueue.main
        )
        
        source.setEventHandler {
            let event = self.source.data
            self.process(event: event)
        }
        
        source.setCancelHandler {
            try? self.fileHandle.close()
        }
        
        fileHandle.seekToEndOfFile()
        source.resume()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey:.url)
    }
    

    init(url: URL) throws {
        self.url = url
        self.fileHandle = try FileHandle(forReadingFrom: url)

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileHandle.fileDescriptor,
            eventMask: .delete,
            queue: DispatchQueue.main
        )

        source.setEventHandler {
            let event = self.source.data
            self.process(event: event)
        }

        source.setCancelHandler {
            try? self.fileHandle.close()
        }

        fileHandle.seekToEndOfFile()
        source.resume()
    }

    deinit {
        source.cancel()
    }

    func process(event: DispatchSource.FileSystemEvent) {
        guard event.contains(.delete) else {
            return
        }
        let newData = self.fileHandle.readDataToEndOfFile()
        let string = String(data: newData, encoding: .utf8)!
        self.delegate?.didReceive(changes: string)
    }
}
