// Pure gesture recognition and timing. This file never sends mouse/key events,
// opens applications, or requests device access.
import Foundation
import CoreGraphics
import Vision

enum PinchHoldEvent: Equatable {
    case none, began, singleClick, doubleClick, released, cancelled
}

struct HoldPinchLatch {
    static let holdDuration: TimeInterval = 0.7
    private(set) var active = false
    private var ready = false
    private var beganAt: TimeInterval?
    private var fired = false
    private var lastSample: TimeInterval?

    mutating func reset() {
        active = false
        ready = false
        beganAt = nil
        fired = false
        lastSample = nil
    }

    mutating func update(ratio: Double, eligible: Bool, time: TimeInterval) -> PinchHoldEvent {
        guard eligible, ratio.isFinite, ratio >= 0, time.isFinite else {
            let wasActive = active
            reset()
            return wasActive ? .cancelled : .none
        }
        if let previous = lastSample, time < previous || time - previous > 0.4 {
            let wasActive = active
            reset()
            lastSample = time
            ready = ratio >= 0.65
            return wasActive ? .cancelled : .none
        }
        lastSample = time
        if ratio >= 0.65 {
            let wasActive = active
            let alreadyFired = fired
            let elapsed = beganAt.map { time - $0 } ?? 0
            active = false
            beganAt = nil
            fired = false
            ready = true
            guard wasActive else { return .none }
            if alreadyFired { return .released }
            // A release frame may be the first sample after the hold deadline.
            // Still emit exactly one click action, never a preceding single.
            return elapsed + 1e-9 >= Self.holdDuration ? .doubleClick : .singleClick
        }
        if active {
            if !fired, let beganAt = beganAt, time - beganAt + 1e-9 >= Self.holdDuration {
                fired = true
                return .doubleClick
            }
            return .none
        }
        guard ready, ratio <= 0.35 else { return .none }
        ready = false
        active = true
        beganAt = time
        fired = false
        return .began
    }
}

/// Relative wrist motion scrolls only while a deliberately closed pinky pinch is held.
struct ScrollPinchLatch {
    private(set) var active = false
    private var ready = false
    private var anchor: Double?
    private var lastTime: Double?
    mutating func reset() { active = false; ready = false; anchor = nil; lastTime = nil }
    mutating func update(ratio: Double, y: Double, eligible: Bool, time: Double) -> Int32 {
        guard eligible, ratio.isFinite, ratio >= 0, y.isFinite, time.isFinite else { reset(); return 0 }
        if let previous = lastTime, time < previous || time - previous > 0.4 { reset() }
        lastTime = time
        if ratio >= 0.65 { active = false; ready = true; anchor = nil; return 0 }
        if !active {
            guard ready, ratio <= 0.35 else { return 0 }
            active = true; ready = false; anchor = y; return 0
        }
        guard let origin = anchor else { anchor = y; return 0 }
        let delta = y - origin
        guard abs(delta) >= 0.004 else { return 0 }
        anchor = y
        // Vision Y increases upwards: positive wheel deltas scroll towards the top.
        return Int32(max(-100, min(100, delta * 1800)))
    }
}

/// Freeze before contact, with a wider release threshold to avoid jitter.
struct PinchApproachLatch {
    private(set) var active = false
    mutating func reset() { active = false }
    mutating func update(ratio: Double) -> Bool {
        guard ratio.isFinite, ratio >= 0 else { reset(); return false }
        if ratio >= 0.75 { active = false }
        else if ratio <= 0.55 { active = true }
        return active
    }
}

enum HandPose: Equatable {
    case fist, closing, open, other, unknown
}

private enum FingerShape { case curled, extended, intermediate }
private typealias HandJoint = VNHumanHandPoseObservation.JointName

private func handPixelPoint(_ point: CGPoint, size: CGSize) -> CGPoint {
    CGPoint(x: point.x * size.width, y: point.y * size.height)
}
private func handLength(_ first: CGPoint, _ second: CGPoint) -> Double {
    hypot(Double(first.x - second.x), Double(first.y - second.y))
}

