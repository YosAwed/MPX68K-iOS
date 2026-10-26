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
//    shown on its own side of the fold in the book posture.
//  - InnerPanelPicker chooses what the lower half shows: keyboard, pad or trackpad.
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

    private var slots: [DriveSlotView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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

    /// Height for the three slots.
    static let preferredHeight: CGFloat = 3 * 46 + 2 * 8
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

// MARK: - Lower panel picker

/// What the lower half shows when the inner display is upright (L-shaped / laptop
/// posture, or fully open in portrait).
enum InnerPanel: Int, CaseIterable {
    case keyboard, pad, trackpad

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
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .keyboard: return "キーボード"
        case .pad: return "仮想パッド"
        case .trackpad: return "トラックパッド"
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
