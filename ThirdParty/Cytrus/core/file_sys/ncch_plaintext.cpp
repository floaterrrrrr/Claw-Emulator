// SPDX-License-Identifier: GPL-3.0-or-later
#include "core/file_sys/ncch_plaintext.h"
#include <algorithm>
#include <array>
#include <cstring>
#include <limits>
#include <cryptopp/sha.h>
#include "common/file_util.h"
#include "core/file_sys/ncch_container.h"

namespace FileSys {
bool VerifyPlaintextNCCH(FileUtil::IOFileBase& file, const NCCH_Header& header) {
    constexpr u64 block_size = 0x200;
    const u64 file_size = file.GetSize();
    // The existing retail loader indexes sections in 0x200-byte units. Do not
    // reinterpret prototype or different-unit layouts in this compatibility path.
    if (!file.IsOpen() || file_size < sizeof(NCCH_Header) || header.content_unit_size != 0 ||
        header.content_size == file_size) {
        return false;
    }
    const u64 content_size = static_cast<u64>(header.content_size) * block_size;
    if (content_size < sizeof(NCCH_Header) || content_size > file_size) return false;
    const auto range_valid = [content_size](u64 offset, u64 size) {
        return offset >= sizeof(NCCH_Header) && offset <= content_size && size > 0 &&
               size <= content_size - offset && offset <= std::numeric_limits<std::size_t>::max();
    };
    const auto hash_matches = [&](u64 offset, u64 size, const u8* expected) {
        if (!range_valid(offset, size) ||
            std::all_of(expected, expected + CryptoPP::SHA256::DIGESTSIZE,
                        [](u8 value) { return value == 0; })) {
            return false;
        }
        CryptoPP::SHA256 hash;
        std::array<u8, 32 * 1024> buffer{};
        u64 remaining = size;
        while (remaining > 0) {
            const auto count = static_cast<std::size_t>(std::min<u64>(remaining, buffer.size()));
            if (file.ReadAtBytes(buffer.data(), count, static_cast<std::size_t>(offset)) != count)
                return false;
            hash.Update(buffer.data(), count);
            offset += count;
            remaining -= count;
        }
        std::array<u8, CryptoPP::SHA256::DIGESTSIZE> digest{};
        hash.Final(digest.data());
        return std::equal(digest.begin(), digest.end(), expected);
    };
    bool verified_region = false;
    if (header.extended_header_size != 0) {
        const u64 size = header.extended_header_size;
        if (size > sizeof(ExHeader_Header) ||
            !hash_matches(sizeof(NCCH_Header), size, header.extended_header_hash)) {
            return false;
        }
        verified_region = true;
    }
    if (header.exefs_size != 0) {
        const u64 offset = static_cast<u64>(header.exefs_offset) * block_size;
        const u64 size = static_cast<u64>(header.exefs_size) * block_size;
        const u64 hash_size = static_cast<u64>(header.exefs_hash_region_size) * block_size;
        if (!range_valid(offset, size) || hash_size < sizeof(ExeFs_Header) || hash_size > size ||
            !hash_matches(offset, hash_size, header.exefs_super_block_hash)) {
            return false;
        }
        ExeFs_Header exefs{};
        if (file.ReadAtBytes(&exefs, sizeof(exefs), static_cast<std::size_t>(offset)) != sizeof(exefs))
            return false;
        bool has_code = false;
        for (std::size_t index = 0; index < std::size(exefs.section); ++index) {
            const auto& section = exefs.section[index];
            if (section.size == 0) continue;
            const u64 relative = sizeof(ExeFs_Header) + static_cast<u64>(section.offset);
            if (relative > size || section.size > size - relative ||
                !hash_matches(offset + relative, section.size,
                              exefs.hashes[std::size(exefs.section) - 1 - index])) {
                return false;
            }
            has_code |= std::memcmp(section.name, ".code", 5) == 0;
        }
        if (header.is_executable && !has_code) return false;
        verified_region = true;
    } else if (header.is_executable) {
        return false;
    }
    if (header.romfs_size != 0) {
        const u64 offset = static_cast<u64>(header.romfs_offset) * block_size;
        const u64 size = static_cast<u64>(header.romfs_size) * block_size;
        const u64 hash_size = static_cast<u64>(header.romfs_hash_region_size) * block_size;
        if (!range_valid(offset, size) || hash_size == 0 || hash_size > size ||
            !hash_matches(offset, hash_size, header.romfs_super_block_hash)) {
            return false;
        }
        verified_region = true;
    }
    return verified_region;
}
} // namespace FileSys
