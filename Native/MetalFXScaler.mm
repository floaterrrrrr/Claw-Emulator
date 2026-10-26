// SPDX-License-Identifier: GPL-3.0-or-later
#include "MetalFXScaler.hpp"
#include "MetalFXSpatial.hpp"
#include "SpatialUpscaleConfig.hpp"
#include "video_core/renderer_vulkan/vk_instance.h"
#include <vulkan/vulkan_metal.h>
#include <vk_mem_alloc.h>
#include <exception>

namespace Claw {
namespace {
class SpatialFrame final : public MetalFXFrame {
public:
    SpatialFrame(const Vulkan::Instance& instance_, std::shared_ptr<SpatialUpscaleConfig> config_,
                 id<MTLCommandQueue> queue_, id<MTLSharedEvent> rendered_)
        : instance{instance_}, config{std::move(config_)}, queue{queue_}, rendered{rendered_} {}
    ~SpatialFrame() override {
        input_texture = nil;
        output_texture = nil;
        finished = nil;
        if (completion) instance.GetDevice().destroySemaphore(completion);
        if (image) vmaDestroyImage(instance.GetAllocator(), image, allocation);
    }
    bool Initialize(PFN_vkExportMetalObjectsEXT export_objects, vk::Image input,
                    u32 width, u32 height, u32 output_width, u32 output_height) {
        extent = SpatialExtent::For2x(width, height, output_width, output_height);
        if (!extent) return Fail("MetalFX requires exact 2x to 4x logical bounds");
        VkExportMetalTextureInfoEXT input_info{
            .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_TEXTURE_INFO_EXT,
            .image = input, .plane = VK_IMAGE_ASPECT_COLOR_BIT};
        VkExportMetalObjectsInfoEXT input_export{
            .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT, .pNext = &input_info};
        export_objects(instance.GetDevice(), &input_export);
        input_texture = input_info.mtlTexture;
        if (!input_texture) return Fail("MoltenVK input texture export failed");
        if (input_texture.width != width || input_texture.height != height ||
            input_texture.textureType != MTLTextureType2D || input_texture.sampleCount != 1)
            return Fail("MoltenVK input texture bounds or sample count mismatch");
        if (!textures.Initialize(queue.device, input_texture.pixelFormat, extent))
            return Fail(textures.Error());

        // Only these exported presentation images need standalone allocations.
        // Guest texture cache images keep their existing logical sizes and heaps.
        const VkExportMetalObjectCreateInfoEXT texture_export{
            .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT,
            .exportObjectType = VK_EXPORT_METAL_OBJECT_TYPE_METAL_TEXTURE_BIT_EXT};
        const VkImageCreateInfo image_info{
            .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .pNext = &texture_export,
            .imageType = VK_IMAGE_TYPE_2D,
            .format = input_texture.pixelFormat == MTLPixelFormatBGRA8Unorm
                          ? VK_FORMAT_B8G8R8A8_UNORM : VK_FORMAT_R8G8B8A8_UNORM,
            .extent = {output_width, output_height, 1}, .mipLevels = 1, .arrayLayers = 1,
            .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
            .usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            .sharingMode = VK_SHARING_MODE_EXCLUSIVE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED};
        const VmaAllocationCreateInfo allocation_info{
            .flags = VMA_ALLOCATION_CREATE_WITHIN_BUDGET_BIT | VMA_ALLOCATION_CREATE_DEDICATED_MEMORY_BIT,
            .usage = VMA_MEMORY_USAGE_AUTO_PREFER_DEVICE};
        const VkResult result = vmaCreateImage(instance.GetAllocator(), &image_info, &allocation_info,
                                               &image, &allocation, nullptr);
        if (result != VK_SUCCESS)
            return Fail("MoltenVK output allocation failed (VkResult " + std::to_string(result) + ")");
        VkExportMetalTextureInfoEXT output_info{
            .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_TEXTURE_INFO_EXT,
            .image = image, .plane = VK_IMAGE_ASPECT_COLOR_BIT};
        VkExportMetalObjectsInfoEXT output_export{
            .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT, .pNext = &output_info};
        export_objects(instance.GetDevice(), &output_export);
        output_texture = output_info.mtlTexture;
        if (!output_texture) return Fail("MoltenVK output texture export failed");

        const VkExportMetalObjectCreateInfoEXT event_export{
            .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT,
            .exportObjectType = VK_EXPORT_METAL_OBJECT_TYPE_METAL_SHARED_EVENT_BIT_EXT};
        const vk::SemaphoreTypeCreateInfo type_info{
            .pNext = &event_export, .semaphoreType = vk::SemaphoreType::eTimeline, .initialValue = 0};
        completion = instance.GetDevice().createSemaphore({.pNext = &type_info});
        VkExportMetalSharedEventInfoEXT event_info{
            .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_SHARED_EVENT_INFO_EXT, .semaphore = completion};
        VkExportMetalObjectsInfoEXT event_objects{
            .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT, .pNext = &event_info};
        export_objects(instance.GetDevice(), &event_objects);
        finished = event_info.mtlSharedEvent;
        return finished != nil || Fail("MoltenVK completion event export failed");
    }
    bool Encode(u64 render_tick) override {
        if (config->failed.load()) return false;
        const u64 next = value + 1;
        const auto token = config;
        id<MTLSharedEvent> completion_event = finished;
        const bool submitted = textures.Encode(queue, input_texture, output_texture,
            rendered, render_tick, finished, next, ^(id<MTLCommandBuffer> command) {
                if (command.status == MTLCommandBufferStatusError) {
                    const char* reason = command.error.localizedDescription.UTF8String;
                    token->Fail(std::string{"Metal GPU execution failed: "} + (reason ? reason : "unknown error"));
                    // A failed command must not leave Vulkan waiting forever.
                    if (completion_event.signaledValue < next)
                        completion_event.signaledValue = next;
                }
            });
        if (!submitted) return Fail(textures.Error());
        value = next;
        config->encoded.store(true);
        return true;
    }
    vk::Image OutputImage() const override { return vk::Image{image}; }
    vk::Extent2D OutputExtent() const override { return {extent.output_width, extent.output_height}; }
    vk::Semaphore CompletionSemaphore() const override { return completion; }
    u64 CompletionValue() const override { return value; }
private:
    bool Fail(std::string reason) { config->Fail(std::move(reason)); return false; }
    const Vulkan::Instance& instance;
    std::shared_ptr<SpatialUpscaleConfig> config;
    id<MTLCommandQueue> queue;
    id<MTLSharedEvent> rendered;
    id<MTLSharedEvent> finished;
    id<MTLTexture> input_texture;
    id<MTLTexture> output_texture;
    SpatialTextures textures;
    SpatialExtent extent{};
    VkImage image{};
    VmaAllocation allocation{};
    vk::Semaphore completion{};
    u64 value{};
};

class SpatialContext final : public MetalFXContext {
public:
    explicit SpatialContext(const Vulkan::Instance& instance_,
                            std::shared_ptr<SpatialUpscaleConfig> config_)
        : instance{instance_}, config{std::move(config_)} {}
    bool Initialize(vk::Semaphore render_timeline) {
        export_objects = reinterpret_cast<PFN_vkExportMetalObjectsEXT>(
            VULKAN_HPP_DEFAULT_DISPATCHER.vkGetDeviceProcAddr(instance.GetDevice(),
                                                            "vkExportMetalObjectsEXT"));
        if (!export_objects || !render_timeline) {
            config->Fail("MoltenVK texture/event export API unavailable"); return false;
        }
        VkExportMetalSharedEventInfoEXT event_info{
            .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_SHARED_EVENT_INFO_EXT,
            .semaphore = render_timeline};
        VkExportMetalDeviceInfoEXT device_info{
            .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_DEVICE_INFO_EXT, .pNext = &event_info};
        VkExportMetalObjectsInfoEXT objects{
            .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECTS_INFO_EXT, .pNext = &device_info};
        export_objects(instance.GetDevice(), &objects);
        device = device_info.mtlDevice;
        rendered = event_info.mtlSharedEvent;
        if (!SupportsSpatialScaler(device)) { config->Fail("MetalFX unsupported by graphics device"); return false; }
        if (!rendered) { config->Fail("MoltenVK render event export failed"); return false; }
        queue = [device newCommandQueue];
        queue.label = @"Claw MetalFX presentation";
        if (!queue) { config->Fail("Metal presentation queue allocation failed"); return false; }
        return true;
    }
    vk::ImageUsageFlags InputUsage(vk::Format format, u32 width, u32 height,
                                  u32 output_width, u32 output_height) override {
        if (format != vk::Format::eB8G8R8A8Unorm && format != vk::Format::eR8G8B8A8Unorm) {
            config->Fail("Unsupported MetalFX presentation format: " + vk::to_string(format));
            return {};
        }
        if (!SpatialExtent::For2x(width, height, output_width, output_height)) {
            config->Fail("MetalFX bounds: input " + std::to_string(width) + "x" + std::to_string(height) +
                         ", output " + std::to_string(output_width) + "x" + std::to_string(output_height));
            return {};
        }
        // MoltenVK supplies a blit source, not the scaler's internal resources.
        return vk::ImageUsageFlagBits::eColorAttachment | vk::ImageUsageFlagBits::eTransferSrc;
    }
    vk::ImageCreateFlags InputFlags() const override { return {}; }
    std::unique_ptr<MetalFXFrame> MakeFrame(vk::Image input, u32 width, u32 height,
                                         u32 output_width, u32 output_height) override {
        @autoreleasepool {
            try {
                auto frame = std::make_unique<SpatialFrame>(instance, config, queue, rendered);
                if (frame->Initialize(export_objects, input, width, height, output_width, output_height))
                    return frame;
            } catch (const std::exception& error) {
                config->Fail(std::string{"MetalFX initialization failed: "} + error.what());
            }
            return nullptr;
        }
    }
private:
    const Vulkan::Instance& instance;
    std::shared_ptr<SpatialUpscaleConfig> config;
    PFN_vkExportMetalObjectsEXT export_objects{};
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLSharedEvent> rendered;
};
} // namespace

std::unique_ptr<MetalFXContext> MakeMetalFXContext(const Vulkan::Instance& instance,
                                                vk::Semaphore render_timeline) {
    const auto config = GetSpatialUpscaleConfig();
    if (!config || config->failed.load()) return nullptr;
    @autoreleasepool {
        if (instance.IsMetalObjectsSupported() && instance.IsTimelineSemaphoreSupported()) {
            auto context = std::make_unique<SpatialContext>(instance, config);
            if (context->Initialize(render_timeline)) return context;
        } else {
            config->Fail("MoltenVK metal objects or timeline semaphores unavailable");
        }
        return nullptr;
    }
}
} // namespace Claw
