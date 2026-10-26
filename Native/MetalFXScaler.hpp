// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <memory>
#include "common/common_types.h"
#include "video_core/renderer_vulkan/vk_common.h"

namespace Vulkan { class Instance; }
namespace Claw {
class MetalFXFrame {
public:
    virtual ~MetalFXFrame() = default;
    // Called after the scheduler submitted both screen draws; never waits on the CPU.
    virtual bool Encode(u64 render_tick) = 0;
    virtual vk::Image OutputImage() const = 0;
    virtual vk::Extent2D OutputExtent() const = 0;
    virtual vk::Semaphore CompletionSemaphore() const = 0;
    virtual u64 CompletionValue() const = 0;
};
class MetalFXContext {
public:
    virtual ~MetalFXContext() = default;
    virtual vk::ImageUsageFlags InputUsage(vk::Format format, u32 width, u32 height,
                                          u32 output_width, u32 output_height) = 0;
    virtual vk::ImageCreateFlags InputFlags() const = 0;
    virtual std::unique_ptr<MetalFXFrame> MakeFrame(vk::Image input, u32 width, u32 height,
                                                 u32 output_width, u32 output_height) = 0;
};
std::unique_ptr<MetalFXContext> MakeMetalFXContext(const Vulkan::Instance& instance,
                                                vk::Semaphore render_timeline);
} // namespace Claw
