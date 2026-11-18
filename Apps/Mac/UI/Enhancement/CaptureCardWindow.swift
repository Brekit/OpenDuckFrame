import AppKit
@preconcurrency import AVFoundation
import CoreGraphics

private final class CaptureCardStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// Dedicated direct-input surface; ordinary workbench profiles are unchanged.
@MainActor final class CaptureCardWindow: NSWindowController, NSWindowDelegate {
    static let shared = CaptureCardWindow()
    private let processor = SPLiveProcessor()
    private let preview = SPLivePreviewView(frame: .zero)
    private var source: CaptureCardSource!
    private let devicePicker = NSPopUpButton()
    private let modePicker = NSPopUpButton()
    private let profilePicker = NSPopUpButton()
    private let screenPicker = NSPopUpButton()
    private let audio = NSButton(checkboxWithTitle: L("capture.audio"), target: nil, action: nil)
    private let startButton = NSButton(title: L("capture.start"), target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: L("capture.ready"))
    private let telemetry = NSTextField(wrappingLabelWithString: "—")
    private let advice = NSTextField(wrappingLabelWithString: L("capture.explanation"))
    private var devices: [AVCaptureDevice] = []
    private var modes: [CaptureCardMode] = []
    private var screens: [NSScreen] = []
    private var generation: UInt64 = 0
    private var running = false
    private var requestingPermission = false
    private var lastReceipt: CaptureCardReceipt?
    private var lastStats: [String: Any] = [:]
    private var outputWindow: NSWindow?
    private var monitorTimer: Timer?
    private var lastReceiptTime = 0.0
    private var lastStatsTime = 0.0
    private var engineWarning: String?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 670),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "OpenDuckFrame · " + L("capture.title")
        window.minSize = NSSize(width: 590, height: 620)
        window.center(); window.delegate = self
        buildUI()
        processor.outputPreview = preview
        processor.installPresentationHooks()
        source = CaptureCardSource(processor: processor) { receipt in
            Task { @MainActor in CaptureCardWindow.shared.received(receipt) }
        }
        processor.statsHandler = { [weak self] stats in
            // The processor publishes handlers on the main queue.
            MainActor.assumeIsolated {
                guard let self, self.running,
                      (stats["sourceGeneration"] as? NSNumber)?.uint64Value == self.generation else { return }
                self.lastStats = stats; self.lastStatsTime = ProcessInfo.processInfo.systemUptime; self.renderTelemetry()
            }
        }
        processor.statusHandler = { [weak self] text, failed, request in
            MainActor.assumeIsolated {
                guard let self, self.running, request == self.generation else { return }
                if failed { self.engineWarning = L("capture.engineError") + " " + EnhancementText.runtime(text); self.status.stringValue = self.engineWarning! }
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        refreshDevices()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show() { showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    private func buildUI() {
        let root = CaptureCardStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        let heading = NSTextField(labelWithString: L("capture.title")); heading.font = .systemFont(ofSize: 23, weight: .semibold)
        root.addArrangedSubview(heading)
        root.addArrangedSubview(NSTextField(wrappingLabelWithString: L("capture.subtitle")))
        func row(_ title: String, _ control: NSView) {
            let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 140).isActive = true
            let row = NSStackView(views: [label, control]); row.spacing = 12
            root.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -44).isActive = true
            control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        row(L("capture.device"), devicePicker)
        row(L("capture.mode"), modePicker)
        profilePicker.addItems(withTitles: [L("capture.profile30"), L("capture.profile60"), L("capture.profileOff")])
        profilePicker.selectItem(at: max(0, min(2, UserDefaults.standard.integer(forKey: "CaptureCard.profile"))))
        row(L("capture.profile"), profilePicker)
        row(L("capture.display"), screenPicker)
        audio.state = (UserDefaults.standard.object(forKey: "CaptureCard.audio") == nil || UserDefaults.standard.bool(forKey: "CaptureCard.audio")) ? .on : .off
        root.addArrangedSubview(audio)
        let actions = NSStackView(); actions.spacing = 10
        for (title, action) in [(L("capture.recommend"), #selector(recommend)), (L("capture.refresh"), #selector(refreshDevices)), (L("capture.elgato"), #selector(openElgato))] {
            actions.addArrangedSubview(NSButton(title: title, target: self, action: action))
        }
        root.addArrangedSubview(actions)
        startButton.target = self; startButton.action = #selector(toggleCapture); startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [startButton, NSButton(title: L("capture.fullscreen"), target: self, action: #selector(fullscreen)), NSButton(title: L("capture.copy"), target: self, action: #selector(copyReport))]); buttons.spacing = 10
        root.addArrangedSubview(buttons)
        status.font = .systemFont(ofSize: 12, weight: .medium)
        root.addArrangedSubview(status)
        telemetry.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        telemetry.isSelectable = true
        root.addArrangedSubview(telemetry)
        advice.font = .systemFont(ofSize: 12); advice.textColor = .secondaryLabelColor
        root.addArrangedSubview(advice)
        for field in [status, telemetry, advice] { field.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -44).isActive = true }
        for picker in [devicePicker, modePicker, profilePicker, screenPicker] { picker.target = self }
        devicePicker.action = #selector(deviceChanged); modePicker.action = #selector(settingsChanged)
        profilePicker.action = #selector(settingsChanged); screenPicker.action = #selector(displayChanged)
        audio.target = self; audio.action = #selector(settingsChanged)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        root.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = root
        root.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        window?.contentView = scroll
    }
    @objc private func refreshDevices() {
        guard !running && !requestingPermission else { return }
        devices = CaptureCardSource.devices(); devicePicker.removeAllItems()
        devicePicker.addItems(withTitles: devices.map(\.localizedName))
        let saved = UserDefaults.standard.string(forKey: "CaptureCard.device")
        if let index = devices.firstIndex(where: { $0.uniqueID == saved }) ?? devices.firstIndex(where: { $0.localizedName.contains("Elgato") }) { devicePicker.selectItem(at: index) }
        refreshScreens(); loadModes()
        status.stringValue = devices.isEmpty ? L("capture.noDevice") : L("capture.ready")
    }
    private func refreshScreens() {
        let selected = screenPicker.indexOfSelectedItem
        screens = NSScreen.screens
        screenPicker.removeAllItems()
        screenPicker.addItems(withTitles: screens.map { "\($0.localizedName) · \(Int(displaySize($0).width))×\(Int(displaySize($0).height)) · \(Int(refreshHz($0))) Hz" })
        if screens.indices.contains(selected) { screenPicker.selectItem(at: selected) }
    }
    private func displaySize(_ screen: NSScreen) -> NSSize {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        if let mode = CGDisplayCopyDisplayMode(id) { return NSSize(width: mode.pixelWidth, height: mode.pixelHeight) }
        return screen.frame.size
    }
    private func refreshHz(_ screen: NSScreen) -> Double {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let hz = CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0
        return hz > 1 ? hz : Double(screen.maximumFramesPerSecond)
    }
    private var selectedScreen: NSScreen? { screens.indices.contains(screenPicker.indexOfSelectedItem) ? screens[screenPicker.indexOfSelectedItem] : NSScreen.main }
    private func loadModes() {
        modes = devices.indices.contains(devicePicker.indexOfSelectedItem) ? CaptureCardMode.list(devices[devicePicker.indexOfSelectedItem]) : []
        modePicker.removeAllItems(); modePicker.addItems(withTitles: modes.map(\.label))
        if let saved = UserDefaults.standard.string(forKey: "CaptureCard.mode"), let index = modes.firstIndex(where: { $0.label == saved }) { modePicker.selectItem(at: index) }
        else { recommend() }
    }
    @objc private func deviceChanged() { stop(); loadModes() }
    @objc private func settingsChanged() { if running || requestingPermission { stop(); status.stringValue = L("capture.changed") } }
    @objc private func displayChanged() { settingsChanged(); moveOutput() }
    @objc private func displaysChanged() { stop(); refreshScreens() }
    @objc private func recommend() {
        settingsChanged()
        let size = selectedScreen.map(displaySize) ?? NSSize(width: 1920, height: 1080)
        if let index = modes.indices.min(by: { a, b in
            func score(_ m: CaptureCardMode) -> Double { CaptureCardPolicy.score(width: m.width, height: m.height, fps: m.fps, compressed: m.compressed, displayWidth: Int(size.width), displayHeight: Int(size.height)) }
            return score(modes[a]) < score(modes[b])
        }) { modePicker.selectItem(at: index) }
        profilePicker.selectItem(at: 0)
    }
    @objc private func toggleCapture() {
        if running || requestingPermission { stop(); return }
        guard devices.indices.contains(devicePicker.indexOfSelectedItem), modes.indices.contains(modePicker.indexOfSelectedItem) else { status.stringValue = L("capture.noDevice"); return }
        requestingPermission = true; generation &+= 1
        let token = generation
        startButton.title = L("capture.stop")
        status.stringValue = L("capture.permission")
        Task {
            let camera = await Self.permission(.video)
            guard generation == token, requestingPermission else { return }
            guard camera else { permissionDenied(); return }
            if audio.state == .on {
                let allowed = await Self.permission(.audio)
                guard generation == token, requestingPermission else { return }
                guard allowed else { permissionDenied(); return }
            }
            requestingPermission = false
            startCapture()
        }
    }
    private static func permission(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }
    private func permissionDenied() { stop(); status.stringValue = L("capture.permission") }
    private func startCapture() {
        let device = devices[devicePicker.indexOfSelectedItem], mode = modes[modePicker.indexOfSelectedItem]
        showOutput()
        generation &+= 1
        processor.adoptSourceGeneration(generation)
        let request = SPLivePlanRequest()
        request.requestID = generation; request.captureSourceKind = .captureCard
        request.engineID = "apple.lowlatency"; request.modelID = "vt.llfi.temporal.1"; request.qualityID = "normal"
        request.interpolationEnabled = profilePicker.indexOfSelectedItem != 2
        request.quality = 1; request.rateKind = .multiplier; request.multiplier = 2
        request.scaleEnabled = false; request.scaleQualityID = "normal"
        request.outputWidth = Int32(mode.width); request.outputHeight = Int32(mode.height)
        request.viewMode = .enhanced; request.captureCapFPS = Int32(mode.fps.rounded())
        request.displayRefreshHz = selectedScreen.map(refreshHz) ?? 60
        request.automaticVideoCadence = false
        processor.update(request)
        processor.setRawCadence(refreshHz: request.displayRefreshHz, captureLimit: request.captureCapFPS, displayID: 0)
        lastStats = [:]; lastReceipt = nil; engineWarning = nil; running = true
        source.start(deviceID: device.uniqueID, mode: mode, generation: generation,
                     thirtyFPS: profilePicker.indexOfSelectedItem == 0, audio: audio.state == .on)
        for (key, value) in [("device", device.uniqueID), ("mode", mode.label)] { UserDefaults.standard.set(value, forKey: "CaptureCard." + key) }
        UserDefaults.standard.set(profilePicker.indexOfSelectedItem, forKey: "CaptureCard.profile")
        UserDefaults.standard.set(audio.state == .on, forKey: "CaptureCard.audio")
        startButton.title = L("capture.stop"); status.stringValue = L("capture.starting")
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in CaptureCardWindow.shared.renderTelemetry() }
        }
    }
    private func stop() {
        generation &+= 1; requestingPermission = false; running = false
        source?.stop(); processor.stop(); monitorTimer?.invalidate(); monitorTimer = nil
        startButton.title = L("capture.start"); status.stringValue = L("capture.stopped")
        lastReceipt = nil; lastStats = [:]; telemetry.stringValue = "—"
    }
    private func received(_ receipt: CaptureCardReceipt) {
        guard running, receipt.generation == generation else { return }
        lastReceipt = receipt; lastReceiptTime = ProcessInfo.processInfo.systemUptime
        if receipt.failed { status.stringValue = receipt.message }
        else if receipt.width > 0 { status.stringValue = engineWarning ?? L("capture.live") }
        if !receipt.running && receipt.failed { stop(); status.stringValue = receipt.message }
        renderTelemetry()
    }
    private func renderTelemetry() {
        preview.refreshVisibilitySnapshot()
        guard running, let r = lastReceipt else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let fresh = now - lastReceiptTime < 2 && !r.failed
        let statsFresh = now - lastStatsTime < 2 && fresh
        func number(_ key: String) -> String {
            guard statsFresh, let n = lastStats[key] as? NSNumber, n.doubleValue >= 0 else { return "—" }
            return String(format: "%.1f", n.doubleValue)
        }
        let usb = fresh ? String(format: "%.2f", r.usbFPS) : "—"
        let admitted = fresh ? String(format: "%.2f", r.admittedFPS) : "—"
        let changed = fresh ? String(format: "%.1f", r.sampledChangeFPS) : "—"
        let width = (lastStats["processingWidth"] as? NSNumber)?.intValue ?? 0
        let height = (lastStats["processingHeight"] as? NSNumber)?.intValue ?? 0
        let link = r.linkGbps.map { String(format: "%.1f Gbit/s", $0) } ?? "—"
        telemetry.stringValue = "USB: \(link)\n\(L("capture.usb")): \(r.width)×\(r.height) · \(r.pixelFormat) · \(usb) FPS\n" +
            "\(L("capture.admitted")): \(admitted) FPS · \(L("capture.changes")): ≈\(changed) /s\n" +
            "\(L("capture.inference")): \(width)×\(height) · \(L("capture.presented")): \(number("overlayPresentedFPS")) FPS\n" +
            "\(L("capture.delay")): \(number("delayMs")) ms · P95: \(number("p95ms")) ms\n" +
            "\(L("capture.drops")): \(r.driverDrops) · \(L("capture.hdmi"))"
        if let mode = modes.indices.contains(modePicker.indexOfSelectedItem) ? modes[modePicker.indexOfSelectedItem] : nil,
           r.width > 0 && (r.width != mode.width || r.height != mode.height) { status.stringValue = L("capture.mismatch") }
    }
    private func showOutput() {
        if outputWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "OpenDuckFrame · " + L("capture.video")
            window.contentView = preview; window.backgroundColor = .black; window.delegate = self
            window.collectionBehavior = [.fullScreenPrimary]; window.isReleasedWhenClosed = false
            outputWindow = window
        }
        moveOutput(); outputWindow?.makeKeyAndOrderFront(nil)
        preview.refreshVisibilitySnapshot()
    }
    private func moveOutput() {
        guard let screen = selectedScreen, let outputWindow, !outputWindow.styleMask.contains(.fullScreen) else { return }
        let bounds = screen.visibleFrame
        outputWindow.setFrame(NSRect(x: bounds.minX + bounds.width*0.08, y: bounds.minY + bounds.height*0.08, width: bounds.width*0.84, height: bounds.height*0.84), display: true)
    }
    @objc private func fullscreen() { if outputWindow == nil { showOutput() }; outputWindow?.toggleFullScreen(nil) }
    @objc private func openElgato() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.elgato.CaptureDeviceUtility") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
        else { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Elgato Capture Device Utility.app")) }
    }
    @objc private func copyReport() {
        let text = "OpenDuckFrame capture card\n" + (devicePicker.titleOfSelectedItem ?? "") + "\nRequested USB: " + (modePicker.titleOfSelectedItem ?? "") + "\n" + (profilePicker.titleOfSelectedItem ?? "") + "\n" + (screenPicker.titleOfSelectedItem ?? "") + "\n" + status.stringValue + "\n" + telemetry.stringValue + "\n" + L("capture.explanation")
        let keys = ["overlayPresentedFPS", "syntheticOK", "frcP95ms", "frcEwmaMs", "captureToModelReadyP95ms", "captureToOutputReadyP95ms", "delayMs", "lateReadyDrops", "deadlineDrops", "pendingExpiredDrops", "queueDrops", "renderDrops", "epochPhysicalSource", "epochPhysicalSynthetic", "firstPresentationFailureLifetime"]
        let metrics = lastStats.filter { keys.contains($0.key) }
        let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        let details = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text + "\n" + details, forType: .string)
    }
    func windowWillClose(_ notification: Notification) { stop(); if notification.object as? NSWindow === window { outputWindow?.orderOut(nil) } }
    func windowDidChangeOcclusionState(_ notification: Notification) { preview.refreshVisibilitySnapshot() }
    func windowDidResize(_ notification: Notification) { preview.refreshVisibilitySnapshot() }
    func windowDidChangeScreen(_ notification: Notification) {
        preview.refreshVisibilitySnapshot()
        if notification.object as? NSWindow === outputWindow, let screen = outputWindow?.screen { processor.updateDisplayRefreshHz(refreshHz(screen)) }
    }
}
