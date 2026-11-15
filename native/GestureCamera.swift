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
func screenPoint(_ point: CGPoint, bounds: CGRect, gain: Double = 1) -> CGPoint {
    // Map the entire camera image, without a cropped central control region.
    let x = clamp(0.5 + (0.5 - point.x) * gain, 0, 1)
    let y = clamp(0.5 + (0.5 - point.y) * gain, 0, 1)
    return CGPoint(x: bounds.minX + x * (bounds.width - 1), y: bounds.minY + y * (bounds.height - 1))
}

struct PinchLatch {
    var released = false
    var pinched = false
    var lastClick = -Double.infinity
    mutating func reset() { released = false; pinched = false }
    mutating func update(ratio: Double, time: Double) -> Bool {
        guard ratio.isFinite else { reset(); return false }
        if ratio >= 0.58 { released = true; pinched = false; return false }
        guard ratio <= 0.40, released, !pinched else { return false }
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
        protectedUntil = time + 15
    }
    mutating func clear() {
        target = nil
        anchor = nil
        protectedUntil = -Double.infinity
    }
    mutating func resolve(hand: CGPoint, time: Double) -> CGPoint? {
        // Allow time to form a click gesture without the index finger pulling
        // the pointer away from the voice-selected target.
        if time >= protectedUntil { clear() }
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
              ["move_to", "back", "tab_left", "tab_right", "close_tab", "close_window", "change_window", "none"].contains(action),
              let id = json["request_id"] as? String, !id.isEmpty, id.count <= 128 else { return nil }
        self.action = action
        self.requestID = id
        if action == "none" { self.point = nil; return }
        if ["back", "tab_left", "tab_right", "close_tab", "close_window", "change_window"].contains(action) {
            // Navigation has a fixed meaning, never caller-supplied keys or URLs.
            guard Set(json.keys).isSubset(of: ["type", "action", "request_id", "choice_id"]),
                  json["choice_id"] == nil || json["choice_id"] is String else { return nil }
            self.point = nil
            return
        }
        guard let x = json["x"] as? NSNumber, let y = json["y"] as? NSNumber,
              CFGetTypeID(x) != CFBooleanGetTypeID(), CFGetTypeID(y) != CFBooleanGetTypeID(),
              x.doubleValue.isFinite, y.doubleValue.isFinite,
              x.doubleValue >= bounds.minX, x.doubleValue < bounds.maxX,
              y.doubleValue >= bounds.minY, y.doubleValue < bounds.maxY else { return nil }
        self.point = CGPoint(x: x.doubleValue, y: y.doubleValue)
    }
}

