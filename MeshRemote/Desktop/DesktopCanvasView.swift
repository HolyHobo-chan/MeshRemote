import UIKit

/// Windows virtual-key codes for the special keys we expose.
enum VirtualKey: UInt8 {
    case backspace = 8
    case tab = 9
    case enter = 13
    case shift = 16
    case control = 17
    case alt = 18
    case escape = 27
    case space = 32
    case pageUp = 33
    case pageDown = 34
    case end = 35
    case home = 36
    case arrowLeft = 37
    case arrowUp = 38
    case arrowRight = 39
    case arrowDown = 40
    case insert = 45
    case delete = 46
    case windows = 91
    case f1 = 112, f2 = 113, f3 = 114, f4 = 115, f5 = 116, f6 = 117
    case f7 = 118, f8 = 119, f9 = 120, f10 = 121, f11 = 122, f12 = 123
}

/// The remote framebuffer view with trackpad-style input: a virtual cursor that
/// one-finger pans move relatively; taps click at the cursor, not the finger.
/// Hosted inside a UIScrollView for pinch-zoom; the viewport follows the cursor.
final class DesktopCanvasView: UIView, UIKeyInput {
    weak var session: DesktopSession?

    /// Called after the cursor moves (canvas coordinates), so the host can keep it visible.
    var onCursorMoved: ((CGPoint) -> Void)?

    /// Sticky modifiers toggled from the accessory bar (VK codes currently held down).
    private(set) var activeModifiers: Set<UInt8> = []
    var onModifiersChanged: (() -> Void)?

    private(set) var cursorPosition: CGPoint = .zero
    private let cursorLayer = CAShapeLayer()

    private var dragActive = false
    private var lastDragLocation: CGPoint = .zero
    private var scrollAccumulator: CGFloat = 0

