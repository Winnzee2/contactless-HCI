// Native local camera / microphone bridge. Recognition uses Apple's bundled
// Vision models; JSON lines over stdin/stdout connect to the Python coordinator.
import AppKit
import AVFoundation
import Vision
import ScreenCaptureKit
import ApplicationServices
import CoreMedia
import CoreText
import ImageIO
import Darwin

final class JSONOutput {
    static let shared = JSONOutput()
    private let lock = NSLock()
    func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        lock.lock()
        defer { lock.unlock() }
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}
func emit(_ object: [String: Any]) { JSONOutput.shared.send(object) }
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func clamp(_ n: Double, _ low: Double, _ high: Double) -> Double { min(high, max(low, n)) }
func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
func imageDistance(_ a: CGPoint, _ b: CGPoint, size: CGSize) -> Double {
    hypot((a.x - b.x) * size.width, (a.y - b.y) * size.height)
}

// Vision coordinates are normalized, unmirrored, and bottom-left based.
func screenPoint(_ point: CGPoint, bounds: CGRect, margin: Double = 0.15) -> CGPoint {
    let x = clamp((1 - point.x - margin) / (1 - 2 * margin), 0, 1)
    let y = clamp((1 - point.y - margin) / (1 - 2 * margin), 0, 1)
    return CGPoint(x: bounds.minX + x * (bounds.width - 1), y: bounds.minY + y * (bounds.height - 1))
}

struct PinchLatch {
    var released = false
    var pinched = false
    var lastClick = -Double.infinity
    mutating func reset() { released = false; pinched = false }
    mutating func update(ratio: Double, time: Double) -> Bool {
        guard ratio.isFinite else { reset(); return false }
        if ratio >= 0.65 { released = true; pinched = false; return false }
        guard ratio <= 0.35, released, !pinched else { return false }
        pinched = true
        released = false
        guard time - lastClick >= 0.65 else { return false }
        lastClick = time
        return true
    }
}

struct VoiceAction {
    let action: String
    let point: CGPoint?
    let requestID: String
    init?(_ json: [String: Any], bounds: CGRect) {
        guard json["type"] as? String == "voice_action",
              let action = json["action"] as? String,
              ["move_to", "none"].contains(action),
              let id = json["request_id"] as? String, !id.isEmpty, id.count <= 128 else { return nil }
        self.action = action
        self.requestID = id
        if action == "none" { self.point = nil; return }
        guard let x = json["x"] as? NSNumber, let y = json["y"] as? NSNumber,
              CFGetTypeID(x) != CFBooleanGetTypeID(), CFGetTypeID(y) != CFBooleanGetTypeID(),
              x.doubleValue.isFinite, y.doubleValue.isFinite,
              x.doubleValue >= bounds.minX, x.doubleValue < bounds.maxX,
              y.doubleValue >= bounds.minY, y.doubleValue < bounds.maxY else { return nil }
        self.point = CGPoint(x: x.doubleValue, y: y.doubleValue)
    }
}

// Energy-based endpointing only: semantic recognition is handled by Argmax.
struct SpeechClipper {
    var rate: Double
    var preRoll: [Float] = []
    var recording: [Float] = []
    var loudSamples = 0
    var quietSamples = 0
    var requestID: String?
    mutating func reset() -> String? {
        let old = requestID
        preRoll.removeAll(keepingCapacity: true); recording.removeAll(keepingCapacity: true)
        loudSamples = 0; quietSamples = 0; requestID = nil
        return old
    }
    mutating func process(_ samples: [Float]) -> [[String: Any]] {
        guard !samples.isEmpty, rate > 0 else { return [] }
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
        let loud = rms >= 0.018
        var events: [[String: Any]] = []
        if requestID == nil {
            preRoll.append(contentsOf: samples)
            let maximum = Int(rate * 0.25)
            if preRoll.count > maximum { preRoll.removeFirst(preRoll.count - maximum) }
            loudSamples = loud ? loudSamples + samples.count : 0
            if loudSamples >= Int(rate * 0.08) {
                let id = UUID().uuidString
                requestID = id
                recording = preRoll
                preRoll.removeAll(keepingCapacity: true)
                quietSamples = 0
                events.append(["type": "speech_start", "request_id": id])
            }
        } else {
            recording.append(contentsOf: samples)
            quietSamples = loud ? 0 : quietSamples + samples.count
        }
        if let id = requestID, quietSamples >= Int(rate * 0.6) || recording.count >= Int(rate * 8) {
            var pcm = Data(capacity: recording.count * 2)
            for sample in recording.prefix(Int(rate * 8)) {
                var value = Int16(clamp(Double(sample), -1, 1) * 32767).littleEndian
                withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
            }
            events.append(["type": "speech_audio", "request_id": id,
                           "sample_rate": Int(rate), "pcm_base64": pcm.base64EncodedString()])
            _ = reset()
        }
        return events
    }
}

