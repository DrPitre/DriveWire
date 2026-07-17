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

public struct DriveWireVirtualChannelStatus: Identifiable, Equatable {
    public let channel: UInt8
    public let number: Int
    public let isOpen: Bool
    public let incomingActive: Bool
    public let outgoingActive: Bool
    public let pendingBytes: Int
    public let isTCPBacked: Bool

    public var id: UInt8 { channel }
}

/// Manages communication with a DriveWire guest.
///
/// DriveWire is a connectivity standard that defines virtual disk drive, virtual printer, and virtual serial port services. A DriveWire *host* provides these services to a *guest*. Connectivity between the host and guest occurs over a physical connection, such as a serial cable. To the guest, it appears that the host's devices are local, when they are actually virtual.
///
/// The basis of communication between the guest and host is a documented set of uni- and bi-directional messages called *transactions*. A transaction is a series of one or more packets that the guest and host pass to each other.
///
@Observable
public class DriveWireHost : Codable {
    static let maximumLogCharacters = 24_000
    static let trimmedLogPrefix = "... older log entries trimmed ...\n"
    static let emitConsoleOutput = false
    static let midiVirtualSerialChannel: UInt8 = 14
    static let standardMIDIFileSignature = Data([0x4D, 0x54, 0x68, 0x64])

    public var detailedOpcodeLogging = false

    var logStorage = ""

    var log: String {
        get { logStorage }
        set { logStorage = Self.trimmedLog(from: newValue) }
    }

    init() {
        setupTransactions()
        refreshMIDIStatus()
    }

    func reloadVirtualDrives() {
        for vd in virtualDrives {
            vd.reload()
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
    public internal(set) var virtualWindows: [DriveWireVirtualWindow] = []
    public internal(set) var virtualSerialChannels: [DriveWireVirtualChannelStatus] = (1...8).map {
        DriveWireVirtualChannelStatus(
            channel: UInt8($0),
            number: $0,
            isOpen: false,
            incomingActive: false,
            outgoingActive: false,
            pendingBytes: 0,
            isTCPBacked: false
        )
    }
    public internal(set) var midiMonitorStatus = DriveWireMIDIStatus()

    /// The guest's capability byte sent from ``OPDWINIT``.
    var guestCapabilityByte : UInt8 = 0x00

    struct DWOp {
        var opcode : UInt8 = 0
        var processor : ((Data) -> Int)
    }

    var dwTransaction : Array<DWOp> = []
    var validateWithCRC = false
    var fastwriteChannel : UInt8 = 0
    var processor : ((Data) -> Int)?
    var openVirtualSerialChannels = Set<UInt8>()
    var virtualSerialInput = [UInt8: Data]()
    var virtualSerialCommandBuffers = [UInt8: String]()
    var pendingClosedVirtualSerialChannels: [UInt8] = []
    var clientRestartRequested = false
    var virtualSerialTCPConnections = [UInt8: VirtualSerialTCPConnection]()
    var virtualSerialTCPListeners = [UInt16: NWListener]()
    var pendingVirtualSerialTCPConnections = [Int: PendingVirtualSerialTCPConnection]()
    var nextVirtualSerialTCPConnectionID = 1
    var virtualSerialIncomingPulseTokens = [UInt8: UInt64]()
    var virtualSerialOutgoingPulseTokens = [UInt8: UInt64]()
    var nextVirtualSerialPulseToken: UInt64 = 1
    var driveWireAPIConfig = [String: String]()
    var virtualDriveParameters = [Int: [String: String]]()
    var nameLength = 0
    var midiBackend: DriveWireMIDIBackend = DriveWireMIDIBackendFactory.makeDefault()
    var lastMIDIErrorMessage: String?
    var midiState = "Idle"
    var midiBytesReceived = 0
    var midiFileBytesReceived = 0
    var midiMessagesSent = 0
    var midiStreamMode = MIDIStreamMode.undetermined
    var midiBufferedData = Data()
    var standardMIDIPlayback: StandardMIDIFileStreamPlayback?

    enum MIDIStreamMode {
        case undetermined
        case raw
        case standardFile
    }

    var rfmRootPath: String = NSHomeDirectory()
    var rfmPaths: [Int: RFMPathDescriptor] = [:]
    var rfmCurrentDir: [Int: String] = [:]      // data directory per process
    var rfmCurrentExecDir: [Int: String] = [:] // execution directory per process
    // Maps host path ↔ unique LSN for synthesized RFM directory entries.
    // LSNs start above a typical NitrOS-9 DW image (~524k sectors for DW format).
    var rfmLSNByPath: [String: Int] = [:]
    var rfmLSNToPath: [Int: String] = [:]
    var rfmLSNCounter: Int = 0x600000

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

    var watchdog : Timer?

    func setupWatchdog() {
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

    func resetState() {
        processor = OP_OPCODE
        invalidateWatchdog()
    }

    func resetGuestSessionState() {
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
        virtualSerialIncomingPulseTokens.removeAll()
        virtualSerialOutgoingPulseTokens.removeAll()
        nextVirtualSerialPulseToken = 1
        lastMIDIErrorMessage = nil
        midiState = "Idle"
        midiBytesReceived = 0
        midiFileBytesReceived = 0
        midiMessagesSent = 0
        standardMIDIPlayback?.stop(shouldResetOutput: true)
        standardMIDIPlayback = nil
        resetMIDIStreamState()
        refreshMIDIStatus()
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
        refreshVirtualSerialChannelStatuses()
        printBuffer.removeAll()
        resetRFMState()
    }

    var printBuffer = Data()

    func OP_FASTWRITE_Serial(data : Data) -> Int {
        guard data.count >= 2 else { return 0 }
        writeVirtualSerial(channel: fastwriteChannel, data: Data([data[1]]))
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        return 2
    }

    func OP_FASTWRITE_Screen(data : Data) -> Int {
        guard data.count >= 2 else { return 0 }
        writeVirtualSerial(channel: 0x81 &+ fastwriteChannel, data: Data([data[1]]))
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        return 2
    }

}
