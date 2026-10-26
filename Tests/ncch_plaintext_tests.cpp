// SPDX-License-Identifier: GPL-3.0-or-later
#include <algorithm>
#include <cassert>
#include <cstring>
#include <iostream>
#include <memory>
#include <vector>
#include <cryptopp/sha.h>
#include "common/file_util.h"
#include "core/file_sys/ncch_container.h"
#include "core/file_sys/ncch_plaintext.h"

class MemoryFile final : public FileUtil::IOFileBase {
public:
    std::vector<u8> bytes = std::vector<u8>(0x18000);
    std::size_t largest_read = 0;
    bool open = true;
    bool IsOpen() const override { return open; }
    u64 GetSize() const override { return bytes.size(); }
    std::unique_ptr<FileUtil::IOFileBase> OpenCopy() const override { return nullptr; }
protected:
    FileUtil::IOType::Type MyType() const override { return FileUtil::IOType::Type::IOFile; }
    std::size_t ReadAtImpl(void* out, std::size_t count, std::size_t offset) override {
        largest_read = std::max(largest_read, count);
        if (!open || offset > bytes.size()) return 0;
        count = std::min(count, bytes.size() - offset);
        std::memcpy(out, bytes.data() + offset, count);
        return count;
    }
};

static void Digest(MemoryFile& file, u64 offset, u64 size, u8* out) {
    CryptoPP::SHA256 hash;
    hash.CalculateDigest(out, file.bytes.data() + offset, size);
}

int main() {
    // Small synthetic cartridge partition; no commercial ROM or key file required.
    MemoryFile file;
    for (std::size_t index = 0x200; index < file.bytes.size(); ++index)
        file.bytes[index] = static_cast<u8>((index * 13) ^ (index >> 8));
    NCCH_Header header{};
    header.content_size = file.bytes.size() / 0x200;
    header.extended_header_size = 0x400;
    header.is_executable.Assign(1);
    header.exefs_offset = 0x1000 / 0x200;
    header.exefs_size = 0x12000 / 0x200;
    header.exefs_hash_region_size = 1;
    header.romfs_offset = 0x14000 / 0x200;
    header.romfs_size = 0x4000 / 0x200;
    header.romfs_hash_region_size = 1;
    ExeFs_Header exefs{};
    std::memcpy(exefs.section[0].name, ".code", 5);
    exefs.section[0].size = 65537; // Verify beyond the first two hash chunks.
    std::memcpy(exefs.section[1].name, "banner", 6);
    exefs.section[1].offset = 0x11000;
    exefs.section[1].size = 31;
    Digest(file, 0x1200, exefs.section[0].size, exefs.hashes[7]);
    Digest(file, 0x12200, exefs.section[1].size, exefs.hashes[6]);
    std::memcpy(file.bytes.data() + 0x1000, &exefs, sizeof(exefs));
    Digest(file, 0x200, header.extended_header_size, header.extended_header_hash);
    Digest(file, 0x1000, 0x200, header.exefs_super_block_hash);
    Digest(file, 0x14000, 0x200, header.romfs_super_block_hash);
    assert(!header.no_crypto); // Deliberately stale encrypted flag.
    assert(FileSys::VerifyPlaintextNCCH(file, header));
    assert(file.largest_read <= 32 * 1024);
    for (std::size_t offset : {0x201, 0x1001, 0x1200 + 33000, 0x12200, 0x14001}) {
        file.bytes[offset] ^= 0x80;
        assert(!FileSys::VerifyPlaintextNCCH(file, header));
        file.bytes[offset] ^= 0x80;
    }
    auto invalid = header;
    invalid.romfs_offset = 0xffffffff;
    assert(!FileSys::VerifyPlaintextNCCH(file, invalid));
    invalid = header;
    invalid.exefs_hash_region_size = 0;
    assert(!FileSys::VerifyPlaintextNCCH(file, invalid));
    invalid = header;
    invalid.content_size = 0xffffffff;
    assert(!FileSys::VerifyPlaintextNCCH(file, invalid));
    invalid = header;
    invalid.content_unit_size = 0xff;
    assert(!FileSys::VerifyPlaintextNCCH(file, invalid));
    invalid = header;
    std::memset(invalid.extended_header_hash, 0, sizeof(invalid.extended_header_hash));
    assert(!FileSys::VerifyPlaintextNCCH(file, invalid));
    invalid = {};
    invalid.content_size = file.bytes.size() / 0x200;
    assert(!FileSys::VerifyPlaintextNCCH(file, invalid));
    file.open = false;
    assert(!FileSys::VerifyPlaintextNCCH(file, header));
    file.open = true;
    file.bytes.resize(0x14010);
    assert(!FileSys::VerifyPlaintextNCCH(file, header));
    std::cout << "PASS: stale flag/plaintext hashes, corrupted executable/metadata, bounds, "
                 "missing hashes, closed/truncated files, bounded 32 KiB reads\n";
}
