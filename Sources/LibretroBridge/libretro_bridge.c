// Generic libretro host. See libretro_bridge.h for the contract. Single-instance: one live core
// per process (libretro callbacks carry no user-data, so the active core lives in `g_core`).

#include "libretro_bridge.h"

#include <libretro.h>

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>

// ---- libretro entry-point signatures we resolve out of the core dylib ---------------------------
typedef void        (*fn_set_environment)(retro_environment_t);
typedef void        (*fn_set_video_refresh)(retro_video_refresh_t);
typedef void        (*fn_set_audio_sample)(retro_audio_sample_t);
typedef void        (*fn_set_audio_sample_batch)(retro_audio_sample_batch_t);
typedef void        (*fn_set_input_poll)(retro_input_poll_t);
typedef void        (*fn_set_input_state)(retro_input_state_t);
typedef void        (*fn_init)(void);
typedef void        (*fn_deinit)(void);
typedef unsigned    (*fn_api_version)(void);
typedef void        (*fn_get_system_info)(struct retro_system_info*);
typedef void        (*fn_get_system_av_info)(struct retro_system_av_info*);
typedef void        (*fn_set_controller_port_device)(unsigned, unsigned);
typedef void        (*fn_reset)(void);
typedef void        (*fn_run)(void);
typedef size_t      (*fn_serialize_size)(void);
typedef bool        (*fn_serialize)(void*, size_t);
typedef bool        (*fn_unserialize)(const void*, size_t);
typedef bool        (*fn_load_game)(const struct retro_game_info*);
typedef void        (*fn_unload_game)(void);
typedef void*       (*fn_get_memory_data)(unsigned);
typedef size_t      (*fn_get_memory_size)(unsigned);

struct LibretroCoreHandle {
    void* dll;

    fn_set_environment            set_environment;
    fn_set_video_refresh          set_video_refresh;
    fn_set_audio_sample           set_audio_sample;
    fn_set_audio_sample_batch     set_audio_sample_batch;
    fn_set_input_poll             set_input_poll;
    fn_set_input_state            set_input_state;
    fn_init                       init;
    fn_deinit                     deinit;
    fn_api_version                api_version;
    fn_get_system_info            get_system_info;
    fn_get_system_av_info         get_system_av_info;
    fn_set_controller_port_device set_controller_port_device;
    fn_reset                      reset;
    fn_run                        run;
    fn_serialize_size             serialize_size;
    fn_serialize                  serialize;
    fn_unserialize                unserialize;
    fn_load_game                  load_game;
    fn_unload_game                unload_game;
    fn_get_memory_data            get_memory_data;
    fn_get_memory_size            get_memory_size;

    char system_dir[1024];
    char save_dir[1024];
    char version[256];           // "<library_name> <library_version>"

    bool need_fullpath;
    enum retro_pixel_format pixfmt;

    // Latest frame, converted to RGBA8888 (R,G,B,A byte order).
    uint32_t* fb;
    size_t    fb_cap;            // capacity in pixels
    uint32_t  fb_w, fb_h;

    // Audio: linear queue of interleaved stereo Int16, drained by read_audio.
    int16_t*  audio;
    size_t    audio_cap;         // capacity in samples (not frames)
    size_t    audio_len;         // valid samples queued

    double    sample_rate;
    double    fps;

    // Input snapshot, set from Swift, read by input_state callback.
    uint16_t  joypad[8];
    int16_t   analog[8][2][2];   // [port][index(L/R)][axis(X/Y)]

    // Core-option overrides the frontend answers GET_VARIABLE with (e.g. PGXP, internal resolution).
    char opt_key[32][64];
    char opt_val[32][64];
    int  opt_n;
    bool opt_dirty;              // an option changed since the core last polled GET_VARIABLE_UPDATE

    // Multi-disc: the core hands us this callback struct for a .m3u; we drive it to swap discs.
    struct retro_disk_control_callback disk;
    bool has_disk;
};