private func fingerShape(wrist: CGPoint, mcp: CGPoint, pip: CGPoint, tip: CGPoint, palm: Double) -> FingerShape {
    let proximal = handLength(mcp, pip)
    let distal = handLength(pip, tip)
    guard proximal > palm * 0.08, distal > palm * 0.06 else { return .intermediate }
    let dot = Double((mcp.x - pip.x) * (tip.x - pip.x) + (mcp.y - pip.y) * (tip.y - pip.y))
    let cosine = min(1, max(-1, dot / (proximal * distal)))
    let angle = acos(cosine) * 180 / .pi
    let reach = handLength(mcp, tip) / palm
    let beyondKnuckle = (handLength(wrist, tip) - handLength(wrist, pip)) / palm
    if angle >= 145, reach >= 0.65, beyondKnuckle >= 0.15 { return .extended }
    if reach <= 0.75, angle <= 125 || beyondKnuckle <= 0.05 { return .curled }
    return .intermediate
}

/// Pass only reliable Vision points (the controller uses confidence >= 0.35).
/// Pixel-space distances preserve geometry on non-square camera frames; angles
/// and palm normalization make the decision independent of hand scale/rotation.
func classifyHandPose(joints: [VNHumanHandPoseObservation.JointName: CGPoint], videoSize: CGSize) -> HandPose {
    guard videoSize.width.isFinite, videoSize.height.isFinite,
          videoSize.width > 0, videoSize.height > 0,
          let wristPoint = joints[.wrist], let middlePoint = joints[.middleMCP] else { return .unknown }
    let fingers: [[HandJoint]] = [
        [.indexMCP, .indexPIP, .indexTip], [.middleMCP, .middlePIP, .middleTip],
        [.ringMCP, .ringPIP, .ringTip], [.littleMCP, .littlePIP, .littleTip]
    ]
    let required = [.wrist] + fingers.flatMap { $0 }
    guard required.allSatisfy({ joint in
        guard let point = joints[joint] else { return false }
        return point.x.isFinite && point.y.isFinite
    }) else { return .unknown }
    let wrist = handPixelPoint(wristPoint, size: videoSize)
    let middle = handPixelPoint(middlePoint, size: videoSize)
    let palm = handLength(wrist, middle)
    guard palm > Double(videoSize.height) * 0.015 else { return .unknown }
    let shapes = fingers.map { finger in
        fingerShape(wrist: wrist,
                    mcp: handPixelPoint(joints[finger[0]]!, size: videoSize),
                    pip: handPixelPoint(joints[finger[1]]!, size: videoSize),
                    tip: handPixelPoint(joints[finger[2]]!, size: videoSize), palm: palm)
    }
    let curled = shapes.filter { $0 == .curled }.count
    let extended = shapes.filter { $0 == .extended }.count
    if extended == 4 { return .open }
    // An extended index finger is the normal mouse pose, including a middle-
    // finger pinch. It must never arm the all-windows gesture.
    if shapes[0] == .curled, curled >= 3, extended == 0 { return .fist }
    if shapes[0] == .curled, curled >= 2 { return .closing }
    return .other
}

struct FistOpenLatch {
    static let fistDwell: TimeInterval = 0.35
    static let openDwell: TimeInterval = 0.2
    static let transitionWindow: TimeInterval = 2
    static let cooldown: TimeInterval = 1.5
    private(set) var isEngaged = false
    private var fistBegan: TimeInterval?
    private var fistConfirmed = false
    private var lastFist: TimeInterval?
    private var openBegan: TimeInterval?
    private var lastSample: TimeInterval?
    private var lastTrigger = -Double.infinity

    mutating func reset() {
        isEngaged = false
        fistBegan = nil
        fistConfirmed = false
        lastFist = nil
        openBegan = nil
        lastSample = nil
        // Preserve the cooldown across a pause or tracking interruption.
    }

