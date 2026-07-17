//
//  DriveWireTCPServerDriver.swift
//  DriveWireSwift
//

import Foundation
import Network

/// Provides a TCP listener for Becker-port DriveWire guests such as XRoar.
final class DriveWireTCPServerDriver: DriveWireDelegate {
    let host = DriveWireHost()

    private let port: UInt16
    private let queue = DispatchQueue(label: "DriveWireTCPServer")
    private var listener: NWListener?
    private var connection: NWConnection?

    var logging = false

    init(port: UInt16) {
        self.port = port
        host.delegate = self
    }

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw CocoaError(.featureUnsupported)
        }

        let listener = try NWListener(using: .tcp, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("DriveWire TCP server listening on port \(self.port)")
            case .failed(let error):
                print("DriveWire TCP server failed: \(error)")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
    }

    private func accept(_ newConnection: NWConnection) {
        connection?.cancel()
        connection = newConnection
        print("DriveWire guest connected")

        newConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.connection = nil
                self?.host.resetRFMState()
                print("DriveWire guest disconnected")
            default:
                break
            }
        }
        receiveNext(from: newConnection)
        newConnection.start(queue: queue)
    }

    private func receiveNext(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }

            if let data, !data.isEmpty {
                if self.logging {
                    data.dump(prefix: "->")
                }
                var buffer = data
                self.host.send(data: &buffer)
            }

            if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receiveNext(from: connection)
            }
        }
    }

    func dataAvailable(host: DriveWireHost, data: Data) {
        if logging {
            data.dump(prefix: "<-")
        }
        connection?.send(content: data, completion: .contentProcessed { error in
            if let error {
                print("DriveWire TCP send failed: \(error)")
            }
        })
    }

    func transactionCompleted(opCode: UInt8) {
    }
}