// The one live core (libretro callbacks have no user-data pointer to route through).
static struct LibretroCoreHandle* g_core = NULL;

// ---- callbacks ----------------------------------------------------------------------------------

static void cb_log(enum retro_log_level level, const char* fmt, ...) {
    (void)level;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
}

static bool cb_environment(unsigned cmd, void* data) {
    struct LibretroCoreHandle* c = g_core;
    switch (cmd) {
    case RETRO_ENVIRONMENT_GET_CAN_DUPE:
        if (data) *(bool*)data = true;
        return true;

    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
        enum retro_pixel_format fmt = *(const enum retro_pixel_format*)data;
        if (fmt == RETRO_PIXEL_FORMAT_0RGB1555 ||
            fmt == RETRO_PIXEL_FORMAT_XRGB8888 ||
            fmt == RETRO_PIXEL_FORMAT_RGB565) {
            if (c) c->pixfmt = fmt;
            return true;
        }
        return false;   // an exotic format we don't convert
    }

    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
        if (data) *(const char**)data = c ? c->system_dir : "";
        return true;

    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
        if (data) *(const char**)data = c ? c->save_dir : "";
        return true;

    case RETRO_ENVIRONMENT_GET_VARIABLE: {
        struct retro_variable* v = (struct retro_variable*)data;
        if (!v || !v->key) return false;
        if (c) {
            for (int i = 0; i < c->opt_n; i++) {
                if (strcmp(c->opt_key[i], v->key) == 0) { v->value = c->opt_val[i]; return true; }
            }
        }
        v->value = NULL;   // not overridden → core uses its own default
        return false;
    }

    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
        if (data) { *(bool*)data = c ? c->opt_dirty : false; }
        if (c) c->opt_dirty = false;
        return true;

    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: {
        struct retro_log_callback* cbk = (struct retro_log_callback*)data;
        if (cbk) cbk->log = cb_log;
        return true;
    }

    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO: {
        const struct retro_system_av_info* av = (const struct retro_system_av_info*)data;
        if (c && av) {
            c->sample_rate = av->timing.sample_rate;
            c->fps         = av->timing.fps;
        }
        return true;
    }

    case RETRO_ENVIRONMENT_SET_GEOMETRY:
        // Geometry hint only; actual size comes from each video_refresh. Accept.
        return true;

    case RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE:
        // A multi-disc game (.m3u): capture the callbacks so we can swap discs. We don't advertise
        // the EXT interface (GET_DISK_CONTROL_INTERFACE_VERSION unhandled → the core uses this v0
        // one), so labels are synthesized frontend-side.
        if (c && data) { c->disk = *(const struct retro_disk_control_callback*)data; c->has_disk = true; }
        return true;

    default:
        // Everything else (input descriptors, core-option variants, rumble, perf, controller
        // info, subsystems, …) is unsupported — the core copes with a false here.
        return false;
    }
}

