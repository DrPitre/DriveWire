import Foundation
import Dispatch
import DriveWireServer

/// Private parent/child pipes, not a network control port. EOF stops the child.
func runManaged() -> Never {
    let control = DriveWireControl()
    func output(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        // A leading newline keeps legacy protocol diagnostic prints separate.
        FileHandle.standardOutput.write(Data(("\n@drivewire " + json + "\n").utf8))
    }
    output(control.handle(["command": "status", "id": 0]))
    DispatchQueue.global().async {
        var pending = Data()
        while true {
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty {
                DispatchQueue.main.async {
                    // Preserve guest writes if the parent unexpectedly disappears.
                    let result = control.handle(["command": "saveAll"])
                    if result["ok"] as? Bool != true { output(result) }
                    _ = control.handle(["command": "shutdown", "discard": true])
                    exit(result["ok"] as? Bool == true ? 0 : 1)
                }
                return
            }
            pending.append(chunk)
            // Bound malformed input without allowing an unbounded parent buffer.
            if pending.count > 1_048_576 { exit(2) }
            while let newline = pending.firstIndex(of: 10) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                DispatchQueue.main.async {
                    let result = control.handle(request ?? [:])
                    output(result)
                    if control.shouldExit { exit(0) }
                }
            }
        }
    }
    dispatchMain()
}
