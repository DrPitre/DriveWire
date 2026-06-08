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
    static var drivewireDocument: UTType {
        UTType(importedAs: "org.pitre.drivewire-document")
    }
}

@MainActor
final class DriveWireDocument: ReferenceFileDocument, ObservableObject {
    struct DriveWireDocumentModel: Codable {
        var serialDriver: DriveWireSerialDriver
        var tcpDriver: DriveWireTCPDriver
        var connectionType: ConnectionType
    }

    typealias Snapshot = DriveWireDocumentModel
    
    @Published var serialDriver = DriveWireSerialDriver()
    @Published var tcpDriver = DriveWireTCPDriver()
    
    enum ConnectionType: String, CaseIterable, Identifiable, Codable {
        case serial, network
        var id: String { rawValue }
    }
    
    @Published var connectionType: ConnectionType = .serial
    
    static var readableContentTypes: [UTType] { [.drivewireDocument] }
    
    init() {
        configureChangeTracking()
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
        configureChangeTracking()
    }

    func snapshot(contentType: UTType) throws -> DriveWireDocumentModel {
        DriveWireDocumentModel(
            serialDriver: self.serialDriver,
            tcpDriver: self.tcpDriver,
            connectionType: self.connectionType
        )
    }

    func fileWrapper(snapshot: DriveWireDocumentModel, configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try JSONEncoder().encode(snapshot)
        return .init(regularFileWithContents: data)
    }

    private func configureChangeTracking() {
        serialDriver.onChange = { [weak self] in
            self?.objectWillChange.send()
        }
        tcpDriver.onChange = { [weak self] in
            self?.objectWillChange.send()
        }
    }
}
