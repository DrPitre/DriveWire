//
//  DriveWireHost.swift
//  DriveWireSwift
//
//  Created by Boisy Pitre on 9/29/23.
//

import Foundation
import AppKit
import AppIntents

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

/// Manages communication with a DriveWire guest.
///
/// DriveWire is a connectivity standard that defines virtual disk drive, virtual printer, and virtual serial port services. A DriveWire *host* provides these services to a *guest*. Connectivity between the host and guest occurs over a physical connection, such as a serial cable. To the guest, it appears that the host's devices are local, when they are actually virtual.
///
/// The basis of communication between the guest and host is a documented set of uni- and bi-directional messages called *transactions*. A transaction is a series of one or more packets that the guest and host pass to each other.
///
@Observable
public class DriveWireHost : Codable {
    var log : String = ""

    init() {
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
    
    struct RFMPathDescriptor {
        var pathNumber = 0
        var mode = 0
        var filePosition = 0
        var pathname = ""
        var localFile : FileHandle? = nil
        var fileContents : Data = Data()
        var attributes = [FileAttributeKey : Any]()

        mutating func openLocalFile(rootPath: String) -> UInt8 {
            var errorCode : UInt8 = 0
            let localPathname: String
            if (pathname as NSString).isAbsolutePath {
                localPathname = rootPath + pathname
            } else {
                localPathname = rootPath + "/" + pathname
            }
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: localPathname)
                if mode & 0x80 != 0 {
                    if let fileType = attributes[.type] as? FileAttributeType, fileType != .typeDirectory {
                        errorCode = 214
                    }
                } else {
                    localFile = try FileHandle(forReadingFrom: URL(filePath: localPathname))
                    if let localFile = localFile {
                        fileContents = localFile.availableData
                    }
                }
            } catch {
                errorCode = 216
            }
            return errorCode
        }

        mutating func readLineFromFile(offset : Int, maximumCount : Int) -> (UInt8, Data) {
            var errorCode : UInt8 = 0
            var data = Data()
            
            var byte : UInt8 = 0
            repeat {
                do {
                    if filePosition >= fileContents.count {
                        errorCode = 211
                        break
                    }
                    byte = fileContents[filePosition]
                    filePosition = filePosition + 1
                    if byte == 0x0A {
                        byte = 0x0D
                    }
                    data = data + Data([byte])
                } catch {
                    errorCode = 211
                }
            } while filePosition < fileContents.count && data.count <= maximumCount && byte != 0x0D && errorCode == 0

            return (errorCode, data)
        }

