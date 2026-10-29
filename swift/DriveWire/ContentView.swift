//
//  ContentView.swift
//  DriveWireSwift
//
//  Created by Boisy Pitre on 9/29/23.
//

import SwiftUI
import ORSSerial
import AppKit

private enum DriveWirePalette {
    static let canvasTop = Color(red: 0.08, green: 0.11, blue: 0.12)
    static let canvasBottom = Color(red: 0.04, green: 0.05, blue: 0.06)
    static let panel = Color(red: 0.15, green: 0.18, blue: 0.18)
    static let panelElevated = Color(red: 0.18, green: 0.21, blue: 0.21)
    static let panelMuted = Color(red: 0.20, green: 0.23, blue: 0.23)
    static let accent = Color(red: 0.28, green: 0.77, blue: 0.61)
    static let accentMuted = Color(red: 0.16, green: 0.39, blue: 0.33)
    static let border = Color.white.opacity(0.08)
    static let softText = Color.white.opacity(0.64)
}

/// The user's text size, as a multiple of the designed point sizes.
enum DriveWireTextScale {
    static let storageKey = "uiTextScale"
    static let steps: [Double] = [1.0, 1.15, 1.3, 1.45, 1.6, 1.8]
    static let defaultValue = 1.0

    static func clamped(_ value: Double) -> Double {
        steps.min(by: { abs($0 - value) < abs($1 - value) }) ?? defaultValue
    }

    static func larger(than value: Double) -> Double {
        steps.first(where: { $0 > clamped(value) }) ?? steps.last!
    }

    static func smaller(than value: Double) -> Double {
        steps.last(where: { $0 < clamped(value) }) ?? steps.first!
    }
}

private struct DriveWireTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var driveWireTextScale: CGFloat {
        get { self[DriveWireTextScaleKey.self] }
        set { self[DriveWireTextScaleKey.self] = newValue }
    }
}

/// Sets a system font whose point size follows the user's text size.
private struct ScaledSystemFont: ViewModifier {
    @Environment(\.driveWireTextScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: (size * scale).rounded(), weight: weight, design: design))
    }
}

/// Steps a control size up as the text grows, so buttons and menus keep pace with their labels.
private struct ScaledControlSize: ViewModifier {
    @Environment(\.driveWireTextScale) private var scale
    let base: ControlSize

    func body(content: Content) -> some View {
        let sizes: [ControlSize] = [.mini, .small, .regular, .large, .extraLarge]
        let steps = scale >= 1.6 ? 2 : (scale >= 1.3 ? 1 : 0)
        let index = min((sizes.firstIndex(of: base) ?? 2) + steps, sizes.count - 1)
        return content.controlSize(sizes[index])
    }
}

/// A button whose label follows the user's text size. macOS draws the
/// standard bordered styles with AppKit, which ignores SwiftUI fonts.
struct DriveWireButtonStyle: ButtonStyle {
    /// The background colour, or `nil` for a neutral button.
    var fill: Color?

    init(fill: Color? = nil) {
        self.fill = fill
    }

    func makeBody(configuration: Configuration) -> some View {
        DriveWireButtonBody(configuration: configuration, fill: fill)
    }
}

private struct DriveWireButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.driveWireTextScale) private var scale

    var body: some View {
        let isSmall = controlSize == .small || controlSize == .mini
        let shape = RoundedRectangle(cornerRadius: isSmall ? 5 : 6, style: .continuous)
        configuration.label
            .font(.system(size: ((isSmall ? 11 : 13) * scale).rounded(), weight: .medium))
            .foregroundStyle(configuration.role == .destructive ? Color(red: 1.0, green: 0.55, blue: 0.5) : .white)
            .lineLimit(1)
            .padding(.horizontal, isSmall ? 7 : 10)
            .padding(.vertical, isSmall ? 2 : 4)
            .background(shape.fill(fill ?? Color.white.opacity(0.12)))
            .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 1))
            .overlay(shape.fill(Color.black.opacity(configuration.isPressed ? 0.18 : 0)))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(shape)
    }
}

/// A pop-up menu whose label follows the user's text size, unlike the AppKit-drawn menu picker.
struct DriveWireMenuPicker<Value: Hashable>: View {
    struct Option: Hashable {
        let value: Value
        let label: String
    }

    let title: String
    @Binding var selection: Value
    let options: [Option]
    /// The label to show when the selection is not one of the options.
    var missingLabel: (Value) -> String = { _ in "None" }

    private var currentLabel: String {
        options.first(where: { $0.value == selection })?.label ?? missingLabel(selection)
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentLabel)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .accessibilityLabel(title)
    }
}

extension View {
    func dwControlSize(_ base: ControlSize) -> some View {
        modifier(ScaledControlSize(base: base))
    }

    func dwFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, design: design))
    }
}

private func serialPortDisplayName(_ path: String) -> String {
    guard !path.isEmpty, path != "NONE" else {
        return "No serial device selected"
    }

    let lastComponent = URL(fileURLWithPath: path).lastPathComponent
    if let trimmed = lastComponent.split(separator: ".", maxSplits: 1).last {
        return String(trimmed)
    }
    return lastComponent
}

private struct WindowLifecycleAccessor: NSViewControllerRepresentable {
    let onWindowWillClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSViewController(context: Context) -> TrackingViewController {
        let controller = TrackingViewController()
        controller.onWindowChange = { window in
            context.coordinator.attach(to: window, onWindowWillClose: onWindowWillClose)
        }
        return controller
    }

