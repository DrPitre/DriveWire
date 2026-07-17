//
//  DriveWireHost+MIDI.swift
//  DriveWireSwift
//

import Foundation

public struct DriveWireMIDIStatus: Equatable {
    public var state: String = "Idle"
    public var backendName: String = "Unavailable"
    public var selectedOutputName: String = "None"
    public var isAvailable: Bool = false
    public var bytesReceived: Int = 0
    public var fileBytesReceived: Int = 0
    public var expectedFileBytes: Int?
    public var completedFileTracks: Int = 0
    public var expectedFileTracks: Int?
    public var messagesSent: Int = 0
    public var lastError: String?
    public var statusLines: [String] = []
}

private struct ScheduledMIDIFileEvent {
    let seconds: TimeInterval
    let order: Int
    let bytes: [UInt8]
}

final class StandardMIDIFileStreamPlayback {
    private var data = Data()
    private var scheduledEventCount = 0
    private var isComplete = false
    private var expectedByteCount: Int?
    private var completedTrackCount = 0
    private var expectedTrackCount: Int?
    private let queue = DispatchQueue(label: "DriveWire.StandardMIDIFilePlayback")
    private var workItems: [DispatchWorkItem] = []
    private var startTime: DispatchTime?
    private let queueKey = DispatchSpecificKey<Void>()
    private let sendMessage: ([UInt8]) throws -> Void
    private let resetOutput: () throws -> Void
    private let report: (String, Bool) -> Void

    init(sendMessage: @escaping ([UInt8]) throws -> Void, resetOutput: @escaping () throws -> Void, report: @escaping (String, Bool) -> Void) {
        self.sendMessage = sendMessage
        self.resetOutput = resetOutput
        self.report = report
        queue.setSpecific(key: queueKey, value: ())
    }

    var receivedByteCount: Int {
        syncOnQueue { data.count }
    }

    var expectedFileByteCount: Int? {
        syncOnQueue { expectedByteCount }
    }

    var completedFileTrackCount: Int {
        syncOnQueue { completedTrackCount }
    }

    var expectedFileTrackCount: Int? {
        syncOnQueue { expectedTrackCount }
    }

