// Copyright 2020-2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

#pragma once

#include <array>
#include <string>
#include <vector>
#include "common/common_types.h"

namespace Core {

struct StateSnapshot {
    std::array<u8, 256> header{};
    std::string contents;
    std::vector<u8> preview; // Optional 400x240 RGBA; never part of the CST archive.
};

// Background-only disk/compression stages; they never access a running System.
void WriteStateSnapshot(StateSnapshot snapshot, const std::string& path);
std::string ReadStateSnapshot(const std::string& path, u64 expected_title);

struct SaveStateInfo {
    u32 slot;
    u64 time;
    enum class ValidationStatus {
        OK,
        RevisionMismatch,
        BuildMismatch,
    } status;
    std::string build_name;
    std::string build_version;
};

constexpr u32 SaveStateSlotCount = 11; // Maximum count of savestate slots

std::vector<SaveStateInfo> ListSaveStates(u64 program_id, u64 movie_id);

SaveStateInfo GetSaveStateInfo(u64 program_id, u64 movie_id, u32 slot);

} // namespace Core