func recognizeTargets(_ image: CGImage, region: CGRect) throws -> [[String: Any]] {
    let textRequest = VNRecognizeTextRequest()
    textRequest.recognitionLevel = .accurate
    textRequest.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"]
    textRequest.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([textRequest])
    var targets: [[String: Any]] = []
    for observation in (textRequest.results ?? []).prefix(64) {
        guard let text = observation.topCandidates(1).first, text.confidence >= 0.3 else { continue }
        let box = observation.boundingBox
        targets.append([
            "id": "target-\(targets.count)", "label": String(text.string.prefix(200)),
            "x": region.minX + box.midX * region.width,
            "y": region.minY + (1 - box.midY) * region.height,
            "width": box.width * region.width, "height": box.height * region.height
        ])
    }
    return targets
}

func captureScreenRegion(_ region: CGRect) async throws -> CGImage {
    let displayID = CGMainDisplayID()
    let screen = CGDisplayBounds(displayID)
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
        throw NSError(domain: "LocalControl", code: 5, userInfo: [NSLocalizedDescriptionKey: "Primary display is unavailable for local text recognition."])
    }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.sourceRect = CGRect(x: region.minX - screen.minX, y: region.minY - screen.minY,
                               width: region.width, height: region.height)
    // Preserve Retina detail so small browser-tab text remains legible to OCR.
    let scale = max(1, Double(filter.pointPixelScale))
    config.width = Int(region.width * scale)
    config.height = Int(region.height * scale)
    config.showsCursor = false
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
}

final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "local.control.audio")
    private var armed = false
    private var clipper = SpeechClipper(rate: 48000)
    private var installed = false
    func setArmed(_ enabled: Bool) {
        queue.async {
            self.armed = enabled
            if let id = self.clipper.reset() { emit(["type": "speech_cancel", "request_id": id]) }
        }
    }
    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "LocalControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."])
        }
        queue.sync { self.clipper = SpeechClipper(rate: format.sampleRate) }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self, let channels = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            var samples = [Float](repeating: 0, count: count)
            for i in 0..<count {
                var value: Float = 0
                for c in 0..<channelCount { value += channels[c][i] }
                samples[i] = value / Float(channelCount)
            }
            self.queue.async {
                guard self.armed else { return }
                for event in self.clipper.process(samples) { emit(event) }
            }
        }
        installed = true
        engine.prepare()
        try engine.start()
        emit(["type": "status", "message": "Microphone ready; voice clips are captured only while enabled."])
    }
    func stop() {
        if installed { engine.inputNode.removeTap(onBus: 0); installed = false }
        engine.stop()
        queue.sync { self.armed = false; _ = self.clipper.reset() }
    }
}

final class HandOverlay: NSView {
    var rawPoint: CGPoint? { didSet { needsDisplay = true } }
    var joints: [VNHumanHandPoseObservation.JointName: CGPoint] = [:] { didSet { needsDisplay = true } }
    var videoSize = CGSize(width: 1280, height: 720)
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let rect = CGRect(x: (bounds.width - videoSize.width * scale) / 2,
                          y: (bounds.height - videoSize.height * scale) / 2,
                          width: videoSize.width * scale, height: videoSize.height * scale)
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let active = rect.insetBy(dx: rect.width * 0.15, dy: rect.height * 0.15)
        let guide = NSBezierPath(rect: active); guide.lineWidth = 1; guide.stroke()
        func location(_ point: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + (1 - point.x) * rect.width,
                    y: rect.minY + (1 - point.y) * rect.height)
        }
        let fingers: [[VNHumanHandPoseObservation.JointName]] = [
            [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
            [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
            [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
            [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
            [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip]
        ]
        NSColor.systemCyan.withAlphaComponent(0.85).setStroke()
        let skeleton = NSBezierPath(); skeleton.lineWidth = 2
        for finger in fingers {
            for i in 1..<finger.count {
                if let a = joints[finger[i - 1]], let b = joints[finger[i]] {
                    skeleton.move(to: location(a)); skeleton.line(to: location(b))
                }
            }
        }
        skeleton.stroke()
        NSColor.systemCyan.setFill()
        for point in joints.values {
            let p = location(point)
            NSBezierPath(ovalIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
        }
        if let point = rawPoint {
            let location = location(point)
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: CGRect(x: location.x - 7, y: location.y - 7, width: 14, height: 14)).fill()
        }
    }
}

final class PreviewView: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    let overlay = HandOverlay(frame: .zero)
    var rawPoint: CGPoint? { get { overlay.rawPoint } set { overlay.rawPoint = newValue } }
    var videoSize: CGSize { get { overlay.videoSize } set { overlay.videoSize = newValue } }
    var joints: [VNHumanHandPoseObservation.JointName: CGPoint] {
        get { overlay.joints }
        set { overlay.joints = newValue }
    }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspect
        layer?.addSublayer(preview)
        overlay.wantsLayer = true
        addSubview(overlay)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); preview.frame = bounds; overlay.frame = bounds }
}

