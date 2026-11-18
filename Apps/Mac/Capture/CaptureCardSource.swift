@preconcurrency import AVFoundation
import CoreVideo
import Darwin

struct CaptureCardMode: @unchecked Sendable {
    let format: AVCaptureDevice.Format
    let duration: CMTime
    let width: Int
    let height: Int
    let subtype: FourCharCode
    var fps: Double { 1 / duration.seconds }
    var compressed: Bool { subtype == kCMVideoCodecType_JPEG || subtype == kCMVideoCodecType_H264 }
    var label: String { "\(width)×\(height) · \(String(format: "%.2f", fps)) Hz · \(Self.fourCC(subtype))" }
    static func fourCC(_ code: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 255) }, encoding: .ascii) ?? "\(code)"
    }
    static func list(_ device: AVCaptureDevice) -> [CaptureCardMode] {
        var seen = Set<String>()
        return device.formats.flatMap { format -> [CaptureCardMode] in
            let description = format.formatDescription
            let size = CMVideoFormatDescriptionGetDimensions(description)
            let subtype = CMFormatDescriptionGetMediaSubType(description)
            return format.videoSupportedFrameRateRanges.flatMap { range -> [CaptureCardMode] in
                var durations = [range.minFrameDuration, range.maxFrameDuration]
                for fps in [30.0, 60.0, 120.0, 30_000.0/1_001, 60_000.0/1_001] where fps >= range.minFrameRate && fps <= range.maxFrameRate {
                    durations.append(CMTime(seconds: 1/fps, preferredTimescale: 60_000))
                }
                return durations.compactMap { duration in
                    let mode = CaptureCardMode(format: format, duration: duration, width: Int(size.width), height: Int(size.height), subtype: subtype)
                    guard mode.fps <= 120.1, mode.fps >= 24, seen.insert(mode.label).inserted else { return nil }
                    return mode
                }
            }
        }.sorted { $0.width != $1.width ? $0.width > $1.width : $0.fps > $1.fps }
    }
}

struct CaptureCardReceipt: Sendable {
    var generation: UInt64
    var width = 0
    var height = 0
    var pixelFormat = ""
    var usbFPS = 0.0
    var linkGbps: Double?
    var admittedFPS = 0.0
    var sampledChangeFPS = 0.0
    var driverDrops = 0
    var message = ""
    var failed = false
    var running = false
}

