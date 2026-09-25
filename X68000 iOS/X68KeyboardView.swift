//
//  X68KeyboardView.swift
//  MPX68K for iOS
//
//  On-screen X68000 keyboard (JIS layout): function keys, the main block,
//  modifiers / XF keys and the editing + cursor keys. Keys send X68000 key
//  codes directly (X68000_Key_DownScancode). SHIFT / CTRL / OPT.1 / OPT.2 latch
//  on tap and release after the next ordinary key.
//

import UIKit

final class X68KeyboardView: UIView {

    /// Called with an X68000 key code and whether it is pressed.
    var onKey: ((UInt8, Bool) -> Void)?

    fileprivate struct KeySpec {
        let label: String
        let code: UInt8
        var width: CGFloat = 1
        var isModifier = false
    }

    private static func k(_ label: String, _ code: UInt8, _ width: CGFloat = 1) -> KeySpec {
        KeySpec(label: label, code: code, width: width)
    }

    private static func mod(_ label: String, _ code: UInt8, _ width: CGFloat) -> KeySpec {
        KeySpec(label: label, code: code, width: width, isModifier: true)
    }

    // X68000 key codes
    private static let rows: [[KeySpec]] = [
        [k("F1", 0x63), k("F2", 0x64), k("F3", 0x65), k("F4", 0x66), k("F5", 0x67),
         k("F6", 0x68), k("F7", 0x69), k("F8", 0x6a), k("F9", 0x6b), k("F10", 0x6c),
         k("BREAK", 0x61), k("HELP", 0x54)],
        [k("ESC", 0x01), k("1", 0x02), k("2", 0x03), k("3", 0x04), k("4", 0x05), k("5", 0x06),
         k("6", 0x07), k("7", 0x08), k("8", 0x09), k("9", 0x0a), k("0", 0x0b), k("-", 0x0c),
         k("^", 0x0d), k("¥", 0x0e), k("BS", 0x0f, 1.5)],
        [k("TAB", 0x10, 1.5), k("Q", 0x11), k("W", 0x12), k("E", 0x13), k("R", 0x14), k("T", 0x15),
         k("Y", 0x16), k("U", 0x17), k("I", 0x18), k("O", 0x19), k("P", 0x1a), k("@", 0x1b),
         k("[", 0x1c), k("RET", 0x1d, 1.5)],
        [mod("CTRL", 0x71, 1.75), k("A", 0x1e), k("S", 0x1f), k("D", 0x20), k("F", 0x21), k("G", 0x22),
         k("H", 0x23), k("J", 0x24), k("K", 0x25), k("L", 0x26), k(";", 0x27), k(":", 0x28),
         k("]", 0x29), k("CAPS", 0x5d, 1.25)],
        [mod("SHIFT", 0x70, 2), k("Z", 0x2a), k("X", 0x2b), k("C", 0x2c), k("V", 0x2d), k("B", 0x2e),
         k("N", 0x2f), k("M", 0x30), k(",", 0x31), k(".", 0x32), k("/", 0x33), k("_", 0x34),
         mod("SHIFT", 0x70, 2)],
        [k("かな", 0x5a, 1.25), mod("OPT.1", 0x72, 1.25), k("XF1", 0x55), k("XF2", 0x56),
         k("SPACE", 0x35, 4), k("XF3", 0x57), k("XF4", 0x58), k("XF5", 0x59),
         mod("OPT.2", 0x73, 1.25), k("登録", 0x53, 1.25)],
        [k("HOME", 0x36), k("INS", 0x5e), k("DEL", 0x37), k("UNDO", 0x3a),
         k("R.UP", 0x38), k("R.DN", 0x39), k("CLR", 0x3f),
         k("←", 0x3b), k("↑", 0x3c), k("↓", 0x3e), k("→", 0x3d)],
    ]

    private var keyRows: [[KeyCap]] = []
    /// Latched modifiers, released after the next ordinary key.
    private var latched: Set<UInt8> = []

    private let spacing: CGFloat = 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        keyRows = Self.rows.map { row in
            row.map { spec in
                let cap = KeyCap(spec: spec)
                cap.onPress = { [weak self] cap, pressed in self?.handle(cap, pressed: pressed) }
                addSubview(cap)
                return cap
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rowCount = CGFloat(keyRows.count)
        let rowHeight = (bounds.height - spacing * (rowCount - 1)) / rowCount
        for (index, row) in keyRows.enumerated() {
            let units = row.reduce(0) { $0 + $1.spec.width }
            let unitWidth = (bounds.width - spacing * CGFloat(row.count - 1)) / units
            var x: CGFloat = 0
            let y = CGFloat(index) * (rowHeight + spacing)
            for cap in row {
                let width = unitWidth * cap.spec.width
                cap.frame = CGRect(x: x, y: y, width: width, height: rowHeight).integral
                x += width + spacing
            }
        }
    }

    /// Releases every held or latched key (e.g. when the keyboard is hidden).
    func releaseAll() {
        keyRows.joined().forEach { $0.reset() }
        for code in latched {
            onKey?(code, false)
        }
        latched.removeAll()
        updateLatchHighlights()
    }

    private func handle(_ cap: KeyCap, pressed: Bool) {
        let code = cap.spec.code
        if cap.spec.isModifier {
            // Toggle the latch on touch-down.
            guard pressed else { return }
            if latched.contains(code) {
                latched.remove(code)
                onKey?(code, false)
            } else {
                latched.insert(code)
                onKey?(code, true)
            }
            updateLatchHighlights()
            return
        }

        onKey?(code, pressed)
        if !pressed && !latched.isEmpty {
            for modifier in latched {
                onKey?(modifier, false)
            }
            latched.removeAll()
            updateLatchHighlights()
        }
    }

    private func updateLatchHighlights() {
        for cap in keyRows.joined() where cap.spec.isModifier {
            cap.isLatched = latched.contains(cap.spec.code)
        }
    }
}

// MARK: - Key cap

private final class KeyCap: UIView {
    let spec: X68KeyboardView.KeySpec
    var onPress: ((KeyCap, Bool) -> Void)?
    var isLatched = false { didSet { updateAppearance() } }
    private var isPressed = false
    private let label = UILabel()

    init(spec: X68KeyboardView.KeySpec) {
        self.spec = spec
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        layer.cornerRadius = 6
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        label.text = spec.label
        label.textColor = UIColor.white.withAlphaComponent(0.85)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        label.font = .systemFont(ofSize: spec.label.count > 2 ? 11 : 16, weight: .medium)
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = spec.label
        accessibilityTraits = .keyboardKey
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 2, dy: 2)
    }

    func reset() {
        if isPressed {
            isPressed = false
            updateAppearance()
            if !spec.isModifier {
                onPress?(self, false)
            }
        }
    }

    private func updateAppearance() {
        let alpha: CGFloat = isPressed ? 0.45 : (isLatched ? 0.3 : 0.08)
        backgroundColor = UIColor.white.withAlphaComponent(alpha)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isPressed else { return }
        isPressed = true
        updateAppearance()
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.5)
        onPress?(self, true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard isPressed else { return }
        isPressed = false
        updateAppearance()
        onPress?(self, false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}
