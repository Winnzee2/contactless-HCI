// System actions stay separate from recognition and from the voice model.
// Constructing events below is side-effect free; only the controller posts them.
import AppKit
import ApplicationServices

enum PointerClickAction: String {
    case left = "click"
    case right = "right_click"
    case double = "double_click"
}

func makePointerClickEvents(_ action: PointerClickAction, at point: CGPoint, clickCount: Int64 = 1) -> [CGEvent]? {
    guard point.x.isFinite, point.y.isFinite, (1...2).contains(clickCount) else { return nil }
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
        press.setIntegerValueField(.mouseEventClickState, value: action == .double ? Int64(click) : clickCount)
        release.setIntegerValueField(.mouseEventClickState, value: action == .double ? Int64(click) : clickCount)
        events.append(contentsOf: [press, release])
    }
    return events
}

/// Construct the standard macOS Finder/browser Back shortcut without posting it.
/// The controller must bind the request to the still-active application before use.
func makeHistoryBackEvents() -> [CGEvent]? {
    // kVK_ANSI_LeftBracket from the local HIToolbox SDK. No transcript or model
    // output can supply a key code, modifier, URL, or arbitrary keyboard action.
    let leftBracket: CGKeyCode = 0x21
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: leftBracket, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: leftBracket, keyDown: false) else { return nil }
    for event in [down, up] {
        event.flags = .maskCommand
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
    }
    return [down, up]
}

enum BrowserTabDirection {
    case left
    case right
}

/// Select the adjacent browser tab without posting input. Command-Shift brackets
/// select tabs by position; Control-Tab can instead use recently visited order.
func makeBrowserTabEvents(_ direction: BrowserTabDirection) -> [CGEvent]? {
    // Fixed kVK_ANSI_LeftBracket / kVK_ANSI_RightBracket codes from HIToolbox.
    // The controller permits this action only in the still-active browser.
    let key: CGKeyCode = direction == .left ? 0x21 : 0x1E
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return nil }
    for event in [down, up] {
        event.flags = [.maskCommand, .maskShift]
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
    }
    return [down, up]
}

private func registeredBrowserMatches(_ identifier: String?, handlers: Set<String>) -> Bool {
    guard let identifier = identifier, !identifier.isEmpty else { return false }
    return handlers.contains(identifier)
}

/// Looking up handlers does not open URLs, access the network, or inspect history.
private func registeredBrowserIdentifiers() -> Set<String> {
    var handlers = Set<String>()
    for scheme in ["https", "http"] {
        guard let url = URL(string: "\(scheme)://example.invalid/") else { continue }
        for application in NSWorkspace.shared.urlsForApplications(toOpen: url) {
            if let bundleID = Bundle(url: application)?.bundleIdentifier { handlers.insert(bundleID) }
        }
    }
    return handlers
}

func isBrowserApplication(bundleIdentifier: String?) -> Bool {
    guard let identifier = bundleIdentifier, !identifier.isEmpty else { return false }
    return registeredBrowserMatches(identifier, handlers: registeredBrowserIdentifiers())
}

private func historyBackMatches(_ identifier: String?, browserHandlers: Set<String>) -> Bool {
    guard let identifier = identifier, !identifier.isEmpty else { return false }
    return identifier == "com.apple.finder" || registeredBrowserMatches(identifier, handlers: browserHandlers)
}

/// Finder uses the same Back shortcut for folder history. Other applications
/// must be locally registered web browsers; names resembling Finder do not qualify.
func supportsHistoryBack(bundleIdentifier: String?) -> Bool {
    guard let identifier = bundleIdentifier, !identifier.isEmpty else { return false }
    let handlers = identifier == "com.apple.finder" ? Set<String>() : registeredBrowserIdentifiers()
    return historyBackMatches(identifier, browserHandlers: handlers)
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
    let second = makePointerClickEvents(.left, at: point, clickCount: 2) ?? []
    check(second.count == 2 && second.allSatisfy { $0.getIntegerValueField(.mouseEventClickState) == 2 },
          "Natural double click emits only its second down/up pair")
    let back = makeHistoryBackEvents() ?? []
    check(back.map(\.type) == [.keyDown, .keyUp], "History Back is exactly one keyboard down/up pair")
    check(back.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 0x21 },
          "History Back uses only the fixed left-bracket key")
    check(back.allSatisfy { $0.flags == .maskCommand }, "History Back has Command and no extra modifiers")
    check(back.allSatisfy { $0.getIntegerValueField(.keyboardEventAutorepeat) == 0 },
          "History Back never requests keyboard repeat")
    for (direction, key): (BrowserTabDirection, Int64) in [(.left, 0x21), (.right, 0x1E)] {
        let events = makeBrowserTabEvents(direction) ?? []
        check(events.map(\.type) == [.keyDown, .keyUp],
              "Tab \(direction) emits exactly one keyboard down/up pair")
        check(events.map { $0.getIntegerValueField(.keyboardEventKeycode) } == [key, key],
              "Tab \(direction) uses its fixed bracket key on both edges")
        check(events.count == 2 && events.allSatisfy { $0.flags == [.maskCommand, .maskShift] },
              "Tab \(direction) has Command-Shift and no extra modifiers")
        check(events.count == 2 && events.allSatisfy { $0.getIntegerValueField(.keyboardEventAutorepeat) == 0 },
              "Tab \(direction) never requests keyboard repeat")
    }
    let handlers: Set<String> = ["com.apple.Safari", "org.example.NewBrowser"]
    check(registeredBrowserMatches("com.apple.Safari", handlers: handlers), "A registered browser is accepted")
    check(registeredBrowserMatches("org.example.NewBrowser", handlers: handlers),
          "New locally registered browsers do not require a hardcoded allowlist")
    check(!registeredBrowserMatches("com.apple.TextEdit", handlers: handlers), "An unrelated editor is rejected")
    check(!registeredBrowserMatches(nil, handlers: handlers), "An unidentified foreground application is rejected")
    check(!registeredBrowserMatches("", handlers: handlers), "An empty application identifier is rejected")
    check(!registeredBrowserMatches("com.apple.Safari", handlers: []), "An empty registry cannot authorize Back")
    check(historyBackMatches("com.apple.finder", browserHandlers: []),
          "Finder supports folder history without being registered as a web browser")
    check(historyBackMatches("com.apple.Safari", browserHandlers: handlers), "Browser history support remains available")
    check(historyBackMatches("org.example.NewBrowser", browserHandlers: handlers), "Custom registered browsers retain Back support")
    for identifier: String? in [nil, "", "com.apple.TextEdit", "com.apple.finder.copy", "org.example.finder", "com.apple.Finder"] {
        check(!historyBackMatches(identifier, browserHandlers: handlers),
              "Missing IDs, unrelated apps, and Finder lookalikes are rejected")
    }
    check(!historyBackMatches("com.apple.Safari", browserHandlers: []),
          "Adding Finder support does not authorize an unregistered browser")
    return (tests, failures)
}
