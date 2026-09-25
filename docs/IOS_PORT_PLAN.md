# MPX68K for iOS 移植計画

MPX68K（macOS 版）をベースに、iOS / iPadOS 版「MPX68K for iOS」を開発する。
最重要ターゲットは iPhone Duo（iOS 27、内側 7.6" 1878×2670 / 外側 5.4" 1398×2034、ProMotion 120Hz）。

## リポジトリ運用

- `origin`   : https://github.com/YosAwed/MPX68K-iOS （private）
- `upstream` : https://github.com/YosAwed/MPX68K （macOS 版）
- エミュレーションコア（`X68000 Shared/px68k`、`SC55/core`、`c68k`）は upstream と共通に保ち、
  iOS 固有の変更は `#if os(iOS)` / `TARGET_OS_IOS` で分離して `git merge upstream/master` を容易にする。
- iOS ターゲットは MPX68K の `68a0c0c`（`f2ba723` で削除される直前）に存在した
  `X68000 iOS/` を出発点として復元する。
- ROM（CGROM.DAT / IPLROM.DAT / SC-55 ROM 等）は絶対にコミットしない。

## iPhone Duo 対応の要件（Apple 公式ガイダンスより）

参照: [Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)、
[Designing for iPhone Duo (HIG)](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)、
Tech Talks 111461 / 111464

- iOS 27.1 SDK（Xcode 27.1）でビルドしないとステータスバー・カメラ下まで全画面にならない。
- 最新 SDK では UIScene ライフサイクルが必須（TN3187）。`SceneDelegate` を導入する。
- 内側ディスプレイは supported orientations を無視する。レイアウトは向き・idiom ではなく
  サイズクラスとシーン境界で決める。`UIScreen.main` は将来非推奨。
- Split View マルチタスクに全アプリが参加するため、任意のサイズで破綻しないこと。
- ゲーム向け HIG: 「レターボックスよりアスペクト比の変更を優先。避けられないなら余白をアートワークで埋める」
  → X68000 画面は 4:3 固定なので、余白をバーチャルパッド / ソフトキーボード / 筐体アートで埋める。
- 折り目: `UIView.ReservedRegion` / `reservedRegions(kind:options:)`（半開き時のみ active）。
- 2 ペイン配置: `UIArrangementViewController`（overlay スタイルで半開き時に折り目の両側へ自動振り分け）
  → 半開き「ノート PC モード」= 片側に X68000 画面、片側にキーボード。
- ヒンジ: `UIHingeInteraction`（閉/半開/全開 + 角度）。レイアウトではなく演出用途。
- 検証: Xcode 27.1 Device Hub の iPhone Duo シミュレータ、App Resizability スキル。

## MPX68K 共有コードの iOS 移植性

Shared 配下に macOS 専用ファイルはないが、以下の修正が必要。

### コア（C/C++）

iPhoneOS 27.0 SDK（arm64, `-DHAVE_C68K -DTARGET_IOS`）で `clang -fsyntax-only` を実施し、失敗は以下 2 ファイルのみ。

- `px68k/x68k/scsi.c` : `#ifdef __APPLE__` で `<IOKit/usb/IOUSBLib.h>` を include → iOS SDK に存在しない。
  `TARGET_OS_OSX` ガードに変更（SCSI-U は iOS 非対応）。
- `px68k/x68k/ppi.c:21-27` : IOKit USB/シリアルヘッダを無条件 include（JoyportU）。`pia.c` / `winx68k.cpp` から
  `PPI_*` が呼ばれるため除外不可 → `TARGET_OS_OSX` でガードし iOS ではスタブ化。
- iOS ターゲットのプリプロセッサ定義は `HAVE_C68K, C68K_NO_JUMP_TABLE, TARGET_IOS`、リンクは `-lc68k`。
  （macOS 側の `TARGET_MACOS` はコア内で参照されていない。XDF/DIM/SASI は `TARGET_IOS` でメモリバッファ経由の読み込み）
