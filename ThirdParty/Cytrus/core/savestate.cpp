// Copyright 2020-2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

#include <chrono>
#include <sstream>
#include <zstd.h>
#include <lodepng.h>
#include "video_core/gpu.h"
#include "video_core/renderer_base.h"
#include <cryptopp/hex.h>
#include <fmt/ranges.h>
#include "common/archives.h"
#include "common/file_util.h"
#include "common/logging/log.h"
#include "common/scm_rev.h"
#include "common/scope_exit.h"
#include "common/swap.h"
#include "common/zstd_compression.h"
#include "core/core.h"
#include "core/loader/loader.h"
#include "core/movie.h"
#include "core/savestate.h"
#include "network/network.h"

namespace Core {

#pragma pack(push, 1)
struct CSTHeader {
    std::array<u8, 4> filetype{};    /// Unique Identifier to check the file type (always "CST"0x1B)
    u64_le program_id{};             /// ID of the ROM being executed. Also called title_id
    std::array<u8, 20> revision{};   /// Git hash of the revision this savestate was created with
    u64_le time{};                   /// The time when this save state was created
    std::array<u8, 20> build_name{}; /// The build name (Canary/Nightly) with the version number
    u32_le zero{};                   /// Should be zero, just in case.
    std::array<u8, 20> build_version{}; /// Latest build version, used as compatibility.
    u32_le zero_2{};                    /// Should be zero, just in case.

