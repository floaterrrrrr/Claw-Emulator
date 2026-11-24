// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <atomic>
#include <cstdint>

namespace Claw {
// The owner thread advances this policy; UI only reads it. Old presentation
// slots carry their generation, so their fences cannot reveal a new restore.
class RestorePresentation {
public:
    void Begin() {
        warmed.store(false);
        completed.store(0);
        generation.fetch_add(1);
    }
    void Warmed() { warmed.store(true); }
    std::uint64_t Generation() const { return generation.load(); }
    void Completed(std::uint64_t token) {
        if (token != 0 && token == Generation() && warmed.load()) completed.fetch_add(1);
    }
    bool AwaitingFrames() const { return Generation() != 0 && completed.load() < 5; }
    bool HasCompletedFrame() const { return Generation() != 0 && completed.load() != 0; }
    bool BypassScaler() const { return Generation() != 0 && completed.load() < 3; }
    bool Ready() const { return Generation() != 0 && warmed.load() && completed.load() >= 5; }
    void Reset() { Begin(); }
private:
    std::atomic<std::uint64_t> generation{0};
    std::atomic<unsigned> completed{0};
    std::atomic<bool> warmed{false};
};
inline RestorePresentation restore_presentation;
} // namespace Claw
