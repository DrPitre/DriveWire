//
//  DriveWireSwiftDocument.swift
//  DriveWireSwift
//
//  Created by Boisy Pitre on 9/29/23.
//

import SwiftUI
import UniformTypeIdentifiers
import ORSSerial
import AppIntents

extension UTType {
    static var exampleText: UTType {
        UTType(importedAs: "com.boisypitre.drivewire-document")
    }
}

final class DriveWireDocument: FileDocument {
    struct DriveWireDocumentModel: Codable {
        var serialDriver: DriveWireSerialDriver
        var tcpDriver: DriveWireTCPDriver
        var connectionType: ConnectionType
        var detailedOpcodeLogging: Bool

        init(
            serialDriver: DriveWireSerialDriver,
            tcpDriver: DriveWireTCPDriver,
            connectionType: ConnectionType,
            detailedOpcodeLogging: Bool = false
        ) {
            self.serialDriver = serialDriver
            self.tcpDriver = tcpDriver
            self.connectionType = connectionType
            self.detailedOpcodeLogging = detailedOpcodeLogging
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            serialDriver = try container.decode(DriveWireSerialDriver.self, forKey: .serialDriver)
            tcpDriver = try container.decode(DriveWireTCPDriver.self, forKey: .tcpDriver)
            connectionType = try container.decode(ConnectionType.self, forKey: .connectionType)
            detailedOpcodeLogging = try container.decodeIfPresent(Bool.self, forKey: .detailedOpcodeLogging) ?? false
        }
    }
    
    @Published var serialDriver = DriveWireSerialDriver() {
        didSet {
            applyLoggingPreferences()
        }
    }
    @Published var tcpDriver = DriveWireTCPDriver() {
        didSet {
            applyLoggingPreferences()
        }
    }
    @Published var detailedOpcodeLogging = false {
        didSet {
            applyLoggingPreferences()
        }
    }
    
    enum ConnectionType: String, CaseIterable, Identifiable, Codable {
        case serial, network
        var id: String { rawValue }
    }
    
    @Published var connectionType: ConnectionType = .serial
    
    static var readableContentTypes: [UTType] { [.exampleText] }
    
    init(connectionType: ConnectionType = .serial) {
        self.connectionType = connectionType
        applyLoggingPreferences()
    }

    private func applyLoggingPreferences() {
        serialDriver.host.detailedOpcodeLogging = detailedOpcodeLogging
        tcpDriver.host.detailedOpcodeLogging = detailedOpcodeLogging
    }
    
    struct ReloadVirtualDriveIntent: AppIntent {
        static let title: LocalizedStringResource = "Reload virtual drives"
        static var description =
        IntentDescription("Instructs DriveWire to reload all virtual drives on all open documents.")
        @AppDependency private var hostProvider : DriveWireHost
        
        func perform() async throws -> some IntentResult {
            // reload
            
            hostProvider.reloadVirtualDrives()
            
            return .result()
        }
    }
    
#if false
    struct AppShortcuts: AppShortcutsProvider {
        @AppShortcutsBuilder
        static var appShortcuts: [AppShortcut] {
            AppShortcut(
                intent: ReloadVirtualDriveIntent(),
                phrases: ["Reload virtual drives"],
                shortTitle: LocalizedStringResource("Reload"),
                systemImageName: "externaldrive"
            )
        }
    }
#endif
    
    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let model = try JSONDecoder().decode(DriveWireDocumentModel.self, from: data)
        self.serialDriver = model.serialDriver
        self.tcpDriver = model.tcpDriver
        self.connectionType = model.connectionType
        self.detailedOpcodeLogging = model.detailedOpcodeLogging
        applyLoggingPreferences()
        if connectionType == .serial {
            serialDriver.restoreConnectionIfNeeded()
        }
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let model = DriveWireDocumentModel(
            serialDriver: self.serialDriver,
            tcpDriver: self.tcpDriver,
            connectionType: self.connectionType,
            detailedOpcodeLogging: self.detailedOpcodeLogging
        )
        
        let data = try JSONEncoder().encode(model)
        return .init(regularFileWithContents: data)
    }

    func persistCurrentState(to fileURL: URL?) {
        guard let fileURL else {
            return
        }

        let model = DriveWireDocumentModel(
            serialDriver: self.serialDriver,
            tcpDriver: self.tcpDriver,
            connectionType: self.connectionType,
            detailedOpcodeLogging: self.detailedOpcodeLogging
        )

        do {
            let data = try JSONEncoder().encode(model)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            serialDriver.log += "Failed to save document state: \(error.localizedDescription)\n"
        }
    }
}