final class ControlWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

final class CameraController: NSObject, NSApplicationDelegate, NSWindowDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    let cameraIndex: Int
    let useVoice: Bool
    let session = AVCaptureSession()
    let sessionQueue = DispatchQueue(label: "local.control.session")
    let frameQueue = DispatchQueue(label: "local.control.vision")
    let request = VNDetectHumanHandPoseRequest()
    let mic = MicrophoneCapture()
    var window: ControlWindow!
    var preview: PreviewView!
    var stateLabel: NSTextField!
    var speechLabel: NSTextField!
    var toggleButton: NSButton!
    var armed = false
    var cameraReady = false
    var closing = false
    var pointer: CGPoint?
    var lastHandTime = -Double.infinity
    var lastFrameTime = -Double.infinity
    var lastPointerEvent = -Double.infinity
    var lastActionTime = -Double.infinity
    var tracked = false
    var leftPinch = PinchLatch()
    var rightPinch = PinchLatch()
    var lastRawPoint: CGPoint?
    var lockedTarget: CGPoint?
    var lockAnchor: CGPoint?
    var seenIDs: [String] = []
    var localMonitor: Any?
    var globalMonitor: Any?
    var watchTimer: Timer?
    var audioStarting = false
    var audioStarted = false
    var captureOutput: AVCaptureVideoDataOutput?
    let screen = CGDisplayBounds(CGMainDisplayID())

    init(cameraIndex: Int, useVoice: Bool) {
        self.cameraIndex = cameraIndex; self.useVoice = useVoice
        super.init()
        request.maximumHandCount = 1
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeWindow()
        installKeyboard()
        readInput()
        emit(["type": "ready", "armed": false, "screen_width": screen.width, "screen_height": screen.height, "screen_x": screen.minX, "screen_y": screen.minY])
        emit(["type": "state", "armed": false])
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if now() - self.lastHandTime > 0.4 { self.loseHand() }
            if self.armed && !AXIsProcessTrusted() { self.setArmed(false) }
        }
        requestCamera()
    }
    func makeWindow() {
        window = ControlWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 650),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Local Control · Hand + Voice"
        window.isRestorable = false
        window.minSize = NSSize(width: 640, height: 480)
        window.delegate = self
        let root = NSView(); root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root
        preview = PreviewView(frame: .zero); preview.translatesAutoresizingMaskIntoConstraints = false
        preview.preview.session = session
        stateLabel = NSTextField(labelWithString: "PAUSED · Starting camera…")
        stateLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        speechLabel = NSTextField(wrappingLabelWithString: useVoice ? "Voice is preparing locally." : "Camera-only mode. Voice capture is off.")
        speechLabel.maximumNumberOfLines = 3
        let hint = NSTextField(wrappingLabelWithString: "Index finger: move pointer · Thumb + middle: left click · Thumb + ring: right click\nSpace: enable/pause · Escape: pause globally · Q: quit this window")
        hint.textColor = .secondaryLabelColor
        toggleButton = NSButton(title: "Enable pointer", target: self, action: #selector(toggle))
        toggleButton.bezelStyle = .rounded
        let quit = NSButton(title: "Quit", target: self, action: #selector(quitPressed))
        quit.bezelStyle = .rounded
        let buttons = NSStackView(views: [toggleButton, quit]); buttons.orientation = .horizontal; buttons.spacing = 12
        let info = NSStackView(views: [stateLabel, speechLabel, hint, buttons])
        info.orientation = .vertical; info.alignment = .leading; info.spacing = 9
        info.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(preview); root.addSubview(info)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: root.topAnchor), preview.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor), preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            info.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 14), info.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            info.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18), info.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func installKeyboard() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.isARepeat { return event }
            if event.keyCode == 53 { self.setArmed(false); return nil }
            if event.keyCode == 49 { self.toggle(); return nil }
            if event.charactersIgnoringModifiers?.lowercased() == "q" { self.shutdown(); return nil }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { DispatchQueue.main.async { self?.setArmed(false) } }
        }
    }
    func requestCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.setupCamera() }
                    else { self?.report("Camera access denied. Enable Local Control or your terminal in System Settings → Privacy & Security → Camera.") }
                }
            }
        default: report("Camera permission is unavailable. Enable it in System Settings → Privacy & Security → Camera, then restart.")
        }
    }
    func setupCamera() {
        sessionQueue.async {
            do {
                let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
                guard devices.indices.contains(self.cameraIndex) else {
                    throw NSError(domain: "LocalControl", code: 2, userInfo: [NSLocalizedDescriptionKey: "Camera index \(self.cameraIndex) is unavailable; detected \(devices.count) camera(s)."])
                }
                let input = try AVCaptureDeviceInput(device: devices[self.cameraIndex])
                self.session.beginConfiguration()
                if self.session.canSetSessionPreset(.hd1280x720) { self.session.sessionPreset = .hd1280x720 }
                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    throw NSError(domain: "LocalControl", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot attach the selected camera."])
                }
                self.session.addInput(input)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.setSampleBufferDelegate(self, queue: self.frameQueue)
                guard self.session.canAddOutput(output) else {
                    self.session.commitConfiguration()
                    throw NSError(domain: "LocalControl", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot attach camera frame output."])
                }
                self.session.addOutput(output)
                if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
                self.captureOutput = output
                self.session.commitConfiguration()
                self.session.startRunning()
                DispatchQueue.main.async {
                    if let connection = self.preview.preview.connection, connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = true
                    }
                    self.cameraReady = true
                    self.stateLabel.stringValue = "PAUSED · Camera ready · Enable pointer to start"
                    emit(["type": "camera_ready", "name": devices[self.cameraIndex].localizedName])
                    if self.useVoice { self.requestMicrophone() }
                }
            } catch { DispatchQueue.main.async { self.report(error.localizedDescription) } }
        }
    }
    func requestMicrophone() {
        guard !audioStarting, !audioStarted else { return }
        audioStarting = true
        func complete(_ allowed: Bool) {
            DispatchQueue.main.async {
                self.audioStarting = false
                guard !self.closing else { return }
                guard allowed else { self.report("Microphone access denied. Gesture control remains available."); return }
                do {
                    try self.mic.start()
                    self.audioStarted = true
                    self.mic.setArmed(self.armed && self.tracked)
                    self.refreshVoiceHint()
                } catch { self.report("Microphone unavailable: \(error.localizedDescription)") }
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: complete(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio, completionHandler: complete)
        default: complete(false)
        }
    }
    @objc func toggle() { setArmed(!armed) }
    @objc func quitPressed() { shutdown() }
    func setArmed(_ value: Bool) {
        guard !closing else { return }
        if value {
            guard cameraReady else { report("Wait for camera access before enabling pointer control."); return }
            guard AXIsProcessTrusted() else {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                report("Allow Accessibility for Local Control or your terminal in System Settings, then enable pointer again.")
                return
            }
        }
        armed = value
        leftPinch.reset(); rightPinch.reset()
        lockedTarget = nil; lockAnchor = nil
        mic.setArmed(value && tracked)
        stateLabel.stringValue = value ? "ENABLED · Index finger moves pointer · Escape pauses" : "PAUSED · Pointer and speech actions are disabled"
        toggleButton.title = value ? "Pause pointer" : "Enable pointer"
        refreshVoiceHint()
        emit(["type": "state", "armed": value])
    }
    func refreshVoiceHint() {
        if !useVoice {
            speechLabel.stringValue = "Camera-only mode. Voice capture is off."
        } else if !audioStarted {
            speechLabel.stringValue = audioStarting ? "Microphone is preparing locally." : "Microphone is not ready. Gesture control remains available."
        } else if armed {
            speechLabel.stringValue = "Keep your hand visible, point near a label, then say its name. Voice moves the pointer; gestures click."
        } else {
            speechLabel.stringValue = "Voice is paused. Enable pointer, show your hand, then say a visible label."
        }
    }
    func report(_ message: String) {
        speechLabel.stringValue = message
        emit(["type": "error", "message": message])
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = now()
        guard time - lastFrameTime >= 0.05 else { return }
        lastFrameTime = time
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:]).perform([request])
            guard let hand = request.results?.first else { DispatchQueue.main.async { self.loseHand() }; return }
            let points = try hand.recognizedPoints(.all)
            guard let index = points[.indexTip], let thumb = points[.thumbTip], let wrist = points[.wrist], let middle = points[.middleMCP], let middleTip = points[.middleTip], let ringTip = points[.ringTip],
                  [index, thumb, wrist, middle, middleTip, ringTip].allSatisfy({ $0.confidence >= 0.35 }) else {
                DispatchQueue.main.async { self.loseHand() }; return
            }
            let palm = imageDistance(wrist.location, middle.location, size: size)
            guard palm > 0.015 * size.height else { DispatchQueue.main.async { self.loseHand() }; return }
            let leftRatio = imageDistance(middleTip.location, thumb.location, size: size) / palm
            let rightRatio = imageDistance(ringTip.location, thumb.location, size: size) / palm
            let visibleJoints = points.filter { $0.value.confidence >= 0.35 }.mapValues { $0.location }
            DispatchQueue.main.async { self.observe(index.location, leftRatio: leftRatio, rightRatio: rightRatio, time: time, videoSize: size, joints: visibleJoints) }
        } catch {
            DispatchQueue.main.async {
                self.loseHand()
                self.speechLabel.stringValue = "Hand tracking unavailable: \(error.localizedDescription)"
            }
        }
    }
    func observe(_ raw: CGPoint, leftRatio: Double, rightRatio: Double, time: Double, videoSize: CGSize,
                 joints: [VNHumanHandPoseObservation.JointName: CGPoint]) {
        guard !closing, now() - time < 0.4 else { return }
        let regainedHand = !tracked
        tracked = true; lastHandTime = time
        if regainedHand && armed { mic.setArmed(true) }
        preview.videoSize = videoSize; preview.rawPoint = raw; preview.joints = joints
        lastRawPoint = raw
        if let anchor = lockAnchor, distance(raw, anchor) > 0.07 { lockedTarget = nil; lockAnchor = nil }
        let target = screenPoint(raw, bounds: screen)
        if let locked = lockedTarget { pointer = locked }
        else if let old = pointer { pointer = CGPoint(x: old.x + 0.28 * (target.x - old.x), y: old.y + 0.28 * (target.y - old.y)) }
        else { pointer = target }
        guard let point = pointer else { return }
        if time - lastPointerEvent > 0.05 {
            emit(["type": "pointer", "x": point.x, "y": point.y, "tracked": true])
            lastPointerEvent = time
        }
        guard armed else { return }
        guard AXIsProcessTrusted() else { setArmed(false); return }
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        let leftEdge = leftPinch.update(ratio: leftRatio, time: time)
        let rightEdge = rightPinch.update(ratio: rightRatio, time: time)
        // If both fingertips are close, treat the pose as ambiguous and click neither.
        if leftEdge && rightRatio > 0.45 { click("click", at: point) }
        else if rightEdge && leftRatio > 0.45 { click("right_click", at: point) }
    }
    func loseHand() {
        preview.rawPoint = nil; preview.joints = [:]
        if tracked { mic.setArmed(false) }
        leftPinch.reset(); rightPinch.reset()
        lockedTarget = nil; lockAnchor = nil; lastRawPoint = nil
        pointer = nil
        if tracked {
            emit(["type": "pointer", "tracked": false, "x": 0, "y": 0])
            tracked = false
        }
    }
    func click(_ action: String, at point: CGPoint) {
        guard armed, tracked, now() - lastHandTime <= 0.4, AXIsProcessTrusted(), now() - lastActionTime >= 0.5 else { return }
        let button: CGMouseButton = action == "right_click" ? .right : .left
        let down: CGEventType = action == "right_click" ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = action == "right_click" ? .rightMouseUp : .leftMouseUp
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
        for count in 1...1 {
            let press = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: point, mouseButton: button)
            let release = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: point, mouseButton: button)
            press?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            release?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
            press?.post(tap: .cghidEventTap); release?.post(tap: .cghidEventTap)
        }
        lastActionTime = now()
        emit(["type": "action", "action": action, "source": "gesture", "x": point.x, "y": point.y])
        lockedTarget = nil; lockAnchor = nil
    }
    func readInput() {
        DispatchQueue.global(qos: .utility).async {
            while let line = readLine() {
                guard let data = line.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                DispatchQueue.main.async { self.handleInput(json) }
            }
            DispatchQueue.main.async { self.shutdown() }
        }
    }
    func handleInput(_ json: [String: Any]) {
        guard !closing else { return }
        if json["type"] as? String == "status", let message = json["message"] as? String {
            if json["important"] as? Bool == true || (armed && useVoice && audioStarted) { speechLabel.stringValue = String(message.prefix(400)) }
            else { refreshVoiceHint() }
            return
        }
        if json["type"] as? String == "capture_targets" {
            captureTargets(json)
            return
        }
        guard let instruction = VoiceAction(json, bounds: screen) else {
            emit(["type": "error", "message": "Rejected invalid native control message."]); return
        }
        guard !seenIDs.contains(instruction.requestID) else { return }
        seenIDs.append(instruction.requestID)
        if seenIDs.count > 128 { seenIDs.removeFirst() }
        if instruction.action == "none" { return }
        guard let point = instruction.point else { return }
        guard armed, tracked, now() - lastHandTime <= 0.4, AXIsProcessTrusted() else { return }
        lockedTarget = point; lockAnchor = lastRawPoint; pointer = point
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        emit(["type": "pointer", "x": point.x, "y": point.y, "tracked": true])
        emit(["type": "action", "action": "move_to", "source": "voice", "x": point.x, "y": point.y, "request_id": instruction.requestID])
    }
    func captureTargets(_ json: [String: Any]) {
        let id = (json["request_id"] as? String) ?? ""
        func fail(_ message: String) {
            speechLabel.stringValue = message
            emit(["type": "error", "request_id": id, "message": message])
        }
        guard !id.isEmpty, id.count <= 128, armed, tracked,
              let x = json["x"] as? NSNumber, let y = json["y"] as? NSNumber,
              CFGetTypeID(x) != CFBooleanGetTypeID(), CFGetTypeID(y) != CFBooleanGetTypeID(),
              x.doubleValue.isFinite, y.doubleValue.isFinite,
              screen.contains(CGPoint(x: x.doubleValue, y: y.doubleValue)) else {
            fail("No current hand target is available for local text lookup."); return
        }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            fail("Allow Screen Recording for Local Control or your terminal in System Settings, then restart to use voice targeting.")
            return
        }
        let requestedWidth = (json["width"] as? NSNumber)?.doubleValue ?? 640
        let requestedHeight = (json["height"] as? NSNumber)?.doubleValue ?? 400
        guard requestedWidth.isFinite, requestedHeight.isFinite else { fail("Invalid screenshot region."); return }
        let width = min(screen.width, clamp(requestedWidth, 100, 1000))
        let height = min(screen.height, clamp(requestedHeight, 100, 800))
        let region = CGRect(x: clamp(x.doubleValue - width / 2, screen.minX, screen.maxX - width),
                            y: clamp(y.doubleValue - height / 2, screen.minY, screen.maxY - height),
                            width: width, height: height)
        Task {
            do {
                let image = try await captureScreenRegion(region)
                // OCR runs on a separate queue; only text and bounding boxes leave this helper.
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let targets = try recognizeTargets(image, region: region)
                        emit(["type": "targets", "request_id": id, "targets": targets,
                              "region": ["x": region.minX, "y": region.minY, "width": region.width, "height": region.height]])
                    } catch { emit(["type": "error", "request_id": id, "message": "Local OCR failed: \(error.localizedDescription)"]) }
                }
            } catch {
                emit(["type": "error", "request_id": id, "message": "Local screen capture failed: \(error.localizedDescription)"])
            }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { shutdown(); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !closing { shutdown(); return .terminateCancel }
        return .terminateNow
    }
    func shutdown() {
        guard !closing else { return }
        setArmed(false); closing = true
        watchTimer?.invalidate()
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        mic.stop()
        sessionQueue.async {
            self.captureOutput?.setSampleBufferDelegate(nil, queue: nil)
            self.session.stopRunning()
            DispatchQueue.main.async {
                emit(["type": "exit"])
                NSApp.terminate(nil)
            }
        }
    }
}

