import AppKit
import QuartzCore
import ApplicationServices
import UserNotifications

/// A local, repeatable introduction. Closing before Get Started quits the app.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let completedKey = "onboardingCompletedV1"
    private static let updatesStep = 4
    private static let finalStep = OnboardingSession.finalStep
    private let onMenuBarVisibilityChange: (Bool) -> Void
    private let onIncompleteClose: () -> Void
    private let launchAtLoginView: LaunchAtLoginView
    private let isAccessibilityGranted: () -> Bool
    private let readNotificationAuthorization: (@escaping (UNAuthorizationStatus) -> Void) -> Void
    private var session = OnboardingSession()
    private var step: Int {
        get { session.step }
        set { session.step = newValue }
    }
    private var transitioning = false
    private var transitionGeneration = OnboardingTransitionGeneration()
    private var waitingForAccessibility = false
    private let notificationStatus = NSTextField(labelWithString: "")
    private let notificationPermissionButton = NSButton(title: "Allow Notifications…", target: nil, action: nil)
    private var notificationsDenied = false
    private var notificationRequestPending = false
    private var shortcutRecorder: ShortcutRecorderView?
    private var permissionTimer: Timer?
    private let heading = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let body = NSView(frame: NSRect(x: 40, y: 96, width: 880, height: 110))
    private let product = OnboardingVideoView(frame: .zero)
    private let contrast = NSView()
    private let contentScroll = NSScrollView()
    private let pageContent = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 644))
    private let pageIcon = AppIconView()
    private let menuBarGuide = OnboardingMenuBarGuide(frame: NSRect(x: 40, y: 562, width: 880, height: 82))
    private let progress = NSTextField(labelWithString: "")
    private let next = NSButton(title: "Continue", target: nil, action: nil)
    private let back = NSButton(title: "Back", target: nil, action: nil)
    private let permissionStatus = NSTextField(labelWithString: "")
    private let accessibilitySwitch = NSSwitch()

    init(onMenuBarVisibilityChange: @escaping (Bool) -> Void = { _ in },
         onIncompleteClose: @escaping () -> Void = { NSApp.terminate(nil) },
         launchAtLogin: LaunchAtLoginController = LaunchAtLoginController(),
         isAccessibilityGranted: @escaping () -> Bool = AXIsProcessTrusted,
         readNotificationAuthorization: @escaping (@escaping (UNAuthorizationStatus) -> Void) -> Void = { completion in
             UNUserNotificationCenter.current().getNotificationSettings { completion($0.authorizationStatus) }
         }) {
        self.readNotificationAuthorization = readNotificationAuthorization
        self.isAccessibilityGranted = isAccessibilityGranted
        self.launchAtLoginView = LaunchAtLoginView(frame: NSRect(x: 0, y: 0, width: 880, height: 76), leadingInset: 62, controller: launchAtLogin)
        self.onMenuBarVisibilityChange = onMenuBarVisibilityChange
        self.onIncompleteClose = onIncompleteClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Welcome to Drag 2.0"
        // The video and its contrast layer are always dark. Apply the same
        // appearance to controls and labels, including the footer and cards.
        window.appearance = NSAppearance(named: .darkAqua)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 960, height: 500)
        window.contentMaxSize = NSSize(width: 960, height: 1000)
        super.init(window: window)
        window.delegate = self
        guard let root = window.contentView else { return }
        product.frame = root.bounds
        product.autoresizingMask = [.width, .height]
        root.addSubview(product)
        // A light extra backdrop blur softens the video without blurring content.
        let backgroundBlur = NSVisualEffectView(frame: root.bounds)
        backgroundBlur.blendingMode = .withinWindow
        backgroundBlur.material = .hudWindow
        backgroundBlur.state = .active
        backgroundBlur.appearance = NSAppearance(named: .darkAqua)
        backgroundBlur.alphaValue = 0.5
        backgroundBlur.autoresizingMask = [.width, .height]
        root.addSubview(backgroundBlur)
        if #available(macOS 26.0, *) {
            let overlay = NSGlassEffectView(frame: root.bounds)
            overlay.style = .regular
            overlay.appearance = NSAppearance(named: .darkAqua)
            overlay.tintColor = nil
            overlay.cornerRadius = 0
            overlay.autoresizingMask = [.width, .height]
            root.addSubview(overlay)
        }
        // Native glass changes its tint when the window resigns key. Keep
        // contrast independent of that state, above glass and below all content.
        contrast.frame = root.bounds
        contrast.wantsLayer = true
        contrast.layer?.backgroundColor = NSColor.black.cgColor
        contrast.alphaValue = 0.64
        contrast.autoresizingMask = [.width, .height]
        root.addSubview(contrast)
        contentScroll.frame = NSRect(x: 0, y: 82, width: 960, height: 644)
        contentScroll.autoresizingMask = [.width, .height]
        contentScroll.drawsBackground = false
        contentScroll.hasVerticalScroller = true
        contentScroll.autohidesScrollers = true
        contentScroll.documentView = pageContent
        root.addSubview(contentScroll)
        pageIcon.frame = NSRect(x: 432, y: 452, width: 96, height: 96)
        pageContent.addSubview(pageIcon)
        pageContent.addSubview(menuBarGuide)
        heading.frame = NSRect(x: 40, y: 643, width: 880, height: 46)
        heading.font = .systemFont(ofSize: 36, weight: .semibold)
        detail.frame = NSRect(x: 40, y: 588, width: 880, height: 42)
        detail.font = .systemFont(ofSize: 15)
        detail.textColor = .secondaryLabelColor
        pageContent.addSubview(heading)
        pageContent.addSubview(detail)
        pageContent.addSubview(body)
        progress.frame = NSRect(x: 40, y: 38, width: 180, height: 22)
        progress.textColor = .secondaryLabelColor
        root.addSubview(progress)
        back.frame = NSRect(x: 692, y: 30, width: 90, height: 32)
        back.bezelStyle = .rounded
        back.target = self; back.action = #selector(previous)
        root.addSubview(back)
        next.frame = NSRect(x: 790, y: 30, width: 126, height: 32)
        next.bezelStyle = .rounded
        next.keyEquivalent = "\r"
        next.target = self; next.action = #selector(advance)
        root.addSubview(next)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        cancelTransition()
        session = OnboardingSession()
        onMenuBarVisibilityChange(false)
        contrast.alphaValue = 0.64
        render()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        product.setActive(true)
    }

    @discardableResult
    private func row(_ title: String, _ text: String, symbol: String, y: CGFloat,
                     detailLabel: NSTextField? = nil) -> NSView {
        let box = NSView(frame: NSRect(x: 0, y: y, width: 880, height: 76))
        let surface: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: box.bounds)
            glass.style = .regular
            glass.cornerRadius = 20
            surface = glass
        } else {
            let material = NSVisualEffectView(frame: box.bounds)
            material.material = .hudWindow
            material.blendingMode = .withinWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 20
            material.layer?.masksToBounds = true
            surface = material
        }
        box.addSubview(surface)
        let image = NSImageView(frame: NSRect(x: 20, y: 25, width: 26, height: 26))
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image.contentTintColor = .secondaryLabelColor
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.frame = NSRect(x: 62, y: text.isEmpty && detailLabel == nil ? 29 : 40, width: 610, height: 18)
        let description = detailLabel ?? NSTextField(labelWithString: text)
        description.font = .systemFont(ofSize: 12)
        description.textColor = .secondaryLabelColor
        description.frame = NSRect(x: 62, y: 18, width: 610, height: 18)
        box.addSubview(image)
        box.addSubview(name)
        box.addSubview(description)
        body.addSubview(box)
        return box
    }

    private func render() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        shortcutRecorder?.cancelRecording()
        shortcutRecorder = nil
        body.subviews.forEach { ($0 as? ShortcutRecorderView)?.cancelRecording(); $0.removeFromSuperview() }
        let welcome = step == 0 || step == Self.finalStep
        pageIcon.isHidden = step != 0
        menuBarGuide.setVisible(step == Self.finalStep)
        pageIcon.frame = welcome ? NSRect(x: 432, y: step == Self.finalStep ? 430 : 382, width: 96, height: 96) : NSRect(x: 40, y: 510, width: 64, height: 64)
        heading.alignment = welcome ? .center : .left
        heading.font = .systemFont(ofSize: welcome ? 44 : 32, weight: .semibold)
        heading.frame = NSRect(x: 40, y: welcome ? (step == Self.finalStep ? 342 : 294) : 532, width: 880, height: 64)
        heading.textColor = .white
        detail.alignment = welcome ? .center : .left
        detail.font = .systemFont(ofSize: welcome ? 20 : 16)
        detail.frame = NSRect(x: welcome ? 90 : 40, y: welcome ? (step == Self.finalStep ? 226 : 178) : 452, width: welcome ? 780 : 880, height: 100)
        detail.textColor = NSColor.white.withAlphaComponent(0.88)
        body.frame.origin.y = step == Self.finalStep ? 70 : welcome ? 112 : 20
        contentScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, pageContent.bounds.height - contentScroll.contentSize.height)))
        contentScroll.reflectScrolledClipView(contentScroll.contentView)
        progress.stringValue = "\(step + 1) of \(Self.finalStep + 1)"
        back.isHidden = step == 0
        next.title = step == Self.finalStep ? "Get Started" : "Continue"
        next.isEnabled = true
        switch step {
        case 0:
            heading.stringValue = "Welcome to Drag 2.0"
            detail.stringValue = "Let's fix your copy-paste.\nInstead drag & drop content in one gesture."
        case 1:
            heading.stringValue = "Enable Accessibility"
            detail.stringValue = "Allow Drag 2.0 to read the content you select and insert it into text fields in other apps."
            let accessibilityBox = row("Enable Accessibility", "", symbol: "accessibility", y: 28,
                                       detailLabel: permissionStatus)
            accessibilitySwitch.frame = NSRect(x: 812, y: 26, width: 40, height: 24)
            accessibilitySwitch.target = self
            accessibilitySwitch.action = #selector(requestPermission)
            accessibilitySwitch.setAccessibilityLabel("Enable Accessibility")
            accessibilitySwitch.toolTip = "Manage Drag 2.0’s Accessibility permission in macOS."
            accessibilityBox.addSubview(accessibilitySwitch)
            refreshPermission()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshPermission() }
        case 2:
            heading.stringValue = "Ready when you log in"
            detail.stringValue = "Let Drag 2.0 start automatically when you log in to your Mac.\nThis is optional. You can change it later in General settings."
            let startupBox = row("", "", symbol: "power", y: 28)
            startupBox.addSubview(launchAtLoginView)
            launchAtLoginView.refresh()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.launchAtLoginView.refresh() }
        case 3:
            heading.stringValue = "Choose your shortcut"
            detail.stringValue = "Keep Option + Command, or choose a combination that feels natural.\nClick the shortcut field, press your keys, then release them."
            let shortcutBox = row("Trigger Shortcut", "", symbol: "keyboard", y: 28)
            let recorder = ShortcutRecorderView(onChange: {})
            recorder.frame.origin = NSPoint(x: 636, y: 38 - recorder.controlCenterY)
            shortcutBox.addSubview(recorder)
            shortcutRecorder = recorder
        case 4:
            heading.stringValue = "Hear about updates"
            detail.stringValue = "Get a notification when a new version is available.\nYou choose when to download and install it."
            let notificationBox = row("Notify about updates", "", symbol: "bell", y: 28,
                                      detailLabel: notificationStatus)
            notificationStatus.frame.size.width = 560
            notificationPermissionButton.frame = NSRect(x: 642, y: 23, width: 220, height: 30)
            notificationPermissionButton.bezelStyle = .rounded
            notificationPermissionButton.target = self
            notificationPermissionButton.action = #selector(requestNotifications)
            notificationBox.addSubview(notificationPermissionButton)
            refreshNotifications()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshNotifications() }
        default:
            heading.stringValue = "You’re all set"
            detail.stringValue = "Hold \(CaptureShortcut.current.title), select your content, and drag it into a text field."
            let settingsTitle = NSTextField(labelWithString: "There’s more in Settings")
            settingsTitle.frame = NSRect(x: 0, y: 88, width: 880, height: 22)
            settingsTitle.alignment = .center
            settingsTitle.font = .systemFont(ofSize: 15, weight: .medium)
            settingsTitle.textColor = .white
            body.addSubview(settingsTitle)
            let categories = row("", "", symbol: "", y: 0)
            categories.frame = NSRect(x: 200, y: 0, width: 480, height: 76)
            categories.subviews.first?.frame = categories.bounds
            let items = [("Behaviour", "slider.horizontal.3"), ("Appearance", "paintpalette"), ("Experimental", "flask")]
            for (index, item) in items.enumerated() {
                let x = CGFloat(index) * 160
                let icon = NSImageView(frame: NSRect(x: x + 68, y: 43, width: 24, height: 24))
                icon.image = NSImage(systemSymbolName: item.1, accessibilityDescription: nil)
                icon.contentTintColor = .labelColor
                categories.addSubview(icon)
                let title = NSTextField(labelWithString: item.0)
                title.frame = NSRect(x: x, y: 13, width: 160, height: 22)
                title.alignment = .center
                title.font = .systemFont(ofSize: 14, weight: .medium)
                categories.addSubview(title)
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = welcome ? .center : .left
        paragraph.minimumLineHeight = welcome ? 36 : 30
        paragraph.maximumLineHeight = welcome ? 36 : 30
        paragraph.lineBreakMode = .byWordWrapping
        detail.attributedStringValue = NSAttributedString(string: detail.stringValue, attributes: [
            .font: NSFont.systemFont(ofSize: welcome ? 20 : 16),
            .foregroundColor: NSColor.white.withAlphaComponent(0.88),
            .paragraphStyle: paragraph
        ])
        layoutWelcomeComposition()
    }
    func windowDidResize(_ notification: Notification) { layoutWelcomeComposition() }

    private func layoutWelcomeComposition() {
        guard step == 0 || step == Self.finalStep else {
            pageContent.frame.size.height = 644
            contentScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, 644 - contentScroll.contentSize.height)))
            contentScroll.reflectScrolledClipView(contentScroll.contentView)
            return
        }
        let height = contentScroll.contentSize.height
        pageContent.frame.size.height = height
        let compact = height < 560
        let shift = (height - 644) / 2
        if compact {
            let layout = CompactOnboardingComposition(height: height, finalPage: step == Self.finalStep)
            heading.frame.origin.y = layout.headingY
            heading.frame.size.height = 54
            heading.font = .systemFont(ofSize: 36, weight: .semibold)
            detail.frame.origin.y = layout.detailY
            detail.frame.size.height = 72
            pageIcon.frame = NSRect(x: 448, y: layout.iconY, width: 64, height: 64)
            body.frame.origin.y = layout.bodyY
        } else {
            heading.frame = NSRect(x: 40, y: (step == Self.finalStep ? 342 : 294) + shift, width: 880, height: 64)
            heading.font = .systemFont(ofSize: 44, weight: .semibold)
            detail.frame.origin.y = (step == Self.finalStep ? 226 : 178) + shift
            detail.frame.size.height = 100
            pageIcon.frame = NSRect(x: 432, y: 382 + shift, width: 96, height: 96)
            body.frame.origin.y = (step == Self.finalStep ? 70 : 112) + shift
        }
        menuBarGuide.frame.origin.y = height - 82
        contentScroll.contentView.scroll(to: .zero)
        contentScroll.reflectScrolledClipView(contentScroll.contentView)
    }

    static func permissionStatusText(granted: Bool) -> String {
        granted ? "Accessibility is enabled." : "Enable Drag 2.0 in System Settings."
    }
    private func refreshPermission() {
        let granted = isAccessibilityGranted()
        permissionStatus.stringValue = Self.permissionStatusText(granted: granted)
        permissionStatus.textColor = granted ? .systemGreen : .secondaryLabelColor
        accessibilitySwitch.state = granted ? .on : .off
        next.isEnabled = granted
        if granted && waitingForAccessibility && step == 1 {
            waitingForAccessibility = false
            transition(to: 2)
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        product.setActive(true)
        }
    }
    @objc private func requestPermission() {
        let granted = isAccessibilityGranted()
        accessibilitySwitch.state = granted ? .on : .off
        if granted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            return
        }
        waitingForAccessibility = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        // Let the macOS alert open Settings; opening it here as well leaves a duplicate alert behind.
    }
    private func refreshNotifications() {
        readNotificationAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self, self.step == Self.updatesStep, !self.notificationRequestPending else { return }
                let authorized = status == .authorized || status == .provisional
                self.notificationsDenied = status == .denied
                self.notificationStatus.stringValue = authorized ? "Notifications allowed in macOS." : "Notifications are not allowed in macOS."
                self.notificationPermissionButton.isEnabled = !authorized
                self.notificationPermissionButton.title = authorized ? "Notifications Allowed" :
                    (self.notificationsDenied ? "Open Notification Settings…" : "Allow Notifications…")
            }
        }
    }
    @objc private func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.maximkich.drop-to-t3")!)
    }
    @objc private func requestNotifications() {
        if notificationsDenied {
            openNotificationSettings()
            return
        }
        notificationRequestPending = true
        notificationPermissionButton.isEnabled = false
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.notificationRequestPending = false
                self.notificationPermissionButton.isEnabled = true
                guard self.step == Self.updatesStep else { return }
                // Read the OS state without changing the user's automatic-check intent.
                self.refreshNotifications()
                if let error { NSLog("Notification authorization: %@", String(describing: error)) }
            }
        }
    }

    private func transition(to destination: Int) {
        guard !transitioning else { return }
        // Hide immediately when leaving the last page; reveal only after landing.
        if destination != Self.finalStep { onMenuBarVisibilityChange(false) }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            contrast.alphaValue = (destination == 0 || destination == Self.finalStep) ? 0.64 : 0.40
            step = destination; render()
            onMenuBarVisibilityChange(session.showsMenuBarIcon)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.52
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            contrast.animator().alphaValue = (destination == 0 || destination == Self.finalStep) ? 0.64 : 0.40
        }
        let generation = transitionGeneration.begin()
        let direction: CGFloat = destination > step ? 1 : -1
        let distance = contentScroll.frame.width
        contentScroll.wantsLayer = true
        transitioning = true
        next.isEnabled = false
        back.isEnabled = false
        permissionTimer?.invalidate()
        slideContent(from: 0, to: -direction * distance, duration: 0.20, timing: .easeIn) { [weak self] in
            guard let self, self.transitionGeneration.accepts(generation) else { return }
            self.step = destination
            self.render()
            let nextEnabled = self.next.isEnabled
            self.next.isEnabled = false
            // Explicit start and end positions prevent AppKit from coalescing
            // the offscreen placement with the incoming animation.
            self.slideContent(from: direction * distance, to: 0, duration: 0.32, timing: .easeOut) { [weak self] in
                guard let self, self.transitionGeneration.accepts(generation) else { return }
                self.contentScroll.layer?.removeAnimation(forKey: "onboardingSlide")
                self.transitioning = false
                self.next.isEnabled = nextEnabled
                self.back.isEnabled = true
                self.onMenuBarVisibilityChange(self.session.showsMenuBarIcon)
            }
        }
    }
    private func slideContent(from start: CGFloat, to end: CGFloat, duration: TimeInterval,
                              timing: CAMediaTimingFunctionName, completion: @escaping () -> Void) {
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = start
        animation.toValue = end
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = end == 0 ? 0 : 1
        opacity.toValue = end == 0 ? 1 : 0
        animation.duration = duration
        opacity.duration = duration
        let transition = CAAnimationGroup()
        transition.animations = [animation, opacity]
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: timing)
        transition.fillMode = .forwards
        transition.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        contentScroll.layer?.add(transition, forKey: "onboardingSlide")
        CATransaction.commit()
    }

    private func cancelTransition() {
        transitionGeneration.invalidate()
        transitioning = false
        contentScroll.layer?.removeAnimation(forKey: "onboardingSlide")
        contrast.layer?.removeAllAnimations()
        shortcutRecorder?.cancelRecording()
        waitingForAccessibility = false
    }
    @objc private func previous() { transition(to: max(0, step - 1)) }
    @objc private func advance() {
        guard !transitioning else { return }
        if step == 1 && !isAccessibilityGranted() { refreshPermission(); return }
        if step == Self.finalStep {
            guard session.finish() else { return }
            UserDefaults.standard.set(true, forKey: Self.completedKey)
            close()
        } else { transition(to: step + 1) }
    }
    func windowWillMiniaturize(_ notification: Notification) { product.setActive(false) }
    func windowDidDeminiaturize(_ notification: Notification) { product.setActive(true) }
    func windowWillClose(_ notification: Notification) {
        cancelTransition()
        product.setActive(false)
        permissionTimer?.invalidate()
        permissionTimer = nil
        if session.shouldQuitOnClose { onIncompleteClose() }
    }
}

