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

    @Option(name: .shortAndLong, help: "Baud rate for the serial port")
    var baudRate: Int = 57600

    @Option(name: .long, help: "Listen for a TCP guest (e.g. XRoar's becker port) on this port")
    var beckerPort: UInt16?

    @Option(name: .long, help: "Virtual serial channel N is bridged on TCP port base+N")
    var channelPortBase: UInt16 = 6810

    @Option(name: .long, help: "Number of virtual serial channels to bridge over TCP")
    var channels: Int = 4

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

    func validate() throws {
        guard (port == nil) != (beckerPort == nil) else {
            throw ValidationError("Specify exactly one of --port (serial) or --becker-port (TCP listen).")
        }
    }

    func run() throws {
        let host: DriveWireHost
        var keepAlive: [AnyObject] = []

        if let port = port {
            let d = DriveWireSerialDriver()
            d.baudRate = baudRate
            d.portName = port
            d.logging = verbose
            host = d.host
            keepAlive.append(d)
        } else {
            let d = DriveWireTCPServerDriver(beckerPort: beckerPort!,
                                             channelPortBase: channelPortBase,
                                             bridgedChannelCount: channels)
            d.logging = verbose
            try d.start()
            host = d.host
            keepAlive.append(d)
            print("DriveWire listening: becker :\(beckerPort!), channels 0..<\(channels) on :\(channelPortBase)+N")
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

        withExtendedLifetime(keepAlive) {
            while true {
                RunLoop.current.run(mode: .default, before: Date.distantFuture)
            }
        }
    }
}

DriveWireCmd.main()
