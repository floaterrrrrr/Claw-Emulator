// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>

namespace Claw {

inline std::atomic_bool pica_tev_ubershader_enabled{false};

// Vulkan GLSL declares six uvec4s followed by one uvec4. Use register
// words explicitly so compiler bitfield layout never reaches the GPU.
struct alignas(16) PicaTevPushConstants {
    std::array<std::array<std::uint32_t, 4>, 6> stages{};
    std::array<std::uint32_t, 4> control{};
};
static_assert(offsetof(PicaTevPushConstants, control) == 96);
static_assert(sizeof(PicaTevPushConstants) == 112);

template <typename Stage>
constexpr PicaTevPushConstants PackPicaTev(const std::array<Stage, 6>& stages,
                                           std::uint32_t buffer_mask, std::uint32_t alpha_test) {
    PicaTevPushConstants result{};
    for (std::size_t i = 0; i < stages.size(); ++i) {
        const auto& stage = stages[i];
        result.stages[i] = {stage.sources_raw & 0x0fff0fff, stage.modifiers_raw & 0x00777fff,
                            stage.ops_raw & 0x000f000f, stage.scales_raw & 0x00030003};
    }
    result.control = {buffer_mask & 0xff, alpha_test & 7, 0, 0};
    return result;
}

enum class TevPipelineChoice { Specialized, Ubershader, Wait, Skip };

constexpr TevPipelineChoice SelectTevPipeline(bool specialized_ready, bool ubershader_ready,
                                               bool hybrid_enabled, bool legacy_wait) {
    if (specialized_ready) return TevPipelineChoice::Specialized;
    if (hybrid_enabled && ubershader_ready) return TevPipelineChoice::Ubershader;
    return hybrid_enabled || legacy_wait ? TevPipelineChoice::Wait : TevPipelineChoice::Skip;
}

} // namespace Claw
