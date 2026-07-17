//
//  FileMonitor.swift
//  DriveWireSwift
//

import Foundation

protocol FileMonitorDelegate: AnyObject {
    func didReceive(changes: String)
}

class FileMonitor : Codable {
    enum CodingKeys: String, CodingKey {
        case url
    }

    let url: URL
    let fileHandle: FileHandle
    weak var delegate: FileMonitorDelegate?
    let source: DispatchSourceFileSystemObject

    public required init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try values.decode(URL.self, forKey: .url)
        self.fileHandle = try FileHandle(forReadingFrom: self.url)
        self.delegate = nil
        self.source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileHandle.fileDescriptor,
            eventMask: .extend,
            queue: DispatchQueue.main
        )

        source.setEventHandler {
            let event = self.source.data
            self.process(event: event)
        }

        source.setCancelHandler {
            try? self.fileHandle.close()
        }

        fileHandle.seekToEndOfFile()
        source.resume()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey:.url)
    }


    init(url: URL) throws {
        self.url = url
        self.fileHandle = try FileHandle(forReadingFrom: url)

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileHandle.fileDescriptor,
            eventMask: .delete,
            queue: DispatchQueue.main
        )

        source.setEventHandler {
            let event = self.source.data
            self.process(event: event)
        }

        source.setCancelHandler {
            try? self.fileHandle.close()
        }

        fileHandle.seekToEndOfFile()
        source.resume()
    }

    deinit {
        source.cancel()
    }

    func process(event: DispatchSource.FileSystemEvent) {
        guard event.contains(.delete) else {
            return
        }
        let newData = self.fileHandle.readDataToEndOfFile()
        let string = String(data: newData, encoding: .utf8)!
        self.delegate?.didReceive(changes: string)
    }
}
