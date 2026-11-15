// Read-only, entirely local target discovery. AX supplies accessible control
// names (including icons); Vision supplies text where an app has no AX labels.
import AppKit
import ApplicationServices
import Vision

/// Shared caption identity for merging discovery results and checking a target
/// again immediately before moving. This performs no application access.
func screenTargetLabelKey(_ label: String) -> String {
    // Match the selector's NFKC, case, punctuation and Chinese spacing
    // normalization so two readings of one caption cannot become fake
    // duplicates (for example Save As… versus Save As...).
    let folded = label.precomposedStringWithCompatibilityMapping
        .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .replacingOccurrences(of: "&", with: " and ")
    let characters = folded.unicodeScalars.map { scalar -> String in
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber: return String(scalar)
        default: return " "
        }
    }.joined().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return characters.replacingOccurrences(of: "(?<=[\\u3400-\\u9fff])\\s+|\\s+(?=[\\u3400-\\u9fff])",
                                          with: "", options: .regularExpression)
}

/// Return fresh coordinates only when one nearby, similarly sized control still
/// has the same canonical caption. Discovery IDs are request-local, so they do
/// not identify a control across captures. Never guess between nearby duplicates.
func revalidatedScreenTarget(_ original: [String: Any], in candidates: [[String: Any]]) -> CGPoint? {
    func geometry(_ value: [String: Any]) -> [Double]? {
        var numbers: [Double] = []
        for field in ["x", "y", "width", "height"] {
            guard let number = value[field] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite else { return nil }
            numbers.append(number.doubleValue)
        }
        guard numbers[2] > 0, numbers[3] > 0 else { return nil }
        return numbers
    }
    guard let label = original["label"] as? String,
          let bounds = geometry(original) else { return nil }
    let key = screenTargetLabelKey(label)
    guard !key.isEmpty else { return nil }
    var point: CGPoint?
    for candidate in candidates {
        guard let caption = candidate["label"] as? String, screenTargetLabelKey(caption) == key,
              let fresh = geometry(candidate),
              abs(fresh[0] - bounds[0]) <= 12, abs(fresh[1] - bounds[1]) <= 12,
              abs(fresh[2] - bounds[2]) <= max(4, min(12, bounds[2] * 0.15)),
              abs(fresh[3] - bounds[3]) <= max(4, min(12, bounds[3] * 0.15)) else { continue }
        if point != nil { return nil }
        point = CGPoint(x: fresh[0], y: fresh[1])
    }
    return point
}

private struct ScreenTarget {
    let label: String
    let rect: CGRect
    let source: String
    let confidence: Double
    let role: String
    let key: String

    init(label: String, rect: CGRect, source: String, confidence: Double, role: String = "") {
        self.label = label
        self.rect = rect
        self.source = source
        self.confidence = confidence
        self.role = role
        self.key = screenTargetLabelKey(label)
    }
    func json(_ index: Int) -> [String: Any] {
        ["id": "target-\(index)", "label": String(label.prefix(200)),
         "x": rect.midX, "y": rect.midY, "width": rect.width, "height": rect.height,
         "source": source, "confidence": confidence, "role": role]
    }
}

private func usableTargetRect(_ rect: CGRect) -> Bool {
    !rect.isNull && !rect.isInfinite && rect.minX.isFinite && rect.minY.isFinite &&
        rect.width.isFinite && rect.height.isFinite && rect.width >= 2 && rect.height >= 2
}

private func targetRect(_ normalized: CGRect, in region: CGRect) -> CGRect {
    CGRect(x: region.minX + normalized.minX * region.width,
           y: region.minY + (1 - normalized.maxY) * region.height,
           width: normalized.width * region.width, height: normalized.height * region.height)
}

private func targetChildClip(role: String, rect: CGRect?, inherited: CGRect, region: CGRect) -> CGRect {
    // A button/group's bounds do not clip its owned popup. Only actual viewports
    // clip descendants; menus/popovers establish their own visible viewport.
    let detached = role == "AXMenu" || role == "AXPopover"
    let clip = detached ? region : inherited
    let viewports: Set<String> = ["AXWindow", "AXScrollArea", "AXList", "AXTable", "AXOutline",
                                  "AXBrowser", "AXWebArea", "AXMenu", "AXPopover"]
    guard viewports.contains(role), let rect = rect else { return clip }
    return clip.intersection(rect)
}

