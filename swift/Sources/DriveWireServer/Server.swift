import Foundation
import DriveWireCore
import DriveWireNetworking

/// One persistent DriveWire guest per listener. All protocol and connection
/// state runs on the main queue, including responses and guest replacement.
public final class DriveWireServer: DriveWireDelegate {
    public let host: DriveWireHost
    public var logging = false
    public var onConnectionChange: ((Bool) -> Void)?
    private let listener: TCPListener
    private var connection: TCPConnection?
    private var running = false
    public var port: UInt16 { listener.port }

    public init(address: String = "127.0.0.1", port: UInt16 = 65504,
                host: DriveWireHost = DriveWireHost()) {
        self.host = host
        listener = TCPListener(host: address, port: port)
    }

    public func start() throws {
        guard !running else { return }
        try listener.start { [weak self] in self?.accept($0) }
        running = true
        host.delegate = self
    }

    public func stop() {
        running = false
        connection?.onClose = nil
        connection?.cancel()
        connection = nil
        listener.cancel()
        host.disconnectGuest()
        host.delegate = nil
    }

    private func accept(_ incoming: TCPConnection) {
        guard running else { incoming.cancel(); return }
        connection?.onClose = nil
        connection?.cancel()
        host.disconnectGuest()
        connection = incoming
        incoming.onReceive = { [weak self, weak incoming] bytes in
            guard let self, self.connection === incoming else { return }
            if self.logging { print("-> \(bytes.map { String(format: "%02x", $0) }.joined())") }
            var buffer = bytes
            self.host.send(data: &buffer)
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
        if logging { print("<- \(data.map { String(format: "%02x", $0) }.joined())") }
        connection?.send(data)
    }

    public func transactionCompleted(opCode: UInt8) {}
}
