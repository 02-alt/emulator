// Vulkan hardware-render host for the libretro bridge. Lets a Vulkan libretro core (Beetle PSX HW /
// parallel-psx) render at high internal resolution with texture filtering, on Apple Silicon via
// MoltenVK. This implements the frontend half of libretro's Vulkan HW-render contract:
//   - create a VkInstance/VkDevice (MoltenVK), injecting VK_KHR_portability_subset the core doesn't
//     know to ask for (via the negotiation v2 create_device2 wrapper);
//   - expose retro_hw_render_interface_vulkan so the core hands us its rendered VkImage each frame;
//   - read that image back to RGBA so the existing display path can show it.
//
// Verified headlessly first (read-back → PPM) before any live Metal path. Single-frame synchronous
// model (wait-idle each frame) — correctness over throughput for the first cut.

#include "libretro_vk.h"

#include <libretro_vulkan.h>

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Everything is single-instance to match the bridge; guarded by the caller's single-core rule.
struct VkHost {
    void* dll;                                  // libMoltenVK
    PFN_vkGetInstanceProcAddr gipa;

    VkInstance instance;
    VkPhysicalDevice gpu;
    VkDevice device;
    VkQueue queue;
    uint32_t queue_family;

    // Core-provided callbacks.
    retro_hw_context_reset_t context_reset;
    retro_hw_context_reset_t context_destroy;
    const struct retro_hw_render_context_negotiation_interface_vulkan* nego;

    struct retro_hw_render_interface_vulkan iface;

    // Latest frame the core handed us.
    VkImage  last_image;
    VkImageView last_view;
    uint32_t last_w, last_h;
    VkFormat last_format;
    bool     have_frame;

    // Read-back scratch.
    VkCommandPool cmd_pool;

    bool ready;
};

static struct VkHost g_vk;

// Instance-level entry points we resolve up front.
static PFN_vkCreateInstance                       vkCreateInstance_;
static PFN_vkEnumeratePhysicalDevices             vkEnumeratePhysicalDevices_;
static PFN_vkGetPhysicalDeviceQueueFamilyProperties vkGetPhysicalDeviceQueueFamilyProperties_;
static PFN_vkGetPhysicalDeviceMemoryProperties    vkGetPhysicalDeviceMemoryProperties_;
static PFN_vkGetDeviceProcAddr                    vkGetDeviceProcAddr_;
static PFN_vkGetDeviceQueue                       vkGetDeviceQueue_;

// Device-level entry points (resolved after the device exists).
static PFN_vkCreateCommandPool        vkCreateCommandPool_;
static PFN_vkAllocateCommandBuffers   vkAllocateCommandBuffers_;
static PFN_vkBeginCommandBuffer       vkBeginCommandBuffer_;
static PFN_vkEndCommandBuffer         vkEndCommandBuffer_;
static PFN_vkCmdPipelineBarrier       vkCmdPipelineBarrier_;
static PFN_vkCmdCopyImageToBuffer     vkCmdCopyImageToBuffer_;
static PFN_vkQueueSubmit              vkQueueSubmit_;
static PFN_vkQueueWaitIdle            vkQueueWaitIdle_;
static PFN_vkDeviceWaitIdle           vkDeviceWaitIdle_;
static PFN_vkCreateBuffer             vkCreateBuffer_;
static PFN_vkGetBufferMemoryRequirements vkGetBufferMemoryRequirements_;
static PFN_vkAllocateMemory           vkAllocateMemory_;
static PFN_vkBindBufferMemory         vkBindBufferMemory_;
static PFN_vkMapMemory                vkMapMemory_;
static PFN_vkUnmapMemory              vkUnmapMemory_;
static PFN_vkFreeMemory               vkFreeMemory_;
static PFN_vkDestroyBuffer            vkDestroyBuffer_;
static PFN_vkFreeCommandBuffers       vkFreeCommandBuffers_;

#define GIPA(name) (PFN_##name) g_vk.gipa(g_vk.instance, #name)
#define GDPA(name) (PFN_##name) vkGetDeviceProcAddr_(g_vk.device, #name)

// ---- MoltenVK load ------------------------------------------------------------------------------

static const char* moltenvk_candidates[] = {
    "vendor/moltenvk/libMoltenVK.dylib",
    "@executable_path/../Resources/libMoltenVK.dylib",
    "libMoltenVK.dylib",
};

