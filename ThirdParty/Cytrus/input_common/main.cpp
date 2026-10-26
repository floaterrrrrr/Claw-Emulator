// Copyright 2017-2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#if defined(__APPLE__) && TARGET_OS_IPHONE
#define INPUT_COMMON_DESKTOP 0
#else
#define INPUT_COMMON_DESKTOP 1
#endif

#include <cmath>
#include <memory>
#include <string>
#include "common/core_build_config.h"
#include "common/param_package.h"
#if INPUT_COMMON_DESKTOP && (defined(HAVE_SDL3) || defined(ENABLE_GCADAPTER))
#include "common/settings.h"
#endif
#include "input_common/analog_from_button.h"
#if INPUT_COMMON_DESKTOP && defined(ENABLE_GCADAPTER)
#include "input_common/gcadapter/gc_adapter.h"
#include "input_common/gcadapter/gc_poller.h"
#endif
#include "input_common/keyboard.h"
#include "input_common/main.h"
#include "input_common/motion_emu.h"
#if INPUT_COMMON_DESKTOP
#include "input_common/sdl/sdl3.h"
#ifdef HAVE_SDL3
#include "input_common/sdl/sdl3_impl.h"
#endif
#endif
#include "input_common/touch_from_button.h"
#if INPUT_COMMON_DESKTOP && ENABLE_REMOTE_INPUT
#include "input_common/udp/udp.h"
#endif

