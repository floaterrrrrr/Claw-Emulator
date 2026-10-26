// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import GameController
import Metal
import QuartzCore
import SwiftUI
import UIKit

struct GameScreen: UIViewControllerRepresentable {
    let game: Game
    let resolution: Int
    let cpuClock: Int
    let asyncShaders: Bool
    let upscaleInput: Int
    var initialStateSlot: Int? = nil
    var onLoaded: ((UInt64) -> Void)? = nil
    var onPlaytime: ((TimeInterval) -> Void)? = nil
    var skipAutoResume = false
    let onExit: () -> Void
    func makeUIViewController(context: Context) -> GameController {
        GameController(game: game, resolution: resolution, cpuClock: cpuClock,
                       asyncShaders: asyncShaders, upscaleInput: upscaleInput, initialStateSlot: initialStateSlot,
                       onLoaded: onLoaded, onPlaytime: onPlaytime, skipAutoResume: skipAutoResume, onExit: onExit)
    }
    func updateUIViewController(_ controller: GameController, context: Context) {}
    static func dismantleUIViewController(_ controller: GameController, coordinator: ()) {
        controller.stopForRemoval()
    }
}

final class MetalScreen: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    let nativeSize: CGSize
    var touch: ((CGPoint, Bool) -> Void)?
    private weak var trackedTouch: UITouch?

    init(width: Int, scale: Int, height: Int = 240, framebufferOnly: Bool = false) {
        let presentationScale = Int(Claw3DSPresentationScale(Int32(scale)))
        nativeSize = CGSize(width: width * presentationScale, height: height * presentationScale)
        super.init(frame: .zero)
        backgroundColor = .black
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        // 3DS needs swapchain blits. Retro cores use the drawable only as a
        // render target, allowing Metal's framebuffer-only optimizations.
        metalLayer.framebufferOnly = framebufferOnly
        metalLayer.maximumDrawableCount = 2
        metalLayer.presentsWithTransaction = false
        metalLayer.isOpaque = true
        contentScaleFactor = max(traitCollection.displayScale, 1)
        metalLayer.contentsScale = contentScaleFactor
        metalLayer.magnificationFilter = .nearest
        // The compositor may downsample to the physical screen. Keep linear
        // minification to avoid aliasing, while preserving pixel edges on enlargement.
        metalLayer.minificationFilter = .linear
        metalLayer.drawableSize = nativeSize
        isMultipleTouchEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layoutSubviews() {
        super.layoutSubviews()
        // Preserve the selected render resolution; never shrink 4x to 3x here.
        metalLayer.drawableSize = nativeSize
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        contentScaleFactor = max(window?.screen.scale ?? traitCollection.displayScale, 1)
        metalLayer.contentsScale = contentScaleFactor
        metalLayer.drawableSize = nativeSize
    }
    func cancelTouch() { trackedTouch = nil }
    private func send(_ value: UITouch, down: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let point = value.location(in: self)
        let mapped = Claw3DSMapTouch(Float(point.x), Float(point.y), Float(bounds.width), Float(bounds.height),
                                 Int32(nativeSize.width), Int32(nativeSize.height))
        guard mapped.x >= 0, mapped.y >= 0 else { return }
        touch?(CGPoint(x: CGFloat(mapped.x), y: CGFloat(mapped.y)), down)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackedTouch == nil, let first = touches.first else { return }
        trackedTouch = first
        send(first, down: true)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let trackedTouch, touches.contains(trackedTouch) { send(trackedTouch, down: true) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let trackedTouch, touches.contains(trackedTouch) {
            send(trackedTouch, down: false)
            self.trackedTouch = nil
        }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touch?(.zero, false)
        trackedTouch = nil
    }
}

// Empty overlay space lets touches reach the lower display.
private final class ControlsCanvas: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        subviews.contains { !$0.isHidden && $0.alpha > 0.01 && $0.isUserInteractionEnabled &&
            $0.point(inside: convert(point, to: $0), with: event) }
    }
}

private final class GameMenuHost: UIHostingController<GameUtilitiesOverlay> {
    var orientationMask: UIInterfaceOrientationMask = .allButUpsideDown
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { orientationMask }
    override var prefersStatusBarHidden: Bool { true }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}

