//
//  GameViewController.swift
//  MPX68K for iOS
//
//  Created by GOROman on 2020/03/28.
//  Copyright © 2020 GOROman. All rights reserved.
//

import UIKit
import SpriteKit
import UniformTypeIdentifiers

final class GameViewController: UIViewController {

    /// FileSystem から起動メディアの確認を依頼するための参照（macOS 版と同じ名前）。
    private(set) static weak var shared: GameViewController?

    private(set) var gameScene: GameScene?

    /// シーン接続時に渡されたディスクイメージ。最初の表示後に読み込む。
    var pendingURLs: [URL] = []

    /// 起動メディアが無い状態でディスクを受け取ったら、読み込み完了後にリセットして起動する。
    private var resetWhenBootMediaReady = false
    private var didPromptForBootMedia = false

    // MARK: Touch input
    private enum InputMode {
        case mouse   // トラックパッド風マウス
        case pad     // 仮想ジョイスティック
    }
    /// Settings.bundle の「virtual_pad」と共有する
    private static let virtualPadDefaultsKey = "virtual_pad"
    /// The D-pad sends cursor keys instead of joystick directions.
    private static let padCursorKeysDefaultsKey = "virtual_pad_cursor_keys"
    private var touchMouse: TouchMouseController?
    private let virtualPad = VirtualPadView()
    private let inputModeButton = UIButton(type: .system)
    private let trackpad = TrackpadSurfaceView()
    private let fullKeyboard = X68KeyboardView()
    /// Inner display (fully open or partially folded) held upright: show the full keyboard.
    private var showsFullKeyboard = false {
        didSet { if showsFullKeyboard != oldValue { applyInputMode() } }
    }
    private let padOutputButton = UIButton(type: .system)
    private let diskButton = UIButton(type: .system)
    private let topButtonRow = UIStackView()
    private var padUsesCursorKeys = UserDefaults.standard.bool(forKey: GameViewController.padCursorKeysDefaultsKey)
    private var lastPadBits: UInt8 = 0

    // MARK: Layout
    private let screenController = ScreenViewController()
    private let controlPanel = ControlPanelViewController()
    /// iPhone Duo partially folded: the control panel has its own side of the fold.
    private var isSplit = false {
        didSet { if isSplit != oldValue { applyInputMode() } }
    }
    /// Area of the control panel the controls may use.
    private let controlArea = UILayoutGuide()
    private var controlAreaTopToPanel: NSLayoutConstraint?
    private var controlAreaTopToScreen: NSLayoutConstraint?
    /// Portrait without a fold split: screen at the top, controls in the space below.
    private var stacksControlsBelowScreen = false {
        didSet {
            guard stacksControlsBelowScreen != oldValue else { return }
            screenController.alignsToTop = stacksControlsBelowScreen
            controlAreaTopToPanel?.isActive = !stacksControlsBelowScreen
            controlAreaTopToScreen?.isActive = stacksControlsBelowScreen
        }
    }
    private var inputMode: InputMode = .mouse {
        didSet { applyInputMode() }
    }

    // MARK: Hardware keyboard state
    /// Key code sent for each held host key, so the matching key-up is sent.
    private var pressedKeyCodes: [UIKeyboardHIDUsage: UInt32] = [:]
    private var physicalShiftKeys: Set<UIKeyboardHIDUsage> = []
    /// SHIFT state as last sent to the X68000.
    private var x68ShiftDown = false
    private weak var bootMediaAlert: UIAlertController?
    private var documentPickerHandler: DocumentPickerHandler?
    /// 画面表示前に要求されたダイアログ（viewDidAppear で表示する）
    private var pendingPresentations: [() -> Void] = []

    private static let diskContentTypes: [UTType] = [
        UTType("NANKIN.X68000.1.FDD"),
        UTType("NANKIN.X68000.1.HDD"),
    ].compactMap { $0 }

    override func loadView() {
        view = UIView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        GameViewController.shared = self
        view.backgroundColor = .black

        setUpLayout()
        controlPanel.onLayout = { [weak self] in self?.updateLayoutState() }
        screenController.onLayout = { [weak self] in self?.updateLayoutState() }

        let skView = screenController.skView
        skView.ignoresSiblingOrder = true
        skView.isMultipleTouchEnabled = true

        let scene = GameScene.newGameScene()
        gameScene = scene
        screenController.setAspectRatio(scene.size)
        skView.presentScene(scene)
        // GameScene.sks は macOS 版と共有しているため、タイトルの表記だけ差し替える
        scene.enumerateChildNodes(withName: "//*") { node, _ in
            if let label = node as? SKLabelNode, label.text == "for macOS" {
                label.text = "for iOS"
            }
        }

        setUpTouchInput(on: skView)
        setUpHingeEffect()

        NotificationCenter.default.addObserver(
            self, selector: #selector(diskImageLoadFinished(_:)),
            name: .diskImageLoadFinished, object: nil)
        // 起動時の自動マウント（前回状態の復元）完了
        NotificationCenter.default.addObserver(
            self, selector: #selector(diskImageLoadFinished(_:)),
            name: .diskImageLoaded, object: nil)
    }