    func updateNSViewController(_ controller: TrackingViewController, context: Context) {
        controller.onWindowChange = { window in
            context.coordinator.attach(to: window, onWindowWillClose: onWindowWillClose)
        }
        controller.reportCurrentWindow()
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var observer: NSObjectProtocol?

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func attach(to window: NSWindow?, onWindowWillClose: @escaping () -> Void) {
            guard let window, self.window !== window else {
                return
            }

            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }

            self.window = window
            window.styleMask.remove(.fullSizeContentView)
            window.titlebarAppearsTransparent = false
            observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                onWindowWillClose()
            }
        }
    }

    final class TrackingViewController: NSViewController {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func loadView() {
            view = NSView(frame: .zero)
        }

        override func viewDidAppear() {
            super.viewDidAppear()
            onWindowChange?(view.window)
        }

        func reportCurrentWindow() {
            onWindowChange?(view.window)
        }
    }
}

struct DriveSlot: Identifiable {
    let driveNumber: Int

    var id: Int { driveNumber }
}

struct StatisticItem: Identifiable {
    let title: String
    let value: String

    var id: String { title }
}

struct StatTile: Identifiable {
    let title: String
    let value: String
    let tint: Color

    var id: String { title }
}

struct DashboardSection<Content: View>: View {
    let eyebrow: String
    let title: String
    let detail: String?
    @ViewBuilder var content: Content

    init(eyebrow: String, title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.eyebrow = eyebrow
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow.uppercased())
                    .dwFont(10, weight: .semibold, design: .rounded)
                    .foregroundStyle(DriveWirePalette.accent)
                    .tracking(1.2)
                Text(title)
                    .dwFont(20, weight: .bold, design: .rounded)
                    .foregroundStyle(.white)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .dwFont(12)
                        .foregroundStyle(DriveWirePalette.softText)
                }
            }

            content
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [DriveWirePalette.panelElevated, DriveWirePalette.panel],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(DriveWirePalette.border, lineWidth: 1)
        )
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .dwFont(12, weight: .semibold, design: .rounded)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(0.18))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }
}

struct DashboardMetricBadge: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .dwFont(10, weight: .medium, design: .rounded)
                .foregroundStyle(DriveWirePalette.softText)
                .tracking(0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(value)
                .dwFont(15, weight: .semibold, design: .rounded)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DriveWirePalette.panelMuted.opacity(0.95))
        )
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(tint.opacity(0.22))
                .frame(width: 28, height: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .stroke(tint.opacity(0.35), lineWidth: 1)
                )

            Text(value)
                .dwFont(19, weight: .bold, design: .rounded)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(title)
                .dwFont(11, weight: .medium, design: .rounded)
                .foregroundStyle(DriveWirePalette.softText)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(DriveWirePalette.panelMuted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(DriveWirePalette.border, lineWidth: 1)
        )
    }
}

struct LabelValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(DriveWirePalette.softText)
            Spacer(minLength: 16)
            Text(value)
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
        }
        .dwFont(12, weight: .medium, design: .rounded)
    }
}

struct VirtualChannelView: View {
    let status: DriveWireVirtualChannelStatus

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                TrafficLED(label: "ON", isOn: status.isOpen, color: Color(red: 0.42, green: 0.76, blue: 1.0))
                TrafficLED(label: "IN", isOn: status.incomingActive, color: Color(red: 0.96, green: 0.68, blue: 0.28))
                TrafficLED(label: "OUT", isOn: status.outgoingActive, color: DriveWirePalette.accent)
            }
            ViewThatFits(in: .horizontal) {
                Text("Channel \(status.number)")
                Text("Ch \(status.number)")
            }
            .dwFont(13, weight: .semibold, design: .rounded)
            .foregroundStyle(.white)
            .lineLimit(1)
            Spacer(minLength: 8)
            Text(statusText)
                .dwFont(11, weight: .medium, design: .rounded)
                .foregroundStyle(DriveWirePalette.softText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DriveWirePalette.panelMuted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DriveWirePalette.border, lineWidth: 1)
        )
    }

    private var statusText: String {
        if status.isTCPBacked {
            return "TCP"
        }
        if status.pendingBytes > 0 {
            return "\(status.pendingBytes) B"
        }
        return status.isOpen ? "Open" : "Idle"
    }
}

private struct TrafficLED: View {
    @Environment(\.driveWireTextScale) private var textScale
    let label: String
    let isOn: Bool
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            LEDView(isOn: isOn, activeColor: color)
                .frame(width: 7, height: 7)
            Text(label)
                .dwFont(9, weight: .bold, design: .rounded)
                .foregroundStyle(isOn ? .white : DriveWirePalette.softText.opacity(0.65))
                .monospacedDigit()
        }
        .frame(width: 12 + 20 * textScale, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(isOn ? "active" : "idle")")
    }
}

struct VirtualChannelsView: View {
    let host: DriveWireHost

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        DashboardSection(eyebrow: "Monitoring", title: "Virtual Channels", detail: "Compact status for the eight guest channels.") {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(host.virtualSerialChannels) { status in
                    VirtualChannelView(status: status)
                }
            }
        }
    }
}

struct VirtualWindowPanelView: View {
    @Environment(\.driveWireTextScale) private var textScale
    let host: DriveWireHost
    @State private var selectedChannel: UInt8?

    private var selectedWindow: DriveWireVirtualWindow? {
        if let selectedChannel,
           let window = host.virtualWindows.first(where: { $0.channel == selectedChannel }) {
            return window
        }
        return host.virtualWindows.first
    }

