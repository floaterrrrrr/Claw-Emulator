// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

// Upstream builds keep their defaults; the iPhone project supplies explicit values.
#ifndef STRICT_INTERPRETER
#define STRICT_INTERPRETER 0
#endif
#ifndef DISABLE_JIT
#define DISABLE_JIT STRICT_INTERPRETER
#endif
#ifndef ENABLE_REMOTE_INPUT
#define ENABLE_REMOTE_INPUT 1
#endif
#ifndef CLAW_DISABLE_LOGGING
#define CLAW_DISABLE_LOGGING 0
#endif

#if STRICT_INTERPRETER && !DISABLE_JIT
#error "STRICT_INTERPRETER requires DISABLE_JIT=1"
#endif
#if STRICT_INTERPRETER && !HAVE_FASTINTERP
#error "STRICT_INTERPRETER requires HAVE_FASTINTERP=1"
#endif
#if STRICT_INTERPRETER && (ENABLE_WEB_SERVICE || ENABLE_QT || CITRA_USE_DISCORD_PRESENCE)
#error "The strict iPhone profile must disable web services, Qt, and Discord presence"
#endif
#if STRICT_INTERPRETER && (defined(ENABLE_GDBSTUB) || defined(ENABLE_SCRIPTING) || \
    defined(HAVE_OPENAL) || defined(HAVE_SDL2) || defined(HAVE_SDL3) || \
    defined(ENABLE_SDL2) || defined(ENABLE_SDL3) || defined(ENABLE_OPENGL) || \
    defined(ENABLE_GCADAPTER))
#error "A legacy desktop feature was enabled in the strict iPhone profile"
#endif

namespace Core::BuildConfig {
constexpr bool AllowJit(bool configured) {
    return !DISABLE_JIT && configured;
}
constexpr bool UseFastInterpreter(bool configured) {
    return STRICT_INTERPRETER || configured;
}
} // namespace Core::BuildConfig