static void cb_video_refresh(const void* data, unsigned width, unsigned height, size_t pitch) {
    struct LibretroCoreHandle* c = g_core;
    if (!c || !data || width == 0 || height == 0) return;   // NULL == duped frame: keep last

    size_t need = (size_t)width * height;
    if (need > c->fb_cap) {
        uint32_t* nb = (uint32_t*)realloc(c->fb, need * sizeof(uint32_t));
        if (!nb) return;
        c->fb = nb;
        c->fb_cap = need;
    }
    c->fb_w = width;
    c->fb_h = height;

    uint32_t* out = c->fb;
    const uint8_t* base = (const uint8_t*)data;

    if (c->pixfmt == RETRO_PIXEL_FORMAT_XRGB8888) {
        for (unsigned y = 0; y < height; y++) {
            const uint32_t* row = (const uint32_t*)(base + (size_t)y * pitch);
            for (unsigned x = 0; x < width; x++) {
                uint32_t px = row[x];               // 0x00RRGGBB / 0xFFRRGGBB
                uint32_t r = (px >> 16) & 0xFF;
                uint32_t g = (px >> 8) & 0xFF;
                uint32_t b = px & 0xFF;
                *out++ = r | (g << 8) | (b << 16) | 0xFF000000u;
            }
        }
    } else if (c->pixfmt == RETRO_PIXEL_FORMAT_RGB565) {
        for (unsigned y = 0; y < height; y++) {
            const uint16_t* row = (const uint16_t*)(base + (size_t)y * pitch);
            for (unsigned x = 0; x < width; x++) {
                uint16_t px = row[x];
                uint32_t r = (px >> 11) & 0x1F, g = (px >> 5) & 0x3F, b = px & 0x1F;
                uint32_t r8 = (r << 3) | (r >> 2);
                uint32_t g8 = (g << 2) | (g >> 4);
                uint32_t b8 = (b << 3) | (b >> 2);
                *out++ = r8 | (g8 << 8) | (b8 << 16) | 0xFF000000u;
            }
        }
    } else { // RETRO_PIXEL_FORMAT_0RGB1555
        for (unsigned y = 0; y < height; y++) {
            const uint16_t* row = (const uint16_t*)(base + (size_t)y * pitch);
            for (unsigned x = 0; x < width; x++) {
                uint16_t px = row[x];
                uint32_t r = (px >> 10) & 0x1F, g = (px >> 5) & 0x1F, b = px & 0x1F;
                uint32_t r8 = (r << 3) | (r >> 2);
                uint32_t g8 = (g << 3) | (g >> 2);
                uint32_t b8 = (b << 3) | (b >> 2);
                *out++ = r8 | (g8 << 8) | (b8 << 16) | 0xFF000000u;
            }
        }
    }
}

static void audio_push(struct LibretroCoreHandle* c, const int16_t* data, size_t frames) {
    size_t samples = frames * 2;
    if (c->audio_len + samples > c->audio_cap) {
        size_t ncap = c->audio_cap ? c->audio_cap : 8192;
        while (ncap < c->audio_len + samples) ncap *= 2;
        int16_t* nb = (int16_t*)realloc(c->audio, ncap * sizeof(int16_t));
        if (!nb) return;
        c->audio = nb;
        c->audio_cap = ncap;
    }
    memcpy(c->audio + c->audio_len, data, samples * sizeof(int16_t));
    c->audio_len += samples;
}

static void cb_audio_sample(int16_t left, int16_t right) {
    if (!g_core) return;
    int16_t f[2] = { left, right };
    audio_push(g_core, f, 1);
}

static size_t cb_audio_sample_batch(const int16_t* data, size_t frames) {
    if (g_core && data) audio_push(g_core, data, frames);
    return frames;
}

static void cb_input_poll(void) { /* input is pushed from Swift; nothing to poll. */ }

static int16_t cb_input_state(unsigned port, unsigned device, unsigned index, unsigned id) {
    struct LibretroCoreHandle* c = g_core;
    if (!c || port >= 8) return 0;

    if (device == RETRO_DEVICE_JOYPAD) {
        if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return c->joypad[port];
        if (id < 16) return (c->joypad[port] >> id) & 1;
        return 0;
    }
    if (device == RETRO_DEVICE_ANALOG) {
        // Sticks only (RETRO_DEVICE_INDEX_ANALOG_LEFT/RIGHT); button-pressure index ignored.
        if (index < 2 && id < 2) return c->analog[port][index][id];
        return 0;
    }
    return 0;
}

// ---- lifecycle ----------------------------------------------------------------------------------

static void* sym(void* dll, const char* name) { return dlsym(dll, name); }

