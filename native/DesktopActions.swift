// System actions stay separate from recognition and from the voice model.
// Constructing events below is side-effect free; only the controller posts them.
import AppKit
import ApplicationServices

enum PointerClickAction: String {
    case left = "click"
    case right = "right_click"
    case double = "double_click"
}

func makePointerClickEvents(_ action: PointerClickAction, at point: CGPoint) -> [CGEvent]? {
    guard point.x.isFinite, point.y.isFinite else { return nil }
    let button: CGMouseButton = action == .right ? .right : .left
    let down: CGEventType = action == .right ? .rightMouseDown : .leftMouseDown
    let up: CGEventType = action == .right ? .rightMouseUp : .leftMouseUp
    let count = action == .double ? 2 : 1
    var events: [CGEvent] = []
    for click in 1...count {
        guard let press = CGEvent(mouseEventSource: nil, mouseType: down,
                                  mouseCursorPosition: point, mouseButton: button),
              let release = CGEvent(mouseEventSource: nil, mouseType: up,
                                    mouseCursorPosition: point, mouseButton: button) else { return nil }
        // A double click is two complete clicks, with the second pair marked 2.
        // There must be no earlier single click at the beginning of a held pinch.
        press.setIntegerValueField(.mouseEventClickState, value: Int64(click))
        release.setIntegerValueField(.mouseEventClickState, value: Int64(click))
        events.append(contentsOf: [press, release])
    }
    return events
}

func showMissionControl(completion: @escaping (Error?) -> Void) {
    let application = URL(fileURLWithPath: "/System/Applications/Mission Control.app", isDirectory: true)
    guard FileManager.default.fileExists(atPath: application.path) else {
        DispatchQueue.main.async {
            completion(NSError(domain: "LocalControl", code: 30,
                               userInfo: [NSLocalizedDescriptionKey: "The macOS Mission Control application is unavailable."]))
        }
        return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.addsToRecentItems = false
    // Launch the bundled local app through the public API. This works even if
    // the user has changed or disabled the default Control-Up keyboard shortcut.
    // Opening Mission Control follows macOS behavior, including its existing
    // desktop/Spaces settings; no window is minimized, moved or closed here.
    NSWorkspace.shared.openApplication(at: application, configuration: configuration) { _, error in
        DispatchQueue.main.async { completion(error) }
    }
}

/// Exercise event contents without posting input or opening Mission Control.
func desktopActionSelfTest() -> (tests: Int, failures: [String]) {
    var tests = 0
    var failures: [String] = []
    func check(_ condition: Bool, _ message: String) { tests += 1; if !condition { failures.append(message) } }
    let point = CGPoint(x: 417.25, y: 206.5)
    let single = makePointerClickEvents(.left, at: point) ?? []
    check(single.map(\.type) == [.leftMouseDown, .leftMouseUp], "Single click has exactly one down/up pair")
    check(single.map { $0.getIntegerValueField(.mouseEventClickState) } == [1, 1], "Single click state is one on both edges")
    let right = makePointerClickEvents(.right, at: point) ?? []
    check(right.map(\.type) == [.rightMouseDown, .rightMouseUp], "Right click retains right mouse event types")
    check(right.allSatisfy { $0.getIntegerValueField(.mouseEventButtonNumber) == Int64(CGMouseButton.right.rawValue) },
          "Right click retains right button identity")
    let double = makePointerClickEvents(.double, at: point) ?? []
    check(double.map(\.type) == [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp],
          "Double click has exactly two complete clicks and no preliminary third click")
    check(double.map { $0.getIntegerValueField(.mouseEventClickState) } == [1, 1, 2, 2],
          "Second double-click pair carries click count two")
    check((single + right + double).allSatisfy { $0.location == point }, "Every click edge uses the same captured pointer point")
    check(makePointerClickEvents(.double, at: CGPoint(x: Double.nan, y: 0)) == nil, "Nonfinite horizontal coordinates are rejected")
    check(makePointerClickEvents(.left, at: CGPoint(x: 0, y: Double.infinity)) == nil, "Nonfinite vertical coordinates are rejected")
    return (tests, failures)
}
