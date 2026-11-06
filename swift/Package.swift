// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "DriveWire",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DriveWireCore", targets: ["DriveWireCore"]),
        .library(name: "DriveWireServer", targets: ["DriveWireServer"]),
        .executable(name: "drivewire-server", targets: ["DriveWireCommand"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.105.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.6.1")
    ],
    targets: [
        .target(name: "CDriveWireSerial"),
        .target(name: "DriveWireSerial", dependencies: ["CDriveWireSerial"]),
        .target(name: "DriveWireNetworking", dependencies: [
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio")
        ]),
        .target(name: "DriveWireCore", dependencies: ["DriveWireNetworking"], path: "DriveWire",
                exclude: ["Assets.xcassets", "Preview Content", "DriveWire.docc", "Info.plist",
                          "DriveWire.entitlements", "ContentView.swift", "DriveWireApp.swift",
                          "DriveWireDocument.swift", "LEDView.swift", "Model/FileMonitor.swift",
                          "Drivers/DriveWireSerialDriver.swift", "Drivers/DriveWireTCPDriver.swift",
                          "Drivers/DriveWireTCPServerDriver.swift"],
                sources: ["Model/DriveWireHost.swift", "Model/DriveWireHost+API.swift",
                          "Model/DriveWireHost+DriveOps.swift", "Model/DriveWireHost+Logging.swift",
                          "Model/DriveWireHost+MIDI.swift", "Model/DriveWireHost+Printer.swift",
                          "Model/DriveWireHost+RFM.swift", "Model/DriveWireHost+VirtualDrive.swift",
                          "Model/DriveWireHost+VirtualSerial.swift", "Drivers/DriveWireMIDIBackend.swift"]),
        .target(name: "DriveWireServer", dependencies: ["DriveWireCore", "DriveWireNetworking", "DriveWireSerial"]),
        .executableTarget(name: "DriveWireCommand", dependencies: ["DriveWireServer", "DriveWireSerial",
            .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(name: "DriveWireCoreTests", dependencies: ["DriveWireCore"],
                    path: "DriveWireTests", sources: ["DriveWireTests.swift"]),
        .testTarget(name: "DriveWireServerTests", dependencies: ["DriveWireServer", "DriveWireNetworking", "DriveWireCore"])
    ],
    swiftLanguageModes: [.v5]
)
