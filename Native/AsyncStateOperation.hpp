// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <atomic>
#include <condition_variable>
#include <exception>
#include <functional>
#include <mutex>
#include <string>
#include <stdexcept>
#include <thread>
#if defined(__APPLE__)
#include <pthread/qos.h>
#endif

namespace Claw {
#if defined(__APPLE__)
void WithStateAutoreleasePool(void (*task)(void*), void* context);
#endif
// One operation at a time. Only the snapshot/apply phase owns the stopped core;
// preparation, compression and persistence proceed while guest execution resumes.
class AsyncStateOperation {
public:
    enum class Phase { Preparing, Ready, Boundary, Background, Done };
    AsyncStateOperation(std::function<void()> prepare, std::function<void()> boundary,
                        std::function<void()> persist, std::function<void()> notify = {})
        : worker([this, prepare = std::move(prepare), boundary = std::move(boundary),
                  persist = std::move(persist), notify = std::move(notify)] {
            auto task = [&] {
#if defined(__APPLE__)
                pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
#endif
                try {
                    prepare();
                    {
                        std::unique_lock lock(mutex);
                        phase.store(Phase::Ready, std::memory_order_release);
                        cv.notify_all();
                        if (notify) notify();
                        cv.wait(lock, [this] { return permitted || cancelled; });
                        if (cancelled) throw std::runtime_error("The game stopped before capture.");
                    }
                    phase.store(Phase::Boundary, std::memory_order_release);
                    boundary_started.store(true, std::memory_order_release);
#if defined(__APPLE__)
                    // The guest waits only for coherent capture/apply. Do not leave
                    // that short phase at the lower disk/compression priority.
                    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
#endif
                    boundary();
#if defined(__APPLE__)
                    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
#endif
                    {
                        std::lock_guard lock(mutex);
                        phase.store(Phase::Background, std::memory_order_release);
                        cv.notify_all();
                    }
                    persist();
                } catch (const std::exception& e) {
                    std::lock_guard lock(mutex); error = e.what();
                } catch (...) {
                    std::lock_guard lock(mutex); error = "The state operation failed.";
                }
                {
                    std::lock_guard lock(mutex);
                    phase.store(Phase::Done, std::memory_order_release);
                    cv.notify_all();
                }
                if (notify) notify();
            };
#if defined(__APPLE__)
            WithStateAutoreleasePool([](void* context) {
                (*static_cast<decltype(task)*>(context))();
            }, &task);
#else
            task();
#endif
        }) {}
    ~AsyncStateOperation() { join(); }
    AsyncStateOperation(const AsyncStateOperation&) = delete;
    AsyncStateOperation& operator=(const AsyncStateOperation&) = delete;
    bool atBoundary() {
        std::unique_lock lock(mutex);
        if (phase.load(std::memory_order_acquire) != Phase::Ready) return false;
        permitted = true; cv.notify_all();
        cv.wait(lock, [this] {
            const auto current = phase.load(std::memory_order_acquire);
            return current == Phase::Background || current == Phase::Done;
        });
        return true;
    }
    Phase current() const { return phase.load(std::memory_order_acquire); }
    bool boundaryStarted() const { return boundary_started.load(std::memory_order_acquire); }
    std::string failure() { std::lock_guard lock(mutex); return error; }
    void join() {
        { std::lock_guard lock(mutex); cancelled = true; cv.notify_all(); }
        if (worker.joinable()) worker.join();
    }
private:
    std::mutex mutex;
    std::condition_variable cv;
    std::atomic<Phase> phase{Phase::Preparing};
    std::atomic<bool> boundary_started{false};
    bool permitted{}, cancelled{};
    std::string error;
    std::thread worker;
};
}
