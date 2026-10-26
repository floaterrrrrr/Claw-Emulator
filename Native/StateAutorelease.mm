// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>

namespace Claw {
void WithStateAutoreleasePool(void (*task)(void*), void* context) {
    // Save restore can call Objective-C/Metal from this C++ worker. Each
    // operation owns a pool, drained before the joined worker is destroyed.
    @autoreleasepool { task(context); }
}
}
