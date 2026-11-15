// A transient, click-through indicator for an existing voice target lock.
// All public methods are called on the main thread. This view never sends input.
import AppKit
import AVFoundation

private func overlayScreenPoint(_ point: CGPoint, quartzBounds: CGRect, appKitFrame: CGRect) -> CGPoint {
    // Both coordinate spaces use points, including on Retina displays. Quartz
    // starts at the display's top left; AppKit starts at its bottom left.
    CGPoint(x: appKitFrame.minX + point.x - quartzBounds.minX,
            y: appKitFrame.maxY - (point.y - quartzBounds.minY))
}

private struct OverlayLayout {
    let frame: CGRect
    let ringCenter: CGPoint
    let caption: CGRect
}

private func overlayLayout(point: CGPoint, screen: CGRect, captionWidth: CGFloat) -> OverlayLayout {
    let width = min(captionWidth, max(1, screen.width - 16))
    let height: CGFloat = 44
    var left = point.x + 19
    if left + width > screen.maxX - 8 { left = point.x - 19 - width }
    left = max(screen.minX + 8, min(left, screen.maxX - width - 8))
    var bottom = point.y - 16 - height
    if bottom < screen.minY + 8 { bottom = point.y + 16 }
    bottom = max(screen.minY + 8, min(bottom, screen.maxY - height - 8))
    let caption = CGRect(x: left, y: bottom, width: width, height: height)
    let ring = CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32)
    // Crop at display edges without moving the ring away from the real target.
    let frame = ring.union(caption).intersection(screen)
    return OverlayLayout(frame: frame,
                         ringCenter: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY),
                         caption: caption.offsetBy(dx: -frame.minX, dy: -frame.minY))
}

private final class TargetOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class TargetOverlayView: NSView {
    var ringCenter = CGPoint.zero
    var caption = CGRect.zero
    var targetLabel = ""
    var status = ""
    private let accent = NSColor(srgbRed: 0.2, green: 0.9, blue: 0.98, alpha: 1)

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: CGRect(x: ringCenter.x - 12, y: ringCenter.y - 12,
                                               width: 24, height: 24))
        NSColor.black.withAlphaComponent(0.65).setStroke()
        circle.lineWidth = 4
        circle.stroke()
        accent.setStroke()
        circle.lineWidth = 2
        circle.stroke()

        let pill = NSBezierPath(roundedRect: caption, xRadius: 8, yRadius: 8)
        NSColor(srgbRed: 0.04, green: 0.09, blue: 0.12, alpha: 0.94).setFill()
        pill.fill()
        accent.withAlphaComponent(0.5).setStroke()
        pill.lineWidth = 1
        pill.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let textWidth = max(0, caption.width - 20)
        (targetLabel as NSString).draw(
            in: CGRect(x: caption.minX + 10, y: caption.minY + 23, width: textWidth, height: 15),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                             .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
        (status as NSString).draw(
            in: CGRect(x: caption.minX + 10, y: caption.minY + 7, width: textWidth, height: 14),
            withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                             .foregroundColor: accent, .paragraphStyle: paragraph])
    }
}

final class TargetOverlay {
    private var panel: TargetOverlayPanel?
    private var view: TargetOverlayView?
    private var point: CGPoint?
    private var protectedUntil: TimeInterval = 0
    private var label = ""

    /// Show the lock already owned by the controller. This creates no lock and
    /// performs no mouse operation. protectedUntil uses systemUptime seconds.
    func show(point: CGPoint, label: String, protectedUntil: TimeInterval) {
        precondition(Thread.isMainThread)
        guard point.x.isFinite, point.y.isFinite, protectedUntil.isFinite else { hide(); return }
        self.point = point
        self.protectedUntil = protectedUntil
        let clean = label.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        self.label = clean.isEmpty ? "Selected target" : String(clean.prefix(80))
        refresh(now: ProcessInfo.processInfo.systemUptime)
        if self.point != nil { panel?.orderFrontRegardless() }
    }