    var body: some View {
        DashboardSection(
            eyebrow: "Display",
            title: "Virtual Windows",
            detail: "Guest /Z window output from active virtual screen channels."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    if host.virtualWindows.isEmpty {
                        HStack(spacing: 7) {
                            LEDView(isOn: false, activeColor: DriveWirePalette.accent)
                                .frame(width: 8, height: 8)
                            Text("No /Z windows")
                                .dwFont(12, weight: .semibold, design: .rounded)
                                .foregroundStyle(DriveWirePalette.softText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(host.virtualWindows) { window in
                                    Button {
                                        selectedChannel = window.channel
                                    } label: {
                                        HStack(spacing: 7) {
                                            LEDView(isOn: window.isOpen, activeColor: DriveWirePalette.accent)
                                                .frame(width: 8, height: 8)
                                            Text(window.title)
                                                .dwFont(12, weight: .semibold, design: .rounded)
                                        }
                                    }
                                    .buttonStyle(DriveWireButtonStyle(fill: selectedWindow?.channel == window.channel ? DriveWirePalette.accentMuted : nil))
                                }
                            }
                        }
                    }

                    if let window = selectedWindow {
                        Button("Clear") {
                            host.clearVirtualWindow(channel: window.channel)
                        }
                        .buttonStyle(DriveWireButtonStyle())
                        .controlSize(.small)
                    }
                }

                if let window = selectedWindow {
                    VirtualWindowTerminalView(text: window.text, channel: window.channel, fontSize: 13 * textScale) { input, channel in
                        host.sendVirtualWindowInput(input, channel: channel)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150, idealHeight: 150, maxHeight: 150)
                    .background(Color.black.opacity(0.45))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(DriveWirePalette.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.45)
                        Text("No active /Z windows")
                            .dwFont(13, weight: .semibold, design: .monospaced)
                            .foregroundStyle(DriveWirePalette.softText)
                            .padding(12)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150, idealHeight: 150, maxHeight: 150)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(DriveWirePalette.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }
}

struct MIDIView: View {
    @Environment(\.driveWireTextScale) private var textScale
    let host: DriveWireHost

    private var status: DriveWireMIDIStatus {
        host.midiMonitorStatus
    }

    private var stateColor: Color {
        switch status.state {
        case "Playing MIDI File", "Receiving MIDI File", "Raw MIDI":
            return DriveWirePalette.accent
        case "Error":
            return .red
        case "Stopped":
            return .orange
        default:
            return .gray
        }
    }

    private var metrics: [StatisticItem] {
        [
            StatisticItem(title: "Bytes", value: String(status.bytesReceived)),
            StatisticItem(title: "File Bytes", value: fileByteProgress),
            StatisticItem(title: "Tracks", value: trackProgress),
            StatisticItem(title: "Messages", value: String(status.messagesSent)),
            StatisticItem(title: "Available", value: status.isAvailable ? "Yes" : "No")
        ]
    }

    private var fileByteProgress: String {
        if let expectedFileBytes = status.expectedFileBytes {
            return "\(status.fileBytesReceived) / \(expectedFileBytes)"
        }
        return status.fileBytesReceived > 0 ? "\(status.fileBytesReceived) / ?" : "0"
    }

    private var trackProgress: String {
        if let expectedFileTracks = status.expectedFileTracks {
            return "\(status.completedFileTracks) / \(expectedFileTracks)"
        }
        return "0"
    }

    var body: some View {
        DashboardSection(eyebrow: "Audio", title: "MIDI", detail: "Live status for the /MIDI virtual channel.") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    StatusPill(text: status.state, color: stateColor)
                    Spacer(minLength: 12)
                    Button("Stop MIDI") {
                        host.stopMIDIPlayback()
                    }
                    .buttonStyle(DriveWireButtonStyle(fill: DriveWirePalette.accentMuted))
                    .controlSize(.small)
                    .help("Stop MIDI playback and send all-notes-off to the selected output.")
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92 * textScale, maximum: 220 * textScale), spacing: 10)], spacing: 10) {
                    DashboardMetricBadge(label: "Backend", value: status.backendName)
                    DashboardMetricBadge(label: "Output", value: status.selectedOutputName)
                    ForEach(metrics) { item in
                        DashboardMetricBadge(label: item.title, value: item.value)
                    }
                }

                if let lastError = status.lastError, !lastError.isEmpty {
                    Text(lastError)
                        .dwFont(12, weight: .semibold, design: .rounded)
                        .foregroundStyle(.red.opacity(0.9))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.red.opacity(0.12))
                        )
                }

                if !status.statusLines.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(status.statusLines, id: \.self) { line in
                            Text(line)
                                .dwFont(12, weight: .medium, design: .monospaced)
                                .foregroundStyle(DriveWirePalette.softText)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.black.opacity(0.20))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(DriveWirePalette.border, lineWidth: 1)
                    )
                }
            }
        }
    }
}

struct PrinterView: View {
    @Environment(\.driveWireTextScale) private var textScale
    let host: DriveWireHost


    private var status: DriveWirePrinterStatus {
        host.printerStatus
    }

    private var stateColor: Color {
        switch status.state {
        case "Receiving":
            return DriveWirePalette.accent
        case "Error":
            return .red
        default:
            return .gray
        }
    }

