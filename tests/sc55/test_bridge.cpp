// Synthetic firmware only: no Roland ROM files are needed or included.
#include "../../X68000 Shared/SC55/SC55Bridge.h"
#include "../../X68000 Shared/SC55/core/lcd.h"
#include <array>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

// The LCD as the firmware leaves it: written through the controller, visible to the
// host only after the next render, cleared by a reset.
static void checkLCD()
{
    uint8_t dd[80], cg[64];
    bool enabled = false;
    assert(X68SC55_GetLCD(dd, cg, &enabled));
    assert(enabled);
    for (uint8_t c : dd) assert(c == ' ');
    LCD_Write(0, 0x38); // 8-bit, two lines
    LCD_Write(0, 0x06); // increment
    LCD_Write(0, 0x80); // line 1, column 0
    LCD_Write(1, 'A');
    LCD_Write(1, 'B');
    LCD_Write(0, 0xC0 | 2); // line 2, column 2
    LCD_Write(1, 0x00);     // user glyph 0
    LCD_Write(0, 0x40 | 8); // CGRAM: glyph 1
    const uint8_t bars[8] = {0x10, 0x18, 0x1c, 0x1e, 0x1f, 0x1f, 0x1f, 0xff};
    for (uint8_t row : bars) LCD_Write(1, row);
    assert(X68SC55_GetLCD(dd, cg, nullptr) && dd[0] == ' ');
    float left[16], right[16];
    assert(X68SC55_Render(left, right, 16));
    assert(X68SC55_GetLCD(dd, cg, &enabled));
    assert(dd[0] == 'A' && dd[1] == 'B' && dd[2] == ' ' && dd[42] == 0x00);
    for (int row = 0; row < 8; ++row) assert(cg[8 + row] == (bars[row] & 0x1f));

    uint8_t glyph[8];
    const uint8_t letterA[8] = {0x0e, 0x11, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x00};
    X68SC55_LCDGlyph('A', nullptr, glyph);
    assert(memcmp(glyph, letterA, 8) == 0);
    X68SC55_LCDGlyph(9, cg, glyph); // codes 8-15 repeat the 8 user glyphs
    assert(memcmp(glyph, cg + 8, 8) == 0);
    X68SC55_LCDGlyph(1, nullptr, glyph);
    for (uint8_t row : glyph) assert(row == 0);

    X68SC55_Reset();
    assert(X68SC55_GetLCD(dd, cg, nullptr));
    for (uint8_t c : dd) assert(c == ' ');
    for (uint8_t row : cg) assert(row == 0);
}

int main()
{
    std::array<float, 1024> left{}, right{}, first{};
    assert(!X68SC55_GetLCD(nullptr, nullptr, nullptr));
    assert(!X68SC55_Render(left.data(), right.data(), left.size()));
    assert(!X68SC55_Render(nullptr, right.data(), left.size()));
    std::vector<uint8_t> rom1(0x8000), rom2(0x40000), wave(0x100000);
    // Reset vector 0x100, followed by H8 SLEEP.
    rom1[2] = 1;
    rom1[0x100] = 0x1a;
    auto load = [&](size_t programSize, size_t waveSize) {
        return X68SC55_Load(rom1.data(), programSize, rom2.data(), rom2.size(),
                           wave.data(), wave.data(), wave.data(), waveSize);
    };
    assert(!load(0x7fff, wave.size()));
    assert(!load(rom1.size(), 0xfffff));
    assert(load(rom1.size(), wave.size()));
    checkLCD();
    assert(X68SC55_Render(left.data(), right.data(), left.size()));
    first = left;
    for (auto sample : left) assert(std::isfinite(sample) && std::abs(sample) <= 1);
    // Reset must clear every timing domain and reproduce the same first samples.
    for (int n = 0; n < 5; ++n) {
        assert(X68SC55_Render(left.data(), right.data(), left.size()));
        X68SC55_Reset();
        assert(X68SC55_Render(left.data(), right.data(), left.size()));
        assert(left == first);
    }
    // A full UART must reject input instead of wrapping and overwriting it.
    std::vector<uint8_t> midi(8191, 0xfe);
    assert(X68SC55_Send(midi.data(), midi.size()));
    assert(!X68SC55_Send(midi.data(), 1));
    X68SC55_Reset();
    assert(X68SC55_Send(midi.data(), 1));
    assert(!X68SC55_Send(nullptr, 1));
    assert(load(rom1.size(), wave.size()));
    assert(X68SC55_Send(midi.data(), midi.size()));
    puts("SC-55 bridge checks passed");
}
