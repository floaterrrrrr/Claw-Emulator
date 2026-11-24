// Copyright 2020 yuzu Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

#pragma once

#include <atomic>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <type_traits>
#include <vector>
#include <queue>

#include "common/polyfill_thread.h"
#include "common/thread.h"
#include "common/thread_qos.h"
#include "common/unique_function.h"

namespace Common {

enum class WorkPriority { Urgent, Background };

template <class StateType = void>
class StatefulThreadWorker {
    static constexpr bool with_state = !std::is_same_v<StateType, void>;

    struct DummyCallable {
        int operator()(std::size_t) const noexcept {
            return 0;
        }
    };

    using Task =
        std::conditional_t<with_state, UniqueFunction<void, StateType*>, UniqueFunction<void>>;
    using StateMaker =
        std::conditional_t<with_state, std::function<StateType(std::size_t)>, DummyCallable>;

public:
    using WorkId = std::size_t;

    explicit StatefulThreadWorker(std::size_t num_workers, std::string_view name,
                                  StateMaker func = {}, ThreadQoS qos = ThreadQoS::Inherit)
        : workers_queued{num_workers}, thread_name{name} {
        const auto lambda = [this, func, qos](std::stop_token stop_token, std::size_t index) {
            Common::SetCurrentThreadName(thread_name.data());
            Common::ConfigureCurrentThreadQoS(qos);
            {
                [[maybe_unused]] std::conditional_t<with_state, StateType, int> state{func(index)};
                while (!stop_token.stop_requested()) {
                    Task task;
                    bool is_background;
                    {
                        std::unique_lock lock{queue_mutex};
                        Common::CondvarWait(condition, lock, stop_token,
                                            [this] { return !requests.empty() || background; });
                        if (stop_token.stop_requested()) {
                            break;
                        }
                        is_background = requests.empty();
                        if (is_background) {
                            task = std::move(background->task);
                            background.reset();
                            background_running = true;
                        } else {
                            task = std::move(requests.front());
                            requests.pop();
                        }
                    }
                    const auto boost = is_background ? ThreadQoS::Inherit
                                                     : urgent_qos.load(std::memory_order_acquire);
                    if (boost != ThreadQoS::Inherit) {
                        Common::ConfigureCurrentThreadQoS(boost);
                    }
                    if constexpr (with_state) {
                        task(&state);
                    } else {
                        task();
                    }
                    if (boost != ThreadQoS::Inherit) {
                        Common::ConfigureCurrentThreadQoS(qos);
                    }
                    task = Task{};
                    {
                        std::scoped_lock lock{queue_mutex};
                        if (is_background) {
                            background_running = false;
                        }
                        ++work_done;
                    }
                    wait_condition.notify_all();
                }
            }
            {
                std::scoped_lock lock{queue_mutex};
                ++workers_stopped;
            }
            wait_condition.notify_all();
        };
        threads.reserve(num_workers);
        for (std::size_t i = 0; i < num_workers; ++i) {
            threads.emplace_back(lambda, i);
        }
    }

    StatefulThreadWorker& operator=(const StatefulThreadWorker&) = delete;
    StatefulThreadWorker(const StatefulThreadWorker&) = delete;

    StatefulThreadWorker& operator=(StatefulThreadWorker&&) = delete;
    StatefulThreadWorker(StatefulThreadWorker&&) = delete;

    // Background admission is best-effort. A zero ID lets the producer defer
    // the request without leaving an unbounded queue for a lifetime drain.
    WorkId QueueWork(Task work, WorkPriority priority = WorkPriority::Urgent) {
        WorkId id;
        {
            std::unique_lock lock{queue_mutex};
            id = work_scheduled + 1;
            if (priority == WorkPriority::Background) {
                if (background || background_running) {
                    return 0;
                }
                background.emplace(BackgroundWork{id, std::move(work)});
            } else {
                requests.emplace(std::move(work));
            }
            ++work_scheduled;
        }
        condition.notify_one();
        return id;
    }

    void PromoteWork(WorkId id) {
        std::scoped_lock lock{queue_mutex};
        if (background && background->id == id) {
            requests.emplace(std::move(background->task));
            background.reset();
            condition.notify_one();
        }
    }

    void SetUrgentQoS(ThreadQoS qos) {
        urgent_qos.store(qos, std::memory_order_release);
    }

    void WaitForRequests(std::stop_token stop_token = {}) {
        std::stop_callback callback(stop_token, [this] {
            for (auto& thread : threads) {
                thread.request_stop();
            }
        });
        std::unique_lock lock{queue_mutex};
        wait_condition.wait(lock, [this] {
            return workers_stopped >= workers_queued || work_done >= work_scheduled;
        });
    }

    const std::size_t NumWorkers() const noexcept {
        return threads.size();
    }

private:
    struct BackgroundWork {
        WorkId id;
        Task task;
    };

    std::queue<Task> requests;
    std::optional<BackgroundWork> background;
    bool background_running{};
    std::mutex queue_mutex;
    std::condition_variable_any condition;
    std::condition_variable wait_condition;
    std::atomic<std::size_t> work_scheduled{};
    std::atomic<std::size_t> work_done{};
    std::atomic<std::size_t> workers_stopped{};
    std::atomic<ThreadQoS> urgent_qos{ThreadQoS::Inherit};
    std::atomic<std::size_t> workers_queued{};
    std::string_view thread_name;
    std::vector<std::jthread> threads;
};

using ThreadWorker = StatefulThreadWorker<>;

} // namespace Common