    private var lastFlushText: String {
        guard let date = status.lastFlushedAt else {
            return "Never"
        }

        return Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        DashboardSection(eyebrow: "Output", title: "Printer", detail: "Live status for DriveWire printer output.") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    StatusPill(text: status.state, color: stateColor)
                    Spacer(minLength: 12)
                    Button("Clear") {
                        host.resetPrinterState()
                    }
                    .buttonStyle(DriveWireButtonStyle(fill: DriveWirePalette.accentMuted))
                    .controlSize(.small)
                    .help("Clear buffered printer output and reset printer counters.")
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92 * textScale, maximum: 220 * textScale), spacing: 10)], spacing: 10) {
                    DashboardMetricBadge(label: "Backend", value: status.backendName)
                    DashboardMetricBadge(label: "Bytes", value: String(status.bytesReceived))
                    DashboardMetricBadge(label: "Pending", value: String(status.pendingBytes))
                    DashboardMetricBadge(label: "Flushes", value: String(status.flushedJobs))
                    DashboardMetricBadge(label: "Last Flush", value: lastFlushText)
                }

                if let lastError = status.lastError, !lastError.isEmpty {
                    Text(lastError)
                        .dwFont(12, weight: .semibold, design: .rounded)
                        .foregroundStyle(.red.opacity(0.9))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.red.opacity(0.12))
                        )
                }

                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.20)
                    Text(status.previewText.isEmpty ? "No printer output" : status.previewText)
                        .dwFont(12, weight: .medium, design: .monospaced)
                        .foregroundStyle(status.previewText.isEmpty ? DriveWirePalette.softText : .white.opacity(0.86))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, minHeight: 92, idealHeight: 92, maxHeight: 92)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(DriveWirePalette.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

private struct VirtualWindowTerminalView: NSViewRepresentable {
    let text: String
    let channel: UInt8
    let fontSize: CGFloat
    let onInput: (String, UInt8) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = VirtualWindowTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .medium)
        textView.terminalFontSize = fontSize
        textView.textColor = NSColor(red: 0.75, green: 1.0, blue: 0.78, alpha: 1.0)
        textView.insertionPointColor = .clear
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(red: 0.75, green: 1.0, blue: 0.78, alpha: 0.35)
        ]
        textView.onInput = { input in
            context.coordinator.onInput(input, context.coordinator.channel)
        }

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.channel = channel
        guard let textView = scrollView.documentView as? VirtualWindowTextView else { return }
        textView.onInput = { input in
            context.coordinator.onInput(input, context.coordinator.channel)
        }
        textView.terminalFontSize = fontSize
        textView.setTerminalText(text)

        DispatchQueue.main.async {
            if textView.window?.firstResponder !== textView {
                textView.window?.makeFirstResponder(textView)
            }
            textView.scrollToTerminalEnd()
        }
    }

    final class Coordinator {
        let onInput: (String, UInt8) -> Void
        var channel: UInt8 = 0x80

        init(onInput: @escaping (String, UInt8) -> Void) {
            self.onInput = onInput
        }
    }
}

private final class VirtualWindowTextView: NSTextView {
    var onInput: ((String) -> Void)?
    private var cursorTimer: Timer?
    private var isCursorVisible = true

    var terminalFontSize: CGFloat = 13 {
        didSet {
            guard terminalFontSize != oldValue else { return }
            font = .monospacedSystemFont(ofSize: terminalFontSize, weight: .medium)
        }
    }

    private var terminalAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: terminalFontSize, weight: .medium),
            .foregroundColor: NSColor(red: 0.75, green: 1.0, blue: 0.78, alpha: 1.0)
        ]
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    func setTerminalText(_ text: String) {
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: terminalAttributes))
        setSelectedRange(NSRange(location: text.count, length: 0))
        scrollToTerminalEnd()
    }

    func scrollToTerminalEnd() {
        scrollRangeToVisible(NSRange(location: string.count, length: 0))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopCursorTimer()
        } else {
            startCursorTimer()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawBlockCursor()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 36, 76:
            onInput?("\r")
        case 51:
            onInput?("\u{08}")
        case 48:
            onInput?("\t")
        case 53:
            onInput?("\u{1B}")
        default:
            if let characters = event.characters, !characters.isEmpty {
                onInput?(characters.replacingOccurrences(of: "\n", with: "\r"))
            }
        }
    }

    private func startCursorTimer() {
        stopCursorTimer()
        cursorTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            isCursorVisible.toggle()
            setNeedsDisplay(bounds)
        }
        if let cursorTimer {
            RunLoop.main.add(cursorTimer, forMode: .common)
        }
    }

    private func stopCursorTimer() {
        cursorTimer?.invalidate()
        cursorTimer = nil
    }

    private func drawBlockCursor() {
        guard isCursorVisible else { return }

        let textLength = string.count
        setSelectedRange(NSRange(location: textLength, length: 0))

        let font = font ?? .monospacedSystemFont(ofSize: terminalFontSize, weight: .medium)
        let characterWidth = max(8, (" " as NSString).size(withAttributes: [.font: font]).width)
        let cursorHeight = font.ascender - font.descender
        let cursorOrigin = terminalCursorOrigin(characterWidth: characterWidth, cursorHeight: cursorHeight)
        let cursorRect = NSRect(
            x: cursorOrigin.x,
            y: cursorOrigin.y,
            width: characterWidth,
            height: cursorHeight
        ).integral

        NSColor(red: 0.75, green: 1.0, blue: 0.78, alpha: 0.75).setFill()
        cursorRect.fill()
    }

    private func terminalCursorOrigin(characterWidth: CGFloat, cursorHeight: CGFloat) -> NSPoint {
        guard
            let layoutManager,
            let textContainer
        else {
            return NSPoint(x: textContainerInset.width, y: textContainerInset.height)
        }

        layoutManager.ensureLayout(for: textContainer)

        if string.isEmpty {
            return NSPoint(x: textContainerInset.width, y: textContainerInset.height)
        }

        let nsString = string as NSString
        let textLength = nsString.length
        let previousCharacter = nsString.character(at: textLength - 1)
        if previousCharacter == 0x0A || previousCharacter == 0x0D {
            let glyphIndex = max(layoutManager.numberOfGlyphs - 1, 0)
            let previousRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            return NSPoint(
                x: textContainerInset.width,
                y: textContainerInset.height + previousRect.maxY
            )
        }

        let glyphIndex = max(layoutManager.glyphIndexForCharacter(at: textLength - 1), 0)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        return NSPoint(
            x: textContainerInset.width + glyphRect.maxX,
            y: textContainerInset.height + lineRect.minY + max(0, (lineRect.height - cursorHeight) / 2)
        )
    }
}

