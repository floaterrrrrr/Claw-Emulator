// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "AudioRing.hpp"
#include "PresentationPolicy.hpp"
// libretro documents callback fields as functions and marks legacy types as
// deprecated in prose. Suppress only those vendor documentation diagnostics;
// restore the application's warnings immediately after the external header.
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#pragma clang diagnostic ignored "-Wdocumentation-deprecated-sync"
#endif
#include "libretro.h"
#if defined(__clang__)
#pragma clang diagnostic pop
#endif
#include <atomic>
#include <array>
#include <condition_variable>
#include <cstdint>
#include <future>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>
namespace ClawRetro {
struct Frame {
    unsigned width{}, height{}; std::uint64_t sequence{};
    std::chrono::steady_clock::time_point publishedAt{};
    std::vector<std::uint32_t> bgra;
};
struct Configuration {
    int core{}; std::uint64_t title{};
    std::string rom, directory, library, revision;
};
class Runtime final {
public:
    explicit Runtime(Configuration config);
    ~Runtime();
    void start(); // Returns paused, after the selected core has loaded.
    void stop(); // Joins emulation and disk operations before unloading its library.
    void requestStop() noexcept;
    void pause(bool value) noexcept;
    void setSpeed(int value) noexcept;
    void button(unsigned key, bool pressed) noexcept;
    void analog(float x, float y) noexcept;
    void touch(float x, float y, bool down) noexcept; // native 256x192 coordinates
    bool state(int slot, bool restore);
    bool running() const noexcept { return alive.load(); }
    bool paused() const noexcept { return isPaused.load(); }
    int speed() const noexcept { return multiplier.load(); }
    double sampleRate() const noexcept { return audioRate.load(); }
    double fps() const noexcept { return measuredFPS.load(); }
    double nativeFPS() const noexcept { return nominalFPS.load(std::memory_order_relaxed); }
    int coreType() const noexcept { return config.core; }
    unsigned epoch() const noexcept { return audioEpoch.load(); }
    int stateStatus() const noexcept { return stateResult.load(); }
    std::string error() const;
    std::shared_ptr<const Frame> frame() const;
    std::shared_ptr<const Frame> waitForFrame(std::uint64_t after, const std::atomic_bool& cancelled) const;
    void wakeFrameWaiters() noexcept;
    AudioRing audio;
    PresentationStatistics presentation;
    std::atomic_size_t outputAudioFrames{0};
    std::atomic<std::uint64_t> audioUnderruns{0};
    std::atomic<unsigned> audioClockChanges{0};
    std::atomic<unsigned> audioConversionErrors{0};
    std::atomic_size_t outputAudioTarget{1024}, sourceAudioFrames{0};
    std::atomic<std::uint64_t> staleAudioFrames{0}, droppedAudioFrames{0};
    std::atomic<double> coreWorkMS{0}, displayQueueMS{0};
private:
    struct API {
        decltype(&retro_init) init{}; decltype(&retro_deinit) deinit{};
        decltype(&retro_set_environment) setEnvironment{};
        decltype(&retro_set_video_refresh) setVideo{};
        decltype(&retro_set_audio_sample) setAudio{};
        decltype(&retro_set_audio_sample_batch) setAudioBatch{};
        decltype(&retro_set_input_poll) setPoll{};
        decltype(&retro_set_input_state) setInput{};
        decltype(&retro_get_system_info) info{};
        decltype(&retro_get_system_av_info) avInfo{};
        decltype(&retro_set_controller_port_device) setController{};
        decltype(&retro_load_game) load{}; decltype(&retro_unload_game) unload{};
        decltype(&retro_run) run{}; decltype(&retro_serialize_size) stateSize{};
        decltype(&retro_serialize) serialize{}; decltype(&retro_unserialize) restore{};
        decltype(&retro_get_memory_data) memory{}; decltype(&retro_get_memory_size) memorySize{};
    } api;
    Configuration config;
    void* library{};
    bool initialized{}, loaded{}, batteryPersistenceAllowed{};
    std::string systemDirectory, saveDirectory, romPath;
    std::vector<std::uint8_t> romBytes;
    std::map<std::string, std::string> options;
    unsigned pixelFormat = RETRO_PIXEL_FORMAT_0RGB1555;
    retro_frame_time_callback frameTime{};
    std::atomic_bool alive{false}, isPaused{true}, stopping{false};
    std::atomic_int multiplier{1}, stateResult{0}, request{0};
    std::atomic_uint buttons{0}, analogButtons{0}, touchValue{0}, audioEpoch{0};
    std::atomic<double> audioRate{48000}, measuredFPS{0};
    std::atomic<double> nominalFPS{60};
    mutable std::mutex frameMutex, errorMutex;
    mutable std::condition_variable frameReady;
    std::shared_ptr<Frame> latest;
    std::string lastError;
    std::thread worker;
    std::condition_variable wake;
    std::mutex waitMutex;
    std::future<void> disk;
    std::future<void> batteryDisk;
    std::shared_ptr<std::vector<std::uint8_t>> pendingBytes;
    int activeCommand{};
    std::array<std::optional<std::uint32_t>, 2> batteryChecksums{}, pendingBatteryChecksums{};
    static thread_local Runtime* active;
    void loop() noexcept;
    void stateBoundary(int command);
    void persistBattery();
    bool finishBattery(bool wait);
    void setError(const std::string& value);
    void video(const void*, unsigned, unsigned, std::size_t);
    bool environment(unsigned, void*);
    bool updateAVTiming(const retro_system_av_info&);
    static bool environmentCallback(unsigned, void*);
    static void videoCallback(const void*, unsigned, unsigned, std::size_t);
    static void sampleCallback(std::int16_t, std::int16_t);
    static std::size_t audioCallback(const std::int16_t*, std::size_t);
    static std::int16_t inputCallback(unsigned, unsigned, unsigned, unsigned);
    static void logCallback(retro_log_level, const char*, ...);
};
}