private func sameTargetLocation(_ a: CGRect, _ b: CGRect) -> Bool {
    let overlap = a.intersection(b)
    guard usableTargetRect(overlap) else { return false }
    return overlap.width * overlap.height >= min(a.width * a.height, b.width * b.height) * 0.7
}

private func captionMatchesControl(_ caption: ScreenTarget, _ control: ScreenTarget, sameVisibleElement: Bool = false) -> Bool {
    (sameVisibleElement || sameTargetLocation(control.rect, caption.rect)) &&
        (control.key == caption.key || (" " + control.key + " ").contains(" " + caption.key + " "))
}

private func mergeScreenTargets(_ candidates: [ScreenTarget], pointer: CGPoint, limit: Int = 96) -> [ScreenTarget] {
    // AX is preferred over an OCR box around the same control's caption.
    let accessible = candidates.filter { $0.source == "accessibility" }
    let filtered = candidates.filter { candidate in
        guard candidate.source == "ocr" else { return true }
        // "Save" inside an accessible "Save As" button is a caption fragment,
        // not a second Save control. Keep the real control's full name and box.
        return !accessible.contains { captionMatchesControl(candidate, $0) }
    }
    let ordered = filtered.enumerated().sorted {
        if ($0.element.source == "accessibility") != ($1.element.source == "accessibility") {
            return $0.element.source == "accessibility"
        }
        return $0.offset < $1.offset
    }.map(\.element)
    var merged: [ScreenTarget] = []
    for candidate in ordered where usableTargetRect(candidate.rect) && !candidate.key.isEmpty {
        if merged.contains(where: { $0.key == candidate.key && sameTargetLocation($0.rect, candidate.rect) }) { continue }
        merged.append(candidate)
    }
    return Array(merged.sorted {
        let first = hypot($0.rect.midX - pointer.x, $0.rect.midY - pointer.y)
        let second = hypot($1.rect.midX - pointer.x, $1.rect.midY - pointer.y)
        if abs(first - second) > 0.01 { return first < second }
        if $0.rect.minY != $1.rect.minY { return $0.rect.minY < $1.rect.minY }
        return $0.rect.minX < $1.rect.minX
    }.prefix(max(0, min(100, limit))))
}

private struct OCRWord {
    let label: String
    let rect: CGRect
}

private func groupedOCRWords(_ words: [OCRWord]) -> [[OCRWord]] {
    guard let first = words.first else { return [] }
    var groups = [[first]]
    for word in words.dropFirst() {
        let previous = groups[groups.count - 1].last!
        // A normal inter-word space remains a phrase. Large visual gaps are
        // separate controls even when Vision reports one line for all of them.
        let glyphWidth = min(previous.rect.width / CGFloat(max(1, previous.label.count)),
                             word.rect.width / CGFloat(max(1, word.label.count)))
        let threshold = max(9, min(previous.rect.height, word.rect.height) * 0.6, glyphWidth * 1.5)
        if word.rect.minX - previous.rect.maxX > threshold {
            groups.append([word])
        } else {
            groups[groups.count - 1].append(word)
        }
    }
    return groups
}

private func recognizeScreenText(_ image: CGImage, region: CGRect) throws -> [ScreenTarget] {
    guard usableTargetRect(region) else { return [] }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"]
    request.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    var result: [ScreenTarget] = []
    for observation in (request.results ?? []).prefix(96) {
        if result.count >= 384 { break }
        guard let text = observation.topCandidates(1).first, text.confidence >= 0.3 else { continue }
        let line = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, line.count <= 200 else { continue }
        let lineRect = targetRect(observation.boundingBox, in: region).intersection(region)
        guard usableTargetRect(lineRect) else { continue }
        // Walk Character indices, not UTF-16 offsets or guessed equal-width
        // subdivisions. CJK sequences and composed Unicode stay intact.
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for index in text.string.indices {
            if text.string[index].isWhitespace {
                if let from = start { ranges.append(from..<index); start = nil }
            } else if start == nil { start = index }
        }
        if let from = start { ranges.append(from..<text.string.endIndex) }
        var words: [OCRWord] = []
        for range in ranges.prefix(24) {
            guard let box = try? text.boundingBox(for: range) else { continue }
            let rect = targetRect(box.boundingBox, in: region).intersection(region)
            guard usableTargetRect(rect) else { continue }
            // Some Vision revisions return the entire line for every range.
            // Never misrepresent that box as a precise individual word.
            if ranges.count > 1 && rect.width > lineRect.width * 0.92 { continue }
            words.append(OCRWord(label: String(text.string[range]), rect: rect))
        }
        let groups = groupedOCRWords(words)
        if groups.count > 1 && words.count == ranges.count {
            for group in groups {
                let rect = group.dropFirst().reduce(group[0].rect) { $0.union($1.rect) }
                result.append(ScreenTarget(label: group.map(\.label).joined(separator: " "), rect: rect,
                                           source: "ocr", confidence: Double(text.confidence), role: "text"))
            }
        } else {
            result.append(ScreenTarget(label: line, rect: lineRect, source: "ocr",
                                       confidence: Double(text.confidence), role: "text"))
        }
        if words.count > 1 {
            for word in words {
                result.append(ScreenTarget(label: word.label, rect: word.rect, source: "ocr",
                                           confidence: Double(text.confidence), role: "word"))
            }
        }
    }
    return result
}