    func append(_ chunk: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            data.append(chunk)
            scheduleAvailableEvents()
        }
    }

    func finishStream() -> Bool {
        var failureMessage: String?
        let completed = syncOnQueue {
            scheduleAvailableEvents()
            if let expectedByteCount, data.count >= expectedByteCount {
                isComplete = true
            }
            if let expectedTrackCount, expectedTrackCount > 0, completedTrackCount >= expectedTrackCount {
                isComplete = true
            }

            if isComplete {
                return true
            }

            stopOnQueue(shouldResetOutput: true)
            if let expectedByteCount {
                failureMessage = "MIDI file stream ended before the file was complete (\(data.count)/\(expectedByteCount) bytes); playback stopped"
            } else if let expectedTrackCount {
                failureMessage = "MIDI file stream ended before all tracks were complete (\(completedTrackCount)/\(expectedTrackCount) tracks); playback stopped"
            } else {
                failureMessage = "MIDI file stream ended before the file size was known; playback stopped"
            }
            return false
        }
        if let failureMessage {
            report(failureMessage, true)
        }
        return completed
    }

    func stop(shouldResetOutput: Bool) {
        syncOnQueue {
            stopOnQueue(shouldResetOutput: shouldResetOutput)
        }
    }

    private func syncOnQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return body()
        }
        return queue.sync(execute: body)
    }

    private func stopOnQueue(shouldResetOutput: Bool) {
        for item in workItems {
            item.cancel()
        }
        workItems.removeAll()
        scheduledEventCount = 0
        startTime = nil
        if shouldResetOutput {
            try? resetOutput()
        }
    }

    private func scheduleAvailableEvents() {
        guard let parsed = try? Self.parse(data) else {
            return
        }

        isComplete = parsed.isComplete
        expectedByteCount = parsed.expectedByteCount
        completedTrackCount = parsed.completedTrackCount
        expectedTrackCount = parsed.expectedTrackCount
        let events = parsed.events
        guard scheduledEventCount < events.count else {
            return
        }

        if startTime == nil {
            startTime = .now()
            report("MIDI file playback started", false)
        }

        let baseTime = startTime ?? .now()
        for event in events.dropFirst(scheduledEventCount) {
            let item = DispatchWorkItem { [sendMessage] in
                try? sendMessage(event.bytes)
            }
            workItems.append(item)
            let nanoseconds = max(0, Int(event.seconds * 1_000_000_000))
            queue.asyncAfter(deadline: baseTime + .nanoseconds(nanoseconds), execute: item)
        }
        scheduledEventCount = events.count
    }

    private static func parse(_ data: Data) throws -> (events: [ScheduledMIDIFileEvent], isComplete: Bool, expectedByteCount: Int?, completedTrackCount: Int, expectedTrackCount: Int?) {
        let bytes = [UInt8](data)
        guard bytes.count >= 14,
              String(bytes: bytes[0..<4], encoding: .ascii) == "MThd" else {
            return ([], false, nil, 0, nil)
        }

        let headerLength = Int(readUInt32(bytes, at: 4))
        guard headerLength >= 6, bytes.count >= 8 + headerLength else {
            return ([], false, nil, 0, nil)
        }

        let trackCount = Int(readUInt16(bytes, at: 10))
        let division = Int(readUInt16(bytes, at: 12))
        guard trackCount > 0, division > 0, division & 0x8000 == 0 else {
            throw DriveWireMIDIError.unavailable("Unsupported MIDI file timing format.")
        }

        let expectedByteCount = expectedFileByteCount(bytes: bytes, headerLength: headerLength, trackCount: trackCount)
        let isComplete = expectedByteCount.map { bytes.count >= $0 } ?? false
        var offset = 8 + headerLength
        var rawEvents: [(tick: Int, order: Int, bytes: [UInt8])] = []
        var tempoEvents: [(tick: Int, microsecondsPerQuarter: Int)] = [(0, 500_000)]
        var order = 0
        var completedTracks = 0

        for _ in 0..<trackCount {
            guard offset + 8 <= bytes.count else {
                break
            }
            guard String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) == "MTrk" else {
                throw DriveWireMIDIError.unavailable("Invalid MIDI track header.")
            }

            let trackLength = Int(readUInt32(bytes, at: offset + 4))
            offset += 8
            let trackEnd = offset + trackLength
            let availableEnd = min(trackEnd, bytes.count)
            let parsedTrack = parseTrack(Array(bytes[offset..<availableEnd]), order: &order)
            rawEvents.append(contentsOf: parsedTrack.events)
            tempoEvents.append(contentsOf: parsedTrack.tempoEvents)
            if parsedTrack.isComplete || availableEnd == trackEnd {
                completedTracks += 1
            }
            offset = trackEnd
            if offset > bytes.count {
                break
            }
        }

        let tempoMap = tempoEvents.sorted { lhs, rhs in
            lhs.tick == rhs.tick ? lhs.microsecondsPerQuarter < rhs.microsecondsPerQuarter : lhs.tick < rhs.tick
        }
        let events = rawEvents
            .sorted { lhs, rhs in
                lhs.tick == rhs.tick ? lhs.order < rhs.order : lhs.tick < rhs.tick
            }
            .map {
                ScheduledMIDIFileEvent(
                    seconds: seconds(for: $0.tick, tempoMap: tempoMap, division: division),
                    order: $0.order,
                    bytes: $0.bytes
                )
            }

        let completedByTracks = completedTracks >= trackCount
        return (events, isComplete || completedByTracks, expectedByteCount, completedTracks, trackCount)
    }

    private static func expectedFileByteCount(bytes: [UInt8], headerLength: Int, trackCount: Int) -> Int? {
        var offset = 8 + headerLength
        for _ in 0..<trackCount {
            guard offset + 8 <= bytes.count else {
                return nil
            }
            guard String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) == "MTrk" else {
                return nil
            }
            let trackLength = Int(readUInt32(bytes, at: offset + 4))
            offset += 8 + trackLength
        }
        return offset
    }

    private static func parseTrack(_ bytes: [UInt8], order: inout Int) -> (events: [(tick: Int, order: Int, bytes: [UInt8])], tempoEvents: [(tick: Int, microsecondsPerQuarter: Int)], isComplete: Bool) {
        var position = 0
        var tick = 0
        var runningStatus: UInt8?
        var events: [(tick: Int, order: Int, bytes: [UInt8])] = []
        var tempoEvents: [(tick: Int, microsecondsPerQuarter: Int)] = []
        var isComplete = false

        while position < bytes.count {
            guard let delta = readVariableLengthQuantity(bytes, position: &position) else { break }
            tick += delta
            guard position < bytes.count else { break }

            var status = bytes[position]
            var firstDataByte: UInt8?
            if status < 0x80 {
                guard let runningStatus else { break }
                firstDataByte = status
                status = runningStatus
            } else {
                position += 1
                if status < 0xF0 {
                    runningStatus = status
                }
            }

            if status >= 0x80 && status <= 0xEF {
                let dataByteCount = channelDataByteCount(for: status)
                var message = [status]
                if let firstDataByte {
                    message.append(firstDataByte)
                }
                let remaining = dataByteCount - (message.count - 1)
                guard remaining >= 0, position + remaining <= bytes.count else { break }
                if remaining > 0 {
                    message.append(contentsOf: bytes[position..<(position + remaining)])
                    position += remaining
                }
                events.append((tick, order, message))
                order += 1
            } else if status == 0xFF {
                guard position < bytes.count else { break }
                let type = bytes[position]
                position += 1
                guard let length = readVariableLengthQuantity(bytes, position: &position),
                      position + length <= bytes.count else { break }
                if type == 0x2F, length == 0 {
                    isComplete = true
                }
                if type == 0x51, length == 3 {
                    let tempo = (Int(bytes[position]) << 16) | (Int(bytes[position + 1]) << 8) | Int(bytes[position + 2])
                    tempoEvents.append((tick, tempo))
                }
                position += length
            } else if status == 0xF0 || status == 0xF7 {
                guard let length = readVariableLengthQuantity(bytes, position: &position),
                      position + length <= bytes.count else { break }
                position += length
            } else {
                let dataByteCount = systemDataByteCount(for: status)
                guard position + dataByteCount <= bytes.count else { break }
                position += dataByteCount
            }
        }

        return (events, tempoEvents, isComplete)
    }

    private static func seconds(for tick: Int, tempoMap: [(tick: Int, microsecondsPerQuarter: Int)], division: Int) -> TimeInterval {
        var seconds: TimeInterval = 0
        var lastTick = 0
        var tempo = 500_000

        for event in tempoMap where event.tick <= tick {
            guard event.tick >= lastTick else { continue }
            seconds += TimeInterval(event.tick - lastTick) * TimeInterval(tempo) / 1_000_000.0 / TimeInterval(division)
            tempo = event.microsecondsPerQuarter
            lastTick = event.tick
        }

        seconds += TimeInterval(tick - lastTick) * TimeInterval(tempo) / 1_000_000.0 / TimeInterval(division)
        return seconds
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16) | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    private static func readVariableLengthQuantity(_ bytes: [UInt8], position: inout Int) -> Int? {
        var value = 0
        var byteCount = 0
        while position < bytes.count && byteCount < 4 {
            let byte = bytes[position]
            position += 1
            byteCount += 1
            value = (value << 7) | Int(byte & 0x7F)
            if byte & 0x80 == 0 {
                return value
            }
        }
        return nil
    }

    private static func channelDataByteCount(for status: UInt8) -> Int {
        switch status & 0xF0 {
        case 0xC0, 0xD0:
            return 1
        default:
            return 2
        }
    }

    private static func systemDataByteCount(for status: UInt8) -> Int {
        switch status {
        case 0xF1, 0xF3:
            return 1
        case 0xF2:
            return 2
        default:
            return 0
        }
    }
}