/// Match a coordinator-selected point back to one native capture. Native
/// geometry remains CGFloat in memory; JSON numbers arrive as NSNumber. Bridge
/// both representations explicitly instead of requiring a Swift Double cast.
func capturedVoiceTarget(_ candidates: [[String: Any]], label: String, point: CGPoint) -> [String: Any]? {
    let key = screenTargetLabelKey(label)
    guard !key.isEmpty, point.x.isFinite, point.y.isFinite else { return nil }
    var selected: [String: Any]?
    for candidate in candidates {
        guard let caption = candidate["label"] as? String, screenTargetLabelKey(caption) == key else { continue }
        let values = ["x", "y", "width", "height"].compactMap { field -> Double? in
            guard let number = candidate[field] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return number.doubleValue
        }
        guard values.count == 4, values[2] > 0, values[3] > 0,
              abs(values[0] - point.x) < 0.01, abs(values[1] - point.y) < 0.01 else { continue }
        guard selected == nil else { return nil }
        selected = candidate
    }
    return selected
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
    let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.owningApplication?.processID == getpid() })
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
    var onSpeechStart: (() -> Void)?
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
                for event in self.clipper.process(samples) {
                    if event["type"] as? String == "speech_start" {
                        DispatchQueue.main.async { self.onSpeechStart?() }
                    }
                    emit(event)
                }
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
        let guide = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        guide.lineWidth = 1; guide.stroke()
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
    var landmarkFilter = HandLandmarkFilter() // Used only on frameQueue.
    var lastFrameTime = -Double.infinity
    var lastPointerEvent = -Double.infinity
    var lastActionTime = -Double.infinity
    var tracked = false
    var scrollPinch = ScrollPinchLatch()
    var leftPinch = HoldPinchLatch()
    var rapidClicks = RapidClickSequence()
    var pointerGain = min(1.5, max(1, UserDefaults.standard.object(forKey: "pointerGain") as? Double ?? 1.15))
    var rangeLabel: NSTextField!
    var rightPinch = PinchLatch()
    var pinchPoint: CGPoint?
    var pinchApproach = PinchApproachLatch()
    var gestureBusy = false
    var lastRawPoint: CGPoint?
    var targetLock = TargetLock()
    let targetOverlay = TargetOverlay()
    let sensingOverlay = SensingOverlay()
    let tactileAudio = TactileAudio()
    var audioCueDeadline = -Double.infinity
    var soundEnabled = UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true
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
        request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
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
            if self.targetLock.resolve(hand: self.lastRawPoint ?? .zero, time: now()) == nil { self.targetOverlay.hide() }
            self.targetOverlay.refresh(now: now())
            self.sensingOverlay.updateCursor(self.armed && self.tracked ? CGEvent(source: nil)?.location : nil, time: now())
        }
        mic.onSpeechStart = { [weak self] in
            guard let self = self, self.armed, !self.closing else { return }
            self.sensingOverlay.showState("Listening…", time: now())
        }
        sensingOverlay.showState("Voice paused", time: now())
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
        let hint = NSTextField(wrappingLabelWithString: "Index: move · Thumb + middle: release to click, pinch twice quickly to double-click · Thumb + ring: right click\nThumb + pinky: hold and move up/down to scroll\nSpace: enable/pause · Escape: pause · Q: quit")
        hint.textColor = .secondaryLabelColor
        toggleButton = NSButton(title: "Enable pointer", target: self, action: #selector(toggle))
        toggleButton.bezelStyle = .rounded
        let quit = NSButton(title: "Quit", target: self, action: #selector(quitPressed))
        quit.bezelStyle = .rounded
        let sound = NSButton(checkboxWithTitle: "Sound effects", target: self, action: #selector(toggleSound(_:)))
        sound.state = soundEnabled ? .on : .off
        let buttons = NSStackView(views: [toggleButton, quit, sound]); buttons.orientation = .horizontal; buttons.spacing = 12
        rangeLabel = NSTextField(labelWithString: String(format: "Pointer reach: %.0f%%", pointerGain * 100))
        let reach = NSSlider(value: pointerGain, minValue: 1, maxValue: 1.5, target: self, action: #selector(changePointerGain(_:)))
        reach.setAccessibilityLabel("Pointer reach")
        reach.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let rangeRow = NSStackView(views: [rangeLabel, reach]); rangeRow.spacing = 12
        let info = NSStackView(views: [stateLabel, speechLabel, hint, buttons, rangeRow])
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
            let clicked = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
            self.invalidateTargetContext(preservingPrompt: !clicked)
            if clicked { self.targetLock.clear(); self.targetOverlay.hide() }
            guard event.type == .keyDown else { return event }
            if event.isARepeat { return event }
            if event.keyCode == 53 { self.setArmed(false); return nil }
            if event.keyCode == 49 { self.toggle(); return nil }
            if event.charactersIgnoringModifiers?.lowercased() == "q" { self.shutdown(); return nil }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: contextEvents) { [weak self] event in
            let clicked = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
            self?.invalidateTargetContext(preservingPrompt: !clicked)
            if clicked { self?.targetLock.clear(); self?.targetOverlay.hide() }
            if event.type == .keyDown && event.keyCode == 53 { self?.setArmed(false) }
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            contextObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.invalidateTargetContext(preservingPrompt: true)
            })
        }
    }
    func invalidateTargetContext(preservingPrompt: Bool = false) {
        if preservingPrompt && duplicateOverlay.choiceID != nil { return }
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
              (capture.choiceID != nil || capture.foregroundPID == NSWorkspace.shared.frontmostApplication?.processIdentifier),
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
    @objc func changePointerGain(_ sender: NSSlider) {
        pointerGain = sender.doubleValue
        UserDefaults.standard.set(pointerGain, forKey: "pointerGain")
        rangeLabel.stringValue = String(format: "Pointer reach: %.0f%%", pointerGain * 100)
        rapidClicks.reset()
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
        if !value { sensingOverlay.clear() }
        rapidClicks.reset(); scrollPinch.reset(); leftPinch.reset(); rightPinch.reset()
        pinchApproach.reset(); pinchPoint = nil; gestureBusy = false
        targetLock.clear()
        targetOverlay.hide()
        invalidateTargetContext()
        mic.setArmed(value && tracked)
        stateLabel.stringValue = value ? "ENABLED · Index finger moves pointer · Escape pauses" : "PAUSED · Pointer and speech actions are disabled"
        toggleButton.title = value ? "Pause pointer" : "Enable pointer"
        refreshVoiceHint()
        sensingOverlay.showState(value ? "Ready — speak a command" : "Voice paused", time: now())
        emit(["type": "state", "armed": value])
    }
    func refreshVoiceHint() {
        if !useVoice {
            speechLabel.stringValue = "Camera-only mode. Voice capture is off."
        } else if !audioStarted {
            speechLabel.stringValue = audioStarting ? "Microphone is preparing locally." : "Microphone is not ready. Gesture control remains available."
        } else if armed {
            speechLabel.stringValue = "Keep your hand visible. Say a label to point, last page to go back, or tab left / tab right in your browser. Gestures click."
        } else {
            speechLabel.stringValue = "Voice is paused. Enable pointer, show your hand, then say a visible label."
        }
    }
    @objc func toggleSound(_ sender: NSButton) {
        soundEnabled = sender.state == .on
        UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled")
    }
    func tactile(_ cue: TactileAudio.Cue) {
        guard soundEnabled, tactileAudio.play(cue) else { return }
        // Avoid transcribing our own speaker output. Resume only if control is
        // still enabled and the hand is available after the short cue tail.
        audioCueDeadline = now() + 0.25
        mic.setArmed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
            guard let self = self, !self.closing, now() >= self.audioCueDeadline else { return }
            self.mic.setArmed(self.armed && self.tracked && !self.gestureBusy)
        }
    }
    func report(_ message: String) {
        speechLabel.stringValue = message
        emit(["type": "error", "message": message])
    }
    func setGestureBusy(_ busy: Bool) {
        guard busy != gestureBusy else { return }
        gestureBusy = busy
        mic.setArmed(armed && tracked && !busy && now() >= audioCueDeadline)
        if busy {
            invalidateTargetContext(preservingPrompt: true)
            emit(["type": "gesture_cancel", "source": "gesture"])
        }
    }
    var acceptsVoiceTarget: Bool {
        !gestureBusy && now() - lastActionTime >= 0.5
    }
    func publishPointer(_ point: CGPoint, time: Double) {
        sensingOverlay.updateCursor(armed && tracked ? point : nil, time: time)
        if time - lastPointerEvent > 0.05 {
            emit(["type": "pointer", "x": point.x, "y": point.y, "tracked": true])
            lastPointerEvent = time
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = now()
        guard time - lastFrameTime >= 1.0 / 30.0 else { return }
        lastFrameTime = time
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:]).perform([request])
            guard let hand = request.results?.first else { DispatchQueue.main.async { self.trackingMiss() }; return }
            let points = try hand.recognizedPoints(.all)
            let samples = points.mapValues { HandLandmarkSample(point: $0.location, confidence: Double($0.confidence)) }
            let visibleJoints = landmarkFilter.update(samples, time: time)
            guard let index = visibleJoints[.indexTip], let thumb = visibleJoints[.thumbTip] else {
                DispatchQueue.main.async { self.trackingMiss() }; return
            }
            let palm = pinchPalmScale(joints: visibleJoints, size: size)
            guard palm > 0.015 * size.height else { DispatchQueue.main.async { self.trackingMiss() }; return }
            func ratio(_ joint: VNHumanHandPoseObservation.JointName) -> Double {
                guard let tip = visibleJoints[joint] else { return .infinity }
                return imageDistance(tip, thumb, size: size) / palm
            }
            let leftRatio = ratio(.middleTip), rightRatio = ratio(.ringTip)
            DispatchQueue.main.async { self.observe(index, leftRatio: leftRatio, rightRatio: rightRatio, time: time, videoSize: size, joints: visibleJoints) }
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
        // Do not synthesize click edges from missing landmarks. Brief gaps hold
        // the current state; sustained loss resets the gesture before reacquisition.
        if (leftPinch.active && !leftRatio.isFinite) || (rightPinch.pinched && !rightRatio.isFinite) ||
            (scrollPinch.active && joints[.littleTip] == nil) {
            trackingMiss(); return
        }
        let regainedHand = !tracked
        tracked = true; lastHandTime = time
        if regainedHand && armed && !gestureBusy && now() >= audioCueDeadline { mic.setArmed(true) }
        preview.videoSize = videoSize; preview.rawPoint = raw; preview.joints = joints
        lastRawPoint = raw
        let target = screenPoint(raw, bounds: screen, gain: pointerGain)
        var pinchEvent = PinchHoldEvent.none
        var rightEdge = false
        if armed {
            guard AXIsProcessTrusted() else { setArmed(false); return }
            let wasScrolling = scrollPinch.active
            let scrollRatio: Double
            if let pinky = joints[.littleTip], let thumb = joints[.thumbTip],
               joints[.wrist] != nil {
                let palm = pinchPalmScale(joints: joints, size: videoSize)
                scrollRatio = palm > 0 ? imageDistance(pinky, thumb, size: videoSize) / palm : .infinity
            } else { scrollRatio = .infinity }
            let approaching = pinchApproach.update(ratio: min(leftRatio, rightRatio, scrollRatio))
            if approaching && pinchPoint == nil {
                pinchPoint = pointer ?? CGEvent(source: nil)?.location ?? target
            }
            let scrollDelta = scrollPinch.update(ratio: scrollRatio, y: Double(joints[.wrist]?.y ?? raw.y),
                eligible: !leftPinch.active && !rightPinch.pinched &&
                    (scrollPinch.active || scrollRatio >= 0.58 || scrollRatio + 0.05 < min(leftRatio, rightRatio)),
                time: time)
            if scrollPinch.active || wasScrolling {
                if scrollPinch.active && !wasScrolling { rapidClicks.reset(); tactile(.scroll) }
                setGestureBusy(scrollPinch.active)
                leftPinch.reset(); rightPinch.reset(); pinchPoint = nil
                if pointer == nil { pointer = CGEvent(source: nil)?.location ?? target }
                if let point = pointer {
                    publishPointer(point, time: time)
                    if scrollDelta != 0 {
                        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                            wheel1: scrollDelta, wheel2: 0, wheel3: 0)
                        event?.location = point
                        event?.post(tap: .cghidEventTap)
                    }
                }
                lastActionTime = time
                return
            }
            pinchEvent = leftPinch.update(ratio: leftRatio,
                                         eligible: leftPinch.active || (!rightPinch.pinched &&
                                             (leftRatio >= 0.58 || leftRatio + 0.05 < min(rightRatio, scrollRatio)) ),
                                         time: time)
            if pinchEvent == .began && pinchPoint == nil {
                pinchPoint = pointer ?? CGEvent(source: nil)?.location ?? target
            }
            setGestureBusy(leftPinch.active || pinchApproach.active)
            if leftPinch.active || (!rightPinch.pinched && rightRatio < 0.58 && rightRatio + 0.05 >= min(leftRatio, scrollRatio)) { rightPinch.reset() }
            else { rightEdge = rightPinch.update(ratio: rightRatio, time: time) }
        }
        // Preserve the captured point through release, including the frame that
        // emits a quick single click. A held pinch never emits a preliminary click.
        if let held = pinchPoint, pinchApproach.active || leftPinch.active || rightEdge || pinchEvent == .singleClick || pinchEvent == .doubleClick { pointer = held }
        else if let locked = targetLock.resolve(hand: raw, time: time) { pointer = locked }
        else {
            targetOverlay.hide()
            if let old = pointer { pointer = CGPoint(x: old.x + 0.18 * (target.x - old.x), y: old.y + 0.18 * (target.y - old.y)) }
            else { pointer = target }
        }
        guard let point = pointer else { return }
        publishPointer(point, time: time)
        guard armed else { return }
        guard AXIsProcessTrusted() else { setArmed(false); return }
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        if pinchEvent == .singleClick { click(.left, at: point) }
        else if rightEdge { click(.right, at: point) }
        if !leftPinch.active && !pinchApproach.active { pinchPoint = nil }
    }
    func trackingMiss() {
        if now() - lastHandTime > 0.15 { loseHand() }
    }
    func loseHand() {
        sensingOverlay.updateCursor(nil, time: now())
        preview.rawPoint = nil; preview.joints = [:]
        if tracked { mic.setArmed(false) }
        rapidClicks.reset(); scrollPinch.reset(); leftPinch.reset(); rightPinch.reset()
        pinchApproach.reset(); pinchPoint = nil; gestureBusy = false
        lastRawPoint = nil
        pointer = nil
        if tracked {
            invalidateTargetContext(preservingPrompt: true)
            emit(["type": "pointer", "tracked": false, "x": 0, "y": 0])
            tracked = false
        }
    }
    func click(_ action: PointerClickAction, at point: CGPoint) {
        guard armed, tracked, now() - lastHandTime <= 0.4, AXIsProcessTrusted(), now() - lastActionTime >= (action == .left ? 0.06 : 0.5) else { return }
        let count: Int64
        if action == .left { count = rapidClicks.register(point: point, time: now(), interval: NSEvent.doubleClickInterval) }
        else { rapidClicks.reset(); count = 1 }
        guard let events = makePointerClickEvents(action, at: point, clickCount: count) else { return }
        invalidateTargetContext()
        let button: CGMouseButton = action == .right ? .right : .left
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
        for event in events { event.post(tap: .cghidEventTap) }
        tactile(count == 2 ? .doubleClick : .click)
        lastActionTime = now()
        emit(["type": "action", "action": action.rawValue, "source": "gesture", "x": point.x, "y": point.y])
        targetLock.clear()
        targetOverlay.hide()
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
        if json["type"] as? String == "voice_feedback" {
            guard armed, useVoice, Set(json.keys) == ["type", "request_id", "text"],
                  let id = json["request_id"] as? String, currentCapture(id) != nil,
                  let text = json["text"] as? String, text.count <= 300 else { return }
            sensingOverlay.showTranscript(text, time: now())
            return
        }
        if json["type"] as? String == "status", let message = json["message"] as? String {
            if json["important"] as? Bool == true || (armed && useVoice && audioStarted) { speechLabel.stringValue = String(message.prefix(400)) }
            else { refreshVoiceHint() }
            if armed { sensingOverlay.showState(message, time: now()) }
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
        if ["back", "tab_left", "tab_right", "close_tab", "close_window", "change_window"].contains(instruction.action) {
            performVoiceNavigation(instruction, choiceID: json["choice_id"] as? String)
            return
        }
        guard let point = instruction.point else { return }
        guard let capture = currentCapture(instruction.requestID),
              capture.choiceID == json["choice_id"] as? String else { return }
        if capture.choiceID != nil {
            guard let label = json["label"] as? String,
                  capturedVoiceTarget(capture.targets, label: label, point: point) != nil else {
                emit(["type": "error", "request_id": instruction.requestID,
                      "message": "Selected numbered target no longer matches its capture. Say the target name again."])
                return
            }
            performVoiceMove(instruction, point: point,
                             label: json["label"] as? String ?? "Selected target")
            return
        }
        performVoiceMove(instruction, point: point, label: json["label"] as? String ?? "Selected target")
    }
    func performVoiceMove(_ instruction: VoiceAction, point: CGPoint, label: String) {
        guard currentCapture(instruction.requestID) != nil else { return }
        guard armed, tracked, acceptsVoiceTarget, now() - lastHandTime <= 0.4, AXIsProcessTrusted(), let anchor = lastRawPoint else { return }
        rapidClicks.reset()
        let lockedAt = now()
        targetLock.hold(point, anchor: anchor, time: lockedAt); pointer = point
        tactile(.lock)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        targetOverlay.show(point: point, label: label, protectedUntil: lockedAt + 15)
        emit(["type": "pointer", "x": point.x, "y": point.y, "tracked": true])
        emit(["type": "action", "action": "move_to", "source": "voice", "x": point.x, "y": point.y, "request_id": instruction.requestID])
    }
    func performVoiceNavigation(_ instruction: VoiceAction, choiceID: String?) {
        func fail(_ message: String) {
            emit(["type": "error", "request_id": instruction.requestID, "message": message])
        }
        guard armed, tracked, acceptsVoiceTarget, now() - lastHandTime <= 0.4, AXIsProcessTrusted(),
              let capture = currentCapture(instruction.requestID), capture.choiceID == choiceID else {
            fail("Navigation context changed or hand control paused. Say the command again.")
            return
        }
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier == capture.foregroundPID else {
            fail("The active application changed. Say the command again.")
            return
        }
        if instruction.action == "close_window" || instruction.action == "change_window" {
            guard let operation = prepareWindowAction(pid: application.processIdentifier, close: instruction.action == "close_window"),
                  armed, tracked, acceptsVoiceTarget, now() - lastHandTime <= 0.4,
                  currentCapture(instruction.requestID) != nil else {
                fail("No available window action. Change window needs another open window in this app.")
                return
            }
            rapidClicks.reset(); targetLock.clear(); targetOverlay.hide(); duplicateOverlay.hide()
            invalidateTargetContext()
            guard operation() else { fail("The window changed or did not accept the action."); return }
            lastActionTime = now(); tactile(.navigation)
            emit(["type": "action", "source": "voice", "action": instruction.action, "request_id": instruction.requestID])
            return
        }
        let shortcut: [CGEvent]?
        if instruction.action == "back" {
            guard supportsHistoryBack(bundleIdentifier: application.bundleIdentifier) else {
                fail("Last page works in Finder or a web browser. Bring that window to the front and try again.")
                return
            }
            shortcut = makeHistoryBackEvents()
        } else if ["tab_left", "tab_right", "close_tab"].contains(instruction.action) {
            guard isBrowserApplication(bundleIdentifier: application.bundleIdentifier) else {
                fail("Tab commands work in a web browser. Bring your browser to the front and try again.")
                return
            }
            shortcut = instruction.action == "close_tab" ? makeCloseTabEvents() : makeBrowserTabEvents(instruction.action == "tab_left" ? .left : .right)
        } else { fail("Unsupported navigation command."); return }
        guard let events = shortcut else { fail("Could not create the navigation shortcut."); return }
        guard armed, tracked, acceptsVoiceTarget, now() - lastHandTime <= 0.4,
              currentCapture(instruction.requestID) != nil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
            fail("Navigation context changed before the action. Say the command again.")
            return
        }
        rapidClicks.reset()
        targetLock.clear(); targetOverlay.hide(); duplicateOverlay.hide()
        invalidateTargetContext()
        lastActionTime = now()
        // Deliver only to the application bound to this recording. A focus change
        // cannot redirect the shortcut to an editor or another application.
        for event in events { event.postToPid(application.processIdentifier) }
        tactile(.navigation)
        emit(["type": "action", "source": "voice", "action": instruction.action, "request_id": instruction.requestID])
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
        tactile(.choices)
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
        let width = min(screen.width, clamp(requestedWidth, 100, screen.width))
        let height = min(screen.height, clamp(requestedHeight, 100, screen.height))
        let region = CGRect(x: clamp(x.doubleValue - width / 2, screen.minX, screen.maxX - width),
                            y: clamp(y.doubleValue - height / 2, screen.minY, screen.maxY - height),
                            width: width, height: height)
        let choiceID = json["choice_id"] as? String
        if let choiceID = choiceID {
            guard duplicateOverlay.choiceID == choiceID, now() < duplicateOverlay.expiresAt else {
                fail("Numbered choices expired. Say the target name again."); return
            }
        }
        if let choiceID = choiceID, let original = targetCaptures[choiceID] {
            latestCaptureID = id
            targetCaptures[id] = TargetCapture(targets: original.targets, region: original.region,
                pointer: original.pointer, foregroundPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                generation: contextGeneration, capturedAt: now(), choiceID: choiceID,
                choiceDeadline: duplicateOverlay.expiresAt)
            emit(["type": "targets", "request_id": id, "targets": original.targets,
                  "region": ["x": original.region.minX, "y": original.region.minY,
                             "width": original.region.width, "height": original.region.height]])
            return
        }
        let choiceDeadline = choiceID == nil ? nil : duplicateOverlay.expiresAt
        latestCaptureID = id
        let generation = contextGeneration
        let foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Keep both kinds of labels out of OCR; suspension preserves the deadline.
        targetOverlay.hide()
        duplicateOverlay.suspend()
        sensingOverlay.suspend()
        Task { @MainActor in
            defer { sensingOverlay.resume(time: now()) }
            // Let WindowServer commit the hidden panels before capturing pixels.
            try? await Task.sleep(nanoseconds: 50_000_000)
            let targets = await discoverTargets(region: region, pointer: CGPoint(x: x.doubleValue, y: y.doubleValue))
            guard generation == contextGeneration,
                  foregroundPID == NSWorkspace.shared.frontmostApplication?.processIdentifier else {
                fail("Screen context changed. Point and speak again."); return
            }
            if let choiceID = choiceID { _ = duplicateOverlay.resume(choiceID: choiceID) }
            // Empty captures still carry foreground context: an explicit Back
            // request must work even on a blank page or without readable text.
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
    check(screenPoint(CGPoint(x: 0.5, y: 0.5), bounds: bounds, gain: 1.15) == CGPoint(x: 499.5, y: 249.5),
          "Extra pointer reach preserves the center")
    check(screenPoint(CGPoint(x: 0.05, y: 0.95), bounds: bounds, gain: 1.15) == CGPoint(x: 999, y: 0),
          "Extra reach reaches screen edges before camera edges")
    let nearEdge = screenPoint(CGPoint(x: 0.1, y: 0.9), bounds: bounds)
    check(abs(nearEdge.x - 899.1) < 0.001 && abs(nearEdge.y - 49.9) < 0.001,
          "Outer camera area maps proportionally instead of clamping early")
    let fartherEdge = screenPoint(CGPoint(x: 0.05, y: 0.95), bounds: bounds)
    check(fartherEdge.x > nearEdge.x && fartherEdge.y < nearEdge.y,
          "Pointer continues moving through the former excluded camera margins")
    check(screenPoint(CGPoint(x: -0.1, y: 1.1), bounds: bounds) == CGPoint(x: 999, y: 0),
          "Out-of-frame landmarks remain clamped to screen bounds")
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
    check(targetLock.resolve(hand: movedHand, time: 13.001) == voiceTarget, "hand movement preserves positional target until timeout")
    check(targetLock.resolve(hand: handAnchor, time: 25) == nil, "positional focus expires after fifteen seconds")
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
    for forbiddenAction in ["click", "double_click", "right_click", "mission_control", "tab_up", "tab_down"] {
        json["action"] = forbiddenAction
        check(VoiceAction(json, bounds: bounds) == nil, "gesture actions cannot be supplied by voice")
    }
    for action in ["back", "tab_left", "tab_right", "close_tab", "close_window", "change_window"] {
        let navigation: [String: Any] = ["type": "voice_action", "action": action, "request_id": "navigation-test"]
        check(VoiceAction(navigation, bounds: bounds)?.action == action, "Explicit navigation requires no target coordinates")
        check(VoiceAction(navigation, bounds: bounds)?.point == nil, "Navigation does not position or click the mouse")
        for field in ["x", "y", "url", "key_code", "modifiers"] {
            var invalid = navigation
            invalid[field] = 1
            check(VoiceAction(invalid, bounds: bounds) == nil, "Navigation cannot accept arbitrary coordinates URLs or keys")
        }
    }
    let nativeRect = CGRect(x: 200, y: 300, width: 80, height: 40)
    let nativePoint = CGPoint(x: nativeRect.midX, y: nativeRect.midY)
    let nativeTarget: [String: Any] = ["id": "native", "label": "Reports",
                                      "x": nativeRect.midX, "y": nativeRect.midY,
                                      "width": nativeRect.width, "height": nativeRect.height]
    check(capturedVoiceTarget([nativeTarget], label: "Reports", point: nativePoint)?["id"] as? String == "native",
          "Numbered movement resolves raw CGFloat geometry from the native capture")
    let encodedTarget = try! JSONSerialization.data(withJSONObject: nativeTarget)
    let decodedTarget = try! JSONSerialization.jsonObject(with: encodedTarget) as! [String: Any]
    check(capturedVoiceTarget([decodedTarget], label: "Reports", point: nativePoint)?["id"] as? String == "native",
          "Numbered movement also accepts JSON-roundtripped NSNumber geometry")
    check(capturedVoiceTarget([nativeTarget], label: " reports! ", point: nativePoint) != nil,
          "Captured target lookup uses canonical caption identity")
    check(capturedVoiceTarget([nativeTarget, nativeTarget], label: "Reports", point: nativePoint) == nil,
          "Two identical capture references cannot select an arbitrary target")
    check(capturedVoiceTarget([nativeTarget], label: "Finder", point: nativePoint) == nil,
          "A different label cannot select captured coordinates")
    check(capturedVoiceTarget([nativeTarget], label: "Reports", point: CGPoint(x: nativePoint.x + 1, y: nativePoint.y)) == nil,
          "Captured reference must use the exact coordinator-selected coordinates")
    for field in ["x", "y", "width", "height"] {
        for invalid: Any in [true, Double.nan, Double.infinity, "200"] {
            var malformed = nativeTarget
            malformed[field] = invalid
            check(capturedVoiceTarget([malformed], label: "Reports", point: nativePoint) == nil,
                  "Captured \(field) rejects boolean, nonfinite and nonnumeric geometry")
        }
    }
    for field in ["width", "height"] {
        var malformed = nativeTarget
        malformed[field] = 0
        check(capturedVoiceTarget([malformed], label: "Reports", point: nativePoint) == nil,
              "Captured target dimensions must be positive")
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
