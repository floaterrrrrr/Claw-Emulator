// SPDX-License-Identifier: GPL-3.0-or-later
#include "ClawCore.h"
#include "SessionGate.hpp"
#include "SessionControls.hpp"
#include "SessionCleanup.hpp"
#include "SpatialUpscaleConfig.hpp"
#include "MobileTransitionCache.hpp"
#include "PerformanceWindow.hpp"
#include "FrameworkProbe.hpp"
#include "MetalFXSpatial.hpp"
#include "audio_core/coreaudio_sink.h"
#include "configuration.h"
#include "emu_window_vk.h"
#include "input_manager.h"
#include "common/file_util.h"
#include "common/logging/backend.h"
#include "common/dynamic_library/ffmpeg.h"
#include <libavdevice/version.h>
#include <libswscale/version.h>
#include "common/settings.h"
#include "core/core.h"
#include "core/file_sys/cia_container.h"
#include "core/frontend/applets/default_applets.h"
#include "core/hle/service/am/am.h"
#include "core/loader/loader.h"
#include "video_core/gpu.h"
#include "video_core/renderer_base.h"
#include <cmath>
#include <array>
#include <atomic>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <dlfcn.h>
#include <exception>
#include <mutex>
#include <string>
#include <thread>
#include <pthread/qos.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <os/proc.h>
#import <QuartzCore/CAMetalLayer.h>

namespace AppleUtils {
float GetRefreshRate() { return 60.f; }
int IsLowPowerModeEnabled() { return NSProcessInfo.processInfo.lowPowerModeEnabled; }
bool IsRunningFromTerminal() { return false; }
}

namespace {
SessionGate gate;
Claw::SessionControls controls;
std::thread emulationThread;
std::atomic<bool> active{false};
std::atomic<bool> pipelineCacheSaveRequested{false};
UIBackgroundTaskIdentifier pipelineCacheBackgroundTask = UIBackgroundTaskInvalid;

void FinishPipelineCacheBackgroundTask() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (pipelineCacheBackgroundTask == UIBackgroundTaskInvalid) return;
        const auto task = pipelineCacheBackgroundTask;
        pipelineCacheBackgroundTask = UIBackgroundTaskInvalid;
        [UIApplication.sharedApplication endBackgroundTask:task];
    });
}
std::atomic<double> fps{0}, speed{0};
struct PerformanceSample {
    bool valid = false;
    int selected_speed = 1;
    double applied_limit = 100, effective_limit = 100;
    double resolution = 1, cpu_clock = 100;
    int metalfx = 0;
    Core::PerfStats::Results stats{};
    Core::FrameLimiter::PacingStats pacing{};
    bool async_presentation = false;
};
std::mutex performanceMutex;
PerformanceSample performanceSample;
Claw::PerformanceWindow performanceWindow;
std::atomic<int> runtimeStatus{0};
std::atomic<uint64_t> loadedTitle{0};
std::unique_ptr<EmulationWindow_Vulkan> topWindow, bottomWindow;
// Strong ARC references outlive both Vulkan windows and their presentation workers.
CAMetalLayer* ownedTopLayer = nil;
CAMetalLayer* ownedBottomLayer = nil;
std::shared_ptr<Common::DynamicLibrary> driver;
std::string lastError;
std::string workerError;
std::mutex workerErrorMutex;
std::string sessionSysdata, sessionStates;
bool initialized = false;
bool sessionLoaded = false;
bool inputsInitialized = false;
std::mutex inputMutex;
std::string launchStagePath;