bool vk_host_available(void) {
    if (g_vk.gipa) return true;
    for (size_t i = 0; i < sizeof(moltenvk_candidates) / sizeof(*moltenvk_candidates); i++) {
        void* dll = dlopen(moltenvk_candidates[i], RTLD_NOW | RTLD_LOCAL);
        if (!dll) continue;
        PFN_vkGetInstanceProcAddr gipa = (PFN_vkGetInstanceProcAddr)dlsym(dll, "vkGetInstanceProcAddr");
        if (!gipa) { dlclose(dll); continue; }
        g_vk.dll = dll;
        g_vk.gipa = gipa;
        return true;
    }
    fprintf(stderr, "vk_host: MoltenVK not found\n");
    return false;
}

// ---- environment handling (called from the bridge's environment callback) -----------------------

bool vk_host_environment(unsigned cmd, void* data) {
    switch (cmd) {
    case RETRO_ENVIRONMENT_SET_HW_RENDER: {
        struct retro_hw_render_callback* cb = (struct retro_hw_render_callback*)data;
        if (!cb || cb->context_type != RETRO_HW_CONTEXT_VULKAN) return false;
        if (!vk_host_available()) return false;
        g_vk.context_reset = cb->context_reset;
        g_vk.context_destroy = cb->context_destroy;
        return true;
    }
    case RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE: {
        const struct retro_hw_render_context_negotiation_interface_vulkan* n = data;
        if (!n || n->interface_type != RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN) return false;
        g_vk.nego = n;
        return true;
    }
    case RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE: {
        if (!g_vk.ready) return false;
        *(const struct retro_hw_render_interface**)data =
            (const struct retro_hw_render_interface*)&g_vk.iface;
        return true;
    }
    default: return false;
    }
}

bool vk_host_active(void) { return g_vk.context_reset != NULL; }

// ---- interface callbacks the core uses ----------------------------------------------------------

static void set_image(void* handle, const struct retro_vulkan_image* image,
                      uint32_t num_semaphores, const VkSemaphore* semaphores, uint32_t src_queue_family) {
    (void)handle; (void)num_semaphores; (void)semaphores; (void)src_queue_family;
    if (!image) { g_vk.have_frame = false; return; }
    g_vk.last_view   = image->image_view;
    g_vk.last_image  = image->create_info.image;
    g_vk.last_format = image->create_info.format;
    g_vk.last_w      = 0;   // filled from the image extent isn't available here; tracked via av_info elsewhere
    g_vk.have_frame  = true;
    if (getenv("EMU_DEBUG_VKFMT")) { static VkFormat _lf = (VkFormat)-1;
        if (image->create_info.format != _lf) { _lf = image->create_info.format;
            fprintf(stderr, "vk_host: set_image format=%d layout=%d\n", image->create_info.format, image->image_layout); } }
}

static uint32_t get_sync_index(void* h) { (void)h; return 0; }
static uint32_t get_sync_index_mask(void* h) { (void)h; return 1u; }
static void set_command_buffers(void* h, uint32_t n, const VkCommandBuffer* c) { (void)h; (void)n; (void)c; }
static void wait_sync_index(void* h) { (void)h; if (vkDeviceWaitIdle_) vkDeviceWaitIdle_(g_vk.device); }
static void lock_queue(void* h) { (void)h; }
static void unlock_queue(void* h) { (void)h; }
static void set_signal_semaphore(void* h, VkSemaphore s) { (void)h; (void)s; }

// ---- device creation (via the negotiation interface) --------------------------------------------

// The core's DeviceCreateInfo won't enable VK_KHR_portability_subset, which MoltenVK requires. Wrap
// vkCreateDevice to append it.
static PFN_vkCreateDevice s_real_create_device;
static PFN_vkEnumerateDeviceExtensionProperties s_enum_dev_ext;

static bool gpu_has_extension(VkPhysicalDevice gpu, const char* name) {
    if (!s_enum_dev_ext) return false;
    uint32_t n = 0;
    s_enum_dev_ext(gpu, NULL, &n, NULL);
    if (!n) return false;
    VkExtensionProperties* props = malloc(sizeof(VkExtensionProperties) * n);
    s_enum_dev_ext(gpu, NULL, &n, props);
    bool found = false;
    for (uint32_t i = 0; i < n; i++) if (strcmp(props[i].extensionName, name) == 0) { found = true; break; }
    free(props);
    return found;
}

