// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <functional>
#include <memory>
#include <span>
#include "common/common_types.h"

namespace AudioCore {
// Converts decoded guest PCM, not Nintendo DSP packets. Apple does not expose
// a hardware decoder for 3DS DSP formats or hardware pitch-preserving stretching.
// Owned exclusively by the audio producer; never used by the RemoteIO callback.
class ApplePCMConverter {
public:
    using Input = std::function<std::size_t(s16*, std::size_t)>;
    explicit ApplePCMConverter(Input input, unsigned int input_rate = 32728);
    ~ApplePCMConverter();
    ApplePCMConverter(const ApplePCMConverter&) = delete;
    ApplePCMConverter& operator=(const ApplePCMConverter&) = delete;
    std::size_t Convert(std::span<s16> stereo);
    void Reset();

private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
} // namespace AudioCore
