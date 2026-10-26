// SPDX-License-Identifier: GPL-3.0-or-later
#include "MetalFXSpatial.hpp"
#include "MetalFXPattern.hpp"
#include <atomic>
#include <memory>
#include <vector>

int main() {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!Claw::SupportsSpatialScaler(device)) {
            std::cout << "SKIP: MetalFX GPU unavailable on this runner; API compiled.\n";
            return 0;
        }
        id<MTLCommandQueue> producer = [device newCommandQueue];
        id<MTLCommandQueue> scaler_queue = [device newCommandQueue];
        id<MTLCommandQueue> consumer = [device newCommandQueue];
        id<MTLSharedEvent> rendered = [device newSharedEvent];
        assert(!Claw::MakeSpatialScaler(device, MTLPixelFormatBGRA8Unorm, 0, 240, 1600, 960));
        uint64_t tick = 0;
        std::array<Claw::SpatialTextures, 6> scalers{};
        std::array<id<MTLTexture>, 6> staging{}, input{}, output{};
        std::array<id<MTLBuffer>, 6> readback{};
        std::array<id<MTLSharedEvent>, 6> done{};
        std::array<NSUInteger, 6> strides{};
        for (int slot = 0; slot < 6; ++slot) {
            const unsigned width = slot < 3 ? 800 : 640;
            auto descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                width:width height:480 mipmapped:NO];
            descriptor.storageMode = MTLStorageModeShared;
            descriptor.usage = MTLTextureUsageShaderRead;
            staging[slot] = [device newTextureWithDescriptor:descriptor];
            descriptor.storageMode = MTLStorageModePrivate;
            input[slot] = [device newTextureWithDescriptor:descriptor];
            const auto extent = Claw::SpatialExtent::For2x(width, 480, width * 2, 960);
            assert(scalers[slot].Initialize(device, MTLPixelFormatBGRA8Unorm, extent));
            descriptor.width = width * 2;
            descriptor.height = 960;
            output[slot] = [device newTextureWithDescriptor:descriptor];
            done[slot] = [device newSharedEvent];
            strides[slot] = (descriptor.width * 4 + 255) & ~NSUInteger(255);
            readback[slot] = [device newBufferWithLength:strides[slot] * 960 options:MTLResourceStorageModeShared];
            assert(staging[slot] && input[slot] && output[slot] && done[slot] && readback[slot]);
            assert(!scalers[slot].Encode(scaler_queue, input[slot], output[slot], rendered, 0, done[slot], 1, nil));
        }
        for (uint64_t cycle = 1; cycle <= 3; ++cycle) {
            const auto failure = std::make_shared<std::atomic<bool>>(false);
            id<MTLCommandBuffer> last_copy = nil;
            for (int slot = 0; slot < 6; ++slot) {
                const auto source = input[slot];
                std::vector<uint32_t> pixels(source.width * source.height);
                for (unsigned y = 0; y < source.height; ++y)
                    for (unsigned x = 0; x < source.width; ++x)
                        pixels[y * source.width + x] = MetalFXTest::Pixel(source.width, source.height, x, y, cycle, slot);
                [staging[slot] replaceRegion:MTLRegionMake2D(0, 0, source.width, source.height)
                    mipmapLevel:0 withBytes:pixels.data() bytesPerRow:source.width * 4];
                const uint64_t ready = ++tick;
                id<MTLCommandBuffer> render = [producer commandBuffer];
                id<MTLBlitCommandEncoder> upload = [render blitCommandEncoder];
                [upload copyFromTexture:staging[slot] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                    sourceSize:MTLSizeMake(source.width, source.height, 1)
                    toTexture:source destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
                [upload endEncoding];
                [render encodeSignalEvent:rendered value:ready];
                [render commit];
                assert(scalers[slot].Encode(scaler_queue, source, output[slot], rendered, ready, done[slot], cycle,
                    ^(id<MTLCommandBuffer> command) {
                        if (command.status == MTLCommandBufferStatusError) {
                            std::cerr << command.error.localizedDescription.UTF8String << std::endl;
                            failure->store(true);
                            done[slot].signaledValue = cycle;
                        }
                    }));
                id<MTLCommandBuffer> copy = [consumer commandBuffer];
                [copy encodeWaitForEvent:done[slot] value:cycle];
                id<MTLBlitCommandEncoder> blit = [copy blitCommandEncoder];
                [blit copyFromTexture:output[slot] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                    sourceSize:MTLSizeMake(output[slot].width, 960, 1) toBuffer:readback[slot]
                    destinationOffset:0 destinationBytesPerRow:strides[slot] destinationBytesPerImage:strides[slot] * 960];
                [blit endEncoding];
                [copy commit];
                last_copy = copy;
            }
            [last_copy waitUntilCompleted]; // Test-only readback; production never waits here.
            assert(last_copy.status == MTLCommandBufferStatusCompleted && !failure->load());
            for (int slot = 0; slot < 6; ++slot)
                MetalFXTest::Verify(static_cast<const uint8_t*>(readback[slot].contents), strides[slot],
                                    output[slot].width, 960, cycle, slot);
        }
        std::cout << "PASS: padded MetalFX 2x to 4x, asymmetric bounds/colors, both screens, six-slot reuse\n";
    }
}
