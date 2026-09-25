//
//  VirtualPadView.swift
//  MPX68K for iOS
//
//  On-screen joystick for X68000 port 1: an 8-way D-pad and the two
//  trigger buttons (A = trigger A, B = trigger B), or in key mode the
//  Z / X / C / SPACE / RETURN keys. Laid out with Auto Layout against
//  the safe area so it can sit in the space the 4:3 screen leaves free.
//

import UIKit

final class VirtualPadView: UIView {

    /// Called with the X68000 joystick bits (JOY_UP ... JOY_TRG1) whenever they change.
    var onChange: ((UInt8) -> Void)?
    /// Called for the key buttons shown in key mode (KeyTable code, pressed).
    var onKey: ((UInt32, Bool) -> Void)?

    /// Key mode: A/B are replaced by Z, X, C, SPACE along the bottom and RETURN on the right.
    var usesKeys = false {
        didSet {
            guard usesKeys != oldValue else { return }
            releaseAll()
            applyMode()
        }
    }

    private let dpad = DPadControl()
    // X68000 trigger A is bit 5 (JOY_TRG2), trigger B is bit 6 (JOY_TRG1),
    // matching the physical gamepad mapping in JoyController.
    private let buttonA = PadButton(title: "A", bit: JOY_TRG2)
    private let buttonB = PadButton(title: "B", bit: JOY_TRG1)
    private var state: UInt8 = 0

    // KeyTable codes (px68k/x11/keyboard.c)
    private let keyZ = KeyButton(title: "Z", code: 0x7a)
    private let keyX = KeyButton(title: "X", code: 0x78)
    private let keyC = KeyButton(title: "C", code: 0x63)
    private let keySpace = KeyButton(title: "SPACE", code: 0x20)
    private let keyReturn = KeyButton(title: "RETURN", code: 0x0d)
    private let keyRow = UIStackView()
    private var keyButtons: [KeyButton] { [keyZ, keyX, keyC, keySpace, keyReturn] }

    private var joyConstraints: [NSLayoutConstraint] = []
    private var keyConstraints: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        keyRow.axis = .horizontal
        keyRow.spacing = 8
        keyRow.alignment = .fill
        [keyZ, keyX, keyC, keySpace].forEach { keyRow.addArrangedSubview($0) }

        [dpad, buttonA, buttonB, keyRow, keyReturn].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        dpad.onChange = { [weak self] _ in self?.update() }
        buttonA.onChange = { [weak self] in self?.update() }
        buttonB.onChange = { [weak self] in self?.update() }
        keyButtons.forEach { button in
            button.onChange = { [weak self] code, pressed in self?.onKey?(code, pressed) }
        }

        let guide = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            dpad.widthAnchor.constraint(equalToConstant: 150),
            dpad.heightAnchor.constraint(equalTo: dpad.widthAnchor),
            dpad.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),

            buttonA.widthAnchor.constraint(equalToConstant: 72),
            buttonA.heightAnchor.constraint(equalTo: buttonA.widthAnchor),
            buttonA.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            buttonA.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -60),

            buttonB.widthAnchor.constraint(equalTo: buttonA.widthAnchor),
            buttonB.heightAnchor.constraint(equalTo: buttonA.widthAnchor),
            buttonB.trailingAnchor.constraint(equalTo: buttonA.leadingAnchor, constant: -16),
            buttonB.topAnchor.constraint(equalTo: buttonA.centerYAnchor),

            // Key mode: Z X C SPACE along the bottom, RETURN at the right centre.
            keyRow.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            keyRow.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            keyRow.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
            keyRow.heightAnchor.constraint(equalToConstant: 52),
            keyZ.widthAnchor.constraint(equalToConstant: 56),
            keyX.widthAnchor.constraint(equalTo: keyZ.widthAnchor),
            keyC.widthAnchor.constraint(equalTo: keyZ.widthAnchor),

            keyReturn.widthAnchor.constraint(equalToConstant: 96),
            keyReturn.heightAnchor.constraint(equalToConstant: 64),
            keyReturn.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            keyReturn.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
        ])
        joyConstraints = [dpad.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -24)]
        keyConstraints = [dpad.bottomAnchor.constraint(equalTo: keyRow.topAnchor, constant: -16)]
        applyMode()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func applyMode() {
        buttonA.isHidden = usesKeys
        buttonB.isHidden = usesKeys
        keyRow.isHidden = !usesKeys
        keyReturn.isHidden = !usesKeys
        NSLayoutConstraint.deactivate(usesKeys ? joyConstraints : keyConstraints)
        NSLayoutConstraint.activate(usesKeys ? keyConstraints : joyConstraints)
    }

    /// Only the controls take touches; everything else falls through to the screen.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        subviews.contains { !$0.isHidden && $0.point(inside: convert(point, to: $0), with: event) }
    }

    func releaseAll() {
        dpad.reset()
        buttonA.reset()
        buttonB.reset()
        keyButtons.forEach { $0.release() }
        update()
    }

    private func update() {
        let newState = dpad.bits | buttonA.bits | buttonB.bits
        guard newState != state else { return }
        state = newState
        onChange?(newState)
    }
}