struct DriveRowView: View {
    let driveNumber: Int
    let imagePath: String?
    let activity: DriveWireDriveActivity
    let onChoose: () -> Void
    let onRefresh: () -> Void
    let onEject: () -> Void

    private var displayName: String {
        guard let imagePath, !imagePath.isEmpty else {
            return "Empty Slot"
        }

        return URL(fileURLWithPath: imagePath).lastPathComponent
    }

    private var detailText: String {
        guard let imagePath, !imagePath.isEmpty else {
            return "No image mounted"
        }

        let fileURL = URL(fileURLWithPath: imagePath)
        let sizeText: String
        if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
           let fileSize = values.fileSize {
            sizeText = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
        } else {
            sizeText = "Unknown size"
        }

        return "\(sizeText) • \(imagePath)"
    }

    private var statusText: String {
        imagePath == nil ? "Ready" : "Mounted"
    }

    private var activityColor: Color {
        if activity.isWriting {
            return .red
        }
        if activity.isReading {
            return DriveWirePalette.accent
        }
        return .gray
    }

    private var activityLabel: String {
        if activity.isWriting {
            return "Drive \(driveNumber) writing"
        }
        if activity.isReading {
            return "Drive \(driveNumber) reading"
        }
        return "Drive \(driveNumber) idle"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(imagePath == nil ? DriveWirePalette.accentMuted.opacity(0.5) : DriveWirePalette.accent.opacity(0.2))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: imagePath == nil ? "externaldrive.badge.plus" : "externaldrive.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(imagePath == nil ? DriveWirePalette.softText : DriveWirePalette.accent)
                )

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: 8) {
                    LEDView(isOn: activity.isReading || activity.isWriting, activeColor: activityColor)
                        .frame(width: 10, height: 10)
                        .accessibilityLabel(activityLabel)
                    Text("Drive \(driveNumber)")
                        .dwFont(15, weight: .bold, design: .rounded)
                        .foregroundStyle(.white)
                    Spacer(minLength: 12)
                    StatusPill(text: statusText, color: imagePath == nil ? .gray : DriveWirePalette.accent)
                }

                Text(displayName)
                    .dwFont(14, weight: .semibold, design: .rounded)
                    .foregroundStyle(.white)
                Text(detailText)
                    .dwFont(12, weight: .medium, design: .rounded)
                    .foregroundStyle(DriveWirePalette.softText)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            VStack(spacing: 8) {
                Button(imagePath == nil ? "Mount" : "Replace", action: onChoose)
                    .buttonStyle(DriveWireButtonStyle(fill: DriveWirePalette.accentMuted))
                Button("Refresh", action: onRefresh)
                    .buttonStyle(DriveWireButtonStyle())
                    .disabled(imagePath == nil)
                    .help("Reload this disk image from its current file path.")
                Button("Eject", role: .destructive, action: onEject)
                    .buttonStyle(DriveWireButtonStyle())
                    .disabled(imagePath == nil)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(DriveWirePalette.panelMuted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(DriveWirePalette.border, lineWidth: 1)
        )
    }
}

struct DrivesPanelView: View {
    @Binding var document: DriveWireDocument

    private let slots = (0..<4).map(DriveSlot.init)

    private var activeHost: DriveWireHost {
        document.connectionType == .serial ? document.serialDriver.host : document.tcpDriver.host
    }

    private var mountedCount: Int {
        activeHost.virtualDrives.count
    }

