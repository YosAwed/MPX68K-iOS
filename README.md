# MPX68K for iOS

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

## Requirements

- iPhone or iPad running **iOS/iPadOS 17.0 or later**.
- An arm64 iPhone or iPad.
- To build from source: a Mac with **Xcode 27.0 or later**.
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

The MIDI menu lets you choose External MIDI, Internal SC-55, or Internal MT-32. These ROM files are not included.

## Controls

- **Virtual joystick:** 8-way movement and A/B buttons. The D-pad can also be configured to send cursor keys.
- **Touch mouse:** drag one finger to move the pointer, tap for the left button, tap with two fingers for the right button, and press and drag to hold the left button. Hover input is available with supported iPad pointing devices.
- **On-screen keyboard:** a JIS-layout X68000 keyboard with function, editing, cursor, and modifier keys.
- **Hardware keyboard and game controller:** connect a compatible device and use it as an alternative to touch controls.

## Build from source

1. Clone this repository:

   ```bash
   git clone https://github.com/YosAwed/MPX68K-iOS.git
   cd MPX68K-iOS
   ```

2. Open `MPX68K iOS.xcodeproj` in Xcode.
3. Select the **MPX68K iOS** scheme and an iPhone or iPad simulator, or a connected device.
4. Build and run. Installing on a physical device may require signing with your Apple Developer account.

## Core tests

The host-side emulator core tests can be run without Xcode or ROM files:

```bash
make -C tests/core
make -C tests/mt32
```

## Project structure

- `MPX68K iOS.xcodeproj` — iPhone and iPad app project.
- `X68000 iOS/` — iOS app lifecycle, screen layout, touch controls, and disk library.
- `X68000 Shared/` — shared Swift interface and emulator code.
- `X68000 Shared/px68k/` — X68000 hardware emulation core.
- `c68k/` — M68000 CPU core.

## Credits and licenses

MPX68K is based on the px68k emulator and incorporates other upstream components. See [ATTRIBUTION.md](ATTRIBUTION.md) for credits and [LICENSE](LICENSE) and [LICENSES](LICENSES/) for license information.
