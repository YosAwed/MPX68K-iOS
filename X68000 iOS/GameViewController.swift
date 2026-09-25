//
//  GameViewController.swift
//  MPX68K for iOS
//
//  Created by GOROman on 2020/03/28.
//  Copyright © 2020 GOROman. All rights reserved.
//

import UIKit
import SpriteKit

final class GameViewController: UIViewController {

    private(set) var gameScene: GameScene?

    /// シーン接続時に渡されたディスクイメージ。最初の表示後に読み込む。
    var pendingURLs: [URL] = []

    override func loadView() {
        view = SKView(frame: .zero)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
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
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let urls = pendingURLs
        pendingURLs.removeAll()
        urls.forEach(load)
    }

    // MARK: - Scene lifecycle

    func load(_ url: URL) {
        gameScene?.load(url: url)
    }

    func sceneWillResignActive() {
        gameScene?.applicationWillResignActive()
    }

    func sceneDidBecomeActive() {
        gameScene?.applicationDidBecomeActive()
    }

    func sceneWillEnterForeground() {
        gameScene?.applicationWillEnterForeground()
    }

    func saveSRAM() {
        gameScene?.fileSystem?.saveSRAM()
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