    var body: some View {
        DashboardSection(
            eyebrow: "Storage",
            title: "Virtual Disks",
            detail: "\(mountedCount) of \(slots.count) slots mounted."
        ) {
            VStack(spacing: 10) {
                ForEach(slots) { slot in
                    DriveRowView(
                        driveNumber: slot.driveNumber,
                        imagePath: imagePath(for: slot.driveNumber),
                        activity: activity(for: slot.driveNumber),
                        onChoose: { chooseDisk(for: slot.driveNumber) },
                        onRefresh: { refreshDisk(slot.driveNumber) },
                        onEject: { ejectDisk(slot.driveNumber) }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func imagePath(for driveNumber: Int) -> String? {
        activeHost.virtualDrives.first(where: { $0.driveNumber == driveNumber })?.imagePath
    }

    private func activity(for driveNumber: Int) -> DriveWireDriveActivity {
        activeHost.driveActivities.first(where: { $0.driveNumber == driveNumber }) ?? DriveWireDriveActivity(driveNumber: driveNumber, isReading: false, isWriting: false)
    }

    private func chooseDisk(for driveNumber: Int) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let path = panel.url?.path(percentEncoded: false) else {
            return
        }

        do {
            try activeHost.insertVirtualDisk(driveNumber: driveNumber, imagePath: path)
        } catch {
            activeHost.log += "Failed to mount drive \(driveNumber): \(error.localizedDescription)\n"
        }
    }

    private func refreshDisk(_ driveNumber: Int) {
        guard let drive = activeHost.virtualDrives.first(where: { $0.driveNumber == driveNumber }) else {
            return
        }

        drive.reload()
        activeHost.log += "Reloaded disk in drive \(driveNumber): \(URL(fileURLWithPath: drive.imagePath).lastPathComponent)\n"
    }

    private func ejectDisk(_ driveNumber: Int) {
        activeHost.ejectVirtualDisk(driveNumber: driveNumber)
    }
}

struct InspectorField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .dwFont(11, weight: .semibold, design: .rounded)
                .foregroundStyle(DriveWirePalette.softText)
                .tracking(0.8)
            content
        }
    }
}

struct SerialPortSelector: View {
    @Environment(\.driveWireTextScale) private var textScale
    @Binding var selectedPortName: String
    @Binding var selectedBaudRate: String
    @StateObject private var portManager = ObservableSerialPortManager()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            InspectorField("Serial Port") {
                DriveWireMenuPicker(
                    title: "Serial Port",
                    selection: $selectedPortName,
                    options: [.init(value: "NONE", label: "No device")] + portManager.availablePorts.map {
                        .init(value: $0.path, label: $0.name)
                    },
                    missingLabel: { "\(serialPortDisplayName($0)) (not present)" }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            InspectorField("Baud Rate") {
                DriveWireMenuPicker(
                    title: "Baud Rate",
                    selection: $selectedBaudRate,
                    options: ["57600", "115200", "230400"].map { .init(value: $0, label: $0) },
                    missingLabel: { $0 }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 160 * textScale, alignment: .topLeading)
        }
    }
}

struct IPAddressSelector: View {
    @Binding var selectedIPAddress: String
    @Binding var selectedIPPort: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            InspectorField("IP Address") {
                TextField("127.0.0.1", text: $selectedIPAddress)
                    .textFieldStyle(.roundedBorder)
            }
            InspectorField("Port") {
                TextField("6809", text: $selectedIPPort)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

struct StatisticsGridView: View {
    @Environment(\.driveWireTextScale) private var textScale
    let statistics: DriveWireStatistics

    private var tiles: [StatTile] {
        [
            StatTile(title: "Last Opcode", value: DriveWireHost.opCodeDisplayName(statistics.lastOpCode), tint: DriveWirePalette.accent),
            StatTile(title: "Last LSN", value: String(statistics.lastLSN), tint: .blue),
            StatTile(title: "Sectors Read", value: String(statistics.readCount), tint: .mint),
            StatTile(title: "Sectors Written", value: String(statistics.writeCount), tint: .orange),
            StatTile(title: "Reads OK", value: "\(statistics.percentReadsOK)%", tint: .green),
            StatTile(title: "Writes OK", value: "\(statistics.percentWritesOK)%", tint: .yellow)
        ]
    }

    private var secondaryStatistics: [StatisticItem] {
        [
            StatisticItem(title: "Last Drive", value: String(statistics.lastDriveNumber)),
            StatisticItem(title: "Last GetStat", value: DriveWireHost.statusCodeDisplayName(statistics.lastGetStat)),
            StatisticItem(title: "Last SetStat", value: DriveWireHost.statusCodeDisplayName(statistics.lastSetStat)),
            StatisticItem(title: "Read Retries", value: String(statistics.reReadCount)),
            StatisticItem(title: "Write Retries", value: String(statistics.reWriteCount)),
            StatisticItem(title: "Last Error", value: hex(statistics.lastError)),
            StatisticItem(title: "Checksum", value: hex(statistics.lastCheckSum))
        ]
    }

    private var primaryColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 112 * textScale, maximum: 220 * textScale), spacing: 10, alignment: .top)]
    }

    private var secondaryColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 92 * textScale, maximum: 220 * textScale), spacing: 10, alignment: .top)]
    }

    var body: some View {
        DashboardSection(eyebrow: "Telemetry", title: "Runtime Snapshot", detail: "Live protocol and disk activity from the active host.") {
            LazyVGrid(columns: primaryColumns, spacing: 10) {
                ForEach(tiles) { tile in
                    MetricTile(title: tile.title, value: tile.value, tint: tile.tint)
                }
            }

            LazyVGrid(columns: secondaryColumns, spacing: 10) {
                ForEach(secondaryStatistics) { item in
                    DashboardMetricBadge(label: item.title, value: item.value)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(DriveWirePalette.panelMuted)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(DriveWirePalette.border, lineWidth: 1)
            )
        }
    }

    private func hex<T: BinaryInteger>(_ value: T) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }
}

struct SerialCommsView: View {
    @Binding var document: DriveWireDocument
    @ObservedObject var serialDriver: DriveWireSerialDriver
    @Binding var portName: String
    @Binding var baudRate: String
    @State private var hasInitializedSelection = false
    @State private var isRestoringSelection = false

    private func applySerialSelection(portSelection: String? = nil, baudSelection: String? = nil) {
        let nextBaud = Int(baudSelection ?? baudRate) ?? serialDriver.baudRate
        let nextPort = (portSelection ?? portName) == "NONE" ? "" : (portSelection ?? portName)

        serialDriver.baudRate = nextBaud
        serialDriver.portName = nextPort

        // Re-assign the driver so the document registers the configuration change for saving.
        document.serialDriver = serialDriver
    }

    private var statusText: String {
        let selectedPort = portName == "NONE" ? "" : portName
        if selectedPort.isEmpty {
            return "Serial Idle"
        }
        if serialDriver.isConnected {
            return "Connected to \(serialPortDisplayName(serialDriver.portName))"
        }
        if serialDriver.isWaitingForPort {
            return "Waiting for \(serialPortDisplayName(serialDriver.portName)) to reconnect"
        }
        return "Disconnected"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LabelValueRow(title: "Status", value: statusText)
            SerialPortSelector(selectedPortName: $portName, selectedBaudRate: $baudRate)

            HStack(spacing: 10) {
                Button("Connect") {
                    serialDriver.connect()
                }
                .buttonStyle(DriveWireButtonStyle(fill: DriveWirePalette.accentMuted))
                .disabled(portName == "NONE" || serialDriver.isConnected || serialDriver.isWaitingForPort)

                Button("Disconnect") {
                    serialDriver.stop()
                }
                .buttonStyle(DriveWireButtonStyle())
                .disabled(!serialDriver.isConnected && !serialDriver.isWaitingForPort)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(DriveWirePalette.panelMuted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(DriveWirePalette.border, lineWidth: 1)
        )
        .onAppear {
            guard !hasInitializedSelection else {
                return
            }

            hasInitializedSelection = true
            isRestoringSelection = true
            portName = document.serialDriver.portName.isEmpty ? "NONE" : document.serialDriver.portName
            baudRate = String(document.serialDriver.baudRate)

            DispatchQueue.main.async {
                isRestoringSelection = false
            }
        }
        .onChange(of: portName) { _, newValue in
            guard !isRestoringSelection else {
                return
            }
            applySerialSelection(portSelection: newValue)
        }
        .onChange(of: baudRate) { _, newValue in
            guard !isRestoringSelection else {
                return
            }
            applySerialSelection(baudSelection: newValue)
        }
    }
}

struct TCPCommsView: View {
    @Binding var document: DriveWireDocument
    @ObservedObject var tcpDriver: DriveWireTCPDriver
    @Binding var ipAddress: String
    @Binding var ipPort: String

