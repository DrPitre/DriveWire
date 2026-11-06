import Foundation
import DriveWireCore
import DriveWireNetworking
import DriveWireSerial
import Dispatch

/// One persistent DriveWire guest over TCP or serial. Protocol and connection
/// state runs on the main queue, including responses and guest replacement.
public final class DriveWireServer: DriveWireDelegate {
    public let host: DriveWireHost
    public var logging = false
    public var onConnectionChange: ((Bool) -> Void)?
    private let listener: TCPListener?
    private var serial: SerialConnection?
    private var retry: DispatchWorkItem?
    private var serialSettings: (String, Int, Bool, Bool)?
    public private(set) var serialError: String?
    public private(set) var serialConnected = false
    private var connection: TCPConnection?
    public private(set) var running = false
    public var connected: Bool { connection != nil || serialConnected }
    public private(set) var bytesReceived: UInt64 = 0
    public private(set) var bytesSent: UInt64 = 0
    public private(set) var transactions: UInt64 = 0
    public var port: UInt16 { listener?.port ?? 0 }

    public init(address: String = "127.0.0.1", port: UInt16 = 65504,
                host: DriveWireHost = DriveWireHost()) {
        self.host = host
        listener = TCPListener(host: address, port: port)
    }

    public init(serialPort: String, baud: Int = 57600, dtr: Bool = true, rts: Bool = true,
                host: DriveWireHost = DriveWireHost()) {
        self.host = host
        listener = nil
        serialSettings = (serialPort, baud, dtr, rts)
    }

    public func start() throws {
        guard !running else { return }
        if let listener { try listener.start { [weak self] in self?.accept($0) } }
        running = true
        host.delegate = self
        if serialSettings != nil { openSerial() }
    }

    private func openSerial() {
        guard running, serial == nil, let (path, baud, dtr, rts) = serialSettings else { return }
        retry?.cancel(); retry = nil
        let incoming = SerialConnection(path: path, baud: baud, dtr: dtr, rts: rts)
        serial = incoming
        incoming.onReady = { [weak self, weak incoming] in
            guard let self, self.running, self.serial === incoming else { return }
            self.serialConnected = true; self.serialError = nil
            self.onConnectionChange?(true)
        }
        incoming.onReceive = { [weak self, weak incoming] bytes in
            guard let self, self.running, self.serial === incoming else { return }
            self.receive(bytes)
        }
        incoming.onClose = { [weak self, weak incoming] error in
            guard let self, self.running, self.serial === incoming else { return }
            self.serial = nil; self.serialConnected = false
            self.serialError = error?.localizedDescription
            self.host.disconnectGuest()
            self.onConnectionChange?(false)
            self.retrySerial()
        }
        incoming.start()
    }

    private func retrySerial() {
        guard running, serialSettings != nil else { return }
        let task = DispatchWorkItem { [weak self] in self?.openSerial() }
        retry = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: task)
    }

    public func disconnect() {
        connection?.onClose = nil; connection?.cancel(); connection = nil
        serial?.onClose = nil; serial?.cancel(); serial = nil; serialConnected = false
        retry?.cancel(); retry = nil
        host.disconnectGuest()
        onConnectionChange?(false)
        if running, serialSettings != nil { retrySerial() }
    }

    public func stop() {
        running = false
        disconnect()
        listener?.cancel()
        host.delegate = nil
    }

    private func receive(_ bytes: Data) {
        bytesReceived += UInt64(bytes.count)
        if logging { print("-> \(bytes.map { String(format: "%02x", $0) }.joined())") }
        var buffer = bytes
        host.send(data: &buffer)
    }

    private func accept(_ incoming: TCPConnection) {
        guard running else { incoming.cancel(); return }
        connection?.onClose = nil
        connection?.cancel()
        host.disconnectGuest()
        connection = incoming
        incoming.onReceive = { [weak self, weak incoming] bytes in
            guard let self, self.connection === incoming else { return }
            self.receive(bytes)
        }
        incoming.onClose = { [weak self, weak incoming] _ in
            guard let self, self.connection === incoming else { return }
            self.connection = nil
            self.host.disconnectGuest()
            self.onConnectionChange?(false)
        }
        incoming.start()
        onConnectionChange?(true)
    }

    public func dataAvailable(host: DriveWireHost, data: Data) {
        bytesSent += UInt64(data.count)
        if logging { print("<- \(data.map { String(format: "%02x", $0) }.joined())") }
        connection?.send(data)
        serial?.send(data)
    }

    public func dataAvailableAfterReceiveBoundary(host: DriveWireHost, data: Data) {
        bytesSent += UInt64(data.count)
        if logging { print("<- \(data.map { String(format: "%02x", $0) }.joined())") }
        connection?.send(data)
        serial?.send(data, afterReceiveBoundary: true)
    }

    public func transactionCompleted(opCode: UInt8) { transactions += 1 }
}
