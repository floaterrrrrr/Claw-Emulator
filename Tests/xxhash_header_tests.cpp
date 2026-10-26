// SPDX-License-Identifier: GPL-3.0-or-later
#include <cassert>
#include "common/hash.h"

int main() {
    // Standard XXH3 empty-input vector. The compile also verifies that Zstd's
    // private header cannot replace standalone xxHash in the core's hash API.
    assert(Common::ComputeHash64("", 0) == 0x2d06800538d394c2ULL);
}
