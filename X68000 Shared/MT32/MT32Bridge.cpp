// Headless host API for the embedded Munt mt32emu library (LGPL-2.1-or-later).
// This file is part of MPX68K; see ../../ATTRIBUTION.md.

#include "MT32Bridge.h"

#include <cstdarg>
#include <cstring>
#include <mutex>
#include <vector>

#include "mt32emu/File.h"
#include "mt32emu/MidiStreamParser.h"
#include "mt32emu/ROMInfo.h"
#include "mt32emu/Synth.h"

using namespace MT32Emu;

namespace {

class QuietReportHandler : public ReportHandler {
public:
    bool overflowed = false;
    void printDebug(const char *, va_list) override {}
    void showLCDMessage(const char *) override {}
    bool onMIDIQueueOverflow() override {
        overflowed = true;
        return false; // drop the event
    }
};

void copyString(char *dst, size_t capacity, const char *src) {
    if (dst == nullptr || capacity == 0) return;
    std::strncpy(dst, src != nullptr ? src : "", capacity - 1);
    dst[capacity - 1] = '\0';
}

const ROMInfo *identify(const uint8_t *data, size_t size) {
    if (data == nullptr || size == 0) return nullptr;
    ArrayFile file(data, size);
    // Only complete images: split (Mux/half) dumps would need pairing first.
    return ROMInfo::getROMInfo(&file, ROMInfo::getFullROMInfos());
}

// The emulated LCD and MIDI MESSAGE LED, published after each render for the UI thread.
struct PublishedDisplay {
    std::mutex mutex;
    char text[21] = {};
    bool midiMessageLED = false;
    bool valid = false;

    void publish(const Synth *synth) {
        char current[21] = {};
        bool led = false;
        if (synth != nullptr) led = synth->getDisplayState(current);
        std::lock_guard<std::mutex> lock(mutex);
        std::memcpy(text, current, sizeof(text));
        text[sizeof(text) - 1] = '\0';
        midiMessageLED = led;
        valid = synth != nullptr;
    }
};

PublishedDisplay publishedDisplay;

// Queue sized so that one render period can never overflow: the host enqueues at most
// 64 KiB of MIDI per render and every queued (non-realtime) message is at least 2 bytes.
const Bit32u kMIDIQueueSize = 65536;

struct Instance {
    std::vector<Bit8u> controlData;
    std::vector<Bit8u> pcmData;
    ArrayFile *controlFile = nullptr;
    ArrayFile *pcmFile = nullptr;
    const ROMImage *controlImage = nullptr;
    const ROMImage *pcmImage = nullptr;
    QuietReportHandler report;
    Synth *synth = nullptr;
    DefaultMidiStreamParser *parser = nullptr;
    std::vector<float> interleaved;

    void closeSynth() {
        publishedDisplay.publish(nullptr);
        delete parser;
        parser = nullptr;
        if (synth != nullptr) {
            synth->close();
            delete synth;
            synth = nullptr;
        }
    }

    bool openSynth() {
        closeSynth();
        if (controlImage == nullptr || pcmImage == nullptr) return false;
        synth = new Synth(&report);
        if (!synth->open(*controlImage, *pcmImage, AnalogOutputMode_ACCURATE)) {
            delete synth;
            synth = nullptr;
            return false;
        }
        synth->setMIDIEventQueueSize(kMIDIQueueSize);
        // The host already delivers each message when its last byte left the emulated
        // MIDI board at 31.25 kbaud; Munt's own cable-delay emulation would add it twice.
        synth->setMIDIDelayMode(MIDIDelayMode_IMMEDIATE);
        parser = new DefaultMidiStreamParser(*synth);
        report.overflowed = false;
        publishedDisplay.publish(synth);
        return true;
    }

    void unload() {
        closeSynth();
        if (controlImage != nullptr) ROMImage::freeROMImage(controlImage);
        if (pcmImage != nullptr) ROMImage::freeROMImage(pcmImage);
        controlImage = pcmImage = nullptr;
        delete controlFile;
        delete pcmFile;
        controlFile = pcmFile = nullptr;
        controlData.clear();
        pcmData.clear();
    }
};

Instance instance;

} // namespace

