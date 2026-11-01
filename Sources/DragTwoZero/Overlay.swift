import AppKit
import QuartzCore

/// Quartz coordinates. Flip beside the pointer before clamping to the active screen.
func hintFrame(at point: CGPoint, size: CGSize, screen: CGRect) -> CGRect {
    let margin: CGFloat = 8, gap: CGFloat = 18
    var x = point.x + gap, y = point.y + gap
    if x + size.width > screen.maxX - margin { x = point.x - gap - size.width }
    if y + size.height > screen.maxY - margin { y = point.y - gap - size.height }
    x = max(screen.minX + margin, min(x, screen.maxX - size.width - margin))
    y = max(screen.minY + margin, min(y, screen.maxY - size.height - margin))
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
}

func selectedTextHintFrame(at point: CGPoint, size: CGSize, screen: CGRect) -> CGRect {
    let margin: CGFloat = 0
    let x = max(screen.minX + margin, min(point.x - size.width / 2, screen.maxX - size.width - margin))
    let y = max(screen.minY + margin, min(point.y - size.height / 2, screen.maxY - size.height - margin))
    return CGRect(origin: CGPoint(x: x, y: y), size: size)
}

/// Screen bounds are in Cocoa coordinates, including negative and stacked displays.
func overlayScreenFrame(at point: CGPoint, screens: [CGRect]) -> CGRect? {
    screens.first { $0.contains(point) }
}

/// Capture visuals never own keyboard focus. A nonactivating panel can still
/// take focus from another app when made key, even while ignoring mouse events.
final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PlainCaptureView: NSView {
    private let filled: Bool
    init(filled: Bool) {
        self.filled = filled
        super.init(frame: .zero)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = filled ? 14 : 12
        layer?.borderWidth = filled ? 1 : 2
        refreshColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshColors()
    }
    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (filled ? NSColor.windowBackgroundColor : .clear).cgColor
            layer?.borderColor = CapturePreferences.borderColor.color.cgColor
        }
    }
}

final class Overlay {
    private let haptics = CaptureHaptics()
    private let glassEnabled = CapturePreferences.liquidGlassEnabled
    private var trackingScroll = false
    private var appliedTone: BackdropTone?
    private var hasAppliedTone = false
    private var capturing = false
    private var dragging = false
    private var completing = false
    private var sourceCollapsing = false
    private var animationGeneration = 0
    private let panel = CapturePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var blockOutlines: [NSView] = []
    private var activeBlockCount = 0
    private var selectedFrames: [CGRect] = []
    private let outline: NSView
    private let badge: NSView
    private let scene: NSView
    private let stage = NSView()
    private var viewport = CGRect.zero
    private let root = NSView()
    private let hint = NSView()
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let copyIcon = NSImageView()
    private let releaseLabel = NSTextField(labelWithString: "Drag")
    private var size = CGSize(width: 150, height: 48)
    private var morphTimer: AnimationFrames?
    private var pointer = CGPoint.zero
    private var morphProgress: CGFloat = 1
    private var morphStartSize = CGSize.zero
    private var morphStartFrame: CGRect?
    private var currentSymbol = ""
    private var destinationReady = false

