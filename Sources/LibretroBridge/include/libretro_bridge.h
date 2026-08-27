// A thin, generic host over the libretro API — the single FFI surface Swift talks to for any
// libretro core (PS1's Beetle PSX first). It `dlopen`s a core dylib at runtime, wires the six
// libretro callbacks, and exposes a small handle-based C API shaped like the mgba bridge so the
// Swift side (`LibretroCore`) reads the same as `MGBACore`.
//
// Single-instance by design: libretro cores keep global state and their callbacks carry no
// user-data pointer, so exactly one core may be live in the process at a time. Creating a second
// while one is live returns NULL.
#ifndef LIBRETRO_BRIDGE_H
#define LIBRETRO_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LibretroCoreHandle LibretroCoreHandle;

/// Load the libretro core dylib at `core_path`, point it at `system_dir` (where it looks for BIOS
/// images) and `save_dir` (where it may drop saves), and run `retro_init`. No game yet.
/// Returns NULL if the dylib can't be opened, a required entry point is missing, the reported
/// libretro API version is unsupported, or another core is already live.
LibretroCoreHandle* libretro_bridge_create(const char* core_path,
                                           const char* system_dir,
                                           const char* save_dir);
void libretro_bridge_destroy(LibretroCoreHandle* c);

/// Load a game by file path. Beetle PSX is a `need_fullpath` core: it reads the .cue/.chd/.m3u
/// itself from this path (data is not pre-buffered). Returns false on failure.
bool libretro_bridge_load_game(LibretroCoreHandle* c, const char* rom_path);
void libretro_bridge_unload_game(LibretroCoreHandle* c);

void libretro_bridge_reset(LibretroCoreHandle* c);
void libretro_bridge_run_frame(LibretroCoreHandle* c);

/// Current framebuffer size in pixels. PS1 changes this per frame (256..640 wide, interlacing),
/// so callers must re-read it after every `run_frame` rather than caching it once.
void libretro_bridge_dimensions(LibretroCoreHandle* c, uint32_t* width, uint32_t* height);

/// Copy the latest frame into `out` (must hold width*height pixels) as RGBA8888 in memory byte
/// order R,G,B,A — matching the app's Metal `.rgba8Unorm` path, whatever pixel format the core
/// emitted. If the core duped the frame (emitted NULL), the previous frame is copied.
void libretro_bridge_video(LibretroCoreHandle* c, uint32_t* out);

/// Pixel capacity of the buffer passed to `libretro_bridge_video`. When set, a dynamic-resolution
/// frame reporting more pixels than this is cropped (never copied past the buffer). 0 = unbounded.
void libretro_bridge_set_max_video_pixels(LibretroCoreHandle* c, uint32_t pixels);

/// Audio sample rate (Hz) and nominal video FPS the core reports via retro_get_system_av_info.
double libretro_bridge_sample_rate(LibretroCoreHandle* c);
double libretro_bridge_fps(LibretroCoreHandle* c);

/// Drain up to `max_frames` stereo sample-frames (interleaved L,R Int16) accumulated since the
/// last drain. Returns the number of sample-frames written.
int libretro_bridge_read_audio(LibretroCoreHandle* c, int16_t* out, int max_frames);

/// Held joypad buttons for `port` as a bitmask; bit i == RETRO_DEVICE_ID_JOYPAD_i (B,Y,Select,
/// Start,Up,Down,Left,Right,A,X,L,R,L2,R2,L3,R3). Mirrors the mgba bridge's set_keys.
void libretro_bridge_set_joypad(LibretroCoreHandle* c, unsigned port, uint16_t mask);

/// Analog stick value for `port`. `index` = 0 (left stick) / 1 (right stick); `axis` = 0 (X) /
/// 1 (Y). Range -32768..32767, matching RETRO_DEVICE_ANALOG.
void libretro_bridge_set_analog(LibretroCoreHandle* c, unsigned port,
                                unsigned index, unsigned axis, int16_t value);

/// Bind a port to a libretro controller device id (e.g. RETRO_DEVICE_ANALOG's DualShock variant).
void libretro_bridge_set_controller(LibretroCoreHandle* c, unsigned port, unsigned device);

/// Override a core option the core reads via GET_VARIABLE (e.g. "beetle_psx_internal_resolution" =
/// "2x", "beetle_psx_pgxp_mode" = "memory only"). Set before loading the game so it's applied at
/// load; changing one later flags the core to re-read on its next GET_VARIABLE_UPDATE poll.
void libretro_bridge_set_option(LibretroCoreHandle* c, const char* key, const char* value);

/// Multi-disc control (populated when a `.m3u` is loaded). `disc_count` is the number of discs (0 or
/// 1 = single-disc, no switching needed); `disc_index` is the currently-inserted one; `set_disc`
/// ejects, swaps to `index`, and re-inserts (returns false on failure or a single-disc game).
unsigned libretro_bridge_disc_count(LibretroCoreHandle* c);
unsigned libretro_bridge_disc_index(LibretroCoreHandle* c);
bool     libretro_bridge_set_disc(LibretroCoreHandle* c, unsigned index);

/// Full machine state (save states / rewind / run-ahead).
size_t libretro_bridge_state_size(LibretroCoreHandle* c);
bool   libretro_bridge_save_state(LibretroCoreHandle* c, void* dst, size_t cap);
bool   libretro_bridge_load_state(LibretroCoreHandle* c, const void* src, size_t len);

/// Persistent cartridge/memory-card save (RETRO_MEMORY_SAVE_RAM). 0 if the game has none.
size_t libretro_bridge_save_ram_size(LibretroCoreHandle* c);
bool   libretro_bridge_get_save_ram(LibretroCoreHandle* c, void* dst);       // dst holds save_ram_size bytes
bool   libretro_bridge_set_save_ram(LibretroCoreHandle* c, const void* src, size_t len);

/// libretro core identity string ("<name> <version>"), for savestate-compatibility gating.
const char* libretro_bridge_core_version(LibretroCoreHandle* c);

#ifdef __cplusplus
}
#endif

#endif // LIBRETRO_BRIDGE_H
