// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <optional>
#include <span>
#include <string_view>
#include <vector>

namespace Claw {

// The Vulkan header that follows this envelope still validates vendor, device
// and pipeline-cache UUID. This header additionally invalidates older Claw
// shader-generation and MoltenVK driver data before passing it to Vulkan.
struct PipelineBlobHeader {
    std::array<char, 8> magic{'C', 'L', 'A', 'W', 'V', 'K', '0', '1'};
    std::uint32_t format_version{1};
    std::uint32_t driver_version{};
    std::array<char, 40> shader_version{};
    std::uint64_t data_size{};
};
static_assert(sizeof(PipelineBlobHeader) == 64);

inline std::array<char, 40> PipelineShaderVersion(std::string_view version) {
    std::array<char, 40> result{};
    // The first 32 bytes are Cytrus's shader-generation version. Increment
    // this Claw salt whenever our Vulkan shader/pipeline generation changes.
    constexpr std::array<char, 8> claw_salt{'C', 'L', 'A', 'W', '0', '0', '0', '1'};
    std::copy_n(version.begin(), std::min(version.size(), result.size() - claw_salt.size()),
                result.begin());
    std::copy(claw_salt.begin(), claw_salt.end(), result.end() - claw_salt.size());
    return result;
}

inline std::vector<std::uint8_t> EncodePipelineBlob(std::span<const std::uint8_t> data,
                                                     std::string_view shader_version,
                                                     std::uint32_t driver_version) {
    PipelineBlobHeader header;
    header.driver_version = driver_version;
    header.shader_version = PipelineShaderVersion(shader_version);
    header.data_size = data.size();
    std::vector<std::uint8_t> blob(sizeof(header) + data.size());
    std::memcpy(blob.data(), &header, sizeof(header));
    if (!data.empty()) std::memcpy(blob.data() + sizeof(header), data.data(), data.size());
    return blob;
}

inline std::optional<std::span<const std::uint8_t>> DecodePipelineBlob(
    std::span<const std::uint8_t> blob, std::string_view shader_version,
    std::uint32_t driver_version) {
    if (blob.size() < sizeof(PipelineBlobHeader)) return std::nullopt;
    PipelineBlobHeader header;
    std::memcpy(&header, blob.data(), sizeof(header));
    if (header.magic != PipelineBlobHeader{}.magic || header.format_version != 1 ||
        header.driver_version != driver_version ||
        header.shader_version != PipelineShaderVersion(shader_version) ||
        header.data_size == 0 || header.data_size > 128ULL * 1024 * 1024 ||
        header.data_size != blob.size() - sizeof(header)) {
        return std::nullopt;
    }
    return blob.subspan(sizeof(header));
}

} // namespace Claw
