// Thin C bridge over libmgba's mCore API — the single FFI surface Swift talks to.
// Keeps mgba's internal headers out of the Swift-facing module: only these plain-C
// declarations are exported.
#ifndef MGBA_BRIDGE_H
#define MGBA_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GBABridge GBABridge;

/// Which mGBA core a bridge wraps. The wire values are stable — Swift passes them straight through.
enum BridgePlatform {
    BRIDGE_PLATFORM_GBA = 0,   ///< Game Boy Advance
    BRIDGE_PLATFORM_GB  = 1,   ///< Game Boy / Game Boy Color
};

/// Create and initialize a GBA core (no ROM yet). Returns NULL on failure.
GBABridge* gba_bridge_create(void);

/// Create and initialize a core for the given platform (no ROM yet). Returns NULL on failure.
/// GBA carts need extra save-type/RTC fix-ups the bare core skips; the GB/GBC core auto-detects its
/// own MBC and save hardware, so those overrides are only applied for `BRIDGE_PLATFORM_GBA`.
GBABridge* gba_bridge_create_system(int platform);
void gba_bridge_destroy(GBABridge* b);

/// Load a .gba ROM from disk and reset. Returns false if the file isn't a valid ROM.
bool gba_bridge_load_rom(GBABridge* b, const char* path);
void gba_bridge_reset(GBABridge* b);
void gba_bridge_run_frame(GBABridge* b);

void gba_bridge_dimensions(GBABridge* b, unsigned* width, unsigned* height);
int  gba_bridge_sample_rate(GBABridge* b);

/// Copy the latest framebuffer (width*height pixels) into out. Pixels are libmgba's
/// native 32-bit color_t; the renderer maps the byte order to its Metal texture format.
void gba_bridge_video(GBABridge* b, uint32_t* out);

/// Drain up to max_frames stereo sample-frames into out (interleaved L,R Int16).
/// Returns the number of sample-frames written.
int  gba_bridge_read_audio(GBABridge* b, int16_t* out, int max_frames);

/// Set held buttons; bit order matches libmgba's GBA key indices.
void gba_bridge_set_keys(GBABridge* b, uint16_t keys);

size_t gba_bridge_state_size(GBABridge* b);
bool   gba_bridge_save_state(GBABridge* b, void* buf, size_t len);
bool   gba_bridge_load_state(GBABridge* b, const void* buf, size_t len);

/// Battery/SRAM (persistent cartridge save). `gba_bridge_save_data` returns the size and, if
/// non-zero, points *out at a malloc'd copy the caller must release with `gba_bridge_free`.
size_t gba_bridge_save_data(GBABridge* b, void** out);
void   gba_bridge_free(void* p);
bool   gba_bridge_load_save_data(GBABridge* b, const void* data, size_t len);

/// The linked libmgba's release version (e.g. "0.10.5"). Stable across builds of the same source,
/// so macOS and iOS report an identical value — used to stamp savestates for Continuity's
/// exact-match version gate (a state is only restorable by the build that wrote it).
const char* gba_bridge_core_version(void);

#ifdef __cplusplus
}
#endif

#endif /* MGBA_BRIDGE_H */