    std::array<u8, 168> reserved{}; /// Make heading 256 bytes so it has consistent size
};
static_assert(sizeof(CSTHeader) == 256, "CSTHeader should be 256 bytes");
#pragma pack(pop)

constexpr std::array<u8, 4> header_magic_bytes{{'C', 'S', 'T', 0x1B}};

static std::string GetSaveStatePath(u64 program_id, u64 movie_id, u32 slot) {
    if (movie_id) {
        return fmt::format("{}{:016X}.movie{:016X}.{:02d}.cst",
                           FileUtil::GetUserPath(FileUtil::UserPath::StatesDir), program_id,
                           movie_id, slot);
    } else {
        return fmt::format("{}{:016X}.{:02d}.cst",
                           FileUtil::GetUserPath(FileUtil::UserPath::StatesDir), program_id, slot);
    }
}

static bool ValidateSaveState(const CSTHeader& header, SaveStateInfo& info, u64 program_id,
                              u64 movie_id) {
    const auto path = GetSaveStatePath(program_id, movie_id, info.slot);
    if (header.filetype != header_magic_bytes) {
        LOG_WARNING(Core, "Invalid save state file {}", path);
        return false;
    }
    info.time = header.time;

    if (header.program_id != program_id) {
        LOG_WARNING(Core, "Save state file isn't for the current game {}", path);
        return false;
    }
    const std::string revision = fmt::format("{:02x}", fmt::join(header.revision, ""));
    const std::string build_name =
        header.zero == 0 ? reinterpret_cast<const char*>(header.build_name.data()) : "";
    const std::string build_version =
        header.zero_2 == 0 ? reinterpret_cast<const char*>(header.build_version.data()) : "";

    if (revision == Common::g_scm_rev) {
        info.status = SaveStateInfo::ValidationStatus::OK;
    } else {
        info.build_name = build_name;
        info.build_version = build_version;

        info.status = Common::g_build_version == info.build_version
                          ? SaveStateInfo::ValidationStatus::RevisionMismatch
                          : SaveStateInfo::ValidationStatus::BuildMismatch;
    }
    return true;
}

std::vector<SaveStateInfo> ListSaveStates(u64 program_id, u64 movie_id) {
    std::vector<SaveStateInfo> result;
    result.reserve(SaveStateSlotCount);
    for (u32 slot = 0; slot <= SaveStateSlotCount; ++slot) {
        const auto path = GetSaveStatePath(program_id, movie_id, slot);
        if (!FileUtil::Exists(path)) {
            continue;
        }

        SaveStateInfo info;
        info.slot = slot;

        FileUtil::IOFile file(path, "rb");
        if (!file) {
            LOG_ERROR(Core, "Could not open file {}", path);
            continue;
        }
        CSTHeader header;
        if (file.GetSize() < sizeof(header)) {
            LOG_ERROR(Core, "File too small {}", path);
            continue;
        }
        if (file.ReadBytes(&header, sizeof(header)) != sizeof(header)) {
            LOG_ERROR(Core, "Could not read from file {}", path);
            continue;
        }
        if (!ValidateSaveState(header, info, program_id, movie_id)) {
            continue;
        }

        result.emplace_back(std::move(info));
    }
    return result;
}

SaveStateInfo GetSaveStateInfo(u64 program_id, u64 movie_id, u32 slot) {
    SaveStateInfo info{};
    info.slot = std::numeric_limits<u32>::max();

    const auto path = GetSaveStatePath(program_id, movie_id, slot);
    if (!FileUtil::Exists(path)) {
        return info;
    }

    FileUtil::IOFile file(path, "rb");
    if (!file) {
        LOG_ERROR(Core, "Could not open file {}", path);
        return info;
    }
    CSTHeader header;
    if (file.GetSize() < sizeof(header)) {
        LOG_ERROR(Core, "File too small {}", path);
        return info;
    }
    if (file.ReadBytes(&header, sizeof(header)) != sizeof(header)) {
        LOG_ERROR(Core, "Could not read from file {}", path);
        return info;
    }
    if (ValidateSaveState(header, info, program_id, movie_id)) {
        info.slot = slot;
    }
    return info;
}


StateSnapshot System::CaptureStateSnapshot() const {
    SCOPE_EXIT({ const_cast<System*>(this)->save_state_status = SaveStateStatus::NONE; });
    if (app_loader && !app_loader->SupportsSaveStates())
        throw std::runtime_error("This game does not support save states.");
    StateSnapshot snapshot;
    // Read the current rendered frame before serialization clears GPU caches.
    // This runs while the guest is parked, for both manual and automatic saves.
    try { snapshot.preview = gpu->Renderer().CaptureSavePreview(); }
    catch (...) { snapshot.preview.clear(); } // a missing picture must not lose a save
    std::ostringstream stream{std::ios_base::binary};
    { oarchive archive{stream}; archive & *this; }
    snapshot.contents = std::move(stream).str();
    CSTHeader header{};
    header.filetype = header_magic_bytes;
    header.program_id = title_id;
    std::string revision;
    CryptoPP::StringSource source(Common::g_scm_rev, true,
        new CryptoPP::HexDecoder(new CryptoPP::StringSink(revision)));
    if (revision.size() != header.revision.size()) throw std::runtime_error("Invalid core revision.");
    std::memcpy(header.revision.data(), revision.data(), revision.size());
    header.time = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    const std::string name = Common::g_build_fullname, version = Common::g_build_version;
    std::memcpy(header.build_name.data(), name.data(), std::min(name.size(), header.build_name.size()-1));
    std::memcpy(header.build_version.data(), version.data(), std::min(version.size(), header.build_version.size()-1));
    std::memcpy(snapshot.header.data(), &header, sizeof(header));
    return snapshot;
}

std::string System::StatePath(u32 slot) const {
    return GetSaveStatePath(title_id, movie.GetCurrentMovieID(), slot);
}

void WriteStateSnapshot(StateSnapshot snapshot, const std::string& path) {
    if (!FileUtil::CreateFullPath(path)) throw std::runtime_error("Could not create the state directory.");
    const auto temporary = path + ".tmp";
    SCOPE_EXIT({ if (FileUtil::Exists(temporary)) FileUtil::Delete(temporary); });
    FileUtil::IOFile file(temporary, "wb");
    if (!file || file.WriteBytes(snapshot.header.data(), snapshot.header.size()) != snapshot.header.size())
        throw std::runtime_error("Could not write the save state header.");
    ZSTD_CCtx* context = ZSTD_createCCtx();
    if (!context) throw std::runtime_error("Could not allocate state compression workspace.");
    SCOPE_EXIT({ ZSTD_freeCCtx(context); });
    if (ZSTD_isError(ZSTD_CCtx_setParameter(context, ZSTD_c_compressionLevel, 3)) ||
        ZSTD_isError(ZSTD_CCtx_setPledgedSrcSize(context, snapshot.contents.size())))
        throw std::runtime_error("Could not configure state compression.");
    std::array<u8, 64 * 1024> output{};
    ZSTD_inBuffer input{snapshot.contents.data(), snapshot.contents.size(), 0};
    size_t remaining = 1;
    while (remaining) {
        ZSTD_outBuffer target{output.data(), output.size(), 0};
        remaining = ZSTD_compressStream2(context, &target, &input, ZSTD_e_end);
        if (ZSTD_isError(remaining) || file.WriteBytes(output.data(), target.pos) != target.pos)
            throw std::runtime_error("Could not write the compressed state. Your previous slot is kept.");
    }
    std::string{}.swap(snapshot.contents);
    if (!file.Flush() || !file.Close() || !FileUtil::Rename(temporary, path))
        throw std::runtime_error("Could not finish writing the save state. Your previous slot is kept.");
    // State is committed first. A preview is optional and must never expose an
    // older slot image after an overwrite. UI also checks its modification time.
    const auto picture = path + ".png", picture_tmp = picture + ".tmp";
    SCOPE_EXIT({ if (FileUtil::Exists(picture_tmp)) FileUtil::Delete(picture_tmp); });
    if (FileUtil::Exists(picture)) FileUtil::Delete(picture);
    try {
        std::vector<u8> png;
        if (snapshot.preview.size() != 400 * 240 * 4 ||
            lodepng::encode(png, snapshot.preview, 400, 240)) return;
        FileUtil::IOFile output(picture_tmp, "wb");
        if (output && output.WriteBytes(png.data(), png.size()) == png.size() &&
            output.Flush() && output.Close()) FileUtil::Rename(picture_tmp, picture);
    } catch (...) { /* The state itself is already durable. */ }
}

std::string ReadStateSnapshot(const std::string& path, u64 expected_title) {
    FileUtil::IOFile file(path, "rb");
    const auto size = file.GetSize();
    if (!file || size <= sizeof(CSTHeader) || size > 256ULL * 1024 * 1024)
        throw std::runtime_error("The save state is missing, incomplete or too large.");
    CSTHeader header{};
    if (file.ReadBytes(&header, sizeof(header)) != sizeof(header) ||
        header.filetype != header_magic_bytes || header.program_id != expected_title)
        throw std::runtime_error("This save state does not belong to this game.");
    const auto revision = fmt::format("{:02x}", fmt::join(header.revision, ""));
    if (revision != Common::g_scm_rev)
        throw std::runtime_error("This save state uses a different core revision.");
    std::vector<u8> compressed(size - sizeof(header));
    if (file.ReadBytes(compressed.data(), compressed.size()) != compressed.size())
        throw std::runtime_error("Could not read the complete save state.");
    const auto expanded = ZSTD_getFrameContentSize(compressed.data(), compressed.size());
    if (expanded == ZSTD_CONTENTSIZE_ERROR || expanded == ZSTD_CONTENTSIZE_UNKNOWN ||
        expanded > 512ULL * 1024 * 1024)
        throw std::runtime_error("The save state compression header is invalid.");
    // Decompress into the final archive buffer, avoiding a second full-size
    // allocation/copy on memory-constrained phones.
    std::string contents(expanded, '\0');
    const auto result = ZSTD_decompress(contents.data(), contents.size(),
                                        compressed.data(), compressed.size());
    if (ZSTD_isError(result) || result != contents.size() || contents.empty())
        throw std::runtime_error("The save state could not be decompressed.");
    return contents;
}

void System::ApplyStateSnapshot(std::string contents) {
    SCOPE_EXIT({ save_state_status = SaveStateStatus::NONE; });
    auto member = Network::GetRoomMember().lock();
    if (member && member->IsConnected()) throw std::runtime_error("Leave multiplayer before loading a state.");
    std::istringstream stream{std::move(contents), std::ios_base::binary};
    iarchive archive{stream}; archive & *this;
}

void System::SaveState(u32 slot) const {
    SCOPE_EXIT({ const_cast<System*>(this)->save_state_status = SaveStateStatus::NONE; });
    if (app_loader) {
        if (!app_loader->SupportsSaveStates()) {
            throw std::runtime_error("The current app loader doesn't support save states");
        }
    }

    std::ostringstream sstream{std::ios_base::binary};
    // Serialize
    oarchive oa{sstream};
    oa&* this;

    const std::string& str{sstream.str()};
    const auto data = std::span<const u8>{reinterpret_cast<const u8*>(str.data()), str.size()};
    auto buffer = Common::Compression::CompressDataZSTDDefault(data);

    const u64 movie_id = movie.GetCurrentMovieID();
    const auto path = GetSaveStatePath(title_id, movie_id, slot);
    if (!FileUtil::CreateFullPath(path)) {
        throw std::runtime_error("Could not create path " + path);
    }

    const std::string temporary_path = path + ".tmp";
    SCOPE_EXIT({
        if (FileUtil::Exists(temporary_path)) FileUtil::Delete(temporary_path);
    });
    FileUtil::IOFile file(temporary_path, "wb");
    if (!file) {
        throw std::runtime_error("Could not open file " + path);
    }

    CSTHeader header{};
    header.filetype = header_magic_bytes;
    header.program_id = title_id;
    std::string rev_bytes;
    CryptoPP::StringSource ss(Common::g_scm_rev, true,
                              new CryptoPP::HexDecoder(new CryptoPP::StringSink(rev_bytes)));
    std::memcpy(header.revision.data(), rev_bytes.data(), sizeof(header.revision));
    header.time = std::chrono::duration_cast<std::chrono::seconds>(
                      std::chrono::system_clock::now().time_since_epoch())
                      .count();
    const std::string build_fullname = Common::g_build_fullname;
    std::memset(header.build_name.data(), 0, sizeof(header.build_name));
    std::memcpy(header.build_name.data(), build_fullname.c_str(),
                std::min(build_fullname.length(), sizeof(header.build_name) - 1));

    if (file.WriteBytes(&header, sizeof(header)) != sizeof(header) ||
        file.WriteBytes(buffer.data(), buffer.size()) != buffer.size()) {
        throw std::runtime_error("Could not write to file " + path);
    }
    if (!file.Flush() || !file.Close() || !FileUtil::Rename(temporary_path, path)) {
        throw std::runtime_error("Could not finish writing save state " + path);
    }
}

void System::LoadState(u32 slot) {
    SCOPE_EXIT({ save_state_status = SaveStateStatus::NONE; });
    if (app_loader) {
        if (!app_loader->SupportsSaveStates()) {
            throw std::runtime_error("The current app loader doesn't support save states");
        }
    }
    auto room_member = Network::GetRoomMember().lock();
    if (room_member && room_member->IsConnected()) {
        throw std::runtime_error("Unable to load while connected to multiplayer");
    }

    const u64 movie_id = movie.GetCurrentMovieID();
    const auto path = GetSaveStatePath(title_id, movie_id, slot);

    std::vector<u8> decompressed;
    {
        const auto file_size = FileUtil::GetSize(path);
        if (file_size < sizeof(CSTHeader)) {
            throw std::runtime_error("The save state is missing or incomplete.");
        }
        std::vector<u8> buffer(file_size - sizeof(CSTHeader));

        FileUtil::IOFile file(path, "rb");

        // load header
        CSTHeader header;
        if (file.ReadBytes(&header, sizeof(header)) != sizeof(header)) {
            throw std::runtime_error("Could not read from file at " + path);
        }

        // validate header
        SaveStateInfo info;
        info.slot = slot;
        if (!ValidateSaveState(header, info, title_id, movie_id) ||
            info.status == SaveStateInfo::ValidationStatus::BuildMismatch) {
            throw std::runtime_error("Invalid savestate");
        }

        if (file.ReadBytes(buffer.data(), buffer.size()) != buffer.size()) {
            throw std::runtime_error("Could not read from file at " + path);
        }
        decompressed = Common::Compression::DecompressDataZSTD(buffer);
    }
    std::istringstream sstream{
        std::string{reinterpret_cast<char*>(decompressed.data()), decompressed.size()},
        std::ios_base::binary};
    decompressed.clear();

    // Deserialize
    iarchive ia{sstream};
    ia&* this;
}

std::vector<u8> System::SaveStateBuffer() const {
    std::ostringstream sstream{std::ios_base::binary};
    // Serialize
    oarchive oa{sstream};
    oa&* this;

    const std::string& str{sstream.str()};
    const auto data = std::span<const u8>{reinterpret_cast<const u8*>(str.data()), str.size()};
    auto buffer = Common::Compression::CompressDataZSTDDefault(data);

    CSTHeader header{};
    header.filetype = header_magic_bytes;
    header.program_id = title_id;
    std::string rev_bytes;
    CryptoPP::StringSource ss(Common::g_scm_rev, true,
                              new CryptoPP::HexDecoder(new CryptoPP::StringSink(rev_bytes)));
    std::memcpy(header.revision.data(), rev_bytes.data(), sizeof(header.revision));
    header.time = std::chrono::duration_cast<std::chrono::seconds>(
                      std::chrono::system_clock::now().time_since_epoch())
                      .count();
    const std::string build_fullname = Common::g_build_fullname;
    std::memset(header.build_name.data(), 0, sizeof(header.build_name));
    std::memcpy(header.build_name.data(), build_fullname.c_str(),
                std::min(build_fullname.length(), sizeof(header.build_name) - 1));

    const std::string build_version = Common::g_build_version;
    std::memset(header.build_version.data(), 0, sizeof(header.build_version));
    std::memcpy(header.build_version.data(), build_version.c_str(),
                std::min(build_version.length(), sizeof(header.build_version) - 1));

    std::vector<u8> result((u8*)&header, (u8*)&header + sizeof(header));
    std::copy(buffer.begin(), buffer.end(), std::back_inserter(result));

    return result;
}

bool System::LoadStateBuffer(std::vector<u8> buffer) {
    CSTHeader header;

    if (buffer.size() < sizeof(header)) {
        LOG_ERROR(Core, "Save state too small");
        return false;
    }

    header = *((CSTHeader*)buffer.data());

    if (header.filetype != header_magic_bytes) {
        LOG_ERROR(Core, "Invalid save state");
        return false;
    }

    if (header.program_id != title_id) {
        LOG_ERROR(Core, "Save state isn't for the current game");
        return false;
    }
    std::string revision = fmt::format("{:02x}", fmt::join(header.revision, ""));
    if (revision != Common::g_scm_rev) {
        LOG_ERROR(Core,
                  "Save state file created from a different revision (core: {}, savestate: {})",
                  Common::g_scm_rev, revision);
        return false;
    }

    std::vector<u8> state(buffer.begin() + sizeof(CSTHeader), buffer.end());
    auto decompressed = Common::Compression::DecompressDataZSTD(state);

    std::istringstream sstream{
        std::string{reinterpret_cast<char*>(decompressed.data()), decompressed.size()},
        std::ios_base::binary};
    decompressed.clear();

    // Deserialize
    iarchive ia{sstream};
    ia&* this;

    return true;
}

} // namespace Core
