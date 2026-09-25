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
    private weak var bootMediaAlert: UIAlertController?

    private static let diskContentTypes: [UTType] = [
        UTType("NANKIN.X68000.1.FDD"),
        UTType("NANKIN.X68000.1.HDD"),
    ].compactMap { $0 }

    override func loadView() {
        view = SKView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        GameViewController.shared = self
        view.backgroundColor = .black

        guard let skView = view as? SKView else { return }
        skView.ignoresSiblingOrder = true
        skView.isMultipleTouchEnabled = true
        #if DEBUG
        skView.showsFPS = true
        skView.showsNodeCount = true
        #endif

        let scene = GameScene.newGameScene()
        gameScene = scene
        skView.presentScene(scene)
        // GameScene.sks は macOS 版と共有しているため、タイトルの表記だけ差し替える
        scene.enumerateChildNodes(withName: "//*") { node, _ in
            if let label = node as? SKLabelNode, label.text == "for macOS" {
                label.text = "for iOS"
            }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(diskImageLoadFinished(_:)),
            name: .diskImageLoadFinished, object: nil)
        // 起動時の自動マウント（前回状態の復元）完了
        NotificationCenter.default.addObserver(
            self, selector: #selector(diskImageLoadFinished(_:)),
            name: .diskImageLoaded, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let urls = pendingURLs
        pendingURLs.removeAll()
        urls.forEach(load)
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
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.diskContentTypes, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
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
        let unhandled = presses.filter { !sendKey($0, isDown: true) }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !sendKey($0, isDown: false) }
        if !unhandled.isEmpty {
            super.pressesEnded(unhandled, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = presses.filter { !sendKey($0, isDown: false) }
        if !unhandled.isEmpty {
            super.pressesCancelled(unhandled, with: event)
        }
    }

    private func sendKey(_ press: UIPress, isDown: Bool) -> Bool {
        guard let keyCode = press.key?.keyCode,
              let x68Key = iOSKeyMap.x68KeyCode(for: keyCode) else {
            return false
        }
        if isDown {
            X68000_Key_Down(x68Key)
        } else {
            X68000_Key_Up(x68Key)
        }
        return true
    }
}

extension GameViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        load(importIntoDocuments(url))
    }
}
