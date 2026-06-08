//
//  DriveWireSerialDriver.swift
//  DriveWireSwift
//
//  Created by Boisy Pitre on 9/29/23.
//

import ORSSerial

/// Provides a serial interface to a DriveWire host.
///
/// This class provides the ability to connect to a guest on a serial port. Provide the
/// device name of the serial port in ``init(serialPort:)``
/// When you're ready for the driver to stop, set ``quit`` to `true`.
@MainActor
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
    
    /// A flag that when set to `true`,  causes serial traffic to log.
    public var logging = true

    var onChange: (() -> Void)?
         
    private var serialPort : ORSSerialPort?
    
    /// The serial port associated with this driver.
    public var portName : String = "" {
        didSet {
            if let sp = serialPort {
                self.stop()
                sp.close()
            }
            
            if let serialPort = ORSSerialPort(path: "/dev/cu." + self.portName) {
                self.serialPort = serialPort
                self.serialPort?.baudRate = NSNumber(value: self.baudRate)
                serialPort.delegate = self
                serialPort.open()
            }

            onChange?()
        }
    }
    
    /// The serial port's speed.
    public var baudRate = 57600 {
        didSet {
            serialPort?.baudRate = NSNumber(value: baudRate)
            onChange?()
        }
    }
    
    /// The host object.
    internal var host : DriveWireHost = DriveWireHost()

    @_documentation(visibility: private)
    internal func serialPortWasRemovedFromSystem(_ serialPort: ORSSerialPort) {
    }
    
    @_documentation(visibility: private)
    internal func serialPortWasOpened(_ serialPort: ORSSerialPort) {
    }
    
    @_documentation(visibility: private)
    internal func serialPort(_ serialPort: ORSSerialPort, didEncounterError error: Error) {
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
        configureHost()
    }
    
    required init(from decoder: Decoder) throws {
        super.init()
        do {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.portName = try values.decode(String.self, forKey: .portName)
//            self.serialPort = ORSSerialPort(path: self.portName)
            self.baudRate = try values.decode(Int.self, forKey: .baudRate)
            self.log = try values.decode(String.self, forKey: .log)
            self.host = try values.decode(DriveWireHost.self, forKey: .host)
            configureHost()
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
        self.serialPort?.delegate = nil
        self.serialPort?.close()
        self.serialPort = nil
    }

    private func configureHost() {
        host.delegate = self
        host.onChange = { [weak self] in
            self?.onChange?()
        }
    }
}
