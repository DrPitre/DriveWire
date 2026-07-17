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
    func playStandardMIDIFile(_ data: Data) throws
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

    func playStandardMIDIFile(_ data: Data) throws {
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
        #if canImport(AVFAudio)
        if let backend = InternalSynthDriveWireMIDIBackend() {
            #if canImport(CoreMIDI)
            if let coreMIDIBackend = CoreMIDIDriveWireBackend() {
                return CompositeDriveWireMIDIBackend(internalSynth: backend, coreMIDI: coreMIDIBackend)
            }
            #endif
            return backend
        }
        #endif
        #if canImport(CoreMIDI)
        if let backend = CoreMIDIDriveWireBackend() {
            return backend
        }
        #endif
        return NullDriveWireMIDIBackend()
    }
}

private final class MIDIStreamParser {
    private var runningStatus: UInt8?
    private var pendingStatus: UInt8?
    private var pendingData: [UInt8] = []
    private var sysexData: [UInt8]?

    func append(_ bytes: [UInt8], emit: ([UInt8]) throws -> Void) throws {
        for byte in bytes {
            if var sysex = sysexData {
                sysex.append(byte)
                if byte == 0xF7 {
                    sysexData = nil
                    try emit(sysex)
                } else {
                    sysexData = sysex
                }
                continue
            }

            if byte >= 0x80 {
                if byte >= 0xF8 {
                    try emit([byte])
                    continue
                }

                if byte == 0xF0 {
                    sysexData = [byte]
                    pendingStatus = nil
                    pendingData.removeAll()
                    continue
                }

                pendingStatus = byte
                pendingData.removeAll()
                if byte < 0xF0 {
                    runningStatus = byte
                }

                if expectedDataCount(for: byte) == 0 {
                    pendingStatus = nil
                    try emit([byte])
                }
                continue
            }

            guard let status = pendingStatus ?? runningStatus else {
                continue
            }

            pendingData.append(byte)
            if pendingData.count >= expectedDataCount(for: status) {
                try emit([status] + pendingData)
                pendingData.removeAll()
                if status >= 0xF0 {
                    pendingStatus = nil
                } else {
                    pendingStatus = nil
                }
            }
        }
    }

    func reset() {
        runningStatus = nil
        pendingStatus = nil
        pendingData.removeAll()
        sysexData = nil
    }

    private func expectedDataCount(for status: UInt8) -> Int {
        switch status {
        case 0x80...0xBF, 0xE0...0xEF:
            return 2
        case 0xC0...0xDF:
            return 1
        case 0xF1, 0xF3:
            return 1
        case 0xF2:
            return 2
        default:
            return 0
        }
    }
}

#if canImport(AVFAudio)
import AVFAudio

final class InternalSynthDriveWireMIDIBackend: DriveWireMIDIBackend {
    let backendName = "Built-in Synth"
    var isAvailable: Bool { true }
    var selectedOutputName: String? { backendName }

    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    private let parser = MIDIStreamParser()
    private var midiPlayer: AVMIDIPlayer?

    init?() {
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)

