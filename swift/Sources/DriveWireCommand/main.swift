import Foundation
import Dispatch
import ArgumentParser
import DriveWireServer

struct DriveWireCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "drivewire-server",
        abstract: "Portable DriveWire TCP server for Windows, macOS and Linux.")

    @Option(help: "TCP listening address.") var bind = "127.0.0.1"
    @Option(help: "TCP listening port (Becker port defaults to 65504).") var tcpPort: UInt16 = 65504
    @Option(help: "Host directory containing OS9Boot and device folders such as DD.") var rfmRoot: String?
    @Option(help: "Virtual disk image for drive 0.") var disk0: String?
    @Option(help: "Virtual disk image for drive 1.") var disk1: String?
    @Option(help: "Virtual disk image for drive 2.") var disk2: String?
    @Option(help: "Virtual disk image for drive 3.") var disk3: String?
    @Flag(help: "Use the private desktop JSON control protocol on stdin/stdout.") var managed = false
    @Flag(name: .shortAndLong, help: "Log wire traffic.") var verbose = false

    func run() throws {
        if managed { runManaged() }
        let server = DriveWireServer(address: bind, port: tcpPort)
        server.logging = verbose
        if let rfmRoot {
            let root = URL(fileURLWithPath: rfmRoot).standardized.path
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ValidationError("RFM root is not a directory: \(rfmRoot)")
            }
            server.host.rfmRootPath = root
        }
        for (number, image) in [disk0, disk1, disk2, disk3].enumerated() {
            if let image { try server.host.insertVirtualDisk(driveNumber: number, imagePath: image) }
        }
        try server.start()
        print("DriveWire TCP server listening on \(bind):\(server.port)")
        // libdispatch's main queue is the protocol executor on all platforms;
        // this does not depend on an AppKit or Foundation GUI event loop.
        withExtendedLifetime(server) { dispatchMain() }
    }
}

DriveWireCommand.main()
