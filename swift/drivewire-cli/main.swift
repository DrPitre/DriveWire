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

    @Option(name: .long, help: "TCP port to listen on for Becker/XRoar connections")
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

    @Option(name: .long, help: "Host root path for RFM file access")
    var rfmRoot: String?

    @Flag(name: .shortAndLong, help: "Show client activity")
    var verbose: Bool = false

    func run() throws {
        if let tcpPort {
            let driver = DriveWireTCPServerDriver(port: tcpPort)
            driver.logging = verbose
            try configure(host: driver.host)
            try driver.start()
            RunLoop.current.run()
            return
        }

        guard let port else {
            throw ValidationError("Either --port or --tcp-port is required")
        }

        let driver = DriveWireSerialDriver()
        driver.baudRate = baudRate
        driver.portName = port
        driver.logging = verbose
        try configure(host: driver.host)

        RunLoop.current.run()
    }

    private func configure(host: DriveWireHost) throws {
        if let rfmRoot {
            host.rfmRootPath = rfmRoot
        }

        if let disk0Path = disk0 {
            try host.insertVirtualDisk(driveNumber: 0, imagePath: disk0Path)
        }

        if let disk1Path = disk1 {
            try host.insertVirtualDisk(driveNumber: 1, imagePath: disk1Path)
        }

        if let disk2Path = disk2 {
            try host.insertVirtualDisk(driveNumber: 2, imagePath: disk2Path)
        }

        if let disk3Path = disk3 {
            try host.insertVirtualDisk(driveNumber: 3, imagePath: disk3Path)
        }
    }
}

DriveWireCmd.main()
