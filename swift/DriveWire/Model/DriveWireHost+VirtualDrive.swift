//
//  DriveWireHost+VirtualDrive.swift
//  DriveWireSwift
//

import Foundation

extension DriveWireHost {
    /// A representation of a storage device.
    public class VirtualDrive : Codable {
        enum CodingKeys: String, CodingKey {
            case driveNumber
            case imagePath
            case bookmarkData
        }

        func didReceive(changes: String) {
            reload()
        }

        /// The drive number for this drive.
        var driveNumber = 0

        /// A path to a file that contains the drive's data.
        var imagePath = ""

        private var bookmarkData = Data()
        private var storageContainer = Data()
        private var isStorageLoaded = false

        /// Creates an empty in-memory virtual drive.
        ///
        /// - Parameters:
        ///     - driveNumber: The number to assign to this virtual drive.
        init(driveNumber: Int) {
            self.driveNumber = driveNumber
            self.imagePath = ""
            self.storageContainer = Data()
            self.isStorageLoaded = true
        }

        /// Creates a new virtual drive.
        ///
        /// - Parameters:
        ///     - driveNumber: The number to assign to this virtual drive.
        ///     - imagePath: A path to a file that contains the drive's data.
        init(driveNumber : Int, imagePath : String) throws {
            self.driveNumber = driveNumber
            self.imagePath = imagePath

            reload()
        }

        public func reload() {
            do {
                let u = URL(fileURLWithPath: self.imagePath)
                self.storageContainer = try Data(contentsOf: u)
                self.isStorageLoaded = true
            } catch {
                self.storageContainer = Data()
                self.isStorageLoaded = false
                print(error)
            }
        }

        private func ensureStorageLoaded() {
            guard !isStorageLoaded, !imagePath.isEmpty else {
                return
            }
            reload()
        }

        /// Reads a 256 byte sector from a virtual disk.
        ///
        /// Call this method to obtain the contents of a 256-byte sector in the virtual disk. If you pass a logical sector number that
        /// is greater than what the virtual disk contains, the function returns a 256-byte sector filled with zeros.
        ///
        /// - Parameters:
        ///     - lsn: The logical sector number to read.
        public func readSector(lsn : Int) -> (Int, Data) {
            ensureStorageLoaded()

            // Seek to the offset in the file represented by the URL.
            let offsetStart = lsn * 256
            let offsetEnd = offsetStart + 256
            if storageContainer.count >= offsetEnd {
                let range: Range<Data.Index> = offsetStart..<offsetEnd
                let sector = storageContainer[range]
                // Send a 256 byte sector of zeros with no error
                return(DriveWireProtocolError.E_NONE.rawValue, sector)
            } else {
                // LSN is past point of capacity of source.
                // Send a 256 byte sector of zeros with no error
                return(DriveWireProtocolError.E_NONE.rawValue, Data(repeating: 0, count: 256))
            }
        }

        /// Writes a 256 byte sector to a virtual disk.
        ///
        /// Call this method to modify a 256-byte sector in the virtual disk. If you pass a logical sector number that
        /// is greater than what the virtual disk contains, it increases to accomodate the new sector.
        ///
        /// - Parameters:
        ///     - lsn: The logical sector number to write.
        ///     - sector: The 256-byte sector to write.
        public func writeSector(lsn : Int, sector : Data) -> Int {
            ensureStorageLoaded()

            // Seek to the offset in the file represented by the URL.
            let offsetStart = lsn * 256
            let offsetEnd = offsetStart + 256
            let range: Range<Data.Index> = offsetStart..<offsetEnd
            if storageContainer.count >= offsetEnd {
                storageContainer[range] = sector
            } else {
                // LSN is past point of capacity of source.
                storageContainer.append(Data(repeating: 0xFF, count: offsetEnd - storageContainer.count))
                storageContainer[range] = sector
            }

            isStorageLoaded = true
            return DriveWireProtocolError.E_NONE.rawValue
        }

        public func save(to path: String? = nil) throws {
            ensureStorageLoaded()
            let destination = path ?? imagePath
            guard !destination.isEmpty else {
                throw CocoaError(.fileNoSuchFile)
            }
            try storageContainer.write(to: URL(fileURLWithPath: destination), options: .atomic)
            if let path {
                imagePath = path
            }
        }

        public required init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.driveNumber = try values.decode(Int.self, forKey: .driveNumber)
            self.imagePath = try values.decode(String.self, forKey: .imagePath)
            self.bookmarkData = try values.decodeIfPresent(Data.self, forKey: .bookmarkData) ?? Data()
            self.storageContainer = Data()
            self.isStorageLoaded = false
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(driveNumber, forKey: .driveNumber)
            try container.encode(imagePath, forKey: .imagePath)
            try container.encode(bookmarkData, forKey: .bookmarkData)
        }
    }
}
