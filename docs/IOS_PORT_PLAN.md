# MPX68K for iOS 移植計画

MPX68K（macOS 版）をベースに、iOS / iPadOS 版「MPX68K for iOS」を開発する。
最重要ターゲットは iPhone Duo（iOS 27、内側 7.6" 1878×2670 / 外側 5.4" 1398×2034、ProMotion 120Hz）。

> 開発環境の移行手順・ブランチ状況・次の作業は [IOS_HANDOFF.md](IOS_HANDOFF.md) を参照。

## リポジトリ運用

- `origin`   : https://github.com/YosAwed/MPX68K-iOS （private）
- `upstream` : https://github.com/YosAwed/MPX68K （macOS 版）
- エミュレーションコア（`X68000 Shared/px68k`、`SC55/core`、`c68k`）は upstream と共通に保ち、
  iOS 固有の変更は `#if os(iOS)` / `TARGET_OS_IOS` で分離して `git merge upstream/master` を容易にする。
- iOS ターゲットは MPX68K の `68a0c0c`（`f2ba723` で削除される直前）に存在した
  `X68000 iOS/` を出発点として復元した。
- iOS 用プロジェクト `MPX68K iOS.xcodeproj` は `tools/generate_ios_project.py` が
  macOS プロジェクト（`X68000.xcodeproj`）のビルド対象から生成する。upstream マージ後は再生成する:
  `python3 tools/generate_ios_project.py`（`X68000.xcodeproj` は手で編集しない）。
- ROM は MPX68K と同様に外部ファイル。iOS では `Documents/MPX68K`（「ファイル」アプリの
  「このiPhone内」→「MPX68K for iOS」→「MPX68K」）に `IPLROM.DAT` / `CGROM.DAT` を置く。
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
- 旧 X68iOS の画像リソースのうち現行コードが参照するのは `jStick` / `jSubstrate` / `X68000LogoW`（アセットカタログ）のみで、
  いずれも MPX68K に残っているため復元不要。
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

1. ✅ **iOS ターゲット復元**: `68a0c0c` の `X68000 iOS/` を復元し、UIScene 化した上で新コアに対してビルドを通す。
   Info.plist 整理（`armv7` 削除、`CADisableMinimumFrameDurationOnPhone`、表示名「MPX68K for iOS」）。
2. **iOS 実用化**: オーディオセッション、タッチマウス、仮想パッド既定値、ファイル取り込み（Document Picker / ROM インポート）。
3. **リサイズ対応**: `.resizeFill` 化、safe area 内に 4:3 画面 + 余白に操作系を配置、Split View 対応。
4. **iPhone Duo 最適化**: ReservedRegion / UIArrangementViewController による半開きノート PC モード、120Hz 検証。

## Phase 1 結果（2026-09-25）

- `MPX68K iOS.xcodeproj` を生成し、Xcode 27.0 / iOS 27.0 シミュレータでビルド・起動を確認。
  ROM 未配置時は iOS のアラートで配置場所を案内する。
- iOS 固有: `SceneDelegate`（UIScene ライフサイクル）、プログラムで生成する `SKView`、
  ハードウェアキーボード（`iOSKeyMap`）、`AVAudioSession`、iOS 用アプリアイコン（`X68000 iOS/Assets.xcassets`）。
- 共有コードの変更（いずれも macOS の動作は不変）:
  - `scsi.c` / `ppi.c`: IOKit USB/シリアルを `TARGET_OS_OSX` に限定、SCSI-U のスタブ追加
  - `winx68k.cpp`: 旧 iOS 製品名由来のバージョン記号参照を削除
  - `FileSystem` / `GameScene` / `MIDIController`: ブックマークオプションを `x68SecurityScope` 経由に（iOS では通常ブックマーク）
  - `MIDIController` / `CRTOverlay`: AppKit 依存を `#if os(macOS)` に
  - `JoyController`: 通知許可リクエストを macOS のみに
  - `GameScene`: iOS のアラート表示を UIScene ベースに
- 未対応（Phase 2 以降）: タッチマウス、仮想パッド既定表示、タイトルの「for macOS」表記、
  ドキュメントピッカーでの ROM / ディスク取り込み、D88 のサンドボックス外パス、常時ファイルログの無効化、
  バンドル ID（仮: `NANKIN.MPX68K-iOS`）の確定。
- iPhone Duo シミュレータには Xcode 27.1 beta が必要（インストール済みの Xcode-beta は 27.0 beta）。

### 動作確認（2026-09-25, iPhone 18 Pro シミュレータ / iOS 27.0）

