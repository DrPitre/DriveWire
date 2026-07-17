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

private struct WindowFramePersistenceAccessor: NSViewControllerRepresentable {
    let fileURL: URL?
    let onWindowWillClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSViewController(context: Context) -> TrackingViewController {
        let controller = TrackingViewController()
        controller.onWindowChange = { window in
            context.coordinator.attach(to: window, fileURL: fileURL, onWindowWillClose: onWindowWillClose)
        }
        return controller
    }

    func updateNSViewController(_ controller: TrackingViewController, context: Context) {
        controller.onWindowChange = { window in
            context.coordinator.attach(to: window, fileURL: fileURL, onWindowWillClose: onWindowWillClose)
        }
        controller.reportCurrentWindow()
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var frameKey: String?
        private var hasRestoredFrame = false

        deinit {
            removeObservers()
        }

        func attach(to window: NSWindow?, fileURL: URL?, onWindowWillClose: @escaping () -> Void) {
            guard let window else {
                return
            }

            if fileURL == nil {
                let needsReattach = self.window !== window || self.frameKey != nil
                if needsReattach {
                    removeObservers()
                    self.window = window
                    self.frameKey = nil
                    hasRestoredFrame = false
                }
                forceWindowFrame(window)
                return
            }

            let frameKey = Self.frameKey(for: fileURL)
            let needsReattach = self.window !== window || self.frameKey != frameKey
            guard needsReattach else {
                if !hasRestoredFrame {
                    restoreFrameIfNeeded(for: window, key: frameKey)
                }
                return
            }

            removeObservers()
            self.window = window
            self.frameKey = frameKey
            hasRestoredFrame = false

            restoreFrameIfNeeded(for: window, key: frameKey)

            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                    self?.saveFrame()
                },
                center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                    self?.saveFrame()
                },
                center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { [weak self] _ in
                    self?.saveFrame()
                },
                center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    self?.saveFrame()
                    onWindowWillClose()
                }
            ]
        }

        private func restoreFrameIfNeeded(for window: NSWindow, key: String?) {
            guard !hasRestoredFrame else {
                return
            }
            hasRestoredFrame = true

            let minimumAcceptedSize = NSSize(width: 1360, height: 1180)

            if let key, let frameString = UserDefaults.standard.string(forKey: key) {
                let frame = NSRectFromString(frameString)
                let isLargeEnough = frame.width >= minimumAcceptedSize.width && frame.height >= minimumAcceptedSize.height
                if isLargeEnough {
                    DispatchQueue.main.async {
                        window.setFrame(frame, display: true)
                    }
                    return
                }
                UserDefaults.standard.removeObject(forKey: key)
            }

            forceWindowFrame(window)
        }

        private func forceWindowFrame(_ window: NSWindow) {
            let minimumSize = NSSize(width: 1240, height: 1180)
            let targetSize = NSSize(width: 1480, height: 1260)

            DispatchQueue.main.async {
                window.minSize = minimumSize
                window.contentMinSize = minimumSize
                window.setContentSize(targetSize)

                let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
                let origin: NSPoint
                if visibleFrame == .zero {
                    origin = window.frame.origin
                } else {
                    origin = NSPoint(
                        x: visibleFrame.midX - (targetSize.width / 2),
                        y: visibleFrame.midY - (targetSize.height / 2)
                    )
                }

                let frame = NSRect(origin: origin, size: targetSize)
                window.setFrame(frame, display: true, animate: false)
            }
        }

        private func saveFrame() {
            guard let window, let frameKey else {
                return
            }

            let frameString = NSStringFromRect(window.frame)
            UserDefaults.standard.set(frameString, forKey: frameKey)
        }

        private func removeObservers() {
            let center = NotificationCenter.default
            for observer in observers {
                center.removeObserver(observer)
            }
            observers.removeAll()
        }

        private static func frameKey(for fileURL: URL?) -> String? {
            guard let fileURL else {
                return nil
            }

            let encodedPath = Data(fileURL.standardizedFileURL.path.utf8).base64EncodedString()
            let sanitized = encodedPath
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
            return "DriveWireDocumentFrame-\(sanitized)"
        }
    }

    final class TrackingViewController: NSViewController {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func loadView() {
            view = NSView(frame: .zero)
        }

        override func viewWillAppear() {
            super.viewWillAppear()
            reportCurrentWindow()
        }

        override func viewDidAppear() {
            super.viewDidAppear()
            reportCurrentWindow()
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
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(DriveWirePalette.accent)
                    .tracking(1.2)
                Text(title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(DriveWirePalette.softText)
                }
            }

            content
        }
        .padding(15)
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
                .font(.system(size: 12, weight: .semibold, design: .rounded))
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
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(DriveWirePalette.softText)
                .tracking(0.8)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(DriveWirePalette.softText)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
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
        .font(.system(size: 12, weight: .medium, design: .rounded))
    }
}

