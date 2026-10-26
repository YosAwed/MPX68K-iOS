# MPX68K for iOS — 開発引き継ぎメモ

最終更新: 2026-10-26（2026-09-25 に Mac mini への移行用に作成。2026-10-26 に自宅の Mac mini で続けるために更新）

詳細な経緯と設計は `docs/IOS_PORT_PLAN.md` を参照。このファイルは「新しい Mac で続きを始める」ための手順と現状のまとめ。

## 1. 新しい Mac でのセットアップ

```bash
git clone https://github.com/YosAwed/MPX68K-iOS.git
cd MPX68K-iOS
git remote add upstream https://github.com/YosAwed/MPX68K.git   # macOS 版
git fetch upstream
git switch ios/module-lcd                                       # 作業中のブランチ（マージ後は master）
python3 tools/generate_ios_project.py                           # iOS プロジェクトを再生成（差分が出なければ OK）
open "MPX68K iOS.xcodeproj"
```

- **Xcode**: 通常ビルドは Xcode 27.0 以降。iPhone Duo（全画面表示・`UIArrangementViewController`・`UIHingeInteraction`）の確認には
  **Xcode 27.1** と **iOS 27.1 シミュレータランタイム** が必要。現在の Mac では `/Applications/Xcode.app` が 27.1（27A9275）なので、
  コマンドラインでは `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` を付ける。ランタイムがなければ
  `xcodebuild -downloadPlatform iOS -buildVersion 27.1`（約 7.9 GB）で入れ、
  `xcrun simctl create "iPhone Duo" com.apple.CoreSimulator.SimDeviceType.iPhone-Duo com.apple.CoreSimulator.SimRuntime.iOS-27-1` で作る。
- **スキーム**: `MPX68K iOS`（iOS）。macOS 版は `X68000.xcodeproj` の `X68000 macOS`（事前に `c68k mac` のビルドが必要）。
- **ROM・ディスク**（リポジトリには絶対に入れない）: `IPLROM.DAT` / `CGROM.DAT` を用意する。git に入らないので、
  Mac を移るときは手で持っていく（置き場所は 6 章）。アプリ初回起動時に「ROM ファイルが必要です」→ ピッカーで取り込める。
  シミュレータに直接置く場合（アプリを一度インストールしてから）:
  ```bash
  C=$(xcrun simctl get_app_container <UDID> NANKIN.MPX68K-iOS data)
  mkdir -p "$C/Documents/MPX68K" && cp IPLROM.DAT CGROM.DAT Human302mod.XDF "$C/Documents/MPX68K/"
  ```
- **内蔵 MIDI 音源（任意）**: 同じ `Documents/MPX68K` に SC-55 の `sc55_*.bin` 5 本、または MT-32 の
  コントロール ROM と PCM ROM（ファイル名は自由。内容の SHA-1 で判定）を置くと、ディスクメニューの MIDI から
  「内蔵 SC-55 / 内蔵 MT-32 / 外部 MIDI」を切り替えられる。以前の版にあった `sim-media/install_to_simulator.sh` は
  リポジトリに無いので、上の `simctl get_app_container` の手順でコピーする。
- **テスト**: `make -C tests/core`（コア単体テスト）、`make -C tests/mt32`（MT-32 ブリッジ、ROM 不要）。
  実 ROM での確認は `make -C tests/mt32 rom ROM_DIR=...`。iOS 用の自動テストはまだ無い。

## 2. リポジトリとブランチの状態

