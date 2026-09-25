# MPX68K for iOS — 開発引き継ぎメモ

最終更新: 2026-09-25（開発機を Mac mini に移行するため作成）

詳細な経緯と設計は `docs/IOS_PORT_PLAN.md` を参照。このファイルは「新しい Mac で続きを始める」ための手順と現状のまとめ。

## 1. 新しい Mac でのセットアップ

```bash
git clone https://github.com/YosAwed/MPX68K-iOS.git
cd MPX68K-iOS
git remote add upstream https://github.com/YosAwed/MPX68K.git   # macOS 版
git fetch upstream
git switch ios/disk-menu                                        # 最新の作業ブランチ
python3 tools/generate_ios_project.py                           # iOS プロジェクトを再生成（差分が出なければ OK）
open "MPX68K iOS.xcodeproj"
```

- **Xcode**: 通常ビルドは Xcode 27.0 以降。iPhone Duo（全画面表示・`UIArrangementViewController`・`UIHingeInteraction`）の確認には
  **Xcode 27.1 beta** が必要。コマンドラインでは `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` を付ける。
- **スキーム**: `MPX68K iOS`（iOS）。macOS 版は `X68000.xcodeproj` の `X68000 macOS`（事前に `c68k mac` のビルドが必要）。
- **ROM**（リポジトリには絶対に入れない）: `IPLROM.DAT` / `CGROM.DAT` を用意する（旧 Mac では `~/Documents/X68IPL/` に置いていた）。
  アプリ初回起動時に「ROM ファイルが必要です」→ ピッカーで取り込める。シミュレータに直接置く場合:
  ```bash
  C=$(xcrun simctl get_app_container <UDID> NANKIN.MPX68K-iOS data)
  mkdir -p "$C/Documents/MPX68K" && cp IPLROM.DAT CGROM.DAT HUMAN302.XDF "$C/Documents/MPX68K/"
  ```
- **テスト**: `make -C tests/core`（コア単体テスト）。iOS 用の自動テストはまだ無い。

## 2. リポジトリとブランチの状態

| ブランチ | 内容 | 状態 |
|---|---|---|
| `master` | upstream（MPX68K）の旧 master | iOS 未統合 |
| `ios/phase2-boot` | iOS ターゲット一式（Phase 1〜3、iPhone Duo 対応、フルキーボード、CRT 演出） | **PR #1（→ master）オープン中**、upstream/master（#30 を含む）マージ済み |
| `ios/disk-menu` | ↑ ＋ ディスクメニュー（挿入・入れ替え・取り出し・最近使ったディスク・HDD・リセット） | **動作未確認**。確認後 PR 化 |
| `ios/bootstrap`, `ios/phase1-target` | 過去の段階（phase2-boot に含まれる） | 削除してよい |

- `origin` = YosAwed/MPX68K-iOS（private）、`upstream` = YosAwed/MPX68K（macOS 版、public）。
- GitHub Actions はリポジトリ設定で無効化済み（private の macOS ランナー課金を避けるため。workflow ファイル自体は upstream と共通なので残す）。
- upstream へ出した修正 PR: YosAwed/MPX68K#30（キー表・ジョイカード A/B・ログ無効化・swift-crypto 削除）はマージ済み。

## 3. 次にやること

1. **`ios/disk-menu` の動作確認**（Device Hub で）:
   ディスクボタン → ドライブ0 →「ディスクを入れ替える…」で一覧 → 選択で入れ替わるか / 最近使ったディスク / 取り出す / リセット / HDD 接続。
   OK なら PR 化（`ios/phase2-boot` か `master` へ）。
2. PR #1 のマージ。
3. TestFlight 準備: バンドル ID が仮の `NANKIN.MPX68K-iOS`（`tools/generate_ios_project.py` の `PRODUCT_BUNDLE_IDENTIFIER`）。Team は `DQR9HH7KUY`。
4. 実機（iPhone Duo）でのみ確認できる項目:
   - ヒンジ連動の CRT 電源演出（閉じ 50° / 開き 70° のしきい値、速さ）
   - タッチマウスの感度
   - 画面サイズ変更時の重さ（Debug ビルドは c68k 以外が最適化なしで重い。Release での体感も要確認。エミュレーションはメインスレッド）
5. 任意: キー配列・F キー等の macOS 側残課題（`IOS_PORT_PLAN.md` 参照。F キーは macOS 側で意図的に別処理なので対応不要）。

## 4. 開発上の注意（旧 Mac で分かったこと）

- **`X68000.xcodeproj` は iOS のために手で編集しない。** iOS プロジェクトは生成物。upstream マージ後は `python3 tools/generate_ios_project.py` を再実行。
  新しい iOS 専用ファイルを足したら、スクリプトの `IOS_SOURCES` に追加する。
- **共有コード（`X68000 Shared/`）の変更は macOS の動作を変えない形に**（`#if os(iOS)` / `TARGET_OS_OSX` 等）。upstream にも出せる修正は PR にする。
  `keyboard.c` / `winx68k.cpp` など古いソースは UTF-8 ではないので、バイト列として編集する。
- **iPhone Duo シミュレータ（Xcode 27.1 beta の Device Hub）の癖**:
  - 半開きの姿勢では、どのアプリでも内側ディスプレイの上半分をシステムがぼかす（アプリの不具合ではない）。
  - 姿勢変更直後は数秒間ぼかした静止画が出る（アプリの再描画待ち）。
  - 開閉は段階的でヒンジ角度が途中の値を取らないため、CRT 演出は Debug ビルドの画面左上「CRT」ボタンで確認する。
    3 本指タップと ⌘ ショートカットは Device Hub から届かない。
  - `simctl` からアプリを起動するとバックグラウンドのままのことがある（Device Hub でタップして前面へ）。
  - 画面の取得は `xcrun simctl io <UDID> screenshot --display=<UUID>`（`simctl io <UDID> enumerate` で 2007×2853=内側、1398×2034=外側）。
  - Claude Code の iOS シミュレータ操作ツールは iPhone Duo に接続できず、Xcode 27.1 のシミュレータサービスが動いている間は他の機種も操作できなくなった。
- **閉じた状態での上下逆さの縦向き**は iOS がアプリを回さない（OS の仕様とみて現状維持）。
- 旧リポジトリ `X68iOS-master` の `CGROM_DAT.c` / `IPLROM_DAT.c` には ROM ダンプが入っているので公開しないこと（MPX68K-iOS では空の定義になっている）。

## 5. 主要ファイル

| ファイル | 役割 |
|---|---|
| `X68000 iOS/GameViewController.swift` | 入れ物。レイアウト（arrangement）、入力モード、ディスクメニュー、ROM/起動ディスク、ヒンジ、キーボード入力 |
| `X68000 iOS/ScreenLayout.swift` | 画面（SKView＋モニター枠＋CRT 演出）と操作パネル |
| `X68000 iOS/TouchMouseController.swift` | トラックパッド風マウス |
| `X68000 iOS/VirtualPadView.swift` | 仮想パッド（JOY/KEY） |
| `X68000 iOS/X68KeyboardView.swift` | X68000 フルキーボード |
| `X68000 iOS/DiskLibraryViewController.swift` | ディスク一覧シート |
| `X68000 iOS/iOSKeyMap.swift` | ハードウェアキーボードの変換 |
| `X68000 iOS/SceneDelegate.swift`, `AppDelegate.swift`, `Info.plist` | UIScene ライフサイクル・設定 |
| `tools/generate_ios_project.py` | iOS プロジェクト生成 |