// MARK: - D-pad

private final class DPadControl: UIView {
    var onChange: ((UInt8) -> Void)?
    private(set) var bits: UInt8 = 0
    private var trackingTouch: UITouch?
    private let ring = CAShapeLayer()
    private let knob = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        ring.fillColor = UIColor.white.withAlphaComponent(0.08).cgColor
        ring.strokeColor = UIColor.white.withAlphaComponent(0.35).cgColor
        ring.lineWidth = 2
        knob.fillColor = UIColor.white.withAlphaComponent(0.35).cgColor
        layer.addSublayer(ring)
        layer.addSublayer(knob)
        isAccessibilityElement = true
        accessibilityLabel = "方向パッド"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).cgPath
        placeKnob(at: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    private func placeKnob(at point: CGPoint) {
        let radius = bounds.width * 0.2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        knob.path = UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                width: radius * 2, height: radius * 2)).cgPath
        CATransaction.commit()
    }

    func reset() {
        trackingTouch = nil
        bits = 0
        placeKnob(at: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    private func track(_ touch: UITouch) {
        let point = touch.location(in: self)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let radius = bounds.width / 2
        let distance = hypot(dx, dy)

        var newBits: UInt8 = 0
        if distance > radius * 0.25 {
            // 8 directions: 45° sectors centred on each axis and diagonal
            let angle = atan2(-dy, dx)
            let sector = Int((angle / (.pi / 4)).rounded())
            switch (sector + 8) % 8 {
            case 0: newBits = JOY_RIGHT
            case 1: newBits = JOY_RIGHT | JOY_UP
            case 2: newBits = JOY_UP
            case 3: newBits = JOY_LEFT | JOY_UP
            case 4: newBits = JOY_LEFT
            case 5: newBits = JOY_LEFT | JOY_DOWN
            case 6: newBits = JOY_DOWN
            default: newBits = JOY_RIGHT | JOY_DOWN
            }
        }

        let clamped = min(distance, radius * 0.6)
        let knobPoint = distance > 0
            ? CGPoint(x: center.x + dx / distance * clamped, y: center.y + dy / distance * clamped)
            : center
        placeKnob(at: knobPoint)

        if newBits != bits {
            bits = newBits
            if newBits != 0 { UISelectionFeedbackGenerator().selectionChanged() }
            onChange?(bits)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackingTouch == nil, let touch = touches.first else { return }
        trackingTouch = touch
        track(touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackingTouch, touches.contains(touch) else { return }
        track(touch)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackingTouch, touches.contains(touch) else { return }
        reset()
        onChange?(bits)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}

// MARK: - Buttons

private final class PadButton: UIView {
    var onChange: (() -> Void)?
    private let bit: UInt8
    private(set) var bits: UInt8 = 0
    private let circle = CAShapeLayer()
    private let label = UILabel()

    init(title: String, bit: UInt8) {
        self.bit = bit
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        circle.lineWidth = 2
        circle.strokeColor = UIColor.white.withAlphaComponent(0.35).cgColor
        layer.addSublayer(circle)
        label.text = title
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.textColor = UIColor.white.withAlphaComponent(0.7)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "\(title)ボタン"
        accessibilityTraits = .button
        setPressed(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        circle.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).cgPath
    }

    func reset() {
        setPressed(false)
    }

    private func setPressed(_ pressed: Bool) {
        bits = pressed ? bit : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circle.fillColor = UIColor.white.withAlphaComponent(pressed ? 0.45 : 0.08).cgColor
        CATransaction.commit()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        setPressed(true)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onChange?()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        setPressed(false)
        onChange?()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}

// MARK: - Key buttons

private final class KeyButton: UIView {
    var onChange: ((UInt32, Bool) -> Void)?
    private let code: UInt32
    private var isPressed = false
    private let label = UILabel()

    init(title: String, code: UInt32) {
        self.code = code
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        layer.cornerRadius = 12
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        label.text = title
        label.font = .systemFont(ofSize: title.count > 1 ? 15 : 20, weight: .semibold)
        label.textColor = UIColor.white.withAlphaComponent(0.7)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "\(title)キー"
        accessibilityTraits = .keyboardKey
        setPressed(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func release() {
        if isPressed {
            setPressed(false)
            onChange?(code, false)
        }
    }

    private func setPressed(_ pressed: Bool) {
        isPressed = pressed
        backgroundColor = UIColor.white.withAlphaComponent(pressed ? 0.45 : 0.08)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isPressed else { return }
        setPressed(true)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onChange?(code, true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        release()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        release()
    }
}
