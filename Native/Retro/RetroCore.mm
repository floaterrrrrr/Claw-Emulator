// SPDX-License-Identifier: GPL-3.0-or-later
#include "RetroCore.h"
#include "RetroRuntime.hpp"
#include "MobileThermal.hpp"
#include "audio_core/apple_pcm_converter.h"
#include "audio_core/mobile_audio_buffer.h"
#include "audio_core/mobile_audio_volume.h"
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CAMetalDisplayLink.h>
#include <simd/simd.h>
#include <array>
#include <cmath>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <pthread.h>
#include <pthread/qos.h>
#if !defined(DISABLE_JIT) || DISABLE_JIT != 1 || !defined(STRICT_INTERPRETER) || STRICT_INTERPRETER != 1
#error "Claw bundled cores require the interpreter-only application profile."
#endif

// A display-synchronized callback on the native render thread, not the main
// run loop. The app already requires iOS 17, where CAMetalDisplayLink is public.
@interface ClawRetroDisplayTarget : NSObject <CAMetalDisplayLinkDelegate>
@property(nonatomic, copy) void (^update)(CAMetalDisplayLink*, CAMetalDisplayLinkUpdate*);
@end
@implementation ClawRetroDisplayTarget
- (void)metalDisplayLink:(CAMetalDisplayLink*)link needsUpdate:(CAMetalDisplayLinkUpdate*)update {
    if (self.update) self.update(link, update);
}
@end

