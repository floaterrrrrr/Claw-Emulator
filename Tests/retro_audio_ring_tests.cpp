// SPDX-License-Identifier: GPL-3.0-or-later
#include "Retro/AudioRing.hpp"
#include <cassert>
#include <thread>
int main() {
    ClawRetro::AudioRing ring;
    constexpr std::size_t total = 1000000;
    std::thread producer([&] {
        std::array<std::int16_t, 514> block{};
        for (std::size_t sent = 0; sent < total;) {
            const auto count = std::min<std::size_t>(257, total - sent);
            for (std::size_t i = 0; i < count; ++i) {
                block[i * 2] = static_cast<std::int16_t>((sent + i) % 32000);
                block[i * 2 + 1] = static_cast<std::int16_t>(-block[i * 2]);
            }
            const auto pushed = ring.push({block.data(), count * 2});
            sent += pushed;
            if (!pushed) std::this_thread::yield();
        }
    });
    std::array<std::int16_t, 126> block{};
    for (std::size_t received = 0; received < total;) {
        const auto count = ring.pop(block.data(), block.size() / 2);
        for (std::size_t i = 0; i < count; ++i) {
            assert(block[i * 2] == static_cast<std::int16_t>((received + i) % 32000));
            assert(block[i * 2 + 1] == -block[i * 2]);
        }
        received += count;
        if (!count) std::this_thread::yield();
    }
    producer.join();
    assert(!ring.pop(block.data(), 1));
    assert(!ring.push({}));
    assert(!ring.pop(nullptr, 0));
    assert(ring.push(block) == block.size() / 2);
    ring.discard();
    assert(!ring.pop(block.data(), 1));
    std::array<std::int16_t, 4096> history{};
    for (std::size_t i = 0; i < history.size() / 2; ++i) {
        history[i * 2] = static_cast<std::int16_t>(i);
        history[i * 2 + 1] = -history[i * 2];
    }
    assert(ring.push(history) == 2048 && ring.bufferedFrames() == 2048);
    assert(ring.trimTo(512) == 1536 && ring.bufferedFrames() == 512);
    assert(ring.trimTo(1024) == 0);
    assert(ring.pop(block.data(), 1) == 1 && block[0] == 1536 && block[1] == -1536);
    assert(ring.trimTo(0) == 511 && ring.bufferedFrames() == 0);
    // Trim concurrently with a producer wrapping the ring. Retained audio must
    // keep complete stereo pairs and sample order, even while old data is shed.
    std::atomic_bool finished{false};
    std::thread recoveryProducer([&] {
        std::array<std::int16_t, 514> packet{};
        for (std::size_t sent = 0; sent < total;) {
            const auto count = std::min<std::size_t>(257, total - sent);
            for (std::size_t i = 0; i < count; ++i) {
                packet[i * 2] = static_cast<std::int16_t>((sent + i) % 32000);
                packet[i * 2 + 1] = -packet[i * 2];
            }
            sent += ring.push({packet.data(), count * 2});
        }
        finished.store(true, std::memory_order_release);
    });
    std::size_t recovered = 0;
    while (!finished.load(std::memory_order_acquire) || ring.bufferedFrames()) {
        ring.trimTo(512);
        const auto count = ring.pop(block.data(), block.size() / 2);
        for (std::size_t i = 0; i < count; ++i) {
            assert(block[i * 2 + 1] == -block[i * 2]);
            if (i) assert(block[i * 2] == (block[(i - 1) * 2] + 1) % 32000);
        }
        recovered += count;
    }
    recoveryProducer.join(); assert(recovered > 0);
}