- 外部 ROM（`Documents/MPX68K` の IPLROM.DAT / CGROM.DAT）で起動し、Human68k 3.02（XDF）が `A>` まで起動。
- 「ファイルを開く」（`scene(_:openURLContexts:)`）経由の XDF マウントと、ハードウェアキーボード入力（`dir`）を確認。
- 既知の問題:
  - ディスクなしで起動すると IPL 実行中に CPU が `PC=$000154`（例外ベクタ領域）で停止し画面が黒いまま。
    macOS 版（同一コア・同一 ROM）でも同じ状態を確認したため iOS 固有ではない（upstream で要調査）。
  - 停止後にディスクを開いてもリセットされないため起動しない。iOS ではディスク投入時のリセット、またはリセット UI が必要。
  - 再起動時に前回のディスクが自動マウントされない（AutoMountMode 既定値 hybrid はファイルを記録するだけ）。
- macOS ターゲットは swift-crypto を外せば本ブランチの共有コード変更込みでビルド可能（swift-crypto はどの Swift ファイルからも import されていない）。

### タッチ入力（2026-09-25）

- マウス: `TouchMouseController`（SKView 上のジェスチャー）。1 本指ドラッグ＝相対移動、タップ＝左クリック、
  2 本指タップ＝右クリック、長押し＋ドラッグ＝左ドラッグ、ポインタのホバー（iPad トラックパッド / Pencil）＝移動。
  `X68MouseController` のキャプチャモード（macOS と同じ相対入力経路）に流す。X-BASIC の `mouse(1)` で追従を確認。
- 仮想パッド: `VirtualPadView`（UIKit、Auto Layout、safe area 基準）。8 方向パッド＋A/B。
  A＝トリガー A（`JOY_TRG2`, bit5）、B＝トリガー B（`JOY_TRG1`, bit6）。X-BASIC の `stick(1)`=6 / `strig(1)`=1 を確認。
  ※ macOS 版の画面上ジョイカード（`X68JoyCard`）は A/B が逆（A=`JOY_TRG1`）。物理パッド（`JoyController`）は規格どおり。
- 右上のボタンでマウス／パッドを切り替え（`virtual_pad` に保存）。GameScene の旧タッチマウス（絶対座標）と
  シーン内の入力モード表示は iOS では使わない。
- ハードウェアキーボード（`iOSKeyMap`）: 印字可能文字は入力された文字（`UIKey.characters`）から
  「X68000 JIS 配列のどのキーか＋SHIFT が必要か」を決め、SHIFT を一時的に上げ下げして送る。
  US 配列・JIS 配列どちらのホストキーボードでも刻印どおりに入力できる（記号・大小文字を Human68k で確認）。
  特殊キー（矢印・F1〜F10・Ctrl・Caps・テンキー等）は KeyTable 拡張領域の位置で送る。SHIFT キー自体は押下中そのまま送る。
  - F1〜F10 は KeyTable の f.1〜f.10（0x1be〜0x1c7）を使用。未検証（シミュレータから送れない）。
- 共有コードで修正済み（macOS 版にも効く）:
  - KeyTable の ASCII 割り当て: `'` を `0x6d`（電卓が出る）→ 7 キー、`:` `*` → `:*` キー、`;` `+` → `;+` キー。
  - 画面上ジョイカード（`X68JoyCard`）の A/B を規格どおりに（A＝トリガー A）。
  - macOS 版で JIS の ¥ キー（ASCII 外）が送られなかった問題（kVK_JIS_Yen → `\` の KeyTable）。
  - 常時有効だったコアのファイルログ（`winx68k.cpp` の `DebugLog` / `X68000_AppendSCSILog`）を
    `MPX68K_ENABLE_RUNTIME_FILE_LOGS`（既定 0）で無効化。
  - 未使用の swift-crypto 依存を `X68000.xcodeproj` から削除（Xcode 27.0 でビルド不能だった）。
- macOS 版の残課題（方針: US 配列での記号ずれは現状維持）:
  - macOS 版の F1〜F10（0x163〜0x16c）は KeyTable の空き（NC）を指しているように見える。
  - macOS 版 `AppDelegate.appendSCSILog` / `resetSCSILogs` も Documents/MPX68K と /tmp にログを常時書く。

### ROM 取り込み（2026-09-25）

- 起動時に IPLROM.DAT / CGROM.DAT が無ければ、macOS 版と同じ `GameViewController.promptForMissingROMFiles` 経路
  （GameScene の `#if os(macOS) || os(iOS)`）で iOS のドキュメントピッカー（複数選択）を表示。
  `FileSystem.importROMFiles`（サイズ検証つき）で Documents/MPX68K にコピーし、そのままエミュレータを起動する。
  足りない ROM やファイル名の誤りは、理由を示して選び直せる。シミュレータで取り込み→起動まで確認。

### Phase 3: 折り目対応レイアウト（2026-09-25）

- Xcode 27.1 beta（27A9269, iOS 27.1 SDK）の iPhone Duo シミュレータで動作確認。
  外側（閉）・内側（全開）とも全画面で動作。Device Hub の開閉操作はシミュレータ上でのみ可能（simctl 不可）。
