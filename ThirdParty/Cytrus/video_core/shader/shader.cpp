// Copyright 2015 Citra Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

#include "common/arch.h"
#include "common/core_build_config.h"
#include "video_core/shader/shader_interpreter.h"
#if !DISABLE_JIT && (CITRA_ARCH(x86_64) || CITRA_ARCH(arm64))
#include "video_core/shader/shader_jit.h"
#endif
#include "video_core/shader/shader.h"

namespace Pica {

std::unique_ptr<ShaderEngine> CreateEngine(bool use_jit) {
#if !DISABLE_JIT && (CITRA_ARCH(x86_64) || CITRA_ARCH(arm64))
    if (use_jit) {
        return std::make_unique<Shader::JitEngine>();
    }
#else
    (void)use_jit;
#endif

    return std::make_unique<Shader::InterpreterEngine>();
}

} // namespace Pica
