// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit
import QuartzCore

// UIKit feedback stays on the main queue. Input is latched before enqueueing;
// no haptic work, allocations or waits run on emulation/audio workers.
@MainActor final class ControlHaptics {
    static let shared = ControlHaptics()
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private var active = false, queued = false, wantsMedium = false
    private var generation = 0
    private var lastImpact: TimeInterval = 0
    private var enabled: Bool { UserDefaults.standard.object(forKey: "controlHaptics") as? Bool ?? true }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value; generation += 1; queued = false; wantsMedium = false
        guard value, enabled else { return }
        let ticket = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, self.generation == ticket, self.enabled else { return }
            self.light.prepare(); self.medium.prepare()
        }
    }
    func press(shoulder: Bool = false) {
        guard active else { return }
        wantsMedium = wantsMedium || shoulder
        guard !queued else { return }
        queued = true
        let ticket = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == ticket else { return }
            let shoulder = self.wantsMedium
            self.queued = false; self.wantsMedium = false
            guard self.active, self.enabled else { return }
            let generator = shoulder ? self.medium : self.light
            // Touch-down refreshes preparation; resume and the previous pulse
            // provide the useful lead time. prepare() cannot guarantee zero latency.
            generator.prepare()
            let now = CACurrentMediaTime()
            guard now - self.lastImpact >= 0.025 else { return }
            self.lastImpact = now
            generator.impactOccurred(intensity: shoulder ? 0.8 : 0.65)
            generator.prepare()
        }
    }
}

