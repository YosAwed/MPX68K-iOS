// ROM-free checks of the MT-32 bridge. Never add Roland ROMs to the repository.
#include "../../X68000 Shared/MT32/MT32Bridge.h"
#include <cstdio>
#include <cstring>
#include <vector>

#define CHECK(cond) do { if (!(cond)) { std::fprintf(stderr, "FAILED: %s (line %d)\n", #cond, __LINE__); return 1; } } while (0)

int main()
{
    char name[64], description[128];
    std::vector<uint8_t> junk(65536);
    for (size_t i = 0; i < junk.size(); ++i) junk[i] = uint8_t(i * 37 + 11);
    std::vector<uint8_t> pcm(524288, 0x5A);

    // Unknown contents (right sizes, wrong hash) are rejected and leave the names empty.
    std::strcpy(name, "stale");
    CHECK(X68MT32_IdentifyROM(junk.data(), junk.size(), name, sizeof name, description, sizeof description) == X68MT32_ROM_UNKNOWN);
    CHECK(name[0] == '\0' && description[0] == '\0');
    CHECK(X68MT32_IdentifyROM(nullptr, 0, name, sizeof name, nullptr, 0) == X68MT32_ROM_UNKNOWN);

    // Pairing uses Munt's machine table.
    CHECK(X68MT32_ROMsCompatible("ctrl_mt32_1_07", "pcm_mt32"));
    CHECK(X68MT32_ROMsCompatible("ctrl_cm32l_1_02", "pcm_cm32l"));
    CHECK(!X68MT32_ROMsCompatible("ctrl_cm32l_1_02", "pcm_nonexistent"));
    CHECK(!X68MT32_ROMsCompatible("pcm_mt32", "ctrl_mt32_1_07"));
    CHECK(!X68MT32_ROMsCompatible(nullptr, "pcm_mt32"));

    // Nothing works before a successful load, and a bad load keeps it that way.
    float left[512], right[512];
    const uint8_t note[] = {0x91, 60, 100};
    CHECK(!X68MT32_Render(left, right, 512));
    CHECK(!X68MT32_Send(note, sizeof note));
    CHECK(!X68MT32_Reset());
    CHECK(X68MT32_SampleRate() == 0);
    CHECK(!X68MT32_Load(junk.data(), junk.size(), pcm.data(), pcm.size()));
    CHECK(!X68MT32_Render(left, right, 512));
    X68MT32_Unload();
    X68MT32_Unload();
    std::puts("MT-32 bridge checks passed (no ROMs)");
    return 0;
}
