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
    var port: String

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
        let d = DriveWireSerialDriver()

        d.baudRate = baudRate
        d.portName = port
        d.logging = verbose
        d.host.rfmRootPath = rfmRoot

        if let disk0Path = disk0 {
            try d.host.insertVirtualDisk(driveNumber: 0, imagePath: disk0Path)
        }
        
        if let disk1Path = disk1 {
            try d.host.insertVirtualDisk(driveNumber: 1, imagePath: disk1Path)
        }
        
        if let disk2Path = disk2 {
            try d.host.insertVirtualDisk(driveNumber: 2, imagePath: disk2Path)
        }
        
        if let disk3Path = disk3 {
            try d.host.insertVirtualDisk(driveNumber: 3, imagePath: disk3Path)
        }
        
        while true {
            RunLoop.current.run(mode: .default, before: Date.distantFuture)
        }
    }
}

DriveWireCmd.main()

