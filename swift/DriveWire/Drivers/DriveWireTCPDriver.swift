//
//  DriveWireTCPDriver.swift
//  DriveWireSwift
//
//  Created by Boisy Pitre on 9/29/23.
//

import Foundation
import Network

/// Provides a TCP/IP interface to a DriveWire host.
///
/// This class provides the ability to connect to a guest on a TCP/IP port. Provide the
/// device name of the serial port in ``init(ipAddress:ipPort:)``
/// When you're ready for the driver to stop, set ``quit`` to `true`.
class DriveWireTCPDriver : NSObject, DriveWireDelegate, ObservableObject, Codable {
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var readBuffer = [UInt8](repeating: 0, count: 1024)
    private var streamQueue = DispatchQueue(label: "DriveWireTCP.StreamQueue")
    @Published public var connected: Bool = false
    
    enum CodingKeys: String, CodingKey {
        case logging
        case ipAddress
        case ipPort
        case log
        case host
    }
    
    /// The log of the driver.
    public var log = ""
    
    /// A flag that when set to `true`,  causes the driver to stop running.
    public var quit = false
    
    /// A flag that when set to `true`,  causes serial traffic to log.
    public var logging = true
    
    /// The TCP/IP address associated with this driver.
    public var ipAddress: String = "" {
        didSet {
            if oldValue != ipAddress {
                reconnect()
            }
        }
    }

    /// The TCP/IP port.
    public var ipPort: UInt32 = 6809 {
        didSet {
            if oldValue != ipPort {
                reconnect()
            }
        }
    }
    
    /// The host object.
    internal var host : DriveWireHost = DriveWireHost()
    
    @_documentation(visibility: private)
    internal func transactionCompleted(opCode: UInt8) {
    }
    
    @_documentation(visibility: private)
    internal func dataAvailable(host: DriveWireHost, data: Data) {
        if logging == true {
            data.dump(prefix: "<-")
        }
        //        serialPort?.send(data)
    }
    
    override init() {
        super.init()
        host = DriveWireHost(delegate: self)
    }
    
    /// Create a driver that connects to a TCP/IP port.
    ///
    /// - Parameters:
    ///     - ipAddress: The TCP/IP address to connect to.
    ///     - ipPort: The TCP/IP port to connect to..
    init(ipAddress: String, ipPort: UInt32) {
        super.init()
        host = DriveWireHost(delegate: self)
        self.ipAddress = ipAddress
        self.ipPort = ipPort
        connect()
    }
    
    func connect() {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        
        CFStreamCreatePairWithSocketToHost(nil, ipAddress as CFString, ipPort, &readStream, &writeStream)
        
        guard let input = readStream?.takeRetainedValue(), let output = writeStream?.takeRetainedValue() else {
            print("Failed to create streams.")
            return
        }
        
        inputStream = input
        outputStream = output
        
        inputStream?.delegate = self
        outputStream?.delegate = self
        
        inputStream?.schedule(in: .current, forMode: .default)
        outputStream?.schedule(in: .current, forMode: .default)
        
        inputStream?.open()
        outputStream?.open()
        
        DispatchQueue.global(qos: .background).async {
            self.readLoop()
        }
        connected = true
    }
    
    private func readLoop() {
        while !quit, let stream = inputStream, stream.hasBytesAvailable {
            let bytesRead = stream.read(&readBuffer, maxLength: readBuffer.count)
            if bytesRead > 0 {
                let data = Data(readBuffer[0..<bytesRead])
                DispatchQueue.main.async {
                    self.dataAvailable(host: self.host, data: data)
                }
            } else {
                if bytesRead < 0 {
                    print("Input stream error: \(stream.streamError?.localizedDescription ?? "unknown")")
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    
    public func send(data: Data) {
        guard let outputStream = outputStream else { return }
        data.withUnsafeBytes {
            _ = outputStream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: data.count)
        }
    }
    
    required init(from decoder: Decoder) throws {
        super.init()
        do {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.ipAddress = try values.decode(String.self, forKey: .ipAddress)
            self.ipPort = try values.decode(UInt32.self, forKey: .ipPort)
            self.log = try values.decode(String.self, forKey: .log)
            self.host = try values.decode(DriveWireHost.self, forKey: .host)
            self.host.delegate = self
        } catch {
            print("\(error)")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ipAddress, forKey:.ipAddress)
        try container.encode(ipPort, forKey:.ipPort)
        try container.encode(log, forKey:.log)
        try container.encode(host, forKey:.host)
    }
    
    public func stop() {
        quit = true
        connected = false
        inputStream?.close()
        outputStream?.close()
        inputStream?.remove(from: .current, forMode: .default)
        outputStream?.remove(from: .current, forMode: .default)
        inputStream = nil
        outputStream = nil
    }
    
    private func reconnect() {
        stop()
        connect()
    }
}

extension DriveWireTCPDriver: StreamDelegate {
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .errorOccurred:
            print("Stream error: \(aStream.streamError?.localizedDescription ?? "Unknown error")")
        case .endEncountered:
            print("Stream ended")
            stop()
        default:
            break
        }
    }
}

/// Provides a TCP server interface to a DriveWire host.
///
/// Listens for an incoming TCP connection (e.g. from MAME's `-bitb socket.127.0.0.1:<port>`)
/// and serves a DriveWire guest over that connection.
class DriveWireTCPServerDriver: NSObject, DriveWireDelegate, ObservableObject {
    private var listener: NWListener?
    private var connection: NWConnection?

    public var logging = false
    public var host: DriveWireHost = DriveWireHost()

    func transactionCompleted(opCode: UInt8) {}

    func dataAvailable(host: DriveWireHost, data: Data) {
        if logging { data.dump(prefix: "<-") }
        connection?.send(content: data, completion: .idempotent)
    }

    func start(port: UInt16) throws {
        host.delegate = self
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw DriveWireHostError.nameNotFound
        }
        listener = try NWListener(using: .tcp, on: nwPort)
        listener?.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener?.stateUpdateHandler = { state in
            if case .ready = state {
                print("DriveWire TCP server listening on port \(port)")
            }
        }
        listener?.start(queue: .main)
    }

    private func accept(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("DriveWire guest connected")
                self?.receive(from: conn)
            case .failed, .cancelled:
                print("DriveWire guest disconnected")
                self?.host.resetRFMState()
                self?.connection = nil
            default:
                break
            }
        }
        conn.start(queue: .main)
    }

    private func receive(from conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                if self?.logging == true { data.dump(prefix: "->") }
                var d = data
                self?.host.send(data: &d)
            }
            if error == nil && !isComplete {
                self?.receive(from: conn)
            } else {
                print("DriveWire guest disconnected")
                self?.host.resetRFMState()
                self?.connection = nil
            }
        }
    }

    func stop() {
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
    }
}
