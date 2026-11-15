// Numbered, click-through choices for an ambiguous spoken target. The controller
// owns selection; this overlay only draws and expires its immutable choice set.
import AppKit

struct NumberedTarget {
    let number: Int
    let id: String
    let label: String
    let point: CGPoint
    let bounds: CGRect
}

private func duplicateScreenPoint(_ point: CGPoint, quartzBounds: CGRect, appKitFrame: CGRect) -> CGPoint {
    CGPoint(x: appKitFrame.minX + point.x - quartzBounds.minX,
            y: appKitFrame.maxY - (point.y - quartzBounds.minY))
}

private func duplicateScreenRect(_ rect: CGRect, quartzBounds: CGRect, appKitFrame: CGRect) -> CGRect {
    let topLeft = duplicateScreenPoint(CGPoint(x: rect.minX, y: rect.minY),
                                       quartzBounds: quartzBounds, appKitFrame: appKitFrame)
    return CGRect(x: topLeft.x, y: topLeft.y - rect.height, width: rect.width, height: rect.height)
}

private struct DuplicateMark {
    let number: Int
    let ring: CGRect
    let badge: CGRect
}

private func duplicateMark(number: Int, bounds: CGRect, screen: CGRect, occupied: [CGRect]) -> DuplicateMark {
    // A ring follows the control's visible bounds, with a minimum size for tiny
    // OCR words. Display clipping never changes the actual target coordinates.
    let width = max(24, bounds.width + 12)
    let height = max(24, bounds.height + 12)
    let ring = CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                      width: width, height: height)
    let badgeSize: CGFloat = 30
    let centers = [CGPoint(x: ring.minX + 9, y: ring.maxY - 5),
                   CGPoint(x: ring.maxX - 9, y: ring.maxY - 5),
                   CGPoint(x: ring.minX + 9, y: ring.minY + 5),
                   CGPoint(x: ring.maxX - 9, y: ring.minY + 5),
                   CGPoint(x: ring.midX, y: ring.maxY + 10),
                   CGPoint(x: ring.midX, y: ring.minY - 10)]
    func badge(at center: CGPoint) -> CGRect {
        CGRect(x: max(screen.minX + 2, min(center.x - badgeSize / 2, screen.maxX - badgeSize - 2)),
               y: max(screen.minY + 2, min(center.y - badgeSize / 2, screen.maxY - badgeSize - 2)),
               width: badgeSize, height: badgeSize)
    }
    var proposals = centers.map { badge(at: $0) }
    // Dense rows of small labels can share the first corners. Look just outside
    // the control before accepting an overlap; numbering itself stays unchanged.
    for distance in 1...4 {
        for direction in [-1, 1] {
            proposals.append(badge(at: CGPoint(x: ring.midX + CGFloat(direction * distance) * 34,
                                               y: ring.maxY + 10)))
            proposals.append(badge(at: CGPoint(x: ring.midX + CGFloat(direction * distance) * 34,
                                               y: ring.minY - 10)))
        }
    }
    let selected = proposals.first { proposal in
        !occupied.contains { $0.insetBy(dx: -2, dy: -2).intersects(proposal) }
    } ?? proposals.min { lhs, rhs in
        func overlap(_ rect: CGRect) -> CGFloat {
            occupied.reduce(0) { total, other in
                let intersection = rect.intersection(other)
                return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
            }
        }
        return overlap(lhs) < overlap(rhs)
    }!
    return DuplicateMark(number: number, ring: ring, badge: selected)
}