- 画面構成: `GameViewController` を入れ物にし、`ScreenViewController`（SKView をシーンの縦横比で safe area に
  aspect-fit）と `ControlPanelViewController`（仮想パッド・モード切替・トラックパッド、タッチ透過）に分離。
  共有の GameScene は固定サイズのまま。
- iOS 27.1 以降は `UIArrangementViewController` の overlay 配置（primary＝操作パネル、secondary＝画面）。
  閉・全開では画面の上に操作パネルが重なり、半開きでは画面が上／前側、操作パネルが下／後側に分かれる。
  半開きかつマウスモードでは操作パネル側にトラックパッド面を表示。
  SDK 27.0 でもビルドできるよう `#if canImport(UIKit.UIArrangementViewController)` で囲み、
  27.1 未満の実行時は単純な重ね表示にフォールバック。
- 確認済み: ノート PC 持ち（横の折り目）の半開きで、上に X68000 画面・下にトラックパッド。
- 既知: 閉じた状態で上下逆さの縦向きにしてもアプリの向きが変わらない（システムがアプリシーンを
  portraitUpsideDown に回さない。キーボード用シーンだけ回る）。Info.plist には追加済み。OS の仕様とみて現状維持。

### 入力まわりの追加（2026-09-25）

- 仮想パッドの JOY/KEY 切替: KEY では方向パッドがカーソルキー、A/B の代わりに Z・X・C・SPACE（下段）と RETURN（右中央）。
- 縦向きで分割なし（閉・全開）は画面を上寄せ（上・左右 12pt の余白）し、操作系をその下に配置。
- 内側ディスプレイ縦向き（全開・半開き）では X68000 フルキーボード（`X68KeyboardView`）を自動表示。
  F1〜F10 / メイン（JIS）/ SHIFT・CTRL・OPT.1・OPT.2（ラッチ）/ XF1〜5 / 編集・カーソルキー。
  コアに `X68000_Key_DownScancode` / `X68000_Key_UpScancode`（KeyTable を経由しない送出）を追加。
  シミュレータで入力を確認（ユーザー確認）。
- SpriteKit のデバッグ表示（FPS・ノード数）を削除。
- 残り候補: 余白のアートワーク（HIG）、`UIHingeInteraction` の演出、バンドル ID 確定と TestFlight 準備、
  `ios/phase2-boot` を `master` へ統合。

### iPhone Duo の姿勢別レイアウト（2026-10-26、ブランチ `ios/duo-posture`）

- 姿勢の判定は `GameViewController.updateLayoutState` で、arrangement が置いたペインの位置から行う。
  - 上下に分かれた半開き（L 字・ノート PC 持ち）: 画面が上、操作パネルが下
  - 左右に分かれた半開き（本の持ち方）: `isBookPosture`
  - 内側ディスプレイの縦向き（L 字、または全開の縦）: `isUprightInnerDisplay`
- 内側ディスプレイが縦のときは、下半分の中身を上段の切り替え（`InnerPanelPicker`）でキーボード／仮想パッド／トラックパッドから選べる。
  選んだものは `ios_inner_panel` に保存する。以前はキーボード固定で、L 字ではパッドを使えなかった。
- キーボードの上の端にランプ列（`StatusLampStripView`）を出す: FDD0・FDD1 のアクセス（ディスクが入っていると薄く点灯）、
  HD BUSY、キーボード LED（かな・ローマ字・コード入力・CAPS・INS・ひらがな・全角）。
- 本の持ち方では、操作パネル側の上にドライブベイ（`DriveBayView`）を出す。FDD0・FDD1・HDD の各スロットに、
  アクセスランプ、ディスク名、取り出しボタンがあり、スロットをタップするとディスクメニューの該当部分が開く。
- 姿勢が変わったときは、操作パネルをクロスフェードで切り替える。
- コアに追加したもの（macOS の動作は変わらない）:
  - `FDD_ActivityCount[]`（fdd.c、シーク・読み書きのたびに加算）
  - `HDD_ActivityCount`（sasi.c、SASI の読み書きと SCSI のイメージ参照で加算）
  - `MFP_KeyboardLEDs`（mfp.c、UDR へ書かれた $80〜$FF の LED コマンド。ビット 0 が点灯）
  - 取得は `X68000_GetFDDActivity` / `X68000_GetHDDActivity` / `X68000_GetKeyboardLEDs`。
    UI 側は `StatusLampMonitor` が 30 Hz で読み、アクセスの後 0.12 秒ランプを点ける。
- 実機・シミュレータで確認が要るもの: L 字でのランプ列と切り替えの幅（626 pt 前後で収まる想定）、本の持ち方での
  ドライブベイの高さ、キーボード LED のビットの向き（Human68k で CAPS やかなを押して確認）。

