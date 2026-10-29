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
    static let newDocumentMenuTitle = "New DriveWire Document…"
}

enum DriveWireWindowMetrics {
    /// The window's initial size; it can be resized from there.
    static let defaultWidth: CGFloat = 1520
    static let defaultHeight: CGFloat = 1420
    /// The draggable divider keeps each column at least this wide at the
    /// normal text size.
    static let minimumColumnWidth: CGFloat = 560
    static let dividerWidth: CGFloat = 1
    /// The left column's share of the window width until the divider is moved.
    static let defaultSplitFraction = 0.47
    /// Below the full layout height the window scrolls.
    static let minimumHeight: CGFloat = 600
}

/// The start window: shown at launch in place of AppKit's Open panel, and
/// from File > New DriveWire Document.
private struct NewDocumentChooserView: View {
    @Environment(\.newDocument) private var newDocument
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DriveWireTextScale.storageKey) private var textScale = DriveWireTextScale.defaultValue

    /// Set once the launch presentation has been handled, so a later
    /// File > New never closes itself.
    private static var handledLaunch = false
    private static let recentLimit = 5

    private var recentSessions: [URL] {
        Array(NSDocumentController.shared.recentDocumentURLs.prefix(Self.recentLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("DriveWire")
                    .dwFont(24, weight: .bold, design: .rounded)
                Text("Start a new session, or open a saved one.")
                    .dwFont(13, weight: .medium, design: .rounded)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                transportButton(
                    title: "Serial",
                    detail: "A new session on a physical serial link.",
                    connectionType: .serial
                )

                transportButton(
                    title: "Network",
                    detail: "A new session on a TCP endpoint.",
                    connectionType: .network
                )
            }

            if !recentSessions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent Sessions")
                        .dwFont(12, weight: .semibold, design: .rounded)
                        .foregroundStyle(.secondary)
                    ForEach(recentSessions, id: \.self) { url in
                        Button {
                            open(url)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc")
                                Text(url.deletingPathExtension().lastPathComponent)
                                    .dwFont(13, weight: .semibold, design: .rounded)
                                Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                                    .dwFont(11, weight: .medium, design: .rounded)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(url.path)
                    }
                }
            }

            HStack {
                Button("Open…") {
                    dismiss()
                    NSDocumentController.shared.openDocument(nil)
                }
                .keyboardShortcut("o")
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(DriveWireButtonStyle())
        }
        .padding(20)
        .frame(width: 520 * CGFloat(DriveWireTextScale.clamped(textScale)))
        .environment(\.driveWireTextScale, CGFloat(DriveWireTextScale.clamped(textScale)))
        .task {
            await closeIfLaunchedWithDocuments()
        }
    }

    /// At launch the window opens alongside any documents the app was asked
    /// to open, or that macOS restored, and steps aside for them.
    private func closeIfLaunchedWithDocuments() async {
        guard !Self.handledLaunch else { return }
        Self.handledLaunch = true
        try? await Task.sleep(for: .milliseconds(500))
        if !NSDocumentController.shared.documents.isEmpty {
            dismiss()
        }
    }

    private func open(_ url: URL) {
        dismiss()
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error {
                NSApp.presentError(error)
            }
        }
    }

    private func transportButton(title: String, detail: String, connectionType: DriveWireDocument.ConnectionType) -> some View {
        Button {
            newDocument(DriveWireDocument(connectionType: connectionType))
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .dwFont(17, weight: .bold, design: .rounded)
                    .foregroundStyle(.primary)
                Text(detail)
                    .dwFont(12, weight: .medium, design: .rounded)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
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

/// Replaces AppKit's launch-time Open panel with the start window.
final class DriveWireAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showStartWindow()
        }
        return false
    }

    /// Runs File > New DriveWire Document, which opens the SwiftUI start window.
    private func showStartWindow() {
        for menuItem in NSApp.mainMenu?.items ?? [] {
            guard let menu = menuItem.submenu,
                  let index = menu.items.firstIndex(where: { $0.title == DriveWireWindowID.newDocumentMenuTitle }) else {
                continue
            }
            menu.performActionForItem(at: index)
            return
        }
    }
}

private struct DriveWireCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(DriveWireTextScale.storageKey) private var textScale = DriveWireTextScale.defaultValue

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(DriveWireWindowID.newDocumentMenuTitle) {
                openWindow(id: DriveWireWindowID.newDocumentChooser)
            }
            .keyboardShortcut("n")
        }

        CommandGroup(before: .toolbar) {
            Button("Bigger Text") {
                textScale = DriveWireTextScale.larger(than: textScale)
            }
            .keyboardShortcut("+")
            .disabled(DriveWireTextScale.clamped(textScale) >= DriveWireTextScale.steps.last!)

            Button("Smaller Text") {
                textScale = DriveWireTextScale.smaller(than: textScale)
            }
            .keyboardShortcut("-")
            .disabled(DriveWireTextScale.clamped(textScale) <= DriveWireTextScale.steps.first!)

            Button("Actual Size") {
                textScale = DriveWireTextScale.defaultValue
            }
            .keyboardShortcut("0")
            .disabled(DriveWireTextScale.clamped(textScale) == DriveWireTextScale.defaultValue)

            Divider()
        }
    }
}

@main
struct DriveWireApp: App {
    @NSApplicationDelegateAdaptor(DriveWireAppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: DriveWireDocument()) { configuration in
            ContentView(document: configuration.$document, fileURL: configuration.fileURL)
        }
        .defaultSize(width: DriveWireWindowMetrics.defaultWidth, height: DriveWireWindowMetrics.defaultHeight)
        .windowResizability(.contentMinSize)
        .commands {
            DriveWireCommands()
        }

        Window("DriveWire", id: DriveWireWindowID.newDocumentChooser) {
            NewDocumentChooserView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)
    }
}