    mutating func update(pose: HandPose, time: TimeInterval) -> Bool {
        guard time.isFinite, pose != .unknown else { reset(); return false }
        if let previous = lastSample, time < previous || time - previous > 0.4 { reset() }
        lastSample = time
        if time - lastTrigger < Self.cooldown {
            reset()
            lastSample = time
            isEngaged = pose == .closing || pose == .fist
            return false
        }
        if let lastFist = lastFist, time - lastFist > Self.transitionWindow {
            fistConfirmed = false
            self.lastFist = nil
            openBegan = nil
        }
        switch pose {
        case .fist:
            isEngaged = true
            openBegan = nil
            if fistBegan == nil { fistBegan = time }
            if time - fistBegan! + 1e-9 >= Self.fistDwell { fistConfirmed = true }
            if fistConfirmed { lastFist = time }
        case .closing:
            isEngaged = true
            fistBegan = nil
            openBegan = nil
        case .open:
            fistBegan = nil
            isEngaged = fistConfirmed
            guard fistConfirmed else { openBegan = nil; return false }
            if openBegan == nil { openBegan = time }
            if time - openBegan! + 1e-9 >= Self.openDwell {
                lastTrigger = time
                reset()
                return true
            }
        case .other:
            fistBegan = nil
            openBegan = nil
            isEngaged = fistConfirmed
        case .unknown:
            reset()
        }
        return false
    }
}

// Opening the overview is asynchronous, but it must never own input for the
// lifetime of the system launch request. A delayed callback must not prevent
// selecting a window with the hand mouse while the overview remains open.
struct MissionControlTransition {
    static let inputBlockDuration: TimeInterval = 0.75
    static let launchTimeout: TimeInterval = 3
    private var generation: UInt64 = 0
    private var pendingRequest: UInt64?
    private var pendingUntil = -Double.infinity
    private var inputStartedAt = -Double.infinity
    private var inputBlockedUntil = -Double.infinity

    mutating func begin(time: TimeInterval) -> UInt64? {
        guard time.isFinite,
              time + Self.inputBlockDuration > time,
              time + Self.launchTimeout > time,
              (time + Self.launchTimeout).isFinite else { return nil }
        // Duplicate requests are suppressed briefly. A missing callback cannot
        // prevent a fresh deliberate gesture from trying again later.
        if pendingRequest != nil && time < pendingUntil { return nil }
        guard generation < UInt64.max else { return nil }
        generation += 1
        pendingRequest = generation
        pendingUntil = time + Self.launchTimeout
        inputStartedAt = time
        inputBlockedUntil = time + Self.inputBlockDuration
        return generation
    }

    func blocksInput(time: TimeInterval) -> Bool {
        time.isFinite && time >= inputStartedAt && time < inputBlockedUntil
    }

    @discardableResult
    mutating func complete(request: UInt64) -> Bool {
        guard pendingRequest == request else { return false }
        pendingRequest = nil
        pendingUntil = -Double.infinity
        // Success and failure complete the same request. Neither changes the
        // independent animation deadline or re-locks input after it expires.
        return true
    }

    mutating func cancel() {
        pendingRequest = nil
        pendingUntil = -Double.infinity
        inputStartedAt = -Double.infinity
        inputBlockedUntil = -Double.infinity
        if generation < UInt64.max { generation += 1 }
    }
}