namespace InputCommon {

#if INPUT_COMMON_DESKTOP && defined(ENABLE_GCADAPTER)
std::shared_ptr<GCButtonFactory> gcbuttons;
std::shared_ptr<GCAnalogFactory> gcanalog;
std::shared_ptr<GCAdapter::Adapter> gcadapter;
#endif
static std::shared_ptr<Keyboard> keyboard;
static std::shared_ptr<MotionEmu> motion_emu;
#if INPUT_COMMON_DESKTOP && ENABLE_REMOTE_INPUT
static std::unique_ptr<CemuhookUDP::State> udp;
#endif
#if INPUT_COMMON_DESKTOP
static std::unique_ptr<SDL::State> sdl;
#endif

void Init() {
#if INPUT_COMMON_DESKTOP && defined(ENABLE_GCADAPTER)
    gcadapter = std::make_shared<GCAdapter::Adapter>();
    gcbuttons = std::make_shared<GCButtonFactory>(gcadapter);
    Input::RegisterFactory<Input::ButtonDevice>("gcpad", gcbuttons);
    gcanalog = std::make_shared<GCAnalogFactory>(gcadapter);
    Input::RegisterFactory<Input::AnalogDevice>("gcpad", gcanalog);
#endif
    keyboard = std::make_shared<Keyboard>();
    Input::RegisterFactory<Input::ButtonDevice>("keyboard", keyboard);
    Input::RegisterFactory<Input::AnalogDevice>("analog_from_button",
                                                std::make_shared<AnalogFromButton>());
    motion_emu = std::make_shared<MotionEmu>();
    Input::RegisterFactory<Input::MotionDevice>("motion_emu", motion_emu);
    Input::RegisterFactory<Input::TouchDevice>("touch_from_button",
                                               std::make_shared<TouchFromButtonFactory>());

    // The frontend supplies virtual buttons/axes through InputManager and touch
    // through EmuWindow. No SDL or USB device discovery is needed on iOS.
#if INPUT_COMMON_DESKTOP
    sdl = SDL::Init();
#endif

#if INPUT_COMMON_DESKTOP && ENABLE_REMOTE_INPUT
    udp = CemuhookUDP::Init();
#endif
}

void Shutdown() {
#if INPUT_COMMON_DESKTOP && defined(ENABLE_GCADAPTER)
    Input::UnregisterFactory<Input::ButtonDevice>("gcpad");
    Input::UnregisterFactory<Input::AnalogDevice>("gcpad");
    gcbuttons.reset();
    gcanalog.reset();
#endif
    Input::UnregisterFactory<Input::ButtonDevice>("keyboard");
    keyboard.reset();
    Input::UnregisterFactory<Input::AnalogDevice>("analog_from_button");
    Input::UnregisterFactory<Input::MotionDevice>("motion_emu");
    motion_emu.reset();
    Input::UnregisterFactory<Input::TouchDevice>("emu_window");
    Input::UnregisterFactory<Input::TouchDevice>("touch_from_button");
#if INPUT_COMMON_DESKTOP
    sdl.reset();
#endif
#if INPUT_COMMON_DESKTOP && ENABLE_REMOTE_INPUT
    udp.reset();
#endif
}

std::string ButtonToText(const Common::ParamPackage& param) {
    if (!param.Has("engine")) {
        return "[not set]";
    }
    const auto engine_str = param.Get("engine", "");
    // if this is a keyboard string, return the param package back as a string
    // to be handled at the frontend
    if (engine_str == "keyboard") {
        return param.Serialize();
    }

    if (engine_str == "sdl") {
        if (param.Has("hat")) {
            return "Hat " + param.Get("hat", "") + " " + param.Get("direction", "");
        } else if (param.Has("button")) {
            if (param.Get("name", "") != "")
                return param.Get("name", "");
            else
                return "Button " + param.Get("button", "");

        } else if (param.Has("axis")) {
            auto name = param.Get("name", "");
            if (name == "LT" || name == "RT")
                return name;
            else if (name != "")
                return name + param.Get("direction", "");
            else
                return "Axis " + param.Get("axis", "") + param.Get("direction", "");
        }

        return {};
    }

    if (engine_str == "gcpad") {
        if (param.Has("axis")) {
            const auto axis_str = param.Get("axis", "");
            const auto direction_str = param.Get("direction", "");

            return "GC Axis " + axis_str + direction_str;
        }
        if (param.Has("button")) {
            const auto button = int(std::log2(param.Get("button", 0)));
            return "GC Button " + std::to_string(button);
        }
        return "keyboard code " + std::to_string(param.Get("code", 0));
    }

    return "[unknown]";
}

std::string AnalogToText(const Common::ParamPackage& param, const std::string& dir) {
    if (!param.Has("engine")) {
        return "[not set]";
    }

    const auto engine_str = param.Get("engine", "");
    if (engine_str == "analog_from_button") {
        return ButtonToText(Common::ParamPackage{param.Get(dir, "")});
    }

    const auto axis_x_str = param.Get("axis_x", "");
    const auto axis_y_str = param.Get("axis_y", "");
    const auto name_x_str = param.Get("name_x", "");
    const auto name_y_str = param.Get("name_y", "");
    static const auto plus_str = "+";
    static const auto minus_str = "-";
    if (engine_str == "sdl" || engine_str == "gcpad") {
        if (dir == "modifier") {
            return "[unused]";
        }
        if (dir == "left") {
            if (name_x_str == "")
                return "Axis " + axis_x_str + minus_str;
            else
                return name_x_str + minus_str;
        }
        if (dir == "right") {
            if (name_x_str == "")
                return "Axis " + axis_x_str + plus_str;
            else
                return name_x_str + plus_str;
        }
        if (dir == "up") {
            if (name_y_str == "")
                return "Axis " + axis_y_str + minus_str;
            else
                return name_y_str + minus_str;
        }
        if (dir == "down") {
            if (name_y_str == "")
                return "Axis " + axis_y_str + plus_str;
            else
                return name_y_str + plus_str;
        }
        return {};
    }
    return "[unknown]";
}

Keyboard* GetKeyboard() {
    return keyboard.get();
}

MotionEmu* GetMotionEmu() {
    return motion_emu.get();
}

std::string GenerateKeyboardParam(int key_code) {
    Common::ParamPackage param{
        {"engine", "keyboard"},
        {"code", std::to_string(key_code)},
    };
    return param.Serialize();
}

std::string GenerateAnalogParamFromKeys(int key_up, int key_down, int key_left, int key_right,
                                        int key_modifier, float modifier_scale) {
    Common::ParamPackage circle_pad_param{
        {"engine", "analog_from_button"},
        {"up", GenerateKeyboardParam(key_up)},
        {"down", GenerateKeyboardParam(key_down)},
        {"left", GenerateKeyboardParam(key_left)},
        {"right", GenerateKeyboardParam(key_right)},
        {"modifier", GenerateKeyboardParam(key_modifier)},
        {"modifier_scale", std::to_string(modifier_scale)},
    };
    return circle_pad_param.Serialize();
}

Common::ParamPackage GetControllerButtonBinds([[maybe_unused]] const Common::ParamPackage& params,
                                            [[maybe_unused]] int button) {
#if INPUT_COMMON_DESKTOP && (defined(HAVE_SDL3) || defined(ENABLE_GCADAPTER))
    const auto native_button{static_cast<Settings::NativeButton::Values>(button)};
    const auto engine{params.Get("engine", "")};
#ifdef HAVE_SDL3
    if (engine == "sdl") {
        return dynamic_cast<SDL::SDLState*>(sdl.get())->GetSDLControllerButtonBind(params,
                                                                                   native_button);
    }
#endif
#ifdef ENABLE_GCADAPTER
    if (engine == "gcpad") {
        return gcbuttons->GetGcTo3DSMappedButton(params.Get("port", 0), native_button);
    }
#endif
#endif
    return {};
}

Common::ParamPackage GetControllerAnalogBinds([[maybe_unused]] const Common::ParamPackage& params,
                                             [[maybe_unused]] int analog) {
#if INPUT_COMMON_DESKTOP && (defined(HAVE_SDL3) || defined(ENABLE_GCADAPTER))
    const auto native_analog{static_cast<Settings::NativeAnalog::Values>(analog)};
    const auto engine{params.Get("engine", "")};
#ifdef HAVE_SDL3
    if (engine == "sdl") {
        return dynamic_cast<SDL::SDLState*>(sdl.get())->GetSDLControllerAnalogBindByGUID(
            params.Get("guid", "0"), params.Get("port", 0), native_analog);
    }
#endif
#ifdef ENABLE_GCADAPTER
    if (engine == "gcpad") {
        return gcanalog->GetGcTo3DSMappedAnalog(params.Get("port", 0), native_analog);
    }
#endif
#endif
    return {};
}

void ReloadInputDevices() {
#if INPUT_COMMON_DESKTOP && ENABLE_REMOTE_INPUT
    if (!udp) {
        return;
    }
    udp->ReloadUDPClient();
#endif
}

namespace Polling {

std::vector<std::unique_ptr<DevicePoller>> GetPollers([[maybe_unused]] DeviceType type) {
    std::vector<std::unique_ptr<DevicePoller>> pollers;

#if INPUT_COMMON_DESKTOP && (defined(HAVE_SDL2) || defined(HAVE_SDL3))
    pollers = sdl->GetPollers(type);
#endif
#if INPUT_COMMON_DESKTOP && defined(ENABLE_GCADAPTER)
    switch (type) {
    case DeviceType::Analog:
        pollers.push_back(std::make_unique<GCAnalogFactory>(*gcanalog));
        break;
    case DeviceType::Button:
        pollers.push_back(std::make_unique<GCButtonFactory>(*gcbuttons));
        break;
    default:
        break;
    }
#endif

    return pollers;
}

} // namespace Polling
} // namespace InputCommon
