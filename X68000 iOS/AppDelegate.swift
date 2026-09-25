//
//  AppDelegate.swift
//  MPX68K for iOS
//
//  Created by GOROman on 2020/03/28.
//  Copyright © 2020 GOROman. All rights reserved.
//

import UIKit
import AVFoundation

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        configureAudioSession()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func applicationWillTerminate(_ application: UIApplication) {
        for case let windowScene as UIWindowScene in application.connectedScenes {
            (windowScene.delegate as? SceneDelegate)?.saveState()
        }
    }

    /// AVAudioSession の設定は同期呼び出しで、メディアサーバーの応答待ちでブロックすることがある
    /// （Xcode の Thread Performance Checker が「AVAudioSession Hang Risk」として警告する）。
    /// 起動中のメインスレッドを止めないよう、専用のシリアルキューで行う。
    private static let audioSessionQueue = DispatchQueue(label: "MPX68K.audioSession", qos: .userInitiated)

    private func configureAudioSession() {
        Self.audioSessionQueue.async {
            let session = AVAudioSession.sharedInstance()
            do {
                // 他のアプリの音と混在させる
                try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
            } catch {
                errorLog("Audio session setup failed: \(error)", category: .audio)
            }
        }
    }
}