    func hide() {
        precondition(Thread.isMainThread)
        point = nil
        label = ""
        protectedUntil = 0
        panel?.orderOut(nil)
    }

    /// Refresh from the controller's existing timer, only while its lock exists.
    /// Reaching the deadline changes the hint; the controller decides when to hide.
    func refresh(now: TimeInterval) {
        precondition(Thread.isMainThread)
        guard let point = point else { return }
        guard now.isFinite else { hide(); return }
        let display = CGMainDisplayID()
        let quartzBounds = CGDisplayBounds(display)
        guard quartzBounds.contains(point),
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
              }) else { hide(); return }
        let screenPoint = overlayScreenPoint(point, quartzBounds: quartzBounds, appKitFrame: screen.frame)
        let labelWidth = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width
        let layout = overlayLayout(point: screenPoint, screen: screen.frame,
                                   captionWidth: min(220, max(126, ceil(labelWidth) + 20)))
        if panel == nil {
            let overlay = TargetOverlayPanel(contentRect: layout.frame,
                                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            overlay.isOpaque = false
            overlay.backgroundColor = .clear
            overlay.hasShadow = false
            overlay.ignoresMouseEvents = true
            overlay.hidesOnDeactivate = false
            overlay.isFloatingPanel = true
            overlay.becomesKeyOnlyIfNeeded = true
            overlay.level = .statusBar
            overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            overlay.animationBehavior = .none
            overlay.isReleasedWhenClosed = false
            let content = TargetOverlayView(frame: CGRect(origin: .zero, size: layout.frame.size))
            content.setAccessibilityElement(false)
            overlay.contentView = content
            panel = overlay
            view = content
        }
        panel?.setFrame(layout.frame, display: false)
        view?.frame = CGRect(origin: .zero, size: layout.frame.size)
        view?.ringCenter = layout.ringCenter
        view?.caption = layout.caption
        view?.targetLabel = label
        let remaining = max(0, protectedUntil - now)
        view?.status = remaining > 0 ? String(format: "Hold %.1fs", locale: Locale(identifier: "en_US_POSIX"), remaining) : "Pinch to click"
        view?.needsDisplay = true
    }
}

private final class SensingRingView: NSView {
    var center = CGPoint.zero
    static let radius: CGFloat = 72
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor(srgbRed: 0.15, green: 0.9, blue: 1, alpha: 1)
        let circle = NSBezierPath(ovalIn: CGRect(x: center.x - Self.radius, y: center.y - Self.radius,
                                                width: Self.radius * 2, height: Self.radius * 2))
        accent.withAlphaComponent(0.025).setFill(); circle.fill()
        NSColor.black.withAlphaComponent(0.3).setStroke(); circle.lineWidth = 4; circle.stroke()
        accent.withAlphaComponent(0.65).setStroke(); circle.lineWidth = 1; circle.stroke()
        for angle in stride(from: 0.0, to: 360.0, by: 30.0) {
            let radians = angle * .pi / 180
            let major = Int(angle) % 90 == 0
            let tick = NSBezierPath()
            tick.move(to: CGPoint(x: center.x + cos(radians) * (Self.radius + 4),
                                 y: center.y + sin(radians) * (Self.radius + 4)))
            tick.line(to: CGPoint(x: center.x + cos(radians) * (Self.radius + (major ? 11 : 7)),
                                 y: center.y + sin(radians) * (Self.radius + (major ? 11 : 7))))
            accent.withAlphaComponent(major ? 0.9 : 0.4).setStroke()
            tick.lineWidth = major ? 2 : 1; tick.stroke()
        }
    }
}

