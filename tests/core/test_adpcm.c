/* MSM6258 (x68k/adpcm.c): PLAY ST resets the decoder (output to the centre,
 * step size to the minimum) only when starting from a stopped state. A
 * PLAY ST written while already playing leaves the decoder state untouched.
 * This matches MAME/libvgm's okim6258, whose COMMAND_PLAY resets the ADPCM
 * parameters only when STATUS_PLAYING was clear, and the macOS core.
 * PCM8A re-issues PLAY ST at sample starts without SP; resetting there made
 * the decoder jump to the centre mid-stream, audible as clicks (RAY01C.MDX
 * via MMDSP + PCM8A, verified on device). The mixer's DC-cut filter stays.
 */
#include <stdio.h>
#include <string.h>
#include "common.h"
#include "prop.h"
#include "adpcm.h"
#include "dmac.h"

Win68Conf Config;
dmac_ch DMA[4];
int FASTCALL DMA_Exec(int ch) { (void)ch; return 0; }

static int g_failures = 0;
#define CHECK_EQ(actual, expected, name) do { \
    long long _a = (long long)(actual), _e = (long long)(expected); \
    if (_a == _e) printf("PASS: %s\n", name); \
    else { printf("FAIL: %s: got %lld, want %lld (%s:%d)\n", name, _a, _e, __FILE__, __LINE__); g_failures++; } \
} while (0)

static ADPCMMonitorState state(void)
{
    ADPCMMonitorState s;
    memset(&s, 0, sizeof s);
    ADPCM_GetMonitorState(&s);
    return s;
}

int main(void)
{
    int i;
    ADPCMMonitorState s, fresh, before;

    ADPCM_Init(44100);
    ADPCM_Write(0xe92001, 0x02);              /* PLAY ST */
    s = state();
    CHECK_EQ(s.playing, 1, "PLAY ST starts playback");
    CHECK_EQ(s.output, 0, "playback starts at the centre");
    CHECK_EQ(s.step, 0, "playback starts at the minimum step");

    /* One byte from a fresh start: the reference for the restart check. */
    ADPCM_Write(0xe92003, 0x77);
    fresh = state();

    /* Rising nibbles (sign 0, magnitude 7): the output and the step grow. */
    for (i = 0; i < 15; i++) ADPCM_Write(0xe92003, 0x77);
    s = state();
    CHECK_EQ(s.output > 0, 1, "decoding moved the output");
    CHECK_EQ(s.step > 0, 1, "decoding raised the step size");

    /* PLAY ST again without SP, as PCM8A does at sample starts. The
     * decoder state must be left untouched (no reset while playing). */
    before = state();
    ADPCM_Write(0xe92001, 0x02);
    s = state();
    CHECK_EQ(s.playing, 1, "still playing after PLAY ST while playing");
    CHECK_EQ(s.output, before.output, "PLAY ST while playing keeps the output");
    CHECK_EQ(s.step, before.step, "PLAY ST while playing keeps the step size");

    /* SP + PLAY ST is a real restart: the state resets on the
     * stopped-to-playing transition, and the same data decodes exactly
     * as it did from a fresh start. */
    ADPCM_Write(0xe92001, 0x01);              /* SP */
    ADPCM_Write(0xe92001, 0x02);              /* PLAY ST */
    s = state();
    CHECK_EQ(s.output, 0, "PLAY ST after SP returns the output to the centre");
    CHECK_EQ(s.step, 0, "PLAY ST after SP returns the step to the minimum");
    ADPCM_Write(0xe92003, 0x77);
    s = state();
    CHECK_EQ(s.output, fresh.output, "restart decodes like a fresh start (output)");
    CHECK_EQ(s.step, fresh.step, "restart decodes like a fresh start (step)");

    if (g_failures) {
        printf("%d test(s) FAILED\n", g_failures);
        return 1;
    }
    printf("all tests passed\n");
    return 0;
}
