#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
// Single instance. All calls must use the same serial worker queue.
bool X68SC55_Load(const uint8_t *program1, size_t size1,
                 const uint8_t *program2, size_t size2,
                 const uint8_t *wave1, const uint8_t *wave2,
                 const uint8_t *wave3, size_t waveSize);
void X68SC55_Reset(void);
bool X68SC55_Send(const uint8_t *bytes, size_t count);
bool X68SC55_Render(float *left, float *right, size_t frames);

// The emulated LCD (HD44780-type controller) as of the last render or reset; may be
// called from any thread. ddram: 80 character codes (line 1 at 0, line 2 at 40);
// cgram: 8 user glyphs of 8 rows. False before the first load.
bool X68SC55_GetLCD(uint8_t *ddram, uint8_t *cgram, bool *enabled);
// 5x8 dot rows of a character (bit 4 = leftmost dot); codes below 16 are user glyphs
// taken from cgram (may be NULL). Stateless; may be called from any thread.
void X68SC55_LCDGlyph(uint8_t code, const uint8_t *cgram, uint8_t *rows);
#ifdef __cplusplus
}
#endif
