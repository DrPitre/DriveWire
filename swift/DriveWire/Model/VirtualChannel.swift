//
//  VirtualChannel.swift
//  DriveWire
//

import Foundation

/// A virtual serial channel between the guest and the host.
///
/// Channels carry byte streams between guest-side devices (`/N1`...) and a
/// host-side consumer such as a TCP bridge. The guest opens and closes
/// channels with OP_SERINIT/OP_SERTERM or OP_SERSETSTAT SS.Open/SS.Close.
public class VirtualChannel {
    /// The channel number (0-14).
    public let channelNumber: UInt8

    /// Whether the guest currently has this channel open.
    public private(set) var isOpen = false

    /// Bytes waiting for the guest to collect via OP_SERREAD/OP_SERREADM.
    var inputQueue = Data()

    init(channelNumber: UInt8) {
        self.channelNumber = channelNumber
    }

    /// Marks the channel open and discards any stale queued input.
    func open() {
        isOpen = true
        inputQueue.removeAll()
    }

    /// Marks the channel closed and discards any queued input.
    func close() {
        isOpen = false
        inputQueue.removeAll()
    }
}