LibretroCoreHandle* libretro_bridge_create(const char* core_path,
                                           const char* system_dir,
                                           const char* save_dir) {
    if (g_core) return NULL;   // single-instance

    void* dll = dlopen(core_path, RTLD_NOW | RTLD_LOCAL);
    if (!dll) {
        fprintf(stderr, "libretro_bridge: dlopen failed: %s\n", dlerror());
        return NULL;
    }

    struct LibretroCoreHandle* c = (struct LibretroCoreHandle*)calloc(1, sizeof(*c));
    if (!c) { dlclose(dll); return NULL; }
    c->dll = dll;
    c->pixfmt = RETRO_PIXEL_FORMAT_0RGB1555;   // libretro default until the core overrides it
    c->sample_rate = 44100.0;
    c->fps = 60.0;

    c->set_environment            = (fn_set_environment)sym(dll, "retro_set_environment");
    c->set_video_refresh          = (fn_set_video_refresh)sym(dll, "retro_set_video_refresh");
    c->set_audio_sample           = (fn_set_audio_sample)sym(dll, "retro_set_audio_sample");
    c->set_audio_sample_batch     = (fn_set_audio_sample_batch)sym(dll, "retro_set_audio_sample_batch");
    c->set_input_poll             = (fn_set_input_poll)sym(dll, "retro_set_input_poll");
    c->set_input_state            = (fn_set_input_state)sym(dll, "retro_set_input_state");
    c->init                       = (fn_init)sym(dll, "retro_init");
    c->deinit                     = (fn_deinit)sym(dll, "retro_deinit");
    c->api_version                = (fn_api_version)sym(dll, "retro_api_version");
    c->get_system_info            = (fn_get_system_info)sym(dll, "retro_get_system_info");
    c->get_system_av_info         = (fn_get_system_av_info)sym(dll, "retro_get_system_av_info");
    c->set_controller_port_device = (fn_set_controller_port_device)sym(dll, "retro_set_controller_port_device");
    c->reset                      = (fn_reset)sym(dll, "retro_reset");
    c->run                        = (fn_run)sym(dll, "retro_run");
    c->serialize_size             = (fn_serialize_size)sym(dll, "retro_serialize_size");
    c->serialize                  = (fn_serialize)sym(dll, "retro_serialize");
    c->unserialize                = (fn_unserialize)sym(dll, "retro_unserialize");
    c->load_game                  = (fn_load_game)sym(dll, "retro_load_game");
    c->unload_game                = (fn_unload_game)sym(dll, "retro_unload_game");
    c->get_memory_data            = (fn_get_memory_data)sym(dll, "retro_get_memory_data");
    c->get_memory_size            = (fn_get_memory_size)sym(dll, "retro_get_memory_size");

    if (!c->set_environment || !c->set_video_refresh || !c->set_audio_sample_batch ||
        !c->set_input_poll || !c->set_input_state || !c->init || !c->deinit || !c->run ||
        !c->load_game || !c->api_version || !c->get_system_av_info || !c->get_system_info) {
        fprintf(stderr, "libretro_bridge: core missing required entry points\n");
        dlclose(dll);
        free(c);
        return NULL;
    }

    if (c->api_version() != RETRO_API_VERSION) {
        fprintf(stderr, "libretro_bridge: unsupported libretro API version %u (want %u)\n",
                c->api_version(), RETRO_API_VERSION);
        dlclose(dll);
        free(c);
        return NULL;
    }

    if (system_dir) { strncpy(c->system_dir, system_dir, sizeof(c->system_dir) - 1); }
    if (save_dir)   { strncpy(c->save_dir,   save_dir,   sizeof(c->save_dir) - 1); }

    struct retro_system_info info;
    memset(&info, 0, sizeof(info));
    c->get_system_info(&info);
    c->need_fullpath = info.need_fullpath;
    snprintf(c->version, sizeof(c->version), "%s %s",
             info.library_name ? info.library_name : "libretro",
             info.library_version ? info.library_version : "?");

    g_core = c;   // publish before wiring callbacks (they reference g_core)
    c->set_environment(cb_environment);
    c->set_video_refresh(cb_video_refresh);
    c->set_audio_sample(cb_audio_sample);
    c->set_audio_sample_batch(cb_audio_sample_batch);
    c->set_input_poll(cb_input_poll);
    c->set_input_state(cb_input_state);
    c->init();

    return c;
}