// A bounded, local-only breadcrumb survives a process crash without collecting
// ROM names, console keys or guest data. It is visible in Files for support.
void RecordLaunchStage(const char* stage) {
    if (launchStagePath.empty()) return;
    @autoreleasepool {
        NSString* path = [NSString stringWithUTF8String:launchStagePath.c_str()];
        NSDictionary* info = NSBundle.mainBundle.infoDictionary;
        NSString* record = [NSString stringWithFormat:@"Build: %@\nFFmpeg: %@\nStage: %s\nCommit: %@\n",
            info[@"CFBundleVersion"] ?: @"unknown", info[@"ClawFFmpegMode"] ?: @"unspecified", stage,
            info[@"ClawSourceCommit"] ?: @"unknown"];
        [record writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        std::fprintf(stderr, "Claw 3DS stage: %s\n", stage);
        std::fflush(stderr);
    }
}

std::string CanonicalFrameworkPath(const char* raw) {
    if (!raw) return {};
    NSString* path = [NSString stringWithUTF8String:raw];
    const char* canonical = path.stringByResolvingSymlinksInPath.fileSystemRepresentation;
    return canonical ? canonical : "";
}

void ProbeBundledFFmpeg(const std::string& dataRoot) {
    // Framework identity is constant within this app process. Run the eager
    // loader probes once, before the core starts; no work runs per frame.
    static std::string cached;
    @autoreleasepool {
        NSString* reportPath = [NSString stringWithUTF8String:(dataRoot + "last-ffmpeg-load.txt").c_str()];
        auto write = [&](const std::string& report) {
            [[NSString stringWithUTF8String:report.c_str()] writeToFile:reportPath atomically:YES
                                            encoding:NSUTF8StringEncoding error:nil];
        };
        if (!cached.empty()) { write(cached); return; }
        NSDictionary* info = NSBundle.mainBundle.infoDictionary;
        NSString* header = [NSString stringWithFormat:@"Build: %@\nCommit: %@\nFFmpeg: %@\n",
            info[@"CFBundleVersion"] ?: @"unknown", info[@"ClawSourceCommit"] ?: @"unknown",
            info[@"ClawFFmpegMode"] ?: @"unspecified"];
        std::string report = header.UTF8String ? header.UTF8String : "Build information unavailable\n";
        report += "Explicit diagnostic preflight; normal 3DS AAC decoding uses FAAD2.\n";
        const auto root = CanonicalFrameworkPath(NSBundle.mainBundle.privateFrameworksPath.fileSystemRepresentation);
        Claw::FrameworkProbeAPI api{
            [](const char* path) { return dlopen(path, RTLD_NOW | RTLD_LOCAL); },
            [](void* handle, const char* name) { return dlsym(handle, name); },
            [] { const char* error = dlerror(); return std::string{error ? error : ""}; },
            [](void* symbol) {
                Dl_info image{};
                return dladdr(symbol, &image) ? CanonicalFrameworkPath(image.dli_fname) : std::string{};
            },
            [](void* handle) { static_cast<void>(dlclose(handle)); },
        };
        struct Spec { const char* name; unsigned major; };
        const std::array specs{
            Spec{"avutil", LIBAVUTIL_VERSION_MAJOR}, Spec{"avcodec", LIBAVCODEC_VERSION_MAJOR},
            Spec{"avfilter", LIBAVFILTER_VERSION_MAJOR}, Spec{"avformat", LIBAVFORMAT_VERSION_MAJOR},
            Spec{"swresample", LIBSWRESAMPLE_VERSION_MAJOR}, Spec{"avdevice", LIBAVDEVICE_VERSION_MAJOR},
            Spec{"swscale", LIBSWSCALE_VERSION_MAJOR},
        };
        for (const auto& spec : specs) {
            report += std::string{"Probing lib"} + spec.name + "\n";
            write(report); // Identify the library even if its initializer traps.
            const auto result = Claw::ProbeFramework(spec.name, spec.major, root, api);
            const auto description = Claw::DescribeFrameworkProbe(result);
            std::fprintf(stderr, "Claw FFmpeg preflight: %s", description.c_str());
            std::fflush(stderr);
            report += description;
            write(report);
        }
        cached = std::move(report);
    }
}

void applyProfile(int resolution, int clock, [[maybe_unused]] bool asyncShaders) {
    auto& v = Settings::values;
    v.use_cpu_jit.SetValue(false);
    v.use_fastinterp.SetValue(true);
    v.use_shader_jit.SetValue(false);
    v.cpu_clock_percentage.SetValue(std::clamp(clock, 50, 100));
    v.is_new_3ds.SetValue(false);
    v.lle_applets.SetValue(false);
    v.deterministic_async_operations.SetValue(false);
    v.enable_required_online_lle_modules.SetValue(false);
    v.graphics_api.SetValue(Settings::GraphicsAPI::Vulkan);
    v.resolution_factor.SetValue(Claw3DSResolutionScale(resolution));
    // Preserve pixel edges in native-resolution text and framebuffer overlays.
    v.filter_mode.SetValue(false);
    v.render_3d.SetValue(Settings::StereoRenderOption::Off);
    v.factor_3d.SetValue(0);
    v.texture_filter.SetValue(Settings::TextureFilter::NoFilter);
    v.use_hw_shader.SetValue(true);
    v.use_disk_shader_cache.SetValue(true);
    v.use_skip_duplicate_frames.SetValue(true);
    v.async_shader_compilation.SetValue(true);
    v.async_presentation.SetValue(false);
    v.use_vsync.SetValue(false);
    v.shaders_accurate_mul.SetValue(true);
    v.frame_limit.SetValue(100);
    v.layout_option.SetValue(Settings::LayoutOption::SeparateWindows);
    v.aspect_ratio.SetValue(Settings::AspectRatio::Stretch);
    v.swap_screen.SetValue(false);
    v.upright_screen.SetValue(false);
    v.renderer_debug.SetValue(false);
    v.dump_command_buffers.SetValue(false);
    v.plugin_loader_enabled.SetValue(false);
    v.allow_plugin_loader.SetValue(false);
    v.use_artic_base_controller.SetValue(false);
    v.audio_emulation.SetValue(Settings::AudioEmulation::HLE);
    v.output_type.SetValue(AudioCore::SinkType::CoreAudio);
    // This playback-only profile never opens a microphone or camera during launch.
    v.input_type.SetValue(AudioCore::InputType::Null);
    v.camera_name.fill("blank");
    v.camera_config.fill("");
    v.camera_flip.fill(0);
    v.enable_audio_stretching.SetValue(false);
    // DSP ticks remain tied to the guest clock; presentation jitter must not
    // retime the source again before fixed-rate Apple sample conversion.
    v.enable_realtime_audio.SetValue(false);
    v.apply_region_free_patch.SetValue(true);
}

std::string loadError(Core::System::ResultStatus status) {
    using R = Core::System::ResultStatus;
    switch (status) {
    case R::ErrorLoader_ErrorEncrypted:
        return "The selected NCCH partition is marked encrypted, and its plaintext hash checks did not pass. "
               "This core loads decrypted ROMs; keys.txt cannot override this flag. "
               "Check the imported file against your verified decrypted dump.";
    case R::ErrorGetLoader:
        return "The core could not open or recognize the imported game. Reimport the original game or decrypted CIA.";
    case R::ErrorLoader_ErrorInvalidFormat:
        return "The game container or its selected partition is incomplete or invalid. Reimport the original ROM.";
    case R::ErrorSystemFiles:
        return "Required system files are missing. Place your dumped files in EmulationData/sysdata using Files.";
    case R::ErrorN3DSApplication:
        return "This profile emulates an original 3DS. This title requires New 3DS mode.";
    default:
        return "The 3DS core could not load this file (status " + std::to_string(static_cast<int>(status)) +
               "). Reimport the original game or decrypted CIA.";
    }
}
}

