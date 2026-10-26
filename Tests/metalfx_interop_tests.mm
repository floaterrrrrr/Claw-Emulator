// SPDX-License-Identifier: GPL-3.0-or-later
#include "MetalFXScaler.hpp"
#include "MetalFXSpatial.hpp"
#include "SpatialUpscaleConfig.hpp"
#include "MetalFXPattern.hpp"
#include "video_core/renderer_vulkan/vk_instance.h"
#include <vulkan/vulkan_metal.h>
#define VMA_IMPLEMENTATION
#include <vk_mem_alloc.h>
#include <dlfcn.h>
#include <vector>

VULKAN_HPP_DEFAULT_DISPATCH_LOADER_DYNAMIC_STORAGE
// This fixture provides only Instance's minimal Vulkan ownership. The actual
// production MetalFX bridge and allocator are compiled unchanged below it.
namespace Vulkan { Instance::~Instance() = default; }

class TestInstance final : public Vulkan::Instance {
public:
    explicit TestInstance(const char* path) : Vulkan::Instance{NoInit{}} {
        driver = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        assert(driver);
        auto get_proc = reinterpret_cast<PFN_vkGetInstanceProcAddr>(dlsym(driver, "vkGetInstanceProcAddr"));
        assert(get_proc);
        VULKAN_HPP_DEFAULT_DISPATCHER.init(get_proc);
        // Portability enumeration belongs to the Vulkan loader on some
        // drivers. Direct MoltenVK loading must not request an absent extension.
        std::vector<const char*> extensions;
        for (const auto& extension : vk::enumerateInstanceExtensionProperties())
            if (std::string_view{extension.extensionName.data()} == VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)
                extensions.push_back(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
        const vk::ApplicationInfo app{.pApplicationName = "Claw MetalFX interop test", .apiVersion = VK_API_VERSION_1_1};
        instance = vk::createInstanceUnique({.flags = extensions.empty() ? vk::InstanceCreateFlags{}
                : vk::InstanceCreateFlagBits::eEnumeratePortabilityKHR,
            .pApplicationInfo = &app, .enabledExtensionCount = static_cast<uint32_t>(extensions.size()),
            .ppEnabledExtensionNames = extensions.data()});
        VULKAN_HPP_DEFAULT_DISPATCHER.init(*instance);
        physical_devices = instance->enumeratePhysicalDevices();
        assert(!physical_devices.empty());
        physical_device = physical_devices.front();
        const auto families = physical_device.getQueueFamilyProperties();
        for (unsigned i = 0; i < families.size(); ++i)
            if (families[i].queueFlags & vk::QueueFlagBits::eGraphics) { queue_family_index = i; break; }
        const float priority = 1;
        const vk::DeviceQueueCreateInfo queue_info{.queueFamilyIndex = queue_family_index, .queueCount = 1, .pQueuePriorities = &priority};
        constexpr std::array device_extensions{VK_KHR_PORTABILITY_SUBSET_EXTENSION_NAME,
            VK_KHR_TIMELINE_SEMAPHORE_EXTENSION_NAME, VK_EXT_METAL_OBJECTS_EXTENSION_NAME};
        const vk::PhysicalDeviceTimelineSemaphoreFeatures timeline{.timelineSemaphore = true};
        device = physical_device.createDeviceUnique({.pNext = &timeline, .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_info, .enabledExtensionCount = device_extensions.size(),
            .ppEnabledExtensionNames = device_extensions.data()});
        VULKAN_HPP_DEFAULT_DISPATCHER.init(*device);
        graphics_queue = device->getQueue(queue_family_index, 0);
        metal_objects = timeline_semaphores = true;
        const VmaVulkanFunctions functions{.vkGetInstanceProcAddr = get_proc,
            .vkGetDeviceProcAddr = VULKAN_HPP_DEFAULT_DISPATCHER.vkGetDeviceProcAddr};
        const VmaAllocatorCreateInfo info{.physicalDevice = physical_device, .device = *device,
            .pVulkanFunctions = &functions, .instance = *instance, .vulkanApiVersion = VK_API_VERSION_1_1};
        assert(vmaCreateAllocator(&info, &allocator) == VK_SUCCESS);
    }
    ~TestInstance() override {
        device->waitIdle();
        vmaDestroyAllocator(allocator);
        device.reset();
        instance.reset();
        dlclose(driver);
    }
private:
    void* driver{};
};

struct Slot {
    unsigned width{};
    VkImage input{};
    VmaAllocation input_allocation{};
    VkImage presentation{};
    VmaAllocation presentation_allocation{};
    vk::Extent2D presentation_extent{};
    VkBuffer buffer{};
    VmaAllocation buffer_allocation{};
    void* mapped{};
    vk::UniqueImageView view;
    vk::UniqueFramebuffer framebuffer;
    vk::CommandBuffer render, copy;
    vk::UniqueFence done;
    std::unique_ptr<Claw::MetalFXFrame> scaler;
};
int main(int argc, const char** argv) {
    assert(argc == 2);
    @autoreleasepool {
        if (!Claw::SupportsSpatialScaler(MTLCreateSystemDefaultDevice())) {
            std::cout << "SKIP: MoltenVK/MetalFX interop requires an exposed Metal GPU\n";
            return 0;
        }
        TestInstance instance{argv[1]};
        const auto device = instance.GetDevice();
        const auto allocator = instance.GetAllocator();
        const auto queue = instance.GetGraphicsQueue();
        const VkExportMetalObjectCreateInfoEXT export_event{
            .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT,
            .exportObjectType = VK_EXPORT_METAL_OBJECT_TYPE_METAL_SHARED_EVENT_BIT_EXT};
        const vk::SemaphoreTypeCreateInfo timeline_type{.pNext = &export_event,
            .semaphoreType = vk::SemaphoreType::eTimeline, .initialValue = 0};
        auto rendered = device.createSemaphoreUnique({.pNext = &timeline_type});
        Claw::ConfigureSpatialUpscale(2);
        std::array<std::unique_ptr<Claw::MetalFXContext>, 2> contexts{
            Claw::MakeMetalFXContext(instance, *rendered), Claw::MakeMetalFXContext(instance, *rendered)};
        if (!contexts[0] || !contexts[1]) std::cerr << Claw::SpatialUpscaleFailureReason() << std::endl;
        assert(contexts[0] && contexts[1]);
        auto pool = device.createCommandPoolUnique({.flags = vk::CommandPoolCreateFlagBits::eResetCommandBuffer,
            .queueFamilyIndex = instance.GetGraphicsQueueFamilyIndex()});
        const auto commands = device.allocateCommandBuffers({.commandPool = *pool,
            .level = vk::CommandBufferLevel::ePrimary, .commandBufferCount = 12});
        const vk::AttachmentDescription attachment{.format = vk::Format::eB8G8R8A8Unorm,
            .samples = vk::SampleCountFlagBits::e1, .loadOp = vk::AttachmentLoadOp::eClear,
            .storeOp = vk::AttachmentStoreOp::eStore, .initialLayout = vk::ImageLayout::eUndefined,
            .finalLayout = vk::ImageLayout::eTransferSrcOptimal};
        const vk::AttachmentReference reference{.attachment = 0, .layout = vk::ImageLayout::eColorAttachmentOptimal};
        const vk::SubpassDescription subpass{.pipelineBindPoint = vk::PipelineBindPoint::eGraphics,
            .colorAttachmentCount = 1, .pColorAttachments = &reference};
        auto pass = device.createRenderPassUnique({.attachmentCount = 1, .pAttachments = &attachment,
            .subpassCount = 1, .pSubpasses = &subpass});
        std::array<Slot, 6> slots{};
        for (unsigned i = 0; i < slots.size(); ++i) {
            auto& slot = slots[i];
            slot.width = i < 3 ? 800 : 640;
            auto& context = contexts[i < 3 ? 0 : 1];
            const auto usage = context->InputUsage(vk::Format::eB8G8R8A8Unorm, slot.width, 480, slot.width * 2, 960);
            assert(usage);
            const VkExportMetalObjectCreateInfoEXT export_texture{
                .sType = VK_STRUCTURE_TYPE_EXPORT_METAL_OBJECT_CREATE_INFO_EXT,
                .exportObjectType = VK_EXPORT_METAL_OBJECT_TYPE_METAL_TEXTURE_BIT_EXT};
            const VkImageCreateInfo image_info{.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                .pNext = &export_texture, .imageType = VK_IMAGE_TYPE_2D, .format = VK_FORMAT_B8G8R8A8_UNORM,
                .extent = {slot.width, 480, 1}, .mipLevels = 1, .arrayLayers = 1,
                .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
                .usage = static_cast<VkImageUsageFlags>(usage)};
            const VmaAllocationCreateInfo allocation_info{
                .flags = VMA_ALLOCATION_CREATE_DEDICATED_MEMORY_BIT | VMA_ALLOCATION_CREATE_WITHIN_BUDGET_BIT,
                .usage = VMA_MEMORY_USAGE_AUTO_PREFER_DEVICE};
            assert(vmaCreateImage(allocator, &image_info, &allocation_info,
                &slot.input, &slot.input_allocation, nullptr) == VK_SUCCESS);
            slot.scaler = context->MakeFrame(vk::Image{slot.input}, slot.width, 480, slot.width * 2, 960);
            if (!slot.scaler) std::cerr << Claw::SpatialUpscaleFailureReason() << std::endl;
            assert(slot.scaler && slot.scaler->OutputExtent().width == slot.width * 2);
            slot.view = device.createImageViewUnique({.image = vk::Image{slot.input}, .viewType = vk::ImageViewType::e2D,
                .format = vk::Format::eB8G8R8A8Unorm, .subresourceRange = {.aspectMask = vk::ImageAspectFlagBits::eColor,
                    .levelCount = 1, .layerCount = 1}});
            slot.framebuffer = device.createFramebufferUnique({.renderPass = *pass,
                .attachmentCount = 1, .pAttachments = &slot.view.get(), .width = slot.width, .height = 480, .layers = 1});
            slot.render = commands[i * 2]; slot.copy = commands[i * 2 + 1];
            slot.done = device.createFenceUnique({});
            // Exercise physical Retina extents that differ from logical 4x.
            // Production applies this final Vulkan blit after MetalFX encoding.
            slot.presentation_extent = i % 3 == 0 ? vk::Extent2D{slot.width * 3 / 2 + 3, 721}
                : i % 3 == 1 ? vk::Extent2D{slot.width + 1, 481} : vk::Extent2D{slot.width * 2, 960};
            const VkImageCreateInfo present_info{.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                .imageType = VK_IMAGE_TYPE_2D, .format = VK_FORMAT_B8G8R8A8_UNORM,
                .extent = {slot.presentation_extent.width, slot.presentation_extent.height, 1},
                .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT,
                .tiling = VK_IMAGE_TILING_OPTIMAL,
                .usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT};
            assert(vmaCreateImage(allocator, &present_info, &allocation_info,
                &slot.presentation, &slot.presentation_allocation, nullptr) == VK_SUCCESS);
            const VkBufferCreateInfo buffer_info{.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                .size = VkDeviceSize(slot.presentation_extent.width) * slot.presentation_extent.height * 4, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT};
            const VmaAllocationCreateInfo read_info{
                .flags = VMA_ALLOCATION_CREATE_HOST_ACCESS_RANDOM_BIT | VMA_ALLOCATION_CREATE_MAPPED_BIT,
                .usage = VMA_MEMORY_USAGE_AUTO};
            VmaAllocationInfo mapping{};
            assert(vmaCreateBuffer(allocator, &buffer_info, &read_info, &slot.buffer,
                                  &slot.buffer_allocation, &mapping) == VK_SUCCESS);
            slot.mapped = mapping.pMappedData;
        }
        uint64_t tick = 0;
        for (unsigned cycle = 1; cycle <= 3; ++cycle) {
            std::array<uint64_t, 6> ready{};
            // Submit all rendering before any presentation wait, as in the real two-screen renderer.
            for (unsigned i = 0; i < slots.size(); ++i) {
                auto& slot = slots[i];
                slot.render.reset();
                slot.render.begin({.flags = vk::CommandBufferUsageFlagBits::eOneTimeSubmit});
                if (cycle == 1) {
                    const vk::ImageMemoryBarrier barrier{.dstAccessMask = vk::AccessFlagBits::eTransferWrite,
                        .oldLayout = vk::ImageLayout::eUndefined, .newLayout = vk::ImageLayout::eGeneral,
                        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                        .image = slot.scaler->OutputImage(), .subresourceRange = {.aspectMask = vk::ImageAspectFlagBits::eColor,
                            .levelCount = 1, .layerCount = 1}};
                    slot.render.pipelineBarrier(vk::PipelineStageFlagBits::eTopOfPipe, vk::PipelineStageFlagBits::eTransfer, {}, {}, {}, barrier);
                }
                const vk::ClearValue clear{.color = vk::ClearColorValue{.float32 = std::array{0.f, 0.f, 0.f, 1.f}}};
                slot.render.beginRenderPass({.renderPass = *pass, .framebuffer = *slot.framebuffer,
                    .renderArea = {.extent = {slot.width, 480}}, .clearValueCount = 1, .pClearValues = &clear}, vk::SubpassContents::eInline);
                for (unsigned row = 0; row < 3; ++row) for (unsigned column = 0; column < 8; ++column) {
                    const auto color = MetalFXTest::Color(column, row, cycle, i);
                    const vk::ClearAttachment color_clear{.aspectMask = vk::ImageAspectFlagBits::eColor,
                        .colorAttachment = 0, .clearValue = {.color = {.float32 = std::array{
                            float((color >> 16) & 255) / 255, float((color >> 8) & 255) / 255,
                            float(color & 255) / 255, 1.f}}}};
                    const vk::ClearRect rect{.rect = {.offset = {int(column * slot.width / 8), int(row * 160)},
                        .extent = {slot.width / 8, 160}}, .baseArrayLayer = 0, .layerCount = 1};
                    slot.render.clearAttachments(color_clear, rect);
                }
                slot.render.endRenderPass();
                slot.render.end();
                ready[i] = ++tick;
                const vk::TimelineSemaphoreSubmitInfo signal_info{.signalSemaphoreValueCount = 1, .pSignalSemaphoreValues = &ready[i]};
                queue.submit(vk::SubmitInfo{.pNext = &signal_info, .commandBufferCount = 1, .pCommandBuffers = &slot.render,
                    .signalSemaphoreCount = 1, .pSignalSemaphores = &rendered.get()});
            }
            for (unsigned i = 0; i < slots.size(); ++i) {
                if (!slots[i].scaler->Encode(ready[i])) std::cerr << Claw::SpatialUpscaleFailureReason() << std::endl;
                assert(!Claw::GetSpatialUpscaleConfig()->failed.load());
            }
            for (auto& slot : slots) {
                slot.copy.reset();
                slot.copy.begin({.flags = vk::CommandBufferUsageFlagBits::eOneTimeSubmit});
                const vk::ImageMemoryBarrier barrier{.srcAccessMask = vk::AccessFlagBits::eMemoryWrite,
                    .dstAccessMask = vk::AccessFlagBits::eTransferRead, .oldLayout = vk::ImageLayout::eGeneral,
                    .newLayout = vk::ImageLayout::eGeneral, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                    .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = slot.scaler->OutputImage(),
                    .subresourceRange = {.aspectMask = vk::ImageAspectFlagBits::eColor, .levelCount = 1, .layerCount = 1}};
                slot.copy.pipelineBarrier(vk::PipelineStageFlagBits::eAllCommands, vk::PipelineStageFlagBits::eTransfer, {}, {}, {}, barrier);
                const vk::ImageMemoryBarrier destination{
                    .srcAccessMask = cycle == 1 ? vk::AccessFlags{} : vk::AccessFlagBits::eTransferRead,
                    .dstAccessMask = vk::AccessFlagBits::eTransferWrite,
                    .oldLayout = cycle == 1 ? vk::ImageLayout::eUndefined : vk::ImageLayout::eGeneral,
                    .newLayout = vk::ImageLayout::eGeneral, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                    .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = vk::Image{slot.presentation},
                    .subresourceRange = {.aspectMask = vk::ImageAspectFlagBits::eColor, .levelCount = 1, .layerCount = 1}};
                slot.copy.pipelineBarrier(vk::PipelineStageFlagBits::eTransfer, vk::PipelineStageFlagBits::eTransfer, {}, {}, {}, destination);
                const vk::ImageBlit blit{
                    .srcSubresource = {.aspectMask = vk::ImageAspectFlagBits::eColor, .layerCount = 1},
                    .srcOffsets = std::array{vk::Offset3D{}, vk::Offset3D{int(slot.width * 2), 960, 1}},
                    .dstSubresource = {.aspectMask = vk::ImageAspectFlagBits::eColor, .layerCount = 1},
                    .dstOffsets = std::array{vk::Offset3D{}, vk::Offset3D{int(slot.presentation_extent.width), int(slot.presentation_extent.height), 1}}};
                slot.copy.blitImage(slot.scaler->OutputImage(), vk::ImageLayout::eGeneral,
                    vk::Image{slot.presentation}, vk::ImageLayout::eGeneral, blit, vk::Filter::eLinear);
                auto readable = destination;
                readable.srcAccessMask = vk::AccessFlagBits::eTransferWrite;
                readable.dstAccessMask = vk::AccessFlagBits::eTransferRead;
                readable.oldLayout = vk::ImageLayout::eGeneral;
                slot.copy.pipelineBarrier(vk::PipelineStageFlagBits::eTransfer, vk::PipelineStageFlagBits::eTransfer, {}, {}, {}, readable);
                const vk::BufferImageCopy region{.imageSubresource = {.aspectMask = vk::ImageAspectFlagBits::eColor, .layerCount = 1},
                    .imageExtent = {slot.presentation_extent.width, slot.presentation_extent.height, 1}};
                slot.copy.copyImageToBuffer(vk::Image{slot.presentation}, vk::ImageLayout::eGeneral, vk::Buffer{slot.buffer}, region);
                const vk::BufferMemoryBarrier host{.srcAccessMask = vk::AccessFlagBits::eTransferWrite,
                    .dstAccessMask = vk::AccessFlagBits::eHostRead, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                    .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .buffer = vk::Buffer{slot.buffer}, .size = VK_WHOLE_SIZE};
                slot.copy.pipelineBarrier(vk::PipelineStageFlagBits::eTransfer, vk::PipelineStageFlagBits::eHost, {}, {}, host, {});
                slot.copy.end();
                const uint64_t value = slot.scaler->CompletionValue();
                const vk::Semaphore completion = slot.scaler->CompletionSemaphore();
                const vk::PipelineStageFlags stage = vk::PipelineStageFlagBits::eTransfer;
                const vk::TimelineSemaphoreSubmitInfo wait{.waitSemaphoreValueCount = 1, .pWaitSemaphoreValues = &value};
                queue.submit(vk::SubmitInfo{.pNext = &wait, .waitSemaphoreCount = 1, .pWaitSemaphores = &completion,
                    .pWaitDstStageMask = &stage, .commandBufferCount = 1, .pCommandBuffers = &slot.copy}, *slot.done);
            }
            for (unsigned i = 0; i < slots.size(); ++i) {
                auto& slot = slots[i];
                assert(device.waitForFences(*slot.done, true, 10'000'000'000) == vk::Result::eSuccess);
                device.resetFences(*slot.done);
                assert(vmaInvalidateAllocation(allocator, slot.buffer_allocation, 0, VK_WHOLE_SIZE) == VK_SUCCESS);
                if (Claw::GetSpatialUpscaleConfig()->failed.load()) std::cerr << Claw::SpatialUpscaleFailureReason() << std::endl;
                assert(!Claw::GetSpatialUpscaleConfig()->failed.load());
                MetalFXTest::Verify(static_cast<const uint8_t*>(slot.mapped), slot.presentation_extent.width * 4, slot.presentation_extent.width, slot.presentation_extent.height, cycle, i);
            }
        }
        device.waitIdle();
        for (auto& slot : slots) {
            slot.scaler.reset(); slot.framebuffer.reset(); slot.view.reset();
            vmaDestroyImage(allocator, slot.input, slot.input_allocation);
            vmaDestroyImage(allocator, slot.presentation, slot.presentation_allocation);
            vmaDestroyBuffer(allocator, slot.buffer, slot.buffer_allocation);
        }
        std::cout << "PASS: real MoltenVK render -> exported texture -> padded MetalFX -> Vulkan readback, both screens, six slots, mismatched Retina extents, changing colors\n";
    }
}