        do {
            try loadDefaultSoundBank()
            try engine.start()
        } catch {
            return nil
        }
    }

    func outputDevices() -> [DriveWireMIDIDevice] {
        [
            DriveWireMIDIDevice(index: 0, name: backendName, isSelected: true)
        ]
    }

    func selectOutput(index: Int) throws {
        guard index == 0 else {
            throw DriveWireMIDIError.invalidDestination(index)
        }
    }

    func send(_ bytes: [UInt8]) throws {
        if !engine.isRunning {
            try engine.start()
        }

        try parser.append(bytes) { [sampler] message in
            guard let status = message.first else { return }
            switch message.count {
            case 1:
                if status == 0xF6 || status >= 0xF8 {
                    return
                }
            case 2:
                sampler.sendMIDIEvent(status, data1: message[1])
            case 3:
                sampler.sendMIDIEvent(status, data1: message[1], data2: message[2])
            default:
                if status == 0xF0 {
                    sampler.sendMIDISysExEvent(Data(message))
                }
            }
        }
    }

    func playStandardMIDIFile(_ data: Data) throws {
        midiPlayer?.stop()
        let player = try AVMIDIPlayer(data: data, soundBankURL: nil)
        player.prepareToPlay()
        midiPlayer = player
        player.play()
    }

    func reset() throws {
        midiPlayer?.stop()
        midiPlayer = nil
        parser.reset()
        for channel in UInt8(0)..<UInt8(16) {
            sampler.sendController(0x7B, withValue: 0, onChannel: channel)
            sampler.sendController(0x78, withValue: 0, onChannel: channel)
        }
    }

    func statusLines() -> [String] {
        [
            "Backend: \(backendName)",
            "Available: yes",
            "Selected output: \(selectedOutputName ?? "none")"
        ]
    }

    private func loadDefaultSoundBank() throws {
        let soundBankURL = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
        if FileManager.default.fileExists(atPath: soundBankURL.path) {
            try sampler.loadSoundBankInstrument(
                at: soundBankURL,
                program: 0,
                bankMSB: 0x79,
                bankLSB: 0
            )
        }
    }
}
#endif

#if canImport(AVFAudio) && canImport(CoreMIDI)
final class CompositeDriveWireMIDIBackend: DriveWireMIDIBackend {
    let backendName = "Built-in Synth + Core MIDI"
    var isAvailable: Bool { true }

    private let internalSynth: InternalSynthDriveWireMIDIBackend
    private let coreMIDI: CoreMIDIDriveWireBackend
    private var selectedDeviceIndex = 0

    var selectedOutputName: String? {
        selectedDeviceIndex == 0 ? internalSynth.selectedOutputName : coreMIDI.selectedOutputName
    }

    init(internalSynth: InternalSynthDriveWireMIDIBackend, coreMIDI: CoreMIDIDriveWireBackend) {
        self.internalSynth = internalSynth
        self.coreMIDI = coreMIDI
    }

    func outputDevices() -> [DriveWireMIDIDevice] {
        let builtIn = DriveWireMIDIDevice(index: 0, name: "Built-in Synth", isSelected: selectedDeviceIndex == 0)
        let external = coreMIDI.outputDevices().map {
            DriveWireMIDIDevice(
                index: $0.index + 1,
                name: $0.name,
                isSelected: selectedDeviceIndex == $0.index + 1
            )
        }
        return [builtIn] + external
    }

    func selectOutput(index: Int) throws {
        if index == 0 {
            selectedDeviceIndex = 0
            return
        }

        try coreMIDI.selectOutput(index: index - 1)
        selectedDeviceIndex = index
    }

    func send(_ bytes: [UInt8]) throws {
        if selectedDeviceIndex == 0 {
            try internalSynth.send(bytes)
        } else {
            try coreMIDI.send(bytes)
        }
    }

    func playStandardMIDIFile(_ data: Data) throws {
        try internalSynth.playStandardMIDIFile(data)
    }

    func reset() throws {
        if selectedDeviceIndex == 0 {
            try internalSynth.reset()
        } else {
            try coreMIDI.reset()
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
}
#endif

#if canImport(CoreMIDI)
import CoreMIDI

final class CoreMIDIDriveWireBackend: DriveWireMIDIBackend {
    let backendName = "Core MIDI"
    var isAvailable: Bool { true }

    private var client = MIDIClientRef()
    private var outputPort = MIDIPortRef()
    private var selectedDestinationIndex: Int?
    private var selectedDestination: MIDIEndpointRef?
    private let parser = MIDIStreamParser()

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

        try parser.append(bytes) { [weak self] message in
            try self?.sendPacket(message, to: selectedDestination)
        }
    }

    func playStandardMIDIFile(_ data: Data) throws {
        throw DriveWireMIDIError.unavailable("Standard MIDI File playback requires the built-in synth output.")
    }

    func reset() throws {
        parser.reset()
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
        let packet = MIDIPacketListInit(packetList)
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
