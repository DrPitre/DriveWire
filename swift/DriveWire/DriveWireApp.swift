//
//  DriveWireSwiftApp.swift
//  DriveWireSwift
//
//  Created by Boisy Pitre on 9/29/23.
//

import SwiftUI
import AppIntents

private enum DriveWireWindowID {
    static let newDocumentChooser = "new-document-chooser"
}

private struct NewDocumentChooserView: View {
    @Environment(\.newDocument) private var newDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("New DriveWire Document")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Choose the transport before opening the main document window.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                transportButton(
                    title: "Serial",
                    detail: "Create a document bound to a physical serial link.",
                    connectionType: .serial
                )

                transportButton(
                    title: "Network",
                    detail: "Create a document bound to a TCP endpoint.",
                    connectionType: .network
                )
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func transportButton(title: String, detail: String, connectionType: DriveWireDocument.ConnectionType) -> some View {
        Button {
            newDocument(DriveWireDocument(connectionType: connectionType))
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct DriveWireCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New DriveWire Document…") {
                openWindow(id: DriveWireWindowID.newDocumentChooser)
            }
            .keyboardShortcut("n")
        }
    }
}

@main
struct DriveWireApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: DriveWireDocument()) { configuration in
            ContentView(document: configuration.$document, fileURL: configuration.fileURL)
                .frame(
                    minWidth: 1240,
                    idealWidth: 1520,
                    maxWidth: .infinity,
                    minHeight: 1180,
                    idealHeight: 1260,
                    maxHeight: .infinity
                )
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1520, height: 1260)
        .commands {
            DriveWireCommands()
        }

        Window("New DriveWire Document", id: DriveWireWindowID.newDocumentChooser) {
            NewDocumentChooserView()
        }
        .windowResizability(.contentSize)
    }
}