/// Temporal traces and synthetic hand geometry; no camera, TCC, or UI needed.
func handGestureSelfTest() -> (tests: Int, failures: [String]) {
    var tests = 0
    var failures: [String] = []
    func check(_ okay: Bool, _ message: String) {
        tests += 1
        if !okay { failures.append(message) }
    }
    var approach = PinchApproachLatch()
    check(!approach.update(ratio: 0.9), "Open fingers allow pointer motion")
    check(approach.update(ratio: 0.54), "Approaching fingers freeze before contact")
    check(approach.update(ratio: 0.68), "Approach hysteresis prevents jitter")
    check(!approach.update(ratio: 0.76), "Opening fingers releases cursor freeze")
    _ = approach.update(ratio: 0.2)
    approach.reset()
    check(!approach.active, "Pause and tracking reset release approach freeze")
    var scroll = ScrollPinchLatch()
    check(scroll.update(ratio: 0.2, y: 0.5, eligible: true, time: 0) == 0 && !scroll.active,
          "Scroll requires an open hand sample before pinching")
    _ = scroll.update(ratio: 0.8, y: 0.5, eligible: true, time: 0.1)
    check(scroll.update(ratio: 0.2, y: 0.5, eligible: true, time: 0.2) == 0 && scroll.active,
          "Starting scroll captures an anchor without a jump")
    check(scroll.update(ratio: 0.5, y: 0.502, eligible: true, time: 0.25) == 0,
          "Scroll ignores small hand jitter and tolerates pinch hysteresis")
    check(scroll.update(ratio: 0.2, y: 0.52, eligible: true, time: 0.3) > 0,
          "Upward hand movement scrolls up")
    check(scroll.update(ratio: 0.2, y: 0.48, eligible: true, time: 0.35) < 0,
          "Downward hand movement reverses scrolling")
    check(scroll.update(ratio: 0.2, y: 0.9, eligible: true, time: 0.4) == 100,
          "Large motion is capped")
    check(scroll.update(ratio: 0.8, y: 0.5, eligible: true, time: 0.45) == 0 && !scroll.active,
          "Releasing pinky immediately stops scrolling")
    _ = scroll.update(ratio: 0.2, y: 0.5, eligible: true, time: 0.5)
    check(scroll.update(ratio: 0.2, y: 0.6, eligible: false, time: 0.55) == 0 && !scroll.active,
          "Conflicting gestures cancel scrolling")
    _ = scroll.update(ratio: 0.8, y: 0.5, eligible: true, time: 0.6)
    _ = scroll.update(ratio: 0.2, y: 0.5, eligible: true, time: 0.65)
    check(scroll.update(ratio: 0.2, y: 0.7, eligible: true, time: 1.2) == 0 && !scroll.active,
          "Tracking gaps never resume a held scroll")
    scroll.reset()
    check(scroll.update(ratio: 0.2, y: 0.7, eligible: true, time: 1.3) == 0 && !scroll.active,
          "Pause reset requires a fresh pinch")
    var pinch = HoldPinchLatch()
    check(pinch.update(ratio: 0.2, eligible: true, time: 0) == .none && !pinch.active,
          "Starting with pinched fingers requires a visible release")
    _ = pinch.update(ratio: 0.8, eligible: true, time: 0.1)
    check(pinch.update(ratio: 0.2, eligible: true, time: 0.2) == .began && pinch.active,
          "Pinch starts a pending action without immediately clicking")
    check(pinch.update(ratio: 0.8, eligible: true, time: 0.35) == .singleClick && !pinch.active,
          "A quick pinch release emits exactly one single click")
    check(pinch.update(ratio: 0.8, eligible: true, time: 0.4) == .none,
          "Continued release does not repeat a single click")
    _ = pinch.update(ratio: 0.2, eligible: true, time: 0.5)
    check(pinch.update(ratio: 0.5, eligible: true, time: 0.8) == .none && pinch.active,
          "Release hysteresis tolerates a little fingertip movement")
    check(pinch.update(ratio: 0.2, eligible: true, time: 1.1) == .none,
          "A hold shorter than 700 ms emits no click")
    check(pinch.update(ratio: 0.2, eligible: true, time: 1.2) == .doubleClick && pinch.active,
          "A continuous 700 ms pinch emits one double click")
    check(pinch.update(ratio: 0.2, eligible: true, time: 1.5) == .none,
          "Holding after double click never repeats")
    check(pinch.update(ratio: 0.8, eligible: true, time: 1.6) == .released && !pinch.active,
          "Release after a double click emits no additional single")
    _ = pinch.update(ratio: 0.2, eligible: true, time: 1.7)
    check(pinch.update(ratio: 0.2, eligible: false, time: 1.8) == .cancelled && !pinch.active,
          "Ambiguous pose cancels a pending pinch")
    check(pinch.update(ratio: 0.2, eligible: true, time: 1.9) == .none,
          "A cancelled hold requires another visible release")
    _ = pinch.update(ratio: 0.8, eligible: true, time: 2)
    _ = pinch.update(ratio: 0.2, eligible: true, time: 2.1)
    check(pinch.update(ratio: 0.2, eligible: true, time: 2.6) == .cancelled,
          "A frame gap cannot complete a stale hold")
    _ = pinch.update(ratio: 0.8, eligible: true, time: 2.7)
    _ = pinch.update(ratio: 0.2, eligible: true, time: 2.8)
    check(pinch.update(ratio: .nan, eligible: true, time: 2.9) == .cancelled,
          "Invalid pinch geometry cancels instead of clicking")
    _ = pinch.update(ratio: 0.8, eligible: true, time: 3)
    _ = pinch.update(ratio: 0.2, eligible: true, time: 3.1)
    pinch.reset()
    check(pinch.update(ratio: 0.8, eligible: true, time: 3.2) == .none,
          "Pausing or losing the hand cancels a pending single")
    _ = pinch.update(ratio: 0.2, eligible: true, time: 3.3)
    _ = pinch.update(ratio: 0.2, eligible: true, time: 3.6)
    _ = pinch.update(ratio: 0.2, eligible: true, time: 3.9)
    check(pinch.update(ratio: 0.8, eligible: true, time: 4) == .doubleClick && !pinch.active,
          "A release at the hold deadline emits a double without a preliminary single")

    var fist = FistOpenLatch()
    check(!fist.update(pose: .open, time: 0) && !fist.isEngaged,
          "An open hand on startup cannot trigger Mission Control")
    check(!fist.update(pose: .closing, time: 0.1) && fist.isEngaged,
          "Closing a fist suppresses competing pinches immediately")
    _ = fist.update(pose: .fist, time: 0.2)
    _ = fist.update(pose: .fist, time: 0.4)
    _ = fist.update(pose: .open, time: 0.45)
    check(!fist.update(pose: .open, time: 0.7) && !fist.isEngaged,
          "A brief accidental curl cannot arm the open-hand action")
    _ = fist.update(pose: .fist, time: 0.8)
    _ = fist.update(pose: .fist, time: 1.1)
    _ = fist.update(pose: .fist, time: 1.2)
    _ = fist.update(pose: .other, time: 1.3)
    check(fist.isEngaged, "A confirmed fist retains exclusive control while the hand opens")
    _ = fist.update(pose: .open, time: 1.4)
    check(!fist.update(pose: .open, time: 1.55), "An unstable open pose does not trigger")
    check(fist.update(pose: .open, time: 1.6) && !fist.isEngaged,
          "A confirmed fist then stable open hand triggers once and releases engagement")
    check(!fist.update(pose: .open, time: 1.9), "An open hand after trigger never toggles repeatedly")
    _ = fist.update(pose: .fist, time: 2)
    _ = fist.update(pose: .fist, time: 2.3)
    _ = fist.update(pose: .open, time: 2.4)
    check(!fist.update(pose: .open, time: 2.6), "A second gesture during cooldown is ignored")
    fist.reset()
    _ = fist.update(pose: .fist, time: 4)
    _ = fist.update(pose: .fist, time: 4.3)
    _ = fist.update(pose: .fist, time: 4.4)
    check(!fist.update(pose: .unknown, time: 4.5) && !fist.isEngaged,
          "Missing landmarks cancel a confirmed fist")
    _ = fist.update(pose: .open, time: 4.6)
    check(!fist.update(pose: .open, time: 4.9), "Reacquiring an open hand cannot revive a lost fist")
    _ = fist.update(pose: .fist, time: 5)
    _ = fist.update(pose: .fist, time: 5.3)
    _ = fist.update(pose: .fist, time: 5.4)
    for index in 1...8 { _ = fist.update(pose: .other, time: 5.4 + Double(index) * 0.3) }
    check(!fist.isEngaged, "An incomplete opening expires without leaving pointer control stuck")
    _ = fist.update(pose: .open, time: 8)
    check(!fist.update(pose: .open, time: 8.3), "A timed-out fist cannot trigger later")
    _ = fist.update(pose: .fist, time: 8.4)
    _ = fist.update(pose: .fist, time: 8.7)
    _ = fist.update(pose: .fist, time: 8.8)
    check(!fist.update(pose: .open, time: 9.4) && !fist.isEngaged,
          "A camera frame gap cancels the fist/open transition")
    _ = fist.update(pose: .fist, time: 10)
    for index in 1...12 { _ = fist.update(pose: .fist, time: 10 + Double(index) * 0.25) }
    _ = fist.update(pose: .open, time: 13.1)
    check(fist.update(pose: .open, time: 13.3), "A deliberately held fist may open after several seconds")

    var overview = MissionControlTransition()
    check(!overview.blocksInput(time: 0), "No overview request leaves normal input available")
    let firstOverview = overview.begin(time: 20)!
    check(overview.blocksInput(time: 20) && overview.blocksInput(time: 20.749),
          "Overview animation briefly suppresses input")
    check(!overview.blocksInput(time: 20.75) && !overview.blocksInput(time: 22),
          "A missing overview callback cannot block input beyond 750 ms")
    check(overview.begin(time: 22) == nil,
          "Input resumes while duplicate launch requests are still suppressed")

    // Exercise the actual pinch latch after an overview whose callback never
    // completes: both normal click modes must remain available in the overview.
    var resumedPinch = HoldPinchLatch()
    func afterOverview(_ ratio: Double, _ time: Double) -> PinchHoldEvent {
        resumedPinch.update(ratio: ratio, eligible: !overview.blocksInput(time: time), time: time)
    }
    _ = afterOverview(0.8, 20.8)
    check(afterOverview(0.2, 20.9) == .began,
          "A new pinch can start with the Mission Control callback still pending")
    check(afterOverview(0.8, 21.05) == .singleClick,
          "A normal single click works while Mission Control launch is pending")
    _ = afterOverview(0.2, 21.2)
    _ = afterOverview(0.2, 21.5)
    _ = afterOverview(0.2, 21.8)
    check(afterOverview(0.2, 21.9) == .doubleClick,
          "A held double click works while Mission Control launch is pending")
    check(afterOverview(0.8, 22) == .released,
          "Releasing the resumed double click produces no extra click")
    check(overview.complete(request: firstOverview) && !overview.blocksInput(time: 22.1),
          "A delayed matching callback cannot re-lock resumed input")
    check(!overview.complete(request: firstOverview),
          "A duplicate completion is ignored")

    let beforeCancel = overview.begin(time: 24)!
    overview.cancel()
    check(!overview.blocksInput(time: 24.1) && !overview.complete(request: beforeCancel),
          "Pause or tracking loss cancels both the transition and its old callback")
    let afterCancel = overview.begin(time: 24.2)!
    check(afterCancel > beforeCancel && !overview.complete(request: beforeCancel),
          "A late callback cannot complete a newer launch after re-enabling")
    check(overview.blocksInput(time: 24.3),
          "Ignoring a stale callback preserves the newer transition")
    check(overview.complete(request: afterCancel) && overview.blocksInput(time: 24.3) &&
          !overview.blocksInput(time: 24.95),
          "An early success or failure leaves only the bounded animation delay")

    let timedOut = overview.begin(time: 30)!
    check(overview.begin(time: 32.999) == nil, "A duplicate launch cannot start before its timeout")
    let retry = overview.begin(time: 33)
    check(retry != nil && retry! > timedOut,
          "A missing callback cannot prevent a new launch after three seconds")
    check(!overview.complete(request: timedOut) && overview.blocksInput(time: 33.1),
          "A timed-out callback cannot affect the retry")
    check(!overview.blocksInput(time: 33.75), "The retry also releases input without a callback")
    overview.cancel()
    check(overview.begin(time: .nan) == nil && overview.begin(time: .infinity) == nil &&
          !overview.blocksInput(time: .nan), "Invalid transition timestamps cannot arm an input lock")

    let video = CGSize(width: 1280, height: 720)
    let fingers: [[HandJoint]] = [
        [.indexMCP, .indexPIP, .indexTip], [.middleMCP, .middlePIP, .middleTip],
        [.ringMCP, .ringPIP, .ringTip], [.littleMCP, .littlePIP, .littleTip]
    ]
    func fixture(curled: Set<Int>, scale: Double = 1, rotation: Double = 0) -> [HandJoint: CGPoint] {
        var coordinates: [HandJoint: CGPoint] = [.wrist: .zero]
        for (index, finger) in fingers.enumerated() {
            let x = Double(index - 1) * 30
            coordinates[finger[0]] = CGPoint(x: x, y: 100)
            coordinates[finger[1]] = CGPoint(x: x, y: 150)
            coordinates[finger[2]] = CGPoint(x: x + (curled.contains(index) ? 15 : 0),
                                            y: curled.contains(index) ? 110 : 215)
        }
        return coordinates.mapValues { p in
            let x = Double(p.x) * scale, y = Double(p.y) * scale
            return CGPoint(x: (640 + x * cos(rotation) - y * sin(rotation)) / video.width,
                           y: (300 + x * sin(rotation) + y * cos(rotation)) / video.height)
        }
    }
    check(classifyHandPose(joints: fixture(curled: []), videoSize: video) == .open,
          "Four extended fingers form an open hand")
    check(classifyHandPose(joints: fixture(curled: [0, 1, 2, 3]), videoSize: video) == .fist,
          "Four curled fingers form a fist")
    check(classifyHandPose(joints: fixture(curled: [1]), videoSize: video) == .other,
          "A middle-finger pinch with an extended index cannot form a fist")
    check(classifyHandPose(joints: fixture(curled: [1, 2, 3]), videoSize: video) == .other,
          "Pointing with only the index extended cannot form a fist")
    check(classifyHandPose(joints: fixture(curled: [0, 1]), videoSize: video) == .closing,
          "A partially closing fist is recognized before all fingers curl")
    for angle in [0.7, -1.2, Double.pi] {
        check(classifyHandPose(joints: fixture(curled: [], scale: 0.5, rotation: angle), videoSize: video) == .open,
              "Open-hand detection tolerates rotation and distance")
        check(classifyHandPose(joints: fixture(curled: [0, 1, 2, 3], scale: 1.2, rotation: angle), videoSize: video) == .fist,
              "Fist detection tolerates rotation and distance")
    }
    var missing = fixture(curled: [])
    missing.removeValue(forKey: .littleTip)
    check(classifyHandPose(joints: missing, videoSize: video) == .unknown,
          "An incomplete hand cannot confirm the open transition")
    var invalid = fixture(curled: [])
    invalid[.indexTip] = CGPoint(x: CGFloat.nan, y: 0)
    check(classifyHandPose(joints: invalid, videoSize: video) == .unknown,
          "Nonfinite landmarks cannot form a pose")
    check(classifyHandPose(joints: fixture(curled: [], scale: 0.01), videoSize: video) == .unknown,
          "Tiny unreliable hands cannot form a pose")
    return (tests, failures)
}
