//
//  main.swift
//  DriveWireCmd
//
//  Created by Boisy Pitre on 10/8/23.
//

import Foundation
import ArgumentParser

struct DriveWireCmd: ParsableCommand {
    @Option(name: .shortAndLong, help: "Serial port path (e.g. /dev/cu.usbserial-FTVA079L)")
    var port: String?

    @Option(name: .long, help: "TCP port to listen on for incoming guest connections (e.g. MAME -bitb socket.127.0.0.1:<port>)")
    var tcpPort: UInt16?

    @Option(name: .shortAndLong, help: "Baud rate for the serial port")
    var baudRate: Int = 57600

    @Option(name: .long, help: "Virtual disk image path to insert into drive 0")
    var disk0: String?

    @Option(name: .long, help: "Virtual disk image path to insert into drive 1")
    var disk1: String?

    @Option(name: .long, help: "Virtual disk image path to insert into drive 2")
    var disk2: String?

    @Option(name: .long, help: "Virtual disk image path to insert into drive 3")
    var disk3: String?

    @Flag(name: .shortAndLong, help: "Show client activity")
    var verbose: Bool = false

    @Option(name: .long, help: "Root path for RFM file access (default: home directory)")
    var rfmRoot: String = NSHomeDirectory()

    func run() throws {
        guard port != nil || tcpPort != nil else {
            throw ValidationError("Provide either --port (serial) or --tcp-port (TCP server).")
        }

        func insertDisks(into host: DriveWireHost) throws {
            if let p = disk0 { try host.insertVirtualDisk(driveNumber: 0, imagePath: p) }
            if let p = disk1 { try host.insertVirtualDisk(driveNumber: 1, imagePath: p) }
            if let p = disk2 { try host.insertVirtualDisk(driveNumber: 2, imagePath: p) }
            if let p = disk3 { try host.insertVirtualDisk(driveNumber: 3, imagePath: p) }
        }

        if let listenPort = tcpPort {
            let d = DriveWireTCPServerDriver()
            d.logging = verbose
            d.host.rfmRootPath = rfmRoot
            try insertDisks(into: d.host)
            try d.start(port: listenPort)
        } else if let serialPort = port {
            let d = DriveWireSerialDriver()
            d.baudRate = baudRate
            d.portName = serialPort
            d.logging = verbose
            d.host.rfmRootPath = rfmRoot
            try insertDisks(into: d.host)
        }

        while true {
            RunLoop.current.run(mode: .default, before: Date.distantFuture)
        }
    }
}

DriveWireCmd.main()

