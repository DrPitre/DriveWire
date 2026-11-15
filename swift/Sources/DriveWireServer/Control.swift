import Foundation
import DriveWireCore
import DriveWireSerial

/// Local, versioned management protocol shared by desktop frontends and tests.
/// Call only on the main dispatch queue, just like the protocol engine.
public final class DriveWireControl {
    public let host = DriveWireHost()
    private var server: DriveWireServer?
    private var address = "127.0.0.1"
    private var port: UInt16 = 65504
    private var verbose = false
    private var transport = "tcp"
    private var serialPath = ""
    private var baud = 57600
    private var dtr = true
    private var rts = true
    public var shouldExit = false

    public init() {}

    private func fail(_ message: String) throws -> Never {
        throw NSError(domain: "DriveWire", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    public func handle(_ request: [String: Any]) -> [String: Any] {
        let id = request["id"] ?? NSNull()
        do {
            guard let command = request["command"] as? String else { try fail("Missing command") }
            switch command {
            case "status": break
            case "ports":
                return ["id": id, "ok": true, "protocol": 1, "ports": try SerialPorts.available(), "state": snapshot()]
            case "configure":
                guard server?.running != true else { try fail("Stop the server before changing connection settings") }
                let nextAddress = request["bind"] as? String ?? address
                let nextPort = (request["port"] as? NSNumber)?.intValue ?? Int(port)
                guard !nextAddress.isEmpty, (0...65535).contains(nextPort) else { try fail("Invalid listening address or port") }
                let root = request["root"] as? String ?? host.rfmRootPath
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
                    try fail("RFM root is not a directory: \(root)")
                }
                let nextTransport = request["transport"] as? String ?? transport
                let nextPath = request["serialPath"] as? String ?? serialPath
                let nextBaud = request["baud"] as? Int ?? baud
                guard ["tcp", "serial"].contains(nextTransport), (300...1_000_000).contains(nextBaud) else { try fail("Invalid transport or baud rate") }
                guard nextTransport != "serial" || !nextPath.isEmpty else { try fail("Select a serial port") }
                transport = nextTransport; serialPath = nextPath; baud = nextBaud
                dtr = request["dtr"] as? Bool ?? dtr; rts = request["rts"] as? Bool ?? rts
                address = nextAddress; port = UInt16(nextPort)
                verbose = request["verbose"] as? Bool ?? verbose
                host.rfmRootPath = URL(fileURLWithPath: root).standardized.path
            case "start":
                if server?.running != true {
                    let next = transport == "serial"
                        ? DriveWireServer(serialPort: serialPath, baud: baud, dtr: dtr, rts: rts, host: host)
                        : DriveWireServer(address: address, port: port, host: host)
                    next.logging = verbose
                    try next.start()
                    server = next
                }
            case "stop": server?.stop()
            case "disconnect": server?.disconnect()
            case "mount", "eject", "save":
                guard let number = request["drive"] as? Int, (0...3).contains(number) else { try fail("Drive must be 0 through 3") }
                let disk = host.virtualDrives.first { $0.driveNumber == number }
                if command == "save" {
                    guard let disk else { try fail("No disk in drive \(number)") }
                    try disk.save(to: request["path"] as? String)
                } else {
                    if request["saveBefore"] as? Bool == true, let disk, disk.isDirty { try disk.save() }
                    guard disk?.isDirty != true || request["discard"] as? Bool == true else {
                        try fail("Drive \(number) has unsaved changes; save it or explicitly discard them")
                    }
                    if command == "mount" {
                        guard let path = request["path"] as? String, !path.isEmpty else { try fail("Missing image path") }
                        try host.insertVirtualDisk(driveNumber: number, imagePath: path)
                    } else { host.ejectVirtualDisk(driveNumber: number) }
                }
            case "saveAll":
                for disk in host.virtualDrives where disk.isDirty { try disk.save() }
            case "windowInput":
                guard let channel = request["channel"] as? Int, (128...143).contains(channel),
                      let text = request["text"] as? String else { try fail("Invalid virtual window input") }
                host.sendVirtualWindowInput(text, channel: UInt8(channel))
            case "clearWindow":
                guard let channel = request["channel"] as? Int, (128...143).contains(channel) else { try fail("Invalid window") }
                host.clearVirtualWindow(channel: UInt8(channel))
            case "shutdown":
                if request["saveBefore"] as? Bool == true {
                    for disk in host.virtualDrives where disk.isDirty { try disk.save() }
                }
                guard !host.virtualDrives.contains(where: { $0.isDirty }) || request["discard"] as? Bool == true else {
                    try fail("There are unsaved disk changes")
                }
                server?.stop(); shouldExit = true
            default: try fail("Unknown command: \(command)")
            }
            return ["id": id, "ok": true, "protocol": 1, "state": snapshot()]
        } catch {
            return ["id": id, "ok": false, "protocol": 1, "error": error.localizedDescription, "state": snapshot()]
        }
    }

    private func snapshot() -> [String: Any] {
        let printer = host.printerStatus
        return [
            "running": server?.running == true, "connected": server?.connected == true,
            "bind": address, "port": server?.running == true && transport == "tcp" ? Int(server!.port) : Int(port),
            "transport": transport, "serialPath": serialPath, "baud": baud, "dtr": dtr, "rts": rts,
            "serialError": server?.serialError ?? "",
            "root": host.rfmRootPath, "verbose": verbose,
            "received": server?.bytesReceived ?? 0, "sent": server?.bytesSent ?? 0,
            "transactions": server?.transactions ?? 0,
            "disks": host.virtualDrives.map { ["drive": $0.driveNumber, "path": $0.imagePath, "dirty": $0.isDirty] as [String: Any] },
            "windows": host.virtualWindows.map { ["channel": Int($0.channel), "title": $0.title, "text": $0.text, "open": $0.isOpen] as [String: Any] },
            "channels": host.virtualSerialChannels.map { ["channel": $0.number, "open": $0.isOpen, "pending": $0.pendingBytes, "tcp": $0.isTCPBacked] as [String: Any] },
            "printer": ["state": printer.state, "bytes": printer.bytesReceived, "jobs": printer.flushedJobs, "text": printer.previewText, "error": printer.lastError ?? ""]
        ]
    }
}
