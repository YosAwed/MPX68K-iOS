#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
/// ROM kinds reported by X68MT32_IdentifyROM.
enum { X68MT32_ROM_UNKNOWN = 0, X68MT32_ROM_CONTROL = 1, X68MT32_ROM_PCM = 2 };

// Stateless helpers; may be called from any thread.
// Identifies a complete (unsplit) control or PCM ROM image by size and SHA-1.
// On success copies the Munt short name (e.g. "ctrl_mt32_1_07", "pcm_mt32") and the
// human-readable description into the given buffers (always NUL-terminated).
int X68MT32_IdentifyROM(const uint8_t *data, size_t size,
                        char *shortName, size_t shortNameCapacity,
                        char *description, size_t descriptionCapacity);
// True if some supported machine (MT-32 / CM-32L / CM-32LN) uses both ROMs.
bool X68MT32_ROMsCompatible(const char *controlShortName, const char *pcmShortName);

// Single instance. All calls below must use the same serial worker queue.
// The ROM contents are copied. Fails for unknown or incompatible ROMs.
bool X68MT32_Load(const uint8_t *control, size_t controlSize,
                  const uint8_t *pcm, size_t pcmSize);
void X68MT32_Unload(void);
// Output sample rate of the loaded synth (48000 Hz), 0 when not loaded.
uint32_t X68MT32_SampleRate(void);
// Power-cycles the emulated unit with the same ROMs.
bool X68MT32_Reset(void);
// Raw MIDI byte stream (running status and SysEx may span calls).
bool X68MT32_Send(const uint8_t *bytes, size_t count);
bool X68MT32_Render(float *left, float *right, size_t frames);

// The emulated 20-character LCD (text gets 21 bytes, NUL-terminated) and the MIDI MESSAGE
// LED as of the last render; may be called from any thread. False when no synth is loaded.
bool X68MT32_GetDisplay(char *text, bool *midiMessageLED);
#ifdef __cplusplus
}
#endif
