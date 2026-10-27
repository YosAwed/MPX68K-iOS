//
//  DuoPanels.swift
//  MPX68K for iOS
//
//  Pieces of the control panel that make the iPhone Duo's folded postures look
//  like the real machine:
//  - StatusLampMonitor polls the core for FDD / HDD activity and the keyboard LEDs.
//  - StatusLampStripView is the row of lamps above the on-screen keyboard
//    (portrait inner display: L-shaped / laptop posture, or fully open).
//  - DriveBayView is the "front panel" with both floppy drives and the hard disk,
//    shown on its own side of the fold in the book posture. Below the drives it shows
//    the LCD of the internal sound module (SC-55 or MT-32) that MIDI goes to.
//  - InnerPanelPicker chooses what the lower half shows: keyboard, pad, trackpad or the
//    sound monitor (SoundMonitorView.swift).
//

import UIKit

extension UIView {
    /// Shows or hides an arranged subview of a UIStackView. A posture change runs inside
    /// an animation, and there the stack view counts repeated `isHidden = true`, so one
    /// `isHidden = false` would not bring the view back. Only set it when it changes.
    func setHiddenInStackView(_ hidden: Bool) {
        if isHidden != hidden { isHidden = hidden }
    }
}

// MARK: - Lamp state

/// Polls the emulator for lamp state (the emulation runs on the main thread, so
/// reading the counters from a display link is safe) and tells observers when it changes.
final class StatusLampMonitor: NSObject {

    static let shared = StatusLampMonitor()

    private override init() {
        super.init()
    }

    struct State: Equatable {
        var fddName: [String?] = [nil, nil]
        var fddAccess: [Bool] = [false, false]
        var hddName: String?
        var hddAccess = false
        /// Keyboard LEDs, bit = 1 when lit (the core's command byte is active low).
        var keyboardLEDs: UInt8 = 0

        func isFDDInserted(_ drive: Int) -> Bool { fddName[drive] != nil }
        var isHDDAttached: Bool { hddName != nil }
        func isKeyboardLEDLit(_ led: KeyboardLED) -> Bool { keyboardLEDs & (1 << led.rawValue) != 0 }
    }

    /// X68000 keyboard LEDs in the order of the bits of the LED command.
    enum KeyboardLED: Int, CaseIterable {
        case kana, romaji, codeInput, caps, ins, hiragana, zenkaku

        var label: String {
            switch self {
            case .kana: return "かな"
            case .romaji: return "ローマ字"
            case .codeInput: return "コード"
            case .caps: return "CAPS"
            case .ins: return "INS"
            case .hiragana: return "ひらがな"
            case .zenkaku: return "全角"
            }
        }
    }

    private(set) var state = State()

    private final class Observer {
        weak var owner: AnyObject?
        let handler: (State) -> Void
        init(owner: AnyObject, handler: @escaping (State) -> Void) {
            self.owner = owner
            self.handler = handler
        }
    }
    private var observers: [Observer] = []
    private var displayLink: CADisplayLink?

    /// How long a lamp stays lit after one access (single sector reads are very short).
    private static let lampHold: CFTimeInterval = 0.12
    private var lastFDDCount: [UInt32] = [0, 0]
    private var lastHDDCount: UInt32 = 0
    private var fddLitUntil: [CFTimeInterval] = [0, 0]
    private var hddLitUntil: CFTimeInterval = 0
    private var tick = 0