extension DriveWireHost {
    func refreshMIDIStatus() {
        midiMonitorStatus = DriveWireMIDIStatus(
            state: midiState,
            backendName: midiBackend.backendName,
            selectedOutputName: midiBackend.selectedOutputName ?? "None",
            isAvailable: midiBackend.isAvailable,
            bytesReceived: midiBytesReceived,
            fileBytesReceived: midiFileBytesReceived,
            expectedFileBytes: standardMIDIPlayback?.expectedFileByteCount,
            completedFileTracks: standardMIDIPlayback?.completedFileTrackCount ?? 0,
            expectedFileTracks: standardMIDIPlayback?.expectedFileTrackCount,
            messagesSent: midiMessagesSent,
            lastError: lastMIDIErrorMessage,
            statusLines: midiBackend.statusLines()
        )
    }

    func handleMIDIData(_ data: Data) {
        midiBytesReceived += data.count
        midiBufferedData.append(data)

        if midiBufferedData.count >= Self.standardMIDIFileSignature.count,
           midiBufferedData.prefix(Self.standardMIDIFileSignature.count) == Self.standardMIDIFileSignature {
            midiStreamMode = .standardFile
            midiFileBytesReceived = midiBufferedData.count
            midiState = "Receiving MIDI File"
        } else {
            midiStreamMode = .raw
            midiState = "Receiving MIDI"
        }

        reportActivity("MIDI buffer <- \(data.count) byte\(data.count == 1 ? "" : "s")", isFrequent: true)
        refreshMIDIStatus()
    }

