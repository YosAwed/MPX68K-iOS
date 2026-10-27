# MPX68K for iOS

English | [日本語](README.ja.md)

A Sharp X68000 emulator for **iPhone and iPad**. MPX68K combines the px68k emulation core with a native iOS interface built with UIKit, SpriteKit, and Swift.

## Features

- X68000 emulation powered by the px68k core and the C68K M68000 CPU core.
- Floppy disk support for `.dim`, `.xdf`, `.2hd`, `.d88`, and `.hdm` images, with two floppy drives.
- Hard disk image support for `.hdf` and `.hds`.
- A disk library for images in the app’s Documents folder, plus import from the Files app or another file provider.
- Touch controls: a virtual 8-way joystick with A/B buttons, a trackpad-style mouse, and an on-screen X68000 keyboard.
- Hardware keyboard and compatible external game controller support.
- FM and ADPCM audio. Optional internal SC-55 or MT-32/CM-32L MIDI playback is available when you provide the required ROM set; external MIDI is also supported.
- Screen and controls that adapt to iPhone and iPad orientations and available display space.
- CPU clock selection (1–50 MHz, 24 MHz by default) and Turbo / No-Wait speed modes from the disk menu.
- Optional CYBER STICK (analog mode) emulation on joystick 1, selectable from the disk menu.

### iPhone Duo

On iPhone Duo (iOS 27.1 or later), the layout follows how the device is held:

- **Closed or fully open:** full-screen picture with the touch controls on top.
- **L-shape / laptop posture:** the X68000 screen on the upper half and, on the lower half, a choice of the X68000 keyboard, the virtual pad, the trackpad, or a sound monitor. A lamp strip above the keyboard shows FDD0/FDD1 access, HD BUSY, and the keyboard LEDs (kana, romaji, code input, CAPS, INS, hiragana, zenkaku).
- **Book posture:** one side shows the screen; the other shows a drive bay with both floppy drives and the hard disk (access lamps, disk names, eject buttons; tap a slot to open its disk menu). Below the drives, the LCD of the internal SC-55 or MT-32 appears while a game sends MIDI, and a compact OPM monitor otherwise.
- **Hinge:** folding the display below about 50° plays a CRT power-off effect, and opening it again turns the picture back on. With CYBER STICK selected, the hinge angle drives the throttle (80° or less = fully back, 170° or more = fully forward).

### Sound monitor

An MMDSP-style monitor of the OPM (YM2151) and ADPCM: for each of the eight FM channels it shows the note, a 7-octave keyboard, a level meter with peak hold, the pan, and the algorithm (`NOIS` when channel 8 plays noise), plus the ADPCM playback state, LFO, and ADPCM sample rate. Levels are estimated from the register writes, since the FM engine does not expose its internal state.

## Requirements

