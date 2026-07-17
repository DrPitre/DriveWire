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

    private var isRestoringState = false
    private var serialPort : ORSSerialPort?
    
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
        isConnected = false
    }
    
    @_documentation(visibility: private)
    internal func serialPortWasOpened(_ serialPort: ORSSerialPort) {
        isConnected = true
    }
    
    @_documentation(visibility: private)
    internal func serialPort(_ serialPort: ORSSerialPort, didEncounterError error: Error) {
        isConnected = false
        log += "Serial error: \(error.localizedDescription)\n"
        print(error)
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
    }

    func restoreConnectionIfNeeded() {
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

        guard let normalizedPath = Self.serialPortPath(for: portName),
              let serialPort = ORSSerialPort(path: normalizedPath) else {
            return
        }

        self.serialPort = serialPort
        serialPort.baudRate = NSNumber(value: baudRate)
        serialPort.delegate = self
        serialPort.open()
    }
    
    required init(from decoder: Decoder) throws {
        super.init()
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
    
    public func stop() {
        isConnected = false
        self.serialPort?.delegate = nil
        self.serialPort?.close()
        self.serialPort = nil
    }
}