    /// `handler` runs now and whenever the state changes, until `owner` goes away.
    func addObserver(_ owner: AnyObject, handler: @escaping (State) -> Void) {
        observers.append(Observer(owner: owner, handler: handler))
        refreshNames()
        handler(state)
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step(_ link: CADisplayLink) {
        observers.removeAll { $0.owner == nil }
        guard !observers.isEmpty else {
            link.invalidate()
            displayLink = nil
            return
        }
        let now = CACurrentMediaTime()
        var next = state
        for drive in 0..<2 {
            let count = X68000_GetFDDActivity(drive)
            if count != lastFDDCount[drive] {
                lastFDDCount[drive] = count
                fddLitUntil[drive] = now + Self.lampHold
            }
            next.fddAccess[drive] = now < fddLitUntil[drive]
        }
        let hddCount = X68000_GetHDDActivity()
        if hddCount != lastHDDCount {
            lastHDDCount = hddCount
            hddLitUntil = now + Self.lampHold
        }
        next.hddAccess = now < hddLitUntil
        next.keyboardLEDs = ~X68000_GetKeyboardLEDs() & 0x7f

        // Disk names change rarely; look at them about twice a second.
        tick += 1
        if tick % 15 == 0 {
            next.fddName = (0..<2).map(Self.floppyName)
            next.hddName = Self.hardDiskName()
        }
        publish(next)
    }

    /// Picks up a disk change right away (e.g. after the menu inserted one).
    func refreshNames() {
        var next = state
        next.fddName = (0..<2).map(Self.floppyName)
        next.hddName = Self.hardDiskName()
        publish(next)
    }

    private func publish(_ next: State) {
        guard next != state else { return }
        state = next
        observers.forEach { if $0.owner != nil { $0.handler(next) } }
    }

    private static func floppyName(_ drive: Int) -> String? {
        guard X68000_IsFDDReady(drive) != 0, let path = X68000_GetFDDFilename(drive) else { return nil }
        let name = (String(cString: path) as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func hardDiskName() -> String? {
        guard X68000_IsHDDReady() != 0, let path = X68000_GetHDDFilename() else { return nil }
        let name = (String(cString: path) as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}

// MARK: - Lamps

/// A small rectangular LED.
final class LampView: UIView {
    var color: UIColor = .systemGreen {
        didSet { update() }
    }
    /// Dimly lit (e.g. a disk is inserted) when not lit.
    var isDimmed = false {
        didSet { if isDimmed != oldValue { update() } }
    }
    var isLit = false {
        didSet { if isLit != oldValue { update() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 2
        layer.shadowOffset = .zero
        layer.shadowRadius = 4
        isUserInteractionEnabled = false
        update()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize { CGSize(width: 12, height: 5) }

    private func update() {
        if isLit {
            backgroundColor = color
            layer.shadowColor = color.cgColor
            layer.shadowOpacity = 0.9
        } else {
            backgroundColor = isDimmed ? color.withAlphaComponent(0.35) : UIColor(white: 0.22, alpha: 1)
            layer.shadowOpacity = 0
        }
    }
}

/// A lamp with a caption under it, as printed on the X68000's panels.
private final class CaptionedLampView: UIStackView {
    let lamp = LampView()

    init(caption: String, color: UIColor) {
        super.init(frame: .zero)
        axis = .vertical
        alignment = .center
        spacing = 2
        lamp.color = color
        let label = UILabel()
        label.text = caption
        label.font = .systemFont(ofSize: 8, weight: .medium)
        label.textColor = UIColor.white.withAlphaComponent(0.55)
        addArrangedSubview(lamp)
        addArrangedSubview(label)
        isUserInteractionEnabled = false
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

enum LampColor {
    static let fdd = UIColor(red: 0.35, green: 1.0, blue: 0.45, alpha: 1)
    static let hdd = UIColor(red: 1.0, green: 0.25, blue: 0.2, alpha: 1)
    static let keyboard = UIColor(red: 1.0, green: 0.35, blue: 0.25, alpha: 1)
    static let midiMessage = UIColor(red: 1.0, green: 0.3, blue: 0.2, alpha: 1)
}

/// FDD 0 / FDD 1 / HD BUSY and the keyboard's LEDs in one row, like the top edge
/// of the X68000 keyboard. Shown above the on-screen keyboard.
final class StatusLampStripView: UIStackView {
    private let fddLamps = [CaptionedLampView(caption: "FDD0", color: LampColor.fdd),
                            CaptionedLampView(caption: "FDD1", color: LampColor.fdd)]
    private let hddLamp = CaptionedLampView(caption: "HD BUSY", color: LampColor.hdd)
    private var keyboardLamps: [(StatusLampMonitor.KeyboardLED, CaptionedLampView)] = []
    private let keyboardGroup = UIStackView()

    /// The keyboard LEDs are only meaningful next to the on-screen keyboard.
    var showsKeyboardLEDs = true {
        didSet { keyboardGroup.setHiddenInStackView(!showsKeyboardLEDs) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .horizontal
        alignment = .center
        spacing = 14

        let drives = UIStackView(arrangedSubviews: fddLamps + [hddLamp])
        drives.spacing = 8
        drives.alignment = .center
        addArrangedSubview(drives)

        keyboardGroup.spacing = 6
        keyboardGroup.alignment = .center
        for led in StatusLampMonitor.KeyboardLED.allCases {
            let lamp = CaptionedLampView(caption: led.label, color: LampColor.keyboard)
            keyboardLamps.append((led, lamp))
            keyboardGroup.addArrangedSubview(lamp)
        }
        addArrangedSubview(keyboardGroup)

        isUserInteractionEnabled = false
        isAccessibilityElement = false
        StatusLampMonitor.shared.addObserver(self) { [weak self] state in
            self?.apply(state)
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func apply(_ state: StatusLampMonitor.State) {
        for (drive, lamp) in fddLamps.enumerated() {
            lamp.lamp.isDimmed = state.isFDDInserted(drive)
            lamp.lamp.isLit = state.fddAccess[drive]
        }
        hddLamp.lamp.isLit = state.hddAccess
        for (led, lamp) in keyboardLamps {
            lamp.lamp.isLit = state.isKeyboardLEDLit(led)
        }
    }
}

// MARK: - Drive bay

/// Both floppy drives and the hard disk as slots with access lamps.
/// Tapping a slot opens its menu (insert / recent / eject); the eject button ejects.
final class DriveBayView: UIView {

    enum Drive: Equatable {
        case floppy(Int)
        case hardDisk
    }

    /// Menu for a slot, rebuilt every time it opens.
    var menuProvider: ((Drive) -> [UIMenuElement])?
    var onEject: ((Drive) -> Void)?
    /// The internal sound module MIDI goes to (nil: external MIDI). Polled while the bay is shown.
    var activeModuleProvider: (() -> MIDIController.InternalSynth?)?
    /// Menu for the module panel (the MIDI menu), rebuilt every time it opens.
    var moduleMenuProvider: (() -> [UIMenuElement])?

    private var slots: [DriveSlotView] = []
    private let sc55Panel = ModulePanelView(kind: .sc55)
    private let mt32Panel = ModulePanelView(kind: .mt32)
    private var displayLink: CADisplayLink?

    /// Height of the three drive slots; the module panel adds its own height below them.
    private static let slotsHeight: CGFloat = 3 * 46 + 2 * 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        let bay = UIStackView()
        bay.axis = .vertical
        bay.spacing = 8
        bay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bay)
        NSLayoutConstraint.activate([
            bay.leadingAnchor.constraint(equalTo: leadingAnchor),
            bay.trailingAnchor.constraint(equalTo: trailingAnchor),
            bay.topAnchor.constraint(equalTo: topAnchor),
            bay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.distribution = .fillEqually
        stack.heightAnchor.constraint(equalToConstant: Self.slotsHeight).isActive = true
        bay.addArrangedSubview(stack)
        for panel in [sc55Panel, mt32Panel] {
            panel.isHidden = true
            panel.menuProvider = { [weak self] in self?.moduleMenuProvider?() ?? [] }
            bay.addArrangedSubview(panel)
        }
        for drive in [Drive.floppy(0), .floppy(1), .hardDisk] {
            let slot = DriveSlotView(drive: drive)
            slot.menuProvider = { [weak self] in self?.menuProvider?(drive) ?? [] }
            slot.onEject = { [weak self] in
                self?.onEject?(drive)
                StatusLampMonitor.shared.refreshNames()
            }
            slots.append(slot)
            stack.addArrangedSubview(slot)
        }
        StatusLampMonitor.shared.addObserver(self) { [weak self] state in
            self?.slots.forEach { $0.apply(state) }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHidden: Bool {
        didSet { if !isHidden && oldValue { updateModulePanel() } }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(updateModulePanel))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            displayLink = link
            updateModulePanel()
        } else if window == nil {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    /// Shows the panel of the active module and copies its LCD from the core.
    @objc private func updateModulePanel() {
        // Nothing to do while the bay is not on screen (any posture but the book).
        var view: UIView? = self
        while let current = view {
            if current.isHidden { return }
            view = current.superview
        }
        guard window != nil else { return }
        let kind = activeModuleProvider?()
        sc55Panel.setHiddenInStackView(kind != .sc55)
        mt32Panel.setHiddenInStackView(kind != .mt32)
        switch kind {
        case .sc55: sc55Panel.updateFromCore()
        case .mt32: mt32Panel.updateFromCore()
        case nil: break
        }
    }
}

private final class DriveSlotView: UIView {
    let drive: DriveBayView.Drive
    var menuProvider: (() -> [UIMenuElement])?
    var onEject: (() -> Void)?

    private let lamp = LampView()
    private let driveLabel = UILabel()
    private let nameLabel = UILabel()
    private let menuButton = UIButton(type: .custom)
    private let ejectButton = UIButton(type: .system)

    init(drive: DriveBayView.Drive) {
        self.drive = drive
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.10, alpha: 1)
        layer.cornerRadius = 10
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor

        switch drive {
        case .floppy(let number):
            driveLabel.text = "FDD\(number)"
            lamp.color = LampColor.fdd
        case .hardDisk:
            driveLabel.text = "HDD"
            lamp.color = LampColor.hdd
        }
        driveLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        driveLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        nameLabel.font = .systemFont(ofSize: 14, weight: .medium)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingMiddle

        // The slot: a dark recess like the drive's disk opening.
        let opening = UIView()
        opening.backgroundColor = .black
        opening.layer.cornerRadius = 2
        opening.isUserInteractionEnabled = false

        // The whole slot is the menu button; the labels sit on top without taking touches.
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.menuProvider?() ?? [])
            }
        ])
        ejectButton.setImage(UIImage(systemName: "eject.fill"), for: .normal)
        ejectButton.tintColor = UIColor.white.withAlphaComponent(0.8)
        ejectButton.addTarget(self, action: #selector(eject), for: .touchUpInside)

        for subview in [menuButton, lamp, driveLabel, nameLabel, opening, ejectButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        [lamp, driveLabel, nameLabel].forEach { $0.isUserInteractionEnabled = false }
        NSLayoutConstraint.activate([
            menuButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            menuButton.trailingAnchor.constraint(equalTo: ejectButton.leadingAnchor),
            menuButton.topAnchor.constraint(equalTo: topAnchor),
            menuButton.bottomAnchor.constraint(equalTo: bottomAnchor),

            lamp.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            lamp.centerYAnchor.constraint(equalTo: centerYAnchor),
            driveLabel.leadingAnchor.constraint(equalTo: lamp.trailingAnchor, constant: 8),
            driveLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            driveLabel.widthAnchor.constraint(equalToConstant: 34),
            nameLabel.leadingAnchor.constraint(equalTo: driveLabel.trailingAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: ejectButton.leadingAnchor, constant: -6),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            opening.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            opening.trailingAnchor.constraint(equalTo: ejectButton.leadingAnchor, constant: -6),
            opening.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            opening.heightAnchor.constraint(equalToConstant: 4),

            ejectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            ejectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            ejectButton.widthAnchor.constraint(equalToConstant: 44),
            ejectButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        apply(StatusLampMonitor.shared.state)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ state: StatusLampMonitor.State) {
        let name: String?
        let access: Bool
        switch drive {
        case .floppy(let number):
            name = state.fddName[number]
            access = state.fddAccess[number]
        case .hardDisk:
            name = state.hddName
            access = state.hddAccess
        }
        lamp.isDimmed = name != nil
        lamp.isLit = access
        nameLabel.text = name ?? "（なし）"
        nameLabel.textColor = name == nil ? UIColor.white.withAlphaComponent(0.35) : .white
        ejectButton.isEnabled = name != nil
        menuButton.accessibilityLabel = "\(driveLabel.text ?? "")：\(name ?? "なし")"
        ejectButton.accessibilityLabel = "\(driveLabel.text ?? "") を取り出す"
    }

    @objc private func eject() {
        onEject?()
    }
}

// MARK: - MIDI module LCDs

/// 5x8 dot patterns of the modules' LCD characters, from the character ROM table in the
/// SC-55 core (an HD44780-style font; the MT-32's LCD shows the same ASCII shapes).
enum LCDCharacterROM {
    private static let rom: [[UInt8]] = (0..<256).map { code -> [UInt8] in
        var rows = [UInt8](repeating: 0, count: 8)
        X68SC55_LCDGlyph(UInt8(code), nil, &rows)
        return rows
    }

    /// Dot rows of `code` (bit 4 = leftmost dot). Codes below 16 are the 8 user glyphs in `cgram`.
    static func rows(_ code: UInt8, cgram: [UInt8] = []) -> [UInt8] {
        guard code < 16 else { return rom[Int(code)] }
        let start = Int(code & 7) * 8
        guard cgram.count >= start + 8 else { return rom[0] }
        return Array(cgram[start..<start + 8])
    }
}

/// A backlit dot-matrix LCD drawn in fixed design units (`canvas`), scaled to fit the view.
class DotMatrixLCDView: UIView {
    /// The design's coordinate space; subclasses draw inside it.
    var canvas: CGRect { CGRect(x: 0, y: 0, width: 1, height: 1) }
    var backlightColor = UIColor.orange
    var litDotColor = UIColor.black
    /// Unlit dots are faintly visible on a real LCD.
    var unlitDotColor = UIColor.orange

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), canvas.width > 0, canvas.height > 0 else { return }
        let scale = min(bounds.width / canvas.width, bounds.height / canvas.height)
        context.translateBy(x: (bounds.width - canvas.width * scale) / 2,
                            y: (bounds.height - canvas.height * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -canvas.minX, y: -canvas.minY)
        backlightColor.setFill()
        UIBezierPath(roundedRect: canvas, cornerRadius: canvas.height * 0.06 + 4).fill()
        var lit: [CGRect] = []
        var unlit: [CGRect] = []
        drawDots(lit: &lit, unlit: &unlit)
        context.setFillColor(unlitDotColor.cgColor)
        context.fill(unlit)
        context.setFillColor(litDotColor.cgColor)
        context.fill(lit)
        drawDecorations()
    }

    /// Adds the dots of every character, in design units.
    func drawDots(lit: inout [CGRect], unlit: inout [CGRect]) {}

    /// Draws what is printed around the dots (labels), in design units.
    func drawDecorations() {}

    /// Adds one character's dots: `rows` x `columns` dots of `glyph` from `origin`.
    func addGlyph(_ glyph: [UInt8], at origin: CGPoint, rows: Int, columns: Int,
                  dot: CGSize, pitch: CGSize, lit: inout [CGRect], unlit: inout [CGRect]) {
        for row in 0..<min(rows, glyph.count) {
            for column in 0..<columns {
                let rect = CGRect(x: origin.x + CGFloat(column) * pitch.width,
                                  y: origin.y + CGFloat(row) * pitch.height,
                                  width: dot.width, height: dot.height)
                if glyph[row] & (0x10 >> column) != 0 {
                    lit.append(rect)
                } else {
                    unlit.append(rect)
                }
            }
        }
    }
}

/// The SC-55's LCD, laid out like the panel picture of Nuked SC-55 (lcd.cpp): the part's
/// parameters on the left, the level bars of the 16 parts on the right. The bars are
/// user glyphs that the firmware redraws.
final class SC55LCDView: DotMatrixLCDView {
    struct State: Equatable {
        var ddram = [UInt8](repeating: 0x20, count: 80)
        var cgram = [UInt8](repeating: 0, count: 64)
        var enabled = false
    }

    var state = State() {
        didSet {
            guard state != oldValue else { return }
            setNeedsDisplay()
            accessibilityValue = fieldsDescription()
        }
    }

    private static let canvasRect = CGRect(x: 20, y: 0, width: 701, height: 268)
    static let aspectRatio = canvasRect.width / canvasRect.height
    override var canvas: CGRect { Self.canvasRect }

    /// A field of characters: its position in display RAM and on the panel.
    private struct Field {
        let label: String
        let start: Int
        let count: Int
        let x: CGFloat
        let y: CGFloat
    }

    private static let fields = [
        Field(label: "PART", start: 0, count: 3, x: 34, y: 11),
        Field(label: "INSTRUMENT", start: 3, count: 16, x: 153, y: 11),
        Field(label: "LEVEL", start: 40, count: 3, x: 34, y: 75),
        Field(label: "PAN", start: 43, count: 3, x: 153, y: 75),
        Field(label: "REVERB", start: 49, count: 3, x: 34, y: 139),
        Field(label: "CHORUS", start: 46, count: 3, x: 153, y: 139),
        Field(label: "KEY SHIFT", start: 52, count: 3, x: 34, y: 203),
        Field(label: "MIDI CH", start: 55, count: 3, x: 153, y: 203),
    ]

    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 15, weight: .bold),
        .foregroundColor: UIColor(red: 0.38, green: 0.15, blue: 0.02, alpha: 1),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backlightColor = UIColor(red: 0.91, green: 0.43, blue: 0.08, alpha: 1)
        unlitDotColor = UIColor(red: 0.87, green: 0.40, blue: 0.06, alpha: 1)
        litDotColor = UIColor(red: 0.16, green: 0.06, blue: 0.02, alpha: 1)
        accessibilityLabel = "SC-55 の液晶"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func code(at index: Int) -> UInt8 {
        state.enabled && index < state.ddram.count ? state.ddram[index] : 0x20
    }

    override func drawDots(lit: inout [CGRect], unlit: inout [CGRect]) {
        for field in Self.fields {
            for i in 0..<field.count {
                addGlyph(LCDCharacterROM.rows(code(at: field.start + i), cgram: state.cgram),
                         at: CGPoint(x: field.x + CGFloat(i) * 35, y: field.y), rows: 7, columns: 5,
                         dot: CGSize(width: 5, height: 5), pitch: CGSize(width: 6, height: 6),
                         lit: &lit, unlit: &unlit)
            }
        }
        // 16 parts x 16 steps: upper and lower halves of 3 full characters and one
        // character's first column.
        for half in 0..<2 {
            for column in 0..<4 {
                addGlyph(LCDCharacterROM.rows(code(at: 20 + column + half * 40), cgram: state.cgram),
                         at: CGPoint(x: 293 + CGFloat(column) * 130, y: 71 + CGFloat(half) * 88),
                         rows: 8, columns: column == 3 ? 1 : 5,
                         dot: CGSize(width: 24, height: 9), pitch: CGSize(width: 26, height: 11),
                         lit: &lit, unlit: &unlit)
            }
        }
    }

    override func drawDecorations() {
        for field in Self.fields {
            (field.label as NSString).draw(at: CGPoint(x: field.x, y: field.y + 44),
                                           withAttributes: Self.labelAttributes)
        }
    }

    private func fieldsDescription() -> String {
        guard state.enabled else { return "" }
        return Self.fields.map { field -> String in
            let bytes = (0..<field.count).map { code(at: field.start + $0) }
            let text = String(decoding: bytes.map { (0x20..<0x7f).contains($0) ? $0 : 0x20 }, as: UTF8.self)
            return "\(field.label) \(text.trimmingCharacters(in: .whitespaces))"
        }.joined(separator: "、")
    }
}

/// The MT-32's 20-character LCD.
final class MT32LCDView: DotMatrixLCDView {
    /// Character codes, at most 20.
    var text: [UInt8] = [] {
        didSet {
            guard text != oldValue else { return }
            setNeedsDisplay()
            accessibilityValue = String(decoding: text.map { (0x20..<0x7f).contains($0) ? $0 : 0x20 },
                                        as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
    }

    private static let canvasRect = CGRect(x: -16, y: -13, width: 726, height: 67)
    static let aspectRatio = canvasRect.width / canvasRect.height
    override var canvas: CGRect { Self.canvasRect }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backlightColor = UIColor(red: 0.62, green: 0.76, blue: 0.20, alpha: 1)
        unlitDotColor = UIColor(red: 0.58, green: 0.72, blue: 0.18, alpha: 1)
        litDotColor = UIColor(red: 0.10, green: 0.16, blue: 0.03, alpha: 1)
        accessibilityLabel = "MT-32 の液晶"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawDots(lit: inout [CGRect], unlit: inout [CGRect]) {
        for i in 0..<20 {
            let code = i < text.count ? text[i] : 0x20
            addGlyph(LCDCharacterROM.rows(code), at: CGPoint(x: CGFloat(i) * 35, y: 0), rows: 7, columns: 5,
                     dot: CGSize(width: 5, height: 5), pitch: CGSize(width: 6, height: 6),
                     lit: &lit, unlit: &unlit)
        }
    }
}

/// The internal sound module's front panel in the drive bay: its LCD and, on the MT-32,
/// the MIDI MESSAGE lamp. Tapping it opens the MIDI menu.
private final class ModulePanelView: UIView {
    let kind: MIDIController.InternalSynth
    var menuProvider: (() -> [UIMenuElement])?

    private let lcd: DotMatrixLCDView
    private let messageLamp = LampView()
    private let menuButton = UIButton(type: .custom)

    init(kind: MIDIController.InternalSynth) {
        self.kind = kind
        let aspectRatio: CGFloat
        let maxLCDHeight: CGFloat
        switch kind {
        case .sc55:
            lcd = SC55LCDView()
            aspectRatio = SC55LCDView.aspectRatio
            maxLCDHeight = 116
        case .mt32:
            lcd = MT32LCDView()
            aspectRatio = MT32LCDView.aspectRatio
            maxLCDHeight = 36
        }
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.10, alpha: 1)
        layer.cornerRadius = 10
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor

        let nameLabel = UILabel()
        nameLabel.text = kind.displayName
        nameLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        nameLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        let caption = UIStackView(arrangedSubviews: [nameLabel])
        caption.spacing = 12
        caption.alignment = .center
        if kind == .mt32 {
            messageLamp.color = LampColor.midiMessage
            let messageLabel = UILabel()
            messageLabel.text = "MIDI MESSAGE"
            messageLabel.font = .systemFont(ofSize: 8, weight: .medium)
            messageLabel.textColor = UIColor.white.withAlphaComponent(0.55)
            let message = UIStackView(arrangedSubviews: [messageLamp, messageLabel])
            message.spacing = 4
            message.alignment = .center
            caption.addArrangedSubview(message)
        }
        caption.isUserInteractionEnabled = false

        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.menuProvider?() ?? [])
            }
        ])
        menuButton.accessibilityLabel = "\(kind.displayName)：MIDI メニュー"

        for subview in [menuButton, caption, lcd] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        let fullWidth = lcd.widthAnchor.constraint(equalTo: widthAnchor, constant: -20)
        fullWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            menuButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            menuButton.topAnchor.constraint(equalTo: topAnchor),
            menuButton.bottomAnchor.constraint(equalTo: bottomAnchor),

            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            caption.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            caption.heightAnchor.constraint(equalToConstant: 14),

            lcd.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 4),
            lcd.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            lcd.centerXAnchor.constraint(equalTo: centerXAnchor),
            lcd.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -20),
            fullWidth,
            lcd.heightAnchor.constraint(equalTo: lcd.widthAnchor, multiplier: 1 / aspectRatio),
            lcd.heightAnchor.constraint(lessThanOrEqualToConstant: maxLCDHeight),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Copies the module's LCD (and MIDI MESSAGE lamp) as of its last rendered buffer.
    func updateFromCore() {
        switch kind {
        case .sc55:
            var ddram = [UInt8](repeating: 0x20, count: 80)
            var cgram = [UInt8](repeating: 0, count: 64)
            var enabled = false
            guard X68SC55_GetLCD(&ddram, &cgram, &enabled) else { return }
            (lcd as? SC55LCDView)?.state = SC55LCDView.State(ddram: ddram, cgram: cgram, enabled: enabled)
        case .mt32:
            var text = [CChar](repeating: 0, count: 21)
            var led = false
            guard X68MT32_GetDisplay(&text, &led) else { return }
            (lcd as? MT32LCDView)?.text = text.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            messageLamp.isLit = led
        }
    }
}

// MARK: - CYBER STICK throttle

/// Shows the CYBER STICK throttle for a moment while the hinge moves it.
final class ThrottleHUDView: UIView {
    private let titleLabel = UILabel()
    private let bar = UIView()
    private let fill = UIView()
    private let percentLabel = UILabel()
    /// 0 = pulled fully back, 1 = pushed fully forward.
    private var level: CGFloat = 0.5
    private var hideTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.6)
        layer.cornerRadius = 10
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor
        isUserInteractionEnabled = false
        alpha = 0

        titleLabel.text = "THROTTLE"
        titleLabel.font = .systemFont(ofSize: 8, weight: .bold)
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        percentLabel.textColor = .white
        percentLabel.textAlignment = .center
        bar.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        bar.layer.cornerRadius = 3
        bar.clipsToBounds = true
        fill.backgroundColor = UIColor(red: 1.0, green: 0.62, blue: 0.2, alpha: 1)
        bar.addSubview(fill)

        let stack = UIStackView(arrangedSubviews: [titleLabel, bar, percentLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bar.widthAnchor.constraint(equalToConstant: 12),
            bar.heightAnchor.constraint(equalToConstant: 64),
            percentLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "スロットル"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = bar.bounds.height * level
        fill.frame = CGRect(x: 0, y: bar.bounds.height - height, width: bar.bounds.width, height: height)
    }

    /// Shows `level` (0 = back ... 1 = forward) and fades out shortly after the last change.
    func show(level newLevel: CGFloat) {
        level = min(1, max(0, newLevel))
        percentLabel.text = "\(Int((level * 100).rounded()))%"
        accessibilityValue = percentLabel.text
        setNeedsLayout()
        layoutIfNeeded()
        hideTimer?.invalidate()
        if alpha < 1 {
            UIView.animate(withDuration: 0.15) { self.alpha = 1 }
        }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            UIView.animate(withDuration: 0.4) { self?.alpha = 0 }
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        alpha = 0
    }
}

// MARK: - Lower panel picker

/// What the lower half shows when the inner display is upright (L-shaped / laptop
/// posture, or fully open in portrait).
enum InnerPanel: Int, CaseIterable {
    case keyboard, pad, trackpad, sound

    static let defaultsKey = "ios_inner_panel"

    static var saved: InnerPanel {
        get {
            guard UserDefaults.standard.object(forKey: defaultsKey) != nil else { return .keyboard }
            return InnerPanel(rawValue: UserDefaults.standard.integer(forKey: defaultsKey)) ?? .keyboard
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var symbolName: String {
        switch self {
        case .keyboard: return "keyboard"
        case .pad: return "gamecontroller"
        case .trackpad: return "cursorarrow"
        case .sound: return "waveform"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .keyboard: return "キーボード"
        case .pad: return "仮想パッド"
        case .trackpad: return "トラックパッド"
        case .sound: return "サウンドモニター"
        }
    }
}

final class InnerPanelPicker: UISegmentedControl {
    var onChange: ((InnerPanel) -> Void)?

    var selection: InnerPanel {
        get { InnerPanel(rawValue: selectedSegmentIndex) ?? .keyboard }
        set { selectedSegmentIndex = newValue.rawValue }
    }

    init() {
        super.init(frame: .zero)
        for panel in InnerPanel.allCases {
            let image = UIImage(systemName: panel.symbolName)
            image?.accessibilityLabel = panel.accessibilityLabel
            insertSegment(with: image, at: panel.rawValue, animated: false)
        }
        selectedSegmentTintColor = UIColor.white.withAlphaComponent(0.3)
        backgroundColor = UIColor.white.withAlphaComponent(0.08)
        setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        tintColor = .white
        addTarget(self, action: #selector(changed), for: .valueChanged)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func changed() {
        onChange?(selection)
    }
}