private final class VoiceCaptionView: NSView {
    var text = ""
    var heading = "SPEECH DETECTION"
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
        NSColor(srgbRed: 0.035, green: 0.045, blue: 0.06, alpha: 0.62).setFill(); card.fill()
        let red = NSColor(srgbRed: 1, green: 0.22, blue: 0.27, alpha: 1)
        red.withAlphaComponent(0.4).setStroke(); card.lineWidth = 1; card.stroke()
        red.setFill()
        NSBezierPath(ovalIn: CGRect(x: 19, y: bounds.height - 27, width: 6, height: 6)).fill()
        (heading as NSString).draw(at: CGPoint(x: 33, y: bounds.height - 30),
            withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                             .foregroundColor: red.withAlphaComponent(0.85), .kern: 1.2])
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: CGRect(x: 18, y: 15, width: bounds.width - 36, height: 55),
            withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold),
                             .foregroundColor: red, .paragraphStyle: paragraph])
    }
}

/// Presentation only: no targeting radius restriction, input events, or saved speech.
/// The persistent caption is excluded from screen capture by its owning process.
final class SensingOverlay {
    private var ringPanel: TargetOverlayPanel?
    private var captionPanel: TargetOverlayPanel?
    private var point: CGPoint?
    private var transcript = "Voice paused"
    private var heading = "SPEECH DETECTION"
    private var suspensions = 0

    private func panel(view: NSView) -> TargetOverlayPanel {
        let panel = TargetOverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar; panel.animationBehavior = .none; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        view.setAccessibilityElement(false); panel.contentView = view
        return panel
    }

    func updateCursor(_ point: CGPoint?, time: TimeInterval) {
        precondition(Thread.isMainThread)
        self.point = point
        refresh(time: time)
    }
    func showTranscript(_ text: String, time: TimeInterval) {
        precondition(Thread.isMainThread)
        let clean = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !clean.isEmpty, time.isFinite else { return }
        transcript = String(clean.prefix(300)); heading = "VOICE RECOGNIZED"
        refresh(time: time)
    }
    func showState(_ text: String, time: TimeInterval) {
        precondition(Thread.isMainThread)
        // Keep the recognized words visible while matching/action statuses change.
        if text.hasPrefix("Listening") || heading != "VOICE RECOGNIZED" || text == "Voice paused" || text.hasPrefix("Ready") {
            transcript = String(text.prefix(300)); heading = "SPEECH DETECTION"
            refresh(time: time)
        }
    }
    func clear() {
        precondition(Thread.isMainThread)
        point = nil; transcript = "Voice paused"; heading = "SPEECH DETECTION"
        ringPanel?.orderOut(nil)
        refresh(time: ProcessInfo.processInfo.systemUptime)
    }
    func suspend() {
        precondition(Thread.isMainThread)
        suspensions += 1
        ringPanel?.orderOut(nil)
    }
    func resume(time: TimeInterval) {
        precondition(Thread.isMainThread)
        suspensions = max(0, suspensions - 1)
        refresh(time: time)
    }
    func refresh(time: TimeInterval) {
        precondition(Thread.isMainThread)
        let display = CGMainDisplayID(), quartz = CGDisplayBounds(CGMainDisplayID())
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }) else { ringPanel?.orderOut(nil); captionPanel?.orderOut(nil); return }
        if suspensions == 0, let point = point, point.x.isFinite, point.y.isFinite, quartz.contains(point) {
            let center = overlayScreenPoint(point, quartzBounds: quartz, appKitFrame: screen.frame)
            // Clip at display edges; never shift the center away from the cursor.
            let frame = CGRect(x: center.x - 86, y: center.y - 86, width: 172, height: 172).intersection(screen.frame)
            if ringPanel == nil { ringPanel = panel(view: SensingRingView()) }
            ringPanel?.setFrame(frame, display: false)
            if let view = ringPanel?.contentView as? SensingRingView {
                view.frame = CGRect(origin: .zero, size: frame.size)
                view.center = CGPoint(x: center.x - frame.minX, y: center.y - frame.minY)
                view.needsDisplay = true
            }
            if ringPanel?.isVisible == false { ringPanel?.orderFrontRegardless() }
        } else { ringPanel?.orderOut(nil) }
        if !transcript.isEmpty {
            let usable = screen.visibleFrame.insetBy(dx: 18, dy: 18)
            let width = min(360, usable.width), height = min(108, usable.height)
            let frame = CGRect(x: usable.maxX - width, y: usable.maxY - height, width: width, height: height)
            if captionPanel == nil { captionPanel = panel(view: VoiceCaptionView()) }
            captionPanel?.setFrame(frame, display: false)
            if let view = captionPanel?.contentView as? VoiceCaptionView {
                view.frame = CGRect(origin: .zero, size: frame.size); view.text = transcript; view.heading = heading; view.needsDisplay = true
            }
            if captionPanel?.isVisible == false { captionPanel?.orderFrontRegardless() }
        } else { captionPanel?.orderOut(nil) }
    }
}

