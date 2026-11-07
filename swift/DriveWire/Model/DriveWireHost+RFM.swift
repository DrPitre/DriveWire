//
//  DriveWireHost+RFM.swift
//  DriveWireSwift
//

import Foundation

extension DriveWireHost {
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
                    // Regular files are read through their live handle. Only directories
                    // use fileContents, which holds their synthesized OS-9 records.
                    attributes = try FileManager.default.attributesOfItem(atPath: localPathname)
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
            if path.hasPrefix("/") {
                let components = path.split(separator: "/").map(String.init)
                guard let device = components.first else { return "/" }
                var resolved = [device]
                // An OS-9 device root's parent is itself, never the host's
                // export root. CoWin loads ../CMDS/grfdrv before SysGo runs.
                for component in components.dropFirst() {
                    if component.allSatisfy({ $0 == "." }) {
                        for _ in 0..<max(0, component.count - 1) {
                            if resolved.count > 1 { resolved.removeLast() }
                        }
                    } else {
                        resolved.append(component)
                    }
                }
                return "/" + resolved.joined(separator: "/")
            }
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
            let sz = localFile != nil ? byteCount : (attributes[.size] as? Int ?? 0)
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

        /// Logical size without changing the RFM cursor. Handle offsets are always
        /// set from filePosition before I/O, so a size query can safely seek to EOF.
        var byteCount: Int {
            if let file = localFile {
                if let length = try? file.seekToEnd(), let count = Int(exactly: length) {
                    return count
                }
                return attributes[.size] as? Int ?? 0
            }
            return fileContents.count
        }