static VkDevice create_device_wrapper(VkPhysicalDevice gpu, void* opaque,
                                      const VkDeviceCreateInfo* ci) {
    (void)opaque;
    // MoltenVK requires VK_KHR_portability_subset on the device when it advertises it (newer builds);
    // older MoltenVK (1.1.x) doesn't advertise it and doesn't need it.
    bool add_portability = gpu_has_extension(gpu, "VK_KHR_portability_subset");
    uint32_t n = ci->enabledExtensionCount;
    const char** exts = malloc(sizeof(char*) * (n + 1));
    for (uint32_t i = 0; i < n; i++) exts[i] = ci->ppEnabledExtensionNames[i];
    if (add_portability) exts[n] = "VK_KHR_portability_subset";

    VkDeviceCreateInfo patched = *ci;
    patched.enabledExtensionCount = add_portability ? n + 1 : n;
    patched.ppEnabledExtensionNames = exts;

    VkDevice dev = VK_NULL_HANDLE;
    VkResult r = s_real_create_device(gpu, &patched, NULL, &dev);
    free(exts);
    if (r != VK_SUCCESS) { fprintf(stderr, "vk_host: vkCreateDevice failed (%d)\n", r); return VK_NULL_HANDLE; }
    return dev;
}

// Create the instance + device and hand the core its interface. Called after load_game, before run.
bool vk_host_create_context(void) {
    if (!g_vk.context_reset || !g_vk.gipa) return false;

    vkCreateInstance_ = GIPA(vkCreateInstance);
    if (!vkCreateInstance_) return false;

    const VkApplicationInfo* app = g_vk.nego && g_vk.nego->get_application_info
        ? g_vk.nego->get_application_info() : NULL;
    VkApplicationInfo default_app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                                      .apiVersion = VK_API_VERSION_1_1 };

    // Talking to MoltenVK directly (no Vulkan loader) — no portability_enumeration needed, and the
    // available MoltenVK may be old (1.1.x). Create a minimal instance.
    VkInstanceCreateInfo ici = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = app ? app : &default_app,
    };
    if (vkCreateInstance_(&ici, NULL, &g_vk.instance) != VK_SUCCESS) {
        fprintf(stderr, "vk_host: vkCreateInstance failed\n"); return false;
    }

    vkEnumeratePhysicalDevices_ = GIPA(vkEnumeratePhysicalDevices);
    vkGetDeviceProcAddr_ = GIPA(vkGetDeviceProcAddr);
    vkGetDeviceQueue_ = GIPA(vkGetDeviceQueue);
    uint32_t count = 0;
    vkEnumeratePhysicalDevices_(g_vk.instance, &count, NULL);
    if (count == 0) { fprintf(stderr, "vk_host: no Vulkan GPU\n"); return false; }
    VkPhysicalDevice gpus[8];
    if (count > 8) count = 8;
    vkEnumeratePhysicalDevices_(g_vk.instance, &count, gpus);
    g_vk.gpu = gpus[0];

    // Let the core build the device, wrapping vkCreateDevice to add portability_subset.
    struct retro_vulkan_context ctx = {0};
    s_real_create_device = GIPA(vkCreateDevice);
    s_enum_dev_ext = GIPA(vkEnumerateDeviceExtensionProperties);
    bool ok = false;
    if (g_vk.nego && g_vk.nego->interface_version >= 2 && g_vk.nego->create_device2) {
        ok = g_vk.nego->create_device2(&ctx, g_vk.instance, g_vk.gpu, VK_NULL_HANDLE,
                                       g_vk.gipa, create_device_wrapper, NULL);
    } else if (g_vk.nego && g_vk.nego->create_device) {
        // v1: no wrapper — hope the core enables portability_subset (may fail on MoltenVK).
        ok = g_vk.nego->create_device(&ctx, g_vk.instance, g_vk.gpu, VK_NULL_HANDLE, g_vk.gipa,
                                      NULL, 0, NULL, 0, NULL);
    }
    if (!ok || ctx.device == VK_NULL_HANDLE) { fprintf(stderr, "vk_host: create_device failed\n"); return false; }
    g_vk.device = ctx.device;
    g_vk.queue = ctx.queue;
    g_vk.queue_family = ctx.queue_family_index;

    // Resolve device functions for read-back.
    vkCreateCommandPool_ = GDPA(vkCreateCommandPool);
    vkAllocateCommandBuffers_ = GDPA(vkAllocateCommandBuffers);
    vkBeginCommandBuffer_ = GDPA(vkBeginCommandBuffer);
    vkEndCommandBuffer_ = GDPA(vkEndCommandBuffer);
    vkCmdPipelineBarrier_ = GDPA(vkCmdPipelineBarrier);
    vkCmdCopyImageToBuffer_ = GDPA(vkCmdCopyImageToBuffer);
    vkQueueSubmit_ = GDPA(vkQueueSubmit);
    vkQueueWaitIdle_ = GDPA(vkQueueWaitIdle);
    vkDeviceWaitIdle_ = GDPA(vkDeviceWaitIdle);
    vkCreateBuffer_ = GDPA(vkCreateBuffer);
    vkGetBufferMemoryRequirements_ = GDPA(vkGetBufferMemoryRequirements);
    vkAllocateMemory_ = GDPA(vkAllocateMemory);
    vkBindBufferMemory_ = GDPA(vkBindBufferMemory);
    vkMapMemory_ = GDPA(vkMapMemory);
    vkUnmapMemory_ = GDPA(vkUnmapMemory);
    vkFreeMemory_ = GDPA(vkFreeMemory);
    vkDestroyBuffer_ = GDPA(vkDestroyBuffer);
    vkFreeCommandBuffers_ = GDPA(vkFreeCommandBuffers);
    vkGetPhysicalDeviceMemoryProperties_ = GIPA(vkGetPhysicalDeviceMemoryProperties);

    VkCommandPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                                    .queueFamilyIndex = g_vk.queue_family,
                                    .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT };
    vkCreateCommandPool_(g_vk.device, &pci, NULL, &g_vk.cmd_pool);

    // Fill the interface the core will fetch via GET_HW_RENDER_INTERFACE.
    g_vk.iface.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
    g_vk.iface.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
    g_vk.iface.handle = &g_vk;
    g_vk.iface.instance = g_vk.instance;
    g_vk.iface.gpu = g_vk.gpu;
    g_vk.iface.device = g_vk.device;
    g_vk.iface.get_device_proc_addr = vkGetDeviceProcAddr_;
    g_vk.iface.get_instance_proc_addr = g_vk.gipa;
    g_vk.iface.queue = g_vk.queue;
    g_vk.iface.queue_index = g_vk.queue_family;
    g_vk.iface.set_image = set_image;
    g_vk.iface.get_sync_index = get_sync_index;
    g_vk.iface.get_sync_index_mask = get_sync_index_mask;
    g_vk.iface.set_command_buffers = set_command_buffers;
    g_vk.iface.wait_sync_index = wait_sync_index;
    g_vk.iface.lock_queue = lock_queue;
    g_vk.iface.unlock_queue = unlock_queue;
    g_vk.iface.set_signal_semaphore = set_signal_semaphore;

    g_vk.ready = true;
    if (g_vk.context_reset) g_vk.context_reset();   // tell the core its context is live
    fprintf(stderr, "vk_host: Vulkan context ready (MoltenVK)\n");
    return true;
}