/// Pure geometry checks: no application, panels, permissions, or input required.
func targetOverlayGeometrySelfTest() -> (tests: Int, failures: [String]) {
    var failures: [String] = []
    var tests = 0
    func check(_ condition: Bool, _ message: String) { tests += 1; if !condition { failures.append(message) } }
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    check(overlayScreenPoint(CGPoint(x: 200, y: 100), quartzBounds: screen, appKitFrame: screen) == CGPoint(x: 200, y: 800),
          "Quartz top-left coordinates convert to AppKit points without Retina scaling")
    check(overlayScreenPoint(CGPoint(x: -1800, y: 200),
                             quartzBounds: CGRect(x: -1920, y: 100, width: 1920, height: 1080),
                             appKitFrame: CGRect(x: -1920, y: -180, width: 1920, height: 1080)) == CGPoint(x: -1800, y: 800),
          "Display origins participate in coordinate conversion")
    for point in [CGPoint(x: 0, y: 0), CGPoint(x: 1439, y: 899), CGPoint(x: 720, y: 450)] {
        let layout = overlayLayout(point: point, screen: screen, captionWidth: 220)
        let actualCenter = CGPoint(x: layout.frame.minX + layout.ringCenter.x, y: layout.frame.minY + layout.ringCenter.y)
        check(actualCenter == point, "Clamping the panel at display edges preserves the target center")
        check(screen.contains(layout.caption.offsetBy(dx: layout.frame.minX, dy: layout.frame.minY)),
              "The complete target caption remains on screen")
    }
    return (tests, failures)
}

// Short synthesized tactile cues: no files, downloads, speech, or network.
final class TactileAudio {
    enum Cue { case lock, click, doubleClick, scroll, choices, navigation }
    private var player: AVAudioPlayer?
    private var lastPlayed = -Double.infinity
    func play(_ cue: Cue) -> Bool {
        let time = ProcessInfo.processInfo.systemUptime
        guard time - lastPlayed > 0.12 else { return false }
        let notes: [Double]
        switch cue {
        case .lock: notes = [660, 990]
        case .click: notes = [820]
        case .doubleClick: notes = [820, 820]
        case .scroll: notes = [380]
        case .choices: notes = [520, 660]
        case .navigation: notes = [740, 550]
        }
        let rate = 22050, frames = 1102
        var pcm = Data()
        func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        for frequency in notes {
            for i in 0..<frames {
                let envelope = pow(sin(Double.pi * Double(i) / Double(frames)), 2)
                let value = Int16(sin(2 * .pi * frequency * Double(i) / Double(rate)) * envelope * 3500)
                append(value, to: &pcm)
            }
            pcm.append(Data(count: 220 * 2))
        }
        var wav = Data("RIFF".utf8)
        append(UInt32(36 + pcm.count), to: &wav); wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &wav); append(UInt16(1), to: &wav); append(UInt16(1), to: &wav)
        append(UInt32(rate), to: &wav); append(UInt32(rate * 2), to: &wav)
        append(UInt16(2), to: &wav); append(UInt16(16), to: &wav)
        wav.append(Data("data".utf8)); append(UInt32(pcm.count), to: &wav); wav.append(pcm)
        guard let sound = try? AVAudioPlayer(data: wav) else { return false }
        player = sound
        guard sound.play() else { return false }
        lastPlayed = time
        return true
    }
}