- D88 は旧 iOS 版にあった `TARGET_IOS` のメモリバッファ読み込みが消え、パスを `fopen` する方式。
  iOS ではサンドボックス内にコピーしたパスを渡す。
- `X68000_GetImage` は再描画が無いフレームでは何もしない。Swift 側は永続バッファを保持し
  `X68000_GetFrameInfo` / `X68000_GetImageInto` を使う（最大 1024×1024）。
- 常時有効のファイルログ（`winx68k.cpp` の `DebugLog` → `/tmp`、`X68000_AppendSCSILog` → `$HOME/Documents/MPX68K/`）は
  iOS では Documents にゴミを出しうるため無効化する。
- `scc.c` の `/dev/ptmx`、`winx68k.cpp` の Monitor UNIX ソケットは iOS では使わない（TCP シリアルのみ検討）。
- `fmgen_simd.h` は arm64 で NEON に分岐済み。`*_optimized*` ファイルはプロジェクト外のデッドコード。
- 旧 X68iOS の画像リソース（`JoyCardLeft.png` / `JoyCardStick.png` / `X68000LogoW.png` / `X68000Mouse.png`）は
  MPX68K で削除済みなので、`68a0c0c` から復元する。
- SC-55（Nuked-SC55, `SC55/core`）は SDL 非依存化済みで iOS でもそのままビルド可能見込み。Debug でも `-O2`。
- ブリッジングヘッダは新コアの API（`X68000_GetImageInto` / `X68000_GetFrameInfo` / `X68000_IsFrameDirty` /
  `X68000_Mouse_Event` / `SCC_*` / `X68000_SCSI_*` / `X68000_Monitor_*` 等）を使うこと。

### Swift

| 分類 | ファイル |
|---|---|
| そのまま | BenchMark, ConfigScene, X68Device, TAAnalogJoyStick, X68JoyCard, X68ErrorHandling, X68Security, X68Logger（subsystem 名変更）, CRT/CRTSettings, CRT/CRTFilterManager, Superimpose/SuperimposeManager, SC55/SC55Synthesizer, AudioStream |
| 小修正 | JoyController（通知許可リクエスト削除）, CRT/CRTOverlay（NSEvent ハンドラを `#if os(macOS)`）, SCCManager（TCP のみ） |
| 要改修 | FileSystem / GameScene / MIDIController（`.withSecurityScope` ブックマークは iOS で使用不可 → ヘルパー化）, MIDIController（`import AppKit`・`NSAlert` をガード）, X68MouseController（iOS のタッチ絶対座標パスが消失 → 復元）, GameScene（`UIApplication.shared.windows` → シーン経由、iOS で仮想パッドが既定で非表示になる問題、座標直書き） |
| 対象外 | `X68000 macOS/*`（iOS 版 SceneDelegate / ViewController を新規作成）, SCSI-U, SCC PTY/シリアル |

- iOS 用に `AVAudioSession` 設定（旧 iOS AppDelegate の `configureAudioSession`）と
  割り込み / ルート変更対応を追加する（AudioQueue と SC-55 の AVAudioEngine の両方）。
- ハードウェアキーボードは旧 iOS `GameViewController` の `pressesBegan` + `iOStoX68` テーブルを移植。

## フェーズ

1. **iOS ターゲット復元**: `68a0c0c` の `X68000 iOS/` を復元し、UIScene 化した上で新コアに対してビルドを通す。
   Info.plist 整理（`armv7` 削除、`CADisableMinimumFrameDurationOnPhone`、表示名「MPX68K for iOS」）。
2. **iOS 実用化**: オーディオセッション、タッチマウス、仮想パッド既定値、ファイル取り込み（Document Picker / ROM インポート）。
3. **リサイズ対応**: `.resizeFill` 化、safe area 内に 4:3 画面 + 余白に操作系を配置、Split View 対応。
4. **iPhone Duo 最適化**: ReservedRegion / UIArrangementViewController による半開きノート PC モード、120Hz 検証。
