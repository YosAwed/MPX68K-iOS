# Embedded Munt libmt32emu (MT-32)

Upstream: https://github.com/munt/munt (directory `mt32emu/`)
Pinned tag: `libmt32emu_2_8_3` (commit 3b05ec276f9e605af86b0eaef7f5eda43477a31f)
License: LGPL-2.1-or-later; see COPYING.LESSER.txt and AUTHORS.txt. Copyright headers are retained.

`mt32emu/` holds the unmodified library sources needed by the C++ API (the
`libmt32emu_CPP_SOURCES` list minus `SampleRateConverter.cpp`, which needs the
optional resampler). Not vendored: the C interface, version tagging, resampler
helpers (`srchelper/`) and tests. `mt32emu/config.h` replaces the CMake-generated
file (static build, C++ API only, no version tagging). No ROMs are included; never
add firmware to this directory.

`MT32Bridge.cpp` / `MT32Bridge.h` are MPX68K's headless adapter:

- ROM identification by size + SHA-1 through Munt's catalogue (`X68MT32_IdentifyROM`),
  complete images only; pairing through Munt's machine table (`X68MT32_ROMsCompatible`).
- A single synth opened with `AnalogOutputMode_ACCURATE` (48 kHz stereo float).
- A raw MIDI byte stream parsed by `DefaultMidiStreamParser`, so running status and
  SysEx may be split across calls. The event queue holds 65536 events: one render
  period's input (at most 64 KiB, at least 2 bytes per queued message) cannot overflow.
- Reset power-cycles the unit by reopening the synth with the same ROM images.
- Debug and LCD messages are swallowed.

The bridge is single-instance and not thread-safe: `MT32Synthesizer` serializes all
calls on its worker queue. Audio uses three 384-frame buffers (8 ms each, 24 ms,
like the SC-55), and MIDI deadlines are checked before every buffer. Library files are
built with -O2 in Debug as well as Release.

Validation: `make -C tests/mt32` checks identification, pairing and failure paths
without ROMs (address/undefined sanitizers). With your own ROMs:

```
make -C tests/mt32 rom ROM_DIR='/path/to/your/MT-32 ROM folder'
```

This picks the same pair as the app, checks note-on/off, reset reproducibility,
running status and a split SysEx, that a note sent between two partial renders
starts at that frame (measured: 2 frames, 0.04 ms), and measures 512-frame
rendering under a 36-note load. Munt's MIDI cable delay emulation is disabled:
the host already times each message by when its last byte left the emulated board. Real-ROM run (2026-09-26, MT-32 v1.07 + MT-32 PCM, Linux VM on the
Mac mini): passed; render median 0.14 ms per 10.7 ms of audio.