extern "C" int X68MT32_IdentifyROM(const uint8_t *data, size_t size,
                                   char *shortName, size_t shortNameCapacity,
                                   char *description, size_t descriptionCapacity) {
    copyString(shortName, shortNameCapacity, "");
    copyString(description, descriptionCapacity, "");
    const ROMInfo *info = identify(data, size);
    if (info == nullptr || info->pairType != ROMInfo::Full) return X68MT32_ROM_UNKNOWN;
    int kind;
    switch (info->type) {
    case ROMInfo::Control: kind = X68MT32_ROM_CONTROL; break;
    case ROMInfo::PCM: kind = X68MT32_ROM_PCM; break;
    default: return X68MT32_ROM_UNKNOWN;
    }
    copyString(shortName, shortNameCapacity, info->shortName);
    copyString(description, descriptionCapacity, info->description);
    return kind;
}

extern "C" bool X68MT32_ROMsCompatible(const char *controlShortName, const char *pcmShortName) {
    if (controlShortName == nullptr || pcmShortName == nullptr) return false;
    const MachineConfiguration * const *machines = MachineConfiguration::getAllMachineConfigurations();
    for (; *machines != nullptr; machines++) {
        bool hasControl = false, hasPCM = false;
        for (const ROMInfo * const *rom = (*machines)->getCompatibleROMInfos(); *rom != nullptr; rom++) {
            if ((*rom)->pairType != ROMInfo::Full) continue;
            if ((*rom)->type == ROMInfo::Control && std::strcmp((*rom)->shortName, controlShortName) == 0) hasControl = true;
            if ((*rom)->type == ROMInfo::PCM && std::strcmp((*rom)->shortName, pcmShortName) == 0) hasPCM = true;
        }
        if (hasControl && hasPCM) return true;
    }
    return false;
}

extern "C" bool X68MT32_Load(const uint8_t *control, size_t controlSize,
                             const uint8_t *pcm, size_t pcmSize) {
    instance.unload();
    const ROMInfo *controlInfo = identify(control, controlSize);
    const ROMInfo *pcmInfo = identify(pcm, pcmSize);
    if (controlInfo == nullptr || controlInfo->type != ROMInfo::Control
        || pcmInfo == nullptr || pcmInfo->type != ROMInfo::PCM
        || !X68MT32_ROMsCompatible(controlInfo->shortName, pcmInfo->shortName)) {
        return false;
    }
    instance.controlData.assign(control, control + controlSize);
    instance.pcmData.assign(pcm, pcm + pcmSize);
    instance.controlFile = new ArrayFile(instance.controlData.data(), instance.controlData.size());
    instance.pcmFile = new ArrayFile(instance.pcmData.data(), instance.pcmData.size());
    const ROMInfo * const *full = ROMInfo::getFullROMInfos();
    instance.controlImage = ROMImage::makeROMImage(instance.controlFile, full);
    instance.pcmImage = ROMImage::makeROMImage(instance.pcmFile, full);
    if (!instance.openSynth()) {
        instance.unload();
        return false;
    }
    return true;
}

extern "C" void X68MT32_Unload(void) { instance.unload(); }

extern "C" uint32_t X68MT32_SampleRate(void) {
    return instance.synth != nullptr ? instance.synth->getStereoOutputSampleRate() : 0;
}

extern "C" bool X68MT32_Reset(void) {
    if (instance.synth == nullptr) return false;
    return instance.openSynth();
}

extern "C" bool X68MT32_Send(const uint8_t *bytes, size_t count) {
    if (instance.parser == nullptr) return false;
    if (bytes == nullptr || count == 0) return true;
    instance.report.overflowed = false;
    while (count > 0) {
        Bit32u chunk = count > 0x10000 ? 0x10000 : static_cast<Bit32u>(count);
        instance.parser->parseStream(bytes, chunk);
        bytes += chunk;
        count -= chunk;
    }
    return !instance.report.overflowed;
}

extern "C" bool X68MT32_Render(float *left, float *right, size_t frames) {
    if (instance.synth == nullptr || left == nullptr || right == nullptr) return false;
    if (instance.interleaved.size() < frames * 2) instance.interleaved.resize(frames * 2);
    float *buffer = instance.interleaved.data();
    instance.synth->render(buffer, static_cast<Bit32u>(frames));
    for (size_t i = 0; i < frames; i++) {
        left[i] = buffer[i * 2];
        right[i] = buffer[i * 2 + 1];
    }
    publishedDisplay.publish(instance.synth);
    return true;
}

extern "C" bool X68MT32_GetDisplay(char *text, bool *midiMessageLED) {
    std::lock_guard<std::mutex> lock(publishedDisplay.mutex);
    if (!publishedDisplay.valid) return false;
    if (text != nullptr) std::memcpy(text, publishedDisplay.text, sizeof(publishedDisplay.text));
    if (midiMessageLED != nullptr) *midiMessageLED = publishedDisplay.midiMessageLED;
    return true;
}
