// SPDX-License-Identifier: GPL-3.0-or-later
// Frontend lifecycle/input fixture, not an emulator or audio converter.
#include "HarnessBridge.h"
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>
#include <atomic>
#include <cstring>
#include <cstdio>
#include <thread>
#include <mutex>
#include <initializer_list>
#include <chrono>
static std::atomic<bool> running{false}, paused{false}, mixing{false};
static std::atomic<int> loads{0}, stops{0}, saved{0}, restored{0}, operation{0}, last_button{0};
static std::atomic<unsigned> heldButtons{0};
static std::atomic<int> comboPresses{0};
static std::atomic<float> volume{1};
static std::atomic<int> speed{1}, selectedResolution{2}, selectedUpscale{0};
static std::atomic<bool> touched{false};
static std::atomic<int> touchEvents{0};
static std::atomic<uint64_t> selectedTitle{0x0004000001234500ULL};
static std::atomic<int> coreType{0};
static void Record(const char* event) {
    static std::mutex mutex;
    std::lock_guard lock(mutex);
    @autoreleasepool {
        NSString* directory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString* path = [directory stringByAppendingPathComponent:@"frontend-events.jsonl"];
        std::FILE* file = std::fopen(path.fileSystemRepresentation, "a");
        if (file) { std::fprintf(file, "{\"event\":\"%s\",\"paused\":%d,\"volume\":%.2f,\"loads\":%d,\"stops\":%d,\"mix\":%d}\n",
            event, int(paused.load()), double(volume.load()), loads.load(), stops.load(), int(mixing.load())); std::fclose(file); }
    }
}
int Claw3DSLoad(const char*, const char*, void* top, void* bottom, int resolution, int, bool, int upscale) {
    heldButtons = 0; comboPresses = 0;
    coreType = 0; selectedTitle = 0x0004000001234500ULL;
    selectedResolution = resolution; selectedUpscale = upscale;
    loads.fetch_add(1); running = true; paused = true;
    mixing = (AVAudioSession.sharedInstance.categoryOptions & AVAudioSessionCategoryOptionMixWithOthers) != 0;
    Record("load");
    for (void* pointer : {top, bottom}) {
        CAMetalLayer* layer = (__bridge CAMetalLayer*)pointer;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIView* view = (UIView*)layer.delegate;
            if (![view isKindOfClass:UIView.class]) return;
            UILabel* label = [[UILabel alloc] initWithFrame:view.bounds];
            label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            label.backgroundColor = pointer == top ? [UIColor colorWithRed:.08 green:.20 blue:.29 alpha:1]
                                                   : [UIColor colorWithRed:.24 green:.13 blue:.10 alpha:1];
            label.text = pointer == top ? @"MAIN DISPLAY\nLayout test fixture" : @"TOUCH DISPLAY\nLayout test fixture";
            label.numberOfLines = 2; label.textAlignment = NSTextAlignmentCenter;
            label.textColor = UIColor.whiteColor; label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
            label.userInteractionEnabled = NO; label.isAccessibilityElement = NO;
            [view addSubview:label];
        });
    }
    return 0;
}
const char* Claw3DSLastError() { return ""; }
void Claw3DSStop() { std::this_thread::sleep_for(std::chrono::milliseconds(120)); ++stops; running = false; Record("joined_stop"); }
void Claw3DSRequestStop() {}
void Claw3DSPause(bool value) { paused = value; Record(value ? "pause" : "resume"); }
void Claw3DSSetFastForward(bool value) { Claw3DSSetSpeed(value ? 2 : 1); }
void Claw3DSSetSpeed(int value) { speed = value; Record("speed"); }
void Claw3DSSetVolume(float value) { volume = value; Record("volume"); }
void Claw3DSMemoryPressure() {}
uint64_t Claw3DSCurrentTitle() { return selectedTitle.load(); }
int Claw3DSDefaultResolution() { return [NSProcessInfo.processInfo.arguments containsObject:@"--fixture-a19"] ? 4 : 2; }
int Claw3DSDefaultMetalFXInput() { return Claw3DSDefaultResolution() == 4 ? 2 : 0; }
bool Claw3DSSaveState(int slot) {
    @autoreleasepool {
        NSString* root = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString* directory = [root stringByAppendingPathComponent:@"EmulationData/save_states"];
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nullptr];
        NSString* path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%016llX.%02d.cst", static_cast<unsigned long long>(selectedTitle.load()),slot]];
        unsigned char header[257]{}; header[0]='C'; header[1]='S'; header[2]='T'; header[3]=27;
        if (coreType.load()) { header[1]='R'; header[2]='S'; header[3]=1; }
        const auto title = Claw3DSCurrentTitle(); std::memcpy(header+4,&title,sizeof(title));
        [[NSData dataWithBytes:header length:sizeof(header)] writeToFile:path atomically:YES];
        // Deliberately labelled test frame, not generated gameplay or a ROM.
        UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(400,240)];
        UIImage* picture = [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
            [[UIColor colorWithRed:.1 green:.25 blue:.3 alpha:1] setFill];
            [context fillRect:CGRectMake(0,0,400,240)];
            [@"Saved frame fixture" drawAtPoint:CGPointMake(24,100)
                withAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:24],NSForegroundColorAttributeName:UIColor.whiteColor}];
        }];
        [UIImagePNGRepresentation(picture) writeToFile:[path stringByAppendingString:@".png"] atomically:YES];
    }
    ++saved; operation = 2; Record(slot >= 9 ? "autosave" : "save"); return true;
}
bool Claw3DSLoadState(int) {
    ++restored;
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--reject-restore-request"]) return false;
    operation = [NSProcessInfo.processInfo.arguments containsObject:@"--fail-restore-read"] ? -1 : 3;
    Record("restore"); return true;
}
int Claw3DSStateStatus() { return operation; }
const char* Claw3DSStateError() { return "Fixture state error"; }
bool Claw3DSIsRunning() { return running; }
bool Claw3DSDidRequestShutdown() { return false; }
bool Claw3DSMetalFXSupported() { return true; }
int Claw3DSMetalFXStatus() { return 0; }
const char* Claw3DSMetalFXError() { return ""; }
void Claw3DSButton(int value, bool pressed) {
    if (pressed) last_button = value;
    if (value >= 0 && value < 16) {
        const unsigned bit = 1u << value;
        const unsigned before = pressed ? heldButtons.fetch_or(bit) : heldButtons.fetch_and(~bit);
        const unsigned after = pressed ? before | bit : before & ~bit;
        constexpr unsigned combo = (1u << 11) | (1u << 0); // Example retro R + B combination.
        if ((after & combo) == combo && (before & combo) != combo) ++comboPresses;
    }
}
void Claw3DSAnalog(float, float) {}
void Claw3DSTouch(float, float, bool down) { touched = down; if (down) ++touchEvents; }
double Claw3DSFPS() { return 59.7; }
double Claw3DSSpeed() { return speed.load(); }
const char* Claw3DSPerformanceReport() { return "Fixture performance sample"; }
int ClawRetroLoad(int core, uint64_t title, const char* rom, const char* data, void* top, void* bottom) {
    const int result = Claw3DSLoad(rom, data, top, bottom, 1, 100, false, 0);
    coreType = core; selectedTitle = title; return result;
}
void ClawRetroStop() { Claw3DSStop(); }
void ClawRetroRequestStop() { Claw3DSRequestStop(); }
void ClawRetroPause(bool value) { Claw3DSPause(value); }
void ClawRetroSetSpeed(int value) { Claw3DSSetSpeed(value); }
void ClawRetroSetVolume(float value) { Claw3DSSetVolume(value); }
void ClawRetroButton(int key, bool value) { Claw3DSButton(key, value); }
void ClawRetroAnalog(float x, float y) { Claw3DSAnalog(x, y); }
void ClawRetroTouch(float x, float y, bool down) { Claw3DSTouch(x, y, down); }
bool ClawRetroState(int slot, bool restore) { return restore ? Claw3DSLoadState(slot) : Claw3DSSaveState(slot); }
int ClawRetroStateStatus() { return Claw3DSStateStatus(); }
bool ClawRetroIsRunning() { return Claw3DSIsRunning(); }
double ClawRetroFPS() { return 60; }
const char* ClawRetroPerformanceReport() { return "Fixture retro presentation sample"; }
const char* ClawRetroError() { return ""; }
const char* Claw3DSTestState() {
    static thread_local char message[240];
    std::snprintf(message, sizeof(message), "running=%d paused=%d volume=%.2f loads=%d stops=%d saved=%d restored=%d mix=%d last=%d touch=%d speed=%d resolution=%d upscale=%d touches=%d held=%u combo=%d",
        int(running.load()), int(paused.load()), double(volume.load()), loads.load(), stops.load(),
        saved.load(), restored.load(), int(mixing.load()), last_button.load(), int(touched.load()), speed.load(), selectedResolution.load(),selectedUpscale.load(),touchEvents.load(),heldButtons.load(),comboPresses.load());
    return message;
}

const char* Claw3DSDeviceModel() { return "layout-fixture"; }

static std::atomic<int> fixtureThermalState{0};
void Claw3DSSetThermalState(int value) { fixtureThermalState = value >= 2 ? value : 0; }
int Claw3DSAppliedThermalState() { return fixtureThermalState; }
uint64_t Claw3DSAvailableMemoryBytes() { return 1024ULL * 1024 * 1024; }
