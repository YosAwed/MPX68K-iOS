// Optional integration check using a caller-supplied ROM folder. Never include ROMs here.
// Picks the ROM pair the app would pick (any file names; identified by SHA-1).
#include "../../X68000 Shared/MT32/MT32Bridge.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <dirent.h>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

struct Metrics { double acRMS; double peak; };
static std::vector<double> renderMilliseconds;

static Metrics render(int blocks)
{
    float left[512], right[512];
    double sum = 0, squares = 0, peak = 0;
    for (int block = 0; block < blocks; ++block) {
        const auto start = std::chrono::steady_clock::now();
        if (!X68MT32_Render(left, right, 512)) throw std::runtime_error("render failed");
        renderMilliseconds.push_back(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count());
        for (int frame = 0; frame < 512; ++frame) {
            for (float sample : {left[frame], right[frame]}) {
                if (!std::isfinite(sample)) throw std::runtime_error("nonfinite audio");
                sum += sample;
                squares += double(sample) * sample;
                peak = std::max(peak, std::abs(double(sample)));
            }
        }
    }
    const double count = blocks * 1024.0, mean = sum / count;
    return {std::sqrt(std::max(0.0, squares / count - mean * mean)), peak};
}

// Genuine MT-32 v1.07 first, other MT-32 firmware next, patched BlueRidge and CM-32L last.
static int rank(const std::string &name)
{
    if (name == "ctrl_mt32_1_07") return 3;
    if (name == "ctrl_mt32_bluer") return 1;
    if (name.find("ctrl_mt32_") == 0) return 2;
    return 0;
}

struct ROM { std::string file, name, description; int kind; std::vector<uint8_t> data; };