    private var statusText: String {
        tcpDriver.connected ? "Connected to \(tcpDriver.ipAddress):\(tcpDriver.ipPort)" : "Disconnected"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LabelValueRow(title: "Status", value: statusText)
            IPAddressSelector(selectedIPAddress: $ipAddress, selectedIPPort: $ipPort)

            HStack(spacing: 10) {
                Button("Connect") {
                    tcpDriver.connect(ipAddress: ipAddress, ipPort: UInt32(ipPort) ?? tcpDriver.ipPort)
                }
                .buttonStyle(DriveWireButtonStyle(fill: DriveWirePalette.accentMuted))

                Button("Disconnect") {
                    tcpDriver.stop()
                }
                .buttonStyle(DriveWireButtonStyle())
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(DriveWirePalette.panelMuted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(DriveWirePalette.border, lineWidth: 1)
        )
        .onAppear {
            ipAddress = tcpDriver.ipAddress
            ipPort = String(tcpDriver.ipPort)
        }
    }
}

struct ConnectionPanelView: View {
    @Binding var document: DriveWireDocument
    @ObservedObject var serialDriver: DriveWireSerialDriver
    @Binding var selectedPortName: String
    @Binding var selectedBaudRate: String
    @Binding var selectedIPAddress: String
    @Binding var selectedIPPort: String

    private var activeHost: DriveWireHost {
        document.connectionType == .serial ? document.serialDriver.host : document.tcpDriver.host
    }

    private var isConnected: Bool {
        switch document.connectionType {
        case .serial:
            return serialDriver.isConnected
        case .network:
            return document.tcpDriver.connected
        }
    }

    private var statusLabel: String {
        switch document.connectionType {
        case .serial:
            let selectedPort = selectedPortName == "NONE" ? "" : selectedPortName
            if serialDriver.isConnected {
                return "Serial on \(serialPortDisplayName(serialDriver.portName))"
            }
            if serialDriver.isWaitingForPort {
                return "Serial waiting for \(serialPortDisplayName(serialDriver.portName))"
            }
            if selectedPort.isEmpty {
                return "Serial Idle"
            }
            return "Serial selected: \(serialPortDisplayName(selectedPort))"
        case .network:
            return document.tcpDriver.connected ? "Network Connected" : "Network Idle"
        }
    }

    private var statusDetail: String {
        switch document.connectionType {
        case .serial:
            return "Configure a physical serial link to serve the active guest."
        case .network:
            return "Connect to a DriveWire guest over TCP with the active document settings."
        }
    }

    var body: some View {
        DashboardSection(eyebrow: "Console", title: "DriveWire Host", detail: statusDetail) {
            HStack(alignment: .top, spacing: 16) {
                HStack(spacing: 12) {
                    LEDView(isOn: isConnected, activeColor: DriveWirePalette.accent)
                        .frame(width: 14, height: 14)
                    Text(statusLabel)
                        .dwFont(15, weight: .bold, design: .rounded)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Button {
                    activeHost.requestCoCoReset()
                } label: {
                    Label("Reset Guest", systemImage: "power")
                }
                .buttonStyle(DriveWireButtonStyle(fill: .red.opacity(0.75)))
                .controlSize(.small)
                .disabled(!isConnected)
                .help("Send the reset byte to the guest, then reset the DriveWire server session.")
            }

            if document.connectionType == .serial {
                SerialCommsView(document: $document, serialDriver: document.serialDriver, portName: $selectedPortName, baudRate: $selectedBaudRate)
            } else {
                TCPCommsView(document: $document, tcpDriver: document.tcpDriver, ipAddress: $selectedIPAddress, ipPort: $selectedIPPort)
            }
        }
    }
}

struct LoggingPanelView: View {
    @Binding var logText: String
    @Binding var detailedOpcodeLogging: Bool

    private let logBottomID = "log-bottom"

