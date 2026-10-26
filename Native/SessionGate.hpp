// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <condition_variable>
#include <mutex>

// A paused session sleeps on a condition variable instead of consuming a CPU core.
class SessionGate {
public:
    enum class Wake { Stopped, Run, Command };
    void begin() {
        std::lock_guard lock(mutex_);
        running_ = true;
        paused_ = false;
        work_pending_ = false;
    }
    void pause(bool paused) {
        {
            std::lock_guard lock(mutex_);
            paused_ = paused;
        }
        condition_.notify_all();
    }
    void stop() {
        {
            std::lock_guard lock(mutex_);
            running_ = false;
        }
        condition_.notify_all();
    }
    bool waitUntilRunnable() {
        std::unique_lock lock(mutex_);
        condition_.wait(lock, [this] { return !running_ || !paused_; });
        return running_;
    }
    // Utility commands may run at a safe core boundary even while paused.
    void notifyWork() {
        {
            std::lock_guard lock(mutex_);
            work_pending_ = true;
        }
        condition_.notify_all();
    }
    Wake waitForWork() {
        std::unique_lock lock(mutex_);
        condition_.wait(lock, [this] { return !running_ || !paused_ || work_pending_; });
        if (!running_) return Wake::Stopped;
        if (work_pending_) {
            work_pending_ = false;
            return Wake::Command;
        }
        return Wake::Run;
    }
    bool isPaused() {
        std::lock_guard lock(mutex_);
        return paused_;
    }
private:
    std::mutex mutex_;
    std::condition_variable condition_;
    bool running_ = false;
    bool paused_ = false;
    bool work_pending_ = false;
};
