import Foundation
import Dispatch
import CDriveWireSerial

public enum SerialPorts {
    public static func available() throws -> [String] {
        var paths = [CChar](repeating: 0, count: 65536)
        var error = [CChar](repeating: 0, count: 512)
        guard dw_serial_ports(&paths, paths.count, &error, error.count) >= 0 else { throw SerialError(String(cString: error)) }
        return String(cString: paths).split(separator: "\n").map(String.init).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

public struct SerialError: LocalizedError {
    let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Main-queue API; blocking OS operations run on independent read/write workers.
/// A session owns its handle until both workers retire, including after unplug.
public final class SerialConnection: @unchecked Sendable {
    public var onReady: (() -> Void)?
    public var onReceive: ((Data) -> Void)?
    public var onClose: ((Error?) -> Void)?
    private let path: String
    private let baud: Int
    private let dtr: Bool
    private let rts: Bool
    private var started = false
    private var closed = false
    private var session: Session?

    public init(path: String, baud: Int = 57600, dtr: Bool = true, rts: Bool = true) {
        self.path = path; self.baud = baud; self.dtr = dtr; self.rts = rts
    }

    public func start() {
        guard !started, !closed else { return }
        started = true
        DispatchQueue.global().async {
            var error = [CChar](repeating: 0, count: 512)
            let pointer = self.path.withCString { dw_serial_open($0, Int32(self.baud), self.dtr ? 1 : 0, self.rts ? 1 : 0, &error, error.count) }
            let opened = pointer.map(Session.init)
            let failure = SerialError(String(cString: error))
            DispatchQueue.main.async {
                guard !self.closed else { opened?.cancel(); return }
                guard let opened else { self.finish(failure); return }
                self.session = opened
                opened.receive = { [weak self, weak opened] data in
                    guard let self, !self.closed, self.session === opened else { return }
                    self.onReceive?(data)
                }
                opened.failed = { [weak self, weak opened] error in
                    guard let self, !self.closed, self.session === opened else { return }
                    self.finish(error)
                }
                self.onReady?()
                opened.read()
            }
        }
    }

    public func send(_ data: Data) { session?.write(data) }
    public func cancel() { finish(nil) }
    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        session?.cancel(); session = nil
        onClose?(error)
    }

    private final class Session: @unchecked Sendable {
        let handle: OpaquePointer
        let lock = NSLock()
        let writer = DispatchQueue(label: "DriveWire.serial.write")
        private var cancelled = false
        private var queuedBytes = 0
        var receive: ((Data) -> Void)?
        var failed: ((Error) -> Void)?
        init(_ handle: OpaquePointer) { self.handle = handle }
        deinit { dw_serial_close(handle) }
        var stopped: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() {
            lock.lock(); cancelled = true; lock.unlock()
            dw_serial_cancel(handle)
        }
        func fail(_ message: String) {
            cancel()
            DispatchQueue.main.async { self.failed?(SerialError(message)) }
        }
        func read() {
            DispatchQueue.global().async {
                var buffer = [UInt8](repeating: 0, count: 4096)
                var error = [CChar](repeating: 0, count: 512)
                while !self.stopped {
                    let count = dw_serial_read(self.handle, &buffer, Int32(buffer.count), &error, error.count)
                    if self.stopped { break }
                    if count < 0 { self.fail(String(cString: error)); break }
                    if count > 0 {
                        let data = Data(buffer.prefix(Int(count)))
                        DispatchQueue.main.async { if !self.stopped { self.receive?(data) } }
                    }
                }
            }
        }
        func write(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            if cancelled { lock.unlock(); return }
            if queuedBytes + data.count > 1_048_576 { lock.unlock(); fail("Serial output buffer is full"); return }
            queuedBytes += data.count; lock.unlock()
            writer.async {
                defer { self.lock.lock(); self.queuedBytes -= data.count; self.lock.unlock() }
                var offset = 0
                var error = [CChar](repeating: 0, count: 512)
                while offset < data.count && !self.stopped {
                    let sent = data.withUnsafeBytes { bytes in
                        dw_serial_write(self.handle, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset), Int32(data.count - offset), &error, error.count)
                    }
                    if self.stopped { break }
                    if sent <= 0 { self.fail(sent == 0 ? "Serial write made no progress" : String(cString: error)); break }
                    offset += Int(sent)
                }
            }
        }
    }
}