func authorizationName(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "not_determined"
    @unknown default: return "unknown"
    }
}
func selfTest() -> Bool {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
    var tests = 0
    func check(_ okay: Bool, _ message: String) {
        tests += 1
        if !okay { fputs("Self-test failed: \(message)\n", stderr); exit(1) }
    }
    check(screenPoint(CGPoint(x: 0.5, y: 0.5), bounds: bounds) == CGPoint(x: 499.5, y: 249.5), "center maps to screen center")
    check(screenPoint(CGPoint(x: 1, y: 1), bounds: bounds) == .zero, "mirrored top-left clamps")
    check(screenPoint(CGPoint(x: 0, y: 0), bounds: bounds) == CGPoint(x: 999, y: 499), "bottom-right clamps")
    let video = CGSize(width: 1280, height: 720)
    check(abs(imageDistance(.zero, CGPoint(x: 0.1, y: 0), size: video) - 128) < 0.001, "pinch horizontal geometry uses pixels")
    check(abs(imageDistance(.zero, CGPoint(x: 0, y: 0.1), size: video) - 72) < 0.001, "pinch vertical geometry uses pixels")
    var pinch = PinchLatch()
    check(!pinch.update(ratio: 0.1, time: 1), "pinched on arm does not click")
    check(!pinch.update(ratio: 0.8, time: 2), "release readies latch")
    check(pinch.update(ratio: 0.1, time: 3), "press clicks once")
    check(!pinch.update(ratio: 0.1, time: 4), "held pinch does not repeat")
    pinch.reset()
    check(!pinch.update(ratio: 0.1, time: 5), "hand loss requires release")
    var json: [String: Any] = ["type": "voice_action", "request_id": "abc", "action": "move_to", "x": 20, "y": 20]
    check(VoiceAction(json, bounds: bounds) != nil, "valid move")
    json["x"] = -1
    check(VoiceAction(json, bounds: bounds) == nil, "out-of-screen target rejected")
    json["x"] = true
    check(VoiceAction(json, bounds: bounds) == nil, "boolean coordinate rejected")
    json["action"] = "click"
    check(VoiceAction(json, bounds: bounds) == nil, "voice click rejected")
    var clipper = SpeechClipper(rate: 1000)
    check(clipper.process([Float](repeating: 0, count: 200)).isEmpty, "silence emits no clip")
    let start = clipper.process([Float](repeating: 0.2, count: 100))
    check(start.count == 1 && start.first?["type"] as? String == "speech_start", "speech begins")
    let audio = clipper.process([Float](repeating: 0, count: 600))
    check(audio.count == 1 && audio.first?["type"] as? String == "speech_audio", "silence ends clip")
    check(clipper.requestID == nil && clipper.recording.isEmpty, "clip state resets")
    emit(["type": "self_test", "passed": true, "tests": tests])
    return true
}