private final class DuplicateOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DuplicateOverlayView: NSView {
    var marks: [DuplicateMark] = []
    private let accent = NSColor(srgbRed: 0.25, green: 0.94, blue: 0.98, alpha: 1)

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        // Draw all rings before all badges so an overlapping ring cannot hide a
        // spoken number. The dark under-stroke remains legible on light pages.
        for mark in marks {
            let ring = NSBezierPath(ovalIn: mark.ring)
            NSColor.black.withAlphaComponent(0.8).setStroke()
            ring.lineWidth = 5
            ring.stroke()
            accent.setStroke()
            ring.lineWidth = 2.5
            ring.stroke()
            if !mark.ring.insetBy(dx: -12, dy: -12).contains(CGPoint(x: mark.badge.midX, y: mark.badge.midY)) {
                let connector = NSBezierPath()
                connector.move(to: CGPoint(x: mark.ring.midX, y: mark.ring.midY))
                connector.line(to: CGPoint(x: mark.badge.midX, y: mark.badge.midY))
                NSColor.black.withAlphaComponent(0.8).setStroke()
                connector.lineWidth = 4
                connector.stroke()
                accent.setStroke()
                connector.lineWidth = 1.5
                connector.stroke()
            }
        }
        for mark in marks {
            let badge = NSBezierPath(ovalIn: mark.badge)
            NSColor(srgbRed: 0.025, green: 0.07, blue: 0.10, alpha: 0.98).setFill()
            badge.fill()
            accent.setStroke()
            badge.lineWidth = 2
            badge.stroke()
            let text = String(mark.number) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: mark.number >= 100 ? 13 : 17, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: mark.badge.midX - size.width / 2,
                                  y: mark.badge.midY - size.height / 2), withAttributes: attributes)
        }
    }
}

final class DuplicateTargetOverlay {
    private var panels: [DuplicateOverlayPanel] = []
    private var timer: Timer?
    private var suspended = false
    private var onExpire: ((String) -> Void)?
    private(set) var choiceID: String?
    private(set) var expiresAt: TimeInterval = 0

    var isVisible: Bool {
        choiceID != nil && !suspended && !panels.isEmpty && ProcessInfo.processInfo.systemUptime < expiresAt
    }

    /// Returns true only when every supplied number can be drawn on its display.
    /// duration is relative to systemUptime; suspension never renews the deadline.
    @discardableResult
    func show(choiceID: String, options: [NumberedTarget], duration: TimeInterval,
              onExpire: @escaping (String) -> Void) -> Bool {
        precondition(Thread.isMainThread)
        hide()
        guard !choiceID.isEmpty, choiceID.count <= 100, (2...100).contains(options.count),
              duration.isFinite, duration > 0, duration <= 30,
              Set(options.map { $0.number }).count == options.count,
              Set(options.map { $0.id }).count == options.count else { return false }

        var groups: [CGDirectDisplayID: (screen: NSScreen, marks: [DuplicateMark])] = [:]
        for option in options {
            guard (1...100).contains(option.number), !option.id.isEmpty,
                  [option.point.x, option.point.y, option.bounds.minX, option.bounds.minY,
                   option.bounds.width, option.bounds.height].allSatisfy({ $0.isFinite }),
                  option.bounds.width > 0, option.bounds.height > 0,
                  let screen = NSScreen.screens.first(where: { screen in
                      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                      return CGDisplayBounds(number.uint32Value).contains(option.point)
                  }),
                  let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            else { return false }
            let bounds = duplicateScreenRect(option.bounds, quartzBounds: CGDisplayBounds(display), appKitFrame: screen.frame)
            let occupied = groups[display]?.marks.map { $0.badge } ?? []
            let mark = duplicateMark(number: option.number, bounds: bounds, screen: screen.frame, occupied: occupied)
            if groups[display] == nil { groups[display] = (screen, []) }
            groups[display]?.marks.append(mark)
        }
        for group in groups.values {
            let screenFrame = group.screen.frame
            let frame = group.marks.reduce(CGRect.null) { $0.union($1.ring.insetBy(dx: -4, dy: -4)).union($1.badge.insetBy(dx: -2, dy: -2)) }
                .intersection(screenFrame)
            guard !frame.isNull, !frame.isEmpty else { hide(); return false }
            let panel = DuplicateOverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                               backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.animationBehavior = .none
            panel.isReleasedWhenClosed = false
            let content = DuplicateOverlayView(frame: CGRect(origin: .zero, size: frame.size))
            content.setAccessibilityElement(false)
            content.marks = group.marks.map {
                DuplicateMark(number: $0.number, ring: $0.ring.offsetBy(dx: -frame.minX, dy: -frame.minY),
                              badge: $0.badge.offsetBy(dx: -frame.minX, dy: -frame.minY))
            }
            panel.contentView = content
            panels.append(panel)
        }
        self.choiceID = choiceID
        self.expiresAt = ProcessInfo.processInfo.systemUptime + duration
        self.onExpire = onExpire
        suspended = false
        panels.forEach { $0.orderFrontRegardless(); $0.displayIfNeeded() }
        let expiryTimer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in self?.expireIfNeeded() }
        timer = expiryTimer
        RunLoop.main.add(expiryTimer, forMode: .common)
        return true
    }

    func hide() {
        precondition(Thread.isMainThread)
        timer?.invalidate()
        timer = nil
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll()
        choiceID = nil
        expiresAt = 0
        onExpire = nil
        suspended = false
    }

    func suspend() {
        precondition(Thread.isMainThread)
        expireIfNeeded()
        suspended = true
        panels.forEach { $0.orderOut(nil) }
    }

    @discardableResult
    func resume(choiceID: String) -> Bool {
        precondition(Thread.isMainThread)
        expireIfNeeded()
        guard self.choiceID == choiceID else { return false }
        suspended = false
        panels.forEach { $0.orderFrontRegardless(); $0.displayIfNeeded() }
        return true
    }

    private func expireIfNeeded() {
        guard let expiredID = choiceID, ProcessInfo.processInfo.systemUptime >= expiresAt else { return }
        let callback = onExpire
        hide()
        callback?(expiredID)
    }
}