// ---- read-back ----------------------------------------------------------------------------------

static uint32_t find_mem_type(uint32_t bits, VkMemoryPropertyFlags want) {
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties_(g_vk.gpu, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) return i;
    return 0;
}

// Copy the core's last image to an RGBA8888 (R,G,B,A) buffer. Returns false if no frame / failure.
bool vk_host_readback(uint32_t* out, uint32_t max_w, uint32_t max_h, uint32_t* w, uint32_t* h) {
    if (!g_vk.have_frame || !g_vk.last_image || !vkDeviceWaitIdle_) return false;
    // The core doesn't pass extent to set_image; the bridge tracks it from av_info (max) — we clamp.
    uint32_t iw = g_vk.last_w ? g_vk.last_w : max_w;
    uint32_t ih = g_vk.last_h ? g_vk.last_h : max_h;
    if (iw == 0 || ih == 0) return false;

    vkDeviceWaitIdle_(g_vk.device);

    // The core's scanout is not always RGBA8 — Beetle's HW renderer emits the native 15-bit PS1 output
    // as A1R5G5B5_PACK16 (2 bytes/px) during gameplay, and only RGBA8 (4 bytes/px) for the menu/boot.
    // vkCmdCopyImageToBuffer copies in the image's own format, so the staging buffer and the unpack loop
    // must match the real bytes-per-pixel or the frame comes out doubled (½ the stride) and mis-colored.
    uint32_t bpp = (g_vk.last_format == VK_FORMAT_A1R5G5B5_UNORM_PACK16) ? 2 : 4;
    VkDeviceSize size = (VkDeviceSize)iw * ih * bpp;
    VkBuffer buf; VkDeviceMemory mem;
    VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size,
                               .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                               .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
    if (vkCreateBuffer_(g_vk.device, &bci, NULL, &buf) != VK_SUCCESS) return false;
    VkMemoryRequirements req; vkGetBufferMemoryRequirements_(g_vk.device, buf, &req);
    VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size,
        .memoryTypeIndex = find_mem_type(req.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
    vkAllocateMemory_(g_vk.device, &mai, NULL, &mem);
    vkBindBufferMemory_(g_vk.device, buf, mem, 0);

    VkCommandBuffer cmd;
    VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = g_vk.cmd_pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    vkAllocateCommandBuffers_(g_vk.device, &cai, &cmd);
    VkCommandBufferBeginInfo cbi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                     .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    vkBeginCommandBuffer_(cmd, &cbi);

    // The core leaves the image in SHADER_READ_ONLY / GENERAL; transition to TRANSFER_SRC for copy.
    VkImageMemoryBarrier bar = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .oldLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcAccessMask = VK_ACCESS_SHADER_READ_BIT, .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
        .image = g_vk.last_image,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED };
    vkCmdPipelineBarrier_(cmd, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                          0, 0, NULL, 0, NULL, 1, &bar);
    VkBufferImageCopy region = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
                                 .imageExtent = { iw, ih, 1 } };
    vkCmdCopyImageToBuffer_(cmd, g_vk.last_image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buf, 1, &region);
    vkEndCommandBuffer_(cmd);
    VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
    vkQueueSubmit_(g_vk.queue, 1, &si, VK_NULL_HANDLE);
    vkQueueWaitIdle_(g_vk.queue);

    void* mapped = NULL;
    vkMapMemory_(g_vk.device, mem, 0, size, 0, &mapped);
    uint32_t cw = iw < max_w ? iw : max_w, ch = ih < max_h ? ih : max_h;
    const uint8_t* src = (const uint8_t*)mapped;
    if (g_vk.last_format == VK_FORMAT_A1R5G5B5_UNORM_PACK16) {
        // 16-bit packed: A in bit 15, R in 14..10, G in 9..5, B in 4..0. Expand each 5-bit channel to 8.
        for (uint32_t y = 0; y < ch; y++) {
            const uint16_t* row = (const uint16_t*)(src + (size_t)y * iw * 2);
            for (uint32_t x = 0; x < cw; x++) {
                uint16_t px = row[x];
                uint32_t r = (px >> 10) & 0x1F, g = (px >> 5) & 0x1F, b = px & 0x1F;
                uint32_t r8 = (r << 3) | (r >> 2), g8 = (g << 3) | (g >> 2), b8 = (b << 3) | (b >> 2);
                out[y * cw + x] = r8 | (g8 << 8) | (b8 << 16) | (0xFFu << 24);
            }
        }
    } else {
        // RGBA8 (R,G,B,A). B8G8R8A8 would need a swizzle, but Beetle's RGBA8 scanout is R-first here.
        for (uint32_t y = 0; y < ch; y++) {
            const uint8_t* prow = src + (size_t)y * iw * 4;
            for (uint32_t x = 0; x < cw; x++) {
                const uint8_t* p = prow + (size_t)x * 4;
                out[y * cw + x] = (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | (0xFFu << 24);
            }
        }
    }
    vkUnmapMemory_(g_vk.device, mem);
    *w = cw; *h = ch;

    vkFreeCommandBuffers_(g_vk.device, g_vk.cmd_pool, 1, &cmd);
    vkDestroyBuffer_(g_vk.device, buf, NULL);
    vkFreeMemory_(g_vk.device, mem, NULL);
    return true;
}

void vk_host_set_frame_size(uint32_t w, uint32_t h) { g_vk.last_w = w; g_vk.last_h = h; }