    override var canBecomeFirstResponder: Bool { true }

    /// ハードウェアキー入力（pressesBegan）を受けるため first responder になっているが、文字入力欄ではない。
    /// それでもディスクメニューを開くとシステムがソフトウェアキーボードを出してしまうので、
    /// 空の inputView を返してキーボードの代わりに何も表示させない（X68000 のキー入力は画面上のキーボードで行う）。
    private let noSoftwareKeyboard = UIView(frame: .zero)
    override var inputView: UIView? { noSoftwareKeyboard }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateLayoutState()
    }

    /// Derives split / stacking / keyboard state from where the arrangement put the panes.
    /// Runs after this view and after either pane lays out: going from partially folded to
    /// fully open keeps the window size, so only the panes move and this view's
    /// viewDidLayoutSubviews may not run (or runs before the panes reach their new frames).
    private func updateLayoutState() {
        guard isViewLoaded, controlPanel.isViewLoaded, screenController.isViewLoaded,
              view.bounds.width > 0, view.bounds.height > 0 else { return }
        let wasSplit = isSplit
        let wasStacked = stacksControlsBelowScreen
        let wasKeyboard = showsFullKeyboard
        // Overlaid, the panel covers the screen; split by the fold, they don't overlap.
        let panelFrame = controlPanel.view.convert(controlPanel.view.bounds, to: view)
        let screenFrame = screenController.view.convert(screenController.view.bounds, to: view)
        isSplit = !panelFrame.intersects(screenFrame.insetBy(dx: 1, dy: 1))
        let isPortrait = view.bounds.height > view.bounds.width
        stacksControlsBelowScreen = !isSplit && isPortrait
        // The inner display's short side is well over 600 pt; the outer display's is not.
        let screenBounds = view.window?.windowScene?.screen.bounds ?? .zero
        let isInnerDisplay = min(screenBounds.width, screenBounds.height) >= 600
        showsFullKeyboard = isPortrait && isInnerDisplay
        if isSplit != wasSplit || stacksControlsBelowScreen != wasStacked || showsFullKeyboard != wasKeyboard {
            // Constraints changed from inside a pane's layout pass; lay out again.
            controlPanel.view.setNeedsLayout()
            screenController.view.setNeedsLayout()
            view.setNeedsLayout()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        // シーン内の入力モード表示は macOS 向け。iOS では右上のボタンで切り替える。
        gameScene?.childNode(withName: "//InputModeButton")?.removeFromParent()
        let urls = pendingURLs
        pendingURLs.removeAll()
        urls.forEach(load)

        let presentations = pendingPresentations
        pendingPresentations.removeAll()
        presentations.forEach { $0() }
    }

    // MARK: - Touch input

    private func setUpLayout() {
        let container: UIViewController
        #if canImport(UIKit.UIArrangementViewController)
        if #available(iOS 27.1, *) {
            // Overlay arrangement: the primary (controls) sits on top of the secondary
            // (screen); when partially folded they move to either side of the fold.
            let arrangement = UIArrangementViewController()
            arrangement.setViewController(controlPanel, for: .primary)
            arrangement.setViewController(screenController, for: .secondary)
            arrangement.updateArrangement(.overlay)
            container = arrangement
        } else {
            container = OverlayContainerViewController(screen: screenController, controls: controlPanel)
        }
        #else
        container = OverlayContainerViewController(screen: screenController, controls: controlPanel)
        #endif

        addChild(container)
        container.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container.view)
        NSLayoutConstraint.activate([
            container.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.view.topAnchor.constraint(equalTo: view.topAnchor),
            container.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        container.didMove(toParent: self)
    }

    // MARK: - Hinge effect

    /// iPhone Duo: switch the "CRT" off while folding shut and back on while opening.
    private func setUpHingeEffect() {
        #if DEBUG
        // The simulator's Device Hub switches poses without intermediate angles, so
        // preview the CRT effect with a three-finger double tap on the screen.
        let preview = UITapGestureRecognizer(target: self, action: #selector(toggleCRTPreview))
        preview.numberOfTouchesRequired = 3
        preview.numberOfTapsRequired = 2
        screenController.skView.addGestureRecognizer(preview)

        // Device Hub can't produce three-finger taps and keeps Command shortcuts for
        // itself, so also offer a button on the screen's top-leading corner.
        let button = UIButton(type: .system)
        button.setTitle("CRT", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        button.tintColor = UIColor.white.withAlphaComponent(0.8)
        button.backgroundColor = UIColor.systemRed.withAlphaComponent(0.35)
        button.layer.cornerRadius = 14
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(toggleCRTPreview), for: .touchUpInside)
        let screenView = screenController.view!
        screenView.addSubview(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 48),
            button.heightAnchor.constraint(equalToConstant: 28),
            button.leadingAnchor.constraint(equalTo: screenView.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            button.topAnchor.constraint(equalTo: screenView.safeAreaLayoutGuide.topAnchor, constant: 16),
        ])
        #endif
        #if canImport(UIKit.UIArrangementViewController)
        if #available(iOS 27.1, *) {
            let interaction = UIHingeInteraction { [weak self] _, update in
                self?.hingeChanged(update.hinge)
            }
            view.addInteraction(interaction)
        }
        #endif
    }

    #if DEBUG
    /// Command-Shift-P also previews the CRT effect (easier than three fingers in the simulator).
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "CRT 電源演出", action: #selector(toggleCRTPreview),
                      input: "p", modifierFlags: [.command, .shift])]
    }

    @objc private func toggleCRTPreview() {
        if screenController.isPoweredOn {
            screenController.powerOff()
        } else {
            screenController.powerOn()
        }
    }
    #endif

    #if canImport(UIKit.UIArrangementViewController)
    /// Angles (degrees) with some hysteresis so the effect doesn't flicker around one angle.
    private static let crtOffAngle: CGFloat = 50
    private static let crtOnAngle: CGFloat = 70

    @available(iOS 27.1, *)
    private func hingeChanged(_ hinge: UIHinge?) {
        // Folding changes where the panes go; make sure the layout state follows.
        view.setNeedsLayout()
        guard let hinge else {
            // No hinge in this hierarchy (not an iPhone Duo).
            screenController.resetPower()
            return
        }
        switch hinge.status {
        case .partiallyOpen, .fullyOpen:
            let degrees = hinge.angle * 180 / .pi
            if degrees < Self.crtOffAngle {
                screenController.powerOff()
            } else if degrees > Self.crtOnAngle {
                screenController.powerOn()
            }
        default:
            // Closed: the app is on the outer display, show the picture as usual.
            screenController.resetPower()
        }
    }
    #endif

    private func setUpTouchInput(on skView: SKView) {
        touchMouse = TouchMouseController(view: skView) { [weak self] in self?.gameScene }
        touchMouse?.addSurface(trackpad)

        let panel = controlPanel.view!
        virtualPad.translatesAutoresizingMaskIntoConstraints = false
        virtualPad.onChange = { [weak self] bits in
            self?.sendPad(bits)
        }
        virtualPad.onKey = { code, pressed in
            if pressed {
                X68000_Key_Down(code)
            } else {
                X68000_Key_Up(code)
            }
        }
        trackpad.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(trackpad)
        panel.addSubview(virtualPad)

        fullKeyboard.translatesAutoresizingMaskIntoConstraints = false
        fullKeyboard.onKey = { code, pressed in
            if pressed {
                X68000_Key_DownScancode(UInt32(code))
            } else {
                X68000_Key_UpScancode(UInt32(code))
            }
        }
        panel.addSubview(fullKeyboard)

        inputModeButton.translatesAutoresizingMaskIntoConstraints = false
        inputModeButton.tintColor = UIColor.white.withAlphaComponent(0.8)
        inputModeButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        inputModeButton.layer.cornerRadius = 22
        inputModeButton.addTarget(self, action: #selector(toggleInputMode), for: .touchUpInside)

        padOutputButton.translatesAutoresizingMaskIntoConstraints = false
        padOutputButton.tintColor = UIColor.white.withAlphaComponent(0.8)
        padOutputButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        padOutputButton.layer.cornerRadius = 16
        padOutputButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        padOutputButton.addTarget(self, action: #selector(togglePadOutput), for: .touchUpInside)

        setUpDiskButton()

        // Hidden buttons collapse, so the disk button stays at the right edge on its own
        // while the full keyboard is shown.
        topButtonRow.axis = .horizontal
        topButtonRow.alignment = .center
        topButtonRow.spacing = 8
        [diskButton, padOutputButton, inputModeButton].forEach { topButtonRow.addArrangedSubview($0) }
        topButtonRow.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(topButtonRow)

        panel.addLayoutGuide(controlArea)
        let guide = controlArea
        let safe = panel.safeAreaLayoutGuide
        controlAreaTopToPanel = controlArea.topAnchor.constraint(equalTo: safe.topAnchor)
        controlAreaTopToScreen = controlArea.topAnchor.constraint(equalTo: skView.bottomAnchor, constant: 4)
        controlAreaTopToPanel?.isActive = true
        NSLayoutConstraint.activate([
            controlArea.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            controlArea.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            controlArea.bottomAnchor.constraint(equalTo: safe.bottomAnchor),

            fullKeyboard.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 6),
            fullKeyboard.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -6),
            fullKeyboard.topAnchor.constraint(equalTo: topButtonRow.bottomAnchor, constant: 6),
            fullKeyboard.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),

            virtualPad.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            virtualPad.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            virtualPad.topAnchor.constraint(equalTo: topButtonRow.bottomAnchor),
            virtualPad.bottomAnchor.constraint(equalTo: guide.bottomAnchor),

            trackpad.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            trackpad.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            trackpad.topAnchor.constraint(equalTo: topButtonRow.bottomAnchor, constant: 12),
            trackpad.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),

            topButtonRow.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            topButtonRow.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
            topButtonRow.heightAnchor.constraint(equalToConstant: 44),

            inputModeButton.widthAnchor.constraint(equalToConstant: 44),
            inputModeButton.heightAnchor.constraint(equalToConstant: 44),
            diskButton.widthAnchor.constraint(equalToConstant: 44),
            diskButton.heightAnchor.constraint(equalToConstant: 44),
            padOutputButton.widthAnchor.constraint(equalToConstant: 56),
            padOutputButton.heightAnchor.constraint(equalToConstant: 32),
        ])

        inputMode = UserDefaults.standard.bool(forKey: Self.virtualPadDefaultsKey) ? .pad : .mouse
    }

    // MARK: - Disk menu

    private static let recentDisksDefaultsKey = "ios_recent_disks"
    private static let maxRecentDisks = 8

    private func setUpDiskButton() {
        diskButton.setImage(UIImage(systemName: "opticaldiscdrive"), for: .normal)
        diskButton.tintColor = UIColor.white.withAlphaComponent(0.8)
        diskButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        diskButton.layer.cornerRadius = 22
        diskButton.accessibilityLabel = "ディスク"
        diskButton.showsMenuAsPrimaryAction = true
        // Rebuilt each time it opens so the drive contents are current.
        diskButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.diskMenuElements() ?? [])
            }
        ])
    }

    private func diskMenuElements() -> [UIMenuElement] {
        var elements: [UIMenuElement] = (0..<2).map(floppyMenu(for:))
        elements.append(hardDiskMenu())
        if let midi = midiMenu() { elements.append(midi) }
        let reset = UIAction(title: "リセット", image: UIImage(systemName: "arrow.counterclockwise")) { [weak self] _ in
            self?.gameScene?.resetSystem()
        }
        elements.append(UIMenu(options: .displayInline, children: [reset]))
        return elements
    }

    /// MIDI output: internal SC-55 or MT-32 (ROMs in Documents/MPX68K, optional) or external CoreMIDI.
    private func midiMenu() -> UIMenu? {
        guard let midi = gameScene?.midiOutputController else { return nil }
        let active = midi.activeInternalSynth

        func internalAction(_ kind: MIDIController.InternalSynth, hint: String) -> UIAction {
            let hasROMs = MIDIController.hasROMsInLibrary(for: kind)
            return UIAction(title: "内蔵 \(kind.displayName)",
                            subtitle: hasROMs ? nil : hint,
                            image: UIImage(systemName: kind == .sc55 ? "pianokeys" : "pianokeys.inverse"),
                            attributes: hasROMs ? [] : .disabled,
                            state: active == kind ? .on : .off) { [weak self] _ in
                midi.iOSMIDIOutput = kind == .sc55 ? .sc55 : .mt32
                midi.applyIOSMIDIOutput { ok in
                    // Only an explicit choice reports a problem; startup falls back silently.
                    if !ok { self?.showInternalSynthUnavailable(kind) }
                }
            }
        }
        let useSC55 = internalAction(.sc55, hint: "ROM を MPX68K フォルダに置くと使えます")
        let useMT32 = internalAction(.mt32, hint: "コントロール ROM と PCM ROM を MPX68K フォルダに置くと使えます")
        let useExternal = UIAction(title: "外部 MIDI",
                                   image: UIImage(systemName: "cable.connector"),
                                   state: active == nil ? .on : .off) { _ in
            midi.iOSMIDIOutput = .external
            midi.applyIOSMIDIOutput()
        }
        var children: [UIMenuElement] = [UIMenu(options: .displayInline, children: [useSC55, useMT32, useExternal])]

        if let kind = active, let synth = midi.activeSynthesizer {
            let current = Int((synth.volume * 100).rounded())
            let levels = [25, 50, 75, 100]
            let volume = UIMenu(title: "\(kind.displayName) 音量", image: UIImage(systemName: "speaker.wave.2"),
                                children: levels.map { level in
                UIAction(title: "\(level)%", state: current == level ? .on : .off) { _ in
                    synth.volume = Double(level) / 100
                }
            })
            children.append(volume)
            // A C major chord at full velocity, 1.5 s (a single note is quite quiet).
            let test = UIAction(title: "\(kind.displayName) テスト音", image: UIImage(systemName: "play.circle")) { _ in
                midi.playInternalTestChord()
            }
            children.append(test)
        }
        var title = "MIDI：外部 MIDI"
        if let kind = active {
            title = "MIDI：内蔵 \(kind.displayName)"
        }
        let menu = UIMenu(title: title, image: UIImage(systemName: "music.note"), children: children)
        if active == .mt32, let rom = MT32Synthesizer.shared.loadedROMDescription {
            menu.subtitle = rom
        }
        return menu
    }

    private func showInternalSynthUnavailable(_ kind: MIDIController.InternalSynth) {
        let message: String
        switch kind {
        case .sc55:
            message = "MPX68K フォルダの SC-55 ROM を読み込めなかったため、外部 MIDI に出力します。\n"
                + "初代 SC-55 の sc55_rom1.bin、sc55_rom2.bin、sc55_waverom1.bin〜sc55_waverom3.bin が必要です（mkII は非対応）。"
        case .mt32:
            message = "MPX68K フォルダの MT-32 ROM を読み込めなかったため、外部 MIDI に出力します。\n"
                + "MT-32（または CM-32L）のコントロール ROM と PCM ROM が必要です。ファイル名は問いません"
                + "（例: MT32_CONTROL.ROM と MT32_PCM.ROM）。分割されたダンプは非対応です。"
        }
        let alert = UIAlertController(title: "内蔵 \(kind.displayName) を使えません",
                                      message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func floppyMenu(for drive: Int) -> UIMenu {
        let mounted = mountedFloppyURL(drive)
        let insert = UIAction(title: mounted == nil ? "ディスクを入れる…" : "ディスクを入れ替える…",
                              image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
            self?.presentDiskLibrary(kind: .floppy, drive: drive)
        }
        let eject = UIAction(title: "取り出す", image: UIImage(systemName: "eject"),
                             attributes: mounted == nil ? .disabled : .destructive) { [weak self] _ in
            self?.gameScene?.ejectFDDFromDrive(drive)
        }
        var children: [UIMenuElement] = [insert, eject]
        let recent = recentDisks().filter { $0.standardizedFileURL != mounted?.standardizedFileURL }
        if !recent.isEmpty {
            children.append(UIMenu(title: "最近使ったディスク", image: UIImage(systemName: "clock"),
                                   children: recent.map { url in
                UIAction(title: url.lastPathComponent) { [weak self] _ in
                    self?.insertFloppy(url, drive: drive)
                }
            }))
        }
        return UIMenu(title: "ドライブ\(drive)：\(mounted?.lastPathComponent ?? "（なし）")",
                      image: UIImage(systemName: "square.fill"), children: children)
    }

    private func hardDiskMenu() -> UIMenu {
        let mounted = mountedHardDiskURL()
        let attach = UIAction(title: mounted == nil ? "接続…" : "入れ替える…",
                              image: UIImage(systemName: "externaldrive.badge.plus")) { [weak self] _ in
            self?.presentDiskLibrary(kind: .hardDisk, drive: 0)
        }
        let detach = UIAction(title: "取り外す", image: UIImage(systemName: "eject"),
                              attributes: mounted == nil ? .disabled : .destructive) { [weak self] _ in
            self?.gameScene?.ejectHDD()
        }
        return UIMenu(title: "HDD：\(mounted?.lastPathComponent ?? "（なし）")",
                      image: UIImage(systemName: "externaldrive"), children: [attach, detach])
    }

    private func mountedFloppyURL(_ drive: Int) -> URL? {
        guard X68000_IsFDDReady(drive) != 0, let path = X68000_GetFDDFilename(drive) else { return nil }
        let string = String(cString: path)
        return string.isEmpty ? nil : URL(fileURLWithPath: string)
    }

    private func mountedHardDiskURL() -> URL? {
        guard X68000_IsHDDReady() != 0, let path = X68000_GetHDDFilename() else { return nil }
        let string = String(cString: path)
        return string.isEmpty ? nil : URL(fileURLWithPath: string)
    }

    private func presentDiskLibrary(kind: DiskLibraryViewController.Kind, drive: Int) {
        let title = kind == .floppy ? "ドライブ\(drive)に入れるディスク" : "接続するハードディスク"
        let mounted = kind == .floppy ? mountedFloppyURL(drive) : mountedHardDiskURL()
        let library = DiskLibraryViewController(
            title: title, kind: kind, mountedURL: mounted,
            onSelect: { [weak self] url in self?.mount(url, kind: kind, drive: drive) },
            onImport: { [weak self] in self?.importDisks(kind: kind, drive: drive) })
        let navigation = UINavigationController(rootViewController: library)
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigation, animated: true)
    }

    /// Imports disk images from elsewhere into the library and mounts the first one.
    private func importDisks(kind: DiskLibraryViewController.Kind, drive: Int) {
        presentDocumentPicker(contentTypes: Self.diskContentTypes, allowsMultipleSelection: true) { [weak self] urls in
            guard let self, let urls, !urls.isEmpty else { return }
            let imported = urls.map(self.importIntoDocuments)
            if let first = imported.first(where: { kind.extensions.contains($0.pathExtension.lowercased()) }) {
                self.mount(first, kind: kind, drive: drive)
            }
        }
    }

    private func mount(_ url: URL, kind: DiskLibraryViewController.Kind, drive: Int) {
        switch kind {
        case .floppy:
            insertFloppy(url, drive: drive)
        case .hardDisk:
            let needsBoot = !Self.hasBootMedia()
            gameScene?.loadHDD(url: url) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.rememberRecentDisk(url)
                    if needsBoot { self.gameScene?.resetSystem() }
                case .failure(let error):
                    self.showDiskError(error, name: url.lastPathComponent)
                }
            }
        }
    }

    private func insertFloppy(_ url: URL, drive: Int) {
        let needsBoot = !Self.hasBootMedia()
        switch gameScene?.loadFDDToDrive(url: url, drive: drive) {
        case .success:
            rememberRecentDisk(url)
            if needsBoot {
                // Same as a first boot disk from Files: boot from it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.gameScene?.resetSystem()
                }
            }
        case .failure(let error):
            showDiskError(error, name: url.lastPathComponent)
        case nil:
            break
        }
    }

    private func showDiskError(_ error: Error, name: String) {
        let alert = UIAlertController(title: "\(name) を読み込めませんでした",
                                      message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// Recently used disks, stored by file name inside Documents/MPX68K.
    private func recentDisks() -> [URL] {
        guard let folder = DiskLibraryViewController.libraryFolder else { return [] }
        let names = UserDefaults.standard.stringArray(forKey: Self.recentDisksDefaultsKey) ?? []
        return names
            .map { folder.appendingPathComponent($0) }
            .filter { DiskLibraryViewController.Kind.floppy.extensions.contains($0.pathExtension.lowercased())
                && FileManager.default.fileExists(atPath: $0.path) }
    }

    private func rememberRecentDisk(_ url: URL) {
        let name = url.lastPathComponent
        var names = UserDefaults.standard.stringArray(forKey: Self.recentDisksDefaultsKey) ?? []
        names.removeAll { $0 == name }
        names.insert(name, at: 0)
        UserDefaults.standard.set(Array(names.prefix(Self.maxRecentDisks)), forKey: Self.recentDisksDefaultsKey)
    }

    // MARK: Virtual pad output

    @objc private func togglePadOutput() {
        virtualPad.releaseAll()
        padUsesCursorKeys.toggle()
        UserDefaults.standard.set(padUsesCursorKeys, forKey: Self.padCursorKeysDefaultsKey)
        updatePadOutputButton()
    }

    private func updatePadOutputButton() {
        virtualPad.usesKeys = padUsesCursorKeys
        padOutputButton.setTitle(padUsesCursorKeys ? "KEY" : "JOY", for: .normal)
        padOutputButton.accessibilityLabel = padUsesCursorKeys
            ? "方向パッド: カーソルキー（タップでジョイスティックに切り替え）"
            : "方向パッド: ジョイスティック（タップでカーソルキーに切り替え）"
    }

    /// Sends the pad state as joystick bits, or the directions as cursor keys.
    private func sendPad(_ bits: UInt8) {
        let directions: [(bit: UInt8, key: UInt32)] = [
            (JOY_UP, 0x111), (JOY_DOWN, 0x112), (JOY_RIGHT, 0x113), (JOY_LEFT, 0x114),
        ]
        let directionMask: UInt8 = JOY_UP | JOY_DOWN | JOY_LEFT | JOY_RIGHT
        if padUsesCursorKeys {
            let changed = (bits ^ lastPadBits) & directionMask
            for (bit, key) in directions where changed & bit != 0 {
                if bits & bit != 0 {
                    X68000_Key_Down(key)
                } else {
                    X68000_Key_Up(key)
                }
            }
            X68000_Joystick_Set(0, bits & ~directionMask)
        } else {
            X68000_Joystick_Set(0, bits)
        }
        lastPadBits = bits
    }

    @objc private func toggleInputMode() {
        inputMode = (inputMode == .mouse) ? .pad : .mouse
        UserDefaults.standard.set(inputMode == .pad, forKey: Self.virtualPadDefaultsKey)
    }

    private func applyInputMode() {
        fullKeyboard.isHidden = !showsFullKeyboard
        inputModeButton.isHidden = showsFullKeyboard
        if showsFullKeyboard {
            // Keyboard layout: the screen stays a touch mouse; pad and trackpad are hidden.
            virtualPad.releaseAll()
            virtualPad.isHidden = true
            trackpad.isHidden = true
            padOutputButton.isHidden = true
            touchMouse?.isEnabled = true
            return
        }
        fullKeyboard.releaseAll()

        let isPad = (inputMode == .pad)
        touchMouse?.isEnabled = !isPad
        virtualPad.isHidden = !isPad
        padOutputButton.isHidden = !isPad
        updatePadOutputButton()
        if !isPad {
            virtualPad.releaseAll()
        }
        // The trackpad panel only appears on its own side of the fold.
        trackpad.isHidden = isPad || !isSplit
        // ボタンには「切り替え先」を表示する
        let symbol = isPad ? "cursorarrow" : "gamecontroller"
        inputModeButton.setImage(UIImage(systemName: symbol), for: .normal)
        inputModeButton.accessibilityLabel = isPad ? "マウス操作に切り替え" : "仮想パッドに切り替え"
    }

    // MARK: - Disk images

    func load(_ url: URL) {
        if !Self.hasBootMedia() {
            resetWhenBootMediaReady = true
        }
        gameScene?.load(url: url)
    }

    private static func hasBootMedia() -> Bool {
        X68000_IsFDDReady(0) != 0 || X68000_IsFDDReady(1) != 0 || X68000_IsHDDReady() != 0
    }

    @objc private func diskImageLoadFinished(_ notification: Notification) {
        let url = notification.object as? URL
        // 読み込み完了はバックグラウンドから通知されることがある
        DispatchQueue.main.async { [weak self] in
            if let url, DiskLibraryViewController.Kind.floppy.extensions.contains(url.pathExtension.lowercased()) {
                self?.rememberRecentDisk(url)
            }
            self?.handleDiskImageLoadFinished(attempt: 0)
        }
    }

    /// 完了通知の時点ではドライブへの挿入がまだ終わっていないことがあるため、少し待って確認する。
    private func handleDiskImageLoadFinished(attempt: Int) {
        guard Self.hasBootMedia() else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.handleDiskImageLoadFinished(attempt: attempt + 1)
                }
            }
            return
        }
        DiskStateManager.shared.saveCurrentState()
        if let alert = bootMediaAlert, alert.presentingViewController != nil {
            alert.dismiss(animated: true)
        }
        if resetWhenBootMediaReady {
            resetWhenBootMediaReady = false
            // macOS 版の resetAfterBootMediaInsert と同じく、読み込みが落ち着いてからリセットする
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.gameScene?.resetSystem()
            }
        }
    }

    /// 起動時の自動マウント後に FileSystem から呼ばれる。起動メディアが無ければ選択を促す。
    func promptForBootMediaIfNeeded() {
        promptForBootMediaIfNeeded(attempt: 0)
    }

    /// 復元したディスクはドライブへの挿入が少し遅れるので、しばらく待ってから判断する。
    private func promptForBootMediaIfNeeded(attempt: Int) {
        guard !didPromptForBootMedia, !Self.hasBootMedia(), presentedViewController == nil else { return }
        if attempt < 6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.promptForBootMediaIfNeeded(attempt: attempt + 1)
            }
            return
        }
        didPromptForBootMedia = true

        let alert = UIAlertController(
            title: "起動ディスクを選択してください",
            message: "ディスクイメージ（.xdf / .dim / .d88 / .hdf など）を選ぶと起動します。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "ファイルを選択…", style: .default) { [weak self] _ in
            self?.presentDiskPicker()
        })
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        bootMediaAlert = alert
        present(alert, animated: true)
    }

    private func presentDiskPicker() {
        presentDocumentPicker(contentTypes: Self.diskContentTypes, allowsMultipleSelection: false) { [weak self] urls in
            guard let self, let url = urls?.first else { return }
            self.load(self.importIntoDocuments(url))
        }
    }

    // MARK: - ROM files

    /// FileSystem / GameScene から呼ばれる（macOS 版と同じ名前）。足りない ROM を選んでもらい、
    /// Documents/MPX68K に取り込めたら completion(true)。
    func promptForMissingROMFiles(_ missing: [String], completion: @escaping (Bool) -> Void) {
        guard !missing.isEmpty else {
            completion(true)
            return
        }
        // エミュレータ初期化は画面表示より先に走るため、表示できるまで待つ
        guard view.window != nil else {
            pendingPresentations.append { [weak self] in
                self?.promptForMissingROMFiles(missing, completion: completion)
            }
            return
        }

        let names = missing.joined(separator: " と ")
        let alert = UIAlertController(
            title: "ROM ファイルが必要です",
            message: "\(names) を選択してください。取り込んだファイルは「このiPhone内」→「MPX68K for iOS」→「MPX68K」に保存されます。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "ROM ファイルを選択…", style: .default) { [weak self] _ in
            self?.presentROMPicker(missing, completion: completion)
        })
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { _ in
            completion(false)
        })
        present(alert, animated: true)
    }

    private func presentROMPicker(_ missing: [String], completion: @escaping (Bool) -> Void) {
        presentDocumentPicker(contentTypes: [.data], allowsMultipleSelection: true) { [weak self] urls in
            guard let self else { return }
            guard let urls, !urls.isEmpty else {
                completion(false)
                return
            }
            guard let fileSystem = self.gameScene?.fileSystem else {
                completion(false)
                return
            }
            do {
                let imported = try fileSystem.importROMFiles(urls, requiredFilenames: missing)
                let remaining = missing.filter { !imported.contains($0.uppercased()) }
                if remaining.isEmpty {
                    completion(true)
                } else {
                    self.showROMImportProblem(
                        "\(remaining.joined(separator: " と ")) がまだ見つかりません。ファイル名が \(remaining.joined(separator: " / ")) になっているか確認してください。",
                        missing: remaining, completion: completion)
                }
            } catch {
                self.showROMImportProblem(error.localizedDescription, missing: missing, completion: completion)
            }
        }
    }

    private func showROMImportProblem(_ message: String, missing: [String], completion: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: "ROM を取り込めませんでした", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "選び直す", style: .default) { [weak self] _ in
            self?.presentROMPicker(missing, completion: completion)
        })
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { _ in
            completion(false)
        })
        present(alert, animated: true)
    }

    // MARK: - Document picker

    private func presentDocumentPicker(contentTypes: [UTType], allowsMultipleSelection: Bool,
                                       completion: @escaping ([URL]?) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = allowsMultipleSelection
        let handler = DocumentPickerHandler { [weak self] urls in
            self?.documentPickerHandler = nil
            completion(urls)
        }
        documentPickerHandler = handler
        picker.delegate = handler
        present(picker, animated: true)
    }

    /// 次回起動時に自動マウントできるよう、選ばれたディスクを Documents/MPX68K に置く。
    private func importIntoDocuments(_ url: URL) -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return url
        }
        let folder = documents.appendingPathComponent("MPX68K", isDirectory: true)
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: url)
            } else {
                try FileManager.default.moveItem(at: url, to: destination)
            }
            return destination
        } catch {
            errorLog("Failed to import disk image: \(error)", category: .fileSystem)
            return url
        }
    }

    // MARK: - Scene lifecycle

    func sceneWillResignActive() {
        gameScene?.applicationWillResignActive()
    }

    func sceneDidBecomeActive() {
        gameScene?.applicationDidBecomeActive()
    }

    func sceneWillEnterForeground() {
        gameScene?.applicationWillEnterForeground()
    }

    func saveState() {
        gameScene?.fileSystem?.saveSRAM()
        if Self.hasBootMedia() {
            DiskStateManager.shared.saveCurrentState()
        }
    }

    // MARK: - Appearance

    override var prefersStatusBarHidden: Bool { true }

    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    // MARK: - Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !keyDown($0) }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !keyUp($0) }
        if !unhandled.isEmpty {
            super.pressesEnded(unhandled, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !keyUp($0) }
        if !unhandled.isEmpty {
            super.pressesCancelled(unhandled, with: event)
        }
    }

    private func keyDown(_ press: UIPress) -> Bool {
        guard let key = press.key else { return false }
        let usage = key.keyCode

        if iOSKeyMap.isShift(usage) {
            physicalShiftKeys.insert(usage)
            setX68Shift(true)
            return true
        }
        if let code = iOSKeyMap.specialKeyCode(for: usage) {
            X68000_Key_Down(code)
            pressedKeyCodes[usage] = code
            return true
        }

        // With CTRL held, `characters` is a control code; use the plain key.
        let text = key.modifierFlags.contains(.control) ? key.charactersIgnoringModifiers : key.characters
        guard let character = text.first, let mapped = iOSKeyMap.characterKey(for: character) else {
            if let code = iOSKeyMap.jisKeyCode(for: usage) {
                X68000_Key_Down(code)
                pressedKeyCodes[usage] = code
                return true
            }
            return false
        }
        // Letters follow the SHIFT key as pressed (CAPS is forwarded to the X68000).
        // Symbols use the SHIFT state the X68000 JIS layout needs for that character.
        if !character.isLetter {
            setX68Shift(mapped.shift)
        }
        X68000_Key_Down(mapped.code)
        pressedKeyCodes[usage] = mapped.code
        return true
    }

    private func keyUp(_ press: UIPress) -> Bool {
        guard let usage = press.key?.keyCode else { return false }

        if iOSKeyMap.isShift(usage) {
            physicalShiftKeys.remove(usage)
            setX68Shift(!physicalShiftKeys.isEmpty)
            return true
        }
        guard let code = pressedKeyCodes.removeValue(forKey: usage) else { return false }
        X68000_Key_Up(code)
        // Put SHIFT back to what the user is actually holding.
        setX68Shift(!physicalShiftKeys.isEmpty)
        return true
    }

    private func setX68Shift(_ down: Bool) {
        guard down != x68ShiftDown else { return }
        x68ShiftDown = down
        if down {
            X68000_Key_Down(iOSKeyMap.shiftKey)
        } else {
            X68000_Key_Up(iOSKeyMap.shiftKey)
        }
    }
}

/// Forwards a document picker's result to a closure (nil when cancelled).
private final class DocumentPickerHandler: NSObject, UIDocumentPickerDelegate {
    private let completion: ([URL]?) -> Void

    init(completion: @escaping ([URL]?) -> Void) {
        self.completion = completion
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        completion(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion(nil)
    }
}

/// Pre-iOS 27.1 layout: the controls simply lie on top of the screen.
private final class OverlayContainerViewController: UIViewController {
    private let screen: UIViewController
    private let controls: UIViewController

    init(screen: UIViewController, controls: UIViewController) {
        self.screen = screen
        self.controls = controls
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for child in [screen, controls] {
            addChild(child)
            child.view.frame = view.bounds
            child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(child.view)
            child.didMove(toParent: self)
        }
    }
}
