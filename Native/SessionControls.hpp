// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <atomic>
#include <chrono>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <memory>
#include "AsyncStateOperation.hpp"

namespace Core { class System; }

namespace Claw {
enum class StateStatus : int { Idle = 0, Pending = 1, Saved = 2, Restored = 3, Failed = -1 };
struct StateRequest { bool restore; unsigned slot; };

class StateRequestQueue {
public:
    bool request(bool restore, int slot) {
        std::lock_guard lock(mutex_);
        if (slot < 1 || slot > 11 || status_ == StateStatus::Pending) return false;
        request_ = StateRequest{restore, static_cast<unsigned>(slot)};
        status_ = StateStatus::Pending;
        error_.clear();
        return true;
    }
    std::optional<StateRequest> take() {
        std::lock_guard lock(mutex_);
        return std::exchange(request_, std::nullopt);
    }
    void complete(StateStatus status, std::string error = {}) {
        std::lock_guard lock(mutex_);
        status_ = status;
        error_ = std::move(error);
    }
    StateStatus status() const {
        std::lock_guard lock(mutex_);
        return status_;
    }
    std::string error() const {
        std::lock_guard lock(mutex_);
        return error_;
    }
    void cancel() {
        std::lock_guard lock(mutex_);
        request_.reset();
        if (status_ == StateStatus::Pending) {
            status_ = StateStatus::Failed;
            error_ = "The game stopped before the state operation completed.";
        }
    }
    void reset() {
        std::lock_guard lock(mutex_);
        request_.reset();
        status_ = StateStatus::Idle;
        error_.clear();
    }
private:
    mutable std::mutex mutex_;
    std::optional<StateRequest> request_;
    StateStatus status_ = StateStatus::Idle;
    std::string error_;
};

class SessionControls {
public:
    std::atomic<int> speedMultiplier{1};
    StateRequestQueue states;
    std::function<void()> wake;
    // Called only on the emulation thread; core settings never change on the UI thread.
    void process(Core::System& system, bool paused);
    // Called before starting a session, after the preceding core thread has joined.
    void joinStateWorker() { operation_.reset(); }
    void reset() {
        joinStateWorker();
        speedMultiplier.store(1);
        states.reset();
        processing_.reset();
        applied_speed_.reset();
    }
private:
    std::unique_ptr<AsyncStateOperation> operation_;
    std::optional<StateRequest> processing_;
    std::optional<int> applied_speed_;
    std::chrono::steady_clock::time_point deadline_;
};
} // namespace Claw