/// Pure image recognition, also used by the permission-free generated-image test.
func recognizeScreenTextTargets(_ image: CGImage, region: CGRect) throws -> [[String: Any]] {
    mergeScreenTargets(try recognizeScreenText(image, region: region),
                       pointer: CGPoint(x: region.midX, y: region.midY)).enumerated().map { $0.element.json($0.offset) }
}

private struct TargetWindow {
    let pid: pid_t
    let rect: CGRect
}

private func onScreenTargetWindows(in region: CGRect) -> [TargetWindow] {
    guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else { return [] }
    return entries.compactMap { entry in
        guard let owner = entry[kCGWindowOwnerPID as String] as? NSNumber,
              let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dictionary), usableTargetRect(rect),
              rect.intersects(region), (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.01 else { return nil }
        // Our floating feedback panels are excluded from captured pixels and
        // must not occlude the real targets beneath them in AX/OCR merging.
        if owner.int32Value == ProcessInfo.processInfo.processIdentifier,
           (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0 > 0 { return nil }
        return TargetWindow(pid: owner.int32Value, rect: rect)
    }
}

private struct TargetAXInfo {
    let role: String
    let subrole: String
    let rect: CGRect?
    let hidden: Bool
    let enabled: Bool
    let selected: Bool?
    var secure: Bool { subrole == "AXSecureTextField" || role == "AXSecureTextField" }
    var disabledControl: Bool {
        // AXEnabled describes whether this particular element is interactive.
        // Finder/static labels and read-only containers may report false while
        // their visible contents remain valid pointer targets.
        let controls: Set<String> = ["AXButton", "AXRadioButton", "AXCheckBox", "AXPopUpButton",
            "AXMenuButton", "AXMenuItem", "AXMenuBarItem", "AXLink", "AXTab", "AXTextField",
            "AXComboBox", "AXSlider", "AXIncrementor", "AXScrollBar"]
        return !enabled && controls.contains(role)
    }
}

private final class ScreenAXReader {
    private let system = AXUIElementCreateSystemWide()
    private var deadline: TimeInterval
    private var calls = 0
    private let region: CGRect
    private let windows: [TargetWindow]
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var blockedRects: [CGRect] = []
    private var acceptedControls: [AXUIElement: ScreenTarget] = [:]
    private let namedRoles: Set<String> = ["AXButton", "AXRadioButton", "AXCheckBox", "AXPopUpButton",
        "AXMenuButton", "AXMenuItem", "AXMenuBarItem", "AXLink", "AXTab", "AXImage",
        "AXTextField", "AXComboBox", "AXSlider", "AXIncrementor", "AXRow", "AXCell"]

    init(region: CGRect, windows: [TargetWindow]) {
        self.region = region
        self.windows = windows
        deadline = ProcessInfo.processInfo.systemUptime + 0.9
    }
    private var available: Bool { calls < 1800 && ProcessInfo.processInfo.systemUptime < deadline }
    private func prepare(_ element: AXUIElement) -> Bool {
        guard available else { return false }
        calls += 1
        // The timeout is local to this AX reference. No global timeout changes,
        // permission prompts, attribute writes or AX actions are performed.
        AXUIElementSetMessagingTimeout(element, 0.035)
        return true
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        guard prepare(element) else { return nil }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private func children(_ element: AXUIElement, _ name: String, limit: Int = 64) -> [AXUIElement]? {
        guard prepare(element) else { return nil }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, name as CFString, 0, limit, &values) == .success,
              let array = values as? [AnyObject] else { return nil }
        return array.compactMap { axElement($0) }
    }
    private func info(_ element: AXUIElement) -> TargetAXInfo? {
        guard prepare(element) else { return nil }
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute,
                     kAXHiddenAttribute, kAXEnabledAttribute, kAXSelectedAttribute]
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values) == .success,
              let array = values as? [AnyObject], array.count == names.count else { return nil }
        var rect: CGRect?
        if CFGetTypeID(array[2]) == AXValueGetTypeID(), CFGetTypeID(array[3]) == AXValueGetTypeID() {
            let position = unsafeBitCast(array[2], to: AXValue.self)
            let size = unsafeBitCast(array[3], to: AXValue.self)
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            if AXValueGetType(position) == .cgPoint && AXValueGetType(size) == .cgSize &&
                AXValueGetValue(position, .cgPoint, &point) && AXValueGetValue(size, .cgSize, &dimensions) {
                rect = CGRect(origin: point, size: dimensions)
            }
        }
        return TargetAXInfo(role: array[0] as? String ?? "", subrole: array[1] as? String ?? "", rect: rect,
                            hidden: (array[4] as? NSNumber)?.boolValue == true,
                            enabled: (array[5] as? NSNumber)?.boolValue != false,
                            selected: (array[6] as? NSNumber)?.boolValue)
    }
    private func hit(_ point: CGPoint) -> AXUIElement? {
        guard prepare(system) else { return nil }
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element = element else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != ownPID else { return nil }
        return element
    }
    private func visible(_ element: AXUIElement, at point: CGPoint) -> Bool {
        guard var current = hit(point) else { return false }
        // Equality with the hit element or one of its parents is evidence that
        // this exact control, not a hidden sibling with the same bounds, is shown.
        for _ in 0..<10 {
            if CFEqual(current, element) { return true }
            guard let parent = axElement(attribute(current, kAXParentAttribute)), !CFEqual(parent, current) else { break }
            current = parent
        }
        return false
    }
    private func label(_ element: AXUIElement) -> String? {
        // Never request AXValue, AXSelectedText, text ranges, or document contents.
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            if let raw = attribute(element, name) as? String {
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty && value.count <= 200 { return value }
            }
        }
        return nil
    }

    func collect(pointer: CGPoint) -> [ScreenTarget] {
        guard AXIsProcessTrusted() else { return [] }
        struct Pending { let element: AXUIElement; let clip: CGRect; let depth: Int }
        var queue: [Pending] = []
        var pids: [pid_t] = []
        let pointerOwner = windows.first(where: { $0.rect.contains(pointer) })?.pid
        if let pid = pointerOwner, pid != ownPID { pids.append(pid) }
        for window in windows where window.pid != ownPID && !pids.contains(window.pid) {
            pids.append(window.pid)
        }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let pid = frontPID, pid != ownPID, !pids.contains(pid) { pids.append(pid) }
        for pid in pids.prefix(8) where available {
            let application = AXUIElementCreateApplication(pid)
            if (attribute(application, kAXHiddenAttribute) as? NSNumber)?.boolValue == true { continue }
            for window in children(application, kAXWindowsAttribute, limit: 16) ?? [] {
                guard let metadata = info(window), !metadata.hidden, let frame = metadata.rect,
                      usableTargetRect(frame), frame.intersects(region),
                      windows.contains(where: { $0.pid == pid && sameTargetLocation($0.rect, frame) }) else { continue }
                queue.append(Pending(element: window, clip: frame.intersection(region), depth: 0))
            }
            if pid == frontPID, let menuBar = axElement(attribute(application, kAXMenuBarAttribute)) {
                queue.append(Pending(element: menuBar, clip: region, depth: 0))
            }
        }
        // Open menus/popovers need not be listed in AXWindows. A visible hit and
        // a bounded climb seed their tree without traversing application roots.
        for point in [pointer, CGPoint(x: region.midX, y: region.midY),
                      CGPoint(x: region.minX + 8, y: region.minY + 8),
                      CGPoint(x: region.maxX - 8, y: region.minY + 8)] where region.contains(point) && available {
            guard var element = hit(point) else { continue }
            for _ in 0..<6 {
                guard let metadata = info(element) else { break }
                if ["AXWindow", "AXMenu", "AXMenuBar", "AXPopover"].contains(metadata.role) {
                    queue.insert(Pending(element: element, clip: region, depth: 0), at: 0)
                    break
                }
                guard let parent = axElement(attribute(element, kAXParentAttribute)), !CFEqual(parent, element) else { break }
                element = parent
            }
        }
        var visited = Set<AXUIElement>()
        var result: [ScreenTarget] = []
        var index = 0
        while index < queue.count && visited.count < 480 && available && result.count < 144 {
            let item = queue[index]; index += 1
            guard visited.insert(item.element).inserted, item.depth <= 12,
                  let metadata = info(item.element) else { continue }
            if metadata.hidden { continue }
            if metadata.secure || metadata.disabledControl {
                if let frame = metadata.rect, usableTargetRect(frame), frame.intersects(item.clip),
                   visible(item.element, at: CGPoint(x: frame.midX, y: frame.midY)) {
                    blockedRects.append(frame)
                }
                continue
            }
            let clip = ["AXMenu", "AXPopover"].contains(metadata.role) ? region : item.clip
            if let frame = metadata.rect {
                guard usableTargetRect(frame), frame.intersects(clip) else { continue }
            }
            if namedRoles.contains(metadata.role), let frame = metadata.rect {
                let rect = frame.intersection(clip)
                if usableTargetRect(rect), visible(item.element, at: CGPoint(x: rect.midX, y: rect.midY)),
                   let name = label(item.element) {
                    let target = ScreenTarget(label: name, rect: rect, source: "accessibility", confidence: 1,
                                              role: metadata.role)
                    result.append(target)
                    acceptedControls[item.element] = target
                }
            }
            // Tab selectors themselves remain candidates; their inactive page
            // contents are never visited. Prefer the app's visible child list.
            if ["AXTab", "AXRadioButton"].contains(metadata.role) { continue }
            if metadata.role == "AXTextField" || metadata.role == "AXTextArea" { continue }
            let descendants = children(item.element, kAXVisibleChildrenAttribute) ?? children(item.element, kAXChildrenAttribute) ?? []
            let childClip = targetChildClip(role: metadata.role, rect: metadata.rect, inherited: clip, region: region)
            for child in descendants where queue.count < 800 {
                queue.append(Pending(element: child, clip: childClip, depth: item.depth + 1))
            }
        }
        return result
    }

    func filterOCR(_ candidates: [ScreenTarget]) -> [ScreenTarget] {
        // The screenshot already contains only visible pixels. AX, when usable,
        // additionally excludes secure/disabled controls instead of re-adding
        // their captions through the OCR fallback.
        deadline = ProcessInfo.processInfo.systemUptime + 0.35
        calls = 0
        let trusted = AXIsProcessTrusted()
        return candidates.filter { candidate in
            let point = CGPoint(x: candidate.rect.midX, y: candidate.rect.midY)
            if windows.first(where: { $0.rect.contains(point) })?.pid == ownPID { return false }
            if blockedRects.contains(where: { $0.contains(point) }) { return false }
            guard trusted, available, var current = hit(point) else { return true }
            for _ in 0..<6 {
                guard let metadata = info(current) else { break }
                if metadata.secure || metadata.hidden || metadata.disabledControl { return false }
                // Finder's caption can sit below the AXImage's frame while
                // hit-testing to that very image. Identity proves one control
                // without merging genuinely separate equal-labelled folders.
                if let control = acceptedControls[current], captionMatchesControl(candidate, control, sameVisibleElement: true) {
                    return false
                }
                if metadata.role == "AXWindow" || metadata.role == "AXApplication" { break }
                guard let parent = axElement(attribute(current, kAXParentAttribute)), !CFEqual(parent, current) else { break }
                current = parent
            }
            return true
        }
    }
}

