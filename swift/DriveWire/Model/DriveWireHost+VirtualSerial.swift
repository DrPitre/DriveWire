//
//  DriveWireHost+VirtualSerial.swift
//  DriveWireSwift
//

import Foundation
import Network

extension DriveWireHost {
    struct PendingVirtualSerialTCPConnection {
        let connection: NWConnection
        let localPort: UInt16
        let remoteAddress: String
    }

    final class VirtualSerialTCPConnection {
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

    func OP_SERINIT(data : Data) -> Int {
        currentTransaction = OPSERINIT
        guard data.count >= 2 else { return 0 }
        let ch = data[1]
        openVirtualSerialChannels.insert(ch)
        refreshVirtualSerialChannelStatuses()
        if isVirtualWindowChannel(ch) {
            openVirtualWindow(channel: ch)
        }
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        let msg = "OP_SERINIT(ch=\(ch))"; log += msg + "\n"; print(msg)
        return 2
    }

    func OP_SERTERM(data : Data) -> Int {
        currentTransaction = OPSERTERM
        guard data.count >= 2 else { return 0 }
        let ch = data[1]
        retireVirtualSerialChannel(ch)
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        let msg = "OP_SERTERM(ch=\(ch))"; log += msg + "\n"; print(msg)
        return 2
    }

    func OP_SERREAD(data : Data) -> Int {
        currentTransaction = OPSERREAD
        guard data.count >= 1 else { return 0 }
        resetState()
        let response = pollVirtualSerial()
        delegate?.dataAvailable(host: self, data: response)
        delegate?.transactionCompleted(opCode: currentTransaction)
        reportActivity("OP_SERREAD -> \(response[0]),\(response[1])", isFrequent: true)
        return 1
    }

    func OP_SERREADM(data : Data) -> Int {
        currentTransaction = OPSERREADM
        guard data.count >= 3 else { return 0 }
        let ch = data[1]
        let count = serialMultiByteCount(data[2])
        let response = readVirtualSerial(channel: virtualSerialInputChannel(forGuestChannel: ch), count: count)
        resetState()
        delegate?.dataAvailable(host: self, data: response)
        delegate?.transactionCompleted(opCode: currentTransaction)
        reportActivity("OP_SERREADM(ch=\(ch), bytes=\(count))", isFrequent: true)
        return 3
    }

    func OP_SERWRITE(data : Data) -> Int {
        currentTransaction = OPSERWRITE
        guard data.count >= 3 else { return 0 }
        let ch = data[1]; let byte = data[2]
        writeVirtualSerial(channel: ch, data: Data([byte]))
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        let msg = "OP_SERWRITE(ch=\(ch), byte=0x\(String(byte, radix: 16)))"; log += msg + "\n"; print(msg)
        return 3
    }

    func OP_SERWRITEM(data : Data) -> Int {
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
        let count = serialMultiByteCount(data[2])
        let total = 3 + count
        guard data.count >= total else { return 0 }
        writeVirtualSerial(channel: ch, data: data.subdata(in: 3..<total))
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        reportActivity("OP_SERWRITEM(ch=\(ch), countByte=0x\(String(data[2], radix: 16, uppercase: true)), bytes=\(count))", isFrequent: !isMIDIVirtualSerialChannel(ch))
        return total
    }

    func serialMultiByteCount(_ countByte: UInt8) -> Int {
        countByte == 0 ? 256 : Int(countByte)
    }

    func OP_SERGETSTAT(data : Data) -> Int {
        currentTransaction = OPSERGETSTAT
        guard data.count >= 3 else { return 0 }
        let ch = data[1]; let code = data[2]
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        let msg = "OP_SERGETSTAT(ch=\(ch), \(DriveWireHost.ssCodeName(Int(code))))"; log += msg + "\n"; print(msg)
        return 3
    }

    func OP_SERSETSTAT(data : Data) -> Int {
        currentTransaction = OPSERSETSTAT
        guard data.count >= 3 else { return 0 }
        let ch = data[1]; let code = data[2]
        let expectedCount = code == 0x28 ? 29 : 3
        guard data.count >= expectedCount else { return 0 }
        switch code {
        case 0x29:
            openVirtualSerialChannels.insert(ch)
            refreshVirtualSerialChannelStatuses()
            if isVirtualWindowChannel(ch) {
                openVirtualWindow(channel: ch)
            }
        case 0x2A:
            if isMIDIVirtualSerialChannel(ch) {
                reportActivity("OP_SERSETSTAT(ch=\(ch), SS.Close) with \(midiFileBytesReceived) MIDI file byte\(midiFileBytesReceived == 1 ? "" : "s") received")
            }
            retireVirtualSerialChannel(ch)
        default:
            break
        }
        resetState()
        delegate?.transactionCompleted(opCode: currentTransaction)
        let msg = "OP_SERSETSTAT(ch=\(ch), \(DriveWireHost.ssCodeName(Int(code))))"; log += msg + "\n"; print(msg)
        return expectedCount
    }