        mutating func readFromFile(offset : Int, maximumCount : Int) -> (UInt8, Data) {
            var errorCode : UInt8 = 0
            var data = Data()
            
            var byte : UInt8 = 0
            repeat {
                do {
                    if filePosition >= fileContents.count {
                        errorCode = 211
                        break
                    }
                    byte = fileContents[filePosition]
                    filePosition = filePosition + 1
                    data = data + Data([byte])
                } catch {
                    errorCode = 211
                }
            } while filePosition < fileContents.count && data.count < maximumCount && errorCode == 0

            return (errorCode, data)
        }
    }

    var rfmRootPath: String = NSHomeDirectory()
    private var rfmPaths: [Int: RFMPathDescriptor] = [:]
    
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
        dwTransaction.append(DWOp(opcode:OPINIT, processor: self.OP_INIT))
        dwTransaction.append(DWOp(opcode:OPTERM, processor: self.OP_TERM))
        dwTransaction.append(DWOp(opcode:OPREAD, processor: self.OP_READ))
        dwTransaction.append(DWOp(opcode:OPREADEX, processor: self.OP_READEX))
        dwTransaction.append(DWOp(opcode:OPREREAD, processor: self.OP_REREAD))
        dwTransaction.append(DWOp(opcode:OPREREADEX, processor: self.OP_REREADEX))
        dwTransaction.append(DWOp(opcode:OPWRITE, processor: self.OP_WRITE))
        dwTransaction.append(DWOp(opcode:OPREWRITE, processor: self.OP_REWRITE))
        dwTransaction.append(DWOp(opcode:OPGETSTAT, processor: self.OP_GETSTAT))
        dwTransaction.append(DWOp(opcode:OPSETSTAT, processor: self.OP_SETSTAT))
        dwTransaction.append(DWOp(opcode:OPRESET3, processor: self.OP_RESET))
        dwTransaction.append(DWOp(opcode:OPRESET2, processor: self.OP_RESET))
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
                // chop off consumed bytes
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
    
    private func OP_DWINIT(data : Data) -> Int {
        var result = 0
        let expectedCount = 2
        currentTransaction = OPDWINIT
        
        if data.count >= expectedCount {
            // Save capabilities byte.
            guestCapabilityByte = data[1]
            
            // Send the host capabilities byte.
            delegate?.dataAvailable(host: self, data: Data([0x00]))
            result = expectedCount
            
            // Reset the state machine.
            resetState()
        }
        
        return result
    }
    
    private var nameLength = 0
    
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
                let name = String(bytes: data, encoding: .ascii)!
                
                // determine if a named object with this name already exists
                if let vd = findVirtualDisk(name: name) {
                    response = UInt8(vd.driveNumber)
                } else {
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
                let name = String(bytes: data, encoding: .ascii)!
                
                // determine if a named object with this name already exists
                if let _ = findVirtualDisk(name: name) {
                    response = 0
                } else {
                    let nextFreeDrive = findAvailableVirtualDrive()
                    do {
                        try insertVirtualDisk(driveNumber: nextFreeDrive, imagePath: name)
                        response = UInt8(nextFreeDrive);
                    } catch {
                        
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
        return 1
    }
    
    private func OP_INIT(data : Data) -> Int {
        currentTransaction = OPINIT
        resetState()
        statistics = DriveWireStatistics()  // reset statistics
        delegate?.transactionCompleted(opCode: currentTransaction)
        log = log + "OP_INIT" + "\n"
        return 1
    }
    
    private func OP_TERM(data : Data) -> Int {
        currentTransaction = OPTERM
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        log = log + "OP_TERM" + "\n"
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
        
        log = log + "OP_GETSTAT(" + String(statistics.lastDriveNumber) + "," + String(statistics.lastGetStat) + ")" + "\n"
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
        
        log = log + "OP_SETSTAT(" + String(statistics.lastDriveNumber) + "," + String(statistics.lastGetStat) + ")" + "\n"
        return result
    }
    
    private func OP_RESET(data : Data) -> Int {
        currentTransaction = OPRESET
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        log = log + "OP_RESET" + "\n"
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
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        return 1
    }
    
    private func OP_SERTERM(data : Data) -> Int {
        currentTransaction = OPSERTERM
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        return 1
    }
    
    private func OP_SERREAD(data : Data) -> Int {
        currentTransaction = OPSERREAD
        resetState()
        delegate?.dataAvailable(host: self, data: Data([0x00, 0x00]))
        return 1
    }
    
    private func OP_SERREADM(data : Data) -> Int {
        currentTransaction = OPSERREADM
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        return 1
    }
    
    private func OP_SERWRITE(data : Data) -> Int {
        currentTransaction = OPSERWRITE
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        return 1
    }
    
    private func OP_SERWRITEM(data : Data) -> Int {
        currentTransaction = OPSERWRITEM
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        return 1
    }
    
    private func OP_SERGETSTAT(data : Data) -> Int {
        currentTransaction = OPSERGETSTAT
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        return 1
    }
    
    private func OP_SERSETSTAT(data : Data) -> Int {
        currentTransaction = OPSERSETSTAT
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        return 1
    }
    
    private func OP_FASTWRITE_Serial(data : Data) -> Int {
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        return 1
    }
    
    private func OP_FASTWRITE_Screen(data : Data) -> Int {
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        return 1
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
        // Create is handled identically to Open on the host side.
        return OPRFMOPEN(data: data)
    }

    // Receives: path#(1) + mode(1), then pathname terminated by CR ($0D).
    // Sends back: 1-byte error code.
    private func OPRFMOPEN(data : Data) -> Int {
        var result = 0
        let expectedCount = 2
        var capturedPathNumber = 0

        if data.count >= expectedCount {
            capturedPathNumber = Int(data[0])
            var descriptor = RFMPathDescriptor()
            descriptor.pathNumber = capturedPathNumber
            descriptor.mode = Int(data[1])
            rfmPaths[capturedPathNumber] = descriptor
            result = expectedCount
            processor = OPRFMGETPATH
        }

        return result

        func OPRFMGETPATH(data: Data) -> Int {
            guard let crOffset = data.firstIndex(of: 0x0D) else { return 0 }
            let pathname = String(bytes: data[data.startIndex..<crOffset], encoding: .ascii) ?? ""
            rfmPaths[capturedPathNumber]?.pathname = pathname
            let errorCode = rfmPaths[capturedPathNumber]?.openLocalFile(rootPath: rfmRootPath) ?? 0xFF
            delegate?.dataAvailable(host: self, data: Data([errorCode]))
            log += "OP_RFM_OPEN(\(capturedPathNumber), \(pathname)) -> \(errorCode)\n"
            resetState()
            return crOffset - data.startIndex + 1
        }
    }

    private func OPRFMMAKDIR(data: Data) -> Int {
        resetState()
        return 0
    }

    private func OPRFMCHGDIR(data: Data) -> Int {
        return OPRFMOPEN(data: data)
    }

    private func OPRFMDELETE(data: Data) -> Int {
        resetState()
        return 0
    }

    // Receives: path#(1) + X(2) + U(2) where X:U is the 32-bit seek position.
    // Sends back: 1-byte error code.
    private func OPRFMSEEK(data: Data) -> Int {
        var result = 0
        let expectedCount = 5
        var errorCode: UInt8 = 0

        if data.count >= expectedCount {
            let pathNumber = Int(data[0])
            let position = Int(data[1]) * 16777216 + Int(data[2]) * 65536 + Int(data[3]) * 256 + Int(data[4])
            rfmPaths[pathNumber]?.filePosition = position
            result = expectedCount
            resetState()
            delegate?.dataAvailable(host: self, data: Data([errorCode]))
            log += "OP_RFM_SEEK(\(pathNumber), \(position)) -> \(errorCode)\n"
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
            let maxBytes = min(Int(data[1]) * 256 + Int(data[2]), 255)
            result = expectedCount

            if var descriptor = rfmPaths[pathNumber] {
                let (errorCode, lineData) = descriptor.readFromFile(offset: descriptor.filePosition, maximumCount: maxBytes)
                rfmPaths[pathNumber] = descriptor
                if errorCode != 0 {
                    delegate?.dataAvailable(host: self, data: Data([0x00]))
                } else {
                    delegate?.dataAvailable(host: self, data: Data([UInt8(lineData.count)]))
                    if !lineData.isEmpty {
                        delegate?.dataAvailable(host: self, data: lineData)
                    }
                }
            } else {
                delegate?.dataAvailable(host: self, data: Data([0x00]))
            }
            resetState()
        }

        return result
    }

    // Receives: path#(1) then count(2) then count bytes. No response.
    private func OPRFMWRITE(data: Data) -> Int {
        var result = 0
        let headerCount = 3

        if data.count >= headerCount {
            let pathNumber = Int(data[0])
            let byteCount = Int(data[1]) * 256 + Int(data[2])
            let totalCount = headerCount + byteCount
            if data.count >= totalCount {
                // TODO: write to file
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
            let maxBytes = min(Int(data[1]) * 256 + Int(data[2]), 255)
            result = expectedCount

            if var descriptor = rfmPaths[pathNumber] {
                let (errorCode, lineData) = descriptor.readLineFromFile(offset: descriptor.filePosition, maximumCount: maxBytes)
                rfmPaths[pathNumber] = descriptor
                if errorCode != 0 {
                    delegate?.dataAvailable(host: self, data: Data([0x00]))
                } else {
                    delegate?.dataAvailable(host: self, data: Data([UInt8(lineData.count)]))
                    if !lineData.isEmpty {
                        delegate?.dataAvailable(host: self, data: lineData)
                    }
                }
            } else {
                delegate?.dataAvailable(host: self, data: Data([0x00]))
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
                // TODO: write to file
                result = totalCount
                resetState()
            }
        }

        return result
    }

    // Receives: path#(1) + SS.code(1). rfm.asm's getstt handlers are stubs, so send nothing.
    private func OPRFMGETSTT(data: Data) -> Int {
        var result = 0
        let expectedCount = 2

        if data.count >= expectedCount {
            let pathNumber = Int(data[0])
            let statCode = Int(data[1])
            result = expectedCount
            resetState()
            log += "OP_RFM_GETSTT(\(pathNumber), \(statCode))\n"
        }

        return result
    }

    // Receives nothing (rfm.asm sendit only sends the sub-op). No response.
    private func OPRFMSETSTT(data: Data) -> Int {
        resetState()
        return 0
    }

    // Receives: path#(1). Sends back: 1-byte error code.
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
            log += "OP_RFM_CLOSE(\(pathNumber))\n"
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

            // Send the error code
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
        
        func didReceive(changes: String) {
            do {
                let u = URL(fileURLWithPath: self.imagePath)
                self.storageContainer = try Data(contentsOf:u)
            } catch {
                print(error)
            }
        }
        
        /// The drive number for this drive.
        var driveNumber = 0
        
        /// A path to a file that contains the drive's data.
        var imagePath = ""
        
        private var bookmarkData = Data()
        private var storageContainer = Data()
        
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
                self.storageContainer = try Data(contentsOf:u)
            } catch {
                print(error)
            }
        }
        
        /// Reads a 256 byte sector from a virtual disk.
        ///
        /// Call this method to obtain the contents of a 256-byte sector in the virtual disk. If you pass a logical sector number that
        /// is greater than what the virtual disk contains, the function returns a 256-byte sector filled with zeros.
        ///
        /// - Parameters:
        ///     - lsn: The logical sector number to read.
        public func readSector(lsn : Int) -> (Int, Data) {
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

            return DriveWireProtocolError.E_NONE.rawValue
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