| ブランチ | 内容 | 状態 |
|---|---|---|
| `master` | iOS 版一式（iPhone Duo 対応、フルキーボード、CRT 演出、ディスクメニュー、内蔵 SC-55 / MT-32）、upstream MPX68K 4.5、速度メニュー、iPhone / iPad 向け README | PR #1〜#4 をマージ済み |
| `ios/module-lcd` | ドライブベイに内蔵音源（SC-55 / MT-32）の液晶を出す。コアに液晶の状態を読む API を追加（`IOS_PORT_PLAN.md` の「ドライブベイの音源液晶」） | 2026-10-26 Mac mini で作成。C/C++ のテストと実 ROM での表示内容は確認済み。Xcode のビルドとシミュレータでの見た目は未確認 |
| `ios/duo-posture` | iPhone Duo の姿勢別パネル（L 字のランプ列と下半分の切り替え、本の持ち方のドライブベイ）、HD BUSY・キーボード LED・画面枠の修正、この引き継ぎメモ | PR #5 で `master` にマージ済み。削除してよい |
| `ios/bootstrap`, `ios/phase1-target`, `ios/phase2-boot`, `ios/disk-menu`, `ios/mt32`, `ios/merge-upstream-4.5`, `ios/speed-menu`, `docs/ios-readme` | 過去の段階（すべて `master` に含まれる） | 削除してよい |
| `claude/distracted-gould-ab9344` | `.HDS` が起動しない件の調査メモ（docs のみ） | 中身は `ios/duo-posture` のこのファイルに取り込み済み。削除してよい |

- `origin` = YosAwed/MPX68K-iOS（private）、`upstream` = YosAwed/MPX68K（macOS 版、public）。
- GitHub Actions はリポジトリ設定で無効化済み（private の macOS ランナー課金を避けるため。workflow ファイル自体は upstream と共通なので残す）。
- upstream へ出した修正 PR: YosAwed/MPX68K#30（キー表・ジョイカード A/B・ログ無効化・swift-crypto 削除）はマージ済み。

## 3. 次にやること

1. `ios/module-lcd` を Xcode でビルドし、iPhone Duo シミュレータの本の持ち方で SC-55 / MT-32 の液晶を確認して `master` へマージ。
2. TestFlight 準備: バンドル ID が仮の `NANKIN.MPX68K-iOS`（`tools/generate_ios_project.py` の `PRODUCT_BUNDLE_IDENTIFIER`）。Team は `DQR9HH7KUY`。
3. 実機（iPhone Duo）でのみ確認できる項目:
   - ヒンジ連動の CRT 電源演出（閉じ 50° / 開き 70° のしきい値、速さ）
   - 姿勢変更のクロスフェード（シミュレータは開閉が段階的で確かめにくい）
   - タッチマウスの感度
   - 画面サイズ変更時の重さ（Debug ビルドは c68k 以外が最適化なしで重い。Release での体感も要確認。エミュレーションはメインスレッド）
4. 任意: キー配列・F キー等の macOS 側残課題（`IOS_PORT_PLAN.md` 参照。F キーは macOS 側で意図的に別処理なので対応不要）。

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
- **SCSI イメージ（`.HDS`）**: `~/Downloads/900MSCSIHDD.HDS`（配布 zip の中身そのまま）は「Human.sys が壊れています」で止まるが、
  **イメージ側の問題で、エミュレータの不具合ではない**（2026-10-26 調査）。ルートディレクトリと FAT1 には HUMAN.SYS
  （クラスタ 2〜5、58496 バイト）と COMMAND.X（6〜7）があるのに、データ領域（ファイル先頭から `0x45400`〜`0x5D400`）が全部ゼロで、
  FAT2 も更新されていない。実機でも同じエラーになる状態。SCSI のトレースでは READCAP 512 バイト/ブロック、FAT → ルート →
  `lba=554 imgOff=0x45400` と正しい位置を読んでいる。起動できるのは macOS 版で手を入れて保存した `~/Documents/X68IPLCG/900MHDD.HDS`
  （上のファイルと 1570 か所違う）で、iOS でも Human68k 3.02 が CONFIG.SYS のドライバを組み込んでプロンプトまで起動する。
  フロッピーから起動した Human68k には SCSI ドライバが組み込まれないので、C: は「ドライブ名が無効です」になる（想定どおり）。
- **`scsi.c` のログ**（`-DMPX68K_ENABLE_RUNTIME_FILE_LOGS=1` でビルド）は、出力先が macOS 用の分岐（`MPX68K_HAVE_IOKIT_USB`）の
  中にあるため、iOS ではそのままでは出ない（調べるときは一時的に分岐を外す）。