- iPhone or iPad running **iOS/iPadOS 17.0 or later**. The iPhone Duo posture layouts and hinge features need **iOS 27.1 or later**.
- An arm64 iPhone or iPad.
- To build from source: a Mac with **Xcode 27.1** (see [Build from source](#build-from-source)).
- Original X68000 system ROM files. They are not included in this repository.

## Set up ROMs and disk images

The emulator requires these X68000 system ROM files:

| File | Purpose |
| --- | --- |
| `IPLROM.DAT` | X68000 system IPL ROM |
| `CGROM.DAT` | Character generator ROM |

On first launch, MPX68K prompts you to select any missing ROM files. You can also copy files in the Files app to:

```text
On My iPhone (or On My iPad)
└── MPX68K for iOS
    └── MPX68K
```

Put disk images in the same `MPX68K` folder. Open the in-app disk menu to select an image, or choose **Other Locations…** to import one from Files or another file provider. The app recognizes floppy and hard disk images by their extensions.

ROM files are copyrighted. Obtain and use them only from sources you are authorized to use. Do not add ROM images to this repository or distribute them with the app.

### Optional MIDI sound modules

To use an internal sound module, provide its ROM files in the same `MPX68K` folder and restart the app:

- **SC-55:** the five-file set `sc55_rom1.bin`, `sc55_rom2.bin`, `sc55_waverom1.bin`, `sc55_waverom2.bin`, and `sc55_waverom3.bin`.
- **MT-32 / CM-32L:** the matching control ROM and PCM ROM.

MT-32 ROMs are recognized by their contents, so the file names do not matter. The MIDI menu lets you choose External MIDI, Internal SC-55, or Internal MT-32. These ROM files are not included.

### Main memory

As on real hardware, the X68000 starts with the main memory size stored in SRAM (1 MB until changed). Programs such as MXDRV may report that memory is insufficient; set a larger size with `SWITCH.X` and reset.

## Controls

- **Virtual joystick:** 8-way movement and A/B buttons. The D-pad can also be configured to send cursor keys.
- **Touch mouse:** drag one finger to move the pointer, tap for the left button, tap with two fingers for the right button, and press and drag to hold the left button. Hover input is available with supported iPad pointing devices.
- **On-screen keyboard:** a JIS-layout X68000 keyboard with function, editing, cursor, and modifier keys.
- **Hardware keyboard and game controller:** connect a compatible device and use it as an alternative to touch controls.
- **CYBER STICK:** the stick and triggers A/B come from the virtual pad or a game controller; on iPhone Duo the throttle follows the hinge, and a THROTTLE indicator appears briefly when it changes. Other devices keep the throttle centered.

## Build from source

1. Clone this repository:

   ```bash
   git clone https://github.com/YosAwed/MPX68K-iOS.git
   cd MPX68K-iOS
   ```

2. Open `MPX68K iOS.xcodeproj` in **Xcode 27.1**.
3. Select the **MPX68K iOS** scheme and an iPhone or iPad simulator, or a connected device.
4. Build and run. Installing on a physical device may require signing with your Apple Developer account.

Build only with Xcode 27.1 and the iOS 27.1 SDK. The iOS 27.0 SDK builds without errors but leaves out the iPhone Duo arrangement and hinge code, so the app stays full screen when the device is partially folded. If `xcode-select` points at another Xcode, set `DEVELOPER_DIR` on the command line:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project "MPX68K iOS.xcodeproj" -scheme "MPX68K iOS" -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build
```

The project file is generated by `tools/generate_ios_project.py`; rerun it after adding or removing source files.

For the iPhone Duo simulator, install the iOS 27.1 simulator runtime and create an "iPhone Duo" device. Debug builds running in the simulator show a HINGE slider and a CRT button in the top-left corner to stand in for the hinge. See [docs/IOS_HANDOFF.md](docs/IOS_HANDOFF.md) for setup details and simulator quirks.

## Core tests

The host-side emulator core tests can be run without Xcode or ROM files:

```bash
make -C tests/core
make -C tests/mt32
make -C tests/sc55
```

`tests/mt32` and `tests/sc55` also have a `rom` target for checks with real ROM files (for example `make -C tests/mt32 rom ROM_DIR=...`).

## Project structure

- `MPX68K iOS.xcodeproj` — iPhone and iPad app project.
- `X68000 iOS/` — iOS app lifecycle, screen layout, touch controls, disk library, iPhone Duo posture panels (`DuoPanels.swift`), and the sound monitor (`SoundMonitorView.swift`).
- `X68000 Shared/` — shared Swift interface and emulator code.
- `X68000 Shared/px68k/` — X68000 hardware emulation core.
- `c68k/` — M68000 CPU core.
- `tests/` — host-side tests for the emulator core and the internal MIDI modules.
- `tools/` — project generator and test-disk sources (CPU speed, CRT modes, CYBER STICK, and more).
- `docs/` — iOS port design notes ([IOS_PORT_PLAN.md](docs/IOS_PORT_PLAN.md)) and development handoff ([IOS_HANDOFF.md](docs/IOS_HANDOFF.md)).

## Credits and licenses

MPX68K is based on the px68k emulator and incorporates other upstream components. See [ATTRIBUTION.md](ATTRIBUTION.md) for credits and [LICENSE](LICENSE) and [LICENSES](LICENSES/) for license information.
