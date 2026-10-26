// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// Routes frontend commands only. The 3DS guest clock, Vulkan renderer and audio
// workers keep their existing implementation and never enter a libretro core.
struct GameEngine: Sendable {
    let game: Game
    var is3DS: Bool { game.platform == .threeDS }
    func load(_ rom: UnsafePointer<CChar>, _ data: UnsafePointer<CChar>, _ top: UnsafeMutableRawPointer,
              _ bottom: UnsafeMutableRawPointer, _ resolution: Int32, _ cpuClock: Int32,
              _ asyncShaders: Bool, _ upscale: Int32) -> Int32 {
        if is3DS { return Claw3DSLoad(rom, data, top, bottom, resolution, cpuClock, asyncShaders, upscale) }
        return ClawRetroLoad(game.platform.core, game.titleID ?? game.platform.saveIdentity(for: game.id), rom, data, top, bottom)
    }
    func stop() { if is3DS { Claw3DSStop() } else { ClawRetroStop() } }
    func requestStop() { if is3DS { Claw3DSRequestStop() } else { ClawRetroRequestStop() } }
    func pause(_ value: Bool) { if is3DS { Claw3DSPause(value) } else { ClawRetroPause(value) } }
    func requestPipelineCacheSave() { if is3DS { Claw3DSRequestPipelineCacheSave() } }
    func setSpeed(_ value: Int32) { if is3DS { Claw3DSSetSpeed(value) } else { ClawRetroSetSpeed(value) } }
    func setVolume(_ value: Float) { if is3DS { Claw3DSSetVolume(value) } else { ClawRetroSetVolume(value) } }
    func touch(_ x: Float, _ y: Float, _ down: Bool) { if is3DS { Claw3DSTouch(x, y, down) } else { ClawRetroTouch(x, y, down) } }
    func analog(_ x: Float, _ y: Float) { if is3DS { Claw3DSAnalog(x, y) } else { ClawRetroAnalog(x, y) } }
    func button(_ value: Int32, _ pressed: Bool) {
        if is3DS { Claw3DSButton(value, pressed); return }
        // Map Claw's touch key codes to libretro joypad positions.
        let key: Int32
        switch value {
        case 700: key = 8
        case 701: key = 0
        case 702 where game.platform.dualScreen: key = 9
        case 703 where game.platform.dualScreen: key = 1
        case 704: key = 3
        case 705: key = 2
        case 709: key = 4
        case 710: key = 5
        case 711: key = 6
        case 712: key = 7
        case 773 where game.platform.showsControl("l"): key = 10
        case 774 where game.platform.showsControl("r"): key = 11
        default: return
        }
        ClawRetroButton(key, pressed)
    }
    func save(_ slot: Int32) -> Bool { is3DS ? Claw3DSSaveState(slot) : ClawRetroState(slot, false) }
    func restore(_ slot: Int32) -> Bool { is3DS ? Claw3DSLoadState(slot) : ClawRetroState(slot, true) }
    func stateStatus() -> Int32 { is3DS ? Claw3DSStateStatus() : ClawRetroStateStatus() }
    func stateError() -> UnsafePointer<CChar> { is3DS ? Claw3DSStateError() : ClawRetroError() }
    func lastError() -> UnsafePointer<CChar> { is3DS ? Claw3DSLastError() : ClawRetroError() }
    func isRunning() -> Bool { is3DS ? Claw3DSIsRunning() : ClawRetroIsRunning() }
    func currentTitle() -> UInt64 { is3DS ? Claw3DSCurrentTitle() : game.titleID ?? game.platform.saveIdentity(for: game.id) }
    func fps() -> Double { is3DS ? Claw3DSFPS() : ClawRetroFPS() }
    func emulationSpeed() -> Double { is3DS ? Claw3DSSpeed() : 0 }
    func didRequestShutdown() -> Bool { is3DS && Claw3DSDidRequestShutdown() }
    func setThermalState(_ value: Int32) { Claw3DSSetThermalState(value) }
    func appliedThermalState() -> Int32 { Claw3DSAppliedThermalState() }
    func availableMemoryBytes() -> UInt64 { Claw3DSAvailableMemoryBytes() }
    func memoryPressure() { if is3DS { Claw3DSMemoryPressure() } }
    func metalFXStatus() -> Int32 { is3DS ? Claw3DSMetalFXStatus() : 0 }
    func metalFXError() -> UnsafePointer<CChar> { is3DS ? Claw3DSMetalFXError() : ClawRetroError() }
}
