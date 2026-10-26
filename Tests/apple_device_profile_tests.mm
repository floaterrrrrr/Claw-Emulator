// SPDX-License-Identifier: GPL-3.0-or-later
#include "MobileDeviceProfile.hpp"
#include <cassert>
#include <iostream>
#import <Foundation/Foundation.h>

int main(int argc, char** argv) {
    assert(argc == 2);
    @autoreleasepool {
        Claw::InitializeMobileDeviceProfile(argv[1]);
        NSString* root = [NSString stringWithUTF8String:argv[1]];
        NSData* data = [NSData dataWithContentsOfFile:
            [root stringByAppendingPathComponent:@"device-profile.json"]];
        assert(data);
        NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nullptr];
        assert(json && [json[@"physical_memory_bytes"] unsignedLongLongValue] > 0);
        const auto profile = Claw::GetMobileMemoryProfile();
        const auto graphics = Claw::SelectMobileGraphicsProfile(Claw::GetMobileDeviceCapabilities());
        assert([json[@"recommended_resolution"] intValue] == graphics.resolution);
        assert([json[@"recommended_metalfx_input"] intValue] == graphics.metalfx_input);
        assert([json[@"recommended_cpu_clock"] intValue] == 100);
        assert([json[@"cache_budget_bytes"] unsignedLongLongValue] == profile.cache_bytes);
        assert([json[@"retained_surface_limit"] unsignedIntValue] == profile.retained_surfaces);
        assert([json[@"texture_upload_buffer_bytes"] unsignedLongLongValue] == profile.upload_buffer_bytes);
        std::cout << "PASS: real Foundation/Metal startup probe and diagnostic profile publication\n";
    }
}
