// Copyright 2023-2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
#pragma once
#include <atomic>
#include <condition_variable>
#include <mutex>

namespace Common {
struct AsyncHandle {
    AsyncHandle(bool done = false) : is_done{done} {}

    [[nodiscard]] bool IsDone() noexcept {
        // Observing completion must also publish the shader/pipeline handle.
        return is_done.load(std::memory_order::acquire);
    }
    void WaitDone() noexcept {
        std::unique_lock lock{mutex};
        condvar.wait(lock, [this] { return IsDone(); });
    }
    void MarkDone(bool done = true) noexcept {
        {
            std::scoped_lock lock{mutex};
            is_done.store(done, std::memory_order::release);
        }
        condvar.notify_all();
    }
private:
    std::condition_variable condvar;
    std::mutex mutex;
    std::atomic_bool is_done{false};
};
}
