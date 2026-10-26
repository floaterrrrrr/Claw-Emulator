// SPDX-License-Identifier: GPL-3.0-or-later
// Minimal dynamically loaded core for exercising real Runtime startup cleanup.
#include "Retro/libretro.h"
#include <array>
#include <cstdlib>
#include <cstring>
namespace {
retro_environment_t environment;
retro_video_refresh_t video;
retro_audio_sample_batch_t audio;
retro_input_state_t input;
double rate = 48000;
std::array<unsigned char, 131072> ram;
std::array<unsigned char, 16> rtc;
}
extern "C" {
void retro_set_environment(retro_environment_t callback) { environment = callback; }
void retro_set_video_refresh(retro_video_refresh_t callback) { video = callback; }
void retro_set_audio_sample(retro_audio_sample_t) {}
void retro_set_audio_sample_batch(retro_audio_sample_batch_t callback) { audio = callback; }
void retro_set_input_poll(retro_input_poll_t) {}
void retro_set_input_state(retro_input_state_t callback) { input = callback; }
void retro_init() {
    // Probe and missing-option responses must both report API support.
    if (!environment(RETRO_ENVIRONMENT_GET_VARIABLE, nullptr)) std::abort();
    retro_variable missing{"claw_absent_option", "sentinel"};
    if (!environment(RETRO_ENVIRONMENT_GET_VARIABLE, &missing) || missing.value) std::abort();
    retro_variable known{"melonds_jit_enable", nullptr};
    if (!environment(RETRO_ENVIRONMENT_GET_VARIABLE, &known) ||
        !known.value || std::strcmp(known.value, "disabled")) std::abort();
    ram.fill(0xFF); rtc.fill(0); rate = 48000;
}
void retro_deinit() {}
void retro_get_system_info(retro_system_info* info) { *info = {}; info->need_fullpath = true; }
void retro_get_system_av_info(retro_system_av_info* info) {
    *info = {}; info->timing.fps = std::getenv("CLAW_TEST_INVALID_AV") ? 0 : 60;
    info->timing.sample_rate = rate;
}
void retro_set_controller_port_device(unsigned, unsigned) {}
bool retro_load_game(const retro_game_info*) { return true; }
void retro_unload_game() {}
void retro_run() {
    const auto wanted = input && input(0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_Y) ? 262144.0
        : input && input(0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_B) ? 96000.0 : 48000.0;
    if (wanted != rate) {
        rate = wanted;
        retro_system_av_info info{}; retro_get_system_av_info(&info);
        environment(RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO, &info);
    }
    if (input && input(0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_X)) {
        retro_system_av_info invalid{};
        if (environment(RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO, &invalid)) std::abort();
    }
    const unsigned short pixels[4] = {0x7FFF, 0, 0, 0x7FFF};
    if (video) video(pixels, 2, 2, 4);
    if (audio) { const std::array<short, 16384> samples{}; audio(samples.data(), static_cast<size_t>(rate / 60)); }
}
size_t retro_serialize_size() { return 1; }
bool retro_serialize(void*, size_t) { return true; }
bool retro_unserialize(const void*, size_t) { ram.fill(0); rtc.fill(0); return false; }
void* retro_get_memory_data(unsigned type) {
    if (type == RETRO_MEMORY_SAVE_RAM) return ram.data();
    if (type == RETRO_MEMORY_RTC) return rtc.data();
    return nullptr;
}
size_t retro_get_memory_size(unsigned type) {
    return type == RETRO_MEMORY_SAVE_RAM ? ram.size() : type == RETRO_MEMORY_RTC ? rtc.size() : 0;
}
}