    var body: some View {
        DashboardSection(eyebrow: "Diagnostics", title: "Activity Log", detail: "Protocol traffic and host events for the active connection.") {
            HStack(spacing: 10) {
                Button("Clear") {
                    logText = ""
                }
                .buttonStyle(DriveWireButtonStyle(fill: DriveWirePalette.accentMuted))

                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText, forType: .string)
                }
                .buttonStyle(DriveWireButtonStyle())

                Toggle("Detailed opcodes", isOn: $detailedOpcodeLogging)
                    .toggleStyle(.switch)
                    .dwFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(.white)
                    .help("Includes frequent READ, WRITE, GETSTAT, and SETSTAT traffic in the activity log. Leave this off for normal performance.")

                Text("\(logText.split(separator: "\n").count) lines")
                    .dwFont(12, weight: .medium, design: .rounded)
                    .foregroundStyle(DriveWirePalette.softText)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(logText.isEmpty ? " " : logText)
                            .dwFont(12, weight: .medium, design: .monospaced)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .textSelection(.enabled)
                        Color.clear
                            .frame(height: 1)
                            .id(logBottomID)
                    }
                    .padding(12)
                }
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.black.opacity(0.28))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(DriveWirePalette.border, lineWidth: 1)
                )
                .frame(maxWidth: .infinity, minHeight: 128, idealHeight: 128, maxHeight: 128)
                .onAppear {
                    proxy.scrollTo(logBottomID, anchor: .bottom)
                }
                .onChange(of: logText) { _, _ in
                    proxy.scrollTo(logBottomID, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct ContentView: View {
    @Binding var document: DriveWireDocument
    let fileURL: URL?
    @AppStorage(DriveWireTextScale.storageKey) private var textScale = DriveWireTextScale.defaultValue
    @State private var selectedPortName = "NONE"
    @State private var selectedBaudRate = "57600"
    @State private var selectedIPAddress = "127.0.0.1"
    @State private var selectedIPPort = "6809"
    @AppStorage("columnSplitFraction") private var splitFraction = DriveWireWindowMetrics.defaultSplitFraction
    @State private var dividerDragStartWidth: CGFloat?

    private var activeHost: DriveWireHost {
        document.connectionType == .serial ? document.serialDriver.host : document.tcpDriver.host
    }

    private var activeLogBinding: Binding<String> {
        Binding(
            get: { activeHost.log },
            set: { activeHost.log = $0 }
        )
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            ConnectionPanelView(
                document: $document,
                serialDriver: document.serialDriver,
                selectedPortName: $selectedPortName,
                selectedBaudRate: $selectedBaudRate,
                selectedIPAddress: $selectedIPAddress,
                selectedIPPort: $selectedIPPort
            )

            DrivesPanelView(document: $document)
            VirtualChannelsView(host: activeHost)
            VirtualWindowPanelView(host: activeHost)
        }
        .padding(18)
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatisticsGridView(statistics: activeHost.statistics)
            MIDIView(host: activeHost)
            PrinterView(host: activeHost)
            LoggingPanelView(logText: activeLogBinding, detailedOpcodeLogging: $document.detailedOpcodeLogging)
        }
        .padding(18)
    }

    /// The narrowest a column may be, which grows at half the rate of the text.
    private var minimumColumnWidth: CGFloat {
        let scale = CGFloat(DriveWireTextScale.clamped(textScale))
        return (DriveWireWindowMetrics.minimumColumnWidth * (1 + (scale - 1) / 2)).rounded()
    }

    /// Limits a left column width so both columns stay above their minimum.
    private func clampedLeftWidth(_ proposed: CGFloat, in totalWidth: CGFloat) -> CGFloat {
        let maximum = max(minimumColumnWidth, totalWidth - DriveWireWindowMetrics.dividerWidth - minimumColumnWidth)
        return min(max(proposed.rounded(), minimumColumnWidth), maximum)
    }

    private func leftColumnWidth(in totalWidth: CGFloat) -> CGFloat {
        clampedLeftWidth(totalWidth * splitFraction, in: totalWidth)
    }

    private func columnDivider(totalWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(isDraggingDivider ? 0.28 : 0.08))
            .frame(width: DriveWireWindowMetrics.dividerWidth)
            .overlay {
                // A wider, invisible grab area centred on the line
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let startWidth = dividerDragStartWidth ?? leftColumnWidth(in: totalWidth)
                                dividerDragStartWidth = startWidth
                                let width = clampedLeftWidth(startWidth + value.translation.width, in: totalWidth)
                                splitFraction = Double(width / totalWidth)
                            }
                            .onEnded { _ in
                                dividerDragStartWidth = nil
                            }
                    )
                    .onTapGesture(count: 2) {
                        splitFraction = DriveWireWindowMetrics.defaultSplitFraction
                    }
                    .help("Drag to resize the columns. Double-click to restore the default split.")
            }
    }

    private var isDraggingDivider: Bool {
        dividerDragStartWidth != nil
    }

    var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let leftWidth = leftColumnWidth(in: totalWidth)

            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    leftColumn
                        .frame(width: leftWidth, alignment: .topLeading)

                    columnDivider(totalWidth: totalWidth)

                    rightColumn
                        .frame(width: max(0, totalWidth - leftWidth - DriveWireWindowMetrics.dividerWidth), alignment: .topLeading)
                }
            }
        }
        .frame(minWidth: minimumColumnWidth * 2 + DriveWireWindowMetrics.dividerWidth, minHeight: DriveWireWindowMetrics.minimumHeight, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [DriveWirePalette.canvasTop, DriveWirePalette.canvasBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .background {
            WindowLifecycleAccessor {
                document.persistCurrentState(to: fileURL)
                document.serialDriver.stop()
                document.tcpDriver.stop()
            }
            .frame(width: 0, height: 0)
        }
        .dwFont(13)
        .dwControlSize(.regular)
        .buttonStyle(DriveWireButtonStyle())
        .environment(\.driveWireTextScale, CGFloat(DriveWireTextScale.clamped(textScale)))
        .navigationTitle("DriveWire Host")
    }
}

final class ObservableSerialPortManager: NSObject, ObservableObject {
    @Published var availablePorts: [ORSSerialPort] = []
    private let portManager: ORSSerialPortManager

    override init() {
        portManager = ORSSerialPortManager.shared()
        super.init()

        NotificationCenter.default.addObserver(self, selector: #selector(portsWereConnected(_:)), name: Notification.Name.ORSSerialPortsWereConnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(portsWereDisconnected(_:)), name: Notification.Name.ORSSerialPortsWereDisconnected, object: nil)

        updateAvailablePorts()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func portsWereConnected(_ notification: Notification) {
        updateAvailablePorts()
    }

    @objc private func portsWereDisconnected(_ notification: Notification) {
        updateAvailablePorts()
    }

    private func updateAvailablePorts() {
        availablePorts = portManager.availablePorts as [ORSSerialPort]
    }
}

#Preview {
    ContentView(document: .constant(DriveWireDocument()), fileURL: nil)
}
