//
//  DriveWireTCPServerDriver.swift
//  DriveWire
//

import Foundation
import Network

/// Serves DriveWire to guests that connect over TCP, such as XRoar's becker port.
///
/// Unlike ``DriveWireTCPDriver``, which dials out to a guest, this driver
/// *listens*: the emulator connects to ``beckerPort`` (XRoar's default is
/// 65504). Each virtual serial channel N is also exposed as its own listening
/// TCP port (``channelPortBase`` + N); bytes flow between whatever connects
/// there and the guest's corresponding `/N` device.
///
/// All Network callbacks are delivered on the main queue: the host's internal
/// watchdog timer needs a running main run loop, which the CLI provides.
class DriveWireTCPServerDriver : NSObject, DriveWireDelegate, ObservableObject {
    /// The host object.
    internal var host = DriveWireHost()

    /// A flag that when set to `true` causes traffic to log.
    public var logging = false

    /// The TCP port the guest's emulator connects to.
    public let beckerPort : UInt16

    /// Virtual serial channel N is served on TCP port `channelPortBase + N`.
    public let channelPortBase : UInt16

    /// The number of channels that get TCP bridge ports.
    public let bridgedChannelCount : Int

    private var beckerListener : NWListener?
    private var guestConnection : NWConnection?
    private var channelListeners : [NWListener] = []
    private var channelClients : [UInt8 : NWConnection] = [:]
    /// Per-channel guest output that arrived while no client was attached.
    private var channelBacklog : [UInt8 : Data] = [:]
    private let backlogLimit = 65536

    /// Creates a listening DriveWire server.
    ///
    /// - Parameters:
    ///     - beckerPort: The TCP port to accept the emulator on.
    ///     - channelPortBase: Channel N is bridged on this port plus N.
    ///     - bridgedChannelCount: How many channels to bridge.
    init(beckerPort : UInt16 = 65504, channelPortBase : UInt16 = 6810, bridgedChannelCount : Int = 4) {
        self.beckerPort = beckerPort
        self.channelPortBase = channelPortBase
        self.bridgedChannelCount = bridgedChannelCount
        super.init()
        host = DriveWireHost(delegate: self)
    }

    /// Starts the becker listener and one bridge listener per channel.
    public func start() throws {
        beckerListener = try makeListener(port: beckerPort) { [weak self] connection in
            self?.acceptGuest(connection)
        }
        for n in 0..<bridgedChannelCount {
            let channel = UInt8(n)
            let listener = try makeListener(port: channelPortBase + UInt16(n)) { [weak self] connection in
                self?.acceptClient(connection, channel: channel)
            }
            channelListeners.append(listener)
        }
    }

    /// Stops all listeners and closes all connections.
    public func stop() {
        beckerListener?.cancel()
        guestConnection?.cancel()
        channelListeners.forEach { $0.cancel() }
        channelClients.values.forEach { $0.cancel() }
        channelListeners.removeAll()
        channelClients.removeAll()
    }

    private func makeListener(port : UInt16, accept : @escaping (NWConnection) -> Void) throws -> NWListener {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = accept
        listener.start(queue: .main)
        return listener
    }

    private func acceptGuest(_ connection : NWConnection) {
        // A newly connecting emulator (e.g. after a reset) replaces the old one.
        guestConnection?.cancel()
        guestConnection = connection
        if logging { print("guest connected on becker port \(beckerPort)") }
        connection.start(queue: .main)
        receiveGuestBytes(connection)
    }

    private func receiveGuestBytes(_ connection : NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            if var data = content, data.isEmpty == false {
                if self.logging { data.dump(prefix: "->") }
                self.host.send(data: &data)
            }
            if isComplete || error != nil {
                if self.logging { print("guest disconnected") }
                if connection === self.guestConnection { self.guestConnection = nil }
                connection.cancel()
                return
            }
            self.receiveGuestBytes(connection)
        }
    }

    private func acceptClient(_ connection : NWConnection, channel : UInt8) {
        channelClients[channel]?.cancel()
        channelClients[channel] = connection
        if logging { print("client connected to channel \(channel)") }
        connection.start(queue: .main)
        if let backlog = channelBacklog.removeValue(forKey: channel), backlog.isEmpty == false {
            connection.send(content: backlog, completion: .contentProcessed { _ in })
        }
        receiveClientBytes(connection, channel: channel)
    }

    private func receiveClientBytes(_ connection : NWConnection, channel : UInt8) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            if let data = content, data.isEmpty == false {
                self.host.writeToChannel(data, channel: channel)
            }
            if isComplete || error != nil {
                // A departing client does NOT close the guest's channel; the
                // next client picks the session up where it left off.
                if self.logging { print("client left channel \(channel)") }
                if connection === self.channelClients[channel] {
                    self.channelClients[channel] = nil
                }
                connection.cancel()
                return
            }
            self.receiveClientBytes(connection, channel: channel)
        }
    }

    @_documentation(visibility: private)
    internal func transactionCompleted(opCode : UInt8) {
    }

    @_documentation(visibility: private)
    internal func dataAvailable(host : DriveWireHost, data : Data) {
        if logging { data.dump(prefix: "<-") }
        guestConnection?.send(content: data, completion: .contentProcessed { _ in })
    }

    @_documentation(visibility: private)
    internal func channelDataAvailable(host : DriveWireHost, channel : UInt8, data : Data) {
        if let client = channelClients[channel] {
            client.send(content: data, completion: .contentProcessed { _ in })
        } else {
            var backlog = channelBacklog[channel, default: Data()]
            backlog.append(data)
            if backlog.count > backlogLimit {
                backlog.removeFirst(backlog.count - backlogLimit)
                if logging { print("channel \(channel) backlog trimmed") }
            }
            channelBacklog[channel] = backlog
        }
    }
}
