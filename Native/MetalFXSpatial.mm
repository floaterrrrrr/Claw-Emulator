// SPDX-License-Identifier: GPL-3.0-or-later
#include "MetalFXSpatial.hpp"

namespace Claw {
bool SupportsSpatialScaler(id<MTLDevice> device) {
    if (@available(iOS 16.0, macOS 13.0, *))
        return device && [MTLFXSpatialScalerDescriptor supportsDevice:device];
    return false;
}
id<MTLFXSpatialScaler> MakeSpatialScaler(id<MTLDevice> device, MTLPixelFormat format,
                                       NSUInteger width, NSUInteger height,
                                       NSUInteger output_width, NSUInteger output_height) {
    if (!SupportsSpatialScaler(device) || !width || !height ||
        output_width <= width || output_height <= height ||
        output_width > 4096 || output_height > 4096)
        return nil;
    MTLFXSpatialScalerDescriptor* descriptor = [MTLFXSpatialScalerDescriptor new];
    descriptor.colorTextureFormat = format;
    descriptor.outputTextureFormat = format;
    descriptor.inputWidth = width;
    descriptor.inputHeight = height;
    descriptor.outputWidth = output_width;
    descriptor.outputHeight = output_height;
    // The 3DS presentation colors are already perceptually encoded, not HDR/linear light.
    descriptor.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
    return [descriptor newSpatialScalerWithDevice:device];
}

bool SpatialTextures::Initialize(id<MTLDevice> device, MTLPixelFormat format, SpatialExtent dimensions) {
    extent = dimensions;
    if (!extent || (format != MTLPixelFormatBGRA8Unorm && format != MTLPixelFormatRGBA8Unorm)) {
        error = "Invalid 2x to 4x texture bounds or pixel format";
        return false;
    }
    scaler = MakeSpatialScaler(device, format, extent.padded_width, extent.padded_height,
                               extent.output_width, extent.output_height);
    if (!scaler) { error = "MetalFX scaler creation failed"; return false; }
    auto descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
        width:extent.padded_width height:extent.padded_height mipmapped:NO];
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.hazardTrackingMode = MTLHazardTrackingModeTracked;
    descriptor.usage = scaler.colorTextureUsage | MTLTextureUsageRenderTarget;
    input = [device newTextureWithDescriptor:descriptor];
    descriptor.width = extent.output_width;
    descriptor.height = extent.output_height;
    descriptor.usage = scaler.outputTextureUsage;
    output = [device newTextureWithDescriptor:descriptor];
    if (!input || !output) {
        error = "MetalFX private scratch texture allocation failed";
        return false;
    }
    input.label = @"Claw padded MetalFX input";
    output.label = @"Claw logical MetalFX output";
    // These resources are owned/tracked Metal textures, so Metal manages the
    // dependencies between blit and scaler encoders without an uninitialized fence.
    scaler.fence = nil;
    return true;
}

bool SpatialTextures::Encode(id<MTLCommandQueue> queue, id<MTLTexture> source,
                             id<MTLTexture> destination,
                             id<MTLSharedEvent> rendered, uint64_t rendered_value,
                             id<MTLSharedEvent> finished, uint64_t finished_value,
                             void (^completion)(id<MTLCommandBuffer>)) {
    @autoreleasepool {
        if (!scaler || !queue || !source || !destination || !rendered || !finished ||
            !rendered_value || !finished_value || source.device != queue.device ||
            destination.device != queue.device || source.pixelFormat != input.pixelFormat ||
            destination.pixelFormat != output.pixelFormat ||
            source.width != extent.content_width || source.height != extent.content_height ||
            destination.width != extent.output_width || destination.height != extent.output_height) {
            error = "Exported texture format or logical bounds mismatch";
            return false;
        }
        id<MTLCommandBuffer> command = [queue commandBuffer];
        if (!command) { error = "Metal command buffer allocation failed"; return false; }
        command.label = @"Claw bounded MetalFX transfer and upscale";
        [command encodeWaitForEvent:rendered value:rendered_value];
        if (!padding_cleared) {
            auto pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = input;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
            id<MTLRenderCommandEncoder> clear = [command renderCommandEncoderWithDescriptor:pass];
            if (!clear) { error = "Metal scratch clear encoder creation failed"; return false; }
            [clear endEncoding];
        }
        id<MTLBlitCommandEncoder> upload = [command blitCommandEncoder];
        if (!upload) { error = "Metal input blit encoder creation failed"; return false; }
        [upload copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
            sourceSize:MTLSizeMake(extent.content_width, extent.content_height, 1)
            toTexture:input destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [upload endEncoding];
        scaler.colorTexture = input;
        scaler.outputTexture = output;
        // Dynamic content bounds crop the padded right/bottom edges. They are
        // independently set per screen; no 400:240 assumption applies to 320:240.
        scaler.inputContentWidth = extent.content_width;
        scaler.inputContentHeight = extent.content_height;
        [scaler encodeToCommandBuffer:command];
        id<MTLBlitCommandEncoder> download = [command blitCommandEncoder];
        if (!download) { error = "Metal output blit encoder creation failed"; return false; }
        [download copyFromTexture:output sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
            sourceSize:MTLSizeMake(extent.output_width, extent.output_height, 1)
            toTexture:destination destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [download endEncoding];
        // Vulkan presentation cannot consume the exported output until both
        // the scaler and its final GPU blit have completed.
        [command encodeSignalEvent:finished value:finished_value];
        if (completion) [command addCompletedHandler:completion];
        [command commit];
        padding_cleared = true;
        return true;
    }
}
} // namespace Claw