struct VirtualChannelView: View {
    let channelNumber: Int

    var body: some View {
        HStack(spacing: 10) {
            LEDView(isOn: false, activeColor: DriveWirePalette.accent)
                .frame(width: 9, height: 9)
            Text("Channel \(channelNumber)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("Idle")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(DriveWirePalette.softText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DriveWirePalette.panelMuted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DriveWirePalette.border, lineWidth: 1)
        )
    }
}

struct VirtualChannelsView: View {
    private let channels = Array(0...7)
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        DashboardSection(eyebrow: "Monitoring", title: "Virtual Channels", detail: "Compact status for the eight guest channels.") {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(channels, id: \.self) { channel in
                    VirtualChannelView(channelNumber: channel)
                }
            }
        }
    }
}

struct VirtualWindowPanelView: View {
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
                                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    }
                                }
                                .buttonStyle(.bordered)
                                .tint(selectedWindow?.channel == window.channel ? DriveWirePalette.accentMuted : .gray)
                            }
                        }
                    }

                    if let window = selectedWindow {
                        Button("Clear") {
                            host.clearVirtualWindow(channel: window.channel)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if let window = selectedWindow {
                    VirtualWindowTerminalView(text: window.text, channel: window.channel) { input, channel in
                        host.sendVirtualWindowInput(input, channel: channel)
                    }
                    .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 300)
                    .background(Color.black.opacity(0.45))
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

private struct VirtualWindowTerminalView: NSViewRepresentable {
    let text: String
    let channel: UInt8
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
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        textView.textColor = NSColor(red: 0.75, green: 1.0, blue: 0.78, alpha: 1.0)
        textView.insertionPointColor = NSColor(red: 0.75, green: 1.0, blue: 0.78, alpha: 1.0)
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
        textView.setTerminalText(text)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, textView.bounds.height - scrollView.contentView.bounds.height)))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        DispatchQueue.main.async {
            if textView.window?.firstResponder !== textView {
                textView.window?.makeFirstResponder(textView)
            }
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
    private let terminalAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(red: 0.75, green: 1.0, blue: 0.78, alpha: 1.0)
    ]

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    func setTerminalText(_ text: String) {
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: terminalAttributes))
        setSelectedRange(NSRange(location: text.count, length: 0))
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
}

struct DriveRowView: View {
    let driveNumber: Int
    let imagePath: String?
    let onChoose: () -> Void
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
                HStack(alignment: .center) {
                    Text("Drive \(driveNumber)")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer(minLength: 12)
                    StatusPill(text: statusText, color: imagePath == nil ? .gray : DriveWirePalette.accent)
                }

                Text(displayName)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(detailText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DriveWirePalette.softText)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            VStack(spacing: 8) {
                Button(imagePath == nil ? "Mount" : "Replace", action: onChoose)
                    .buttonStyle(.borderedProminent)
                    .tint(DriveWirePalette.accentMuted)
                Button("Eject", role: .destructive, action: onEject)
                    .buttonStyle(.bordered)
                    .disabled(imagePath == nil)
            }
            .controlSize(.small)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
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
                        onChoose: { chooseDisk(for: slot.driveNumber) },
                        onEject: { ejectDisk(slot.driveNumber) }
                    )
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func imagePath(for driveNumber: Int) -> String? {
        activeHost.virtualDrives.first(where: { $0.driveNumber == driveNumber })?.imagePath
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
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(DriveWirePalette.softText)
                .tracking(0.8)
            content
        }
    }
}

