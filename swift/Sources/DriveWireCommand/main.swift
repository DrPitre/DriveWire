import Foundation
import Dispatch
import ArgumentParser
import DriveWireServer
import DriveWireSerial

struct DriveWireCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "drivewire-server",
        abstract: "Portable DriveWire TCP/serial server for Windows, macOS and Linux.")

    @Option(help: "Physical serial port, e.g. COM3 or /dev/cu.usbserial. Selects serial instead of TCP.") var serialPort: String?
    @Option(help: "Serial baud rate (8N1, no software or hardware flow control).") var baud: Int = 57600
    @Flag(help: "Leave DTR deasserted.") var noDtr = false
    @Flag(help: "Leave RTS deasserted.") var noRts = false
    @Flag(help: "List available physical serial ports and exit.") var listPorts = false
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
        if listPorts { for path in try SerialPorts.available() { print(path) }; return }
        if let serialPort, serialPort.isEmpty { throw ValidationError("Select a serial port") }
        guard (300...1_000_000).contains(baud) else { throw ValidationError("Invalid baud rate") }
        let server = serialPort.map { DriveWireServer(serialPort: $0, baud: baud, dtr: !noDtr, rts: !noRts) }
            ?? DriveWireServer(address: bind, port: tcpPort)
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
        if let serialPort {
            var lastState = ""
            server.onConnectionChange = { [weak server] connected in
                guard let server else { return }
                let state = connected ? "Serial port opened: \(serialPort)" : "Waiting for \(serialPort): \(server.serialError ?? "disconnected")"
                if state != lastState { print(state); lastState = state }
            }
        }
        try server.start()
        if let serialPort { print("DriveWire serial server: \(serialPort) at \(baud) baud (waiting/reconnecting as needed)") }
        else { print("DriveWire TCP server listening on \(bind):\(server.port)") }
        // libdispatch's main queue is the protocol executor on all platforms;
        // this does not depend on an AppKit or Foundation GUI event loop.
        withExtendedLifetime(server) { dispatchMain() }
    }
}

DriveWireCommand.main()