func ocrSelfTest() throws {
    let size = CGSize(width: 640, height: 180)
    guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "LocalControl", code: 6, userInfo: [NSLocalizedDescriptionKey: "Cannot allocate OCR test image."])
    }
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(origin: .zero, size: size))
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 32, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
    ]
    for (index, label) in ["Codex", "Safari", "Finder"].enumerated() {
        let text = NSAttributedString(string: label, attributes: attributes)
        context.textPosition = CGPoint(x: 30 + index * 210, y: 75)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
    }
    guard let image = context.makeImage() else { throw NSError(domain: "LocalControl", code: 7) }
    let targets = try recognizeTargets(image, region: CGRect(origin: CGPoint(x: 100, y: 200), size: size))
    guard targets.contains(where: { ($0["label"] as? String)?.lowercased().contains("codex") == true }) else {
        throw NSError(domain: "LocalControl", code: 8, userInfo: [NSLocalizedDescriptionKey: "OCR did not recognize the generated Codex label."])
    }
    emit(["type": "ocr_self_test", "passed": true, "targets": targets])
}

// Hardware checks deliberately avoid moving the cursor or injecting clicks.
final class CameraProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let frameQueue = DispatchQueue(label: "local.control.camera.probe")
    let done = DispatchSemaphore(value: 0)
    var frameCount = 0
    var handFrames = 0
    var visionFailures = 0
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCount += 1
        if frameCount % 6 == 0, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            do {
                let request = VNDetectHumanHandPoseRequest(); request.maximumHandCount = 1
                try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:]).perform([request])
                if !(request.results ?? []).isEmpty { handFrames += 1 }
            } catch { visionFailures += 1 }
        }
        if frameCount == 30 { done.signal() }
    }
}

