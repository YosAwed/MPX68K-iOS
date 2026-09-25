//
//  SceneDelegate.swift
//  MPX68K for iOS
//

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    private var gameViewController: GameViewController? {
        window?.rootViewController as? GameViewController
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let viewController = GameViewController()
        // 起動時に渡されたディスクイメージはエミュレータ初期化後に読み込む
        viewController.pendingURLs = connectionOptions.urlContexts.map(\.url)

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        self.window = window
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            gameViewController?.load(context.url)
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        gameViewController?.sceneWillResignActive()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        gameViewController?.sceneDidBecomeActive()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        gameViewController?.sceneWillEnterForeground()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        saveState()
    }

    func saveState() {
        gameViewController?.saveSRAM()
    }
}