void libretro_bridge_destroy(LibretroCoreHandle* c) {
    if (!c) return;
    if (c->unload_game) c->unload_game();
    if (c->deinit) c->deinit();
    if (c->dll) dlclose(c->dll);
    free(c->fb);
    free(c->audio);
    if (g_core == c) g_core = NULL;
    free(c);
}

bool libretro_bridge_load_game(LibretroCoreHandle* c, const char* rom_path) {
    if (!c || !rom_path) return false;

    struct retro_game_info gi;
    memset(&gi, 0, sizeof(gi));
    gi.path = rom_path;
    // need_fullpath cores (Beetle PSX) read the file themselves; others want the bytes buffered.
    unsigned char* buf = NULL;
    if (!c->need_fullpath) {
        FILE* f = fopen(rom_path, "rb");
        if (!f) return false;
        fseek(f, 0, SEEK_END);
        long sz = ftell(f);
        fseek(f, 0, SEEK_SET);
        if (sz > 0) {
            buf = (unsigned char*)malloc((size_t)sz);
            if (buf && fread(buf, 1, (size_t)sz, f) == (size_t)sz) {
                gi.data = buf;
                gi.size = (size_t)sz;
            }
        }
        fclose(f);
    }

    bool ok = c->load_game(&gi);
    free(buf);
    if (!ok) return false;

    struct retro_system_av_info av;
    memset(&av, 0, sizeof(av));
    c->get_system_av_info(&av);
    c->sample_rate = av.timing.sample_rate > 0 ? av.timing.sample_rate : 44100.0;
    c->fps         = av.timing.fps > 0 ? av.timing.fps : 60.0;
    return true;
}

void libretro_bridge_unload_game(LibretroCoreHandle* c) {
    if (c && c->unload_game) c->unload_game();
}

void libretro_bridge_reset(LibretroCoreHandle* c) { if (c && c->reset) c->reset(); }

void libretro_bridge_run_frame(LibretroCoreHandle* c) {
    if (!c) return;
    c->audio_len = 0;   // audio queued this frame is drained after run
    c->run();
}

void libretro_bridge_dimensions(LibretroCoreHandle* c, uint32_t* width, uint32_t* height) {
    if (width)  *width  = c ? c->fb_w : 0;
    if (height) *height = c ? c->fb_h : 0;
}

void libretro_bridge_video(LibretroCoreHandle* c, uint32_t* out) {
    if (!c || !out || !c->fb) return;
    memcpy(out, c->fb, (size_t)c->fb_w * c->fb_h * sizeof(uint32_t));
}

double libretro_bridge_sample_rate(LibretroCoreHandle* c) { return c ? c->sample_rate : 44100.0; }
double libretro_bridge_fps(LibretroCoreHandle* c)         { return c ? c->fps : 60.0; }

int libretro_bridge_read_audio(LibretroCoreHandle* c, int16_t* out, int max_frames) {
    if (!c || !out || max_frames <= 0) return 0;
    size_t want = (size_t)max_frames * 2;
    size_t give = c->audio_len < want ? c->audio_len : want;
    memcpy(out, c->audio, give * sizeof(int16_t));
    size_t rem = c->audio_len - give;
    if (rem) memmove(c->audio, c->audio + give, rem * sizeof(int16_t));
    c->audio_len = rem;
    return (int)(give / 2);
}

void libretro_bridge_set_joypad(LibretroCoreHandle* c, unsigned port, uint16_t mask) {
    if (c && port < 8) c->joypad[port] = mask;
}

void libretro_bridge_set_analog(LibretroCoreHandle* c, unsigned port,
                                unsigned index, unsigned axis, int16_t value) {
    if (c && port < 8 && index < 2 && axis < 2) c->analog[port][index][axis] = value;
}

