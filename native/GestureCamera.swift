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

struct TargetLock {
    private var target: CGPoint?
    private var anchor: CGPoint?
    private var protectedUntil = -Double.infinity

    mutating func hold(_ point: CGPoint, anchor: CGPoint, time: Double) {
        target = point
        self.anchor = anchor
        protectedUntil = time + 3
    }
    mutating func clear() {
        target = nil
        anchor = nil
        protectedUntil = -Double.infinity
    }
    mutating func resolve(hand: CGPoint, time: Double) -> CGPoint? {
        // Allow time to form a click gesture without the index finger pulling
        // the pointer away from the voice-selected target.
        if time >= protectedUntil, let anchor = anchor, distance(hand, anchor) > 0.07 { clear() }
        return target
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
    try recognizeScreenTextTargets(image, region: region)
}

// Both the application and diagnostics use this same read-only discovery path.
// AX labels cover native controls and named icons; local OCR fills remaining gaps.
func discoverTargets(region: CGRect, pointer: CGPoint) async -> [[String: Any]] {
    var image: CGImage?
    if CGPreflightScreenCaptureAccess() { image = try? await captureScreenRegion(region) }
    let capturedImage = image
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: collectScreenTargets(image: capturedImage, region: region, pointer: pointer))
        }
    }
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