/// All coordinates are Quartz global screen points (top-left origin). Passing a
/// nil image still permits AX discovery when screen recording is unavailable.
func collectScreenTargets(image: CGImage?, region: CGRect, pointer: CGPoint) -> [[String: Any]] {
    guard usableTargetRect(region), pointer.x.isFinite, pointer.y.isFinite else { return [] }
    let windows = onScreenTargetWindows(in: region)
    let reader = ScreenAXReader(region: region, windows: windows)
    let accessible = reader.collect(pointer: pointer)
    let recognized = image.flatMap { try? recognizeScreenText($0, region: region) } ?? []
    let visibleText = reader.filterOCR(mergeScreenTargets(recognized, pointer: pointer, limit: 100))
    return mergeScreenTargets(accessible + visibleText, pointer: pointer).enumerated().map { $0.element.json($0.offset) }
}

/// Returns failure descriptions; no TCC permissions, screens, or apps are used.
func screenTargetGeometrySelfTest() -> (tests: Int, failures: [String]) {
    var failures: [String] = []
    var tests = 0
    func check(_ condition: Bool, _ message: String) { tests += 1; if !condition { failures.append(message) } }
    let region = CGRect(x: 100, y: 200, width: 640, height: 180)
    let converted = targetRect(CGRect(x: 0.25, y: 0.5, width: 0.2, height: 0.25), in: region)
    check(converted == CGRect(x: 260, y: 245, width: 128, height: 45), "Vision geometry converts to global top-left screen points")
    let ax = ScreenTarget(label: "Save", rect: CGRect(x: 10, y: 10, width: 100, height: 40), source: "accessibility", confidence: 1)
    let caption = ScreenTarget(label: " save ", rect: CGRect(x: 35, y: 20, width: 40, height: 15), source: "ocr", confidence: 0.9)
    let other = ScreenTarget(label: "Save", rect: CGRect(x: 170, y: 10, width: 100, height: 40), source: "accessibility", confidence: 1)
    let merged = mergeScreenTargets([caption, other, ax], pointer: CGPoint(x: 60, y: 30))
    check(merged.count == 2 && merged.first?.source == "accessibility", "AX/OCR duplicate collapses while two real Save buttons remain")
    check(merged.first?.rect == ax.rect, "Merged label retains actionable AX control bounds")
    let saveAs = ScreenTarget(label: "Save As", rect: CGRect(x: 300, y: 10, width: 100, height: 40), source: "accessibility", confidence: 1)
    let fragment = ScreenTarget(label: "Save", rect: CGRect(x: 320, y: 20, width: 30, height: 15), source: "ocr", confidence: 0.9, role: "word")
    let withoutFragments = mergeScreenTargets([ax, saveAs, fragment], pointer: .zero)
    check(withoutFragments.count == 2 && withoutFragments.filter({ $0.label == "Save" }).count == 1,
          "OCR word inside Save As does not invent a second Save control")
    let punctuated = ScreenTarget(label: "Ｓave As…", rect: saveAs.rect, source: "ocr", confidence: 0.9)
    check(mergeScreenTargets([saveAs, punctuated], pointer: .zero).count == 1,
          "Full-width letters and ellipsis agree with selector normalization")
    let chinese = ScreenTarget(label: "打开 设置", rect: ax.rect, source: "ocr", confidence: 0.9)
    check(chinese.key == "打开设置", "Chinese spacing agrees with selector normalization")
    let separate = groupedOCRWords([
        OCRWord(label: "Codex", rect: CGRect(x: 10, y: 20, width: 60, height: 20)),
        OCRWord(label: "Safari", rect: CGRect(x: 210, y: 20, width: 65, height: 20)),
        OCRWord(label: "Finder", rect: CGRect(x: 410, y: 20, width: 60, height: 20))])
    check(separate.count == 3, "Separate labels on one OCR line have separate geometrical groups")
    let phrase = groupedOCRWords([
        OCRWord(label: "Sign", rect: CGRect(x: 10, y: 20, width: 38, height: 20)),
        OCRWord(label: "In", rect: CGRect(x: 54, y: 20, width: 15, height: 20))])
    check(phrase.count == 1, "Natural spaces preserve multi-word labels")
    let owner = CGRect(x: 120, y: 220, width: 60, height: 24)
    check(targetChildClip(role: "AXMenuBarItem", rect: owner, inherited: region, region: region) == region,
          "Menu owner bounds do not clip an opened submenu")
    check(targetChildClip(role: "AXScrollArea", rect: owner, inherited: region, region: region) == owner,
          "Scroll view viewport still clips offscreen descendants")
    let popup = CGRect(x: 130, y: 255, width: 180, height: 90)
    check(targetChildClip(role: "AXMenu", rect: popup, inherited: owner, region: region) == popup,
          "Detached popup establishes its own viewport outside owner bounds")
    check(!usableTargetRect(CGRect(x: 0, y: 0, width: 0, height: 5)), "Zero-area targets rejected")
    check(mergeScreenTargets([ax, caption, other], pointer: .zero, limit: 1).count == 1, "Candidate output is bounded")
    for role in ["AXStaticText", "AXGroup", "AXScrollArea", "AXImage"] {
        check(!TargetAXInfo(role: role, subrole: "", rect: nil, hidden: false, enabled: false, selected: nil).disabledControl,
              "Read-only \(role) does not hide visible content")
    }
    check(TargetAXInfo(role: "AXButton", subrole: "", rect: nil, hidden: false, enabled: false, selected: nil).disabledControl,
          "Disabled actionable button remains excluded")
    let icon = ScreenTarget(label: "Reports", rect: CGRect(x: 435, y: 106, width: 64, height: 64), source: "accessibility", confidence: 1)
    let iconCaption = ScreenTarget(label: "Reports", rect: CGRect(x: 440, y: 178, width: 54, height: 14), source: "ocr", confidence: 1)
    check(captionMatchesControl(iconCaption, icon, sameVisibleElement: true),
          "Caption hit-testing to the same icon is merged outside the icon rectangle")
    check(!captionMatchesControl(iconCaption, icon),
          "Separate nonoverlapping equal labels are not merged without AX identity")
    let original = ax.json(0)
    var moved = original
    moved["x"] = ax.rect.midX + 12
    moved["y"] = ax.rect.midY - 12
    moved["id"] = "new-discovery-id"
    moved["label"] = " ＳＡＶＥ… "
    check(revalidatedScreenTarget(original, in: [moved]) == CGPoint(x: ax.rect.midX + 12, y: ax.rect.midY - 12),
          "Final revalidation returns fresh coordinates for a small move and equivalent caption")
    check(revalidatedScreenTarget(original, in: []) == nil,
          "A disappeared control cannot receive a delayed pointer move")
    check(revalidatedScreenTarget(original, in: [original, moved]) == nil,
          "Two nearby equal captions make final revalidation ambiguous")
    var renamed = moved
    renamed["label"] = "Delete"
    check(revalidatedScreenTarget(original, in: [renamed]) == nil,
          "A renamed control is rejected even at the same coordinates")
    var distant = moved
    distant["x"] = ax.rect.midX + 12.01
    check(revalidatedScreenTarget(original, in: [distant]) == nil,
          "Horizontal layout movement beyond the tolerance cancels the target")
    distant["x"] = ax.rect.midX
    distant["y"] = ax.rect.midY - 12.01
    check(revalidatedScreenTarget(original, in: [distant]) == nil,
          "Vertical layout movement beyond the tolerance cancels the target")
    var resized = original
    resized["width"] = ax.rect.width + 12
    resized["height"] = ax.rect.height + 6
    check(revalidatedScreenTarget(original, in: [resized]) != nil,
          "Small size changes remain inside the capped proportional tolerance")
    resized["width"] = ax.rect.width + 12.01
    check(revalidatedScreenTarget(original, in: [resized]) == nil,
          "A substantially resized width no longer identifies the original control")
    resized["width"] = ax.rect.width
    resized["height"] = ax.rect.height + 6.01
    check(revalidatedScreenTarget(original, in: [resized]) == nil,
          "Height tolerance scales with the original control rather than the fresh size")
    for field in ["x", "y", "width", "height"] {
        var malformed = original
        malformed[field] = true
        check(revalidatedScreenTarget(original, in: [malformed]) == nil,
              "Boolean \(field) is rejected in fresh target geometry")
        check(revalidatedScreenTarget(malformed, in: [original]) == nil,
              "Boolean \(field) is rejected in original target geometry")
    }
    for value in [Double.nan, Double.infinity, -Double.infinity] {
        var malformed = original
        malformed["x"] = value
        check(revalidatedScreenTarget(original, in: [malformed]) == nil,
              "Nonfinite target coordinates cannot pass final revalidation")
    }
    var empty = original
    empty["width"] = 0
    check(revalidatedScreenTarget(original, in: [empty]) == nil,
          "Zero-width target geometry is rejected")
    empty["width"] = -10
    check(revalidatedScreenTarget(original, in: [empty]) == nil,
          "Negative-width target geometry is rejected")
    empty = original
    empty["label"] = "…"
    check(revalidatedScreenTarget(empty, in: [empty]) == nil,
          "Punctuation-only captions cannot identify a target")
    check(screenTargetLabelKey("打开 设置") == "打开设置" && screenTargetLabelKey("Save & Exit…") == "save and exit",
          "Final revalidation uses the same Chinese, punctuation and ampersand normalization as discovery")
    return (tests, failures)
}