void libretro_bridge_set_controller(LibretroCoreHandle* c, unsigned port, unsigned device) {
    if (c && c->set_controller_port_device) c->set_controller_port_device(port, device);
}

unsigned libretro_bridge_disc_count(LibretroCoreHandle* c) {
    return (c && c->has_disk && c->disk.get_num_images) ? c->disk.get_num_images() : 0;
}

unsigned libretro_bridge_disc_index(LibretroCoreHandle* c) {
    return (c && c->has_disk && c->disk.get_image_index) ? c->disk.get_image_index() : 0;
}

bool libretro_bridge_set_disc(LibretroCoreHandle* c, unsigned index) {
    if (!c || !c->has_disk || !c->disk.set_eject_state || !c->disk.set_image_index) return false;
    // Real drive sequence: open the tray, swap the disc image, close the tray.
    c->disk.set_eject_state(true);
    bool ok = c->disk.set_image_index(index);
    c->disk.set_eject_state(false);
    return ok;
}

void libretro_bridge_set_option(LibretroCoreHandle* c, const char* key, const char* value) {
    if (!c || !key || !value) return;
    for (int i = 0; i < c->opt_n; i++) {              // replace an existing override
        if (strcmp(c->opt_key[i], key) == 0) {
            strncpy(c->opt_val[i], value, sizeof(c->opt_val[i]) - 1);
            c->opt_val[i][sizeof(c->opt_val[i]) - 1] = 0;
            c->opt_dirty = true;
            return;
        }
    }
    if (c->opt_n >= 32) return;                       // table full
    strncpy(c->opt_key[c->opt_n], key, sizeof(c->opt_key[0]) - 1);
    c->opt_key[c->opt_n][sizeof(c->opt_key[0]) - 1] = 0;
    strncpy(c->opt_val[c->opt_n], value, sizeof(c->opt_val[0]) - 1);
    c->opt_val[c->opt_n][sizeof(c->opt_val[0]) - 1] = 0;
    c->opt_n++;
    c->opt_dirty = true;
}

size_t libretro_bridge_state_size(LibretroCoreHandle* c) {
    return (c && c->serialize_size) ? c->serialize_size() : 0;
}

bool libretro_bridge_save_state(LibretroCoreHandle* c, void* dst, size_t cap) {
    return (c && c->serialize) ? c->serialize(dst, cap) : false;
}

bool libretro_bridge_load_state(LibretroCoreHandle* c, const void* src, size_t len) {
    return (c && c->unserialize) ? c->unserialize(src, len) : false;
}

size_t libretro_bridge_save_ram_size(LibretroCoreHandle* c) {
    return (c && c->get_memory_size) ? c->get_memory_size(RETRO_MEMORY_SAVE_RAM) : 0;
}

bool libretro_bridge_get_save_ram(LibretroCoreHandle* c, void* dst) {
    if (!c || !dst || !c->get_memory_data || !c->get_memory_size) return false;
    size_t n = c->get_memory_size(RETRO_MEMORY_SAVE_RAM);
    void* src = c->get_memory_data(RETRO_MEMORY_SAVE_RAM);
    if (!n || !src) return false;
    memcpy(dst, src, n);
    return true;
}

bool libretro_bridge_set_save_ram(LibretroCoreHandle* c, const void* src, size_t len) {
    if (!c || !src || !c->get_memory_data || !c->get_memory_size) return false;
    size_t n = c->get_memory_size(RETRO_MEMORY_SAVE_RAM);
    void* dst = c->get_memory_data(RETRO_MEMORY_SAVE_RAM);
    if (!n || !dst) return false;
    memcpy(dst, src, len < n ? len : n);
    return true;
}

const char* libretro_bridge_core_version(LibretroCoreHandle* c) {
    return c ? c->version : "libretro ?";
}
