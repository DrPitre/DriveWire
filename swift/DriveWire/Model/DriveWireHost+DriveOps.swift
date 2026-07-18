//
//  DriveWireHost+DriveOps.swift
//  DriveWireSwift
//

import Foundation

extension DriveWireHost {
    func OP_DWINIT(data : Data) -> Int {
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

    static func decodedNameObjectPath(from data: Data, length: Int) -> String? {
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

    func OP_NAMEOBJ_MOUNT(data : Data) -> Int {
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

    func OP_NAMEOBJ_CREATE(data : Data) -> Int {
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

    func OP_NOP(data : Data) -> Int {
        currentTransaction = OPNOP
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        return 1
    }

    func OP_TIME(data : Data) -> Int {
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

    func OP_INIT(data : Data) -> Int {
        currentTransaction = 0x49   // OPINIT (historical)
        resetState()
        statistics = DriveWireStatistics()
        resetRFMState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        log += "OP_INIT\n"; print("OP_INIT")
        return 1
    }

    func OP_TERM(data : Data) -> Int {
        currentTransaction = 0x54   // OPTERM (historical)
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        log += "OP_TERM\n"; print("OP_TERM")
        return 1
    }

    func OP_WRITE_CORE(data : Data, operation: UInt8) -> Int {
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
                    markDriveActivity(driveNumber: Int(driveNumber), isReading: false, isWriting: true)
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

    func OP_WRITE(data : Data) -> Int {
        return OP_WRITE_CORE(data: data, operation: OPWRITE)
    }

    func OP_REWRITE(data : Data) -> Int {
        statistics.reWriteCount = statistics.reWriteCount + 1
        return OP_WRITE_CORE(data: data, operation: OPREWRITE)
    }

    func OP_REREADEX(data : Data) -> Int {
        statistics.reReadCount = statistics.reReadCount + 1
        return OP_READEX(data: data)
    }

    func OP_READEX(data : Data) -> Int {
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
                markDriveActivity(driveNumber: Int(driveNumber), isReading: true, isWriting: false)
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
                let msg = "OP_READEX(drive=\(statistics.lastDriveNumber), lsn=0x\(String(statistics.lastLSN, radix: 16))) -> \(error), hostChecksum=0x\(String(readexChecksum, radix: 16, uppercase: true)), guestChecksum=0x\(String(guestChecksum, radix: 16, uppercase: true))"
                reportActivity(msg, isFrequent: true, isError: error != DriveWireProtocolError.E_NONE.rawValue)
                // Reset the state machine.
                resetState()
            }

            return result
        }
    }

    func OP_REREAD(data : Data) -> Int {
        statistics.reReadCount = statistics.reReadCount + 1
        return OP_READ(data: data)
    }

    func OP_READ(data : Data) -> Int {
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
                markDriveActivity(driveNumber: Int(driveNumber), isReading: true, isWriting: false)
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

    func OP_GETSTAT(data : Data) -> Int {
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

    func OP_SETSTAT(data : Data) -> Int {
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

    func OP_RESET(data : Data) -> Int {
        currentTransaction = OPRESET
        resetGuestSessionState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        log = "OP_RESET\n"
        print("OP_RESET")
        return 1
    }

    func OP_WIREBUG(data : Data) -> Int {
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

    func OP_OPCODE(data: Data) -> Int {
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