        mutating func readLineFromFile(maximumCount: Int) -> (UInt8, Data) {
            let (error, bytes) = readFromFile(maximumCount: maximumCount)
            guard error == 0 else { return (error, bytes) }
            guard let terminator = bytes.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) else {
                return (0, bytes)
            }
            let consumed = bytes.distance(from: bytes.startIndex, to: terminator) + 1
            filePosition -= bytes.count - consumed
            var line = Data(bytes.prefix(consumed))
            line[line.count - 1] = 0x0D
            return (0, line)
        }

        mutating func readFromFile(maximumCount: Int) -> (UInt8, Data) {
            guard maximumCount > 0 else { return (0, Data()) }
            if let file = localFile {
                do {
                    try file.seek(toOffset: UInt64(filePosition))
                    let bytes = try file.read(upToCount: maximumCount) ?? Data()
                    guard !bytes.isEmpty else { return (211, Data()) }
                    filePosition += bytes.count
                    return (0, bytes)
                } catch {
                    return (245, Data())  // E$Read
                }
            }
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
            guard !bytesToWrite.isEmpty else { return 0 }
            do {
                try file.seek(toOffset: UInt64(filePosition))
                try file.write(contentsOf: bytesToWrite)
                try file.synchronize()
                filePosition += bytesToWrite.count
                attributes[.size] = byteCount
                attributes[.modificationDate] = Date()
                return 0
            } catch {
                return 246  // E$Write
            }
        }
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

    func OP_RFM(data : Data) -> Int {
        var result = 0
        let expectedCount = 2
        currentTransaction = OPRFM

        if data.count >= expectedCount {
            result = expectedCount
            let rfmSubOp = data[1]
            currentSubTransaction = rfmSubOp
            switch currentSubTransaction {
            case 0x11...0x15:
                processor = { self.rfmContextPath(data: $0, operation: rfmSubOp & 0x0F) }
            case DWRFMTransaction.OP_RFM_CREATE.rawValue:
                processor = OPRFMCREATE
            case DWRFMTransaction.OP_RFM_OPEN.rawValue:
                processor = OPRFMOPEN
            case DWRFMTransaction.OP_RFM_MAKDIR.rawValue:
                processor = OPRFMMAKDIR
            case DWRFMTransaction.OP_RFM_CHGDIR.rawValue:
                processor = { self.OPRFMCHGDIR(data: $0) }
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

    // Context protocol: path, PID, immutable directory LSN (24-bit), mode,
    // CR-terminated pathname. No PID lookup is used, including for stale cookies.
    func rfmContextPath(data: Data, operation: UInt8) -> Int {
        guard data.count >= 6, let cr = data.dropFirst(6).firstIndex(of: 13) else { return 0 }
        let cookie = Int(data[2]) << 16 | Int(data[3]) << 8 | Int(data[4])
        let name = String(bytes: data[6..<cr].map { $0 & 0x7F }, encoding: .ascii) ?? ""
        var pathname = name
        if !name.hasPrefix("/"), cookie != 0 {
            guard let directory = rfmLSNToPath[cookie] else {
                delegate?.dataAvailable(host: self, data: Data([216]))
                resetState()
                return cr + 1
            }
            let root = URL(fileURLWithPath: rfmRootPath).standardized.path
            guard directory.hasPrefix(root + "/") else {
                delegate?.dataAvailable(host: self, data: Data([216]))
                resetState()
                return cr + 1
            }
            pathname = String(directory.dropFirst(root.count)) + "/" + name
        } else if !name.hasPrefix("/") {
            // Zero has no directory; never fall back to a mutable PID context.
            delegate?.dataAvailable(host: self, data: Data([216]))
            resetState()
            return cr + 1
        }
        let header = Data([data[0], data[1], 0, data[5]])
        switch operation {
        case 1: _ = OPRFMCREATE(data: header)
        case 2: _ = OPRFMOPEN(data: header)
        case 3: _ = OPRFMMAKDIR(data: header)
        case 4: _ = OPRFMCHGDIR(data: header, contextReply: true)
        case 5: _ = OPRFMDELETE(data: header)
        default: preconditionFailure("invalid context operation")
        }
        _ = processor?(Data(pathname.utf8) + Data([13]))
        return cr + 1
    }

    func OPRFMCREATE(data : Data) -> Int {
        return rfmOpen(data: data, shouldCreate: true)
    }

    // Receives: path#(1), PID(1), directory-owner/parent PID(1), mode(1), then a CR-terminated pathname.
    // Sends back: 1-byte error code.
    func OPRFMOPEN(data : Data) -> Int {
        return rfmOpen(data: data, shouldCreate: false)
    }

    func rfmOpen(data: Data, shouldCreate: Bool) -> Int {
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
            let isExec = (mode & 0x24) != 0
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
                ? (rfmCurrentExecDir[ppid] ?? rfmCurrentExecDir[pid] ?? "none")
                : (rfmCurrentDir[ppid] ?? rfmCurrentDir[pid] ?? "none")
            let msg = "OP_RFM_\(shouldCreate ? "CREATE" : "OPEN")(path#\(capturedPathNumber), pid=\(pid), ppid=\(ppid), mode=0x\(String(mode, radix: 16)), \(dirLabel)=\(dirVal), resolved=\(pathname)) -> \(errorCode)"
            log += msg + "\n"
            print(msg)
            resetState()
            return crOffset - data.startIndex + 1
        }
    }

    func resolveRFMPathname(_ pathname: String, processID: Int, parentProcessID: Int, isExec: Bool = false) -> String {
        guard !(pathname as NSString).isAbsolutePath else { return expandOS9MultiDots(pathname) }
        let dirMap = isExec ? rfmCurrentExecDir : rfmCurrentDir
        let base: String
        // For relative requests the client puts the directory-owner PID in the
        // parent field. It is authoritative even if this request's PID was reused.
        if let cwd = dirMap[parentProcessID] {
            base = cwd
        } else if let cwd = dirMap[processID] {
            base = cwd
        } else {
            return pathname
        }
        if pathname == "." { return base }
        return expandOS9MultiDots((base as NSString).appendingPathComponent(pathname))
    }

    // Expand OS-9 multi-dot path components: N dots = N-1 parent-dir references.
    func expandOS9MultiDots(_ path: String) -> String {
        RFMPathDescriptor.expandMultiDots(path)
    }

    public static func opCodeDisplayName(_ code: UInt8) -> String {
        switch code {
        case 0x00: return "Idle"
        case 0x01: return "OP_NAMEOBJMOUNT"
        case 0x02: return "OP_NAMEOBJCREATE"
        case 0x23: return "OP_TIME"
        case 0x42: return "OP_WIREBUG"
        case 0x43: return "OP_SERREAD"
        case 0x44: return "OP_SERGETSTAT"
        case 0x45: return "OP_SERINIT"
        case 0x46: return "OP_PRINTFLUSH"
        case 0x47: return "OP_GETSTAT"
        case 0x50: return "OP_PRINT"
        case 0x52: return "OP_READ"
        case 0x53: return "OP_SETSTAT"
        case 0x57: return "OP_WRITE"
        case 0x49: return "OP_INIT"
        case 0x54: return "OP_TERM"
        case 0x5A: return "OP_DWINIT"
        case 0x63: return "OP_SERREADM"
        case 0x64: return "OP_SERWRITEM"
        case 0x72: return "OP_REREAD"
        case 0x77: return "OP_REWRITE"
        case 0xC3: return "OP_SERWRITE"
        case 0xC4: return "OP_SERSETSTAT"
        case 0xC5: return "OP_SERTERM"
        case 0xD2: return "OP_READEX"
        case 0xD6: return "OP_RFM"
        case 0xF2: return "OP_REREADEX"
        case 0xF8: return "OP_RESET3"
        case 0xFE: return "OP_RESET2"
        case 0xFF: return "OP_RESET"
        case 0x80...0x8E, 0x91...0x9E: return "OP_FASTWRITE"
        default: return hexDisplay(code)
        }
    }

    public static func statusCodeDisplayName(_ code: UInt8) -> String {
        ssCodeName(Int(code))
    }

    static func hexDisplay<T: BinaryInteger>(_ value: T) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }

    static func ssCodeName(_ code: Int) -> String {
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
        case 0x2D: return "SS.Rename"
        default:   return hexDisplay(code)
        }
    }

    // Returns a stable LSN for the given absolute host path, allocating a new one if needed.
    func lsnForPath(_ path: String) -> Int {
        // Match the host volume's name semantics without resolving symlinks:
        // DD/SYS may point outside DD, but its guest parent must remain DD.
        let url = URL(fileURLWithPath: path).standardized
        let key = rfmIdentityPath(url)
        if let existing = rfmLSNByPath[key] { return existing }
        let lsn = rfmLSNCounter
        rfmLSNByPath[key] = lsn
        rfmLSNToPath[lsn] = path
        rfmLSNCounter += 1
        return lsn
    }

    // Recover the spelling stored by the filesystem, component by component.
    // Foundation's volume case-sensitivity resource is unavailable on some
    // platforms. Enumeration also respects Windows per-directory sensitivity.
    // Only fold a name when the requested spelling actually opens on the host;
    // exact entries always win on case-sensitive filesystems.
    private func rfmIdentityPath(_ url: URL) -> String {
        // Walk a finite component list: deletingLastPathComponent at a volume
        // root does not terminate consistently across Foundation versions.
        let components = url.pathComponents
        guard let root = components.first else { return url.path }
        var current = URL(fileURLWithPath: root, isDirectory: true)
        let fm = FileManager.default
        for requested in components.dropFirst() {
            var stored = requested
            let candidate = current.appendingPathComponent(requested)
            if let names = try? fm.contentsOfDirectory(atPath: current.path),
               !names.contains(requested), fm.fileExists(atPath: candidate.path),
               let match = names.first(where: { $0.caseInsensitiveCompare(requested) == .orderedSame }) {
                stored = match
            }
            current.appendPathComponent(stored)
        }
        return current.path
    }

    // Builds OS-9 directory contents for the open directory descriptor, registering each entry in the LSN map.
    func synthesizeDirectoryEntries(for descriptor: RFMPathDescriptor) -> Data {
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

    func OPRFMMAKDIR(data: Data) -> Int {
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
            let isExec = (capturedMode & 0x24) != 0
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

    func OPRFMCHGDIR(data: Data, contextReply: Bool = false) -> Int {
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
            let isExec = (capturedMode & 0x24) != 0
            let pathname = resolveRFMPathname(String(bytes: pathBytes, encoding: .ascii) ?? "",
                                              processID: capturedProcessID,
                                              parentProcessID: capturedParentProcessID,
                                              isExec: isExec)
            let expandedPathname = expandOS9MultiDots(pathname)
            var errorCode: UInt8 = 216
            var cookie = 0
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
                    // A successful change establishes this PID's own context, even
                    // when the owner is itself or the path equals its parent's.
                    // Removing that entry would lose chd . and inherited snapshots.
                    if capturedMode & 0x1B != 0 {
                        rfmCurrentDir[capturedProcessID] = relativePath
                    }
                    if capturedMode & 0x24 != 0 {
                        rfmCurrentExecDir[capturedProcessID] = relativePath
                    }
                    cookie = lsnForPath(effectiveResolved)
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
            if contextReply && errorCode == 0 {
                delegate?.dataAvailableAfterReceiveBoundary(host: self, data: Data([
                    UInt8((cookie >> 16) & 255), UInt8((cookie >> 8) & 255), UInt8(cookie & 255)]))
            }
            resetState()
            return crOffset - data.startIndex + 1
        }
    }

    func OPRFMDELETE(data: Data) -> Int {
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
            let isExec = (capturedMode & 0x24) != 0
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
    func OPRFMSEEK(data: Data) -> Int {
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
    func OPRFMREAD(data: Data) -> Int {
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
                        delegate?.dataAvailableAfterReceiveBoundary(host: self, data: lineData)
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
    func OPRFMWRITE(data: Data) -> Int {
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
    func OPRFMREADLN(data: Data) -> Int {
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
                        delegate?.dataAvailableAfterReceiveBoundary(host: self, data: lineData)
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
    func OPRFMWRITLN(data: Data) -> Int {
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
    func OPRFMGETSTT(data: Data) -> Int {
        var result = 0
        let expectedCount = 2
        var capturedPathNumber = 0

        if data.count >= expectedCount {
            capturedPathNumber = Int(data[0])
            let statCode = Int(data[1])
            result = expectedCount
            log += "OP_RFM_GETSTT(path#\(capturedPathNumber), \(DriveWireHost.ssCodeName(statCode)))\n"
            print("OP_RFM_GETSTT(path#\(capturedPathNumber), \(DriveWireHost.ssCodeName(statCode)))")
            if statCode == 0x2D {  // SS.Rename capability probe
                delegate?.dataAvailable(host: self, data: Data([rfmPaths[capturedPathNumber] == nil ? 201 : 0]))
                resetState()
            } else if statCode == 0x02 {  // SS.Size — send 4-byte file size
                let size = rfmPaths[capturedPathNumber]?.byteCount ?? 0
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
                let isEOF = rfmPaths[capturedPathNumber].map { $0.filePosition >= $0.byteCount } ?? true
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

    // SETSTT: path, status. SS.Rename ($2D) adds two zero-padded
    // 30-byte basenames. Reply: one OS-9 status byte, including on failure.
    func OPRFMSETSTT(data: Data) -> Int {
        guard data.count >= 2 else { return 0 }
        let count = data[1] == 0x2D ? 62 : 2
        guard data.count >= count else { return 0 }
        let error: UInt8 = data[1] == 0x2D
            ? renameRFMEntry(parent: Int(data[0]), record: Data(data[2..<62])) : 208
        delegate?.dataAvailable(host: self, data: Data([error]))
        resetState()
        return count
    }

    private func renameRFMEntry(parent: Int, record: Data) -> UInt8 {
        func name(_ field: Data) -> String? {
            guard let end = field.firstIndex(of: 0), end > field.startIndex,
                  field.distance(from: field.startIndex, to: end) <= 29,
                  field[end...].allSatisfy({ $0 == 0 }) else { return nil }
            let bytes = field[..<end]
            guard bytes.allSatisfy({ $0 >= 0x21 && $0 < 0x7F && ![47, 92, 58].contains($0) }),
                  let value = String(data: bytes, encoding: .ascii), value != ".", value != ".." else { return nil }
            return value
        }
        guard record.count == 60, let old = name(Data(record.prefix(30))),
              let new = name(Data(record.suffix(30))) else { return 215 }
        guard let descriptor = rfmPaths[parent] else { return 201 }
        guard descriptor.mode & 0x82 == 0x82 else { return 214 }
        let fm = FileManager.default
        let directory = URL(fileURLWithPath: rfmRootPath + descriptor.pathname).standardized
        let root = URL(fileURLWithPath: rfmRootPath).standardized.path
        guard directory.path.hasPrefix(root + "/"), fm.isWritableFile(atPath: directory.path) else { return 214 }
        let source = directory.appendingPathComponent(old)
        let destination = directory.appendingPathComponent(new)
        // attributesOfItem also recognizes a dangling symlink: rename its entry.
        guard (try? fm.attributesOfItem(atPath: source.path)) != nil else { return 216 }
        let oldKey = rfmIdentityPath(source)
        if (try? fm.attributesOfItem(atPath: destination.path)) != nil,
           rfmIdentityPath(destination) != oldKey { return 218 }
        func moved(_ absolute: String) -> String? {
            let key = rfmIdentityPath(URL(fileURLWithPath: absolute))
            guard key == oldKey || key.hasPrefix(oldKey + "/") else { return nil }
            return destination.path + key.dropFirst(oldKey.count)
        }
        // Resolve aliases before the old spelling disappears. Cookies keep their
        // numeric identity, and open descendants and legacy CWDs follow the move.
        let cookieMoves = rfmLSNToPath.compactMap { id, path in moved(path).map { (id, $0) } }
        let pathMoves = rfmPaths.compactMap { id, path in
            moved(rfmRootPath + path.pathname).map { (id, String($0.dropFirst(root.count))) }
        }
        let dataMoves = rfmCurrentDir.compactMap { id, path in
            moved(rfmRootPath + path).map { (id, String($0.dropFirst(root.count))) }
        }
        let execMoves = rfmCurrentExecDir.compactMap { id, path in
            moved(rfmRootPath + path).map { (id, String($0.dropFirst(root.count))) }
        }
        do {
            if URL(fileURLWithPath: oldKey).lastPathComponent != new {
                try fm.moveItem(at: source, to: destination)
            }
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { return 218 }
            return 214
        }
        for (id, path) in cookieMoves { rfmLSNToPath[id] = path }
        let movedIDs = Set(cookieMoves.map { $0.0 })
        rfmLSNByPath = rfmLSNByPath.filter { !movedIDs.contains($0.value) }
        for (id, path) in cookieMoves { rfmLSNByPath[rfmIdentityPath(URL(fileURLWithPath: path))] = id }
        for (id, path) in pathMoves { rfmPaths[id]?.pathname = path }
        for (id, path) in dataMoves { rfmCurrentDir[id] = path }
        for (id, path) in execMoves { rfmCurrentExecDir[id] = path }
        for (id, path) in Array(rfmPaths) where path.mode & 0x80 != 0 {
            rfmPaths[id]?.fileContents = synthesizeDirectoryEntries(for: path)
        }
        return 0
    }

    // Receives: path#(1). Sends back: 1-byte error code.
    // Receives: path#(1). Sends back: 1-byte error code.
    // If the path was opened via CREATE, the shell closes its reference after
    // forking the child writer — keep the descriptor alive for incoming writes.
    func OPRFMCLOSE(data: Data) -> Int {
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
}
