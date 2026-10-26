// SPDX-License-Identifier: GPL-3.0-or-later
#include "MobileDeviceProfile.hpp"
#include <sys/sysctl.h>
#include <string>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <TargetConditionals.h>

namespace Claw {
const char* MobileDeviceModel() {
    static const std::string machine = [] {
        size_t size = 0;
        if (sysctlbyname("hw.machine", nullptr, &size, nullptr, 0) != 0 || !size || size >= 256)
            return std::string("unknown");
        std::string value(size, '\0');
        if (sysctlbyname("hw.machine", value.data(), &size, nullptr, 0) != 0)
            return std::string("unknown");
        value.resize(size && value[size - 1] == '\0' ? size - 1 : size);
        return value;
    }();
    return machine.c_str();
}
const MobileDeviceCapabilities& GetMobileDeviceCapabilities() {
    static const MobileDeviceCapabilities caps = [] {
        @autoreleasepool {
            id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            bool spatial = false;
            if (@available(iOS 16.0, macOS 13.0, *))
                spatial = device && [MTLFXSpatialScalerDescriptor supportsDevice:device];
            return MobileDeviceCapabilities{
                .apple8_or_newer = device && [device supportsFamily:MTLGPUFamilyApple8],
                .physical_memory_bytes = NSProcessInfo.processInfo.physicalMemory,
                .max_buffer_bytes = device ? device.maxBufferLength : 0,
                .iphone_generation = IPhoneGeneration(MobileDeviceModel()),
                .metalfx_supported = spatial,
                .simulator = TARGET_OS_SIMULATOR != 0,
            };
        }
    }();
    return caps;
}
void InitializeMobileDeviceProfile(const char* data_directory) {
    @autoreleasepool {
        const auto& caps = GetMobileDeviceCapabilities();
        const auto graphics = SelectMobileGraphicsProfile(caps);
        const auto profile = ConfigureMobileMemoryProfile(caps);
        if (!data_directory || !*data_directory) return;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSString* model = [NSString stringWithUTF8String:MobileDeviceModel()];
        NSDictionary* values = @{
            @"profile": graphics.metalfx_input ? @"Spatial 2x to 4x" : graphics.resolution == 1 ? @"Native" : @"Balanced 2x",
            @"machine": model ?: @"unknown",
            @"recommended_resolution": @(graphics.resolution),
            @"recommended_metalfx_input": @(graphics.metalfx_input),
            @"recommended_cpu_clock": @(graphics.cpu_clock),
            @"metalfx_supported": @(caps.metalfx_supported),
            @"simulator": @(caps.simulator),
            @"gpu": device.name ?: @"unavailable",
            @"apple8_or_newer": @(caps.apple8_or_newer),
            @"physical_memory_bytes": @(caps.physical_memory_bytes),
            @"max_buffer_bytes": @(caps.max_buffer_bytes),
            @"cache_budget_bytes": @(profile.cache_bytes),
            @"retained_surface_limit": @(profile.retained_surfaces),
            @"max_idle_frames": @(profile.max_idle_frames),
            @"texture_upload_buffer_bytes": @(profile.upload_buffer_bytes),
            @"render_target_format": @"unchanged; optimal tiling; driver-managed compression",
        };
        // One small diagnostic file per launch, never a logging/background thread.
        // A failed diagnostic write must not block game startup.
        if (data_directory && *data_directory) {
            NSString* root = [NSString stringWithUTF8String:data_directory];
            NSData* data = [NSJSONSerialization dataWithJSONObject:values
                                    options:NSJSONWritingPrettyPrinted error:nullptr];
            if (root && data) {
                [data writeToFile:[root stringByAppendingPathComponent:@"device-profile.json"]
                         options:NSDataWritingAtomic error:nullptr];
            }
        }
    }
}
} // namespace Claw
