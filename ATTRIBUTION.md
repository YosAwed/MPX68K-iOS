# Attribution

MPX68K builds on the work of many authors. This file records the
provenance of the third-party code vendored in this repository.

## px68k

- **Location**: `X68000 Shared/px68k/` (hardware emulation: FDC, SASI/SCSI,
  CRTC, ADPCM, MFP, etc.)
- **Upstream**: <https://github.com/hissorii/px68k>
- **Author**: hissorii
- **Lineage**: px68k is a portable port of **WinX68k (WinX68k高速版 /
  "Keropi")** by Kenjo (けろぴー). The Japanese comments throughout the
  hardware emulation sources originate from WinX68k.

## C68K — M68000 CPU emulator

- **Location**: `X68000 Shared/px68k/m68000/c68k/` (built as a static
  library via `c68k/c68k.xcodeproj`)
- **Author**: Copyright 2003–2004 Stephane Dallongeville
- **License**: GNU General Public License, version 2 or later. The license
  notice in the source files states the files are part of **Yabause**, the
  Sega Saturn emulator through which this copy of C68K was distributed.
  Full license text: `LICENSES/GPL-2.0.txt`.

## Debabelizer — M680x0 disassembler (d68k)

- **Location**: `X68000 Shared/px68k/x68k/d68k.c`, `d68k.h`
- **Author**: Copyright 1999 Karl Stenerud
- **License**: Freeware. The license header states the code "may be freely
  used as long as this copyright notice remains unaltered in the source code
  and any binary files containing this code in compiled form."

## fmgen — FM Sound Generator

- **Location**: `X68000 Shared/px68k/fmgen/`
- **Author**: Copyright (C) cisc 1998, 2003
- **Notes**: FM synthesis core used for OPM (YM2151) emulation. The source
  headers credit Tatsuyuki Satoh (fm.c for M.A.M.E.), Hiromitsu Shioya
  (ADPCM-A), DMP-SOFT (OPNB), and KAJA (test program). fmgen is distributed
  under cisc's terms as stated in the upstream distribution.

## win32api compatibility layer / dosio

- **Location**: `X68000 Shared/px68k/win32api/`
- **Author**: Copyright (c) 2003 NONAKA Kimihiro (file I/O layer originating
  from NP2/xkeropi)
- **License**: BSD-style license with advertising clause, as stated in the
  source file headers (e.g. `win32api/dosio.h`).

## MPX68K application layer

- **Location**: `X68000 Shared/*.swift`, `X68000 macOS/`
- **Authors**: GOROman (original iOS port of px68k), YosAwed (macOS port
  and ongoing development), and contributors.
- **Upstream**: <https://github.com/YosAwed/MPX68K>

## Nuked SC-55 — internal MIDI sound module

- **Location**: `X68000 Shared/SC55/core/`
- **Upstream**: https://github.com/nukeykt/Nuked-SC55
- **Revision**: `9c98ab97b8d7b1af841845bbd65c4d2371f33ad0`
- **Author**: Copyright (C) 2021, 2024 nukeykt and upstream contributors.
- **License**: GPL-2.0-or-later, as stated by this pinned revision;
  full text in `X68000 Shared/SC55/LICENSE`.
- **Modifications (2026-09-07)**: headless host API, SDL removal, bounded MIDI and
  rendering, complete reset support. See the component README for details.
- No Roland firmware, wave ROMs, artwork or standalone front-panel assets are included.

## Munt libmt32emu — internal MT-32 sound module

- **Location**: `X68000 Shared/MT32/mt32emu/`
- **Upstream**: https://github.com/munt/munt (`mt32emu/`)
- **Revision**: tag `libmt32emu_2_8_3` (`3b05ec276f9e605af86b0eaef7f5eda43477a31f`)
- **Authors**: Copyright (C) 2003–2009 Dean Beeler, Jerome Fisher; 2011–2026 Dean
  Beeler, Jerome Fisher, Sergey V. Mikayev (see `X68000 Shared/MT32/AUTHORS.txt`).
- **License**: GNU Lesser General Public License, version 2.1 or later; full text in
  `X68000 Shared/MT32/COPYING.LESSER.txt`. It is combined here with the GPL-2.0
  application, which LGPL-2.1 permits.
- **Modifications**: none to the library sources. Only the files needed by the C++
  API are vendored; `config.h` is written by hand in place of the CMake-generated one.
  `X68000 Shared/MT32/MT32Bridge.cpp` is MPX68K's own headless adapter.
- No Roland ROMs are included.
