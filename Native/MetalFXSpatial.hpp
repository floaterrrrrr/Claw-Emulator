// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#include "SpatialExtent.hpp"
#include <string>

namespace Claw {
bool SupportsSpatialScaler(id<MTLDevice> device);
id<MTLFXSpatialScaler> MakeSpatialScaler(id<MTLDevice> device, MTLPixelFormat format,
                                       NSUInteger width, NSUInteger height,
                                       NSUInteger output_width, NSUInteger output_height);
// All waits/signals are encoded on the GPU. Caller retains one scaler per in-flight slot.
class SpatialTextures {
public:
    bool Initialize(id<MTLDevice> device, MTLPixelFormat format, SpatialExtent extent);
    // Blit logical content into owned, tracked scratch textures. MetalFX never
    // sees MoltenVK heap views or treats the padding as screen content.
    bool Encode(id<MTLCommandQueue> queue, id<MTLTexture> source, id<MTLTexture> destination,
                         id<MTLSharedEvent> rendered, uint64_t rendered_value,
                         id<MTLSharedEvent> finished, uint64_t finished_value,
                         void (^completion)(id<MTLCommandBuffer>));
    const std::string& Error() const { return error; }
private:
    SpatialExtent extent{};
    id<MTLFXSpatialScaler> scaler;
    id<MTLTexture> input;
    id<MTLTexture> output;
    bool padding_cleared{};
    std::string error;
};
} // namespace Claw