private struct TargetCapture {
    let targets: [[String: Any]]
    let region: CGRect
    let pointer: CGPoint
    let foregroundPID: pid_t?
    let generation: Int
    let capturedAt: TimeInterval
    let choiceID: String?
    let choiceDeadline: TimeInterval?
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
    var leftPinch = HoldPinchLatch()
    var rightPinch = PinchLatch()
    var fistOpen = FistOpenLatch()
    var pinchPoint: CGPoint?
    var gestureBusy = false
    var missionControlTransition = MissionControlTransition()
    var lastRawPoint: CGPoint?
    var targetLock = TargetLock()
    let targetOverlay = TargetOverlay()
    let duplicateOverlay = DuplicateTargetOverlay()
    private var targetCaptures: [String: TargetCapture] = [:]
    private var latestCaptureID: String?
    private var contextGeneration = 0
    private var contextObservers: [NSObjectProtocol] = []
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
            self.targetOverlay.refresh(now: now())
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
        let hint = NSTextField(wrappingLabelWithString: "Index: move · Thumb + middle: release to click, hold 0.7s to double-click · Thumb + ring: right click\nFist, then open hand: show windows · Space: enable/pause · Escape: pause · Q: quit")
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
        let contextEvents: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: contextEvents) { [weak self] event in
            guard let self = self else { return event }
            self.invalidateTargetContext()
            guard event.type == .keyDown else { return event }
            if event.isARepeat { return event }
            if event.keyCode == 53 { self.setArmed(false); return nil }
            if event.keyCode == 49 { self.toggle(); return nil }
            if event.charactersIgnoringModifiers?.lowercased() == "q" { self.shutdown(); return nil }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: contextEvents) { [weak self] event in
            self?.invalidateTargetContext()
            if event.type == .keyDown && event.keyCode == 53 { self?.setArmed(false) }
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            contextObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.invalidateTargetContext()
            })
        }
    }
    func invalidateTargetContext() {
        contextGeneration += 1
        targetCaptures.removeAll()
        latestCaptureID = nil
        if let id = duplicateOverlay.choiceID {
            duplicateOverlay.hide()
            emit(["type": "choices_cancel", "choice_id": id])
        }
    }
    private func currentCapture(_ id: String) -> TargetCapture? {
        guard id == latestCaptureID, let capture = targetCaptures[id], capture.generation == contextGeneration,
              now() - capture.capturedAt <= 20,
              capture.foregroundPID == NSWorkspace.shared.frontmostApplication?.processIdentifier,
              capture.choiceDeadline.map({ now() < $0 }) ?? true else { return nil }
        return capture
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
        fistOpen.reset(); pinchPoint = nil; gestureBusy = false
        missionControlTransition.cancel()
        targetLock.clear()
        targetOverlay.hide()
        invalidateTargetContext()
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
    func setGestureBusy(_ busy: Bool) {
        guard busy != gestureBusy else { return }
        gestureBusy = busy
        mic.setArmed(armed && tracked && !busy)
        if busy {
            invalidateTargetContext()
            emit(["type": "gesture_cancel", "source": "gesture"])
        }
    }
    var acceptsVoiceTarget: Bool {
        !gestureBusy && !missionControlTransition.blocksInput(time: now()) && now() - lastActionTime >= 0.5
    }
    func publishPointer(_ point: CGPoint, time: Double) {
        if time - lastPointerEvent > 0.05 {
            emit(["type": "pointer", "x": point.x, "y": point.y, "tracked": true])
            lastPointerEvent = time
        }
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
        if regainedHand && armed && !gestureBusy { mic.setArmed(true) }
        preview.videoSize = videoSize; preview.rawPoint = raw; preview.joints = joints
        lastRawPoint = raw
        let target = screenPoint(raw, bounds: screen)
        var pinchEvent = PinchHoldEvent.none
        var rightEdge = false
        if armed {
            guard AXIsProcessTrusted() else { setArmed(false); return }
            let pose = classifyHandPose(joints: joints, videoSize: videoSize)
            let showWindows = fistOpen.update(pose: pose, time: time)
            if showWindows || fistOpen.isEngaged || pose == .fist || pose == .closing ||
                missionControlTransition.blocksInput(time: now()) {
                setGestureBusy(true)
                leftPinch.reset(); rightPinch.reset(); pinchPoint = nil
                targetLock.clear(); targetOverlay.hide()
                // Folding the index finger must not drag the pointer across the desktop.
                if pointer == nil { pointer = CGEvent(source: nil)?.location ?? target }
                if let point = pointer { publishPointer(point, time: time) }
                if showWindows { openWindowOverview() }
                return
            }
            pinchEvent = leftPinch.update(ratio: leftRatio,
                                         eligible: rightRatio > 0.45 && (leftPinch.active || time - lastActionTime >= 0.5),
                                         time: time)
            if pinchEvent == .began {
                pinchPoint = pointer ?? CGEvent(source: nil)?.location ?? target
            }
            setGestureBusy(leftPinch.active)
            if leftPinch.active || leftRatio <= 0.45 { rightPinch.reset() }
            else { rightEdge = rightPinch.update(ratio: rightRatio, time: time) }
        }
        // Preserve the captured point through release, including the frame that
        // emits a quick single click. A held pinch never emits a preliminary click.
        if let held = pinchPoint, leftPinch.active || pinchEvent == .singleClick || pinchEvent == .doubleClick { pointer = held }
        else if let locked = targetLock.resolve(hand: raw, time: time) { pointer = locked }
        else {
            targetOverlay.hide()
            if let old = pointer { pointer = CGPoint(x: old.x + 0.28 * (target.x - old.x), y: old.y + 0.28 * (target.y - old.y)) }
            else { pointer = target }
        }
        guard let point = pointer else { return }
        publishPointer(point, time: time)
        guard armed else { return }
        guard AXIsProcessTrusted() else { setArmed(false); return }
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        if pinchEvent == .singleClick { click(.left, at: point) }
        else if pinchEvent == .doubleClick { click(.double, at: point) }
        else if rightEdge && leftRatio > 0.45 { click(.right, at: point) }
        if !leftPinch.active { pinchPoint = nil }
    }
    func loseHand() {
        preview.rawPoint = nil; preview.joints = [:]
        if tracked { mic.setArmed(false) }
        leftPinch.reset(); rightPinch.reset()
        fistOpen.reset(); pinchPoint = nil; gestureBusy = false
        missionControlTransition.cancel()
        targetLock.clear(); lastRawPoint = nil
        targetOverlay.hide()
        pointer = nil
        if tracked {
            invalidateTargetContext()
            emit(["type": "pointer", "tracked": false, "x": 0, "y": 0])
            tracked = false
        }
    }
    func click(_ action: PointerClickAction, at point: CGPoint) {
        guard armed, tracked, now() - lastHandTime <= 0.4, AXIsProcessTrusted(), now() - lastActionTime >= 0.5 else { return }
        guard let events = makePointerClickEvents(action, at: point) else { return }
        invalidateTargetContext()
        let button: CGMouseButton = action == .right ? .right : .left
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
        for event in events { event.post(tap: .cghidEventTap) }
        lastActionTime = now()
        emit(["type": "action", "action": action.rawValue, "source": "gesture", "x": point.x, "y": point.y])
        targetLock.clear()
        targetOverlay.hide()
    }
    func openWindowOverview() {
        guard armed, tracked, now() - lastHandTime <= 0.4, AXIsProcessTrusted(),
              now() - lastActionTime >= 0.5 else { return }
        let startedAt = now()
        guard let request = missionControlTransition.begin(time: startedAt) else { return }
        lastActionTime = startedAt
        emit(["type": "action", "action": "mission_control", "source": "gesture", "phase": "requested"])
        speechLabel.stringValue = "Opening window overview. Point and pinch after it opens."
        // Launch completion is bookkeeping only. Pointer and pinch processing
        // resume after the animation deadline, even while this callback waits.
        showMissionControl { [weak self] error in
            guard let self = self else { return }
            guard !self.closing, self.missionControlTransition.complete(request: request) else { return }
            if let error = error { self.report("Cannot show windows: \(error.localizedDescription)") }
        }
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
        if json["type"] as? String == "show_choices" {
            showChoices(json)
            return
        }
        if json["type"] as? String == "clear_choices" {
            if let id = json["choice_id"] as? String, id == duplicateOverlay.choiceID { duplicateOverlay.hide() }
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
        guard let capture = currentCapture(instruction.requestID),
              capture.choiceID == json["choice_id"] as? String else { return }
        if capture.choiceID != nil {
            let originals = capture.targets.filter {
                guard let label = $0["label"] as? String, let requested = json["label"] as? String,
                      let x = $0["x"] as? Double, let y = $0["y"] as? Double else { return false }
                return screenTargetLabelKey(label) == screenTargetLabelKey(requested) &&
                    abs(x - point.x) < 0.01 && abs(y - point.y) < 0.01
            }
            guard originals.count == 1 else { return }
            // A page can rearrange itself without a mouse/key event while the
            // number is transcribed. Confirm the target again just before moving.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                let fresh = await discoverTargets(region: capture.region, pointer: capture.pointer)
                guard currentCapture(instruction.requestID) != nil,
                      let confirmed = revalidatedScreenTarget(originals[0], in: fresh) else {
                    emit(["type": "error", "request_id": instruction.requestID,
                          "message": "Target changed or choices expired. Say the target name again."])
                    return
                }
                performVoiceMove(instruction, point: confirmed, label: json["label"] as? String ?? "Selected target")
            }
            return
        }
        performVoiceMove(instruction, point: point, label: json["label"] as? String ?? "Selected target")
    }
    func performVoiceMove(_ instruction: VoiceAction, point: CGPoint, label: String) {
        guard currentCapture(instruction.requestID) != nil else { return }
        guard armed, tracked, acceptsVoiceTarget, now() - lastHandTime <= 0.4, AXIsProcessTrusted(), let anchor = lastRawPoint else { return }
        let lockedAt = now()
        targetLock.hold(point, anchor: anchor, time: lockedAt); pointer = point
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        targetOverlay.show(point: point, label: label, protectedUntil: lockedAt + 3)
        emit(["type": "pointer", "x": point.x, "y": point.y, "tracked": true])
        emit(["type": "action", "action": "move_to", "source": "voice", "x": point.x, "y": point.y, "request_id": instruction.requestID])
    }
    func showChoices(_ json: [String: Any]) {
        guard let id = json["choice_id"] as? String, !id.isEmpty, id.count <= 100 else { return }
        func reject() { emit(["type": "choices_cancel", "choice_id": id]) }
        guard armed, tracked, acceptsVoiceTarget, now() - lastHandTime <= 0.4,
              let requestID = json["request_id"] as? String, requestID == id,
              let capture = currentCapture(requestID), capture.choiceID == nil,
              let raw = json["options"] as? [[String: Any]], (2...100).contains(raw.count),
              let duration = json["duration"] as? NSNumber,
              CFGetTypeID(duration) != CFBooleanGetTypeID(), duration.doubleValue.isFinite,
              duration.doubleValue > 0, duration.doubleValue <= 15 else { reject(); return }
        var ids = Set<String>()
        var options: [NumberedTarget] = []
        for (index, item) in raw.enumerated() {
            guard let number = item["number"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(index + 1),
                  let targetID = item["id"] as? String, ids.insert(targetID).inserted,
                  let original = capture.targets.first(where: { $0["id"] as? String == targetID }),
                  let label = item["label"] as? String, label == original["label"] as? String else { reject(); return }
            var values: [Double] = []
            for field in ["x", "y", "width", "height"] {
                guard let value = item[field] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite, let known = original[field] as? NSNumber,
                      abs(value.doubleValue - known.doubleValue) < 0.01 else { reject(); return }
                values.append(value.doubleValue)
            }
            let point = CGPoint(x: values[0], y: values[1])
            guard screen.contains(point), values[2] > 0, values[3] > 0 else { reject(); return }
            options.append(NumberedTarget(number: index + 1, id: targetID, label: label, point: point,
                                          bounds: CGRect(x: point.x - values[2] / 2, y: point.y - values[3] / 2,
                                                         width: values[2], height: values[3])))
        }
        targetLock.clear(); targetOverlay.hide()
        guard duplicateOverlay.show(choiceID: id, options: options, duration: duration.doubleValue, onExpire: { [weak self] expired in
            self?.invalidateTargetContext()
            emit(["type": "choices_cancel", "choice_id": expired])
        }) else { reject(); return }
        emit(["type": "choices_shown", "choice_id": id])
    }
    func captureTargets(_ json: [String: Any]) {
        let id = (json["request_id"] as? String) ?? ""
        func fail(_ message: String) {
            speechLabel.stringValue = message
            emit(["type": "error", "request_id": id, "message": message])
        }
        guard !id.isEmpty, id.count <= 128, armed, tracked, acceptsVoiceTarget,
              let x = json["x"] as? NSNumber, let y = json["y"] as? NSNumber,
              CFGetTypeID(x) != CFBooleanGetTypeID(), CFGetTypeID(y) != CFBooleanGetTypeID(),
              x.doubleValue.isFinite, y.doubleValue.isFinite,
              screen.contains(CGPoint(x: x.doubleValue, y: y.doubleValue)) else {
            fail("No current hand target is available for local text lookup."); return
        }
        let requestedWidth = (json["width"] as? NSNumber)?.doubleValue ?? 640
        let requestedHeight = (json["height"] as? NSNumber)?.doubleValue ?? 400
        guard requestedWidth.isFinite, requestedHeight.isFinite else { fail("Invalid screenshot region."); return }
        let width = min(screen.width, clamp(requestedWidth, 100, 1000))
        let height = min(screen.height, clamp(requestedHeight, 100, 800))
        let region = CGRect(x: clamp(x.doubleValue - width / 2, screen.minX, screen.maxX - width),
                            y: clamp(y.doubleValue - height / 2, screen.minY, screen.maxY - height),
                            width: width, height: height)
        let choiceID = json["choice_id"] as? String
        if let choiceID = choiceID {
            guard duplicateOverlay.choiceID == choiceID, now() < duplicateOverlay.expiresAt else {
                fail("Numbered choices expired. Say the target name again."); return
            }
        }
        let choiceDeadline = choiceID == nil ? nil : duplicateOverlay.expiresAt
        latestCaptureID = id
        let generation = contextGeneration
        let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Keep both kinds of labels out of OCR; suspension preserves the deadline.
        targetOverlay.hide()
        duplicateOverlay.suspend()
        Task { @MainActor in
            // Let WindowServer commit the hidden panels before capturing pixels.
            try? await Task.sleep(nanoseconds: 50_000_000)
            let targets = await discoverTargets(region: region, pointer: CGPoint(x: x.doubleValue, y: y.doubleValue))
            guard generation == contextGeneration,
                  foregroundPID == NSWorkspace.shared.frontmostApplication?.processIdentifier else {
                fail("Screen context changed. Point and speak again."); return
            }
            if let choiceID = choiceID { _ = duplicateOverlay.resume(choiceID: choiceID) }
            if targets.isEmpty && !CGPreflightScreenCaptureAccess() {
                DispatchQueue.main.async {
                    _ = CGRequestScreenCaptureAccess()
                    fail("No named controls found here. Allow Screen Recording to also search visible text, then restart.")
                }
                return
            }
            if targetCaptures.count >= 16 { targetCaptures.removeAll() }
            targetCaptures[id] = TargetCapture(targets: targets, region: region,
                                              pointer: CGPoint(x: x.doubleValue, y: y.doubleValue), foregroundPID: foregroundPID,
                                              generation: generation, capturedAt: now(),
                                              choiceID: choiceID, choiceDeadline: choiceDeadline)
            emit(["type": "targets", "request_id": id, "targets": targets,
                  "region": ["x": region.minX, "y": region.minY, "width": region.width, "height": region.height]])
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
        for observer in contextObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        contextObservers.removeAll()
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
    var targetLock = TargetLock()
    let voiceTarget = CGPoint(x: 400, y: 200), handAnchor = CGPoint(x: 0.5, y: 0.5)
    let movedHand = CGPoint(x: 0.7, y: 0.5)
    targetLock.hold(voiceTarget, anchor: handAnchor, time: 10)
    check(targetLock.resolve(hand: movedHand, time: 12.999) == voiceTarget, "voice target ignores finger movement for three seconds")
    check(targetLock.resolve(hand: handAnchor, time: 13) == voiceTarget, "stable hand keeps target after protection expires")
    check(targetLock.resolve(hand: movedHand, time: 13.001) == nil, "deliberate movement releases target after three seconds")
    targetLock.hold(voiceTarget, anchor: handAnchor, time: 20)
    targetLock.clear()
    check(targetLock.resolve(hand: handAnchor, time: 20.1) == nil, "click pause or hand loss can clear a protected target immediately")
    targetLock.hold(voiceTarget, anchor: handAnchor, time: 30)
    let nextTarget = CGPoint(x: 600, y: 300)
    targetLock.hold(nextTarget, anchor: handAnchor, time: 32)
    check(targetLock.resolve(hand: movedHand, time: 34.999) == nextTarget, "new voice target restarts three-second protection")
    var json: [String: Any] = ["type": "voice_action", "request_id": "abc", "action": "move_to", "x": 20, "y": 20]
    check(VoiceAction(json, bounds: bounds) != nil, "valid move")
    json["x"] = -1
    check(VoiceAction(json, bounds: bounds) == nil, "out-of-screen target rejected")
    json["x"] = true
    check(VoiceAction(json, bounds: bounds) == nil, "boolean coordinate rejected")
    for forbiddenAction in ["click", "double_click", "right_click", "mission_control"] {
        json["action"] = forbiddenAction
        check(VoiceAction(json, bounds: bounds) == nil, "gesture actions cannot be supplied by voice")
    }
    var clipper = SpeechClipper(rate: 1000)
    check(clipper.process([Float](repeating: 0, count: 200)).isEmpty, "silence emits no clip")
    let start = clipper.process([Float](repeating: 0.2, count: 100))
    check(start.count == 1 && start.first?["type"] as? String == "speech_start", "speech begins")
    let audio = clipper.process([Float](repeating: 0, count: 600))
    check(audio.count == 1 && audio.first?["type"] as? String == "speech_audio", "silence ends clip")
    check(clipper.requestID == nil && clipper.recording.isEmpty, "clip state resets")
    let targetTests = screenTargetGeometrySelfTest()
    tests += targetTests.tests
    if !targetTests.failures.isEmpty {
        fputs("Screen target self-test failed: \(targetTests.failures.joined(separator: "; "))\n", stderr)
        exit(1)
    }
    let overlayTests = targetOverlayGeometrySelfTest()
    tests += overlayTests.tests
    if !overlayTests.failures.isEmpty {
        fputs("Target overlay self-test failed: \(overlayTests.failures.joined(separator: "; "))\n", stderr)
        exit(1)
    }
    for result in [handGestureSelfTest(), desktopActionSelfTest(), duplicateTargetOverlayGeometrySelfTest()] {
        tests += result.tests
        if !result.failures.isEmpty {
            fputs("Gesture self-test failed: \(result.failures.joined(separator: "; "))\n", stderr)
            exit(1)
        }
    }
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

func targetsDiagnostic(point: CGPoint) async throws {
    let screen = CGDisplayBounds(CGMainDisplayID())
    guard point.x.isFinite, point.y.isFinite, screen.contains(point) else {
        throw NSError(domain: "LocalControl", code: 20, userInfo: [NSLocalizedDescriptionKey: "Target coordinates must be on the primary display."])
    }
    guard AXIsProcessTrusted() || CGPreflightScreenCaptureAccess() else {
        throw NSError(domain: "LocalControl", code: 21, userInfo: [NSLocalizedDescriptionKey: "Grant Accessibility or Screen Recording before inspecting screen targets."])
    }
    let width = min(720, screen.width), height = min(420, screen.height)
    let region = CGRect(x: clamp(point.x - width / 2, screen.minX, screen.maxX - width),
                        y: clamp(point.y - height / 2, screen.minY, screen.maxY - height),
                        width: width, height: height)
    let targets = await discoverTargets(region: region, pointer: point)
    let foreground = NSWorkspace.shared.frontmostApplication
    emit(["type": "targets_diagnostic", "mouse_events": 0,
          "accessibility": AXIsProcessTrusted(), "screen_recording": CGPreflightScreenCaptureAccess(),
          "foreground_app": ["name": foreground?.localizedName ?? "", "bundle_id": foreground?.bundleIdentifier ?? ""],
          "region": ["x": region.minX, "y": region.minY, "width": region.width, "height": region.height],
          "targets": targets])
}

@main
struct GestureCameraProgram {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        var cameraIndex = 0
        if let index = arguments.firstIndex(of: "--camera") {
            guard arguments.indices.contains(index + 1), let number = Int(arguments[index + 1]), number >= 0 else {
                fputs("--camera requires a non-negative camera index\n", stderr); exit(2)
            }
            cameraIndex = number
        }
        if let index = arguments.firstIndex(of: "--targets-at") {
            guard arguments.indices.contains(index + 2), let x = Double(arguments[index + 1]), let y = Double(arguments[index + 2]) else {
                fputs("--targets-at requires screen X and Y coordinates\n", stderr); exit(2)
            }
            Task {
                do { try await targetsDiagnostic(point: CGPoint(x: x, y: y)); exit(0) }
                catch { emit(["type": "error", "message": error.localizedDescription]); exit(1) }
            }
            RunLoop.main.run()
            exit(1)
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
        withExtendedLifetime(delegate) { app.run() }
    }
}