func cameraSelfTest(index: Int) throws {
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
        throw NSError(domain: "LocalControl", code: 10, userInfo: [NSLocalizedDescriptionKey: "Camera permission is required before the hardware check."])
    }
    let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
    guard devices.indices.contains(index) else {
        throw NSError(domain: "LocalControl", code: 11, userInfo: [NSLocalizedDescriptionKey: "Selected camera is unavailable."])
    }
    let session = AVCaptureSession()
    let input = try AVCaptureDeviceInput(device: devices[index])
    let output = AVCaptureVideoDataOutput()
    let probe = CameraProbe()
    output.alwaysDiscardsLateVideoFrames = true
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    output.setSampleBufferDelegate(probe, queue: probe.frameQueue)
    session.beginConfiguration()
    if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
    guard session.canAddInput(input), session.canAddOutput(output) else {
        session.commitConfiguration()
        throw NSError(domain: "LocalControl", code: 12, userInfo: [NSLocalizedDescriptionKey: "Camera test could not create a capture session."])
    }
    session.addInput(input); session.addOutput(output); session.commitConfiguration()
    let sessionQueue = DispatchQueue(label: "local.control.camera.probe.session")
    sessionQueue.sync { session.startRunning() }
    _ = probe.done.wait(timeout: .now() + 8)
    sessionQueue.sync { session.stopRunning() }
    output.setSampleBufferDelegate(nil, queue: nil)
    let result: [String: Any] = probe.frameQueue.sync {
        ["type": "camera_self_test", "passed": probe.frameCount > 0 && probe.visionFailures == 0,
         "camera": devices[index].localizedName, "frames": probe.frameCount,
         "hand_frames": probe.handFrames, "vision_failures": probe.visionFailures,
         "mouse_events": 0]
    }
    emit(result)
    if result["passed"] as? Bool != true {
        throw NSError(domain: "LocalControl", code: 13, userInfo: [NSLocalizedDescriptionKey: "No usable camera frames or local hand inference failed."])
    }
}

