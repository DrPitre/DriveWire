//
//  DriveWireMIDIBackend.swift
//  DriveWire
//

import Foundation

struct DriveWireMIDIDevice: Equatable {
    let index: Int
    let name: String
    let isSelected: Bool
}

enum DriveWireMIDIError: Error, LocalizedError {
    case unavailable(String)
    case invalidDestination(Int)
    case sendFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        case .invalidDestination(let index):
            return "MIDI output device #\(index) is not available."
        case .sendFailed(let status):
            return "MIDI send failed with OSStatus \(status)."
        }
    }
}

protocol DriveWireMIDIBackend: AnyObject {
    var backendName: String { get }
    var isAvailable: Bool { get }
    var selectedOutputName: String? { get }

    func outputDevices() -> [DriveWireMIDIDevice]
    func selectOutput(index: Int) throws
    func send(_ bytes: [UInt8]) throws
    func reset() throws
    func statusLines() -> [String]
}

final class NullDriveWireMIDIBackend: DriveWireMIDIBackend {
    let backendName = "Unavailable"
    let isAvailable = false
    let selectedOutputName: String? = nil

    func outputDevices() -> [DriveWireMIDIDevice] {
        []
    }

    func selectOutput(index: Int) throws {
        throw DriveWireMIDIError.unavailable("MIDI is not available on this platform.")
    }

    func send(_ bytes: [UInt8]) throws {
        throw DriveWireMIDIError.unavailable("MIDI is not available on this platform.")
    }

    func reset() throws {
        throw DriveWireMIDIError.unavailable("MIDI is not available on this platform.")
    }

    func statusLines() -> [String] {
        [
            "Backend: \(backendName)",
            "Available: no",
            "Selected output: none"
        ]
    }
}

enum DriveWireMIDIBackendFactory {
    static func makeDefault() -> DriveWireMIDIBackend {
        #if canImport(CoreMIDI)
        if let backend = CoreMIDIDriveWireBackend() {
            return backend
        }
        #endif
        return NullDriveWireMIDIBackend()
    }
}

#if canImport(CoreMIDI)
import CoreMIDI

final class CoreMIDIDriveWireBackend: DriveWireMIDIBackend {
    let backendName = "Core MIDI"
    var isAvailable: Bool { true }

    private var client = MIDIClientRef()
    private var outputPort = MIDIPortRef()
    private var selectedDestinationIndex: Int?
    private var selectedDestination: MIDIEndpointRef?

    var selectedOutputName: String? {
        guard let selectedDestination else { return nil }
        return name(for: selectedDestination)
    }

    init?() {
        let clientStatus = MIDIClientCreateWithBlock("DriveWire MIDI" as CFString, &client) { _ in }
        guard clientStatus == noErr else { return nil }

        let portStatus = MIDIOutputPortCreate(client, "DriveWire MIDI Output" as CFString, &outputPort)
        guard portStatus == noErr else {
            MIDIClientDispose(client)
            return nil
        }

        if MIDIGetNumberOfDestinations() > 0 {
            selectedDestinationIndex = 0
            selectedDestination = MIDIGetDestination(0)
        }
    }

    deinit {
        if outputPort != 0 {
            MIDIPortDispose(outputPort)
        }
        if client != 0 {
            MIDIClientDispose(client)
        }
    }

    func outputDevices() -> [DriveWireMIDIDevice] {
        let count = MIDIGetNumberOfDestinations()
        guard count > 0 else { return [] }

        return (0..<count).map { index in
            let destination = MIDIGetDestination(index)
            return DriveWireMIDIDevice(
                index: index,
                name: name(for: destination),
                isSelected: index == selectedDestinationIndex
            )
        }
    }

    func selectOutput(index: Int) throws {
        guard index >= 0 && index < MIDIGetNumberOfDestinations() else {
            throw DriveWireMIDIError.invalidDestination(index)
        }
        selectedDestinationIndex = index
        selectedDestination = MIDIGetDestination(index)
    }

    func send(_ bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        guard let selectedDestination else {
            throw DriveWireMIDIError.unavailable("No MIDI output device is selected.")
        }

        var offset = 0
        while offset < bytes.count {
            let chunkEnd = min(offset + 256, bytes.count)
            let chunk = Array(bytes[offset..<chunkEnd])
            try sendPacket(chunk, to: selectedDestination)
            offset = chunkEnd
        }
    }

    func reset() throws {
        for channel in UInt8(0)..<UInt8(16) {
            try send([0xB0 | channel, 0x7B, 0x00])
            try send([0xB0 | channel, 0x78, 0x00])
        }
    }

    func statusLines() -> [String] {
        [
            "Backend: \(backendName)",
            "Available: yes",
            "Output devices: \(outputDevices().count)",
            "Selected output: \(selectedOutputName ?? "none")"
        ]
    }

    private func sendPacket(_ bytes: [UInt8], to destination: MIDIEndpointRef) throws {
        let packetListSize = MemoryLayout<MIDIPacketList>.size + bytes.count
        let rawPacketList = UnsafeMutableRawPointer.allocate(
            byteCount: packetListSize,
            alignment: MemoryLayout<MIDIPacketList>.alignment
        )
        defer { rawPacketList.deallocate() }

        let packetList = rawPacketList.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var packet = MIDIPacketListInit(packetList)
        let addedPacket = bytes.withUnsafeBufferPointer { buffer -> UnsafeMutablePointer<MIDIPacket>? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return MIDIPacketListAdd(packetList, packetListSize, packet, 0, bytes.count, baseAddress)
        }
        guard addedPacket != nil else {
            throw DriveWireMIDIError.sendFailed(-1)
        }

        let status = MIDISend(outputPort, destination, packetList)
        guard status == noErr else {
            throw DriveWireMIDIError.sendFailed(status)
        }
    }

    private func name(for endpoint: MIDIEndpointRef) -> String {
        var unmanagedName: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &unmanagedName) == noErr,
           let name = unmanagedName?.takeRetainedValue() as String? {
            return name
        }

        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &unmanagedName) == noErr,
           let name = unmanagedName?.takeRetainedValue() as String? {
            return name
        }

        return "MIDI Destination \(endpoint)"
    }
}
#endif
