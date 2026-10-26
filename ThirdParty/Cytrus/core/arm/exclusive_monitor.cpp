// SPDX-FileCopyrightText: Copyright 2018 yuzu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "common/arch.h"
#include "common/core_build_config.h"
#if !DISABLE_JIT && (CITRA_ARCH(x86_64) || CITRA_ARCH(arm64))
#include "core/arm/dynarmic/arm_exclusive_monitor.h"
#endif
#include "common/settings.h"
#include "core/arm/exclusive_monitor.h"
#include "core/memory.h"

namespace Core {

ExclusiveMonitor::~ExclusiveMonitor() = default;

std::unique_ptr<Core::ExclusiveMonitor> MakeExclusiveMonitor(
    [[maybe_unused]] Memory::MemorySystem& memory, [[maybe_unused]] std::size_t num_cores) {
#if !DISABLE_JIT && (CITRA_ARCH(x86_64) || CITRA_ARCH(arm64))
    if (Settings::values.use_cpu_jit) {
        return std::make_unique<Core::DynarmicExclusiveMonitor>(memory, num_cores);
    }
#endif
    // TODO(merry): Passthrough exclusive monitor
    return nullptr;
}

} // namespace Core
