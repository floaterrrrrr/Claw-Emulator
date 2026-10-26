// Copyright 2023-2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

#include "common/microprofile.h"
#include "common/settings.h"
#include "common/thread.h"
#include "core/frontend/emu_window.h"
#include "video_core/renderer_vulkan/vk_instance.h"
#include "video_core/renderer_vulkan/vk_platform.h"
#include "video_core/renderer_vulkan/vk_present_window.h"
#include "video_core/renderer_vulkan/vk_scheduler.h"
#include "video_core/renderer_vulkan/vk_swapchain.h"

#include <vk_mem_alloc.h>
#include "MobileThermal.hpp"
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if CLAW_ENABLE_METALFX
#include "SpatialUpscaleConfig.hpp"
#include "video_core/renderer_vulkan/vk_master_semaphore.h"
#include <vulkan/vulkan_metal.h>
#endif

MICROPROFILE_DEFINE(Vulkan_WaitPresent, "Vulkan", "Wait For Present", MP_RGB(128, 128, 128));

namespace Vulkan {

namespace {

bool CanBlitToSwapchain(const vk::PhysicalDevice& physical_device, vk::Format format) {
    const vk::FormatProperties props{physical_device.getFormatProperties(format)};
    return static_cast<bool>(props.optimalTilingFeatures & vk::FormatFeatureFlagBits::eBlitDst);
}

[[nodiscard]] vk::ImageSubresourceLayers MakeImageSubresourceLayers() {
    return vk::ImageSubresourceLayers{
        .aspectMask = vk::ImageAspectFlagBits::eColor,
        .mipLevel = 0,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };
}

[[nodiscard]] vk::ImageBlit MakeImageBlit(s32 frame_width, s32 frame_height, s32 swapchain_width,
                                          s32 swapchain_height) {
    return vk::ImageBlit{
        .srcSubresource = MakeImageSubresourceLayers(),
        .srcOffsets =
            std::array{
                vk::Offset3D{
                    .x = 0,
                    .y = 0,
                    .z = 0,
                },
                vk::Offset3D{
                    .x = frame_width,
                    .y = frame_height,
                    .z = 1,
                },
            },
        .dstSubresource = MakeImageSubresourceLayers(),
        .dstOffsets =
            std::array{
                vk::Offset3D{
                    .x = 0,
                    .y = 0,
                    .z = 0,
                },
                vk::Offset3D{
                    .x = swapchain_width,
                    .y = swapchain_height,
                    .z = 1,
                },
            },
    };
}

[[nodiscard]] vk::ImageCopy MakeImageCopy(u32 frame_width, u32 frame_height, u32 swapchain_width,
                                          u32 swapchain_height) {
    return vk::ImageCopy{
        .srcSubresource = MakeImageSubresourceLayers(),
        .srcOffset =
            vk::Offset3D{
                .x = 0,
                .y = 0,
                .z = 0,
            },
        .dstSubresource = MakeImageSubresourceLayers(),
        .dstOffset =
            vk::Offset3D{
                .x = 0,
                .y = 0,
                .z = 0,
            },
        .extent =
            vk::Extent3D{
                .width = std::min(frame_width, swapchain_width),
                .height = std::min(frame_height, swapchain_height),
                .depth = 1,
            },
    };
}

} // Anonymous namespace

PresentWindow::PresentWindow(Frontend::EmuWindow& emu_window_, const Instance& instance_,
                             Scheduler& scheduler_, bool low_refresh_rate_)
    : emu_window{emu_window_}, instance{instance_}, scheduler{scheduler_},
      low_refresh_rate{low_refresh_rate_},
      surface{CreateSurface(instance.GetInstance(), emu_window)}, next_surface{surface},
      swapchain{instance, emu_window.GetFramebufferLayout().width,
                emu_window.GetFramebufferLayout().height, surface, low_refresh_rate_},
      graphics_queue{instance.GetGraphicsQueue()}, present_renderpass{CreateRenderpass()},
      vsync_enabled{Settings::values.use_vsync.GetValue()},
      blit_supported{
          CanBlitToSwapchain(instance.GetPhysicalDevice(), swapchain.GetSurfaceFormat().format)},
      use_present_thread{Settings::values.async_presentation.GetValue()},
      last_render_surface{emu_window.GetWindowInfo().render_surface} {

    const u32 num_images = swapchain.GetImageCount();
    const vk::Device device = instance.GetDevice();

#if CLAW_ENABLE_METALFX
    if (const auto config = Claw::GetSpatialUpscaleConfig(); config && !config->failed.load()) {
        auto* timeline = dynamic_cast<MasterSemaphoreTimeline*>(scheduler.GetMasterSemaphore());
        upscale_context = Claw::MakeMetalFXContext(instance, timeline ? timeline->Handle()
                                                                    : vk::Semaphore{});
        if (!upscale_context && !Claw::MobileThermallyLimited()) Settings::values.resolution_factor.SetValue(4);
    }
#endif

    const vk::CommandPoolCreateInfo pool_info = {
        .flags = vk::CommandPoolCreateFlagBits::eResetCommandBuffer |
                 vk::CommandPoolCreateFlagBits::eTransient,
        .queueFamilyIndex = instance.GetGraphicsQueueFamilyIndex(),
    };
    command_pool = device.createCommandPool(pool_info);

    const vk::CommandBufferAllocateInfo alloc_info = {
        .commandPool = command_pool,
        .level = vk::CommandBufferLevel::ePrimary,
        .commandBufferCount = num_images,
    };
    const std::vector command_buffers = device.allocateCommandBuffers(alloc_info);

    swap_chain.resize(num_images);
    for (u32 i = 0; i < num_images; i++) {
        Frame& frame = swap_chain[i];
        frame.cmdbuf = command_buffers[i];
        frame.render_ready = device.createSemaphore({});
        frame.present_done = device.createFence({.flags = vk::FenceCreateFlagBits::eSignaled});
        free_queue.push(&frame);
    }

    if (instance.HasDebuggingToolAttached()) {
        for (u32 i = 0; i < num_images; ++i) {
            SetObjectName(device, swap_chain[i].cmdbuf, "Swapchain Command Buffer {}", i);
            SetObjectName(device, swap_chain[i].render_ready,
                          "Swapchain Semaphore: render_ready {}", i);
            SetObjectName(device, swap_chain[i].present_done, "Swapchain Fence: present_done {}",
                          i);
        }
    }

#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
    // Fences/semaphores already exist and are initially signaled. Allocate
    // each persistent presentation slot now, before starting its worker; no
    // scene-specific fence reset, dummy submit or device-idle wait is needed.
    auto initial_layout = emu_window.GetFramebufferLayout();
#if CLAW_ENABLE_METALFX
    initial_layout = RenderLayout(initial_layout);
#endif
    for (auto& frame : swap_chain) RecreateFrame(&frame, initial_layout.width, initial_layout.height);
#endif
    if (use_present_thread) {
        present_thread = std::jthread([this](std::stop_token token) { PresentThread(token); });
    }
}

PresentWindow::~PresentWindow() {
    scheduler.Finish();
    // The jthread member's destructor runs after this destructor body. Join here,
    // before freeing any resources the presentation worker can still access.
    if (present_thread.joinable()) {
        present_thread.request_stop();
        frame_cv.notify_all();
        present_thread.join();
    }
    const vk::Device device = instance.GetDevice();
    // If the window is destroyed before the next_surface is
    // consumed, make sure to destroy it here to prevent a
    // resource leak.
    if (next_surface && next_surface != surface) {
        instance.GetInstance().destroySurfaceKHR(next_surface);
        next_surface = vk::SurfaceKHR{};
    }
    device.destroyCommandPool(command_pool);
    device.destroyRenderPass(present_renderpass);
    for (auto& frame : swap_chain) {
#if CLAW_ENABLE_METALFX
        frame.metalfx.reset();
#endif
        device.destroyImageView(frame.image_view);
        device.destroyFramebuffer(frame.framebuffer);
        device.destroySemaphore(frame.render_ready);
        device.destroyFence(frame.present_done);
        vmaDestroyImage(instance.GetAllocator(), frame.image, frame.allocation);
    }
}

void PresentWindow::RecreateFrame(Frame* frame, u32 width, u32 height, [[maybe_unused]] bool allow_upscale) {
    vk::Device device = instance.GetDevice();
    frame->thermal_limited = Claw::MobileThermallyLimited();
#if CLAW_ENABLE_METALFX
    // The slot's presentation fence was waited before it reached this function.
    frame->metalfx.reset();
    frame->upscaled = false;
    bool use_upscaler = allow_upscale && upscale_context && Claw::SpatialUpscaleInputScale();
    const VkExportMetalObjectCreateInfoEXT export_info{
        .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT,
        .exportObjectType = VK_EXPORT_METAL_OBJECT_TYPE_METAL_TEXTURE_BIT_EXT};
#endif
    if (frame->framebuffer) {
        device.destroyFramebuffer(frame->framebuffer);
    }
    if (frame->image_view) {
        device.destroyImageView(frame->image_view);
    }
    if (frame->image) {
        vmaDestroyImage(instance.GetAllocator(), frame->image, frame->allocation);
    }

    const vk::Format format = swapchain.GetSurfaceFormat().format;
    auto image_usage = vk::ImageUsageFlagBits::eColorAttachment | vk::ImageUsageFlagBits::eTransferSrc;
#if CLAW_ENABLE_METALFX
    if (use_upscaler) {
        // MetalFX operates on logical render pixels, not the display surface's
        // Retina extent. MoltenVK can report a different surface extent after
        // layout/rotation; CopyToSwapchain scales the completed 4x image to it.
        const vk::Extent2D output{width * 2, height * 2};
        const auto required = upscale_context->InputUsage(format, width, height, output.width, output.height);
        if (required) image_usage = required;
        else use_upscaler = false;
    }
#endif
    const vk::ImageCreateInfo image_info = {
#if CLAW_ENABLE_METALFX
        .pNext = use_upscaler ? &export_info : nullptr,
        .flags = use_upscaler ? upscale_context->InputFlags() : vk::ImageCreateFlags{},
#endif
        .imageType = vk::ImageType::e2D,
        .format = format,
        .extent = {width, height, 1},
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = vk::SampleCountFlagBits::e1,
        .usage = image_usage,
    };

    const VmaAllocationCreateInfo alloc_info = {
#if CLAW_ENABLE_METALFX
        // Native Metal only sees these exported presentation images. Do not
        // expose VMA heap suballocations to an independent Metal command queue.
        .flags = VMA_ALLOCATION_CREATE_WITHIN_BUDGET_BIT |
                 (use_upscaler ? VmaAllocationCreateFlags{VMA_ALLOCATION_CREATE_DEDICATED_MEMORY_BIT}
                               : VmaAllocationCreateFlags{}),
#else
        .flags = VMA_ALLOCATION_CREATE_WITHIN_BUDGET_BIT,
#endif
        .usage = VMA_MEMORY_USAGE_AUTO_PREFER_DEVICE,
        .requiredFlags = 0,
        .preferredFlags = 0,
        .pool = VK_NULL_HANDLE,
        .pUserData = nullptr,
    };

    VkImage unsafe_image{};
    VkImageCreateInfo unsafe_image_info = static_cast<VkImageCreateInfo>(image_info);

    VkResult result = vmaCreateImage(instance.GetAllocator(), &unsafe_image_info, &alloc_info,
                                     &unsafe_image, &frame->allocation, nullptr);
#if CLAW_ENABLE_METALFX
    if (result != VK_SUCCESS && use_upscaler) {
        if (const auto config = Claw::GetSpatialUpscaleConfig())
            config->Fail("MoltenVK input allocation failed (VkResult " + std::to_string(result) + ")");
        // Optional interop allocations must not turn a recoverable allocation
        // failure into an abort. This frame can use the ordinary native blit;
        // the emulation thread applies native 4x on the following frame.
        use_upscaler = false;
        unsafe_image_info.pNext = nullptr;
        unsafe_image_info.flags = 0;
        auto native_alloc_info = alloc_info;
        native_alloc_info.flags = VMA_ALLOCATION_CREATE_WITHIN_BUDGET_BIT;
        result = vmaCreateImage(instance.GetAllocator(), &unsafe_image_info, &native_alloc_info,
                               &unsafe_image, &frame->allocation, nullptr);
    }
#endif
    if (result != VK_SUCCESS) [[unlikely]] {
        LOG_CRITICAL(Render_Vulkan, "Failed allocating texture with error {}", result);
        if (!allow_upscale) throw std::runtime_error("The screenshot texture could not be allocated.");
        UNREACHABLE();
    }
    frame->image = vk::Image{unsafe_image};

    const vk::ImageViewCreateInfo view_info = {
        .image = frame->image,
        .viewType = vk::ImageViewType::e2D,
        .format = format,
        .subresourceRange{
            .aspectMask = vk::ImageAspectFlagBits::eColor,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    frame->image_view = device.createImageView(view_info);

    const vk::FramebufferCreateInfo framebuffer_info = {
        .renderPass = present_renderpass,
        .attachmentCount = 1,
        .pAttachments = &frame->image_view,
        .width = width,
        .height = height,
        .layers = 1,
    };
    frame->framebuffer = instance.GetDevice().createFramebuffer(framebuffer_info);

    frame->width = width;
    frame->height = height;
#if CLAW_ENABLE_METALFX
    if (use_upscaler) {
        const vk::Extent2D output{width * 2, height * 2};
        frame->metalfx = upscale_context->MakeFrame(frame->image, width, height,
                                                    output.width, output.height);
        if (frame->metalfx) {
            const vk::Image output_image = frame->metalfx->OutputImage();
            scheduler.Record([output_image](vk::CommandBuffer cmdbuf) {
                const vk::ImageMemoryBarrier initialize{
                    .dstAccessMask = vk::AccessFlagBits::eTransferWrite,
                    .oldLayout = vk::ImageLayout::eUndefined,
                    .newLayout = vk::ImageLayout::eGeneral,
                    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                    .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                    .image = output_image,
                    .subresourceRange = {.aspectMask = vk::ImageAspectFlagBits::eColor,
                                         .levelCount = 1, .layerCount = 1}};
                cmdbuf.pipelineBarrier(vk::PipelineStageFlagBits::eTopOfPipe,
                                       vk::PipelineStageFlagBits::eTransfer, {}, {}, {}, initialize);
            });
        }
    }
#endif
}

#if CLAW_ENABLE_METALFX
Layout::FramebufferLayout PresentWindow::RenderLayout(const Layout::FramebufferLayout& output) const {
    const int input_scale = Claw::SpatialUpscaleInputScale();
    if (!upscale_context || !input_scale) return output;
    return Layout::SingleFrameLayout(output.width * input_scale / 4,
                                    output.height * input_scale / 4,
                                    output.bottom_screen_enabled, false);
}

void PresentWindow::PrepareUpscale(Frame* frame) {
    frame->upscaled = false;
    if (!frame->metalfx || !Claw::SpatialUpscaleInputScale()) return;
    scheduler.WaitWorker();
    frame->upscaled = frame->metalfx->Encode(frame->render_tick);
}
#endif

Frame* PresentWindow::GetRenderFrame() {
    MICROPROFILE_SCOPE(Vulkan_WaitPresent);

    // Wait for free presentation frames
    std::unique_lock lock{free_mutex};
    free_cv.wait(lock, [this] { return !free_queue.empty(); });

    // Take the frame from the queue
    Frame* frame = free_queue.front();
    free_queue.pop();

    vk::Device device = instance.GetDevice();
    vk::Result result{};

    const auto wait = [&]() {
        result = device.waitForFences(frame->present_done, false, std::numeric_limits<u64>::max());
        return result;
    };

    // Wait for the presentation to be finished so all frame resources are free
    while (wait() != vk::Result::eSuccess) {
        // Retry if the waiting times out
        if (result == vk::Result::eTimeout) {
            continue;
        }

        // eErrorInitializationFailed occurs on Mali GPU drivers due to them
        // using the ppoll() syscall which isn't correctly restarted after a signal,
        // we need to manually retry waiting in that case
        if (result == vk::Result::eErrorInitializationFailed) {
            continue;
        }
    }

    device.resetFences(frame->present_done);
    return frame;
}

void PresentWindow::Present(Frame* frame) {
    if (!use_present_thread) {
        scheduler.WaitWorker();
        CopyToSwapchain(frame);
        free_queue.push(frame);
        return;
    }

    scheduler.Record([this, frame](vk::CommandBuffer) {
        std::unique_lock lock{queue_mutex};
        present_queue.push(frame);
        frame_cv.notify_one();
    });
}

void PresentWindow::WaitPresent() {
    if (!use_present_thread) {
        return;
    }

    // Wait for the present queue to be empty
    {
        std::unique_lock queue_lock{queue_mutex};
        frame_cv.wait(queue_lock, [this] { return present_queue.empty(); });
    }

    // The above condition will be satisfied when the last frame is taken from the queue.
    // To ensure that frame has been presented as well take hold of the swapchain
    // mutex.
    std::scoped_lock swapchain_lock{swapchain_mutex};
}

void PresentWindow::PresentThread(std::stop_token token) {
    Common::SetCurrentThreadName("VulkanPresent");
    while (!token.stop_requested()) {
        std::unique_lock lock{queue_mutex};

        // Wait for presentation frames
        Common::CondvarWait(frame_cv, lock, token, [this] { return !present_queue.empty(); });
        if (token.stop_requested()) {
            return;
        }

        // Take the frame and notify anyone waiting
        Frame* frame = present_queue.front();
        present_queue.pop();
        frame_cv.notify_one();

        // By exchanging the lock ownership we take the swapchain lock
        // before the queue lock goes out of scope. This way the swapchain
        // lock in WaitPresent is guaranteed to occur after here.
        std::exchange(lock, std::unique_lock{swapchain_mutex});

        CopyToSwapchain(frame);

        // Free the frame for reuse
        std::scoped_lock fl{free_mutex};
        free_queue.push(frame);
        free_cv.notify_one();
    }
}

void PresentWindow::NotifySurfaceChanged() {
#ifdef ANDROID
    std::scoped_lock lock{recreate_surface_mutex};

    // surfaceChanged() may notify us that a surface has changed
    // for the same surface multiple times. If that is the case
    // skip creating the surface again as that would cause a
    // vulkan ErrorNativeWindowInUseKHR.
    void* const render_surface = emu_window.GetWindowInfo().render_surface;
    if (render_surface == last_render_surface) {
        return;
    }
    last_render_surface = render_surface;

    // If an earlier notification produced a surface that CopyToSwapchain() has not consumed yet,
    // release it rather than just overwritting its handle and causing a leak.
    if (next_surface && next_surface != surface) {
        instance.GetInstance().destroySurfaceKHR(next_surface);
        next_surface = vk::SurfaceKHR{};
    }

    next_surface = CreateSurface(instance.GetInstance(), emu_window);
    recreate_surface_cv.notify_one();
#endif
}

void PresentWindow::CopyToSwapchain(Frame* frame) {
    // Output surface size remains 4x when its render input is 2x.
    const auto& output_layout = emu_window.GetFramebufferLayout();
    const u32 output_width = output_layout.width;
    const u32 output_height = output_layout.height;
    const auto recreate_swapchain = [&] {
#ifdef ANDROID
        {
            std::unique_lock lock{recreate_surface_mutex};
            recreate_surface_cv.wait(lock, [this]() { return surface != next_surface; });
            surface = next_surface;
        }
#endif
        std::scoped_lock submit_lock{scheduler.submit_mutex};
        graphics_queue.waitIdle();
        swapchain.Create(output_width, output_height, surface, low_refresh_rate);
    };

#ifndef ANDROID
    const bool use_vsync = Settings::values.use_vsync.GetValue();
    const bool size_changed =
        swapchain.GetWidth() != output_width || swapchain.GetHeight() != output_height;
    const bool vsync_changed = vsync_enabled != use_vsync;
    if (vsync_changed || size_changed) [[unlikely]] {
        vsync_enabled = use_vsync;
        recreate_swapchain();
    }
#endif

    while (!swapchain.AcquireNextImage()) {
        recreate_swapchain();
    }

    const vk::Image swapchain_image = swapchain.Image();

    const vk::CommandBufferBeginInfo begin_info = {
        .flags = vk::CommandBufferUsageFlagBits::eOneTimeSubmit,
    };
    const vk::CommandBuffer cmdbuf = frame->cmdbuf;
    cmdbuf.begin(begin_info);

    const vk::Extent2D extent = swapchain.GetExtent();
    vk::Image source_image = frame->image;
    vk::ImageLayout source_layout = vk::ImageLayout::eTransferSrcOptimal;
    u32 source_width = frame->width, source_height = frame->height;
    vk::AccessFlags source_access = vk::AccessFlagBits::eColorAttachmentWrite;
#if CLAW_ENABLE_METALFX
    if (frame->upscaled) {
        source_image = frame->metalfx->OutputImage();
        source_layout = vk::ImageLayout::eGeneral;
        const auto upscaled_extent = frame->metalfx->OutputExtent();
        source_width = upscaled_extent.width;
        source_height = upscaled_extent.height;
        source_access = vk::AccessFlagBits::eMemoryWrite;
    }
#endif
    const std::array pre_barriers{
        vk::ImageMemoryBarrier{
            .srcAccessMask = vk::AccessFlagBits::eNone,
            .dstAccessMask = vk::AccessFlagBits::eTransferWrite,
            .oldLayout = vk::ImageLayout::eUndefined,
            .newLayout = vk::ImageLayout::eTransferDstOptimal,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = swapchain_image,
            .subresourceRange{
                .aspectMask = vk::ImageAspectFlagBits::eColor,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = VK_REMAINING_ARRAY_LAYERS,
            },
        },
        vk::ImageMemoryBarrier{
            .srcAccessMask = source_access,
            .dstAccessMask = vk::AccessFlagBits::eTransferRead,
            .oldLayout = source_layout,
            .newLayout = source_layout,
            .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
            .image = source_image,
            .subresourceRange{
                .aspectMask = vk::ImageAspectFlagBits::eColor,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = VK_REMAINING_ARRAY_LAYERS,
            },
        },
    };
    const vk::ImageMemoryBarrier post_barrier{
        .srcAccessMask = vk::AccessFlagBits::eTransferWrite,
        .dstAccessMask = vk::AccessFlagBits::eMemoryRead,
        .oldLayout = vk::ImageLayout::eTransferDstOptimal,
        .newLayout = vk::ImageLayout::ePresentSrcKHR,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = swapchain_image,
        .subresourceRange{
            .aspectMask = vk::ImageAspectFlagBits::eColor,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = VK_REMAINING_ARRAY_LAYERS,
        },
    };

    cmdbuf.pipelineBarrier(vk::PipelineStageFlagBits::eAllCommands,
                           vk::PipelineStageFlagBits::eTransfer, vk::DependencyFlagBits::eByRegion,
                           {}, {}, pre_barriers);

    // The frame uses the swapchain format. Equal-sized images need only a copy:
    // avoid invoking a scaling/filtering blit for every full-resolution screen.
    const bool same_size = source_width == extent.width && source_height == extent.height;
    if (same_size || !blit_supported) {
        cmdbuf.copyImage(source_image, source_layout, swapchain_image,
                         vk::ImageLayout::eTransferDstOptimal,
                         MakeImageCopy(source_width, source_height, extent.width, extent.height));
    } else {
        cmdbuf.blitImage(source_image, source_layout, swapchain_image,
                         vk::ImageLayout::eTransferDstOptimal,
                         MakeImageBlit(source_width, source_height, extent.width, extent.height),
                         Settings::values.filter_mode.GetValue() ? vk::Filter::eLinear
                                                                 : vk::Filter::eNearest);
    }

    cmdbuf.pipelineBarrier(vk::PipelineStageFlagBits::eAllCommands,
                           vk::PipelineStageFlagBits::eAllCommands,
                           vk::DependencyFlagBits::eByRegion, {}, {}, post_barrier);

    cmdbuf.end();

    static constexpr std::array<vk::PipelineStageFlags, 3> wait_stage_masks = {
        // The acquired image and rendered frame are first accessed by the
        // transfer command, not by a color-attachment/graphics stage.
        vk::PipelineStageFlagBits::eTransfer,
        vk::PipelineStageFlagBits::eTransfer,
        vk::PipelineStageFlagBits::eTransfer,
    };

    const vk::Semaphore present_ready = swapchain.GetPresentReadySemaphore();
    const vk::Semaphore image_acquired = swapchain.GetImageAcquiredSemaphore();
    std::array<vk::Semaphore, 3> wait_semaphores = {image_acquired, frame->render_ready, {}};
    std::array<u64, 3> wait_values{};
    u32 wait_count = 2;
    vk::TimelineSemaphoreSubmitInfo timeline_info{};
    const u64 signal_value = 0; // The presentation-ready semaphore remains binary.
#if CLAW_ENABLE_METALFX
    if (frame->upscaled) {
        wait_semaphores[2] = frame->metalfx->CompletionSemaphore();
        wait_values[2] = frame->metalfx->CompletionValue();
        wait_count = 3;
        timeline_info.waitSemaphoreValueCount = wait_count;
        timeline_info.pWaitSemaphoreValues = wait_values.data();
        timeline_info.signalSemaphoreValueCount = 1;
        timeline_info.pSignalSemaphoreValues = &signal_value;
    }
#else
    (void)wait_values;
    (void)signal_value;
#endif

    vk::SubmitInfo submit_info = {
        .pNext = wait_count == 3 ? &timeline_info : nullptr,
        .waitSemaphoreCount = wait_count,
        .pWaitSemaphores = wait_semaphores.data(),
        .pWaitDstStageMask = wait_stage_masks.data(),
        .commandBufferCount = 1u,
        .pCommandBuffers = &cmdbuf,
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &present_ready,
    };

    std::scoped_lock submit_lock{scheduler.submit_mutex, recreate_surface_mutex};

    try {
        graphics_queue.submit(submit_info, frame->present_done);
    } catch (vk::DeviceLostError& err) {
        LOG_CRITICAL(Render_Vulkan, "Device lost during present submit: {}", err.what());
        UNREACHABLE();
    }

    swapchain.Present();
}

vk::RenderPass PresentWindow::CreateRenderpass() {
    const vk::AttachmentReference color_ref = {
        .attachment = 0,
        .layout = vk::ImageLayout::eGeneral,
    };

    const vk::SubpassDescription subpass = {
        .pipelineBindPoint = vk::PipelineBindPoint::eGraphics,
        .inputAttachmentCount = 0,
        .pInputAttachments = nullptr,
        .colorAttachmentCount = 1u,
        .pColorAttachments = &color_ref,
        .pResolveAttachments = 0,
        .pDepthStencilAttachment = nullptr,
    };

    const vk::AttachmentDescription color_attachment = {
        .format = swapchain.GetSurfaceFormat().format,
        .loadOp = vk::AttachmentLoadOp::eClear,
        .storeOp = vk::AttachmentStoreOp::eStore,
        .stencilLoadOp = vk::AttachmentLoadOp::eDontCare,
        .stencilStoreOp = vk::AttachmentStoreOp::eDontCare,
        .initialLayout = vk::ImageLayout::eUndefined,
        .finalLayout = vk::ImageLayout::eTransferSrcOptimal,
    };

    const vk::RenderPassCreateInfo renderpass_info = {
        .attachmentCount = 1,
        .pAttachments = &color_attachment,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 0,
        .pDependencies = nullptr,
    };

    return instance.GetDevice().createRenderPass(renderpass_info);
}

} // namespace Vulkan