/// Session and delegate state have exactly one owner: queue. No frame is copied
/// through OBS/ScreenCaptureKit, and the processor retains the CVPixelBuffer lease.
final class CaptureCardSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.openduckframe.capture-card", qos: .userInteractive)
    private let processor: SPLiveProcessor
    private let receipt: @Sendable (CaptureCardReceipt) -> Void
    private var session: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var previousPTS: Double?
    private var observers: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private var generation: UInt64 = 0
    private var gate = CaptureCardRateGate()
    private var selectedSourceFPS: Double?
    private var begin = 0.0
    private var lastFrame = 0.0
    private var frames = 0, admitted = 0, changes = 0, drops = 0
    private var previousSample: [UInt8]?
    private var lastReceipt = CaptureCardReceipt(generation: 0)
    init(processor: SPLiveProcessor, receipt: @escaping @Sendable (CaptureCardReceipt) -> Void) {
        self.processor = processor; self.receipt = receipt
    }
    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
    }
    func start(deviceID: String, mode: CaptureCardMode, generation: UInt64, thirtyFPS: Bool, audio: Bool) {
        queue.async { [self] in
            stopOnQueue()
            self.generation = generation
            lastReceipt = CaptureCardReceipt(generation: generation)
            guard let device = Self.devices().first(where: { $0.uniqueID == deviceID }) else {
                fail("Capture card disconnected."); return
            }
            lastReceipt.linkGbps = CaptureCardUSB.linkGbps(deviceName: device.localizedName)
            do {
                let session = AVCaptureSession()
                session.beginConfiguration()
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw failure("Capture input unavailable. Close OBS or Elgato Studio and retry.") }
                session.addInput(input)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                guard session.canAddOutput(output) else { throw failure("Video output unavailable.") }
                session.addOutput(output)
                try device.lockForConfiguration()
                device.activeFormat = mode.format
                device.activeVideoMinFrameDuration = mode.duration
                device.activeVideoMaxFrameDuration = mode.duration
                device.unlockForConfiguration()
                // NV12 avoids a 4K BGRA copy at the capture boundary. Conversion
                // and restored inference sizing stay in the existing processor.
                let preferred = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                let type = output.availableVideoPixelFormatTypes.contains(preferred) ? preferred : kCVPixelFormatType_32BGRA
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: type]
                output.setSampleBufferDelegate(self, queue: queue)
                var audioNote = ""
                if audio {
                    let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
                    // Never substitute the user's microphone for HDMI audio.
                    if let audioDevice = devices.first(where: { $0.uniqueID == device.uniqueID || $0.localizedName == device.localizedName || ($0.localizedName.contains("Elgato") && device.localizedName.contains("Elgato")) }) {
                        let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                        let audioOutput = AVCaptureAudioPreviewOutput()
                        if session.canAddInput(audioInput) { session.addInput(audioInput) }
                        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput); audioOutput.volume = 1 }
                        else { audioNote = " HDMI audio unavailable." }
                    } else { audioNote = " HDMI audio device not found; microphone is not used." }
                }
                session.commitConfiguration()
                self.session = session; self.videoOutput = output; previousPTS = nil
                gate = CaptureCardRateGate(); previousSample = nil
                selectedSourceFPS = CaptureCardPolicy.sourceFPS(captureFPS: mode.fps, thirtyFPS: thirtyFPS)
                frames = 0; admitted = 0; changes = 0; drops = 0
                begin = ProcessInfo.processInfo.systemUptime; lastFrame = begin
                for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification, AVCaptureDevice.wasDisconnectedNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: name == AVCaptureDevice.wasDisconnectedNotification ? device : session, queue: nil) { [weak self] notification in
                        let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "Capture interrupted or disconnected. Reconnect and press Start."
                        self?.queue.async { [weak self] in self?.fail(message); self?.stopOnQueue() }
                    })
                }
                session.startRunning()
                lastReceipt.running = session.isRunning
                lastReceipt.message = "\(mode.label).\(audioNote)"
                receipt(lastReceipt)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler { [weak self] in self?.publish() }
                self.timer = timer; timer.resume()
            } catch { fail(error.localizedDescription); stopOnQueue() }
        }
    }
    func stop() { queue.async { [self] in stopOnQueue() } }
    private func stopOnQueue() {
        timer?.cancel(); timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll()
        videoOutput = nil; session?.stopRunning(); session = nil; previousSample = nil; previousPTS = nil
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "CaptureCard", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func fail(_ message: String) { lastReceipt.failed = true; lastReceipt.running = false; lastReceipt.message = message; receipt(lastReceipt) }
    private func publish() {
        let now = ProcessInfo.processInfo.systemUptime, elapsed = now - begin
        guard elapsed > 0 else { return }
        lastReceipt.usbFPS = Double(frames)/elapsed
        lastReceipt.admittedFPS = Double(admitted)/elapsed
        lastReceipt.sampledChangeFPS = Double(changes)/elapsed
        lastReceipt.driverDrops = drops
        if now - lastFrame > 2 {
            lastReceipt.message = "No video frames for 2 seconds. Check HDMI, HDCP, USB and other capture apps."
            lastReceipt.failed = true
        }
        receipt(lastReceipt)
        begin = now; frames = 0; admitted = 0; changes = 0
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { drops += 1 }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let host = Int64(mach_absolute_time())
        guard output === videoOutput, session?.isRunning == true, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isNumeric else { return }
        if let previousPTS, pts.seconds <= previousPTS || pts.seconds - previousPTS > 0.5 {
            fail("Capture clock changed. Press Start to establish a new session."); stopOnQueue(); return
        }
        previousPTS = pts.seconds
        lastFrame = ProcessInfo.processInfo.systemUptime
        lastReceipt.failed = false
        lastReceipt.width = CVPixelBufferGetWidth(buffer); lastReceipt.height = CVPixelBufferGetHeight(buffer)
        lastReceipt.pixelFormat = CaptureCardMode.fourCC(CVPixelBufferGetPixelFormatType(buffer))
        frames += 1
        let sample = fingerprint(buffer)
        if let previousSample, zip(sample, previousSample).reduce(0, { $0 + abs(Int($1.0) - Int($1.1)) }) > sample.count { changes += 1 }
        previousSample = sample
        // Observe all delivered USB frames; selected 30 fps admission is separate.
        processor.noteRawCapture(ptsNum: pts.value, ptsDen: Int64(pts.timescale), host: host, width: Int32(lastReceipt.width), height: Int32(lastReceipt.height), generation: generation)
        guard gate.accepts(pts.seconds, sourceFPS: selectedSourceFPS) else { return }
        admitted += 1
        processor.push(buffer, ptsNum: pts.value, ptsDen: Int64(pts.timescale), host: host, generation: generation)
    }
    private func fingerprint(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(buffer)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let p = base.assumingMemoryBound(to: UInt8.self)
        return (0..<192).map { i in
            let x = (i % 16 + 1) * w / 17, y = (i / 16 + 1) * h / 13
            return p[y * stride + x * (planar ? 1 : 4) + (planar ? 0 : 1)]
        }
    }
}
