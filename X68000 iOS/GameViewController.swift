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
    private let padOutputButton = UIButton(type: .system)
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

        let skView = screenController.skView
        skView.ignoresSiblingOrder = true
        skView.isMultipleTouchEnabled = true
        #if DEBUG
        skView.showsFPS = true
        skView.showsNodeCount = true
        #endif

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

        NotificationCenter.default.addObserver(
            self, selector: #selector(diskImageLoadFinished(_:)),
            name: .diskImageLoadFinished, object: nil)
        // 起動時の自動マウント（前回状態の復元）完了
        NotificationCenter.default.addObserver(
            self, selector: #selector(diskImageLoadFinished(_:)),
            name: .diskImageLoaded, object: nil)
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Overlaid, the panel covers the screen; split by the fold, they don't overlap.
        let panelFrame = controlPanel.view.convert(controlPanel.view.bounds, to: view)
        let screenFrame = screenController.view.convert(screenController.view.bounds, to: view)
        isSplit = !panelFrame.intersects(screenFrame.insetBy(dx: 1, dy: 1))
        stacksControlsBelowScreen = !isSplit && view.bounds.height > view.bounds.width
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

        inputModeButton.translatesAutoresizingMaskIntoConstraints = false
        inputModeButton.tintColor = UIColor.white.withAlphaComponent(0.8)
        inputModeButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        inputModeButton.layer.cornerRadius = 22
        inputModeButton.addTarget(self, action: #selector(toggleInputMode), for: .touchUpInside)
        panel.addSubview(inputModeButton)

        padOutputButton.translatesAutoresizingMaskIntoConstraints = false
        padOutputButton.tintColor = UIColor.white.withAlphaComponent(0.8)
        padOutputButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        padOutputButton.layer.cornerRadius = 16
        padOutputButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        padOutputButton.addTarget(self, action: #selector(togglePadOutput), for: .touchUpInside)
        panel.addSubview(padOutputButton)

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

            virtualPad.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            virtualPad.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            virtualPad.topAnchor.constraint(equalTo: inputModeButton.bottomAnchor),
            virtualPad.bottomAnchor.constraint(equalTo: guide.bottomAnchor),

            trackpad.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            trackpad.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            trackpad.topAnchor.constraint(equalTo: inputModeButton.bottomAnchor, constant: 12),
            trackpad.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),

            inputModeButton.widthAnchor.constraint(equalToConstant: 44),
            inputModeButton.heightAnchor.constraint(equalToConstant: 44),
            inputModeButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),

            padOutputButton.widthAnchor.constraint(equalToConstant: 56),
            padOutputButton.heightAnchor.constraint(equalToConstant: 32),
            padOutputButton.centerYAnchor.constraint(equalTo: inputModeButton.centerYAnchor),
            padOutputButton.trailingAnchor.constraint(equalTo: inputModeButton.leadingAnchor, constant: -8),
            inputModeButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),
        ])

        inputMode = UserDefaults.standard.bool(forKey: Self.virtualPadDefaultsKey) ? .pad : .mouse
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
        // 読み込み完了はバックグラウンドから通知されることがある
        DispatchQueue.main.async { [weak self] in
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