struct SerialPortSelector: View {
    @Binding var selectedPortName: String
    @Binding var selectedBaudRate: String
    @StateObject private var portManager = ObservableSerialPortManager()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            InspectorField("Serial Port") {
                Picker("Serial Port", selection: $selectedPortName) {
                    Text("No device")
                        .tag("NONE")
                    ForEach(portManager.availablePorts, id: \.self) { port in
                        Text(port.name)
                            .tag(port.path)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            InspectorField("Baud Rate") {
                Picker("Baud Rate", selection: $selectedBaudRate) {
                    ForEach(["57600", "115200", "230400"], id: \.self) { baud in
                        Text(baud)
                            .tag(baud)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 160, alignment: .topLeading)
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
    let statistics: DriveWireStatistics

    private var tiles: [StatTile] {
        [
            StatTile(title: "Last Opcode", value: hex(statistics.lastOpCode), tint: DriveWirePalette.accent),
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
            StatisticItem(title: "Last GetStat", value: hex(statistics.lastGetStat)),
            StatisticItem(title: "Last SetStat", value: hex(statistics.lastSetStat)),
            StatisticItem(title: "Read Retries", value: String(statistics.reReadCount)),
            StatisticItem(title: "Write Retries", value: String(statistics.reWriteCount)),
            StatisticItem(title: "Last Error", value: hex(statistics.lastError)),
            StatisticItem(title: "Checksum", value: hex(statistics.lastCheckSum))
        ]
    }

    private let primaryColumns = [
        GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10, alignment: .top)
    ]

    private let secondaryColumns = [
        GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 10, alignment: .top)
    ]

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
        return "Select a device to connect, or choose No device to disconnect"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SerialPortSelector(selectedPortName: $portName, selectedBaudRate: $baudRate)
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
    @Binding var ipAddress: String
    @Binding var ipPort: String

    private var statusText: String {
        document.tcpDriver.connected ? "Connected to \(document.tcpDriver.ipAddress):\(document.tcpDriver.ipPort)" : "Disconnected"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LabelValueRow(title: "Status", value: statusText)
            IPAddressSelector(selectedIPAddress: $ipAddress, selectedIPPort: $ipPort)

            HStack(spacing: 10) {
                Button("Connect") {
                    document.tcpDriver.ipAddress = ipAddress
                    document.tcpDriver.ipPort = UInt32(ipPort) ?? document.tcpDriver.ipPort
                }
                .buttonStyle(.borderedProminent)
                .tint(DriveWirePalette.accentMuted)

                Button("Disconnect") {
                    document.tcpDriver.stop()
                }
                .buttonStyle(.bordered)
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
            ipAddress = document.tcpDriver.ipAddress
            ipPort = String(document.tcpDriver.ipPort)
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
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            if document.connectionType == .serial {
                SerialCommsView(document: $document, serialDriver: document.serialDriver, portName: $selectedPortName, baudRate: $selectedBaudRate)
            } else {
                TCPCommsView(document: $document, ipAddress: $selectedIPAddress, ipPort: $selectedIPPort)
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
                .buttonStyle(.borderedProminent)
                .tint(DriveWirePalette.accentMuted)

                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText, forType: .string)
                }
                .buttonStyle(.bordered)

                Toggle("Detailed opcodes", isOn: $detailedOpcodeLogging)
                    .toggleStyle(.switch)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .help("Includes frequent READ, WRITE, GETSTAT, and SETSTAT traffic in the activity log. Leave this off for normal performance.")

                Text("\(logText.split(separator: "\n").count) lines")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DriveWirePalette.softText)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(logText.isEmpty ? " " : logText)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
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
                .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 220)
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
    @State private var selectedPortName = "NONE"
    @State private var selectedBaudRate = "57600"
    @State private var selectedIPAddress = "127.0.0.1"
    @State private var selectedIPPort = "6809"

    private var activeHost: DriveWireHost {
        document.connectionType == .serial ? document.serialDriver.host : document.tcpDriver.host
    }

    private var activeLogBinding: Binding<String> {
        Binding(
            get: { activeHost.log },
            set: { activeHost.log = $0 }
        )
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [DriveWirePalette.canvasTop, DriveWirePalette.canvasBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            HSplitView {
                ScrollView {
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
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.hidden)
                .frame(minWidth: 390, idealWidth: 440, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.white.opacity(0.02))

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        StatisticsGridView(statistics: activeHost.statistics)
                        if !activeHost.virtualWindows.isEmpty {
                            VirtualWindowPanelView(host: activeHost)
                        }
                        LoggingPanelView(logText: activeLogBinding, detailedOpcodeLogging: $document.detailedOpcodeLogging)
                        VirtualChannelsView()
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.hidden)
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.black.opacity(0.1))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .background {
                WindowFramePersistenceAccessor(fileURL: fileURL) {
                    document.persistCurrentState(to: fileURL)
                    document.serialDriver.stop()
                    document.tcpDriver.stop()
                }
                .frame(width: 0, height: 0)
            }
            .padding(18)
        }
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
