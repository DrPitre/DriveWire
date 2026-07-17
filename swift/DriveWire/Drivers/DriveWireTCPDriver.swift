//
//  DriveWireTCPDriver.swift
//  DriveWireSwift
//
//  Created by Boisy Pitre on 9/29/23.
//

import Foundation

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
    private var isRestoringState = false
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
    
    /// A flag that when set to `true`, causes raw network traffic hex dumps to log.
    public var logging = false
    
    /// The TCP/IP address associated with this driver.
    public var ipAddress: String = "" {
        didSet {
            guard !isRestoringState else {
                return
            }
            if oldValue != ipAddress {
                reconnect()
            }
        }
    }

    /// The TCP/IP port.
    public var ipPort: UInt32 = 6809 {
        didSet {
            guard !isRestoringState else {
                return
            }
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
        send(data: data)
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
    
    /// Connects to the given endpoint, replacing any current connection.
    ///
    /// - Parameters:
    ///     - ipAddress: The TCP/IP address to connect to.
    ///     - ipPort: The TCP/IP port to connect to.
    public func connect(ipAddress: String, ipPort: UInt32) {
        isRestoringState = true
        self.ipAddress = ipAddress
        self.ipPort = ipPort
        isRestoringState = false
        reconnect()
    }

    func connect() {
        quit = false
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
        while !quit, let stream = inputStream {
            if stream.hasBytesAvailable {
                let bytesRead = stream.read(&readBuffer, maxLength: readBuffer.count)
                if bytesRead > 0 {
                    let data = Data(readBuffer[0..<bytesRead])
                    if logging == true {
                        data.dump(prefix: "->")
                    }
                    DispatchQueue.main.async {
                        var incoming = data
                        self.host.send(data: &incoming)
                    }
                } else {
                    if bytesRead < 0 {
                        print("Input stream error: \(stream.streamError?.localizedDescription ?? "unknown")")
                    }
                    break
                }
            } else {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    public func send(data: Data) {
        guard let outputStream = outputStream else { return }
        data.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self).baseAddress!
            var written = 0
            while written < data.count {
                let result = outputStream.write(bytes + written, maxLength: data.count - written)
                if result <= 0 {
                    print("Output stream error: \(outputStream.streamError?.localizedDescription ?? "unknown")")
                    return
                }
                written += result
            }
        }
    }
    
    required init(from decoder: Decoder) throws {
        super.init()
        isRestoringState = true
        defer { isRestoringState = false }
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