    // Trackball momentum.
    private var momentumLink: CADisplayLink?
    private var momentumVelocity: CGPoint = .zero
    private var lastMomentumTick: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        layer.magnificationFilter = .linear
        layer.minificationFilter = .trilinear
        backgroundColor = UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1)
        setupCursorLayer()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Installs the input gestures on `host` (the full-screen scroll view), so
    /// swipes work everywhere — including screen edges and letterboxed areas
    /// outside the canvas. Handlers still compute in this view's coordinates.
    func attachGestures(to host: UIView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleCursorPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        host.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTapsRequired = 1
        host.addGestureRecognizer(tap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        host.addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        host.addGestureRecognizer(twoFingerTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        host.addGestureRecognizer(longPress)

        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        host.addGestureRecognizer(twoFingerPan)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { stopMomentum() }   // CADisplayLink retains its target
    }

    func updateFrame(_ image: CGImage) {
        layer.contents = image
    }

    // MARK: - Cursor

    private func setupCursorLayer() {
        // Classic pointer arrow, drawn at 1x; counter-scaled against the zoom
        // so it stays a constant size on screen.
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 17))
        path.addLine(to: CGPoint(x: 4, y: 13.5))
        path.addLine(to: CGPoint(x: 7.2, y: 20))
        path.addLine(to: CGPoint(x: 9.8, y: 18.7))
        path.addLine(to: CGPoint(x: 6.6, y: 12.3))
        path.addLine(to: CGPoint(x: 12, y: 12.3))
        path.close()
        cursorLayer.path = path.cgPath
        cursorLayer.fillColor = UIColor.white.cgColor
        cursorLayer.strokeColor = UIColor.black.cgColor
        cursorLayer.lineWidth = 1
        cursorLayer.anchorPoint = .zero
        cursorLayer.shadowColor = UIColor.black.cgColor
        cursorLayer.shadowOpacity = 0.4
        cursorLayer.shadowRadius = 1.5
        cursorLayer.shadowOffset = CGSize(width: 0, height: 1)
        cursorLayer.zPosition = 10
        layer.addSublayer(cursorLayer)
    }

    /// Counter-scale the cursor for the current zoom (pass 1/zoomScale).
    func updateCursorScale(_ scale: CGFloat) {
        withoutLayerAnimation {
            cursorLayer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        }
    }

    func resetCursor(to point: CGPoint) {
        cursorPosition = clamped(point)
        positionCursorLayer()
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        let size = session?.screenSize ?? bounds.size
        return CGPoint(x: max(0, min(point.x, max(size.width - 1, 0))),
                       y: max(0, min(point.y, max(size.height - 1, 0))))
    }

    private func positionCursorLayer() {
        withoutLayerAnimation {
            cursorLayer.position = cursorPosition
        }
    }

    private func withoutLayerAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// Moves the cursor by a delta in canvas coordinates and tells the remote side.
    /// Returns which axes hit the screen edge (used to kill momentum per-axis).
    @discardableResult
    private func moveCursor(by delta: CGPoint) -> (hitX: Bool, hitY: Bool) {
        let raw = CGPoint(x: cursorPosition.x + delta.x, y: cursorPosition.y + delta.y)
        cursorPosition = clamped(raw)
        positionCursorLayer()
        session?.sendMouseMove(to: cursorPosition)
        onCursorMoved?(cursorPosition)
        return (raw.x != cursorPosition.x, raw.y != cursorPosition.y)
    }

    // MARK: - Trackball momentum

    private func startMomentum(velocity: CGPoint) {
        guard hypot(velocity.x, velocity.y) > 120 else { return }   // require a real flick
        momentumVelocity = velocity
        lastMomentumTick = CACurrentMediaTime()
        momentumLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(momentumTick(_:)))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }

    func stopMomentum() {
        momentumLink?.invalidate()
        momentumLink = nil
        momentumVelocity = .zero
    }

    @objc private func momentumTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(now - lastMomentumTick, 1.0 / 30.0)
        lastMomentumTick = now

        let hit = moveCursor(by: CGPoint(x: momentumVelocity.x * dt,
                                         y: momentumVelocity.y * dt))
        if hit.hitX { momentumVelocity.x = 0 }
        if hit.hitY { momentumVelocity.y = 0 }

        // Same exponential decay feel as UIScrollView's normal deceleration.
        let decay = pow(CGFloat(UIScrollView.DecelerationRate.normal.rawValue), CGFloat(dt * 1000))
        momentumVelocity.x *= decay
        momentumVelocity.y *= decay

        if hypot(momentumVelocity.x, momentumVelocity.y) < 25 {
            stopMomentum()
        }
    }

    // MARK: - Gestures (trackpad model)

    /// One-finger pan: relative cursor movement. Translation is measured in this
    /// view's (zoomed) coordinate space, so finger-to-cursor speed matches what
    /// you see at any zoom level.
    @objc private func handleCursorPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopMomentum()
        case .changed:
            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            moveCursor(by: translation)
        case .ended:
            startMomentum(velocity: gesture.velocity(in: self))
        default:
            break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        stopMomentum()
        session?.sendClick(.left, at: cursorPosition)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        stopMomentum()
        session?.sendDoubleClick(at: cursorPosition)
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        stopMomentum()
        session?.sendClick(.right, at: cursorPosition)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Long-press starts a left-button drag at the cursor; moving the finger
    /// drags (relative, like the pan), lifting releases.
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopMomentum()
            dragActive = true
            lastDragLocation = gesture.location(in: self)
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            session?.sendMouseButton(.left, down: true, at: cursorPosition)
        case .changed:
            guard dragActive else { return }
            let location = gesture.location(in: self)
            let delta = CGPoint(x: location.x - lastDragLocation.x,
                                y: location.y - lastDragLocation.y)
            lastDragLocation = location
            moveCursor(by: delta)
        case .ended, .cancelled, .failed:
            guard dragActive else { return }
            dragActive = false
            session?.sendMouseButton(.left, down: false, at: cursorPosition)
        default:
            break
        }
    }

    @objc private func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
        guard let session else { return }
        switch gesture.state {
        case .began:
            stopMomentum()
        case .changed:
            let translation = gesture.translation(in: self)
            scrollAccumulator += translation.y
            gesture.setTranslation(.zero, in: self)
            // One wheel notch (±120) per ~14 view points, natural direction.
            while abs(scrollAccumulator) >= 14 {
                let notch = scrollAccumulator > 0 ? 120 : -120
                session.sendScroll(delta: notch, at: cursorPosition)
                scrollAccumulator -= scrollAccumulator > 0 ? 14 : -14
            }
        case .ended, .cancelled:
            scrollAccumulator = 0
        default:
            break
        }
    }

    // MARK: - Keyboard (UIKeyInput)

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var keyboardType: UIKeyboardType = .asciiCapable
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none

    func insertText(_ text: String) {
        guard let session else { return }
        for character in text {
            if character == "\n" {
                session.sendKeyTap(VirtualKey.enter.rawValue)
                continue
            }
            // With a modifier held (e.g. Ctrl), letters must go as VK codes,
            // because the unicode path bypasses modifier handling on the agent.
            if !activeModifiers.isEmpty, let vk = Self.virtualKey(for: character) {
                session.sendKeyTap(vk)
                releaseTransientModifiers()
                continue
            }
            for scalar in String(character).unicodeScalars {
                session.sendUnicode(scalar)
            }
        }
    }

    func deleteBackward() {
        session?.sendKeyTap(VirtualKey.backspace.rawValue)
    }

    /// VK code for characters that make sense with Ctrl/Alt combos.
    static func virtualKey(for character: Character) -> UInt8? {
        guard let ascii = character.uppercased().first?.asciiValue else { return nil }
        switch ascii {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return ascii
        case UInt8(ascii: " "):
            return VirtualKey.space.rawValue
        default:
            return nil
        }
    }

    // MARK: - Modifiers

    func toggleModifier(_ vk: UInt8) {
        if activeModifiers.contains(vk) {
            activeModifiers.remove(vk)
            session?.sendKey(vk, action: .up)
        } else {
            activeModifiers.insert(vk)
            session?.sendKey(vk, action: .down)
        }
        onModifiersChanged?()
    }

    /// After a modified keystroke, release one-shot modifiers (Ctrl+C style chords).
    private func releaseTransientModifiers() {
        for vk in activeModifiers {
            session?.sendKey(vk, action: .up)
        }
        activeModifiers.removeAll()
        onModifiersChanged?()
    }

    func sendSpecialKey(_ key: VirtualKey) {
        let extendedKeys: Set<VirtualKey> = [.arrowLeft, .arrowUp, .arrowRight, .arrowDown,
                                             .home, .end, .pageUp, .pageDown, .insert, .delete]
        session?.sendKeyTap(key.rawValue, extended: extendedKeys.contains(key))
        releaseTransientModifiers()
    }

    func releaseAllModifiers() {
        releaseTransientModifiers()
    }
}
