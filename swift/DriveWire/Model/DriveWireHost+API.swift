//
//  DriveWireHost+API.swift
//  DriveWireSwift
//

import Foundation

extension DriveWireHost {
    func processDriveWireAPICommand(_ command: String) -> String {
        let arguments = Array(command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init).dropFirst())
        let result = parseDriveWireAPI(arguments)
        switch result {
        case .success(let text):
            return driveWireAPISuccess(text)
        case .failure(let code, let text):
            return driveWireAPIFailure(code: code, text: text)
        }
    }

    enum DriveWireAPIResult {
        case success(String)
        case failure(UInt8, String)
    }

    struct DriveWireAPICommand {
        let name: String
        let help: String
    }

    enum DriveWireAPICommandMatch {
        case success(String)
        case failure(String)
    }

    func parseDriveWireAPI(_ arguments: [String]) -> DriveWireAPIResult {
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

    func parseClientCommand(_ arguments: [String]) -> DriveWireAPIResult {
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

    func parseConfigCommand(_ arguments: [String]) -> DriveWireAPIResult {
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

    func parseDiskCommand(_ arguments: [String]) -> DriveWireAPIResult {
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

    func parseInstanceCommand(_ arguments: [String]) -> DriveWireAPIResult {
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

    func parseLogCommand(_ arguments: [String]) -> DriveWireAPIResult {
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

    func parseMIDICommand(_ arguments: [String]) -> DriveWireAPIResult {
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

    func parseNetCommand(_ arguments: [String]) -> DriveWireAPIResult {
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

    func parsePortCommand(_ arguments: [String]) -> DriveWireAPIResult {
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

    func parseServerCommand(_ arguments: [String]) -> DriveWireAPIResult {
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

    func match(_ input: String, in commands: [String]) -> DriveWireAPICommandMatch {
        let matches = commands.filter { $0.hasPrefix(input.lowercased()) }
        if matches.count == 1 {
            return .success(matches[0])
        } else if matches.isEmpty {
            return .failure("Unknown command '\(input)'")
        } else {
            return .failure("Ambiguous command, '\(input)' matches \(matches.joined(separator: " or "))")
        }
    }

    func shortHelp(for commands: [DriveWireAPICommand]) -> String {
        let names = commands.map(\.name).sorted()
        return "Possible commands:\r\n\r\n" + columnLayout(names) + "\r\n"
    }

    func columnLayout(_ values: [String], columns: Int = 80) -> String {
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

    func currentDriveWireAPIConfig() -> [String: String] {
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

    func configShow(_ arguments: [String]) -> DriveWireAPIResult {
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

    func configSet(_ arguments: [String]) -> DriveWireAPIResult {
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

    func instanceShow() -> DriveWireAPIResult {
        var text = "DriveWire protocol handler instances:\r\n\n"
        text += "#0  (Ready)     "
        text += String(format: "Proto: %-11@", "DriveWire")
        text += String(format: "Type: %-11@", "swift")
        text += "Drives: \(virtualDrives.count) Ports: \(openVirtualSerialChannels.count)\r\n"
        return .success(text)
    }

    func instanceLifecycle(arguments: [String], action: String) -> DriveWireAPIResult {
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

    func logShow(_ arguments: [String]) -> DriveWireAPIResult {
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

    func midiStatus() -> DriveWireAPIResult {
        var text = "\r\nDriveWire MIDI status:\r\n\n"
        for line in midiBackend.statusLines() {
            text += line + "\r\n"
        }
        text += "\r\n"
        return .success(text)
    }

    func midiOutput(_ arguments: [String]) -> DriveWireAPIResult {
        if let argument = arguments.first {
            guard arguments.count == 1, let outputIndex = Int(argument) else {
                return .failure(10, "Syntax error: dw midi output requires a numeric device #")
            }

            do {
                try midiBackend.selectOutput(index: outputIndex)
                lastMIDIErrorMessage = nil
                refreshMIDIStatus()
                return .success("MIDI output set to \(midiBackend.selectedOutputName ?? "device #\(outputIndex)").\r\n")
            } catch {
                lastMIDIErrorMessage = error.localizedDescription
                refreshMIDIStatus()
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

    func midiSynth(_ arguments: [String]) -> DriveWireAPIResult {
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
                lastMIDIErrorMessage = nil
                midiState = "Stopped"
                refreshMIDIStatus()
                return .success("MIDI synthesizer reset sent.\r\n")
            } catch {
                lastMIDIErrorMessage = error.localizedDescription
                midiState = "Error"
                refreshMIDIStatus()
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

    func netShow() -> DriveWireAPIResult {
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

    func diskCreate(_ arguments: [String]) -> DriveWireAPIResult {
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

    func diskShow(_ arguments: [String]) -> DriveWireAPIResult {
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

    func diskInsert(_ arguments: [String]) -> DriveWireAPIResult {
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

    func diskEject(_ arguments: [String]) -> DriveWireAPIResult {
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

    func diskReload(_ arguments: [String]) -> DriveWireAPIResult {
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

    func diskDump(_ arguments: [String]) -> DriveWireAPIResult {
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

    func diskSet(_ arguments: [String]) -> DriveWireAPIResult {
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

    func diskWrite(_ arguments: [String]) -> DriveWireAPIResult {
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

    func portOpen(_ arguments: [String]) -> DriveWireAPIResult {
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
        refreshVirtualSerialChannelStatuses()

        let connection = makeVirtualSerialTCPConnection(channel: channel, host: host, port: tcpPort)
        virtualSerialTCPConnections[channel] = connection
        refreshVirtualSerialChannelStatuses()
        connection.start()

        return .success("Port #\(portNumber) open.\r\n")
    }

    func portClose(_ arguments: [String]) -> DriveWireAPIResult {
        guard let portArgument = arguments.first else {
            return .failure(10, "dw port close requires a port # as an argument")
        }
        guard arguments.count == 1, let portNumber = Int(portArgument), portNumber >= 0, portNumber < 15 else {
            return .failure(10, "Syntax error: non numeric port #")
        }

        let channel = UInt8(portNumber)
        retireVirtualSerialChannel(channel)
        return .success("Port #\(portNumber) closed.\r\n")
    }

    func portShow() -> DriveWireAPIResult {
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

    func serverStatus() -> DriveWireAPIResult {
        var text = "DriveWire Swift status:\r\n\n"
        text += "Device:        Swift host\r\n"
        text += "DW4 support:   enabled\r\n"
        text += "Virtual disks: \(virtualDrives.count)\r\n"
        text += "Open ports:    \(openVirtualSerialChannels.count)\r\n"
        text += "Last opcode:   \(Self.opCodeDisplayName(statistics.lastOpCode))\r\n"
        text += "Reads:         \(statistics.readCount)\r\n"
        text += "Writes:        \(statistics.writeCount)\r\n"
        return .success(text)
    }

    func serverShow(_ arguments: [String]) -> DriveWireAPIResult {
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

    func serverHelp(_ arguments: [String]) -> DriveWireAPIResult {
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

    func serverHelpShow(_ arguments: [String]) -> DriveWireAPIResult {
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

    func serverShowSerial() -> DriveWireAPIResult {
        var text = "\r\nDriveWire serial status:\r\n\n"
        text += "Open virtual channels: \(openVirtualSerialChannels.sorted().map { "/N\(Int($0) + 1)" }.joined(separator: ", "))\r\n"
        text += "TCP-backed channels: \(virtualSerialTCPConnections.count)\r\n"
        text += "Pending close notifications: \(pendingClosedVirtualSerialChannels.count)\r\n"
        text += "Client restart pending: \(clientRestartRequested ? "true" : "false")\r\n"
        return .success(text)
    }

    func serverShowThreads() -> DriveWireAPIResult {
        var text = "\r\nDriveWire Server Threads:\r\n\n"
        text += String(format: "%40@ %3d %-8@ %-14@\r\n", "main", 0, "Swift", Thread.isMainThread ? "RUNNABLE" : "UNKNOWN")
        text += String(format: "%40@ %3d %-8@ %-14@\r\n", "virtual-serial-tcp", 0, "Swift", virtualSerialTCPConnections.isEmpty ? "IDLE" : "RUNNABLE")
        return .success(text)
    }

    func serverShowTimers() -> DriveWireAPIResult {
        var text = "DriveWire instance timers (not shown == 0):\r\n\r\n"
        text += "No active instance timers.\r\n"
        return .success(text)
    }

    func serverTurbo() -> DriveWireAPIResult {
        .success("Failed to enable DATurbo mode: active device does not support serial baud-rate switching.\r\n")
    }

    func serverDir(_ arguments: [String]) -> DriveWireAPIResult {
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

    func serverList(_ arguments: [String]) -> DriveWireAPIResult {
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

    func serverPrint(_ arguments: [String]) -> DriveWireAPIResult {
        guard !arguments.isEmpty else {
            return .failure(10, "dw server print requires a URI or local file path as an argument")
        }

        let path = arguments.joined(separator: " ")
        do {
            writePrinterData(try Data(contentsOf: serverFileURL(from: path)))
            return .success("Sent item to printer\r\n")
        } catch {
            return .failure(202, error.localizedDescription)
        }
    }

    func parseDriveNumber(_ value: String) -> Int? {
        let trimmed = value.uppercased().hasPrefix("X") ? String(value.dropFirst()) : value
        guard let number = Int(trimmed), number >= 0, number <= 255 else {
            return nil
        }
        return number
    }

    func serverFileURL(from path: String) -> URL {
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

    func hexDump(_ data: Data, baseAddress: Int) -> String {
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

    func shortenedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