int Claw3DSExtractCIA(const char* source, const char* destination) {
    if (!source || !*source || !destination || !*destination) return 1;
    FileUtil::IOFile input(source, "rb");
    if (!input.IsOpen()) return 4;
    const u64 file_size = input.GetSize();
    FileSys::CIAHeader header{};
    if (file_size < sizeof(header) || input.ReadBytes(&header, sizeof(header)) != sizeof(header) ||
        header.header_size != FileSys::CIA_HEADER_SIZE || header.cert_size > 1'048'576 ||
        header.tik_size > 1'048'576 || header.tmd_size > 1'048'576 ||
        header.meta_size > 2'097'152 || header.content_size > file_size) return 1;

    // The core deliberately does not decrypt imported titles. Reuse its own
    // CIA and NCCH checks so an encrypted archive is never imported as a game.
    bool compressed = false;
    const auto status = Service::AM::CheckCIAToInstall(source, compressed, true);
    if (status == Service::AM::InstallStatus::ErrorEncrypted) return 2;
    if (status != Service::AM::InstallStatus::Success) return 1;
    if (compressed || !input.Seek(0, SEEK_SET)) return 1;

    FileSys::CIAContainer cia;
    if (cia.Load(&input) != Loader::ResultStatus::Success) return 1;
    const auto& tmd = cia.GetTitleMetadata();
    const u64 title_id = tmd.GetTitleID();
    const u32 category = static_cast<u32>(title_id >> 32);
    if (category != 0x00040000 && category != 0x00040002) return 3;
    if (!tmd.GetContentCount() || !cia.GetHeader()->IsContentPresent(FileSys::TMDContentIndex::Main))
        return 1;
    const u64 offset = cia.GetContentOffset(FileSys::TMDContentIndex::Main);
    const u64 size = cia.GetContentSize(FileSys::TMDContentIndex::Main);
    if (size < 0x200 || offset > file_size || size > file_size - offset ||
        !input.Seek(static_cast<s64>(offset), SEEK_SET)) return 1;

    FileUtil::IOFile output(destination, "wb");
    if (!output.IsOpen()) return 4;
    std::array<u8, 64 * 1024> buffer{};
    for (u64 remaining = size; remaining;) {
        const auto count = static_cast<std::size_t>(std::min<u64>(remaining, buffer.size()));
        if (input.ReadBytes(buffer.data(), count) != count ||
            output.WriteBytes(buffer.data(), count) != count) return 4;
        remaining -= count;
    }
    return output.Close() ? 0 : 4;
}