/// A quiet directional cue, using the same template icon as the status item.
private final class OnboardingMenuBarGuide: NSView {
    private let badge = NSView(frame: NSRect(x: 844, y: 40, width: 36, height: 36))

    override init(frame: NSRect) {
        super.init(frame: frame)
        alphaValue = 0.65
        let label = NSTextField(labelWithString: "Drag 2.0 is ready in your menu bar")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        label.frame.origin = NSPoint(x: badge.frame.minX - 8 - label.frame.width,
                                     y: badge.frame.midY - label.frame.height / 2)
        addSubview(label)
        badge.wantsLayer = true
        let icon = NSImageView(frame: NSRect(x: 1, y: 1, width: 34, height: 34))
        icon.image = MenuBarIcon.image
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .white
        badge.addSubview(icon)
        addSubview(badge)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setVisible(_ visible: Bool) {
        isHidden = !visible
        badge.layer?.removeAnimation(forKey: "menuBarJiggle")
        guard visible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        // Swing around the badge's top center, like a hanging bell.
        if let layer = badge.layer {
            let frame = layer.frame
            layer.anchorPoint = CGPoint(x: 0.5, y: 1)
            layer.frame = frame
        }
        let jiggle = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        jiggle.values = [0, -0.14, 0.14, -0.09, 0.06, 0, 0]
        jiggle.keyTimes = [0, 0.08, 0.18, 0.28, 0.38, 0.48, 1]
        jiggle.duration = 1.8
        jiggle.repeatCount = .infinity
        jiggle.calculationMode = .cubic
        badge.layer?.add(jiggle, forKey: "menuBarJiggle")
    }
}