int main(int argc, char **argv)
{
    try {
        if (argc != 2) throw std::runtime_error("usage: test-rom ROM_FOLDER");
        std::vector<ROM> roms;
        DIR *dir = opendir(argv[1]);
        if (!dir) throw std::runtime_error("cannot open folder");
        while (dirent *entry = readdir(dir)) {
            std::string path = std::string(argv[1]) + "/" + entry->d_name;
            std::ifstream file(path, std::ios::binary | std::ios::ate);
            if (!file) continue;
            const auto size = file.tellg();
            if (size <= 0 || size > 0x100000) continue;
            std::vector<uint8_t> data(static_cast<size_t>(size));
            file.seekg(0);
            if (!file.read(reinterpret_cast<char *>(data.data()), size)) continue;
            char name[64], description[128];
            int kind = X68MT32_IdentifyROM(data.data(), data.size(), name, sizeof name, description, sizeof description);
            if (kind == X68MT32_ROM_UNKNOWN) continue;
            std::printf("found %-45s %-18s %s\n", entry->d_name, name, description);
            roms.push_back({entry->d_name, name, description, kind, std::move(data)});
        }
        closedir(dir);
        const ROM *control = nullptr, *pcm = nullptr;
        for (const ROM &c : roms) {
            if (c.kind != X68MT32_ROM_CONTROL) continue;
            for (const ROM &p : roms) {
                if (p.kind == X68MT32_ROM_PCM && X68MT32_ROMsCompatible(c.name.c_str(), p.name.c_str())) {
                    // Same preference as the app (MT32Synthesizer.preference).
                    bool better = !control || rank(c.name) > rank(control->name)
                        || (rank(c.name) == rank(control->name) && c.name > control->name);
                    if (better) { control = &c; pcm = &p; }
                }
            }
        }
        if (!control) throw std::runtime_error("no compatible control/PCM ROM pair found");
        std::printf("using %s + %s\n", control->description.c_str(), pcm->description.c_str());
        if (!X68MT32_Load(control->data.data(), control->data.size(), pcm->data.data(), pcm->data.size()))
            throw std::runtime_error("load failed");
        if (X68MT32_SampleRate() != 48000) throw std::runtime_error("unexpected sample rate");

        double firstNote = 0;
        for (int pass = 0; pass < 2; ++pass) {
            if (pass && !X68MT32_Reset()) throw std::runtime_error("reset failed");
            render(47); // ~0.5 s
            const auto idle = render(10);
            // MT-32 default: parts 1-8 on MIDI channels 2-9 (channel 1 is unassigned).
            const uint8_t on[] = {0x91, 60, 100}, off[] = {0x81, 60, 0};
            if (!X68MT32_Send(on, sizeof on)) throw std::runtime_error("note-on rejected");
            const auto note = render(47);
            if (!X68MT32_Send(off, sizeof off)) throw std::runtime_error("note-off rejected");
            render(188); // 2 s release + reverb
            const auto tail = render(47);
            std::printf("pass %d: idle AC RMS %.7f, note %.7f, tail %.7f, peak %.7f\n",
                        pass + 1, idle.acRMS, note.acRMS, tail.acRMS, note.peak);
            if (note.acRMS < idle.acRMS * 4 + 0.001 || tail.acRMS > note.acRMS / 4)
                throw std::runtime_error("note-on/off did not produce the expected audio change");
            if (pass && std::abs(firstNote - note.acRMS) > 0.000001)
                throw std::runtime_error("reset did not reproduce note output");
            firstNote = note.acRMS;
        }
        // Running status and a SysEx split across Send calls (MT-32 display message).
        const uint8_t sysex1[] = {0xF0, 0x41, 0x10, 0x16, 0x12, 0x20, 0x00, 0x00};
        const uint8_t sysex2[] = {'M', 'P', 'X', '6', '8', 'K', 0x00, 0xF7};
        const uint8_t chord[] = {0x92, 48, 100, 55, 100, 64, 100};
        if (!X68MT32_Send(sysex1, sizeof sysex1) || !X68MT32_Send(sysex2, sizeof sysex2)
            || !X68MT32_Send(chord, sizeof chord)) throw std::runtime_error("stream input rejected");
        const auto chordMetrics = render(47);
        std::printf("running-status chord AC RMS %.7f\n", chordMetrics.acRMS);
        if (chordMetrics.acRMS < 0.001) throw std::runtime_error("running-status chord silent");
        std::puts("MT-32 real-ROM note-on/off, reset and stream checks passed");

        // Sample placement: a note sent between two partial renders starts at that frame
        // (the host delivers MIDI at its position inside a buffer; no cable delay added).
        if (!X68MT32_Reset()) throw std::runtime_error("reset failed");
        render(47);
        {
            static float left[4800], right[4800];
            const size_t at = 200;
            if (!X68MT32_Render(left, right, at)) throw std::runtime_error("render failed");
            const uint8_t on[] = {0x91, 72, 127};
            X68MT32_Send(on, sizeof on);
            if (!X68MT32_Render(left + at, right + at, 4800 - at)) throw std::runtime_error("render failed");
            size_t onset = 4800;
            for (size_t i = 0; i < 4800; ++i)
                if (std::abs(left[i]) > 1e-4f || std::abs(right[i]) > 1e-4f) { onset = i; break; }
            std::printf("note sent at frame %zu, first output at frame %zu (%.2f ms later)\n",
                        at, onset, (double(onset) - at) / 48.0);
            if (onset < at || onset > at + 96) throw std::runtime_error("note not placed at its frame");
            const uint8_t off[] = {0x81, 72, 0};
            X68MT32_Send(off, sizeof off);
            render(200);
        }

        // Full polyphony load on all parts plus rhythm.
        renderMilliseconds.clear();
        for (uint8_t ch = 1; ch < 10; ++ch)
            for (uint8_t n = 0; n < 4; ++n) {
                const uint8_t on[] = {uint8_t(0x90 | ch), uint8_t(40 + ch * 3 + n * 5), 110};
                X68MT32_Send(on, sizeof on);
            }
        render(500);
        std::sort(renderMilliseconds.begin(), renderMilliseconds.end());
        std::printf("512-frame render (10.7 ms audio): median %.3f ms, p99 %.3f ms, max %.3f ms\n",
                    renderMilliseconds[renderMilliseconds.size() / 2],
                    renderMilliseconds[renderMilliseconds.size() * 99 / 100], renderMilliseconds.back());
        X68MT32_Unload();
    } catch (const std::exception &error) {
        std::fprintf(stderr, "%s\n", error.what());
        return 1;
    }
}