    init() {
        if !glassEnabled {
            scene = NSView(); scene.addSubview(stage)
            outline = Self.borderView()
            badge = PlainCaptureView(filled: true)
            scene.appearance = CapturePreferences.borderAppearance.appearance
            badge.addSubview(root); root.autoresizingMask = [.width, .height]
        } else if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView()
            container.spacing = 36
            container.contentView = stage
            scene = container
            let selection = NSGlassEffectView()
            selection.style = .clear; selection.tintColor = nil; selection.cornerRadius = 12
            selection.focusRingType = .none
            outline = selection
            let tile = NSGlassEffectView()
            tile.style = .clear; tile.tintColor = nil; tile.cornerRadius = 14
            tile.focusRingType = .none
            tile.contentView = root
            badge = tile
        } else {
            scene = NSView()
            scene.addSubview(stage)
            func material(radius: CGFloat) -> NSVisualEffectView {
                let effect = NSVisualEffectView()
                effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
                effect.wantsLayer = true
                effect.layer?.cornerRadius = radius; effect.layer?.masksToBounds = true
                return effect
            }
            outline = material(radius: 12); badge = material(radius: 14)
            badge.addSubview(root); root.autoresizingMask = [.width, .height]
        }
        viewport = overlayScreenFrame(at: NSEvent.mouseLocation, screens: NSScreen.screens.map(\.frame))
            ?? NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(viewport, display: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = CaptureWindowLayers.hint
        panel.ignoresMouseEvents = true
        // Pure decoration must not become the system accessibility hit target.
        panel.setAccessibilityHidden(true)
        scene.setAccessibilityHidden(true)
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.contentView = scene
        stage.frame = CGRect(origin: .zero, size: viewport.size)
        stage.bounds = viewport
        stage.autoresizingMask = [.width, .height]
        scene.wantsLayer = true
        for view in [scene, stage, root, hint, label, icon, copyIcon, releaseLabel] { view.focusRingType = .none }
        stage.addSubview(outline); stage.addSubview(badge)
        outline.isHidden = true; badge.isHidden = true
        root.wantsLayer = true; hint.wantsLayer = true
        root.addSubview(hint)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true; label.cell?.wraps = false
        icon.contentTintColor = .labelColor
        hint.addSubview(icon); hint.addSubview(label)
        copyIcon.image = DragCursorIcon.image
        copyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 21, weight: .semibold)
        copyIcon.contentTintColor = .labelColor
        copyIcon.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        root.addSubview(copyIcon)
        releaseLabel.font = .systemFont(ofSize: 13, weight: .medium)
        releaseLabel.textColor = .labelColor
        releaseLabel.alphaValue = 0
        root.addSubview(releaseLabel)
        copyIcon.alphaValue = 0
    }
    private static func borderView() -> NSView {
        PlainCaptureView(filled: false)
    }
    func close() {
        morphTimer?.invalidate()
        panel.orderOut(nil); panel.close()
    }
    func setBackdropTone(_ tone: BackdropTone?) {
        guard glassEnabled else { return }
        guard !hasAppliedTone || appliedTone != tone else { return }
        hasAppliedTone = true; appliedTone = tone
        let appearance = tone.map { NSAppearance(named: $0 == .light ? .aqua : .darkAqua)! }
        // Seed both material and foreground from the measured target before showing it.
        // Native glass still handles refraction and merging; no screenshot is rendered.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CapturePreferences.animationDuration(0.10)
            context.allowsImplicitAnimation = context.duration > 0
            for view in [scene, outline, badge] + blockOutlines {
                view.appearance = appearance
            }
        }
        // Glass manages the effective appearance of its content. Explicit child
        // appearances and resolved colors prevent foreground adaptation when the
        // native material changes against a different backdrop.
        for view in [root, hint, label, icon, copyIcon, releaseLabel] {
            view.appearance = nil
        }
        label.textColor = .labelColor
        icon.contentTintColor = .labelColor
        copyIcon.contentTintColor = .labelColor
    }

    private func updateScreen(at point: CGPoint) {
        let position = cocoa(CGRect(origin: point, size: .zero)).origin
        guard let frame = overlayScreenFrame(at: position, screens: NSScreen.screens.map(\.frame)),
              frame != viewport else { return }
        viewport = frame
        // A desktop-spanning window stays associated with one display. Relocating it
        // lets AppKit update the backing scale and compositor for the pointer's screen.
        panel.setFrame(frame, display: false)
        scene.layoutSubtreeIfNeeded()
        stage.frame = CGRect(origin: .zero, size: frame.size)
        stage.bounds = frame
        scene.needsDisplay = true
    }
    private func presentScene() {
        scene.layoutSubtreeIfNeeded()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
    private func hideSceneIfIdle() {
        guard !capturing, !dragging, !completing else { return }
        badge.isHidden = true; panel.orderOut(nil)
    }
    private func animate(_ duration: TimeInterval, _ changes: () -> Void, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = trackingScroll ? 0 : CapturePreferences.animationDuration(duration)
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.85, 0.22, 1)
            changes()
        }, completionHandler: completion)
    }
    private func cocoa(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY, width: frame.width, height: frame.height)
    }
    private func layout(_ newSize: CGSize) {
        guard hint.frame.size != newSize || root.frame.size != newSize else { return }
        hint.frame = CGRect(origin: .zero, size: newSize)
        root.frame = CGRect(origin: .zero, size: newSize)
        icon.frame = CGRect(x: 10, y: (newSize.height - 16) / 2, width: 16, height: 16)
        label.frame = CGRect(x: 33, y: floor((newSize.height - 17) / 2), width: max(0, newSize.width - 43), height: 17)
        copyIcon.frame = CGRect(x: (newSize.width - 19) / 2, y: (newSize.height - 21) / 2, width: 19, height: 21)
    }
    func beginCapture() {
        haptics.reset()
        if panel.isVisible { panel.orderOut(nil) }
        capturing = true
        setDestinationReady(false)
        animationGeneration += 1; dragging = false; completing = false; sourceCollapsing = false
        morphStartFrame = nil
        morphTimer?.invalidate(); morphTimer = nil
        copyIcon.image = DragCursorIcon.image
        hint.alphaValue = 1; copyIcon.alphaValue = 0; releaseLabel.alphaValue = 0
        // The first positioned glass view will present the passive window.
        outline.isHidden = true; badge.isHidden = true; clearBlockHighlights()
        let mouse = NSEvent.mouseLocation
        updateScreen(at: cocoa(CGRect(origin: mouse, size: .zero)).origin)
        // Keep the source's hover target intact. The event tap consumes captured
        // mouse presses/drags; all visual windows remain mouse-transparent.
        NSCursor.arrow.set()
    }
    func endCapture() {
        capturing = false
    }
    func setDestinationReady(_ ready: Bool) {
        guard destinationReady != ready else { return }
        destinationReady = ready
        haptics.destination(ready)
        if #available(macOS 26.0, *), let glass = badge as? NSGlassEffectView {
            // Matching styles let the chip merge with the clear input-area glass.
            glass.style = .clear
        }
        copyIcon.image = ready
            ? NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: "Drop to insert")
            : DragCursorIcon.image
        copyIcon.setAccessibilityLabel(ready ? "Drop to insert" : "Drag")
        releaseLabel.stringValue = ready ? "Drop" : "Drag"
        if dragging { animate(0.14, { self.updateDragShape(animated: true) }) }
    }
    private func clearBlockHighlights() {
        activeBlockCount = 0; selectedFrames = []
        for view in blockOutlines { view.isHidden = true }
    }
    func highlightBlocks(_ frames: [CGRect], trackingScroll: Bool = false, textSelection: Bool = false) {
        self.trackingScroll = trackingScroll
        defer { self.trackingScroll = false }
        let feedbackFrames = textSelection ? frames.first.map { first in [frames.dropFirst().reduce(first) { $0.union($1) }] } ?? [] : frames
        if trackingScroll { haptics.reposition(feedbackFrames) } else { haptics.highlight(feedbackFrames) }
        guard frames.isEmpty || frames != selectedFrames else { return }
        let previousFrames = selectedFrames
        selectedFrames = frames
        sourceCollapsing = false
        guard let first = frames.first else {
            outline.isHidden = true; clearBlockHighlights(); return
        }
        let padding: CGFloat = textSelection ? 1 : 6
        highlight(first, preservingBlocks: true, textSelection: textSelection)
        if !previousFrames.isEmpty && !previousFrames.contains(first) {
            morphAddedBlock(outline, to: cocoa(first.insetBy(dx: -padding, dy: -padding)))
        }
        activeBlockCount = frames.count - 1
        for (index, view) in blockOutlines.enumerated() where index >= activeBlockCount && !view.isHidden {
            let target = outline.frame
            animate(0.14, {
                view.animator().frame = CGRect(x: target.midX, y: target.midY, width: 1, height: 1)
                view.animator().alphaValue = 0
            }, completion: { [weak self, weak view] in
                guard let self, index >= self.activeBlockCount else { return }
                view?.isHidden = true
            })
        }
        while blockOutlines.count < frames.count - 1 {
            let view: NSView
            if !glassEnabled {
                view = Self.borderView()
            } else if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.focusRingType = .none
                glass.style = .clear; glass.cornerRadius = 12
                view = glass
            } else {
                let effect = NSVisualEffectView()
                effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
                effect.wantsLayer = true; effect.layer?.cornerRadius = 12
                view = effect
            }
            view.appearance = outline.appearance
            view.isHidden = true
            stage.addSubview(view, positioned: .below, relativeTo: badge)
            blockOutlines.append(view)
        }
        for (index, frame) in frames.dropFirst().enumerated() {
            let view = blockOutlines[index]
            if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
                glass.cornerRadius = textSelection ? 4 : 12
            } else { view.layer?.cornerRadius = textSelection ? 4 : 12 }
            let rect = cocoa(frame.insetBy(dx: -padding, dy: -padding))
            if !previousFrames.contains(frame) || view.isHidden || view.alphaValue < 1 {
                morphAddedBlock(view, to: rect)
            } else if view.frame != rect {
                animate(0.08, { view.animator().frame = rect })
            }
        }
    }
    private func morphAddedBlock(_ view: NSView, to rect: CGRect) {
        // Full opacity from the first frame; a larger, slower expansion makes the
        // new glass surface visibly join the selection without delaying feedback.
        view.frame = rect.insetBy(dx: min(16, rect.width * 0.09), dy: min(14, rect.height * 0.22))
        view.alphaValue = 1; view.isHidden = false
        animate(0.24, { view.animator().frame = rect })
    }
    func highlight(_ frame: CGRect?, destination: Bool = false, preservingBlocks: Bool = false, textSelection: Bool = false, paddingOverride: CGFloat? = nil, cornerRadiusOverride: CGFloat? = nil) {
        if !preservingBlocks && !destination { haptics.highlight(frame.map { [$0] } ?? []) }
        if !preservingBlocks { clearBlockHighlights() }
        guard let frame else {
            if !sourceCollapsing { outline.isHidden = true }
            return
        }
        sourceCollapsing = false
        let padding: CGFloat = paddingOverride ?? (destination ? 8 : (textSelection ? 1 : 6))
        let radius: CGFloat = cornerRadiusOverride ?? (destination ? 18 : (textSelection ? 4 : 12))
        if #available(macOS 26.0, *), let glass = outline as? NSGlassEffectView {
            let style: NSGlassEffectView.Style = .clear
            if glass.style != style { glass.style = style }
            if glass.cornerRadius != radius { glass.cornerRadius = radius }
        } else { outline.layer?.cornerRadius = radius }
        let rect = cocoa(frame.insetBy(dx: -padding, dy: -padding))
        if outline.frame != rect {
            if preservingBlocks && !outline.isHidden { animate(0.14, { self.outline.animator().frame = rect }) }
            else { outline.frame = rect }
        }
        outline.alphaValue = 1
        outline.isHidden = false; presentScene()
    }
    func highlightBufferSlot(_ frame: CGRect?) {
        highlight(frame, destination: true, paddingOverride: 0, cornerRadiusOverride: BufferLayout.slotCornerRadius)
    }
    private func placement(at point: CGPoint, size: CGSize) -> CGRect {
        let screens = NSScreen.screens.map { cocoa($0.visibleFrame) }
        let screen = screens.first(where: { $0.contains(point) }) ?? screens.first ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var frame = cocoa(hintFrame(at: point, size: size, screen: screen))
        let scale = NSScreen.screens.first(where: { $0.frame.contains(frame.origin) })?.backingScaleFactor ?? 2
        frame.origin.x = (frame.origin.x * scale).rounded() / scale
        frame.origin.y = (frame.origin.y * scale).rounded() / scale
        return frame
    }
    private func updateDragShape(animated: Bool = false) {
        let p = morphProgress
        let targetWidth: CGFloat = 90
        size = CGSize(width: morphStartSize.width + (targetWidth - morphStartSize.width) * p, height: 48)
        // Geometry follows the current pointer even while the glass is changing shape.
        let hintOrigin = morphStartFrame ?? placement(at: pointer, size: morphStartSize)
        // Icon center is 14 + 19 / 2 points from the leading edge.
        let anchored = cocoa(CGRect(x: pointer.x - 23.5, y: pointer.y - 30, width: size.width, height: 48))
        let origin = CGPoint(x: hintOrigin.minX + (anchored.minX - hintOrigin.minX) * p,
                             y: hintOrigin.minY + (anchored.minY - hintOrigin.minY) * p)
        let rect = CGRect(origin: origin, size: size)
        if badge.frame != rect {
            if animated { badge.animator().frame = rect } else { badge.frame = rect }
        }
        layout(size)
        copyIcon.frame = CGRect(x: 14, y: 13.5, width: 19, height: 21)
        releaseLabel.frame = CGRect(x: copyIcon.frame.maxX + 7, y: 15, width: max(0, size.width - 48), height: 18)
        let releaseOpacity = min(1, max(0, (p - 0.2) / 0.6))
        if animated { releaseLabel.animator().alphaValue = releaseOpacity }
        else { releaseLabel.alphaValue = releaseOpacity }
        hint.alphaValue = max(0, 1 - p * 2)
        copyIcon.alphaValue = min(1, max(0, (p - 0.2) / 0.6))
    }
    func move(to point: CGPoint) {
        guard !completing else { return }
        pointer = point
        updateScreen(at: point)
        if dragging { updateDragShape() }
        else {
            let rect = placement(at: point, size: size)
            if badge.frame != rect { badge.frame = rect }
        }
    }
    private func configureHint(text: String, symbol: String) {
        let displayText = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        if label.stringValue != displayText { label.stringValue = displayText }
        if currentSymbol != symbol {
            currentSymbol = symbol
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }
    func show(at point: CGPoint, text: String, symbol: String = "cursorarrow", centeredOnPointer: Bool = false) {
        guard !dragging, !completing else { return }
        configureHint(text: text, symbol: symbol)
        size = CGSize(width: min(280, max(64, ceil(label.intrinsicContentSize.width) + 51)), height: 48)
        if centeredOnPointer {
            pointer = point; updateScreen(at: point)
            let screens = NSScreen.screens.map { cocoa($0.visibleFrame) }
            let screen = screens.first(where: { $0.contains(point) }) ?? screens.first ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            badge.frame = cocoa(selectedTextHintFrame(at: point, size: size, screen: screen))
        } else { move(to: point) }
        layout(size)
        let appearing = badge.isHidden
        // First presentation must contain visible glass, not a zero-opacity material
        // whose backdrop registration can be deferred until a later geometry change.
        let fade = appearing && panel.isVisible
        if appearing { badge.alphaValue = fade ? 0 : 1 }
        badge.isHidden = false; presentScene()
        if fade { animate(0.10, { self.badge.animator().alphaValue = 1 }) }
    }
    var dragHintText: String { label.stringValue }
    var dragHintFrame: CGRect? {
        guard panel.isVisible, !badge.isHidden, badge.alphaValue > 0 else { return nil }
        return cocoa(badge.frame)
    }
    func liftBufferItem(from frame: CGRect, at point: CGPoint, title: String, symbol: String) {
        // Configure while hidden. show() would order the glass at its ordinary
        // pointer placement before collapse can seed the actual slot geometry.
        configureHint(text: title, symbol: symbol)
        updateScreen(at: point)
        collapse(from: frame, to: point, symbol: symbol, startingInSlot: true)
    }
    func liftSelectedTextHint(from frame: CGRect, at point: CGPoint, text: String) {
        configureHint(text: text, symbol: "text.alignleft")
        updateScreen(at: point)
        collapse(from: frame, to: point, symbol: "text.alignleft", startingInSlot: true)
    }
    func collapse(from frame: CGRect, to point: CGPoint, symbol: String, startingInSlot: Bool = false) {
        haptics.startDrag()
        let selectedViews = blockOutlines.filter { !$0.isHidden }
        let sourceFrame = startingInSlot ? cocoa(frame) : (outline.isHidden ? cocoa(frame.insetBy(dx: -6, dy: -6)) : outline.frame)
        dragging = true; pointer = point
        NSCursor.closedHand.set()
        releaseLabel.stringValue = "Drag"
        morphTimer?.invalidate()
        morphStartSize = startingInSlot ? frame.size : size
        morphStartFrame = startingInSlot ? sourceFrame : nil
        morphProgress = 0
        badge.isHidden = false; badge.alphaValue = 1
        updateDragShape()
        let token = animationGeneration
        let morphDuration = CapturePreferences.animationDuration(0.42)
        if morphDuration == 0 {
            morphProgress = 1; updateDragShape()
        } else {
            let start = ProcessInfo.processInfo.systemUptime
            morphTimer = AnimationFrames(screen: panel.screen) { [weak self] in
                guard let self, self.animationGeneration == token, self.dragging, !self.completing else { return false }
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let t = min(1, elapsed / morphDuration)
                // Damped settling makes the single native glass surface contract like liquid.
                self.morphProgress = t == 1 ? 1 : CGFloat(1 - exp(-7 * t) * cos(8 * t))
                self.updateDragShape()
                if t == 1 { self.morphTimer = nil }
                return t < 1
            }
        }
        if startingInSlot {
            // The badge itself lifts from the slot. A second collapsing outline
            // would leave an empty glass hint at the original press location.
            sourceCollapsing = false
            outline.isHidden = true; clearBlockHighlights(); presentScene()
            return
        }
        let end = cocoa(CGRect(x: point.x - 23.5, y: point.y - 30, width: 90, height: 48))
        outline.frame = sourceFrame
        outline.alphaValue = 1; outline.isHidden = false; presentScene()
        sourceCollapsing = true
        animate(0.28, {
            self.outline.animator().frame = end
            self.outline.animator().alphaValue = 0
            for view in selectedViews {
                view.animator().frame = end
                view.animator().alphaValue = 0
            }
        }, completion: { [weak self] in
            guard let self, self.animationGeneration == token, self.sourceCollapsing else { return }
            self.sourceCollapsing = false; self.outline.isHidden = true; self.clearBlockHighlights()
        })
    }
    func parkInBuffer(_ frame: CGRect, title: String, symbol: String, completion: @escaping () -> Void) {
        haptics.drop()
        completing = true; dragging = false; sourceCollapsing = false
        morphTimer?.invalidate(); morphTimer = nil
        let token = animationGeneration
        let destination = cocoa(frame)
        label.stringValue = title.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        currentSymbol = symbol
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let oldCopyFrame = copyIcon.frame
        layout(frame.size)
        copyIcon.frame = oldCopyFrame
        hint.alphaValue = 0
        badge.alphaValue = 1; badge.isHidden = false
        highlightBufferSlot(frame)
        presentScene()
        // Both clear glass surfaces live in the same native container. Moving
        // the tile into the bounded slot lets AppKit merge them as they meet.
        animate(0.30, {
            self.badge.animator().frame = destination
            self.hint.animator().alphaValue = 1
            self.copyIcon.animator().alphaValue = 0
            self.releaseLabel.animator().alphaValue = 0
            self.outline.animator().alphaValue = 0
        }, completion: { [weak self] in
            guard let self, self.animationGeneration == token else { return }
            self.completing = false; self.outline.isHidden = true
            // Reveal the saved preview beneath the settled glass before removing
            // the capture scene, so there is no empty-slot flash on handoff.
            completion()
            self.badge.isHidden = true
            self.endCapture(); self.panel.orderOut(nil)
        })
    }
    func absorb(into frame: CGRect, completion: @escaping () -> Void) {
        haptics.drop()
        completing = true; dragging = false
        morphTimer?.invalidate(); morphTimer = nil
        let token = animationGeneration
        // Collapse at the pointer, rather than implying insertion at the field's center.
        let destination = CGRect(x: badge.frame.midX - 4, y: badge.frame.midY - 4, width: 8, height: 8)
        animate(0.12, {
            self.badge.animator().frame = destination
            self.badge.animator().alphaValue = 0
            self.outline.animator().alphaValue = 0
        }, completion: { [weak self] in
            guard let self, self.animationGeneration == token else { return }
            self.completing = false; self.sourceCollapsing = false
            self.outline.isHidden = true; self.badge.isHidden = true
            self.endCapture()
            self.panel.orderOut(nil)
            // Delivery can only start after all overlay surfaces are gone.
            completion()
        })
    }
    func dismiss(toward frame: CGRect? = nil) {
        haptics.reset()
        // Explicit cancellation also invalidates a pending drop animation.
        completing = false
        animationGeneration += 1; dragging = false; sourceCollapsing = false
        morphTimer?.invalidate(); morphTimer = nil
        outline.isHidden = true; outline.alphaValue = 1; clearBlockHighlights()
        let token = animationGeneration
        animate(0.12, { self.badge.animator().alphaValue = 0 }, completion: { [weak self] in
            guard let self, self.animationGeneration == token else { return }
            self.hideSceneIfIdle()
        })
    }
}
