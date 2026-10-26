// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstring>
#include <span>
#include <cstdint>
#include <type_traits>

namespace AudioCore {
inline constexpr std::size_t mobile_latency_frames = 6144; // 128 ms at 48 kHz
inline constexpr std::size_t mobile_producer_frames = 1024;

// One producer and the RemoteIO consumer. Neither side takes a mutex.
// Index publication makes sample storage visible before the consumer reads it.
template <typename Sample>
class MobileAudioBufferT {
public:
    static_assert(std::is_same_v<Sample, float> || std::is_same_v<Sample, std::int16_t>);
    static constexpr std::size_t capacity = 16384;
    static_assert(std::atomic_size_t::is_always_lock_free);

    explicit MobileAudioBufferT(std::size_t target = mobile_latency_frames) noexcept
        : target_frames(std::clamp<std::size_t>(target, 1, capacity)) {}
    std::size_t TargetFrames() const noexcept { return target_frames; }
    std::uint64_t Underruns() const noexcept { return underruns.load(std::memory_order_relaxed); }

    // Called by the producer; the consumer can only make more space available.
    std::size_t BufferedFrames() const noexcept {
        const auto written = write_index.load(std::memory_order_relaxed);
        return written - read_index.load(std::memory_order_acquire);
    }

    std::size_t Push(std::span<const Sample> stereo) noexcept {
        const auto written = write_index.load(std::memory_order_relaxed);
        const auto read = read_index.load(std::memory_order_acquire);
        const auto count = std::min(stereo.size() / 2, capacity - (written - read));
        if (count == 0) return 0;
        const auto position = written % capacity;
        const auto first = std::min(count, capacity - position);
        std::memcpy(samples.data() + position * 2, stereo.data(), first * 2 * sizeof(Sample));
        std::memcpy(samples.data(), stereo.data() + first * 2, (count - first) * 2 * sizeof(Sample));
        write_index.store(written + count, std::memory_order_release);
        return count;
    }

    // Solely the audio callback owns priming/fade state. Underflow fades to
    // silence and re-primes, rather than repeatedly emitting a nonzero DC sample.
    std::size_t Read(std::span<Sample> stereo, std::size_t minimumFrames = 0) noexcept {
        const auto requested = stereo.size() / 2;
        if (requested == 0) return 0;
        std::fill(stereo.begin(), stereo.end(), Sample{});
        const auto read = read_index.load(std::memory_order_relaxed);
        const auto written = write_index.load(std::memory_order_acquire);
        const auto available = written - read;
        if (!primed) {
            if (available < std::max(target_frames, std::min(minimumFrames, capacity))) return 0;
            primed = true;
            fade_in_remaining = fade_frames;
        }
        const auto count = std::min(requested, available);
        const auto position = read % capacity;
        const auto first = std::min(count, capacity - position);
        std::memcpy(stereo.data(), samples.data() + position * 2, first * 2 * sizeof(Sample));
        std::memcpy(stereo.data() + first * 2, samples.data(), (count - first) * 2 * sizeof(Sample));
        read_index.store(read + count, std::memory_order_release);
        for (std::size_t i = 0; i < count && fade_in_remaining != 0; ++i) {
            const float gain = static_cast<float>(fade_frames - fade_in_remaining + 1) / fade_frames;
            stereo[i * 2] = static_cast<Sample>(stereo[i * 2] * gain);
            stereo[i * 2 + 1] = static_cast<Sample>(stereo[i * 2 + 1] * gain);
            --fade_in_remaining;
        }
        if (count != 0) {
            last = {stereo[(count - 1) * 2], stereo[(count - 1) * 2 + 1]};
        }
        if (count < requested) {
            underruns.fetch_add(1, std::memory_order_relaxed);
            const auto fade = std::min(fade_frames, requested - count);
            for (std::size_t i = 0; i < fade; ++i) {
                const float gain = 1.0f - static_cast<float>(i + 1) / fade;
                stereo[(count + i) * 2] = static_cast<Sample>(last[0] * gain);
                stereo[(count + i) * 2 + 1] = static_cast<Sample>(last[1] * gain);
            }
            primed = false;
            last = {};
        }
        return count;
    }

    // The callback is the only caller while running. Samples stay queued so
    // a deliberate pause freezes playback, instead of discarding its history.
    void Mute() noexcept {
        fade_in_remaining = fade_frames;
        last = {};
    }

    // Sole consumer only. A playback-rate transition drops old history so
    // returning to normal speed cannot replay stale accelerated-game audio.
    void Discard() noexcept {
        read_index.store(write_index.load(std::memory_order_acquire), std::memory_order_release);
        primed = false;
        Mute();
    }

    // Both threads must have stopped before resetting indices.
    void ResetStopped() noexcept {
        read_index.store(0, std::memory_order_relaxed);
        write_index.store(0, std::memory_order_relaxed);
        primed = false;
        fade_in_remaining = 0;
        last = {};
    }

private:
    const std::size_t target_frames;
    std::atomic<std::uint64_t> underruns{0};
    static constexpr std::size_t fade_frames = 96; // 2 ms
    alignas(128) std::atomic_size_t read_index{0};
    alignas(128) std::atomic_size_t write_index{0};
    std::array<Sample, capacity * 2> samples{};
    bool primed = false;
    std::size_t fade_in_remaining = 0;
    std::array<Sample, 2> last{};
};
using MobileAudioBuffer = MobileAudioBufferT<float>;
using MobilePCM16Buffer = MobileAudioBufferT<std::int16_t>;
} // namespace AudioCore
