// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <span>
namespace ClawRetro {
// A single producer and consumer. No allocation, locking or waits in playback.
class AudioRing {
    static constexpr std::size_t capacity = 16384;
    std::array<std::int16_t, capacity * 2> samples{};
    alignas(128) std::atomic_size_t written{0};
    alignas(128) std::atomic_size_t read{0};
public:
    std::size_t bufferedFrames() const noexcept {
        const auto r = read.load(std::memory_order_acquire);
        return written.load(std::memory_order_acquire) - r;
    }
    std::size_t push(std::span<const std::int16_t> input) noexcept {
        if (input.size() < 2) return 0;
        const auto w = written.load(std::memory_order_relaxed);
        const auto r = read.load(std::memory_order_acquire);
        const auto n = std::min(input.size() / 2, capacity - (w - r));
        const auto first = std::min(n, capacity - w % capacity);
        std::memcpy(samples.data() + w % capacity * 2, input.data(), first * 4);
        std::memcpy(samples.data(), input.data() + first * 2, (n - first) * 4);
        written.store(w + n, std::memory_order_release); return n;
    }
    std::size_t pop(std::int16_t* output, std::size_t frames) noexcept {
        if (!output || !frames) return 0;
        const auto r = read.load(std::memory_order_relaxed);
        const auto w = written.load(std::memory_order_acquire);
        const auto n = std::min(frames, w - r);
        const auto first = std::min(n, capacity - r % capacity);
        std::memcpy(output, samples.data() + r % capacity * 2, first * 4);
        std::memcpy(output + first * 2, samples.data(), (n - first) * 4);
        read.store(r + n, std::memory_order_release); return n;
    }
    // Consumer only, including on pause, speed change and state restoration.
    void discard() noexcept { read.store(written.load(std::memory_order_acquire), std::memory_order_release); }
    // Consumer only. Recover from a delayed converter without replaying a
    // growing backlog of stale game audio.
    std::size_t trimTo(std::size_t maximum) noexcept {
        const auto r = read.load(std::memory_order_relaxed);
        const auto w = written.load(std::memory_order_acquire);
        const auto available = w - r;
        if (available <= maximum) return 0;
        const auto dropped = available - maximum;
        read.store(r + dropped, std::memory_order_release);
        return dropped;
    }
};
}