namespace {
using namespace ClawRetro;
std::shared_ptr<Runtime> current;
std::mutex failureMutex;
std::string failure;
std::atomic<float> targetVolume{1};
struct AppleHost {
    std::shared_ptr<Runtime> core;
    CAMetalLayer* top{}; CAMetalLayer* bottom{};
    bool dual{};
    AudioUnit unit{};
    std::atomic_bool stopped{false};
    AudioCore::MobilePCM16Buffer output;
    AudioCore::MobileAudioVolume gain;
    unsigned callbackEpoch{};
    unsigned callbackDiscontinuity{};
    std::atomic_uint audioDiscontinuity{0};
    AudioLatencyBudget latencyBudget;
    std::thread audioThread, videoThread;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> pipeline;
    dispatch_semaphore_t inFlight;
    std::mutex renderLoopMutex;
    CFRunLoopRef renderLoop{};
    std::array<id<MTLTexture>, 3> textures{};
    unsigned textureIndex{};
    std::uint64_t presentedSequence{};
    Claw::MobileThermalGovernor thermal;
    std::mutex sleepMutex;
    std::condition_variable wake;
    explicit AppleHost(std::shared_ptr<Runtime> value) : core(std::move(value)),
        output(AudioTargetFrames(core->coreType(), AudioCore::mobile_latency_frames)) {
        core->outputAudioTarget.store(output.TargetFrames());
    }
    ~AppleHost() { stop(); }
    void require(OSStatus status, const char* action) {
        if (status != noErr) throw std::runtime_error(std::string("Audio could not ") + action + " (" + std::to_string(status) + ").");
    }
    static OSStatus audioCallback(void* context, AudioUnitRenderActionFlags*, const AudioTimeStamp*, UInt32,
                                  UInt32 frames, AudioBufferList* buffers) noexcept {
        auto& host = *static_cast<AppleHost*>(context);
        for (UInt32 i = 0; i < buffers->mNumberBuffers; ++i)
            if (buffers->mBuffers[i].mData) std::memset(buffers->mBuffers[i].mData, 0, buffers->mBuffers[i].mDataByteSize);
        const auto epoch = host.core->epoch();
        const auto discontinuity = host.audioDiscontinuity.load(std::memory_order_acquire);
        if (epoch != host.callbackEpoch || discontinuity != host.callbackDiscontinuity) {
            host.output.Discard(); host.callbackEpoch = epoch; host.callbackDiscontinuity = discontinuity;
        }
        if (host.core->paused() || host.core->speed() == 4 || host.stopped.load()) { host.output.Mute(); return noErr; }
        if (buffers->mNumberBuffers != 1 || !buffers->mBuffers[0].mData || buffers->mBuffers[0].mNumberChannels != 2) return noErr;
        auto& b = buffers->mBuffers[0]; const auto count = std::min<std::size_t>(frames, b.mDataByteSize / 4);
        auto samples = std::span<std::int16_t>(static_cast<std::int16_t*>(b.mData), count * 2);
        if (host.core->coreType() == 1) {
            const auto before = host.output.Underruns();
            host.output.Read(samples, host.latencyBudget.target(count));
            host.latencyBudget.observe(count, host.output.Underruns() != before);
            host.core->outputAudioTarget.store(host.latencyBudget.target(count), std::memory_order_relaxed);
        } else { host.output.Read(samples); }
        host.core->outputAudioFrames.store(host.output.BufferedFrames(), std::memory_order_relaxed);
        host.core->audioUnderruns.store(host.output.Underruns(), std::memory_order_relaxed);
        host.gain.Apply(samples, targetVolume.load()); return noErr;
    }
    void initialize() {
        device = top.device;
        queue = [device newCommandQueue];
        if (!queue) throw std::runtime_error("Metal command submission is unavailable.");
        const auto source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct V { float4 p [[position]]; float2 uv; };\n"
            "vertex V claw_vertex(uint i [[vertex_id]], constant float4& crop [[buffer(0)]]) {\n"
            "float2 p[4]={float2(-1,1),float2(-1,-1),float2(1,1),float2(1,-1)};\n"
            "float2 uv[4]={float2(0,0),float2(0,1),float2(1,0),float2(1,1)};\n"
            "V o; o.p=float4(p[i],0,1);o.uv=crop.xy+uv[i]*crop.zw;return o;}\n"
            "fragment half4 claw_fragment(V i [[stage_in]], texture2d<half> t [[texture(0)]]) {\n"
            "constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);return t.sample(s,i.uv);}";
        NSError* error = nil;
        id<MTLLibrary> shaders = [device newLibraryWithSource:source options:nil error:&error];
        if (!shaders) throw std::runtime_error("The emulator display shader could not compile.");
        auto* description = [MTLRenderPipelineDescriptor new];
        description.vertexFunction = [shaders newFunctionWithName:@"claw_vertex"];
        description.fragmentFunction = [shaders newFunctionWithName:@"claw_fragment"];
        description.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pipeline = [device newRenderPipelineStateWithDescriptor:description error:&error];
        if (!pipeline) throw std::runtime_error("The emulator display pipeline is unavailable.");
        // A tiny 2D blit needs only one queued GPU command. Keeping multiple
        // complete game frames in flight adds latency without useful throughput.
        inFlight = dispatch_semaphore_create(1);
        AudioComponentDescription component{};
        component.componentType = kAudioUnitType_Output; component.componentSubType = kAudioUnitSubType_RemoteIO;
        component.componentManufacturer = kAudioUnitManufacturer_Apple;
        const auto available = AudioComponentFindNext(nullptr, &component);
        if (!available) throw std::runtime_error("Audio output is unavailable.");
        require(AudioComponentInstanceNew(available, &unit), "create output");
        AudioStreamBasicDescription pcm{}; pcm.mSampleRate = 48000; pcm.mFormatID = kAudioFormatLinearPCM;
        pcm.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
        pcm.mBytesPerFrame = pcm.mBytesPerPacket = 4; pcm.mFramesPerPacket = 1; pcm.mChannelsPerFrame = 2; pcm.mBitsPerChannel = 16;
        require(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &pcm, sizeof(pcm)), "configure PCM");
        const UInt32 maximumFrames = 8192;
        require(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFrames, sizeof(maximumFrames)), "configure callback capacity");
        const AURenderCallbackStruct callback{audioCallback, this};
        require(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)), "install callback");
        require(AudioUnitInitialize(unit), "initialize output");
        require(AudioOutputUnitStart(unit), "start output");
        audioThread = std::thread([this] { produceAudio(); });
        videoThread = std::thread([this] { produceVideo(); });
    }
    void wait(std::chrono::milliseconds duration) {
        std::unique_lock lock(sleepMutex); wake.wait_for(lock, duration, [this] { return stopped.load(); });
    }
    void produceAudio() noexcept {
        pthread_setname_np("ClawRetroAudio");
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        std::unique_ptr<AudioCore::ApplePCMConverter> converter;
        unsigned previousEpoch = ~0u;
        std::array<std::int16_t, 2048> pcm{};
        while (!stopped.load()) {
            try {
                const auto epoch = core->epoch();
                if (epoch != previousEpoch) {
                    core->audio.discard(); converter.reset(); previousEpoch = epoch;
                }
                if (core->paused() || core->speed() == 4) { core->audio.discard(); wait(std::chrono::milliseconds(5)); continue; }
                const auto queued = core->audio.bufferedFrames();
                core->sourceAudioFrames.store(queued, std::memory_order_relaxed);
                if (core->coreType() == 1) {
                    // Keep at most three source frames, scaled for the actual
                    // PWM clock and selected speed. Trim only on recovery from
                    // a backlog, never as routine rate/pitch control.
                    const auto maximum = static_cast<std::size_t>(std::ceil(core->sampleRate() * core->speed() * 3 / core->nativeFPS()));
                    if (queued > maximum) {
                        core->staleAudioFrames.fetch_add(core->audio.trimTo(maximum), std::memory_order_relaxed);
                        converter.reset(); ++audioDiscontinuity;
                    }
                }
                if (!converter) converter = std::make_unique<AudioCore::ApplePCMConverter>(
                    [this](std::int16_t* out, std::size_t n) { return core->audio.pop(out, n); },
                    static_cast<unsigned>(std::lround(core->sampleRate() * core->speed())));
                const auto buffered = output.BufferedFrames();
                const auto target = core->outputAudioTarget.load(std::memory_order_relaxed);
                if (buffered >= target) {
                    wait(std::chrono::milliseconds(core->coreType() == 1 ? 2 : 5)); continue;
                }
                // Smaller mGBA conversion quanta reduce target overshoot without
                // changing the fixed-ratio resampler or the guest's 1x clock.
                const auto samples = core->coreType() == 1 ? std::min<std::size_t>(512, target - buffered) * 2 : 2048;
                const auto n = converter->Convert({pcm.data(), samples});
                if (epoch == core->epoch()) output.Push({pcm.data(), n * 2});
                if (!n) wait(std::chrono::milliseconds(2));
            } catch (...) {
                core->audioConversionErrors.fetch_add(1, std::memory_order_relaxed);
                converter.reset(); wait(std::chrono::milliseconds(5));
            }
        }
    }
    bool draw(CAMetalLayer* layer, id<MTLTexture> texture, id<MTLCommandBuffer> commands,
              vector_float4 crop, id<CAMetalDrawable> supplied, double sourceAge) {
        id<CAMetalDrawable> drawable = supplied ?: [layer nextDrawable];
        if (!drawable) return false;
        auto* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLRenderCommandEncoder> encode = [commands renderCommandEncoderWithDescriptor:pass];
        [encode setRenderPipelineState:pipeline]; [encode setVertexBytes:&crop length:sizeof(crop) atIndex:0];
        [encode setFragmentTexture:texture atIndex:0];
        [encode drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4]; [encode endEncoding];
        if (layer == top) {
            const auto session = core;
            const auto epoch = core->epoch();
            const auto submitted = CACurrentMediaTime();
            [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
                if (!session->paused() && session->epoch() == epoch) {
                    session->presentation.record(presented.presentedTime, epoch);
                    session->displayQueueMS.store(sourceAge + std::max(0.0, presented.presentedTime - submitted) * 1000,
                                                  std::memory_order_relaxed);
                }
            }];
        }
        // CAMetalDisplayLink owns the presentation deadline. An additional
        // present-at-time floor can push a frame onto the following refresh.
        [commands presentDrawable:drawable];
        return true;
    }
    void renderFrame(id<CAMetalDrawable> drawable) {
        if (!drawable || stopped.load() || core->paused() || !core->running()) return;
        // Sample the latest frame at the display callback, after the system
        // supplies a drawable; never wait on the core or a busy GPU here.
        const auto picture = core->frame();
        if (!picture || picture->sequence == presentedSequence) return;
        if (dispatch_semaphore_wait(inFlight, DISPATCH_TIME_NOW)) return;
        struct Permit {
            dispatch_semaphore_t semaphore;
            bool submitted = false;
            ~Permit() { if (!submitted) dispatch_semaphore_signal(semaphore); }
        } permit{inFlight};
        auto& texture = textures[textureIndex++ % textures.size()];
        if (!texture || texture.width != picture->width || texture.height != picture->height) {
            auto* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                width:picture->width height:picture->height mipmapped:NO];
            desc.usage = MTLTextureUsageShaderRead; desc.storageMode = MTLStorageModeShared;
            texture = [device newTextureWithDescriptor:desc];
        }
        if (!texture) return;
        [texture replaceRegion:MTLRegionMake2D(0, 0, picture->width, picture->height) mipmapLevel:0
            withBytes:picture->bgra.data() bytesPerRow:picture->width * 4];
        id<MTLCommandBuffer> commands = [queue commandBuffer];
        if (!commands) return;
        const auto age = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - picture->publishedAt).count();
        if (!draw(top, texture, commands, (vector_float4){0, 0, 1, dual ? 0.5f : 1}, drawable, age)) return;
        if (dual) draw(bottom, texture, commands, (vector_float4){0, 0.5f, 1, 0.5f}, nil, age);
        const auto semaphore = inFlight;
        [commands addCompletedHandler:^(id<MTLCommandBuffer>) { dispatch_semaphore_signal(semaphore); }];
        [commands commit]; permit.submitted = true; presentedSequence = picture->sequence;
    }
    void produceVideo() noexcept {
        pthread_setname_np("ClawRetroVideo");
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        @autoreleasepool {
            auto* target = [ClawRetroDisplayTarget new];
            auto* link = [[CAMetalDisplayLink alloc] initWithMetalLayer:top];
            link.preferredFrameLatency = 1;
            link.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
            link.paused = NO;
            target.update = ^(CAMetalDisplayLink* display, CAMetalDisplayLinkUpdate* update) {
                if (stopped.load()) return;
                const auto requested_heat = Claw::mobile_requested_thermal_state.load(std::memory_order_relaxed);
                if (requested_heat >= 2 || Claw::MobileThermallyLimited()) {
                    Claw::mobile_applied_thermal_state.store(thermal.Observe(requested_heat,
                        std::chrono::steady_clock::now()), std::memory_order_relaxed);
                }
                const auto hz = DisplayTargetHz(core->paused(),
                    Claw::mobile_applied_thermal_state.load(std::memory_order_relaxed));
                if (display.preferredFrameRateRange.preferred != hz)
                    display.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, hz);
                @autoreleasepool {
                    try { renderFrame(update.drawable); }
                    catch (...) { core->requestStop(); }
                }
            };
            link.delegate = target;
            [link addToRunLoop:NSRunLoop.currentRunLoop forMode:NSDefaultRunLoopMode];
            {
                std::lock_guard lock(renderLoopMutex);
                renderLoop = CFRunLoopGetCurrent(); CFRetain(renderLoop);
            }
            // Timeout is a shutdown fallback if Stop arrives just before the
            // run loop starts. Active callbacks are driven by the display.
            while (!stopped.load()) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, true);
            [link invalidate]; target.update = nil;
            {
                std::lock_guard lock(renderLoopMutex);
                CFRelease(renderLoop); renderLoop = nullptr;
            }
        }
        // Wait for every in-flight command before releasing textures/layers.
        dispatch_semaphore_wait(inFlight, DISPATCH_TIME_FOREVER);
        // Draining proves all GPU callbacks have completed, but the drain's
        // own waits still count as borrowed permits. Restore them before ARC
        // releases the semaphore, or libdispatch aborts: deallocated while in use.
        dispatch_semaphore_signal(inFlight);
    }
    void stop() noexcept {
        if (stopped.exchange(true)) return;
        core->wakeFrameWaiters();
        {
            std::lock_guard lock(renderLoopMutex);
            if (renderLoop) CFRunLoopStop(renderLoop);
        }
        if (unit) { AudioOutputUnitStop(unit); AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit); unit = nullptr; }
        wake.notify_all();
        if (audioThread.joinable()) audioThread.join();
        if (videoThread.joinable()) videoThread.join();
    }
};
std::unique_ptr<AppleHost> host;
template<class F> void withCore(F task) { if (const auto core = std::atomic_load(&current)) task(*core); }
}
int ClawRetroLoad(int core, uint64_t title, const char* rom, const char* directory, void* top, void* bottom) {
    ClawRetroStop();
    Claw::ResetMobileThermal();
    try {
        if (!rom || !directory || !top || !bottom || core < 1 || core > 3) throw std::runtime_error("Invalid emulator launch parameters.");
        const char* names[] = {"", "ClawmGBA", "ClawNES", "ClawDS"};
        NSString* name = [NSString stringWithUTF8String:names[core]];
        NSString* path = [[NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:[name stringByAppendingString:@".framework"]] stringByAppendingPathComponent:name];
        NSString* revisionPath = [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"SourceRevision.txt"];
        NSString* revision = [NSString stringWithContentsOfFile:revisionPath encoding:NSUTF8StringEncoding error:nullptr];
        if (!revision.length) throw std::runtime_error("The emulator framework is missing its source identity. Run prepare-macos before building.");
        auto session = std::make_shared<Runtime>(Configuration{core, title, rom, directory, path.UTF8String, revision.UTF8String});
        session->start(); std::atomic_store(&current, session);
        host = std::make_unique<AppleHost>(session);
        host->top = (__bridge CAMetalLayer*)top; host->bottom = (__bridge CAMetalLayer*)bottom; host->dual = core == 3;
        host->initialize();
        { std::lock_guard lock(failureMutex); failure.clear(); }
        return 0;
    } catch (const std::exception& error) {
        { std::lock_guard lock(failureMutex); failure = error.what(); }
        ClawRetroStop(); return -1;
    }
}
void ClawRetroStop() { host.reset(); if (auto value = std::atomic_exchange(&current, std::shared_ptr<Runtime>{})) value->stop(); }
void ClawRetroRequestStop() { withCore([](auto& c) { c.requestStop(); }); }
void ClawRetroPause(bool value) { withCore([=](auto& c) { c.pause(value); }); }
void ClawRetroSetSpeed(int value) { withCore([=](auto& c) { c.setSpeed(value); }); }
void ClawRetroSetVolume(float value) { targetVolume.store(std::isfinite(value) ? std::clamp(value, 0.f, 1.f) : 0.f); }
void ClawRetroButton(int key, bool pressed) { withCore([=](auto& c) { c.button(static_cast<unsigned>(key), pressed); }); }
void ClawRetroAnalog(float x, float y) { withCore([=](auto& c) { c.analog(x, y); }); }
void ClawRetroTouch(float x, float y, bool down) { withCore([=](auto& c) { c.touch(x, y, down); }); }
bool ClawRetroState(int slot, bool restore) { const auto c = std::atomic_load(&current); return c && c->state(slot, restore); }
int ClawRetroStateStatus() { const auto c = std::atomic_load(&current); return c ? c->stateStatus() : -1; }
bool ClawRetroIsRunning() { const auto c = std::atomic_load(&current); return c && c->running(); }
double ClawRetroFPS() {
    const auto c = std::atomic_load(&current);
    return c ? c->presentation.sample(CACurrentMediaTime()).fps : 0;
}
const char* ClawRetroPerformanceReport() {
    static thread_local char report[1792];
    const auto c = std::atomic_load(&current);
    if (!c) return "No retro runtime sample is available.";
    const auto video = c->presentation.sample();
    std::snprintf(report, sizeof(report),
        "Retro runtime last running sample\nSelected speed: %dx\nNative refresh: %.3f Hz\n"
        "Emulated FPS: %.2f\nAchieved speed: %.3fx\nGPU-presented FPS: %.2f\n"
        "Worst presentation interval: %.2f ms\nPresented frames in current speed window: %llu\n"
        "Core work (last frame): %.3f ms\nFrame-to-display age (last): %.2f ms\n"
        "Native audio clock: %.0f Hz\nAudio clock changes: %u\n"
        "Audio target: %zu frames (%.2f ms at 48 kHz)\nOutput audio queued: %zu frames\n"
        "Source audio queued (last active): %zu frames\nStale source frames discarded: %llu\n"
        "Source overflow frames: %llu\nAudio underruns: %llu\nAudio converter errors: %u\n"
        "Presentation: CAMetalDisplayLink; 60 Hz running / 30 Hz critical; one GPU submission\nJIT: disabled",
        c->speed(), c->nativeFPS(), c->fps(), c->fps() / c->nativeFPS(), video.fps,
        video.worstIntervalMS, static_cast<unsigned long long>(video.frames),
        c->coreWorkMS.load(), c->displayQueueMS.load(), c->sampleRate(), c->audioClockChanges.load(),
        c->outputAudioTarget.load(), c->outputAudioTarget.load() * 1000.0 / 48000,
        c->outputAudioFrames.load(), c->sourceAudioFrames.load(),
        static_cast<unsigned long long>(c->staleAudioFrames.load()),
        static_cast<unsigned long long>(c->droppedAudioFrames.load()),
        static_cast<unsigned long long>(c->audioUnderruns.load()), c->audioConversionErrors.load());
    return report;
}
const char* ClawRetroError() {
    static thread_local std::string value;
    const auto c = std::atomic_load(&current); value = c ? c->error() : "";
    if (value.empty()) { std::lock_guard lock(failureMutex); value = failure; }
    return value.c_str();
}
