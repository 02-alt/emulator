// Vulkan HW-render host (MoltenVK) for the libretro bridge — internal to the target.
#ifndef LIBRETRO_VK_H
#define LIBRETRO_VK_H

#include <stdint.h>
#include <stdbool.h>

/// True once MoltenVK is loaded (and thus a Vulkan HW core can be driven).
bool vk_host_available(void);

/// Handle the Vulkan HW-render environment calls (SET_HW_RENDER, negotiation, GET_HW_RENDER_INTERFACE).
/// Returns true if the call was for us and handled.
bool vk_host_environment(unsigned cmd, void* data);

/// True once the core has requested a Vulkan context (SET_HW_RENDER seen).
bool vk_host_active(void);

/// Create the Vulkan instance/device (MoltenVK) and hand the core its interface. Call after the game
/// loads, before the first frame. Returns false on any failure (caller falls back to software).
bool vk_host_create_context(void);

/// Copy the core's latest rendered image into `out` (RGBA8888, R,G,B,A), clamped to max_w×max_h.
/// Writes the actual copied size to *w,*h. Returns false if no HW frame is available.
bool vk_host_readback(uint32_t* out, uint32_t max_w, uint32_t max_h, uint32_t* w, uint32_t* h);

/// Tell the host the current frame dimensions (the core doesn't pass them to set_image).
void vk_host_set_frame_size(uint32_t w, uint32_t h);

#endif
