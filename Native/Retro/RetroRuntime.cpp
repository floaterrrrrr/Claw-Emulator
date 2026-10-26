// SPDX-License-Identifier: GPL-3.0-or-later
#include "RetroRuntime.hpp"
#include <lodepng.h>
#include <zlib.h>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <dlfcn.h>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#if defined(__APPLE__)
#include <pthread.h>
#include <pthread/qos.h>
#endif
namespace ClawRetro {
namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;
thread_local Runtime* Runtime::active = nullptr;
namespace {
constexpr std::size_t maxState = 128 * 1024 * 1024;
struct BatteryPart { unsigned type; const char* name; std::size_t maximum; };
constexpr BatteryPart batteryParts[] = {{RETRO_MEMORY_SAVE_RAM, "battery.srm", 32 * 1024 * 1024},
                                       {RETRO_MEMORY_RTC, "clock.rtc", 64 * 1024}};
void diskThread() {
#if defined(__APPLE__)
    pthread_setname_np("ClawRetroSaveIO");
    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
#endif
}
std::string stem(std::uint64_t title) {
    char value[17]; std::snprintf(value, sizeof(value), "%016llX", static_cast<unsigned long long>(title)); return value;
}
std::string statePath(const Configuration& c, int slot) {
    char value[32]; std::snprintf(value, sizeof(value), "%s.%02d.cst", stem(c.title).c_str(), slot);
    return (fs::path(c.directory) / "save_states" / value).string();
}
std::vector<std::uint8_t> readFile(const std::string& path, std::size_t maximum) {
    const auto size = fs::file_size(path);
    if (!size || size > maximum) throw std::runtime_error("File size is invalid or exceeds the supported limit.");
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(size));
    std::ifstream file(path, std::ios::binary);
    if (!file.read(reinterpret_cast<char*>(bytes.data()), bytes.size())) throw std::runtime_error("Could not read the complete file.");
    return bytes;
}
void atomicWrite(const std::string& path, const std::vector<std::uint8_t>& bytes) {
    const auto temporary = path + ".tmp";
    try {
        std::ofstream file(temporary, std::ios::binary | std::ios::trunc);
        if (!file.write(reinterpret_cast<const char*>(bytes.data()), bytes.size()) || !file.flush())
            throw std::runtime_error("Could not write the save. Check available storage.");
        file.close(); if (file.fail()) throw std::runtime_error("Could not close the save file.");
        fs::rename(temporary, path);
    } catch (...) { std::error_code e; fs::remove(temporary, e); throw; }
}
void put(std::vector<std::uint8_t>& v, std::size_t at, std::uint64_t n) {
    for (unsigned i = 0; i < 8; ++i) v[at + i] = static_cast<std::uint8_t>(n >> (i * 8));
}
std::uint64_t get(const std::vector<std::uint8_t>& v, std::size_t at) {
    std::uint64_t n = 0; for (unsigned i = 0; i < 8; ++i) n |= std::uint64_t(v.at(at + i)) << (i * 8); return n;
}
void writeState(const Configuration& c, int slot, const std::vector<std::uint8_t>& bytes, std::shared_ptr<const Frame> frame) {
    uLongf size = compressBound(bytes.size()); std::vector<std::uint8_t> out(256 + size);
    if (compress2(out.data() + 256, &size, bytes.data(), bytes.size(), Z_BEST_SPEED) != Z_OK)
        throw std::runtime_error("Could not compress the save state.");
    out.resize(256 + size); std::memcpy(out.data(), "CRS\x01", 4);
    put(out, 4, c.title); put(out, 16, bytes.size()); put(out, 24, crc32(0, bytes.data(), bytes.size()));
    put(out, 32, std::time(nullptr)); put(out, 40, c.core);
    std::memcpy(out.data() + 64, c.revision.data(), std::min<std::size_t>(c.revision.size(), 64));
    const auto path = statePath(c, slot); atomicWrite(path, out);
    std::error_code error; fs::remove(path + ".png", error);
    try {
        if (!frame) return;
        const unsigned h = c.core == 3 ? frame->height / 2 : frame->height;
        std::vector<std::uint8_t> rgba(frame->width * h * 4);
        for (std::size_t i = 0; i < rgba.size() / 4; ++i) {
            const auto pixel = frame->bgra[i]; rgba[i*4] = pixel >> 16; rgba[i*4+1] = pixel >> 8;
            rgba[i*4+2] = pixel; rgba[i*4+3] = 255;
        }
        std::vector<std::uint8_t> png;
        if (!lodepng::encode(png, rgba, frame->width, h)) atomicWrite(path + ".png", png);
    } catch (...) {} // A preview failure must never invalidate a committed state.
}
std::vector<std::uint8_t> readState(const Configuration& c, int slot) {
    const auto input = readFile(statePath(c, slot), maxState + 1024 * 1024);
    if (input.size() <= 256 || std::memcmp(input.data(), "CRS\x01", 4) || get(input, 4) != c.title || get(input, 40) != std::uint64_t(c.core))
        throw std::runtime_error("This save belongs to a different game or emulator.");
    std::array<char, 64> revision{}; std::memcpy(revision.data(), c.revision.data(), std::min<std::size_t>(64, c.revision.size()));
    if (std::memcmp(input.data() + 64, revision.data(), 64))
        throw std::runtime_error("This state was created by a different core version. Use the game's battery save instead.");
    const auto expected = get(input, 16);
    if (!expected || expected > maxState) throw std::runtime_error("Invalid save-state payload size.");
    std::vector<std::uint8_t> bytes(expected); uLongf size = bytes.size();
    if (uncompress(bytes.data(), &size, input.data() + 256, input.size() - 256) != Z_OK || size != expected ||
        crc32(0, bytes.data(), bytes.size()) != get(input, 24)) throw std::runtime_error("The save-state checksum is invalid.");
    return bytes;
}
}
Runtime::Runtime(Configuration value) : config(std::move(value)) {}
Runtime::~Runtime() { stop(); }
void Runtime::start() {
    if (config.core < 1 || config.core > 3 || !config.title || config.revision.empty()) throw std::runtime_error("Invalid core configuration.");
    active = this;
    systemDirectory = (fs::path(config.directory) / "Systems" / std::to_string(config.core)).string();
    saveDirectory = (fs::path(config.directory) / "BatterySaves" / stem(config.title)).string();
    fs::create_directories(systemDirectory); fs::create_directories(saveDirectory);
    fs::create_directories(fs::path(config.directory) / "save_states");
    library = dlopen(config.library.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!library) throw std::runtime_error("The selected emulator framework could not be loaded.");
#define CLAW_SYMBOL(member, symbol) api.member = reinterpret_cast<decltype(api.member)>(dlsym(library, #symbol)); if (!api.member) throw std::runtime_error("Core API is incomplete: " #symbol)
    CLAW_SYMBOL(init, retro_init); CLAW_SYMBOL(deinit, retro_deinit); CLAW_SYMBOL(setEnvironment, retro_set_environment);
    CLAW_SYMBOL(setVideo, retro_set_video_refresh); CLAW_SYMBOL(setAudio, retro_set_audio_sample);
    CLAW_SYMBOL(setAudioBatch, retro_set_audio_sample_batch); CLAW_SYMBOL(setPoll, retro_set_input_poll);
    CLAW_SYMBOL(setInput, retro_set_input_state); CLAW_SYMBOL(info, retro_get_system_info);
    CLAW_SYMBOL(avInfo, retro_get_system_av_info); CLAW_SYMBOL(setController, retro_set_controller_port_device);
    CLAW_SYMBOL(load, retro_load_game); CLAW_SYMBOL(unload, retro_unload_game); CLAW_SYMBOL(run, retro_run);
    CLAW_SYMBOL(stateSize, retro_serialize_size); CLAW_SYMBOL(serialize, retro_serialize);
    CLAW_SYMBOL(restore, retro_unserialize); CLAW_SYMBOL(memory, retro_get_memory_data); CLAW_SYMBOL(memorySize, retro_get_memory_size);
#undef CLAW_SYMBOL
    options = {{"melonds_console_mode", "ds"}, {"melonds_sysfile_mode", "builtin"}, {"melonds_boot_mode", "direct"},
        {"melonds_render_mode", "software"}, {"melonds_screen_layout1", "top-bottom"}, {"melonds_screen_gap", "0"},
        {"melonds_number_of_screen_layouts", "1"}, {"melonds_touch_mode", "touch"}, {"melonds_show_cursor", "disabled"},
        {"melonds_jit_enable", "disabled"}, {"melonds_network_mode", "disabled"},
        {"fceumm_overscan_h_left", "0"}, {"fceumm_overscan_h_right", "0"},
        {"fceumm_overscan_v_top", "0"}, {"fceumm_overscan_v_bottom", "0"}};
    api.setEnvironment(environmentCallback); api.setVideo(videoCallback); api.setAudio(sampleCallback);
    api.setAudioBatch(audioCallback); api.setPoll(+[] {}); api.setInput(inputCallback);
    api.init(); initialized = true;
    retro_system_info info{}; api.info(&info);
    romPath = config.rom;
    retro_game_info game{romPath.c_str(), nullptr, 0, nullptr};
    if (!info.need_fullpath) { romBytes = readFile(romPath, 512 * 1024 * 1024); game.data = romBytes.data(); game.size = romBytes.size(); }
    if (!api.load(&game)) throw std::runtime_error("The core could not open this game. Verify the extracted file and system type. " + error());
    loaded = true; api.setController(0, RETRO_DEVICE_JOYPAD);
    retro_system_av_info av{}; api.avInfo(&av);
    if (!updateAVTiming(av))
        throw std::runtime_error("Unsupported core clock or audio rate.");
    for (const auto& part : batteryParts) {
        const auto battery = fs::path(saveDirectory) / part.name;
        const auto size = api.memorySize(part.type);
        auto* memory = api.memory(part.type);
        if (size && memory && fs::exists(battery)) {
            const auto bytes = readFile(battery.string(), part.maximum);
            // mGBA initially exposes a 128 KiB autodetection buffer for GBA.
            // After the game accesses its cartridge, SRAM/EEPROM may shrink
            // that interface. Restore standard shorter saves into the erased
            // prefix without truncating or rejecting a valid previous session.
            const bool detectedGBA = config.core == 1 && fs::path(romPath).extension() == ".gba" &&
                part.type == RETRO_MEMORY_SAVE_RAM && size == 131072 &&
                (bytes.size() == 512 || bytes.size() == 8192 || bytes.size() == 32768 || bytes.size() == 65536);
            if (bytes.size() != size && !detectedGBA)
                throw std::runtime_error("The battery save has an unexpected size; it has been preserved.");
            std::memcpy(memory, bytes.data(), bytes.size());
        }
    }
    // Startup cleanup must never save fresh/partially restored cartridge RAM.
    batteryPersistenceAllowed = true;
    stopping.store(false); isPaused.store(true); alive.store(true);
    worker = std::thread([this] { loop(); });
}
void Runtime::requestStop() noexcept {
    stopping.store(true); wake.notify_all(); wakeFrameWaiters();
}
void Runtime::stop() {
    requestStop(); if (worker.joinable()) worker.join();
    if (disk.valid()) { try { disk.get(); } catch (...) {} }
    finishBattery(true);
    active = this;
    if (loaded) {
        try { persistBattery(); finishBattery(true); } catch (const std::exception& e) { setError(e.what()); }
        api.unload(); loaded = false;
        batteryPersistenceAllowed = false;
    }
    if (initialized) { api.deinit(); initialized = false; }
    if (library) { dlclose(library); library = nullptr; }
    active = nullptr; alive.store(false);
}
void Runtime::pause(bool value) noexcept { isPaused.store(value); ++audioEpoch; wake.notify_all(); }
void Runtime::setSpeed(int value) noexcept { multiplier.store(value == 2 || value == 4 ? value : 1); ++audioEpoch; wake.notify_all(); }
void Runtime::button(unsigned key, bool pressed) noexcept {
    if (key >= 16) return;
    if (pressed) buttons.fetch_or(1u << key); else buttons.fetch_and(~(1u << key));
}
void Runtime::analog(float x, float y) noexcept {
    unsigned value = 0;
    if (std::isfinite(x) && std::isfinite(y)) {
        if (x < -0.3f) value |= 1 << RETRO_DEVICE_ID_JOYPAD_LEFT;
        if (x > 0.3f) value |= 1 << RETRO_DEVICE_ID_JOYPAD_RIGHT;
        if (y < -0.3f) value |= 1 << RETRO_DEVICE_ID_JOYPAD_DOWN;
        if (y > 0.3f) value |= 1 << RETRO_DEVICE_ID_JOYPAD_UP;
    }
    analogButtons.store(value);
}
void Runtime::touch(float x, float y, bool down) noexcept {
    const bool valid = down && std::isfinite(x) && std::isfinite(y) && x >= 0 && y >= 0 && x < 256 && y < 192;
    touchValue.store(valid ? 0x10000u | unsigned(x) | unsigned(y) << 8 : 0);
}
bool Runtime::state(int slot, bool restore) {
    if (!alive.load() || stopping.load() || slot < 1 || slot > 11) return false;
    int previous = stateResult.load();
    do { if (previous == 1) return false; } while (!stateResult.compare_exchange_weak(previous, 1));
    request.store(restore ? -slot : slot); wake.notify_all(); return true;
}
void Runtime::stateBoundary(int command) {
    if (command) {
        activeCommand = command; pendingBytes = std::make_shared<std::vector<std::uint8_t>>();
        if (command < 0) {
            disk = std::async(std::launch::async, [this, bytes = pendingBytes, command] {
                diskThread(); *bytes = readState(config, -command);
            });
        } else {
            const auto size = api.stateSize();
            if (!size || size > maxState) throw std::runtime_error("This core cannot create a bounded save state.");
            pendingBytes->resize(size);
            if (!api.serialize(pendingBytes->data(), size)) throw std::runtime_error("The core could not capture a save state.");
            disk = std::async(std::launch::async, [this, bytes = pendingBytes, command, picture = frame()] {
                diskThread(); writeState(config, command, *bytes, picture);
            });
        }
    }
    if (!activeCommand || !disk.valid() || disk.wait_for(std::chrono::seconds(0)) != std::future_status::ready) return;
    disk.get();
    if (activeCommand < 0) {
        if (!api.restore(pendingBytes->data(), pendingBytes->size())) {
            batteryPersistenceAllowed = false;
            requestStop(); throw std::runtime_error("The core rejected this state. Restart the game to continue safely.");
        }
        // Some cores restore their hardware sample clock without emitting an
        // AV-change callback. Query it at the restore boundary as well.
        retro_system_av_info restoredAV{}; api.avInfo(&restoredAV);
        if (!updateAVTiming(restoredAV)) {
            batteryPersistenceAllowed = false;
            requestStop(); throw std::runtime_error("The restored state contains an unsupported audio clock.");
        }
        buttons.store(0); analogButtons.store(0); touchValue.store(0); ++audioEpoch;
    }
    stateResult.store(activeCommand < 0 ? 3 : 2); activeCommand = 0; pendingBytes.reset();
}
bool Runtime::finishBattery(bool wait) {
    if (!batteryDisk.valid()) return true;
    if (!wait && batteryDisk.wait_for(std::chrono::seconds(0)) != std::future_status::ready) return false;
    try { batteryDisk.get(); batteryChecksums = pendingBatteryChecksums; }
    catch (const std::exception& error) { setError(std::string("Battery save: ") + error.what()); }
    return true;
}
void Runtime::persistBattery() {
    if (!batteryPersistenceAllowed) return;
    if (!finishBattery(false)) return;
    std::vector<std::pair<std::string, std::vector<std::uint8_t>>> writes;
    pendingBatteryChecksums = batteryChecksums;
    for (std::size_t i = 0; i < std::size(batteryParts); ++i) {
        const auto& part = batteryParts[i];
        const auto size = api.memorySize(part.type);
        const auto* memory = static_cast<const std::uint8_t*>(api.memory(part.type));
        if (!memory || !size || size > part.maximum) continue;
        const auto checksum = crc32(0, memory, size);
        if (batteryChecksums[i] && checksum == *batteryChecksums[i]) continue;
        writes.emplace_back((fs::path(saveDirectory) / part.name).string(), std::vector<std::uint8_t>(memory, memory + size));
        pendingBatteryChecksums[i] = checksum;
    }
    if (writes.empty()) return;
    // Mark checksums committed only after every atomic disk write succeeds.
    // Storage failures preserve the previous save and retry on the next cycle.
    batteryDisk = std::async(std::launch::async, [writes = std::move(writes)] {
        diskThread();
        for (const auto& [path, bytes] : writes) atomicWrite(path, bytes);
    });
}
void Runtime::loop() noexcept {
    active = this;
#if defined(__APPLE__)
    pthread_setname_np("ClawRetroCore"); pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
#endif
    auto next = Clock::now(), measuredAt = next, batteryAt = next; unsigned count = 0;
    try {
        while (!stopping.load()) {
            try { stateBoundary(request.exchange(0)); }
            catch (const std::exception& e) { setError(e.what()); activeCommand = 0; pendingBytes.reset(); stateResult.store(-1); }
            if (stopping.load()) break;
            if (isPaused.load()) {
                std::unique_lock lock(waitMutex); wake.wait_for(lock, std::chrono::milliseconds(10));
                next = measuredAt = Clock::now(); count = 0; continue;
            }
            const auto rate = nativeFPS();
            if (frameTime.callback) frameTime.callback(static_cast<retro_usec_t>(1000000 / rate));
            const auto workStart = Clock::now();
            api.run(); ++count;
            const auto now = Clock::now();
            coreWorkMS.store(std::chrono::duration<double, std::milli>(now - workStart).count(), std::memory_order_relaxed);
            if (now - measuredAt >= std::chrono::seconds(1)) { measuredFPS.store(count / std::chrono::duration<double>(now - measuredAt).count()); count = 0; measuredAt = now; }
            if (now - batteryAt >= std::chrono::seconds(30)) { persistBattery(); batteryAt = now; }
            next += std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(1 / nativeFPS() / multiplier.load()));
            if (now - next > std::chrono::milliseconds(100)) next = now;
            std::unique_lock lock(waitMutex);
            wake.wait_until(lock, next, [this] { return stopping.load() || isPaused.load() || request.load(); });
        }
    } catch (const std::exception& e) { setError(e.what()); }
    catch (...) { setError("The emulator stopped unexpectedly."); }
    alive.store(false); active = nullptr;
    wakeFrameWaiters();
}
void Runtime::setError(const std::string& value) { std::lock_guard lock(errorMutex); lastError = value; }
std::string Runtime::error() const { std::lock_guard lock(errorMutex); return lastError; }
std::shared_ptr<const Frame> Runtime::frame() const { std::lock_guard lock(frameMutex); return latest; }
std::shared_ptr<const Frame> Runtime::waitForFrame(std::uint64_t after, const std::atomic_bool& cancelled) const {
    std::unique_lock lock(frameMutex);
    frameReady.wait(lock, [&] {
        return stopping.load() || cancelled.load() || !alive.load() || (latest && latest->sequence != after);
    });
    if (stopping.load() || cancelled.load() || !alive.load()) return {};
    return latest;
}
void Runtime::wakeFrameWaiters() noexcept {
    // Pair with the waiter's mutex even when only its cancellation flag changed,
    // so shutdown cannot lose a notification between checking and sleeping.
    std::lock_guard lock(frameMutex);
    frameReady.notify_all();
}
void Runtime::video(const void* data, unsigned w, unsigned h, std::size_t pitch) {
    if (!data || !w || !h || w > 2048 || h > 2048) return;
    const auto bpp = pixelFormat == RETRO_PIXEL_FORMAT_XRGB8888 ? 4u : 2u;
    if (pitch < w * bpp) return;
    auto value = std::make_shared<Frame>(); value->width = w; value->height = h; value->bgra.resize(std::size_t(w) * h);
    for (unsigned y = 0; y < h; ++y) for (unsigned x = 0; x < w; ++x) {
        const auto* row = static_cast<const std::uint8_t*>(data) + y * pitch; std::uint32_t color = 0;
        if (bpp == 4) { std::memcpy(&color, row + x * 4, 4); }
        else {
            std::uint16_t p; std::memcpy(&p, row + x * 2, 2);
            const unsigned red = p >> (pixelFormat == RETRO_PIXEL_FORMAT_RGB565 ? 11 : 10) & 31;
            const unsigned green = p >> 5 & (pixelFormat == RETRO_PIXEL_FORMAT_RGB565 ? 63 : 31), blue = p & 31;
            color = ((red * 255 / 31) << 16) | ((green * 255 / (pixelFormat == RETRO_PIXEL_FORMAT_RGB565 ? 63 : 31)) << 8) | (blue * 255 / 31);
        }
        value->bgra[y * w + x] = color | 0xFF000000u;
    }
    {
        std::lock_guard lock(frameMutex);
        value->sequence = latest ? latest->sequence + 1 : 1;
        value->publishedAt = Clock::now(); latest = std::move(value);
    }
    frameReady.notify_one();
}
bool Runtime::environmentCallback(unsigned command, void* data) { return active && active->environment(command, data); }
void Runtime::videoCallback(const void* data, unsigned w, unsigned h, std::size_t pitch) {
    if (!active) return;
    try { active->video(data, w, h, pitch); }
    catch (...) { active->setError("A video frame could not be allocated."); active->requestStop(); }
}
void Runtime::sampleCallback(std::int16_t l, std::int16_t r) { const std::int16_t samples[] = {l, r}; audioCallback(samples, 1); }
std::size_t Runtime::audioCallback(const std::int16_t* data, std::size_t frames) {
    if (active && data && frames <= 16384 && active->multiplier.load() != 4) {
        const auto pushed = active->audio.push({data, frames * 2});
        if (pushed < frames) active->droppedAudioFrames.fetch_add(frames - pushed, std::memory_order_relaxed);
    }
    return frames;
}
std::int16_t Runtime::inputCallback(unsigned port, unsigned device, unsigned, unsigned id) {
    if (!active || port != 0) return 0;
    if (device == RETRO_DEVICE_JOYPAD) {
        const auto value = active->buttons.load() | active->analogButtons.load();
        return id == RETRO_DEVICE_ID_JOYPAD_MASK ? static_cast<std::int16_t>(value) : id < 16 && (value & (1u << id)) ? 1 : 0;
    }
    if (device == RETRO_DEVICE_POINTER) {
        const auto p = active->touchValue.load();
        if (id == RETRO_DEVICE_ID_POINTER_PRESSED) return (p & 0x10000) != 0;
        if (id == RETRO_DEVICE_ID_POINTER_COUNT) return (p & 0x10000) ? 1 : 0;
        if (id == RETRO_DEVICE_ID_POINTER_X) return static_cast<std::int16_t>(int(p & 255) * 65534 / 255 - 32767);
        // DS pointer coordinates cover the whole stacked 256x384 framebuffer.
        if (id == RETRO_DEVICE_ID_POINTER_Y) return static_cast<std::int16_t>((192 + int(p >> 8 & 255)) * 65534 / 383 - 32767);
    }
    return 0;
}
void Runtime::logCallback(retro_log_level level, const char* format, ...) {
    if (!active || level < RETRO_LOG_ERROR) return;
    char text[1024]; va_list args; va_start(args, format); std::vsnprintf(text, sizeof(text), format, args); va_end(args); active->setError(text);
}
bool Runtime::updateAVTiming(const retro_system_av_info& av) {
    const auto fps = av.timing.fps, rate = av.timing.sample_rate;
    // GBA SOUNDBIAS can switch PWM rates up to 262144 Hz during a game.
    // Reject malformed descriptors without changing the current valid clock.
    if (!std::isfinite(fps) || fps < 10 || fps > 240 ||
        !std::isfinite(rate) || rate < 8000 || rate > 384000) return false;
    const auto oldRate = audioRate.exchange(rate);
    const auto oldFPS = nominalFPS.exchange(fps);
    if (oldRate != rate || oldFPS != fps) {
        ++audioClockChanges;
        // The audio producer rebuilds its fixed-ratio converter; the playback
        // consumer flushes old-format samples and fades in the new stream.
        ++audioEpoch;
    }
    return true;
}
bool Runtime::environment(unsigned command, void* data) {
    switch (command) {
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY: *static_cast<const char**>(data) = systemDirectory.c_str(); return true;
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY: *static_cast<const char**>(data) = saveDirectory.c_str(); return true;
    case RETRO_ENVIRONMENT_GET_CAN_DUPE: *static_cast<bool*>(data) = true; return true;
    case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS: return true;
    case RETRO_ENVIRONMENT_GET_INPUT_DEVICE_CAPABILITIES:
        *static_cast<std::uint64_t*>(data) = (1ull << RETRO_DEVICE_JOYPAD) | (1ull << RETRO_DEVICE_POINTER); return true;
    case RETRO_ENVIRONMENT_GET_INPUT_MAX_USERS: *static_cast<unsigned*>(data) = 1; return true;
    case RETRO_ENVIRONMENT_GET_USERNAME: *static_cast<const char**>(data) = "Claw"; return true;
    case RETRO_ENVIRONMENT_GET_LANGUAGE: *static_cast<unsigned*>(data) = RETRO_LANGUAGE_ENGLISH; return true;
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: static_cast<retro_log_callback*>(data)->log = logCallback; return true;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
        const auto format = *static_cast<retro_pixel_format*>(data);
        if (format != RETRO_PIXEL_FORMAT_RGB565 && format != RETRO_PIXEL_FORMAT_XRGB8888 && format != RETRO_PIXEL_FORMAT_0RGB1555) return false;
        pixelFormat = format; return true;
    }
    case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION: *static_cast<unsigned*>(data) = 2; return true;
    case RETRO_ENVIRONMENT_GET_JIT_CAPABLE: *static_cast<bool*>(data) = false; return true;
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL: {
        auto* entries = command == RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2 ? static_cast<retro_core_options_v2*>(data)
            : static_cast<retro_core_options_v2_intl*>(data)->us;
        if (!entries || !entries->definitions) return false;
        for (auto* option = entries->definitions; option->key; ++option)
            if (option->default_value || option->values[0].value) options.try_emplace(option->key, option->default_value ? option->default_value : option->values[0].value);
        return true;
    }
    case RETRO_ENVIRONMENT_SET_VARIABLES:
        for (auto* entry = static_cast<retro_variable*>(data); entry && entry->key; ++entry) {
            std::string value = entry->value ? entry->value : ""; const auto at = value.find(';');
            if (at == std::string::npos) continue;
            value = value.substr(at + 1); value.erase(0, value.find_first_not_of(' '));
            options.try_emplace(entry->key, value.substr(0, value.find('|')));
        }
        return true;
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
        if (!data) return true; // libretro permits a capability probe.
        auto* value = static_cast<retro_variable*>(data);
        const auto found = value->key ? options.find(value->key) : options.end();
        value->value = found == options.end() ? nullptr : found->second.c_str();
        return true; // A missing option is supported, with a null value.
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE: *static_cast<bool*>(data) = false; return true;
    case RETRO_ENVIRONMENT_SET_FRAME_TIME_CALLBACK: frameTime = *static_cast<retro_frame_time_callback*>(data); return true;
    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
        return data && updateAVTiming(*static_cast<retro_system_av_info*>(data));
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS: case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
    case RETRO_ENVIRONMENT_SET_MEMORY_MAPS: case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
    case RETRO_ENVIRONMENT_SET_GEOMETRY: case RETRO_ENVIRONMENT_SET_MESSAGE:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY: case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK:
    case RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS: case RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL: return true;
    case RETRO_ENVIRONMENT_GET_FASTFORWARDING: *static_cast<bool*>(data) = multiplier.load() != 1; return true;
    case RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE: *static_cast<int*>(data) = 3; return true;
    case RETRO_ENVIRONMENT_SHUTDOWN: requestStop(); return true;
    default: return false; // No JIT, downloaded cores, networking or hardware-GL context.
    }
}
}