int Claw3DSLoad(const char* rom, const char* dataDirectory, void* topLayer, void* bottomLayer,
             int resolution, int cpuClock, bool asyncShaders, int upscaleInput) {
    Claw3DSStop();
    lastError.clear();
    { std::lock_guard lock(workerErrorMutex); workerError.clear(); }
    controls.reset();
    pipelineCacheSaveRequested.store(false);
    Claw::ResetMobileThermal();
    { std::lock_guard lock(performanceMutex); performanceSample = {}; performanceWindow.Reset(); }
    controls.wake = [] { gate.notifyWork(); };
    AudioCore::SetCoreAudioSpeed(1);
    Claw::ResetTransitionCache();
    try {
        if (!rom || !*rom || !dataDirectory || !*dataDirectory) {
            lastError = "The game or data directory is unavailable.";
            return -1;
        }
        if (!topLayer || !bottomLayer) {
            lastError = "The two display surfaces are unavailable.";
            return -1;
        }
        const std::string dataRoot = FileUtil::SanitizePath(dataDirectory) + "/";
        // Use the frontend's current sandbox root on every load, never a cached
        // desktop fallback or the path from a previous app-container installation.
        if (!FileUtil::CreateFullPath(dataRoot) || !FileUtil::IsDirectory(dataRoot)) {
            lastError = "The app's EmulationData directory could not be opened or created.";
            return -1;
        }
        FileUtil::SetUserPath(dataRoot);
#if CLAW_DISABLE_LOGGING
        Common::Log::Initialize(dataRoot + "last-core-error.txt");
#endif
        launchStagePath = dataRoot + "last-3ds-launch.txt";
        RecordLaunchStage("Data directory ready");
        RecordLaunchStage("Checking embedded FFmpeg frameworks");
        ProbeBundledFFmpeg(dataRoot);
        RecordLaunchStage("FFmpeg framework preflight finished");
        // Vulkan pipeline blobs are regenerable and must live outside the
        // Documents-backed emulation data. iOS excludes Library/Caches from
        // iCloud backup while retaining it across ordinary app updates.
        NSURL* cacheURL = [NSFileManager.defaultManager URLForDirectory:NSCachesDirectory
                        inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
        if (!cacheURL || !FileUtil::CreateFullPath(std::string(cacheURL.fileSystemRepresentation) + "/")) {
            lastError = "The app's pipeline cache directory could not be created.";
            return -1;
        }
        FileUtil::UpdateUserPath(FileUtil::UserPath::CacheDir,
                                 std::string(cacheURL.fileSystemRepresentation) + "/");
        // Claw3DSStop above joined the old session; publish hardware budgets before
        // constructing the renderer or starting its workers.
        Claw::InitializeMobileDeviceProfile(dataRoot.c_str());
        const std::string sysdataRoot = dataRoot + "sysdata/";
        if (!FileUtil::CreateFullPath(sysdataRoot) || !FileUtil::IsDirectory(sysdataRoot)) {
            lastError = "The app's sysdata directory could not be opened or created.";
            return -1;
        }
        // This upstream core defaults to system_data; the app's established
        // import/export schema and Files instructions use EmulationData/sysdata.
        FileUtil::UpdateUserPath(FileUtil::UserPath::SysDataDir, sysdataRoot);
        sessionSysdata = sysdataRoot;
        sessionStates = FileUtil::GetUserPath(FileUtil::UserPath::StatesDir);
        // Recover recognizable leftovers from an earlier interrupted process too.
        Claw::CleanupSessionArtifacts(sessionSysdata, sessionStates);
        if (FileUtil::GetUserPath(FileUtil::UserPath::UserDir) != dataRoot ||
            FileUtil::GetUserPath(FileUtil::UserPath::SysDataDir) != sysdataRoot) {
            lastError = "The core's data directory does not match this app's EmulationData directory.";
            return -1;
        }
        FileUtil::IOFile romFile(rom, "rb");
        if (!romFile.IsOpen() || romFile.GetSize() < 0x200) {
            lastError = "The imported game file is unreadable or incomplete. Reimport it from Files.";
            return -1;
        }
        if (!initialized) {
            RecordLaunchStage("Initializing core configuration");
            Config{};
            initialized = true;
        }
        if (!driver) {
            RecordLaunchStage("Loading MoltenVK");
            void* handle = dlopen("@rpath/MoltenVK.framework/MoltenVK", RTLD_NOW);
            if (!handle) {
                lastError = "The bundled MoltenVK graphics framework could not be loaded.";
                return -1;
            }
            driver = std::make_shared<Common::DynamicLibrary>(handle);
        }
        RecordLaunchStage("MoltenVK loaded; preparing display layers");
        ownedTopLayer = (__bridge CAMetalLayer*)topLayer;
        ownedBottomLayer = (__bridge CAMetalLayer*)bottomLayer;
        Claw::ConfigureSpatialUpscale(upscaleInput);
        if (const auto config = Claw::GetSpatialUpscaleConfig()) {
            if (!Claw::SupportsSpatialScaler(ownedTopLayer.device) ||
                !Claw::SupportsSpatialScaler(ownedBottomLayer.device))
                config->Fail("MetalFX unsupported by display device");
        }
        const bool requestedUpscale = upscaleInput == 2 || upscaleInput == 3;
        const int internalScale = requestedUpscale
            ? (Claw::SpatialUpscaleInputScale() ? 2 : 4) : resolution;
        applyProfile(internalScale, cpuClock, asyncShaders);
        // Preserve the requested internal scale through both display surfaces.
        const int scale = requestedUpscale ? 4 : Claw3DSPresentationScale(resolution);
        Claw::mobile_base_presentation_scale.store(scale);
        if (!ownedTopLayer.device || !ownedBottomLayer.device ||
            ownedTopLayer.drawableSize.width != 400 * scale ||
            ownedTopLayer.drawableSize.height != 240 * scale ||
            ownedBottomLayer.drawableSize.width != 320 * scale ||
            ownedBottomLayer.drawableSize.height != 240 * scale) {
            lastError = "The game display layers are not ready. Return to the library and retry.";
            Claw3DSStop();
            return -1;
        }
        RecordLaunchStage("Creating Vulkan windows");
        topWindow = std::make_unique<EmulationWindow_Vulkan>(static_cast<CA::MetalLayer*>(topLayer),
                         false, driver, 240 * scale, 400 * scale);
        bottomWindow = std::make_unique<EmulationWindow_Vulkan>(static_cast<CA::MetalLayer*>(bottomLayer),
                         true, driver, 240 * scale, 320 * scale);
        auto& system = Core::System::GetInstance();
        FileUtil::SetCurrentRomPath(rom);
        Frontend::RegisterDefaultApplets(system);
        system.ApplySettings();
        InputManager::Init();
        inputsInitialized = true;
        sessionLoaded = true;
        RecordLaunchStage("Loading 3DS core and ROM");
        auto result = system.Load(*topWindow, rom, bottomWindow.get());
        if (result != Core::System::ResultStatus::Success) {
            lastError = loadError(result);
            Claw3DSStop();
            return static_cast<int>(result);
        }
        RecordLaunchStage("3DS core loaded; starting emulation worker");
        loadedTitle.store(system.StateTitle());
        fps.store(0);
        speed.store(0);
        runtimeStatus.store(0);
        AudioCore::SetCoreAudioPaused(false);
        gate.begin();
        gate.pause(true);
        AudioCore::SetCoreAudioPaused(true);
        active.store(true);
        emulationThread = std::thread([preferred_resolution = Settings::values.resolution_factor.GetValue()] {
            @autoreleasepool {
                pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
                auto& system = Core::System::GetInstance();
                auto lastSample = std::chrono::steady_clock::now();
                bool wasPaused = true;
                bool pipelineSavePending = false;
                Claw::MobileThermalGovernor thermal;
                bool firstLoop = true;
                bool firstSample = true;
                try {
                    while (gate.waitForWork() != SessionGate::Wake::Stopped) {
                        const bool paused = gate.isPaused();
                        auto* rasterizer = system.GPU().Renderer().Rasterizer();
                        if (pipelineSavePending) {
                            rasterizer->WaitBackgroundDiskResources();
                            pipelineSavePending = false;
                        }
                        controls.process(system, paused);
                        if (paused && pipelineCacheSaveRequested.exchange(false)) {
                            rasterizer->SaveBackgroundDiskResources(FinishPipelineCacheBackgroundTask);
                            pipelineSavePending = true;
                        } else if (!paused && pipelineCacheSaveRequested.exchange(false)) {
                            // A rapid foreground transition can overtake the
                            // paused save boundary. Release its iOS task;
                            // teardown still persists the latest cache.
                            FinishPipelineCacheBackgroundTask();
                        }
                        const int requested_heat = Claw::mobile_requested_thermal_state.load(std::memory_order_relaxed);
                        const int previous_heat = Claw::mobile_applied_thermal_state.load(std::memory_order_relaxed);
                        if (requested_heat >= 2 || previous_heat >= 2) {
                            const int applied_heat = thermal.Observe(requested_heat, std::chrono::steady_clock::now());
                            if (applied_heat != previous_heat)
                                Claw::mobile_applied_thermal_state.store(applied_heat, std::memory_order_relaxed);
                            int restored_scale = preferred_resolution;
                            if (applied_heat == 0) {
                                if (const auto config = Claw::GetSpatialUpscaleConfig(); config && config->failed.load())
                                    restored_scale = 4;
                            }
                            const int target_scale = Claw::ThermalRenderScale(restored_scale,
                                Claw::mobile_base_presentation_scale.load(), applied_heat);
                            if (Settings::values.resolution_factor.GetValue() != target_scale)
                                Settings::values.resolution_factor.SetValue(target_scale);
                        }
                        if (paused) { wasPaused = true; continue; }
                        if (wasPaused) {
                            system.GPU().Renderer().InvalidatePresentationCache();
                            // A pause is not evidence of a slow interpreter.
                            // Exclude menu/background time from the rate sample.
                            static_cast<void>(system.GetAndResetPerfStats());
                            static_cast<void>(system.frame_limiter.TakePacingStats());
                            { std::lock_guard lock(performanceMutex); performanceSample = {}; performanceWindow.Reset(); }
                            lastSample = std::chrono::steady_clock::now();
                            wasPaused = false;
                        }
                        if (firstLoop) RecordLaunchStage("Entering first 3DS RunLoop");
                        auto result = system.RunLoop();
                        if (firstLoop) {
                            RecordLaunchStage("First 3DS RunLoop returned");
                            firstLoop = false;
                        }
                        if (result != Core::System::ResultStatus::Success) {
                            RecordLaunchStage("3DS RunLoop returned an error");
                            if (result == Core::System::ResultStatus::ErrorUnknown) {
                                std::lock_guard lock(workerErrorMutex);
                                workerError = system.GetStatusDetails();
                            }
                            runtimeStatus.store(static_cast<int>(result));
                            break;
                        }
                        auto now = std::chrono::steady_clock::now();
                        if (now - lastSample >= std::chrono::milliseconds(500)) {
                            auto stats = system.GetAndResetPerfStats();
                            const auto pacing = system.frame_limiter.TakePacingStats();
                            {
                                std::lock_guard lock(performanceMutex);
                                performanceSample = {true, controls.speedMultiplier.load(),
                                    Settings::values.frame_limit.GetValue(), Settings::GetFrameLimit(),
                                    static_cast<double>(Settings::values.resolution_factor.GetValue()),
                                    static_cast<double>(Settings::values.cpu_clock_percentage.GetValue()),
                                    Claw::SpatialUpscaleStatus(), stats, pacing,
                                    Settings::values.async_presentation.GetValue()};
                                performanceWindow.Add(stats.emulation_speed,
                                    std::chrono::duration<double>(now - lastSample).count());
                            }
                            fps.store(stats.game_fps);
                            speed.store(stats.emulation_speed);
                            lastSample = now;
                            if (firstSample) {
                                RecordLaunchStage("3DS running; first performance sample collected");
                                firstSample = false;
                            }
                        }
                    }
                } catch (const std::exception& error) {
                    RecordLaunchStage("Emulation worker caught a C++ exception");
                    { std::lock_guard lock(workerErrorMutex); workerError = error.what(); }
                    runtimeStatus.store(-1);
                } catch (...) {
                    RecordLaunchStage("Emulation worker caught an unknown exception");
                    runtimeStatus.store(-1);
                }
                AudioCore::SetCoreAudioPaused(true);
                active.store(false);
                controls.states.cancel();
                gate.stop();
            }
        });
        return 0;
    } catch (const std::exception& e) {
        lastError = std::string("The core reported: ") + e.what();
        Claw3DSStop();
        return -1;
    }
}

const char* Claw3DSLastError() {
    if (lastError.empty() && runtimeStatus.load() != 0 && !Claw3DSDidRequestShutdown()) {
        std::lock_guard lock(workerErrorMutex);
        lastError = workerError.empty()
            ? "Emulation stopped with status " + std::to_string(runtimeStatus.load()) +
                ". Your last in-game save is kept."
            : workerError;
    }
    return lastError.c_str();
}

void Claw3DSRequestStop() {
    AudioCore::SetCoreAudioPaused(true);
    const bool was_active = active.exchange(false);
    gate.stop();
    if (was_active) {
        Core::System::GetInstance().RequestShutdown();
    }
}

void Claw3DSStop() {
    Claw3DSRequestStop();
    // Finish the current RunLoop and join before destroying the system or display surfaces.
    if (emulationThread.joinable()) emulationThread.join();
    controls.joinStateWorker();
    loadedTitle.store(0);
    std::lock_guard lock(inputMutex);
    if (sessionLoaded) {
        Core::System::GetInstance().Shutdown();
        sessionLoaded = false;
    }
    FinishPipelineCacheBackgroundTask();
    if (inputsInitialized) {
        InputManager::Shutdown();
        inputsInitialized = false;
    }
    controls.speedMultiplier.store(1);
    controls.states.cancel();
    Settings::values.frame_limit.SetValue(100.0);
    Settings::values.use_vsync.SetValue(false);
    Settings::values.enable_realtime_audio.SetValue(false);
    topWindow.reset();
    bottomWindow.reset();
    ownedTopLayer = nil;
    ownedBottomLayer = nil;
    Claw::ConfigureSpatialUpscale(0);
    // No open core/cache/audio/presentation worker can be using these files now.
    Claw::CleanupSessionArtifacts(sessionSysdata, sessionStates);
    sessionSysdata.clear();
    sessionStates.clear();
}

void Claw3DSPause(bool paused) {
    AudioCore::SetCoreAudioPaused(paused);
    gate.pause(paused);
    if (paused) gate.notifyWork(); // Record the pause boundary before sleeping.
}
void Claw3DSRequestPipelineCacheSave() {
    if (!active.load()) return;
    if (pipelineCacheBackgroundTask == UIBackgroundTaskInvalid) {
        pipelineCacheBackgroundTask = [UIApplication.sharedApplication
            beginBackgroundTaskWithName:@"Claw Vulkan pipeline cache"
            expirationHandler:^{ FinishPipelineCacheBackgroundTask(); }];
    }
    pipelineCacheSaveRequested.store(true);
    gate.notifyWork();
}
void Claw3DSSetVolume(float volume) {
    AudioCore::SetCoreAudioVolume(volume);
}
void Claw3DSMemoryPressure() { Claw::ReleaseTransitionCache(); }
void Claw3DSSetThermalState(int state) {
    Claw::mobile_requested_thermal_state.store(std::clamp(state, 0, 3), std::memory_order_relaxed);
    gate.notifyWork();
}
int Claw3DSAppliedThermalState() { return Claw::mobile_applied_thermal_state.load(std::memory_order_relaxed); }
uint64_t Claw3DSAvailableMemoryBytes() { return os_proc_available_memory(); }
void Claw3DSSetFastForward(bool enabled) { Claw3DSSetSpeed(enabled ? 2 : 1); }
void Claw3DSSetSpeed(int multiplier) {
    std::lock_guard lock(inputMutex);
    if (!active.load()) return;
    const int selected = multiplier == 2 || multiplier == 4 ? multiplier : 1;
    controls.speedMultiplier.store(selected);
    AudioCore::SetCoreAudioSpeed(selected);
    gate.notifyWork();
}
static bool RequestState(bool restore, int slot) {
    std::lock_guard lock(inputMutex);
    if (!active.load() || !controls.states.request(restore, slot)) return false;
    gate.notifyWork();
    return true;
}
bool Claw3DSSaveState(int slot) { return RequestState(false, slot); }
bool Claw3DSLoadState(int slot) { return RequestState(true, slot); }
uint64_t Claw3DSCurrentTitle() { return loadedTitle.load(); }
int Claw3DSStateStatus() { return static_cast<int>(controls.states.status()); }
const char* Claw3DSStateError() {
    thread_local std::string copy;
    copy = controls.states.error();
    return copy.c_str();
}
bool Claw3DSIsRunning() { return active.load(); }
bool Claw3DSDidRequestShutdown() {
    return runtimeStatus.load() == static_cast<int>(Core::System::ResultStatus::ShutdownRequested);
}
void Claw3DSButton(int button, bool pressed) {
    std::lock_guard lock(inputMutex);
    if (!active.load()) return;
    if (auto handler = InputManager::ButtonHandler()) {
        if (pressed) handler->PressKey(button); else handler->ReleaseKey(button);
    }
}
void Claw3DSAnalog(float x, float y) {
    std::lock_guard lock(inputMutex);
    if (active.load())
        if (auto handler = InputManager::AnalogHandler()) handler->MoveJoystick(713, x, y);
}
void Claw3DSTouch(float x, float y, bool down) {
    std::lock_guard lock(inputMutex);
    if (active.load() && bottomWindow) {
        if (down) bottomWindow->TouchPressed(x, y); else bottomWindow->TouchReleased();
    }
}
double Claw3DSFPS() { return fps.load(); }
double Claw3DSSpeed() { return speed.load(); }
const char* Claw3DSPerformanceReport() {
    PerformanceSample sample;
    Claw::PerformanceWindow::Summary window;
    { std::lock_guard lock(performanceMutex); sample = performanceSample; window = performanceWindow.Get(); }
    if (!sample.valid) return "No running sample yet. Resume the game for five seconds first.";
    // Format only on an explicit user request; never allocate/report from the audio callback.
    thread_local char report[2048];
    const double calls = static_cast<double>(sample.pacing.calls);
    std::snprintf(report, sizeof(report),
        "3DS last running sample\nPerformance restoration: Build 30 paths\n"
        "Presentation: %s\nNative selected speed: %dx\nApplied frame limit: %.0f%%\n"
        "Guest effective limit: %.0f%%\nPacer target: %.0f%%\nAchieved speed: %.3fx\n"
        "Recent running window: %.2f s (%zu samples)\nWindow speed mean/min/max: %.3fx / %.3fx / %.3fx\n"
        "Game FPS: %.2f\nSystem VBlanks/s: %.2f\n"
        "Requested limiter sleep: %.3f ms/VBlank\nActual limiter sleep: %.3f ms/VBlank (2x/4x only)\n"
        "CPU/other work: %.3f ms/VBlank\nHLE SVC: %.3f ms/VBlank\nHLE IPC: %.3f ms/VBlank\n"
        "GPU command processing: %.3f ms/VBlank\nDisplay/swap: %.3f ms/VBlank\n"
        "Render scale: %.0fx\nGuest CPU clock: %.0f%%\nMetalFX status: %d\nJIT: disabled\n",
        sample.async_presentation ? "threaded" : "inline", sample.selected_speed, sample.applied_limit, sample.effective_limit,
        sample.pacing.target_percent, sample.stats.emulation_speed,
        window.seconds, window.samples, window.mean, window.minimum, window.maximum,
        sample.stats.game_fps,
        sample.stats.system_fps,
        calls ? sample.pacing.requested_sleep_seconds * 1000 / calls : 0,
        calls ? sample.pacing.actual_sleep_seconds * 1000 / calls : 0,
        sample.stats.time_remaining * 1000, sample.stats.time_hle_svc * 1000,
        sample.stats.time_hle_ipc * 1000, sample.stats.time_gpu * 1000,
        sample.stats.time_swap * 1000, sample.resolution, sample.cpu_clock, sample.metalfx);
    return report;
}
bool Claw3DSMetalFXSupported() { return Claw::GetMobileDeviceCapabilities().metalfx_supported; }
int Claw3DSMetalFXStatus() { return Claw::SpatialUpscaleStatus(); }
const char* Claw3DSMetalFXError() {
    thread_local std::string reason;
    reason = Claw::SpatialUpscaleFailureReason();
    return reason.c_str();
}

static void EnsureDeviceDefaults() {
    static std::once_flag once;
    std::call_once(once, [] { Claw::InitializeMobileDeviceProfile(nullptr); });
}
int Claw3DSDefaultResolution() { EnsureDeviceDefaults(); return Claw::SelectMobileGraphicsProfile(Claw::GetMobileDeviceCapabilities()).resolution; }
int Claw3DSDefaultMetalFXInput() { EnsureDeviceDefaults(); return Claw::SelectMobileGraphicsProfile(Claw::GetMobileDeviceCapabilities()).metalfx_input; }

const char* Claw3DSDeviceModel() { return Claw::MobileDeviceModel(); }
