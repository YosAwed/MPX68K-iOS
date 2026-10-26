# MPX68K for iOS — 開発引き継ぎメモ

最終更新: 2026-10-02（2026-09-25 に Mac mini への移行用に作成）

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
- **内蔵 MIDI 音源（任意）**: 同じ `Documents/MPX68K` に SC-55 の `sc55_*.bin` 5 本、または MT-32 の
  コントロール ROM と PCM ROM（ファイル名は自由。内容の SHA-1 で判定）を置くと、ディスクメニューの MIDI から
  「内蔵 SC-55 / 内蔵 MT-32 / 外部 MIDI」を切り替えられる。`sim-media/install_to_simulator.sh` は `*.bin` と `*.rom` もコピーする。
- **テスト**: `make -C tests/core`（コア単体テスト）、`make -C tests/mt32`（MT-32 ブリッジ、ROM 不要）。
  実 ROM での確認は `make -C tests/mt32 rom ROM_DIR=...`。iOS 用の自動テストはまだ無い。

## 2. リポジトリとブランチの状態

| ブランチ | 内容 | 状態 |
|---|---|---|
| `master` | iOS 版一式（iPhone Duo 対応、フルキーボード、CRT 演出、ディスクメニュー、内蔵 SC-55 / MT-32） | PR #1 と `ios/disk-menu`・`ios/mt32` を統合済み |
| `ios/merge-upstream-4.5` | `master` ＋ upstream MPX68K 4.5（#31 コア修正、#32 CPU クロック / Turbo / サウンドスレッド整理） | iOS・macOS ビルド、`tests/core`、iPad 実機での FM / ADPCM / SC-55 再生を確認済み |
| `ios/bootstrap`, `ios/phase1-target`, `ios/phase2-boot`, `ios/disk-menu`, `ios/mt32` | 過去の段階（すべて `master` に含まれる） | 削除してよい |

- `origin` = YosAwed/MPX68K-iOS（private）、`upstream` = YosAwed/MPX68K（macOS 版、public）。
- GitHub Actions はリポジトリ設定で無効化済み（private の macOS ランナー課金を避けるため。workflow ファイル自体は upstream と共通なので残す）。
- upstream へ出した修正 PR: YosAwed/MPX68K#30（キー表・ジョイカード A/B・ログ無効化・swift-crypto 削除）はマージ済み。

## 3. 次にやること

1. `ios/merge-upstream-4.5` を `master` へマージ。
2. iOS で CPU クロック / Turbo / No-Wait を選べるようにするか検討（upstream 4.5 では macOS のメニューのみ。iOS は 24MHz・等速固定）。
3. TestFlight 準備: バンドル ID が仮の `NANKIN.MPX68K-iOS`（`tools/generate_ios_project.py` の `PRODUCT_BUNDLE_IDENTIFIER`）。Team は `DQR9HH7KUY`。
4. 実機（iPhone Duo）でのみ確認できる項目:
   - ヒンジ連動の CRT 電源演出（閉じ 50° / 開き 70° のしきい値、速さ）
   - タッチマウスの感度
   - 画面サイズ変更時の重さ（Debug ビルドは c68k 以外が最適化なしで重い。Release での体感も要確認。エミュレーションはメインスレッド）
5. 任意: キー配列・F キー等の macOS 側残課題（`IOS_PORT_PLAN.md` 参照。F キーは macOS 側で意図的に別処理なので対応不要）。

### iPad 実機でのテスト

iPhone Duo が手元にない間は iPad で代用できる（`TARGETED_DEVICE_FAMILY` = iPhone / iPad）。折りたたみ・ヒンジ関係以外は確認できる。

```bash
xcrun devicectl list devices
xcodebuild -project "MPX68K iOS.xcodeproj" -scheme "MPX68K iOS" -configuration Release -destination 'id=<iPad の UDID>' -allowProvisioningUpdates build
xcrun devicectl device install app --device <UDID> <DerivedData>/Build/Products/Release-iphoneos/MPX68K.app
```

ROM・ディスク・内蔵音源 ROM は「ファイル」アプリの「このiPad内」→「MPX68K for iOS」→「MPX68K」に置く（Finder のデバイス画面の「ファイル」タブからも可）。
SC-55 は `sc55_rom1.bin` `sc55_rom2.bin` `sc55_waverom1.bin` `sc55_waverom2.bin` `sc55_waverom3.bin` の 5 つ、MT-32 / CM-32L は内容で判別。起動時に読むので置いたらアプリを再起動。MIDI の切り替えはディスクボタンのメニュー。

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
| `X68000 iOS/DuoPanels.swift` | iPhone Duo の姿勢別パネル（ランプ列、ドライブベイ、下半分の切り替え） |
| `X68000 iOS/DiskLibraryViewController.swift` | ディスク一覧シート |
| `X68000 iOS/iOSKeyMap.swift` | ハードウェアキーボードの変換 |
| `X68000 iOS/SceneDelegate.swift`, `AppDelegate.swift`, `Info.plist` | UIScene ライフサイクル・設定 |
| `tools/generate_ios_project.py` | iOS プロジェクト生成 |