    func finishMIDIStream() {
        guard !midiBufferedData.isEmpty else {
            midiState = "Idle"
            resetMIDIStreamState()
            refreshMIDIStatus()
            return
        }

        if midiBufferedData.count >= Self.standardMIDIFileSignature.count,
           midiBufferedData.prefix(Self.standardMIDIFileSignature.count) == Self.standardMIDIFileSignature {
            midiStreamMode = .standardFile
            midiFileBytesReceived = midiBufferedData.count
            standardMIDIPlayback?.stop(shouldResetOutput: true)
            standardMIDIPlayback = makeStandardMIDIPlayback()
            standardMIDIPlayback?.append(midiBufferedData)
            let completed = standardMIDIPlayback?.finishStream() ?? false
            if !completed {
                midiState = "Stopped"
            } else {
                midiState = "Playing MIDI File"
            }
        } else {
            midiStreamMode = .raw
            midiState = "Raw MIDI"
            sendMIDI(midiBufferedData)
        }

        resetMIDIStreamState()
        refreshMIDIStatus()
    }

    private func sendMIDI(_ data: Data) {
        do {
            try midiBackend.send(Array(data))
            lastMIDIErrorMessage = nil
            midiMessagesSent += 1
            reportActivity("MIDI <- \(data.count) byte\(data.count == 1 ? "" : "s")", isFrequent: true)
        } catch {
            let message = error.localizedDescription
            if lastMIDIErrorMessage != message {
                reportActivity("MIDI send failed: \(message)", isError: true)
                lastMIDIErrorMessage = message
            }
        }
        refreshMIDIStatus()
    }

    private func makeStandardMIDIPlayback() -> StandardMIDIFileStreamPlayback {
        StandardMIDIFileStreamPlayback(
            sendMessage: { [weak self] bytes in
                guard let self else { return }
                try self.midiBackend.send(bytes)
                self.lastMIDIErrorMessage = nil
                self.midiMessagesSent += 1
                self.midiState = "Playing MIDI File"
                self.refreshMIDIStatus()
            },
            resetOutput: { [weak self] in
                try self?.midiBackend.reset()
            },
            report: { [weak self] message, isError in
                self?.reportActivity(message, isError: isError)
                if isError {
                    self?.lastMIDIErrorMessage = message
                }
                self?.refreshMIDIStatus()
            }
        )
    }

    public func stopMIDIPlayback() {
        standardMIDIPlayback?.stop(shouldResetOutput: true)
        standardMIDIPlayback = nil
        resetMIDIStreamState()
        do {
            try midiBackend.reset()
            lastMIDIErrorMessage = nil
            midiState = "Stopped"
            reportActivity("MIDI playback stopped")
        } catch {
            let message = error.localizedDescription
            lastMIDIErrorMessage = message
            midiState = "Error"
            reportActivity("MIDI stop failed: \(message)", isError: true)
        }
        refreshMIDIStatus()
    }

    func resetMIDIStreamState() {
        midiStreamMode = .undetermined
        midiBufferedData.removeAll()
    }

}