final class HeldButton: UIButton {
    var changed: ((Bool) -> Void)?
    private var defaultConfiguration: UIButton.Configuration?
    private var skinned = false
    private var padPressLatched = false
    var shoulderHaptic = false
    override var isHighlighted: Bool { didSet {
        if skinned { backgroundColor = isHighlighted ? .white.withAlphaComponent(0.12) : .clear }
    } }
    override func layoutSubviews() {
        super.layoutSubviews()
        if skinned { layer.cornerRadius = min(bounds.width, bounds.height) / 2 }
    }
    var circularSkinTarget = false
    init(_ title: String) {
        super.init(frame: .zero)
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = .white.withAlphaComponent(0.10)
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        configuration = config
        defaultConfiguration = config
        accessibilityLabel = title
        accessibilityIdentifier = "pad\(title)"
        isMultipleTouchEnabled = false
        addTarget(self, action: #selector(heldDown), for: [.touchDown, .touchDragEnter])
        addTarget(self, action: #selector(heldUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func heldDown() {
        guard !padPressLatched else { return }
        padPressLatched = true
        changed?(true) // Latch first; feedback is queued afterward.
        ControlHaptics.shared.press(shoulder: shoulderHaptic)
    }
    @objc private func heldUp() {
        guard padPressLatched else { return }
        padPressLatched = false; changed?(false)
    }
    func reset() { padPressLatched = false; isHighlighted = false }
    func useSkin(_ enabled: Bool) {
        skinned = enabled
        configuration = enabled ? nil : defaultConfiguration
        if enabled { setTitle(nil, for: .normal); backgroundColor = .clear }
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard circularSkinTarget else { return super.point(inside: point, with: event) }
        return hypot(point.x - bounds.midX, point.y - bounds.midY) <= min(bounds.width, bounds.height) / 2
    }
}

final class CirclePad: UIView {
    var moved: ((Float, Float) -> Void)?
    private let knob = UIView()
    private let skinKnob = ObsidianThumbCap()
    private let importedKnob = UIImageView()
    private var skinMode = false
    private weak var tracked: UITouch?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.white.withAlphaComponent(0.08)
        knob.backgroundColor = .systemPurple
        knob.isUserInteractionEnabled = false
        addSubview(knob)
        skinKnob.isUserInteractionEnabled = false
        skinKnob.isHidden = true
        addSubview(skinKnob)
        importedKnob.contentMode = .scaleAspectFit
        importedKnob.isUserInteractionEnabled = false
        importedKnob.isHidden = true
        addSubview(importedKnob)
        isAccessibilityElement = true
        accessibilityLabel = "Circle pad"
        accessibilityIdentifier = "circlePad"
        accessibilityTraits = .allowsDirectInteraction
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        let size = min(44, bounds.width * 0.38)
        knob.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        knob.layer.cornerRadius = size / 2
        skinKnob.bounds = CGRect(origin: .zero, size: CGSize(width: bounds.width * 0.60, height: bounds.height * 0.60))
        if tracked == nil { knob.center = CGPoint(x: bounds.midX, y: bounds.midY) }
        skinKnob.center = knob.center
        importedKnob.bounds = skinKnob.bounds
        importedKnob.center = knob.center
    }
    func reset() {
        tracked = nil; knob.center = CGPoint(x: bounds.midX, y: bounds.midY)
        skinKnob.center = knob.center
        importedKnob.bounds = skinKnob.bounds
        importedKnob.center = knob.center
    }
    func useSkin(_ enabled: Bool) {
        backgroundColor = enabled ? .clear : UIColor.white.withAlphaComponent(0.08)
        knob.isHidden = enabled
        skinMode = enabled
        skinKnob.isHidden = !enabled || importedKnob.image != nil
        importedKnob.isHidden = !enabled || importedKnob.image == nil
        clipsToBounds = enabled
    }
    func setImportedArtwork(_ image: UIImage?) {
        if importedKnob.image !== image { importedKnob.image = image }
        importedKnob.isHidden = !skinMode || image == nil
        skinKnob.isHidden = !skinMode || image != nil
    }
    func useFloatingStyle(_ enabled: Bool) {
        knob.backgroundColor = enabled ? .white : .systemPurple
    }
    private func move(_ touch: UITouch) {
        let point = touch.location(in: self)
        let radius = skinMode ? max(bounds.width * 0.18, 1) : max(bounds.width / 2 - knob.bounds.width / 2, 1)
        var x = (point.x - bounds.midX) / radius
        var y = (point.y - bounds.midY) / radius
        let length = hypot(x, y)
        if length > 1 { x /= length; y /= length }
        knob.center = CGPoint(x: bounds.midX + x * radius, y: bounds.midY + y * radius)
        skinKnob.center = knob.center
        importedKnob.bounds = skinKnob.bounds
        importedKnob.center = knob.center
        moved?(Float(x), Float(-y))
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tracked == nil, let touch = touches.first else { return }
        tracked = touch; move(touch)
        ControlHaptics.shared.press()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let tracked, touches.contains(tracked) { move(tracked) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let tracked, touches.contains(tracked) { reset(); moved?(0, 0) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { reset(); moved?(0, 0) }
}

final class DirectionPad: UIView {
    var changed: ((Set<PadKey>) -> Void)?
    private var lastKeys = Set<PadKey>()
    private weak var tracked: UITouch?
    private let arrows = ["↑", "←", "→", "↓"].map { text -> UILabel in
        let label = UILabel(); label.text = text; label.textAlignment = .center
        label.font = .systemFont(ofSize: 23, weight: .medium); label.textColor = .white
        return label
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.white.withAlphaComponent(0.07)
        for arrow in arrows { addSubview(arrow) }
        isAccessibilityElement = true
        accessibilityLabel = "Directional pad"
        accessibilityIdentifier = "directionPad"
        accessibilityHint = "Slide for directions and diagonals"
        accessibilityTraits = .allowsDirectInteraction
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layoutSubviews() {
        super.layoutSubviews(); layer.cornerRadius = bounds.width / 2
        let side = bounds.width / 3
        for (label, point) in zip(arrows, [CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 2, y: 1), CGPoint(x: 1, y: 2)]) {
            label.frame = CGRect(x: point.x * side, y: point.y * side, width: side, height: side)
        }
    }
    func reset() { tracked = nil; lastKeys.removeAll(); arrows.forEach { $0.textColor = .white } }
    func useSkin(_ enabled: Bool) {
        backgroundColor = enabled ? .clear : UIColor.white.withAlphaComponent(0.07)
        arrows.forEach { $0.isHidden = enabled }
    }
    private func move(_ touch: UITouch) {
        let axes = DPadAxes.at(touch.location(in: self), size: bounds.size)
        var keys = Set<PadKey>()
        if axes.horizontal < 0 { keys.insert(.left) }; if axes.horizontal > 0 { keys.insert(.right) }
        if axes.vertical > 0 { keys.insert(.up) }; if axes.vertical < 0 { keys.insert(.down) }
        for (label, key) in zip(arrows, [PadKey.up, .left, .right, .down]) {
            label.textColor = keys.contains(key) ? .systemPurple : .white
        }
        changed?(keys)
        if !keys.isEmpty && keys != lastKeys { ControlHaptics.shared.press() }
        lastKeys = keys
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tracked == nil, let touch = touches.first else { return }; tracked = touch; move(touch)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let tracked, touches.contains(tracked) { move(tracked) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let tracked, touches.contains(tracked) { reset(); changed?([]) }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { reset(); changed?([]) }
}

final class FaceButtons: UIView {
    let buttons: [PadKey: HeldButton] = [.x: HeldButton("X"), .y: HeldButton("Y"), .a: HeldButton("A"), .b: HeldButton("B")]
    var skinFrames: [PadKey: CGRect]? { didSet { setNeedsLayout() } }
    override init(frame: CGRect) { super.init(frame: frame); buttons.values.forEach { addSubview($0) } }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let skinFrames {
            for (key, frame) in skinFrames { buttons[key]?.frame = frame }
            return
        }
        let side = max(44, bounds.width / 3)
        let mid = (bounds.width - side) / 2
        buttons[.x]?.frame = CGRect(x: mid, y: 0, width: side, height: side)
        buttons[.y]?.frame = CGRect(x: 0, y: mid, width: side, height: side)
        buttons[.a]?.frame = CGRect(x: bounds.width - side, y: mid, width: side, height: side)
        buttons[.b]?.frame = CGRect(x: mid, y: bounds.height - side, width: side, height: side)
    }
    func reset() { buttons.values.forEach { $0.reset() } }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        buttons.values.contains { !$0.isHidden && $0.alpha > 0.01 && $0.point(inside: convert(point, to: $0), with: event) }
    }
}

// Native moving cap: static layers, no per-frame SwiftUI body work while dragging.
private final class ObsidianThumbCap: UIView {
    private let gradient = CAGradientLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        gradient.colors = [UIColor(white: 0.20, alpha: 1).cgColor, UIColor(white: 0.045, alpha: 1).cgColor]
        gradient.startPoint = CGPoint(x: 0.2, y: 0); gradient.endPoint = CGPoint(x: 0.8, y: 1)
        layer.addSublayer(gradient)
        layer.borderColor = UIColor(white: 0.25, alpha: 1).cgColor
        layer.borderWidth = 1
        layer.shadowColor = UIColor.black.cgColor; layer.shadowOpacity = 0.8; layer.shadowRadius = 3
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds; gradient.cornerRadius = bounds.width / 2
        layer.cornerRadius = bounds.width / 2
        layer.shadowPath = UIBezierPath(ovalIn: bounds).cgPath
    }
}