/// Pure checks need no panels, camera, microphone, screen capture, or input.
func duplicateTargetOverlayGeometrySelfTest() -> (tests: Int, failures: [String]) {
    var failures: [String] = []
    var tests = 0
    func check(_ condition: Bool, _ message: String) { tests += 1; if !condition { failures.append(message) } }
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let rect = CGRect(x: 120, y: 60, width: 100, height: 40)
    check(duplicateScreenRect(rect, quartzBounds: screen, appKitFrame: screen) == CGRect(x: 120, y: 800, width: 100, height: 40),
          "Target rectangles convert from Quartz top-left to AppKit bottom-left without pixel scaling")
    let externalQuartz = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
    let externalAppKit = CGRect(x: -1920, y: -280, width: 1920, height: 1080)
    check(duplicateScreenRect(CGRect(x: -1800, y: 200, width: 90, height: 50), quartzBounds: externalQuartz,
                               appKitFrame: externalAppKit) == CGRect(x: -1800, y: 650, width: 90, height: 50),
          "Each display's own origin is used for numbered target bounds")
    for point in [CGPoint(x: 0, y: 0), CGPoint(x: 1440, y: 900), CGPoint(x: 720, y: 450)] {
        let bounds = CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
        let mark = duplicateMark(number: 100, bounds: bounds, screen: screen, occupied: [])
        check(mark.ring.midX == point.x && mark.ring.midY == point.y,
              "Screen-edge clipping preserves the circled target's center")
        check(screen.contains(mark.badge), "Three-digit number badges remain completely on screen")
        check(mark.ring.width >= 24 && mark.ring.height >= 24, "Small OCR targets get a visible minimum ring")
    }
    let first = duplicateMark(number: 1, bounds: rect, screen: screen, occupied: [])
    let second = duplicateMark(number: 2, bounds: rect, screen: screen, occupied: [first.badge])
    check(!first.badge.intersects(second.badge), "Coincident labels use separate readable number badges")
    check(first.number == 1 && second.number == 2, "Badge placement never changes supplied numbering")
    return (tests, failures)
}