- **iPhone Duo シミュレータ（Xcode 27.1 の Device Hub）の癖**:
  - 半開きの姿勢では、どのアプリでも内側ディスプレイの上半分をシステムがぼかす（アプリの不具合ではない）。
  - 姿勢変更直後は数秒間ぼかした静止画が出る（アプリの再描画待ち）。
  - 開閉は段階的でヒンジ角度が途中の値を取らないため、CRT 演出は Debug ビルドの画面左上「CRT」ボタンで確認する。
    3 本指タップと ⌘ ショートカットは Device Hub から届かない。
  - `simctl` からアプリを起動するとバックグラウンドのままのことがある（Device Hub でタップして前面へ）。
  - 画面の取得は `xcrun simctl io <UDID> screenshot --display=<UUID>`（`simctl io <UDID> enumerate` で 2007×2853=内側、1398×2034=外側）。
  - 姿勢（閉・L 字・本の持ち方・全開）は Device Hub の GUI でしか変えられない。`simctl` には開閉の操作がなく、
    `devicectl device orientation` も縦横の向きだけ。
  - Claude Code の iOS シミュレータ操作ツールは、2026-10-26（Xcode 27.1 27A9275）の時点で iPhone Duo に接続でき、
    外側・内側どちらのディスプレイもタップと撮影ができた（そのとき表示中のディスプレイが対象。入力の反映は少し遅れる）。
    以前は接続できなかった。
  - ランプの点灯のような短い変化は、`xcrun simctl io <UDID> recordVideo --display=<UUID>` で録画して確かめる
    （`simctl io screenshot` の連写では間に合わない）。
  - Xcode 27.1 の `simctl` を使うと、シミュレータのサービスが 27.1 版に置き換わり、起動中の他のシミュレータは止まる。
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

## 6. Mac を移るときに手で持っていくもの（2026-10-26 時点）

コードとこのメモはすべて origin に push 済み。git に入らない（入れてはいけない）ものは手で持っていく。
いま作業している Mac での置き場所:

| 種類 | 置き場所 |
|---|---|
| ROM | `~/Documents/X68IPLCG/` の `IPLROM.DAT` `CGROM.DAT`（macOS 版の SCSI 用に `SCSIEXROM.DAT`、ほか `IPLROMCO.DAT` `SCSIINROM*.DAT`）。`~/Documents/MPX68K/` にも `IPLROM.DAT` `CGROM.DAT` `SRAM.DAT` |
| 起動ディスク | `~/Downloads/Human302mod.XDF`（Human68k 3.02） |
| SCSI HDD | `~/Documents/X68IPLCG/900MHDD.HDS`（起動できる方、約 900 MB）。`~/Downloads/900MSCSIHDD.HDS` は壊れているので持っていかなくてよい |
| SASI HDD | `~/Downloads/HDD-MDX.HDF`（約 40 MB、MXDRV・MusTool 入り） |
| テスト用 | `~/Documents/crtmodetest.xdf`（`tools/crt-mode-test/` からも作れる） |
| SC-55 | `~/Downloads/Roland SC-55 v1.21/sc55_*.bin`（5 本） |

Mac mini 側では次の順に用意する:

1. 1 章の手順で clone して `ios/duo-posture` に切り替える（PR #5 がマージされていれば `master`）。
2. Xcode 27.1 と iOS 27.1 シミュレータランタイムを入れ、iPhone Duo シミュレータを作る（1 章の「Xcode」）。
3. `MPX68K iOS` スキームをビルドしてシミュレータに入れ、上の ROM・ディスクを `Documents/MPX68K` にコピーする（1 章の「ROM・ディスク」）。
4. 動作の確かめ方は 4 章の「iPhone Duo シミュレータの癖」と `IOS_PORT_PLAN.md` の「iPhone Duo の姿勢別レイアウト」の動作確認を参照。
