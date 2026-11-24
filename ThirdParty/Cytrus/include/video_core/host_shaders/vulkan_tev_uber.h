// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <string_view>

namespace HostShaders {

// Shared with Claw::PicaTevPushConstants. Operation and source numbers are
// the PICA200 register encodings in TexturingRegs::TevStageConfig.
inline constexpr std::string_view VULKAN_TEV_UBER = R"glsl(
layout(push_constant, std430) uniform TevData {
    uvec4 tev_stages[6];
    uvec4 tev_control;
};

vec4 tev_source(uint source, vec4 primary, vec4 light_primary, vec4 light_secondary,
                vec4 buffer_color, vec4 constant_color, vec4 previous) {
    switch (source) {
    case 0u: return primary;
    case 1u: return light_primary;
    case 2u: return light_secondary;
    case 3u: return sampleTexUnit0();
    case 4u: return sampleTexUnit1();
    case 5u: return sampleTexUnit2();
    case 6u: return sampleTexUnit3();
    case 13u: return buffer_color;
    case 14u: return constant_color;
    case 15u: return previous;
    default: return vec4(0.0);
    }
}

vec3 tev_color_modifier(vec4 value, uint modifier) {
    switch (modifier & ~1u) {
    case 0u: break;
    case 2u: value.rgb = value.aaa; break;
    case 4u: value.rgb = value.rrr; break;
    case 8u: value.rgb = value.ggg; break;
    case 12u: value.rgb = value.bbb; break;
    default: return vec3(0.0);
    }
    return (modifier & 1u) == 0u ? value.rgb : vec3(1.0) - value.rgb;
}

float tev_alpha_modifier(vec4 value, uint modifier) {
    float component = value[(int(modifier >> 1u) + 3) % 4];
    return (modifier & 1u) == 0u ? component : 1.0 - component;
}

vec3 tev_rgb(uint op, vec3 a, vec3 b, vec3 c) {
    switch (op) {
    case 0u: return a;
    case 1u: return a * b;
    case 2u: return a + b;
    case 3u: return a + b - vec3(0.5);
    case 4u: return mix(b, a, c);
    case 5u: return a - b;
    case 6u:
    case 7u: return vec3(4.0 * dot(a - vec3(0.5), b - vec3(0.5)));
    case 8u: return fma(a, b, c);
    case 9u: return min(a + b, vec3(1.0)) * c;
    default: return vec3(0.0);
    }
}

float tev_alpha(uint op, float a, float b, float c) {
    switch (op) {
    case 0u: return a;
    case 1u: return a * b;
    case 2u: return a + b;
    case 3u: return a + b - 0.5;
    case 4u: return mix(b, a, c);
    case 5u: return a - b;
    case 8u: return fma(a, b, c);
    case 9u: return min(a + b, 1.0) * c;
    default: return 0.0;
    }
}

bool tev_passthrough(uvec4 stage) {
    uint rgb_scale = stage.w & 3u;
    uint alpha_scale = (stage.w >> 16u) & 3u;
    return (stage.z & 0xf000fu) == 0u &&
           (stage.x & 0xf000fu) == 0xf000fu &&
           (stage.y & 0x700fu) == 0u &&
           (rgb_scale == 0u || rgb_scale == 3u) &&
           (alpha_scale == 0u || alpha_scale == 3u);
}

float tev_scale(uint bits) {
    return float(bits < 3u ? 1u << bits : 1u);
}

vec4 run_tev(vec4 primary, vec4 light_primary, vec4 light_secondary) {
    vec4 previous = vec4(0.0);
    vec4 buffer_color = vec4(0.0);
    vec4 next_buffer = tev_combiner_buffer_color;
    for (int stage_index = 0; stage_index < 6; ++stage_index) {
        uvec4 stage = tev_stages[stage_index];
        if (!tev_passthrough(stage)) {
            vec3 rgb_args[3];
            float alpha_args[3];
            uint rgb_op = stage.z & 15u;
            uint alpha_op = (stage.z >> 16u) & 15u;
            for (uint arg = 0u; arg < 3u; ++arg) {
                uint rgb_source = (stage.x >> (4u * arg)) & 15u;
                uint alpha_source = (stage.x >> (16u + 4u * arg)) & 15u;
                // The original generator substitutes source 3 for Previous
                // at stage zero, including for a Previous source 3 itself.
                if (stage_index == 0 && rgb_source == 15u) rgb_source = (stage.x >> 8u) & 15u;
                if (stage_index == 0 && alpha_source == 15u) alpha_source = (stage.x >> 24u) & 15u;
                vec4 rgb_value = tev_source(rgb_source, primary, light_primary, light_secondary,
                                            buffer_color, const_color[stage_index], previous);
                rgb_args[arg] = tev_color_modifier(rgb_value, (stage.y >> (4u * arg)) & 15u);
                if (rgb_op != 7u) {
                    vec4 alpha_value = alpha_source == rgb_source ? rgb_value :
                        tev_source(alpha_source, primary, light_primary, light_secondary,
                                   buffer_color, const_color[stage_index], previous);
                    alpha_args[arg] = tev_alpha_modifier(alpha_value, (stage.y >> (12u + 4u * arg)) & 7u);
                }
            }
            vec3 rgb = byteround(clamp(tev_rgb(rgb_op, rgb_args[0], rgb_args[1], rgb_args[2]), 0.0, 1.0));
            float alpha = rgb.r;
            if (rgb_op != 7u) {
                alpha = byteround(clamp(tev_alpha(alpha_op, alpha_args[0], alpha_args[1], alpha_args[2]), 0.0, 1.0));
            }
            previous = clamp(vec4(rgb * tev_scale(stage.w & 3u),
                                  alpha * tev_scale((stage.w >> 16u) & 3u)), 0.0, 1.0);
        }
        buffer_color = next_buffer;
        if (stage_index < 4) {
            if ((tev_control.x & (1u << uint(stage_index))) != 0u) next_buffer.rgb = previous.rgb;
            if ((tev_control.x & (16u << uint(stage_index))) != 0u) next_buffer.a = previous.a;
        }
    }
    return previous;
}

bool tev_passes_alpha(float alpha) {
    int value = int(alpha * 255.0);
    switch (tev_control.y) {
    case 0u: return false;
    case 2u: return value == alphatest_ref;
    case 3u: return value != alphatest_ref;
    case 4u: return value < alphatest_ref;
    case 5u: return value <= alphatest_ref;
    case 6u: return value > alphatest_ref;
    case 7u: return value >= alphatest_ref;
    default: return true;
    }
}
)glsl";

} // namespace HostShaders