    func pollVirtualSerial() -> Data {
        if clientRestartRequested {
            clientRestartRequested = false
            return Data([16, 255])
        }

        if let channel = pendingClosedVirtualSerialChannels.first,
           virtualSerialInput[channel]?.isEmpty ?? true {
            pendingClosedVirtualSerialChannels.removeFirst()
            retireVirtualSerialChannel(channel)
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

    func readVirtualSerial(channel: UInt8, count: Int) -> Data {
        guard count > 0, var queued = virtualSerialInput[channel], !queued.isEmpty else {
            return Data()
        }

        let readCount = min(count, queued.count)
        let response = queued.prefix(readCount)
        queued.removeFirst(readCount)
        virtualSerialInput[channel] = queued
        pulseVirtualSerialChannel(channel, incoming: false)
        refreshVirtualSerialChannelStatuses()
        return Data(response)
    }

    func retireVirtualSerialChannel(_ channel: UInt8) {
        if isMIDIVirtualSerialChannel(channel) {
            reportActivity("MIDI channel retiring after \(midiFileBytesReceived) file byte\(midiFileBytesReceived == 1 ? "" : "s"), tracks \(standardMIDIPlayback?.completedFileTrackCount ?? 0)/\(standardMIDIPlayback?.expectedFileTrackCount ?? 0)")
            finishMIDIStream()
        }
        virtualSerialTCPConnections[channel]?.close()
        virtualSerialTCPConnections[channel] = nil
        openVirtualSerialChannels.remove(channel)
        virtualSerialInput.removeValue(forKey: channel)
        virtualSerialCommandBuffers.removeValue(forKey: channel)
        pendingClosedVirtualSerialChannels.removeAll { $0 == channel }
        virtualSerialIncomingPulseTokens.removeValue(forKey: channel)
        virtualSerialOutgoingPulseTokens.removeValue(forKey: channel)
        if isVirtualWindowChannel(channel) {
            closeVirtualWindow(channel: channel)
        } else {
            refreshVirtualSerialChannelStatuses()
        }
    }

    func writeVirtualSerial(channel: UInt8, data: Data) {
        guard !data.isEmpty else { return }
        pulseVirtualSerialChannel(channel, incoming: true)

        if isMIDIVirtualSerialChannel(channel) {
            handleMIDIData(data)
            return
        }

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
        refreshVirtualSerialChannelStatuses()
        openVirtualWindow(channel: channel)
    }

    public func clearVirtualWindow(channel: UInt8) {
        guard let index = virtualWindowIndex(for: channel, createIfNeeded: false) else {
            return
        }
        virtualWindows[index].text = ""
    }

    func openVirtualWindow(channel: UInt8) {
        guard let index = virtualWindowIndex(for: channel, createIfNeeded: true) else {
            return
        }
        virtualWindows[index].isOpen = true
        refreshVirtualSerialChannelStatuses()
    }

    func closeVirtualWindow(channel: UInt8) {
        guard let index = virtualWindowIndex(for: channel, createIfNeeded: false) else {
            return
        }
        virtualWindows[index].isOpen = false
        refreshVirtualSerialChannelStatuses()
    }

    func appendVirtualWindowOutput(_ data: Data, channel: UInt8) {
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

    func pulseVirtualSerialChannel(_ channel: UInt8, incoming: Bool) {
        guard channel >= 1 && channel <= 8 else { return }

        let token = nextVirtualSerialPulseToken
        nextVirtualSerialPulseToken &+= 1
        if incoming {
            virtualSerialIncomingPulseTokens[channel] = token
        } else {
            virtualSerialOutgoingPulseTokens[channel] = token
        }
        refreshVirtualSerialChannelStatuses()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            guard let self else { return }
            if incoming {
                guard self.virtualSerialIncomingPulseTokens[channel] == token else { return }
                self.virtualSerialIncomingPulseTokens.removeValue(forKey: channel)
            } else {
                guard self.virtualSerialOutgoingPulseTokens[channel] == token else { return }
                self.virtualSerialOutgoingPulseTokens.removeValue(forKey: channel)
            }
            self.refreshVirtualSerialChannelStatuses()
        }
    }

    func refreshVirtualSerialChannelStatuses() {
        virtualSerialChannels = (1...8).map { number in
            let channel = UInt8(number)
            return DriveWireVirtualChannelStatus(
                channel: channel,
                number: number,
                isOpen: openVirtualSerialChannels.contains(channel),
                incomingActive: virtualSerialIncomingPulseTokens[channel] != nil,
                outgoingActive: virtualSerialOutgoingPulseTokens[channel] != nil,
                pendingBytes: virtualSerialInput[channel]?.count ?? 0,
                isTCPBacked: virtualSerialTCPConnections[channel] != nil
            )
        }
    }

    func virtualWindowIndex(for channel: UInt8, createIfNeeded: Bool) -> Int? {
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

    func processVirtualSerialCommand(_ command: String, channel: UInt8) {
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

    func enqueueVirtualSerialResponse(_ response: String, channel: UInt8) {
        virtualSerialInput[channel, default: Data()].append(contentsOf: response.data(using: .ascii) ?? Data())
        refreshVirtualSerialChannelStatuses()
    }

    func enqueueDriveWireUtilityResponse(_ text: String, channel: UInt8) {
        enqueueVirtualSerialResponse(driveWireAPISuccess(text), channel: channel)
        pendingClosedVirtualSerialChannels.append(channel)
    }

    func driveWireAPISuccess(_ text: String) -> String {
        "OK command successful\n\r" + text
    }

    func driveWireAPIFailure(code: UInt8, text: String) -> String {
        String(format: "FAIL %03d %@\r", Int(code), text)
    }

    func virtualSerialTCPSuccess(_ text: String = "") -> String {
        text.isEmpty ? "SUCCESS\n\r" : "SUCCESS\n\r" + text
    }

    func virtualSerialTCPFailure(_ text: String = "") -> String {
        text.isEmpty ? "FAIL\n\r" : "FAIL\n\r" + text
    }

    func processVirtualSerialTCPCommand(_ command: String, channel: UInt8) -> String {
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

    func tcpConnect(_ arguments: [String], channel: UInt8) -> String {
        guard arguments.count >= 2, let tcpPort = UInt16(arguments[1]), tcpPort > 0 else {
            return virtualSerialTCPFailure()
        }

        let host = arguments[0]
        virtualSerialTCPConnections[channel]?.close()
        openVirtualSerialChannels.insert(channel)
        refreshVirtualSerialChannelStatuses()

        let connection = makeVirtualSerialTCPConnection(channel: channel, host: host, port: tcpPort)
        virtualSerialTCPConnections[channel] = connection
        refreshVirtualSerialChannelStatuses()
        connection.start()
        return virtualSerialTCPSuccess()
    }

    func tcpListen(_ arguments: [String], channel: UInt8) -> String {
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
            refreshVirtualSerialChannelStatuses()
            return virtualSerialTCPSuccess()
        } catch {
            return virtualSerialTCPFailure()
        }
    }

    func tcpJoin(_ arguments: [String], channel: UInt8) -> String {
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
        refreshVirtualSerialChannelStatuses()
        connection.start()
        return virtualSerialTCPSuccess()
    }

    func tcpKill(_ arguments: [String]) -> String {
        guard let idText = arguments.first, let connectionID = Int(idText),
              let pending = pendingVirtualSerialTCPConnections.removeValue(forKey: connectionID) else {
            return virtualSerialTCPFailure()
        }

        pending.connection.cancel()
        return virtualSerialTCPSuccess()
    }

    func acceptVirtualSerialTCPConnection(_ connection: NWConnection, localPort: UInt16, announceOn channel: UInt8) {
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

    func remoteAddressDescription(for endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _):
            return "\(host)"
        default:
            return "\(endpoint)"
        }
    }

    func makeVirtualSerialTCPConnection(channel: UInt8, host: String, port: UInt16) -> VirtualSerialTCPConnection {
        VirtualSerialTCPConnection(host: host, port: port, onReceive: { [weak self] data in
            DispatchQueue.main.async {
                self?.virtualSerialInput[channel, default: Data()].append(data)
                self?.refreshVirtualSerialChannelStatuses()
            }
        }, onClose: { [weak self] in
            DispatchQueue.main.async {
                self?.virtualSerialTCPConnections[channel] = nil
                self?.openVirtualSerialChannels.remove(channel)
                self?.refreshVirtualSerialChannelStatuses()
            }
        })
    }

    func makeVirtualSerialTCPConnection(channel: UInt8, connection: NWConnection, host: String, port: UInt16) -> VirtualSerialTCPConnection {
        VirtualSerialTCPConnection(connection: connection, host: host, port: port, onReceive: { [weak self] data in
            DispatchQueue.main.async {
                self?.virtualSerialInput[channel, default: Data()].append(data)
                self?.refreshVirtualSerialChannelStatuses()
            }
        }, onClose: { [weak self] in
            DispatchQueue.main.async {
                self?.virtualSerialTCPConnections[channel] = nil
                self?.openVirtualSerialChannels.remove(channel)
                self?.refreshVirtualSerialChannelStatuses()
            }
        })
    }

    func isVirtualWindowChannel(_ channel: UInt8) -> Bool {
        channel >= 0x81 && channel <= 0x8F
    }

    func isMIDIVirtualSerialChannel(_ channel: UInt8) -> Bool {
        channel == Self.midiVirtualSerialChannel
    }

    func virtualWindowTitle(for channel: UInt8) -> String {
        "/Z\(Int(channel & 0x0F))"
    }

    func virtualWindowGuestChannel(forInternalChannel channel: UInt8) -> UInt8 {
        0x40 | (channel & 0x0F)
    }

    func virtualSerialInputChannel(forGuestChannel channel: UInt8) -> UInt8 {
        if channel & 0xC0 == 0x40 {
            let virtualWindowChannel = 0x80 | (channel & 0x0F)
            if isVirtualWindowChannel(virtualWindowChannel), virtualSerialInput[virtualWindowChannel] != nil {
                return virtualWindowChannel
            }
        }
        return channel
    }
}
