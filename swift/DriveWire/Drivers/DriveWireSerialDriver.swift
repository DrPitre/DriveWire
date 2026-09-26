//
//  DriveWireSerialDriver.swift
//  DriveWireSwift
//
//  Created by Boisy Pitre on 9/29/23.
//

import ORSSerial
import Combine

/// Provides a serial interface to a DriveWire host.
///
/// This class provides the ability to connect to a guest on a serial port. Provide the
/// device name of the serial port in ``init(serialPort:)``
/// When you're ready for the driver to stop, set ``quit`` to `true`.
///
/// If the selected port is not present, or is removed while in use, the driver
/// waits for it and reopens it when the system reports it again.
class DriveWireSerialDriver : NSObject, DriveWireDelegate, ORSSerialPortDelegate, ObservableObject, Codable {
    
    enum CodingKeys: String, CodingKey {
        case logging
        case portName
        case baudRate
        case log
        case host
    }
    
    /// The log of the driver.
    public var log = ""
    
    /// A flag that when set to `true`,  causes the driver to stop running.
    public var quit = false
    
    /// A flag that when set to `true`, causes raw serial traffic hex dumps to log.
    public var logging = false

    @Published public private(set) var isConnected = false

    /// `true` while the driver wants the selected port but it is absent or failed to open.
    @Published public private(set) var isWaitingForPort = false

    private var isRestoringState = false
    private var serialPort : ORSSerialPort?

    /// `true` from a connection request until ``stop()``, including while the port is absent.
    private var wantsConnection = false

    /// The last open error logged, so repeated retries don't flood the log.
    private var lastOpenError: String?

    /// How long to wait before retrying a port that is present but failed to open.
    private static let openRetryDelay: TimeInterval = 2
    
    /// The serial port associated with this driver.
    public var portName : String = "" {
        didSet {
            guard !isRestoringState else {
                return
            }

            guard oldValue != portName else {
                return
            }

            connectIfPossible()
        }
    }
    
    /// The serial port's speed.
    public var baudRate = 57600 {
        didSet {
            serialPort?.baudRate = NSNumber(value: baudRate)
        }
    }
    
    /// The host object.
    internal var host : DriveWireHost = DriveWireHost()

    @_documentation(visibility: private)
    internal func serialPortWasRemovedFromSystem(_ serialPort: ORSSerialPort) {
        releasePort()
        if wantsConnection {
            isWaitingForPort = true
            note("Serial port \(serialPort.path) removed, waiting for it to return")
        }
    }
    
    @_documentation(visibility: private)
    internal func serialPortWasOpened(_ serialPort: ORSSerialPort) {
        isConnected = true
        isWaitingForPort = false
        lastOpenError = nil
        note("Serial port \(serialPort.path) opened")
    }
    
    @_documentation(visibility: private)
    internal func serialPort(_ serialPort: ORSSerialPort, didEncounterError error: Error) {
        if serialPort.isOpen {
            log += "Serial error: \(error.localizedDescription)\n"
            print(error)
            return
        }

        // The port is present but would not open (busy, or not ready yet after
        // being plugged in), so drop it and try again shortly
        isConnected = false
        releasePort()
        guard wantsConnection else {
            return
        }
        isWaitingForPort = true
        if lastOpenError != error.localizedDescription {
            lastOpenError = error.localizedDescription
            note("Serial port \(serialPort.path) failed to open: \(error.localizedDescription), retrying")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.openRetryDelay) { [weak self] in
            self?.reopenIfWanted()
        }
    }
    
    @_documentation(visibility: private)
    internal func serialPort(_ serialPort: ORSSerialPort, didReceive data: Data) {
        var d = data
        if logging == true {
            data.dump(prefix: "->")
        }
        host.send(data: &d)
    }
    
    @_documentation(visibility: private)
    internal func transactionCompleted(opCode: UInt8) {
    }
    
    @_documentation(visibility: private)
    internal func dataAvailable(host: DriveWireHost, data: Data) {
        if logging == true {
            data.dump(prefix: "<-")
        }
        serialPort?.send(data)
    }
    
    override init() {
        super.init()
        host = DriveWireHost(delegate: self)
        observePortArrivals()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func restoreConnectionIfNeeded() {
        connectIfPossible()
    }

    /// Connects to the selected port, waiting for it if it isn't present.
    public func connect() {
        connectIfPossible()
    }

    private static func serialPortPath(for selection: String) -> String? {
        guard !selection.isEmpty else {
            return nil
        }
        if selection.hasPrefix("/dev/") {
            return selection
        }
        return "/dev/cu." + selection
    }

    private func connectIfPossible() {
        stop()

        guard let normalizedPath = Self.serialPortPath(for: portName) else {
            return
        }

        wantsConnection = true
        openPort(at: normalizedPath)
    }

    private func openPort(at path: String) {
        guard let serialPort = ORSSerialPort(path: path) else {
            if !isWaitingForPort {
                note("Serial port \(path) not present, waiting for it to appear")
            }
            isWaitingForPort = true
            return
        }

        self.serialPort = serialPort
        serialPort.baudRate = NSNumber(value: baudRate)
        serialPort.delegate = self
        serialPort.open()
    }

    private func reopenIfWanted() {
        guard wantsConnection, serialPort == nil,
              let normalizedPath = Self.serialPortPath(for: portName) else {
            return
        }
        openPort(at: normalizedPath)
    }

    private func observePortArrivals() {
        // The manager only posts arrival notifications once it has been created
        _ = ORSSerialPortManager.shared()
        NotificationCenter.default.addObserver(self, selector: #selector(serialPortsWereConnected(_:)), name: Notification.Name.ORSSerialPortsWereConnected, object: nil)
    }

    @objc private func serialPortsWereConnected(_ notification: Notification) {
        guard wantsConnection, serialPort == nil,
              let normalizedPath = Self.serialPortPath(for: portName) else {
            return
        }

        let ports = notification.userInfo?[ORSConnectedSerialPortsKey] as? [ORSSerialPort] ?? []
        guard ports.contains(where: { $0.path == normalizedPath }) else {
            return
        }

        note("Serial port \(normalizedPath) returned, reconnecting")
        openPort(at: normalizedPath)
    }

    private func note(_ message: String) {
        log += message + "\n"
        print(message)
    }

    /// Closes the port without giving up on it, so it can be reopened when it returns.
    private func releasePort() {
        isConnected = false
        serialPort?.delegate = nil
        serialPort?.close()
        serialPort = nil
    }
    
    required init(from decoder: Decoder) throws {
        super.init()
        observePortArrivals()
        isRestoringState = true
        defer { isRestoringState = false }
        do {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.portName = try values.decode(String.self, forKey: .portName)
//            self.serialPort = ORSSerialPort(path: self.portName)
            self.baudRate = try values.decode(Int.self, forKey: .baudRate)
            self.log = try values.decode(String.self, forKey: .log)
            self.host = try values.decode(DriveWireHost.self, forKey: .host)
            self.host.delegate = self
        } catch {
            print("\(error)")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(portName, forKey:.portName)
        try container.encode(baudRate, forKey:.baudRate)
        try container.encode(log, forKey:.log)
        try container.encode(host, forKey:.host)
    }
    
    /// Closes the port and stops waiting for it to return.
    public func stop() {
        wantsConnection = false
        isWaitingForPort = false
        lastOpenError = nil
        releasePort()
    }
}