func screenSelfTest(outputURL: URL? = nil) async throws {
    guard CGPreflightScreenCaptureAccess() else {
        throw NSError(domain: "LocalControl", code: 14, userInfo: [NSLocalizedDescriptionKey: "Screen Recording permission is required before the screen check."])
    }
    let screen = CGDisplayBounds(CGMainDisplayID())
    let point = CGEvent(source: nil)?.location ?? CGPoint(x: screen.midX, y: screen.midY)
    let width = min(720, screen.width), height = min(420, screen.height)
    let region = CGRect(x: clamp(point.x - width / 2, screen.minX, screen.maxX - width),
                        y: clamp(point.y - height / 2, screen.minY, screen.maxY - height),
                        width: width, height: height)
    let image = try await captureScreenRegion(region)
    if let outputURL {
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "LocalControl", code: 15, userInfo: [NSLocalizedDescriptionKey: "Cannot create screen diagnostic PNG."])
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "LocalControl", code: 16, userInfo: [NSLocalizedDescriptionKey: "Cannot save screen diagnostic PNG."])
        }
    }
    let targets = try recognizeTargets(image, region: region)
    emit(["type": "screen_self_test", "passed": true, "mouse_events": 0,
          "image_width": image.width, "image_height": image.height, "targets": targets,
          "region": ["x": region.minX, "y": region.minY, "width": region.width, "height": region.height]])
}