final class GameController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private let game: Game
    private let engine: GameEngine
    private let resolution: Int, cpuClock: Int
    private let asyncShaders: Bool
    private let upscaleInput: Int
    private let onExit: () -> Void
    private let initialStateSlot: Int?
    private let onLoaded: ((UInt64) -> Void)?
    private let onPlaytime: ((TimeInterval) -> Void)?
    private let skipAutoResume: Bool
    private var playtimeClock = PlaytimeClock()
    // All controllers share the queue so a replacement cannot load before teardown finishes.
    private static let coreWorker = DispatchQueue(label: "claw.core", qos: .userInitiated)
    private static var activeFrontend: UUID?
    private static var originalIdleSetting: Bool?
    private let frontendID = UUID()
    private let worker = GameController.coreWorker
    private let audioActivation = AudioActivation()
    private let top: MetalScreen, bottom: MetalScreen
    private let status = UILabel()
    private let gear = UIButton(type: .system)
    private let editControlsShortcut = UIButton(type: .system)
    private var returnToGameplayAfterControlEditing = false
    private let inputArea = ControlsCanvas()
    private lazy var skin: ControllerSkin? = {
        guard let skin = ControllerSkin.bundled,
              UIImage(named: skin.background) != nil,
              skin.controls.allSatisfy({ UIImage(named: $0.asset) != nil }) else { return nil }
        return skin
    }()
    private let skinArtwork = UIImageView()
    private var skinArtworkAvailable = false
    private var lastArtworkScale: CGFloat = 0
    private var importedSkins: [String: ImportedSkinSession] = [:]
    private var importedSkinsMode: Bool?
    private var importedSkinsRequestedMode: Bool?
    private var importedSkinsGeneration = 0
    private var importedSkinsLoading = false
    private struct DuplicateSkinControl: Equatable {
        let key: String
        let frame: CGRect
        let source: String
        let digital: Bool
        let asset: String?
        let ordinal: Int
    }
    private var duplicateControls: [UIView] = []
    private var lastDuplicateDescriptors: [DuplicateSkinControl] = []
    private var duplicatesVisible = false
    private var lastSkinLayout: ControllerSkinLayout?
    private var lastSkinOpacity = -1.0
    // Read preferences at launch/settings changes, never in the render loop.
    private var handheldConfiguration: HandheldControlsConfiguration?
    private var usingHandheldOverlay = false
    private var lastHandheldFrames: [HandheldControl: CGRect] = [:]
    private var comboButtons: [String: HeldButton] = [:]
    private var lastCombos: [HandheldCombo] = []
    private var controlsEditorHost: UIHostingController<HandheldControlsEditor>?
    private let quickSave = UIButton(type: .custom)
    private let quickLoad = UIButton(type: .custom)
    private let circle = CirclePad()
    private let dpad = DirectionPad()
    private let face = FaceButtons()
    private lazy var leftShoulder = button("L", .l)
    private lazy var rightShoulder = button("R", .r)
    private lazy var selectButton = button("Select", .select)
    private lazy var startButton = button("Start", .start)
    private let utilities = GameUtilitiesModel()
    private var menuHost: GameMenuHost?
    private var importedDigitalStick = false
    private var lastImportedDigitalStick = false
    private var resumeAfterMenu = false
    private var saveAndLeave = false
    private static let sharedStateStore = SaveStateStore(directory: DiskStore.coreDirectory.appendingPathComponent("save_states"))
    private let stateStore = GameController.sharedStateStore
    private var titleID: UInt64 = 0
    private var pendingSlot = 1
    private var pendingName = ""
    private var stateRequestPending = false
    private var continueAfterRestore = false
    private var checkingPreviousSession = true
    private var previousSession: SaveEntry?
    private static var autosaveInterval: Double {
#if CLAW_FRONTEND_FIXTURE
        return ProcessInfo.processInfo.arguments.contains("--test-autosave") ? 2 :
            Double(min(10, max(1, UserDefaults.standard.object(forKey: "autosaveMinutes") as? Int ?? 5))) * 60
#else
        return Double(min(10, max(1, UserDefaults.standard.object(forKey: "autosaveMinutes") as? Int ?? 5))) * 60
#endif
    }
    private var nextAutosave = ProcessInfo.processInfo.systemUptime + GameController.autosaveInterval
    private var schedulingAutosave = false
    private var nextMemoryHeadroomCheck: TimeInterval = 0
    private var requestedOrientation = GameplayOrientation.automatic
    private var lastLayoutSize = CGSize.zero
    private var observers: [NSObjectProtocol] = []
    private var controllers: [GCController] = []
    private var timer: Timer?
    private var held = HeldInputUnion<PadKey>()
    private var analogInputs: [String: (x: Float, y: Float)] = [:]
    private var analogOrder: [String] = []
    private var inputLocked: Bool { utilities.busy && pendingSlot < 9 }
    private var started = false, loaded = false, paused = false, stopping = false
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        switch utilities.orientation {
        case .automatic: return .allButUpsideDown
        case .landscape: return .landscape
        case .portrait: return .portrait
        }
    }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        switch utilities.orientation {
        case .landscape: return .landscapeRight
        case .portrait: return .portrait
        case .automatic: return view.window?.windowScene?.interfaceOrientation ?? .portrait
        }
    }
    override var prefersHomeIndicatorAutoHidden: Bool { false }
    override var prefersStatusBarHidden: Bool { true }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    init(game: Game, resolution: Int, cpuClock: Int, asyncShaders: Bool,
         upscaleInput: Int, initialStateSlot: Int? = nil, onLoaded: ((UInt64) -> Void)? = nil,
         onPlaytime: ((TimeInterval) -> Void)? = nil, skipAutoResume: Bool = false, onExit: @escaping () -> Void) {
        self.game = game
        self.engine = GameEngine(game: game)
        handheldConfiguration = game.platform.hasHandheldOverlay ? .load(system: game.platform) : nil
        let scale = game.platform == .threeDS ? Int(Claw3DSResolutionScale(Int32(resolution))) : 1
        self.resolution = scale
        self.cpuClock = min(max(cpuClock, 50), 100)
        self.asyncShaders = asyncShaders
        let selectedUpscale = game.platform == .threeDS && [2, 3].contains(upscaleInput) ? 2 : 0
        self.upscaleInput = selectedUpscale
        self.onExit = onExit
        self.initialStateSlot = initialStateSlot
        self.onLoaded = onLoaded
        self.onPlaytime = onPlaytime
        self.skipAutoResume = skipAutoResume
        let outputScale = selectedUpscale == 0 ? scale : 4
        top = MetalScreen(width: game.platform.nativeWidth, scale: outputScale, height: game.platform.nativeHeight,
                          framebufferOnly: game.platform != .threeDS)
        bottom = MetalScreen(width: game.platform == .threeDS ? 320 : 256, scale: outputScale,
                             height: game.platform == .threeDS ? 240 : 192, framebufferOnly: game.platform != .threeDS)
        super.init(nibName: nil, bundle: nil)
        utilities.gameName = game.name
        utilities.system = game.platform
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true
        status.text = "Loading game…"
        status.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        status.textColor = .secondaryLabel
        status.numberOfLines = 1
        status.adjustsFontSizeToFitWidth = true
        status.minimumScaleFactor = 0.75
        status.isUserInteractionEnabled = true
        status.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(clawGraphicsStatus)))
        status.accessibilityIdentifier = "gameStatus"
        top.accessibilityIdentifier = "topScreen"
        bottom.accessibilityIdentifier = "bottomScreen"
        skinArtwork.backgroundColor = .clear
        skinArtwork.isUserInteractionEnabled = false
        skinArtwork.isAccessibilityElement = false
        skinArtwork.contentMode = .scaleToFill
        view.addSubview(skinArtwork)
        for screen in [top, bottom] {
            screen.isAccessibilityElement = true
            screen.accessibilityLabel = screen === top ? "Main display" : "Touch display"
            view.addSubview(screen)
        }
        view.addSubview(inputArea)
        inputArea.isUserInteractionEnabled = false
        buildControls()
        view.addSubview(status)
        gear.setImage(UIImage(systemName: "gearshape", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18)), for: .normal)
        gear.tintColor = .white
        gear.accessibilityLabel = "Game menu"
        gear.accessibilityIdentifier = "gameMenu"
        gear.addTarget(self, action: #selector(openMenu), for: .touchUpInside)
        gear.isEnabled = false
        view.addSubview(gear)
        var editStyle = UIButton.Configuration.plain()
        editStyle.image = UIImage(systemName: "hand.draw", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18))
        editStyle.baseForegroundColor = .white
        editStyle.background.backgroundColor = .black.withAlphaComponent(0.35)
        editStyle.cornerStyle = .capsule
        editControlsShortcut.configuration = editStyle
        editControlsShortcut.accessibilityLabel = "Edit control layout"
        editControlsShortcut.accessibilityHint = "Pauses the game to move and resize controls"
        editControlsShortcut.accessibilityIdentifier = "quickEditControls"
        editControlsShortcut.isHidden = true
        editControlsShortcut.addTarget(self, action: #selector(openControlEditor), for: .touchUpInside)
        view.addSubview(editControlsShortcut)
        bottom.touch = { [weak self] point, down in
            guard self?.loaded == true, self?.paused == false, self?.inputLocked == false else { return }
            self?.engine.touch(Float(point.x), Float(point.y), down)
        }
        observe(UIApplication.willResignActiveNotification) { [weak self] in self?.interruptPlayback() }
        observe(UIApplication.didEnterBackgroundNotification) { [weak self] in self?.engine.requestPipelineCacheSave() }
        observe(UIApplication.didBecomeActiveNotification) { [weak self] in self?.presentPreviousSession() }
        observe(UIApplication.willTerminateNotification) { [weak self] in self?.finish() }
        observe(UIApplication.didReceiveMemoryWarningNotification) { [weak self] in self?.engine.memoryPressure() }
        observe(AVAudioSession.interruptionNotification) { [weak self] in self?.interruptPlayback() }
        observe(AVAudioSession.routeChangeNotification) { [weak self] in self?.interruptPlayback() }
        observe(ProcessInfo.thermalStateDidChangeNotification) { [weak self] in self?.updateThermalState() }
        observe(.GCControllerDidConnect) { [weak self] in self?.connectControllers() }
        observe(.GCControllerDidDisconnect) { [weak self] in
            self?.releaseInputs()
            self?.connectControllers()
        }
        if game.platform.hasHandheldOverlay {
            observe(.handheldControlsChanged) { [weak self] in
                guard let self else { return }
                self.releaseInputs()
                self.handheldConfiguration = .load(system: self.game.platform)
                self.view.setNeedsLayout()
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started, !stopping else { return }
        started = true
        if Self.originalIdleSetting == nil {
            Self.originalIdleSetting = UIApplication.shared.isIdleTimerDisabled
        }
        Self.activeFrontend = frontendID
        UIApplication.shared.isIdleTimerDisabled = true
        applyMenuLayout()
        view.layoutIfNeeded()
        guard top.metalLayer.device != nil, bottom.metalLayer.device != nil,
              top.bounds.width > 0, (!game.platform.dualScreen || bottom.bounds.width > 0) else {
            showError("Metal graphics are unavailable on this device.")
            return
        }
        engine.setVolume(Float(utilities.volume))
        // The controller owns both layers until the serial stop operation has joined the core thread.
        let topPointer = Unmanaged.passUnretained(top.metalLayer).toOpaque()
        let bottomPointer = Unmanaged.passUnretained(bottom.metalLayer).toOpaque()
        let lowLatencyAudio = game.platform.core == 1
        worker.async { [self] in
            do {
                try Self.configureAudioSession(lowLatency: lowLatencyAudio)
            } catch {
                let message = "Audio could not start: \(error.localizedDescription)"
                DispatchQueue.main.async { [self] in
                    guard !stopping else { return }
                    showError(message)
                }
                return
            }
            let result = game.url.path.withCString { rom in
                DiskStore.coreDirectory.path.withCString { data in
                    engine.load(rom, data, topPointer, bottomPointer, Int32(resolution), Int32(cpuClock),
                             asyncShaders, Int32(upscaleInput))
                }
            }
            let error = result == 0 ? nil : String(cString: engine.lastError())
            DispatchQueue.main.async { [self] in
                guard !stopping else { return }
                if let error { showError(error); return }
                loaded = true
                updateThermalState()
                paused = true
                titleID = engine.currentTitle()
                utilities.titleID = titleID
                onLoaded?(titleID)
                connectControllers()
                if let slot = initialStateSlot {
                    finishSessionCheck()
                    continueAfterRestore = requestState(restore: true, slot: slot)
                    if !continueAfterRestore { continueNormalBootAfterRestoreFailure() }
                } else if skipAutoResume {
                    finishSessionCheck()
                    setPaused(false)
                } else { checkPreviousSession() }
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sample() }
                }
            }
        }
    }

    private nonisolated static func configureAudioSession(lowLatency: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setPreferredSampleRate(48_000)
        // mGBA requests 5.3 ms callbacks; its native sink adapts to the actual
        // hardware slice and underruns. A preferred duration is only a hint.
        // The verified 3DS callback preference remains 1024 / 48000 seconds.
        try session.setPreferredIOBufferDuration((lowLatency ? 256.0 : 1024.0) / 48_000.0)
        try session.setActive(true)
    }

    private func observe(_ name: Notification.Name, action: @escaping @MainActor @Sendable () -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        })
    }

    private func buildControls() {
        for control in [circle, dpad, face, leftShoulder, rightShoulder, selectButton, startButton,
                        quickSave, quickLoad] {
            inputArea.addSubview(control)
        }
        quickSave.accessibilityLabel = "Save state"
        quickSave.accessibilityIdentifier = "skinQuickSave"
        quickSave.addTarget(self, action: #selector(skinSave), for: .touchUpInside)
        quickLoad.accessibilityLabel = "Load state"
        quickLoad.accessibilityIdentifier = "skinQuickLoad"
        quickLoad.addTarget(self, action: #selector(skinLoad), for: .touchUpInside)
        circle.moved = { [weak self] x, y in
            guard let self else { return }
            self.updateCircle(source: "circle", digital: self.usingHandheldOverlay || self.importedDigitalStick, x: x, y: y)
        }
        dpad.changed = { [weak self] keys in
            self?.updateDirections(keys, source: "dpad")
        }
        for (key, control) in face.buttons {
            let source = "face-\(key.rawValue)"
            control.changed = { [weak self] pressed in self?.send(key, pressed: pressed, source: source) }
        }
    }
    private func button(_ title: String, _ code: PadKey) -> HeldButton {
        let result = HeldButton(title)
        result.shoulderHaptic = code == .l || code == .r
        let source = "button-\(code.rawValue)"
        result.changed = { [weak self] pressed in self?.send(code, pressed: pressed, source: source) }
        return result
    }
    private func updateDirections(_ keys: Set<PadKey>, source: String) {
        for key in [PadKey.up, .down, .left, .right] {
            send(key, pressed: keys.contains(key), source: source)
        }
    }
    private func updateCircle(source: String, digital: Bool, x: Float, y: Float) {
        guard loaded, !paused, !stopping, !inputLocked else { return }
        guard digital else {
            updateAnalog(source: source, x: x, y: y)
            return
        }
        var keys = Set<PadKey>()
        if x < -0.35 { keys.insert(.left) }
        if x > 0.35 { keys.insert(.right) }
        if y > 0.35 { keys.insert(.up) }
        if y < -0.35 { keys.insert(.down) }
        updateDirections(keys, source: source)
    }
    private func updateAnalog(source: String, x: Float, y: Float) {
        guard loaded, !paused, !stopping, !inputLocked else { return }
        analogOrder.removeAll { $0 == source }
        if abs(x) < 0.0001 && abs(y) < 0.0001 {
            analogInputs.removeValue(forKey: source)
        } else {
            analogInputs[source] = (x, y)
            analogOrder.append(source)
        }
        let value = analogOrder.last.flatMap { analogInputs[$0] } ?? (0, 0)
        engine.analog(value.0, value.1)
    }
    private func clearAnalogInputs() {
        analogInputs.removeAll()
        analogOrder.removeAll()
        engine.analog(0, 0)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        defer {
            if let host = controlsEditorHost {
                inputArea.isHidden = true; gear.isHidden = true; status.isHidden = true
                view.bringSubviewToFront(host.view)
            }
        }
        if lastLayoutSize != view.bounds.size {
            releaseInputs()
            lastLayoutSize = view.bounds.size
        }
        var safe = view.bounds.inset(by: view.safeAreaInsets)
        // The SwiftUI cover ignores safe areas; retain the physical window's
        // notch and home-indicator insets even if the child reports zero.
        if let window = view.window {
            let physical = view.convert(window.bounds.inset(by: window.safeAreaInsets), from: window)
            safe = safe.intersection(physical)
        }
        guard !safe.isNull, safe.width > 0, safe.height > 0 else { return }
        defer { layoutControlShortcut(safe: safe) }
        if let configuration = handheldConfiguration, configuration.enabled {
            layoutHandheldControls(configuration, safe: safe)
            return
        }
        if usingHandheldOverlay {
            releaseInputs()
            usingHandheldOverlay = false
            dpad.isHidden = false
            for button in comboButtons.values { button.removeFromSuperview() }
            comboButtons.removeAll(); lastCombos = []
            circle.useFloatingStyle(false)
            inputArea.layer.allowsGroupOpacity = true
            lastHandheldFrames = [:]
            skinArtwork.isHidden = false
            gear.alpha = 1
            status.textColor = .secondaryLabel
            status.backgroundColor = .clear
            dpad.layer.borderWidth = 0
            lastSkinLayout = nil
            lastSkinOpacity = -1
        }
        let shortSide = min(view.bounds.width, view.bounds.height)
        let edgeToEdge = shortSide > 0 &&
            max(view.bounds.width, view.bounds.height) / shortSide > 2
        ensureImportedSkins(edgeToEdge: edgeToEdge)
        let orientation = safe.width > safe.height ? "landscape" : "portrait"
        let candidate = utilities.skinEnabled ? importedSkins[orientation] : nil
        let customLayout = candidate?.variant.layout(in: safe, bounds: view.bounds,
                                                   mainAspect: CGFloat(game.platform.aspect),
                                                   hasSecondScreen: game.platform.dualScreen,
                                                   edgeToEdge: candidate?.edgeToEdge ?? false)
        let imported = customLayout == nil ? nil : candidate
        let themed = customLayout ?? (utilities.skinEnabled ? skin.flatMap {
            ControllerSkinLayout.make(skin: $0, in: safe, bounds: view.bounds,
                                      mainAspect: CGFloat(game.platform.aspect), hasSecondScreen: game.platform.dualScreen,
                                      largerTouchScreen: utilities.largerTouchScreen, hasAnalog: game.platform == .threeDS)
        } : nil)
        let layout = themed?.gameplay ?? GameplayLayout.make(in: safe, largerTouchScreen: utilities.largerTouchScreen,
            mainAspect: CGFloat(game.platform.aspect), hasSecondScreen: game.platform.dualScreen)
        skinArtwork.frame = view.bounds
        let displayScale = view.window?.screen.scale ?? traitCollection.displayScale
        if themed != lastSkinLayout || utilities.opacity != lastSkinOpacity || displayScale != lastArtworkScale {
            lastSkinLayout = themed; lastSkinOpacity = utilities.opacity
            lastArtworkScale = displayScale
            // Release the old bitmap before allocating another orientation's
            // snapshot. No retained SwiftUI host or per-emulated-frame rendering.
            skinArtwork.image = nil
            skinArtwork.image = SkinArtworkSnapshot.image(skin: skin, layout: themed,
                opacity: utilities.opacity, system: game.platform, imported: imported,
                size: view.bounds.size, displayScale: displayScale)
            skinArtworkAvailable = skinArtwork.image != nil
            let usesSkin = themed != nil && skinArtworkAvailable
            circle.useSkin(usesSkin); dpad.useSkin(usesSkin)
            [leftShoulder, rightShoulder, selectButton, startButton].forEach { $0.useSkin(usesSkin) }
            face.buttons.values.forEach { $0.useSkin(usesSkin); $0.circularSkinTarget = usesSkin && imported == nil }
            let faceKeys: [String: PadKey] = ["a": .a, "b": .b, "x": .x, "y": .y]
            let importedMenu = imported?.variant.controls.contains(where: { $0.key == "menu" }) ?? false
            configureFooter(usesSkin, imported: usesSkin && imported != nil, importedMenu: importedMenu)
            face.skinFrames = (usesSkin ? themed : nil).map { theme in
                Dictionary(uniqueKeysWithValues: faceKeys.compactMap { key, code in
                    theme.hitFrames[key].map { (code, $0.offsetBy(dx: -layout.face.minX, dy: -layout.face.minY)) }
                })
            }
        }
        let usesSkin = themed != nil && skinArtworkAvailable
        updateDuplicateControls(session: usesSkin ? imported : nil, layout: themed, usesSkin: usesSkin)
        quickSave.isHidden = !usesSkin || themed?.quickSave.isEmpty == true
        quickLoad.isHidden = !usesSkin || themed?.quickLoad.isEmpty == true
        circle.setImportedArtwork((usesSkin ? imported : nil).flatMap { session in
            session.variant.controls.first(where: { $0.key == "circle" })?.asset.flatMap { session.images[$0] }
        })
        importedDigitalStick = imported?.variant.controls.first(where: { $0.key == "circle" })?.digitalDirections == true
        if importedDigitalStick != lastImportedDigitalStick {
            releaseInputs()
            lastImportedDigitalStick = importedDigitalStick
        }
        circle.accessibilityLabel = importedDigitalStick ? "Directional thumbstick" : "Circle pad"
        circle.isHidden = (game.platform != .threeDS && !importedDigitalStick) || layout.circle.isEmpty
        quickSave.frame = themed?.quickSave ?? .zero; quickLoad.frame = themed?.quickLoad ?? .zero
        inputArea.frame = view.bounds
        top.frame = layout.top; bottom.frame = layout.bottom
        bottom.isHidden = !game.platform.dualScreen
        face.buttons[.x]?.isHidden = !game.platform.dualScreen
        face.buttons[.y]?.isHidden = !game.platform.dualScreen
        leftShoulder.isHidden = !game.platform.showsControl("l")
        rightShoulder.isHidden = !game.platform.showsControl("r")
        circle.frame = layout.circle; dpad.frame = layout.dpad; face.frame = layout.face
        leftShoulder.frame = layout.leftShoulder; rightShoulder.frame = layout.rightShoulder
        selectButton.frame = layout.select; startButton.frame = layout.start
        status.frame = layout.hud; gear.frame = layout.gear
        inputArea.alpha = CGFloat(utilities.opacity)
        status.isHidden = !utilities.showStats && !paused && loaded && !stopping
    }
    private func layoutHandheldControls(_ configuration: HandheldControlsConfiguration, safe: CGRect) {
        if !usingHandheldOverlay {
            releaseInputs()
            usingHandheldOverlay = true
            // Apply opacity to the simple control layers directly, rather than
            // requesting an offscreen composite of the full-screen container.
            inputArea.layer.allowsGroupOpacity = false
            // Cancel pending skin work and release its bitmaps while floating
            // controls are active. Changing the view frame doesn't increase the
            // Metal drawable size, core resolution, or audio work.
            importedSkinsGeneration += 1
            importedSkins.removeAll()
            importedSkinsMode = nil; importedSkinsRequestedMode = nil
            importedSkinsLoading = false
            updateDuplicateControls(session: nil, layout: nil, usesSkin: false)
            skinArtwork.image = nil; skinArtwork.isHidden = true
            skinArtworkAvailable = false
            circle.useSkin(false); circle.setImportedArtwork(nil)
            dpad.useSkin(false)
            dpad.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            dpad.layer.borderColor = UIColor.white.withAlphaComponent(0.65).cgColor
            dpad.layer.borderWidth = 1
            for button in [leftShoulder, rightShoulder, selectButton, startButton] + Array(face.buttons.values) {
                button.useSkin(false)
                button.circularSkinTarget = false
                var style = button.configuration
                style?.baseBackgroundColor = .black.withAlphaComponent(0.55)
                style?.background.strokeColor = .white.withAlphaComponent(0.65)
                style?.background.strokeWidth = 1
                style?.titleLineBreakMode = .byClipping
                button.configuration = style
                button.titleLabel?.numberOfLines = 1
                button.titleLabel?.adjustsFontSizeToFitWidth = true
                button.titleLabel?.minimumScaleFactor = 0.5
            }
            configureFooter(false)
            status.textColor = .white
            status.backgroundColor = .black.withAlphaComponent(0.4)
        }
        let layout = safe.width > safe.height ? configuration.landscape : configuration.portrait
        let frames = layout.frames(in: view.bounds, system: game.platform, safeArea: safe)
        if configuration.combos != lastCombos {
            releaseInputs()
            for button in comboButtons.values { button.removeFromSuperview() }
            comboButtons.removeAll()
            lastCombos = configuration.combos
            for combo in configuration.combos {
                let button = HeldButton(combo.name)
                button.accessibilityIdentifier = combo.key
                button.titleLabel?.adjustsFontSizeToFitWidth = true
                button.titleLabel?.minimumScaleFactor = 0.5
                button.titleLabel?.numberOfLines = 1
                var style = button.configuration
                style?.baseBackgroundColor = .black.withAlphaComponent(0.55)
                style?.background.strokeColor = .white.withAlphaComponent(0.65)
                style?.background.strokeWidth = 1
                style?.titleLineBreakMode = .byClipping
                button.configuration = style
                if let speed = combo.speed, game.platform == .gba {
                    var speedStyle = button.configuration
                    speedStyle?.title = nil; speedStyle?.image = FastForwardGlyph.image(speed: speed)
                    button.configuration = speedStyle
                    button.accessibilityLabel = "Fast forward \(speed)×"
                    button.addAction(UIAction { [weak self] _ in
                        guard let self else { return }
                        self.setSpeed(self.utilities.speed == speed ? 1 : speed)
                    }, for: .touchUpInside)
                } else {
                    let inputs = combo.keys
                    button.changed = { [weak self] pressed in
                        for key in inputs { self?.send(key, pressed: pressed, source: combo.key) }
                    }
                }
                inputArea.addSubview(button); comboButtons[combo.key] = button
            }
            updateSpeedButtons()
        }
        let allFrames = layout.allFrames(in: view.bounds, system: game.platform, combos: configuration.combos, safeArea: safe)
        for (key, button) in comboButtons { button.frame = allFrames[key] ?? .zero }
        if frames != lastHandheldFrames {
            releaseInputs()
            lastHandheldFrames = frames
        }
        inputArea.frame = view.bounds
        // The game owns the entire display. Aspect-fit is the default; borders
        // are not reserved for controls. Both orientations preserve the whole picture.
        top.frame = HandheldViewport.frame(in: view.bounds, aspect: game.platform.aspect)
        bottom.isHidden = true; bottom.frame = .zero
        circle.isHidden = configuration.movement != .joystick
        dpad.isHidden = configuration.movement == .joystick
        circle.useFloatingStyle(true)
        circle.frame = frames[.dpad] ?? .zero
        quickSave.isHidden = true; quickLoad.isHidden = true
        face.buttons[.x]?.isHidden = true; face.buttons[.y]?.isHidden = true
        leftShoulder.isHidden = game.platform != .gba
        rightShoulder.isHidden = game.platform != .gba
        dpad.frame = frames[.dpad] ?? .zero
        leftShoulder.frame = frames[.l] ?? .zero; rightShoulder.frame = frames[.r] ?? .zero
        selectButton.frame = frames[.select] ?? .zero; startButton.frame = frames[.start] ?? .zero
        let a = frames[.a] ?? .zero, b = frames[.b] ?? .zero, faceBounds = a.union(b)
        face.frame = faceBounds
        face.skinFrames = [.a: a.offsetBy(dx: -faceBounds.minX, dy: -faceBounds.minY),
                           .b: b.offsetBy(dx: -faceBounds.minX, dy: -faceBounds.minY)]
        gear.frame = frames[.menu] ?? .zero
        gear.alpha = max(0.65, configuration.opacity)
        inputArea.alpha = CGFloat(configuration.opacity)
        status.frame = CGRect(x: safe.minX + 8, y: safe.minY + 4,
                              width: min(220, max(44, safe.width - 64)), height: 32)
        status.isHidden = !utilities.showStats && !paused && loaded && !stopping
    }
    private func ensureImportedSkins(edgeToEdge: Bool) {
        guard utilities.skinEnabled else { return }
        guard importedSkinsMode != edgeToEdge else { return }
        guard !importedSkinsLoading || importedSkinsRequestedMode != edgeToEdge else { return }
        importedSkinsGeneration += 1
        let generation = importedSkinsGeneration
        importedSkinsLoading = true
        importedSkinsRequestedMode = edgeToEdge
        // Sessions are variant-specific. Drop the previous mode rather than
        // painting the wrong canvas while the new bounds are loaded.
        importedSkins.removeAll()
        lastSkinLayout = nil
        lastDuplicateDescriptors = []
        duplicatesVisible = false
        Task { [weak self] in
            await self?.prepareImportedSkins(edgeToEdge: edgeToEdge, generation: generation)
        }
    }
    private func prepareImportedSkins(edgeToEdge: Bool, generation: Int) async {
        let available = (try? await ImportedSkinStore.shared.list()) ?? []
        var loaded: [String: ImportedSkinSession] = [:]
        for orientation in ["portrait", "landscape"] {
            guard generation == importedSkinsGeneration, !stopping else { return }
            let selected = ImportedSkin.selected(system: game.platform, orientation: orientation, game: game.id, available: available)
            guard selected != "obsidian" else { continue }
            do {
                guard let session = try await ImportedSkinSession.load(id: selected, orientation: orientation, edgeToEdge: edgeToEdge) else {
                    continue
                }
                guard generation == importedSkinsGeneration, !stopping else { return }
                loaded[orientation] = session
            } catch {
                guard generation == importedSkinsGeneration, !stopping else { return }
                utilities.message = "Skin unavailable; using Obsidian. " + error.localizedDescription
            }
        }
        guard generation == importedSkinsGeneration, !stopping else { return }
        importedSkins = loaded
        importedSkinsMode = edgeToEdge
        importedSkinsRequestedMode = nil
        importedSkinsLoading = false
        lastSkinLayout = nil
        lastDuplicateDescriptors = []
        duplicatesVisible = false
        view.setNeedsLayout()
    }
    private func updateDuplicateControls(session: ImportedSkinSession?, layout: ControllerSkinLayout?, usesSkin: Bool) {
        let descriptors = duplicateDescriptors(session: session, layout: layout, usesSkin: usesSkin)
        guard descriptors != lastDuplicateDescriptors || duplicatesVisible != usesSkin else { return }
        lastDuplicateDescriptors = descriptors
        duplicatesVisible = usesSkin
        if !duplicateControls.isEmpty {
            // Removing a latched touch view must first release every unioned
            // source so a held button cannot remain pressed in the core.
            releaseInputs()
            for control in duplicateControls { control.removeFromSuperview() }
            duplicateControls.removeAll()
        }
        guard usesSkin, let session else { return }
        for descriptor in descriptors {
            addDuplicateControl(descriptor, session: session)
        }
    }
    private func duplicateDescriptors(session: ImportedSkinSession?, layout: ControllerSkinLayout?,
                                      usesSkin: Bool) -> [DuplicateSkinControl] {
        guard usesSkin, let session, let layout,
              session.variant.controls.count == layout.importedFrames.count else { return [] }
        var seen = Set<String>()
        var counts: [String: Int] = [:]
        var result: [DuplicateSkinControl] = []
        for (index, control) in session.variant.controls.enumerated() {
            // The first authored region is already owned by the primary UIKit
            // control. Every later region gets its own hit view and input source.
            guard !seen.insert(control.key).inserted else { continue }
            let frame = layout.importedFrames[index]
            guard frame.width > 0, frame.height > 0 else { continue }
            if let pad = padKey(for: control.key) {
                if (pad == .x || pad == .y) && !game.platform.dualScreen { continue }
                if (pad == .l || pad == .r) && !game.platform.showsControl(control.key) { continue }
            } else if control.key == "dpad" || control.key == "circle" {
                // Both movement controls can be duplicated freely.
            } else if control.key == "menu" {
                guard layout.hitFrames["menu"] != nil else { continue }
            } else if control.key == "save" {
                guard !layout.quickSave.isEmpty else { continue }
            } else if control.key == "load" {
                guard !layout.quickLoad.isEmpty else { continue }
            } else {
                continue
            }
            let ordinal = (counts[control.key] ?? 0) + 1
            counts[control.key] = ordinal
            result.append(DuplicateSkinControl(key: control.key, frame: frame,
                                               source: "duplicate-\(control.key)-\(ordinal)",
                                               digital: control.digitalDirections == true,
                                               asset: control.asset, ordinal: ordinal))
        }
        return result
    }
    private func addDuplicateControl(_ descriptor: DuplicateSkinControl, session: ImportedSkinSession) {
        if let key = padKey(for: descriptor.key) {
            let control = HeldButton(label(for: key))
            control.frame = descriptor.frame
            control.useSkin(true)
            control.shoulderHaptic = key == .l || key == .r
            control.accessibilityIdentifier = "pad\(label(for: key))Extra\(descriptor.ordinal)"
            control.isHidden = !game.platform.showsControl(descriptor.key)
            let source = descriptor.source
            control.changed = { [weak self] pressed in
                self?.send(key, pressed: pressed, source: source)
            }
            installDuplicate(control)
            return
        }
        switch descriptor.key {
        case "dpad":
            let pad = DirectionPad()
            pad.frame = descriptor.frame
            pad.useSkin(true)
            pad.accessibilityIdentifier = "directionPadExtra\(descriptor.ordinal)"
            let source = descriptor.source
            pad.changed = { [weak self] keys in self?.updateDirections(keys, source: source) }
            installDuplicate(pad)
        case "circle":
            let pad = CirclePad()
            pad.frame = descriptor.frame
            pad.useSkin(true)
            pad.accessibilityIdentifier = "circlePadExtra\(descriptor.ordinal)"
            pad.accessibilityLabel = descriptor.digital ? "Directional thumbstick" : "Circle pad"
            pad.setImportedArtwork(descriptor.asset.flatMap { session.images[$0] })
            pad.isHidden = (!descriptor.digital && game.platform != .threeDS) || descriptor.frame.isEmpty
            let source = descriptor.source
            pad.moved = { [weak self] x, y in
                self?.updateCircle(source: source, digital: descriptor.digital, x: x, y: y)
            }
            installDuplicate(pad)
        case "menu":
            addDuplicateAction(descriptor.frame, action: #selector(openMenu), label: "Game menu",
                               identifier: "gameMenuExtra\(descriptor.ordinal)")
        case "save":
            addDuplicateAction(descriptor.frame, action: #selector(skinSave), label: "Save state",
                               identifier: "skinQuickSaveExtra\(descriptor.ordinal)")
        case "load":
            addDuplicateAction(descriptor.frame, action: #selector(skinLoad), label: "Load state",
                               identifier: "skinQuickLoadExtra\(descriptor.ordinal)")
        default:
            break
        }
    }
    private func installDuplicate(_ control: UIView) {
        inputArea.addSubview(control)
        duplicateControls.append(control)
    }
    private func addDuplicateAction(_ frame: CGRect, action: Selector, label: String, identifier: String) {
        let button = UIButton(type: .custom)
        button.frame = frame
        button.backgroundColor = .clear
        button.isAccessibilityElement = true
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)
        installDuplicate(button)
    }
    private func padKey(for key: String) -> PadKey? {
        switch key {
        case "a": return .a
        case "b": return .b
        case "x": return .x
        case "y": return .y
        case "l": return .l
        case "r": return .r
        case "start": return .start
        case "select": return .select
        default: return nil
        }
    }
    private func label(for key: PadKey) -> String {
        switch key {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .l: return "L"
        case .r: return "R"
        case .start: return "Start"
        case .select: return "Select"
        default: return ""
        }
    }
    private func configureFooter(_ themed: Bool, imported: Bool = false, importedMenu: Bool = false) {
        for (button, label, icon) in [(quickSave, "Save", "square.and.arrow.down"),
                                      (gear, "Menu", "gearshape"),
                                      (quickLoad, "Load", "arrow.counterclockwise")] {
            var config = UIButton.Configuration.plain()
            config.image = UIImage(systemName: icon)
            config.title = themed && button !== gear && view.bounds.width <= view.bounds.height ? label : nil
            config.imagePadding = 6
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
            config.titleLineBreakMode = .byClipping
            config.baseForegroundColor = .white
            if themed {
                config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14)
                config.background.backgroundColor = UIColor(white: 0.08, alpha: 1)
                config.background.strokeColor = UIColor(white: 0.4, alpha: 1)
                config.background.strokeWidth = 0.7
                config.background.cornerRadius = view.bounds.width > view.bounds.height || button === gear ? 22 : 10
                config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { value in
                    var value = value; value.font = UIFont.systemFont(ofSize: 12, weight: .medium); return value
                }
            }
            // Imported artwork normally supplies Save/Load/Menu visuals. If the
            // author did not map a menu, keep Claw's built-in gear visible so
            // the game can still be paused and exited.
            if imported && (button !== gear || importedMenu) {
                config.image = nil; config.title = nil
                config.background.backgroundColor = .clear
                config.background.strokeWidth = 0
            }
            button.configuration = config
            button.titleLabel?.numberOfLines = 1
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.85
        }
    }
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange(); view.setNeedsLayout()
    }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        releaseInputs()
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in self?.view.setNeedsLayout() })
    }
    private func applyMenuLayout() {
        GameOrientationPolicy.mask = supportedInterfaceOrientations
        let defaults = UserDefaults.standard
        defaults.set(utilities.orientation.rawValue, forKey: "gameOrientation")
        defaults.set(utilities.opacity, forKey: "controlOpacity")
        defaults.set(utilities.showStats, forKey: "showGameStats")
        defaults.set(utilities.largerTouchScreen, forKey: "largerTouchScreen")
        defaults.set(utilities.skinEnabled, forKey: "controllerSkin")
        let wasAutosaving = defaults.object(forKey: "autosaveEnabled") as? Bool ?? true
        defaults.set(utilities.autosaveEnabled, forKey: "autosaveEnabled")
        let minutes = min(10, max(1, utilities.autosaveMinutes))
        if defaults.integer(forKey: "autosaveMinutes") != minutes || (!wasAutosaving && utilities.autosaveEnabled) {
            defaults.set(minutes, forKey: "autosaveMinutes")
            nextAutosave = ProcessInfo.processInfo.systemUptime + Double(minutes) * 60
        }
        releaseInputs()
        view.setNeedsLayout()
        menuHost?.orientationMask = supportedInterfaceOrientations
        menuHost?.setNeedsUpdateOfSupportedInterfaceOrientations()
        setNeedsUpdateOfSupportedInterfaceOrientations()
        guard requestedOrientation != utilities.orientation else { return }
        requestedOrientation = utilities.orientation
        if utilities.orientation != .automatic {
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: supportedInterfaceOrientations)) { [weak self] error in
                self?.utilities.message = "Rotation: \(error.localizedDescription)"
            }
        }
    }
    private func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        utilities.volume = min(1, max(0, value))
        UserDefaults.standard.set(utilities.volume, forKey: "gameVolume")
        engine.setVolume(Float(utilities.volume))
    }
    private func interruptPlayback() {
        resumeAfterMenu = false
        setPaused(true)
    }
    @objc private func openMenu() {
        presentMenu()
    }
    @objc private func skinSave() { presentMenu { [weak self] in self?.confirmSave() } }
    @objc private func skinLoad() { presentMenu { [weak self] in self?.confirmRestore() } }
    private func presentMenu(afterPresentation: (() -> Void)? = nil) {
        guard loaded, !stopping, !checkingPreviousSession, !utilities.busy,
              presentedViewController == nil else { return }
        resumeAfterMenu = !paused
        let selectedSpeed = utilities.speed
        setPaused(true)
        // Pausing clears held input but preserves the user's selected speed.
        setSpeed(selectedSpeed)
        let host = GameMenuHost(rootView: GameUtilitiesOverlay(model: utilities,
            onResume: { [weak self] in self?.closeMenu(resume: true) },
            onSpeed: { [weak self] in self?.setSpeed($0) },
            onSave: { [weak self] in self?.confirmSave() },
            onRestore: { [weak self] in self?.confirmRestore() },
            onSaveAndLeave: { [weak self] in
                guard let self else { return }
                self.confirmSave(leave: true)
            },
            onLoadSlot: { [weak self] in self?.confirmRestore(slot: $0.slot) },
            onDeleteSlot: { [weak self] in self?.confirmDelete($0) },
            onStop: { [weak self] in self?.clawConfirmExit() },
            onVolume: { [weak self] in self?.setVolume($0) },
            onLayout: { [weak self] in self?.applyMenuLayout() },
            onEditControls: { [weak self] in self?.editLiveControls() }))
        host.orientationMask = supportedInterfaceOrientations
        host.modalPresentationStyle = .overFullScreen
        host.modalPresentationCapturesStatusBarAppearance = true
        host.view.backgroundColor = .clear
        menuHost = host
        present(host, animated: true, completion: afterPresentation)
        host.presentationController?.delegate = self
    }
    private func closeMenu(resume: Bool) {
        guard !utilities.busy, !stopping, let host = menuHost else { return }
        resumeAfterMenu = false
        host.dismiss(animated: true) { [weak self] in
            self?.menuHost = nil
            if resume { self?.setPaused(false) }
        }
    }
    private func editLiveControls(selectShortcut: Bool = false) {
        guard game.platform.hasHandheldOverlay, loaded, !checkingPreviousSession, !stopping, !utilities.busy,
              controlsEditorHost == nil else { return }
        returnToGameplayAfterControlEditing = menuHost == nil && !paused
        setPaused(true)
        resumeAfterMenu = false
        let openEditor: () -> Void = { [weak self] in
            guard let self, !self.stopping else { return }
            self.menuHost = nil
            let configuration = HandheldControlsConfiguration.load(system: self.game.platform)
            self.handheldConfiguration = HandheldControlsConfiguration(enabled: true,
                movement: configuration.movement, combos: configuration.combos, opacity: configuration.opacity,
                portrait: configuration.portrait, landscape: configuration.landscape)
            self.view.setNeedsLayout(); self.view.layoutIfNeeded()
            let editor = HandheldControlsEditor(initialSystem: self.game.platform, liveCanvas: self.view.bounds.size,
                initialSelection: selectShortcut ? .edit : .dpad) { [weak self] saved in
                self?.finishControlEditing(saved: saved)
            }
            self.installControlsEditor(editor)
        }
        if let menu = menuHost { menu.dismiss(animated: false, completion: openEditor) }
        else { openEditor() }
    }
    @objc private func openControlEditor() {
        guard menuHost == nil, controlsEditorHost == nil, !paused else { return }
        InterfaceHaptics.action()
        editLiveControls(selectShortcut: true)
    }
    private func layoutControlShortcut(safe: CGRect) {
        editControlsShortcut.isHidden = !game.platform.hasHandheldOverlay || !loaded || stopping || controlsEditorHost != nil
        editControlsShortcut.isEnabled = utilities.ready && !utilities.busy && !paused
        guard !editControlsShortcut.isHidden else { return }
        let layout = (view.bounds.width > view.bounds.height ? handheldConfiguration?.landscape : handheldConfiguration?.portrait)
            ?? HandheldControlLayout()
        editControlsShortcut.frame = (usingHandheldOverlay ? lastHandheldFrames[.edit] : nil)
            ?? layout.frames(in: view.bounds, system: game.platform, safeArea: safe)[.edit] ?? .zero
        editControlsShortcut.alpha = gear.alpha
    }
    private func installControlsEditor(_ editor: HandheldControlsEditor) {
        let host = UIHostingController(rootView: editor)
        controlsEditorHost = host
        host.view.backgroundColor = .clear
        host.view.isOpaque = false
        addChild(host); host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view); host.didMove(toParent: self)
        inputArea.isHidden = true; gear.isHidden = true; status.isHidden = true
        editControlsShortcut.isHidden = true
    }
    private func finishControlEditing(saved: Bool) {
        guard controlsEditorHost != nil else { return }
        removeControlsEditor()
        inputArea.isHidden = false; gear.isHidden = false
        handheldConfiguration = .load(system: game.platform)
        view.setNeedsLayout(); view.layoutIfNeeded()
        guard !stopping else { return }
        let resume = saved || returnToGameplayAfterControlEditing
        returnToGameplayAfterControlEditing = false
        if resume { setPaused(false) }
        else { presentMenu() }
    }
    private func removeControlsEditor() {
        guard let host = controlsEditorHost else { return }
        host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
        controlsEditorHost = nil
    }
    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        !utilities.busy && !stopping
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        menuHost = nil
        let resume = resumeAfterMenu
        resumeAfterMenu = false
        if resume { setPaused(false) }
    }
    private var alertPresenter: UIViewController { menuHost ?? self }
    private func presentPrompt(title: String, message: String, confirmTitle: String,
                               destructive: Bool = false, initialName: String? = nil,
                               onCancel: @escaping () -> Void = {},
                               onConfirm: @escaping (String) -> Void) {
        let host = UIHostingController(rootView: ClawGamePrompt(title: title, message: message,
            confirmTitle: confirmTitle, destructive: destructive, initialName: initialName,
            onCancel: onCancel, onConfirm: onConfirm).modifier(ClawStyle()).statusBarHidden(true))
        host.view.backgroundColor = .clear
        host.modalPresentationStyle = .overFullScreen
        host.modalTransitionStyle = .crossDissolve
        alertPresenter.present(host, animated: true)
    }
    private func send(_ code: PadKey, pressed: Bool, source: String = "touch") {
        guard loaded, !paused, !stopping, !inputLocked else { return }
        // Sources are unioned: a controller release must not cancel the same
        // button held on the touch overlay, and a duplicate visual region must
        // not release an input still held by the primary region (or another
        // duplicate).
        if let nowPressed = held.set(code, pressed: pressed, source: source) {
            engine.button(code.rawValue, nowPressed)
        }
    }
    private func releaseInputs() {
        for code in held.allInputs { engine.button(code.rawValue, false) }
        held.removeAll()
        circle.reset(); dpad.reset(); face.reset(); bottom.cancelTouch()
        [leftShoulder, rightShoulder, selectButton, startButton].forEach { $0.reset() }
        comboButtons.values.forEach { $0.reset() }
        resetDuplicateControls()
        clearAnalogInputs()
        engine.touch(0, 0, false)
    }
    private func resetDuplicateControls() {
        for control in duplicateControls {
            (control as? HeldButton)?.reset()
            (control as? DirectionPad)?.reset()
            (control as? CirclePad)?.reset()
        }
    }
    private func connectControllers() {
        for controller in controllers { controller.extendedGamepad?.valueChangedHandler = nil }
        controllers = GCController.controllers()
        for controller in controllers {
            let source = "controller-\(ObjectIdentifier(controller))"
            controller.extendedGamepad?.valueChangedHandler = { [weak self] pad, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    // Position-based mapping: south = B, east = A, north = X, west = Y.
                    let mapping: [(GCControllerButtonInput, PadKey)] = [
                        (pad.buttonA, .b), (pad.buttonB, .a), (pad.buttonX, .y), (pad.buttonY, .x),
                        (pad.leftShoulder, .l), (pad.rightShoulder, .r),
                        (pad.dpad.up, .up), (pad.dpad.down, .down), (pad.dpad.left, .left), (pad.dpad.right, .right)]
                    for (element, code) in mapping {
                        self.send(code, pressed: element.isPressed, source: source)
                    }
                    self.send(.start, pressed: pad.buttonMenu.isPressed, source: source)
                    if let options = pad.buttonOptions { self.send(.select, pressed: options.isPressed, source: source) }
                    if self.loaded && !self.paused && !self.inputLocked {
                        self.updateAnalog(source: source, x: pad.leftThumbstick.xAxis.value,
                                          y: pad.leftThumbstick.yAxis.value)
                    }
                }
            }
        }
    }

    private func setSpeed(_ value: Int) {
        guard loaded, !stopping, !utilities.busy else { return }
        utilities.speed = [1, 2, 4].contains(value) ? value : 1
        engine.setSpeed(Int32(utilities.speed))
        updateSpeedButtons()
        switch utilities.speed {
        case 2: utilities.message = "Target 2× speed · Faster, higher-pitched game audio."
        case 4: utilities.message = "Target 4× speed · Game audio muted."
        default: utilities.message = "Normal speed"
        }
    }
    private func updateSpeedButtons() {
        let accentName = UserDefaults.standard.string(forKey: "clawAccent") ?? ClawAccent.orange.rawValue
        let accentChoice = ClawAccent(rawValue: accentName) ?? .orange
        let accent = UIColor(accentChoice == .custom
            ? ClawAccent.customColor(UserDefaults.standard.object(forKey: "clawCustomAccentRGB") as? Int
                ?? ClawAccent.defaultCustomRGB)
            : accentChoice.color)
        for combo in lastCombos {
            guard let speed = combo.speed, let button = comboButtons[combo.key] else { continue }
            let active = utilities.speed == speed
            button.accessibilityValue = active ? "On" : "Off"
            guard button.isSelected != active else { continue }
            button.isSelected = active
            var style = button.configuration
            style?.baseBackgroundColor = active ? accent.withAlphaComponent(0.85) : .black.withAlphaComponent(0.55)
            style?.background.strokeColor = active ? accent : UIColor.white.withAlphaComponent(0.65)
            button.configuration = style
        }
    }
    @discardableResult private func requestState(restore: Bool, slot: Int? = nil, name: String = "") -> Bool {
        guard loaded, !stopping, !utilities.busy else { return false }
        let selected = slot ?? utilities.selectedSlot
        if restore || selected < 9 { releaseInputs() }
        let accepted = restore ? engine.restore(Int32(selected)) : engine.save(Int32(selected))
        guard accepted else {
            utilities.message = "The game is busy. Try again in a moment."
            return false
        }
        pendingSlot = selected; pendingName = name; stateRequestPending = true
        utilities.busy = true
        utilities.message = restore ? "Loading slot \(selected)…" : "Saving slot \(selected)…"
        gear.isEnabled = false
        menuHost?.isModalInPresentation = true
        inputArea.isUserInteractionEnabled = !paused && !inputLocked
        return true
    }
    private func confirmRestore(slot: Int? = nil) {
        guard loaded, !stopping, !utilities.busy else { return }
        let wasPaused = paused
        setPaused(true)
        let selected = slot ?? utilities.selectedSlot
        presentPrompt(title: "Load slot \(selected)?", message: "Your current progress will be replaced by this snapshot.",
                      confirmTitle: "Load", onCancel: { [weak self] in self?.setPaused(wasPaused) }) { [weak self] _ in
            self?.requestState(restore: true, slot: selected)
        }
    }
    private func refreshStates(recordName: String? = nil, slot: Int = 1, completion: @escaping @MainActor () -> Void = {}) {
        let title = titleID
        Task { [weak self, stateStore] in
            do {
                let entries: [SaveEntry]
                if let name = recordName { entries = try await stateStore.record(title: title, slot: slot, name: name) }
                else { entries = try await stateStore.list(title: title) }
                guard let self, !self.stopping else { return }
                self.utilities.states = entries
            } catch { self?.utilities.message = "Save list: \(error.localizedDescription)" }
            completion()
        }
    }
    private func checkPreviousSession() {
        let title = titleID
        Task { [weak self, stateStore] in
            do {
                let entries = try await stateStore.list(title: title)
                guard let self, !self.stopping else { return }
                self.utilities.states = entries
                guard let recent = entries.first else {
                    self.finishSessionCheck(); self.setPaused(false); return
                }
                self.previousSession = recent
                self.presentPreviousSession()
            } catch {
                self?.utilities.message = "Save list: \(error.localizedDescription)"
                self?.finishSessionCheck()
                self?.setPaused(false)
            }
        }
    }
    private func finishSessionCheck() {
        guard !stopping else { return }
        checkingPreviousSession = false
        previousSession = nil
        utilities.ready = true
        gear.isEnabled = !utilities.busy
    }
    private func presentPreviousSession() {
        guard loaded, !stopping, checkingPreviousSession, let recent = previousSession,
              UIApplication.shared.applicationState == .active,
              view.window != nil, presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Previous session found—continue?",
            message: "\(recent.label) · \(recent.date.formatted(date: .abbreviated, time: .standard))",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Start Normally", style: .cancel) { [weak self] _ in
            self?.finishSessionCheck(); self?.setPaused(false)
        })
        alert.addAction(UIAlertAction(title: "Continue", style: .default) { [weak self] _ in
            guard let self else { return }
            self.finishSessionCheck()
            self.continueAfterRestore = self.requestState(restore: true, slot: recent.slot)
            if !self.continueAfterRestore { self.continueNormalBootAfterRestoreFailure() }
        })
        present(alert, animated: true)
    }
    private func confirmSave(leave: Bool = false) {
        guard loaded, !stopping, !utilities.busy else { return }
        let slot = utilities.selectedSlot
        let existing = utilities.states.first { $0.slot == slot }
        presentPrompt(title: existing == nil ? "Save to slot \(slot)?" : "Overwrite slot \(slot)?",
                      message: existing == nil ? "Create a manual save of your current progress." : "This replaces the previous snapshot in this slot.",
                      confirmTitle: "Save", initialName: existing?.name ?? "") { [weak self] name in
            guard let self else { return }
            let accepted = self.requestState(restore: false, slot: slot, name: name)
            self.saveAndLeave = leave && accepted
        }
    }
    private func confirmDelete(_ entry: SaveEntry) {
        guard !utilities.busy, !stopping else { return }
        presentPrompt(title: "Delete this save?", message: "\(entry.label) · Slot \(entry.slot). This cannot be undone.",
                      confirmTitle: "Delete", destructive: true) { [weak self] _ in
            guard let self else { return }
            self.utilities.busy = true
            let title = self.titleID
            Task { [weak self, stateStore] in
                do {
                    let entries = try await stateStore.delete(title: title, slot: entry.slot)
                    self?.utilities.states = entries
                } catch { self?.utilities.message = error.localizedDescription }
                self?.utilities.busy = false
            }
        }
    }
    private func scheduleAutosave() {
        schedulingAutosave = true
        let title = titleID
        Task { [weak self, stateStore] in
            do {
                let slot = try await stateStore.autosaveSlot(title: title)
                guard let self, !self.stopping else { return }
                if !self.paused { _ = self.requestState(restore: false, slot: slot) }
            } catch { self?.utilities.message = "Auto Save: \(error.localizedDescription)" }
            self?.nextAutosave = ProcessInfo.processInfo.systemUptime + Self.autosaveInterval
            self?.schedulingAutosave = false
        }
    }
    private func setPaused(_ value: Bool) {
        guard loaded, !stopping else { return }
        if !value && UIApplication.shared.applicationState != .active { return }
        if !value && paused {
            status.text = "Resuming…"
            audioActivation.request(on: worker, activate: {
                try AVAudioSession.sharedInstance().setActive(true)
            }) { [weak self] error in
                guard let self, self.loaded, !self.stopping,
                      Self.activeFrontend == self.frontendID,
                      UIApplication.shared.applicationState == .active else { return }
                if let error {
                    self.status.text = "Audio is unavailable. Try Resume again after the interruption."
                    self.utilities.message = "Audio: \(error)"
                    return
                }
                self.applyPausedState(false)
            }
            return
        }
        if value {
            audioActivation.cancel()
            releaseInputs()
            if !utilities.busy { utilities.message = "Paused" }
        }
        applyPausedState(value)
    }
    private func updateThermalState() {
        guard loaded, !stopping else { return }
        engine.setThermalState(Int32(ProcessInfo.processInfo.thermalState.rawValue))
    }
    private func applyPausedState(_ value: Bool) {
        if value { checkpointPlaytime() }
        else if loaded && !stopping { playtimeClock.resume(at: ProcessInfo.processInfo.systemUptime) }
        paused = value
        ControlHaptics.shared.setActive(!value && !inputLocked)
        if !value { updateThermalState() }
        engine.pause(value)
        inputArea.isUserInteractionEnabled = !value && !inputLocked
        status.text = value ? "Paused" : "Resuming…"
        view.setNeedsLayout()
    }
    private func sample() {
        guard loaded, !stopping else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime >= nextMemoryHeadroomCheck {
            nextMemoryHeadroomCheck = uptime + 2
            let available = engine.availableMemoryBytes()
            if available > 0 && available < 192 * 1024 * 1024 { engine.memoryPressure() }
        }
        if utilities.busy && stateRequestPending {
            let operation = engine.stateStatus()
            if operation != 1 {
                stateRequestPending = false
                switch operation {
                case 2: utilities.message = "Slot \(pendingSlot) saved."
                case 3: utilities.message = "Slot \(pendingSlot) loaded. Tap Resume to continue."
                default: utilities.message = String(cString: engine.stateError())
                }
                let shouldResume = continueAfterRestore
                continueAfterRestore = false
                let shouldLeave = saveAndLeave && operation == 2
                saveAndLeave = false
                // Finish metadata before enabling exit or a second save. The
                // library can then immediately show the correct name/frame.
                refreshStates(recordName: operation == 2 ? pendingName : nil, slot: pendingSlot) { [weak self] in
                    guard let self, !self.stopping else { return }
                    self.utilities.busy = false
                    self.gear.isEnabled = true
                    self.menuHost?.isModalInPresentation = false
                    self.inputArea.isUserInteractionEnabled = !self.paused
                    if shouldResume {
                        if operation == 3 { self.setPaused(false) }
                        else if self.engine.isRunning() { self.continueNormalBootAfterRestoreFailure() }
                    }
                    if shouldLeave { self.finish() }
                }
            }
        }
        if !engine.isRunning() {
            timer?.invalidate()
            if engine.didRequestShutdown() {
                finish()
                return
            }
            worker.async { [self] in
                let error = String(cString: engine.lastError())
                DispatchQueue.main.async {
                    guard !self.stopping else { return }
                    self.showError(error.isEmpty ? "The game stopped." : error)
                }
            }
            return
        }
        if utilities.autosaveEnabled, !paused, !utilities.busy, !schedulingAutosave,
           ProcessInfo.processInfo.systemUptime >= nextAutosave { scheduleAutosave() }
        let graphics: String
        let thermal = engine.appliedThermalState()
        if !engine.is3DS {
            utilities.graphics = "\(game.platform.title) · Native resolution · Metal display · Interpreter"
            if !paused {
                status.text = String(format: "%.1f FPS · ", engine.fps()) + game.platform.title +
                    (thermal >= 3 ? " · Thermal protection · 30 Hz display target" : "")
            }
            return
        }
        if engine.metalFXStatus() == -1 {
            utilities.graphics = "Native 4× · " + String(cString: engine.metalFXError())
        }
        if !paused {
            if thermal >= 2 {
                let scale = thermal >= 3 ? 1 : (resolution > 2 || upscaleInput != 0 ? 2 : 1)
                graphics = "Thermal protection · Native \(scale)× · MetalFX bypassed" +
                    (thermal >= 3 ? " · 30 Hz display target" : "")
            } else { switch engine.metalFXStatus() {
            case 1: graphics = "\(upscaleInput)× → 4× · MetalFX active"
            case 2: graphics = "\(upscaleInput)× → 4× · MetalFX starting"
            case -1: graphics = "Native 4× · MetalFX fallback"
            default: graphics = "Native \(resolution)× · MetalFX off"
            } }
            if engine.metalFXStatus() != -1 { utilities.graphics = graphics }
            let speedLabel = utilities.speed > 1
                ? String(format: "%.2f× / %d× · ", engine.emulationSpeed(), utilities.speed) : ""
            status.text = String(format: "%.1f FPS · ", engine.fps()) + speedLabel + graphics
        }
    }
    @objc private func clawGraphicsStatus() {
        guard !stopping, !checkingPreviousSession, engine.metalFXStatus() == -1,
              presentedViewController == nil else { return }
        let reason = String(cString: engine.metalFXError())
        let alert = UIAlertController(title: "MetalFX fallback", message: reason.isEmpty
            ? "MetalFX could not start. Native rendering is active." : reason, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        alertPresenter.present(alert, animated: true)
    }
    @objc private func clawConfirmExit() {
        setPaused(true)
        presentPrompt(title: "Stop game?", message: "Your last in-game save is kept. Unsaved progress will be lost.",
                      confirmTitle: "Stop", destructive: true) { [weak self] _ in self?.finish() }
    }
    private func continueNormalBootAfterRestoreFailure() {
        // Both engines stop themselves if deserialization touched unsafe state.
        // Only an intact, still-running boot may continue after a rejected file.
        guard engine.isRunning(), !stopping else { return }
        utilities.message = "The save state could not be loaded. Starting normally; your save file is unchanged."
        setPaused(false)
    }
    private func showError(_ message: String) {
        guard !stopping else { return }
        checkpointPlaytime()
        ControlHaptics.shared.setActive(false)
        audioActivation.cancel()
        timer?.invalidate()
        utilities.ready = false
        inputArea.isUserInteractionEnabled = false
        gear.isEnabled = false
        let alert = UIAlertController(title: "Game could not continue", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Back to library", style: .default) { [weak self] _ in self?.finish() })
        alertPresenter.present(alert, animated: true)
    }
    func stopForRemoval() { finish(returnToLibrary: false) }
    private func checkpointPlaytime() {
        let seconds = playtimeClock.pause(at: ProcessInfo.processInfo.systemUptime)
        if seconds > 0 { onPlaytime?(seconds) }
    }
    private func finish(returnToLibrary: Bool = true) {
        guard !stopping else { return }
        checkpointPlaytime()
        stopping = true
        removeControlsEditor()
        importedSkinsGeneration += 1
        importedSkinsLoading = false
        ControlHaptics.shared.setActive(false)
        audioActivation.cancel()
        utilities.ready = false
        utilities.speed = 1
        releaseInputs()
        engine.requestStop()
        timer?.invalidate()
        inputArea.isUserInteractionEnabled = false
        gear.isEnabled = false
        status.text = "Stopping…"
        for controller in controllers { controller.extendedGamepad?.valueChangedHandler = nil }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        worker.async { [self] in
            engine.stop()
            DispatchQueue.main.async { [self] in
                loaded = false
                if Self.activeFrontend == frontendID {
                    GameOrientationPolicy.mask = .allButUpsideDown
                    UIApplication.shared.isIdleTimerDisabled = Self.originalIdleSetting ?? false
                    Self.originalIdleSetting = nil
                    Self.activeFrontend = nil
                    // Queue deactivation before a replacement can queue its load.
                    worker.async { [self] in
                        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                        DispatchQueue.main.async { [self] in
                            if returnToLibrary { onExit() }
                        }
                    }
                } else if returnToLibrary {
                    onExit()
                }
            }
        }
    }
    deinit {
        timer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

struct ClawGamePrompt: View {
    let title: String
    let message: String
    let confirmTitle: String
    let destructive: Bool
    let initialName: String?
    var cancelTitle: String? = "Cancel"
    let onCancel: () -> Void
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.clawAccent) private var accent
    @State private var name = ""
    @State private var confirmed: Bool?
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 16) {
                    Text(title).font(.title3.bold())
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                    if initialName != nil {
                        TextField("Optional save name", text: $name)
                            .textInputAutocapitalization(.sentences)
                            .accessibilityIdentifier("saveName")
                            .padding(14).background(ClawPalette.subtleFill, in: RoundedRectangle(cornerRadius: 14))
                    }
                    HStack(spacing: 10) {
                        if let cancelTitle {
                            Button { confirmed = false; dismiss() } label: {
                                Text(cancelTitle).frame(maxWidth: .infinity, minHeight: 48)
                                    .consoleGlass(radius: 100).contentShape(Capsule())
                            }.accessibilityIdentifier("promptCancel")
                        }
                        Button { confirmed = true; dismiss() } label: {
                            Text(confirmTitle).frame(maxWidth: .infinity, minHeight: 48)
                                .background(destructive ? Color.red.opacity(0.82) : accent.clawSelectionFill, in: Capsule())
                                .foregroundStyle(.white).contentShape(Capsule())
                        }.accessibilityIdentifier("promptConfirm")
                    }.font(.subheadline.weight(.semibold)).buttonStyle(ConsolePressStyle())
                }.padding(20).frame(maxWidth: 400)
                    .background(ClawPalette.card, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(ClawPalette.border, lineWidth: 1))
                    .padding(20).accessibilityElement(children: .contain).accessibilityIdentifier("gamePrompt")
                Spacer(minLength: 0)
                }.frame(minHeight: geometry.size.height)
            }.frame(maxWidth: .infinity)
        }.background(Color.black.opacity(0.58)).onAppear { name = initialName ?? "" }
            .onDisappear {
                guard let confirmed else { return }
                if confirmed { onConfirm(name) } else { onCancel() }
            }
    }
}
