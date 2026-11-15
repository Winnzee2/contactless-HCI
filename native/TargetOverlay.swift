// A transient, click-through indicator for an existing voice target lock.
// All public methods are called on the main thread. This view never sends input.
import AppKit

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
