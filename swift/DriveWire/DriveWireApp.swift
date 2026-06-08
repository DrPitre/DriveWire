//
//  DriveWireSwiftApp.swift
//  DriveWireSwift
//
//  Created by Boisy Pitre on 9/29/23.
//

import SwiftUI
import AppIntents

@main
struct DriveWireApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { DriveWireDocument() }) { configuration in
            ContentView(document: configuration.document).frame(minWidth: 800, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        }
    }
}