signal(SIGPIPE, SIG_IGN)
let arguments = Array(CommandLine.arguments.dropFirst())
var cameraIndex = 0
if let index = arguments.firstIndex(of: "--camera") {
    guard arguments.indices.contains(index + 1), let number = Int(arguments[index + 1]), number >= 0 else {
        fputs("--camera requires a non-negative camera index\n", stderr); exit(2)
    }
    cameraIndex = number
}
if arguments.contains("--self-test") { _ = selfTest(); exit(0) }
if arguments.contains("--ocr-self-test") {
    do { try ocrSelfTest(); exit(0) }
    catch { emit(["type": "error", "message": error.localizedDescription]); exit(1) }
}
if arguments.contains("--camera-self-test") {
    do { try cameraSelfTest(index: cameraIndex); exit(0) }
    catch { emit(["type": "error", "message": error.localizedDescription]); exit(1) }
}
if arguments.contains("--screen-self-test") {
    var outputURL: URL?
    if let index = arguments.firstIndex(of: "--capture-output") {
        guard arguments.indices.contains(index + 1) else { fputs("--capture-output needs a PNG path\n", stderr); exit(2) }
        outputURL = URL(fileURLWithPath: arguments[index + 1])
    }
    Task {
        do { try await screenSelfTest(outputURL: outputURL); exit(0) }
        catch { emit(["type": "error", "message": error.localizedDescription]); exit(1) }
    }
    RunLoop.main.run()
    exit(1)
}
if arguments.contains("--check") {
    let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
    emit(["type": "check", "camera_authorization": authorizationName(AVCaptureDevice.authorizationStatus(for: .video)),
          "microphone_authorization": authorizationName(AVCaptureDevice.authorizationStatus(for: .audio)),
          "accessibility": AXIsProcessTrusted(), "screen_recording": CGPreflightScreenCaptureAccess(), "camera_count": devices.count,
          "cameras": devices.enumerated().map { ["index": $0.offset, "name": $0.element.localizedName] }])
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = CameraController(cameraIndex: cameraIndex, useVoice: arguments.contains("--voice"))
app.delegate = delegate
let menu = NSMenu()
let item = NSMenuItem()
let submenu = NSMenu()
submenu.addItem(withTitle: "Quit Local Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
app.run()
