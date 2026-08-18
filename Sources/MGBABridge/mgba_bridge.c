#include "mgba_bridge.h"

#include <stdlib.h>
#include <string.h>

#include <mgba/core/core.h>
#include <mgba/core/blip_buf.h>
#include <mgba/gba/core.h>
#include <mgba/internal/gba/gba.h>
#include <mgba/internal/gba/overrides.h>
#include <mgba/internal/gba/cart/gpio.h>

#define BRIDGE_SAMPLE_RATE 32768
#define BRIDGE_AUDIO_BUFFER 2048

struct GBABridge {
    struct mCore* core;
    color_t* video;      // color_t is 32-bit in this build
    unsigned width;
    unsigned height;
    int sampleRate;
};

// (Re)point the core at our video buffer and (re)set audio rates. Safe to call after reset,
// since some cores rebuild these on reset.
static void bridge_apply_buffers(GBABridge* b) {
    b->core->setVideoBuffer(b->core, b->video, b->width);
    b->core->setAudioBufferSize(b->core, BRIDGE_AUDIO_BUFFER);
    double clock = (double)b->core->frequency(b->core);
    blip_set_rates(b->core->getAudioChannel(b->core, 0), clock, BRIDGE_SAMPLE_RATE);
    blip_set_rates(b->core->getAudioChannel(b->core, 1), clock, BRIDGE_SAMPLE_RATE);
}

GBABridge* gba_bridge_create(void) {
    GBABridge* b = calloc(1, sizeof(GBABridge));
    if (!b) return NULL;

    b->core = GBACoreCreate();
    if (!b->core) { free(b); return NULL; }

    b->core->init(b->core);
    mCoreInitConfig(b->core, NULL); // required before reset/runFrame, else the core NULL-derefs
    b->core->desiredVideoDimensions(b->core, &b->width, &b->height);
    b->video = malloc((size_t)b->width * b->height * sizeof(color_t));
    if (!b->video) { b->core->deinit(b->core); free(b); return NULL; }

    b->sampleRate = BRIDGE_SAMPLE_RATE;
    bridge_apply_buffers(b);
    return b;
}

void gba_bridge_destroy(GBABridge* b) {
    if (!b) return;
    if (b->core) {
        mCoreConfigDeinit(&b->core->config);
        b->core->deinit(b->core);
    }
    free(b->video);
    free(b);
}

// Detect the cartridge save type by scanning the ROM for its marker string — the job real mGBA
// frontends do but the bare core does not, so without it the save chip is never set up and games
// that probe it at boot (e.g. Pokémon's flash-ID check) hang on a white screen.
static enum SavedataType bridge_detect_savetype(const struct GBA* gba) {
    const char* rom = (const char*) gba->memory.rom;
    size_t size = gba->memory.romSize;
    if (!rom || !size) return SAVEDATA_AUTODETECT;

    static const struct { const char* marker; enum SavedataType type; } markers[] = {
        { "EEPROM_V",   SAVEDATA_EEPROM },
        { "SRAM_V",     SAVEDATA_SRAM },
        { "SRAM_F_V",   SAVEDATA_SRAM },
        { "FLASH1M_V",  SAVEDATA_FLASH1M },
        { "FLASH512_V", SAVEDATA_FLASH512 },
        { "FLASH_V",    SAVEDATA_FLASH512 },
    };
    for (size_t k = 0; k < sizeof(markers) / sizeof(markers[0]); ++k) {
        if (memmem(rom, size, markers[k].marker, strlen(markers[k].marker))) {
            return markers[k].type;
        }
    }
    return SAVEDATA_AUTODETECT;
}

// Fix up carts mGBA can't fully configure on its own (must run *after* reset, which re-runs the
// built-in auto-detect): (1) apply the ROM-scanned save type, and (2) if no cartridge hardware was
// recognised — the case for ROM hacks with custom game codes — force the real-time clock, since
// RTC-dependent Pokémon-family hacks otherwise hang on a white screen. Recognised games keep the
// hardware mGBA already detected.
static void bridge_apply_overrides(GBABridge* b) {
    struct GBA* gba = (struct GBA*) b->core->board;
    if (!gba || !gba->memory.rom) return;

    bool hwUndetected = (gba->memory.hw.devices & ~HW_GB_PLAYER_DETECTION) == HW_NONE;

    struct GBACartridgeOverride override;
    memcpy(override.id, &((const char*) gba->memory.rom)[0xAC], 4);
    override.savetype = bridge_detect_savetype(gba);                  // AUTODETECT if no marker
    override.hardware = hwUndetected ? HW_RTC : HW_NO_OVERRIDE;       // force RTC only for unknowns
    override.idleLoop = IDLE_LOOP_NONE;
    override.mirroring = false;
    override.vbaBugCompat = gba->vbaBugCompat;
    GBAOverrideApply(gba, &override);
}

bool gba_bridge_load_rom(GBABridge* b, const char* path) {
    if (!mCoreLoadFile(b->core, path)) return false;
    b->core->reset(b->core);
    bridge_apply_overrides(b);
    bridge_apply_buffers(b);
    return true;
}

void gba_bridge_reset(GBABridge* b) {
    b->core->reset(b->core);
    bridge_apply_overrides(b);
    bridge_apply_buffers(b);
}

void gba_bridge_run_frame(GBABridge* b) {
    b->core->runFrame(b->core);
}

void gba_bridge_dimensions(GBABridge* b, unsigned* width, unsigned* height) {
    if (width) *width = b->width;
    if (height) *height = b->height;
}

int gba_bridge_sample_rate(GBABridge* b) {
    return b->sampleRate;
}

void gba_bridge_video(GBABridge* b, uint32_t* out) {
    memcpy(out, b->video, (size_t)b->width * b->height * sizeof(color_t));
}

int gba_bridge_read_audio(GBABridge* b, int16_t* out, int max_frames) {
    struct blip_t* left = b->core->getAudioChannel(b->core, 0);
    struct blip_t* right = b->core->getAudioChannel(b->core, 1);
    int avail = blip_samples_avail(left);
    int count = avail < max_frames ? avail : max_frames;
    if (count <= 0) return 0;
    // stereo=1 => interleaved stride of 2; write L at even, R at odd offsets.
    blip_read_samples(left, out, count, 1);
    blip_read_samples(right, out + 1, count, 1);
    return count;
}

void gba_bridge_set_keys(GBABridge* b, uint16_t keys) {
    b->core->setKeys(b->core, keys);
}

size_t gba_bridge_state_size(GBABridge* b) {
    return b->core->stateSize(b->core);
}

bool gba_bridge_save_state(GBABridge* b, void* buf, size_t len) {
    if (len < b->core->stateSize(b->core)) return false;
    return b->core->saveState(b->core, buf);
}

bool gba_bridge_load_state(GBABridge* b, const void* buf, size_t len) {
    if (len < b->core->stateSize(b->core)) return false;
    return b->core->loadState(b->core, buf);
}

size_t gba_bridge_save_data(GBABridge* b, void** out) {
    return b->core->savedataClone(b->core, out);
}

void gba_bridge_free(void* p) {
    free(p);
}

bool gba_bridge_load_save_data(GBABridge* b, const void* data, size_t len) {
    return b->core->savedataRestore(b->core, data, len, true);
}
