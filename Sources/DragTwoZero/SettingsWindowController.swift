import AppKit
import ApplicationServices
import UniformTypeIdentifiers
import UserNotifications

private final class AttributionLinkField: NSTextField {
    override func resetCursorRects() {
        super.resetCursorRects()
        let text = attributedStringValue
        let range = (text.string as NSString).range(of: "Maxim Kich")
        guard range.location != NSNotFound else { return }
        let prefix = text.attributedSubstring(from: NSRange(location: 0, length: range.location)).size().width
        let linkWidth = text.attributedSubstring(from: range).size().width
        let textWidth = text.size().width
        let paragraph = text.length > 0 ? text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil
        let origin = paragraph?.alignment == .center ? (bounds.width - textWidth) / 2 : 0
        let rect = NSRect(x: origin + prefix,
                          y: 0, width: linkWidth, height: bounds.height)
        addCursorRect(rect, cursor: .pointingHand)
    }
}

private final class SettingsPageView: NSView {
    override var isFlipped: Bool { true }
}

enum SettingsSection: String, CaseIterable {
    case general = "General", behaviour = "Behaviour"
    case appearance = "Appearance", experimental = "Experimental", about = "About"

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .behaviour: return "slider.horizontal.3"
        case .appearance: return "paintpalette"
        case .experimental: return "flask"
        case .about: return "info.circle"
        }
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let onStructureChange: () -> Void
    private let onAppearanceChange: () -> Void
    private let onBufferChange: () -> Void
    private let bufferPositionControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let bufferSwitch = NSSwitch()
    private let bufferPositionLabel = NSTextField(labelWithString: "Position of buffer")
    private let onActivationChange: (Bool) -> Void
    private let isActive: () -> Bool
    private let activationSwitch = NSSwitch()
    private let dockIconSwitch = NSSwitch()
    private let launchAtLoginView: LaunchAtLoginView
    private let isAccessibilityGranted: () -> Bool
    private let accessibilityButton = NSButton(title: "Open System Settings…", target: nil, action: nil)
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private var accessibilityTimer: Timer?
    private let multiselectInfoPopover = NSPopover()
    private let selectedTextInfoPopover = NSPopover()
    private let updateButton = NSButton()
    private let cancelUpdateButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let updateStatus = NSTextField(labelWithString: "")
    private var showsUpdateStatus = false
    private let updateCheckSwitch = NSSwitch()
    private let debugLogButton = NSButton(title: "Export Debug Log…", target: nil, action: nil)
    private let debugLogStatus = NSTextField(labelWithString: "Local diagnostics only. Nothing is sent automatically.")
    private let animations = AnimationSettingsView()
    private let navigation = NSTableView()
    private let pageNames = SettingsSection.allCases.map(\.rawValue)
    private var pages: [NSView] = []
    private var pageScrollViews: [NSScrollView] = []
    private var hasLaidOutPages = false

    init(onStructureChange: @escaping () -> Void, onAppearanceChange: @escaping () -> Void,
         isActive: @escaping () -> Bool, onActivationChange: @escaping (Bool) -> Void,
         onBufferChange: @escaping () -> Void = {},
         launchAtLogin: LaunchAtLoginController = LaunchAtLoginController(),
         isAccessibilityGranted: @escaping () -> Bool = AXIsProcessTrusted) {
        self.isAccessibilityGranted = isAccessibilityGranted
        self.launchAtLoginView = LaunchAtLoginView(frame: NSRect(x: 0, y: 0, width: 592, height: 64), controller: launchAtLogin)
        self.isActive = isActive
        self.onActivationChange = onActivationChange
        self.onStructureChange = onStructureChange
        self.onAppearanceChange = onAppearanceChange
        self.onBufferChange = onBufferChange
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Drag 2.0"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Native unified toolbar spacing keeps the traffic lights comfortably
        // inside the inset sidebar instead of against its rounded edge.
        let toolbar = NSToolbar(identifier: "SettingsHeader")
        toolbar.showsBaselineSeparator = false
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: 860, height: 420)
        window.contentMaxSize = NSSize(width: 860, height: 1200)
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.managed, .primary, .fullScreenPrimary]
        super.init(window: window)
        window.delegate = self
        buildContent()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshUpdates), name: UpdateChecker.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshAccessibility), name: NSApplication.didBecomeActiveNotification, object: NSApp)
        refreshUpdates()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func presentAbout() {
        present()
        navigation.selectRowIndexes(IndexSet(integer: SettingsSection.allCases.firstIndex(of: .about)!), byExtendingSelection: false)
        tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
    }

    func present() {
        refreshActivation()
        refreshBuffer()
        animations.refresh()
        dockIconSwitch.state = AppPresentationPreferences.hidesDockIcon() ? .on : .off
        AppPresentationPreferences.applyDockVisibility()
        refreshAccessibility()
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshAccessibility()
        }
        // Accessory apps may not receive the activation/Space combination a
        // regular app does. Never leave an invisible key window waiting for it.
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        alignPageContentWithSidebar()
    }

    func windowWillClose(_ notification: Notification) {
        DebugLog.shared.record(.action(.settingsClosed))
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        showsUpdateStatus = false
        refreshUpdates()
        AppPresentationPreferences.applyDockVisibility()
    }

    func alignPageContentWithSidebar() {
        guard !hasLaidOutPages, let root = window?.contentView else { return }
        root.layoutSubtreeIfNeeded()
        let rowTop = navigation.convert(navigation.rect(ofRow: 0), to: root).maxY
        for (index, page) in pages.enumerated() {
            guard let title = page.subviews.compactMap({ $0 as? NSTextField }).first else { continue }
            let viewport = pageScrollViews[index]
            let inset = max(0, viewport.frame.maxY - rowTop)
            let titleTop = title.frame.maxY
            // Convert the existing bottom-origin layout into a top-origin
            // scrolling document, keeping its spacing and sidebar alignment.
            for item in page.subviews {
                item.frame.origin.y = inset + titleTop - item.frame.maxY
            }
            let bottom = page.subviews.map { $0.frame.maxY }.max() ?? 0
            page.frame.size.height = max(viewport.contentSize.height, bottom + 24)
            viewport.contentView.scroll(to: .zero)
            viewport.reflectScrolledClipView(viewport.contentView)
        }
        hasLaidOutPages = true
    }

    private func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat,
                       size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: size >= 15 ? .semibold : .regular)
        field.frame = NSRect(x: x, y: y, width: width, height: max(22, ceil(field.intrinsicContentSize.height)))
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        return field
    }

    private func card(_ frame: NSRect) -> NSBox {
        settingsOutlineCard(frame)
    }

    private func feedbackButton(at origin: NSPoint) -> NSButton {
        let button = NSButton(title: "Send feedback", target: self, action: #selector(openFeedback))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.frame = NSRect(origin: origin, size: NSSize(width: 144, height: 32))
        button.setAccessibilityLabel("Send feedback on GitHub")
        button.toolTip = "Report a problem or suggest an improvement on GitHub."
        return button
    }

    private func buildContent() {
        guard let root = window?.contentView else { return }
        let sidebarFrame = NSRect(x: 8, y: 8, width: 204, height: root.bounds.height - 16)
        let sidebarContent = NSView(frame: NSRect(origin: .zero, size: sidebarFrame.size))
        sidebarContent.autoresizingMask = [.width, .height]
        let sidebar: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: sidebarFrame)
            glass.style = .regular
            glass.cornerRadius = 20
            glass.contentView = sidebarContent
            sidebar = glass
        } else {
            let effect = NSVisualEffectView(frame: sidebarFrame)
            effect.material = .sidebar
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 20
            effect.layer?.masksToBounds = true
            effect.addSubview(sidebarContent)
            sidebar = effect
        }
        sidebar.autoresizingMask = [.height]
        root.addSubview(sidebar)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 204, height: 500))
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.height]
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        column.width = 204
        navigation.addTableColumn(column)
        navigation.headerView = nil
        navigation.rowHeight = 34
        navigation.intercellSpacing = NSSize(width: 0, height: 4)
        navigation.style = .sourceList
        navigation.backgroundColor = .clear
        navigation.dataSource = self
        navigation.delegate = self
        scroll.documentView = navigation
        sidebarContent.addSubview(scroll)
        pages = SettingsSection.allCases.map { _ in SettingsPageView(frame: NSRect(x: 0, y: 0, width: 640, height: 560)) }
        pageScrollViews = pages.map { page in
            let viewport = NSScrollView(frame: NSRect(x: 220, y: 12, width: 640, height: root.bounds.height - 64))
            viewport.autoresizingMask = [.height]
            viewport.drawsBackground = false
            viewport.hasVerticalScroller = true
            viewport.hasHorizontalScroller = false
            viewport.autohidesScrollers = true
            viewport.scrollerStyle = .overlay
            viewport.documentView = page
            viewport.isHidden = true
            root.addSubview(viewport)
            return viewport
        }
        let windowHeading = label("Drag 2.0", x: 248, y: root.bounds.height - 37, width: 584)
        windowHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        windowHeading.autoresizingMask = [.minYMargin]
        root.addSubview(windowHeading)
        let general = pages[0], behaviour = pages[1]
        let appearance = pages[2], experimental = pages[3], about = pages[4]
        general.addSubview(label("General", x: 28, y: 494, width: 560, size: 24))
        let activationCard = card(NSRect(x: 24, y: 396, width: 592, height: 64))
        general.addSubview(activationCard)
        let activationLabel = label("Activate", x: 16, y: 21, width: 470)
        activationSwitch.frame = NSRect(x: 528, y: 20, width: 40, height: 24)
        activationSwitch.target = self
        activationSwitch.action = #selector(activationChanged(_:))
        activationSwitch.setAccessibilityLabel("Activate")
        refreshActivation()
        activationCard.contentView?.addSubview(activationLabel)
        activationCard.contentView?.addSubview(activationSwitch)
        alignSettingsLabels([activationLabel], with: activationSwitch)
        let shortcutCard = card(NSRect(x: 24, y: 156, width: 592, height: 64))
        general.addSubview(shortcutCard)
        let shortcutLabel = label("Trigger Shortcut", x: 16, y: 21, width: 280)
        shortcutCard.contentView?.addSubview(shortcutLabel)
        let recorder = ShortcutRecorderView(onChange: onStructureChange)
        recorder.frame.origin = NSPoint(x: 352, y: 16)
        shortcutCard.contentView?.addSubview(recorder)
        alignSettingsLabels([shortcutLabel], centerY: recorder.frame.minY + recorder.controlCenterY)
        behaviour.addSubview(label("Behaviour", x: 28, y: 494, width: 560, size: 24))
        let structureCard = card(NSRect(x: 24, y: 396, width: 592, height: 64))
        let hapticCard = card(NSRect(x: 24, y: 76, width: 592, height: 64))
        behaviour.addSubview(structureCard)
        general.addSubview(hapticCard)
        guard let structureContent = structureCard.contentView,
              let hapticContent = hapticCard.contentView else { return }
        let structureTitle = label("Preserve content structure", x: 16, y: 35, width: 470)
        structureContent.addSubview(structureTitle)
        let structureDetail = label("Keep headings, lists, links, and emphasis as Markdown.", x: 16, y: 12, width: 510, size: 12, secondary: true)
        structureContent.addSubview(structureDetail)
        let structure = NSSwitch(frame: NSRect(x: 528, y: 20, width: 40, height: 24))
        structure.state = CapturePreferences.preserveStructure ? .on : .off
        structure.target = self; structure.action = #selector(structureChanged(_:))
        structure.setAccessibilityLabel("Preserve content structure")
        structureContent.addSubview(structure)
        alignSettingsLabels([structureTitle, structureDetail], with: structure)
        let hapticTitle = label("Haptic feedback", x: 16, y: 35, width: 470)
        hapticContent.addSubview(hapticTitle)
        let hapticDetail = label("Feel selection, drag, and drop on your trackpad.", x: 16, y: 12, width: 510, size: 12, secondary: true)
        hapticContent.addSubview(hapticDetail)
        let haptics = NSSwitch(frame: NSRect(x: 528, y: 20, width: 40, height: 24))
        haptics.state = CapturePreferences.hapticsEnabled ? .on : .off
        haptics.target = self; haptics.action = #selector(hapticsChanged(_:))
        haptics.setAccessibilityLabel("Haptic feedback")
        hapticContent.addSubview(haptics)
        alignSettingsLabels([hapticTitle, hapticDetail], with: haptics)

        let clipboardCard = card(NSRect(x: 24, y: 316, width: 592, height: 64))
        behaviour.addSubview(clipboardCard)
        let clipboardLabel = label("Overwrite clipboard", x: 16, y: 35, width: 470)
        let clipboardDetail = label("Keep successfully dropped content on the clipboard.", x: 16, y: 12, width: 510, size: 12, secondary: true)
        let clipboardSwitch = NSSwitch(frame: NSRect(x: 528, y: 20, width: 40, height: 24))
        clipboardSwitch.state = CapturePreferences.overwriteClipboard ? .on : .off
        clipboardSwitch.target = self
        clipboardSwitch.action = #selector(overwriteClipboardChanged(_:))
        clipboardSwitch.setAccessibilityLabel("Overwrite clipboard")
        let clipboardExplanation = "Paste temporarily uses the clipboard. When off, the previous contents return after confirmed insertion. An unconfirmed paste may leave the captured content available. A newer copy always wins."
        clipboardSwitch.toolTip = clipboardExplanation
        clipboardDetail.toolTip = clipboardExplanation
        clipboardCard.contentView?.addSubview(clipboardLabel)
        clipboardCard.contentView?.addSubview(clipboardDetail)
        clipboardCard.contentView?.addSubview(clipboardSwitch)
        alignSettingsLabels([clipboardLabel, clipboardDetail], with: clipboardSwitch)

        let bufferCard = card(NSRect(x: 24, y: 156, width: 592, height: 144))
        let bufferTitle = label("Buffer", x: 16, y: 115, width: 470)
        let bufferDetail = label("Keep an item above your apps, then drag it into an input.", x: 16, y: 92, width: 510, size: 12, secondary: true)
        bufferSwitch.frame = NSRect(x: 528, y: 100, width: 40, height: 24)
        bufferSwitch.state = CapturePreferences.bufferEnabled ? .on : .off
        bufferSwitch.target = self; bufferSwitch.action = #selector(bufferChanged(_:))
        bufferSwitch.setAccessibilityLabel("Buffer")
        [bufferTitle, bufferDetail, bufferSwitch].forEach { bufferCard.contentView?.addSubview($0) }
        alignSettingsLabels([bufferTitle, bufferDetail], with: bufferSwitch)
        experimental.addSubview(bufferCard)
        let positionTitle = bufferPositionLabel
        positionTitle.frame = NSRect(x: 16, y: 21, width: 280, height: 20)
        bufferPositionControl.frame = NSRect(x: 416, y: 18, width: 157, height: 28)
        bufferPositionControl.addItems(withTitles: BufferPosition.allCases.map(\.title))
        bufferPositionControl.selectItem(at: BufferPosition.allCases.firstIndex(of: CapturePreferences.bufferPosition) ?? 0)
        bufferPositionControl.target = self; bufferPositionControl.action = #selector(bufferPositionChanged)
        bufferPositionControl.setAccessibilityLabel("Position of buffer")
        bufferCard.contentView?.addSubview(positionTitle)
        bufferCard.contentView?.addSubview(bufferPositionControl)
        alignSettingsLabels([positionTitle], with: bufferPositionControl)
        refreshBufferPositionAvailability()
        let dockCard = card(NSRect(x: 24, y: 52, width: 592, height: 64))
        let dockLabel = label("Hide app icon from Dock", x: 16, y: 21, width: 470)
        dockIconSwitch.frame = NSRect(x: 528, y: 20, width: 40, height: 24)
        dockIconSwitch.state = AppPresentationPreferences.hidesDockIcon() ? .on : .off
        dockIconSwitch.target = self
        dockIconSwitch.action = #selector(dockIconChanged(_:))
        dockIconSwitch.setAccessibilityLabel("Hide app icon from Dock")
        dockCard.contentView?.addSubview(dockLabel)
        dockCard.contentView?.addSubview(dockIconSwitch)
        alignSettingsLabels([dockLabel], with: dockIconSwitch)

        let accessibilityCard = card(NSRect(x: 24, y: 316, width: 592, height: 64))
        let accessibilityLabel = label("Accessibility", x: 16, y: 21, width: 350)
        accessibilityButton.target = self
        accessibilityButton.action = #selector(openAccessibilitySettings)
        accessibilityButton.bezelStyle = .rounded
        accessibilityButton.frame = NSRect(x: 400, y: 17, width: 176, height: 30)
        accessibilityButton.setAccessibilityLabel("Manage Accessibility permission")
        accessibilityStatus.frame = NSRect(x: 400, y: 20, width: 176, height: 24)
        accessibilityStatus.font = .systemFont(ofSize: 13)
        accessibilityStatus.alignment = .right
        accessibilityStatus.setAccessibilityLabel("Accessibility permission status")
        [accessibilityLabel, accessibilityStatus, accessibilityButton].forEach { accessibilityCard.contentView?.addSubview($0) }
        alignSettingsLabels([accessibilityLabel], with: accessibilityButton)
        alignSettingsLabels([accessibilityStatus], centerY: accessibilityButton.frame.midY)
        general.addSubview(accessibilityCard)
        let startupCard = card(NSRect(x: 24, y: 236, width: 592, height: 64))
        startupCard.contentView?.addSubview(launchAtLoginView)
        general.addSubview(startupCard)
        refreshAccessibility()

        experimental.addSubview(label("Experimental", x: 28, y: 494, width: 440, size: 24))
        experimental.addSubview(feedbackButton(at: NSPoint(x: 472, y: 492)))
        let multiselectCard = card(NSRect(x: 24, y: 396, width: 592, height: 64))
        experimental.addSubview(multiselectCard)
        let multiselectLabel = label("Multi-select", x: 16, y: 21, width: 110)
        let multiselectSwitch = NSSwitch(frame: NSRect(x: 528, y: 20, width: 40, height: 24))
        multiselectSwitch.state = CapturePreferences.multiselectEnabled ? .on : .off
        multiselectSwitch.target = self
        multiselectSwitch.action = #selector(multiselectChanged(_:))
        multiselectSwitch.setAccessibilityLabel("Multi-select")
        multiselectCard.contentView?.addSubview(multiselectLabel)
        multiselectCard.contentView?.addSubview(multiselectSwitch)
        alignSettingsLabels([multiselectLabel], with: multiselectSwitch)
        multiselectLabel.sizeToFit()
        let info = NSButton(frame: NSRect(x: multiselectLabel.frame.maxX + 4,
                                         y: multiselectLabel.frame.midY - 10, width: 20, height: 20))
        info.isBordered = false
        info.imagePosition = .imageOnly
        info.target = self
        info.action = #selector(showMultiselectInfo(_:))
        info.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "How Multi-select works")
        info.contentTintColor = .secondaryLabelColor
        info.toolTip = "Hold the shortcut and drag from empty space across blocks. Release the shortcut to drag them together."
        info.setAccessibilityHelp(info.toolTip)
        multiselectCard.contentView?.addSubview(info)

        let selectedTextCard = card(NSRect(x: 24, y: 316, width: 592, height: 64))
        experimental.addSubview(selectedTextCard)
        let selectedTextLabel = label("Drag selected text", x: 16, y: 21, width: 180)
        let selectedTextSwitch = NSSwitch(frame: NSRect(x: 528, y: 20, width: 40, height: 24))
        selectedTextSwitch.state = CapturePreferences.selectedTextDraggingEnabled ? .on : .off
        selectedTextSwitch.target = self
        selectedTextSwitch.action = #selector(selectedTextChanged(_:))
        selectedTextSwitch.setAccessibilityLabel("Drag selected text")
        selectedTextCard.contentView?.addSubview(selectedTextLabel)
        selectedTextCard.contentView?.addSubview(selectedTextSwitch)
        alignSettingsLabels([selectedTextLabel], with: selectedTextSwitch)
        selectedTextLabel.sizeToFit()
        let selectedTextInfo = NSButton(frame: NSRect(x: selectedTextLabel.frame.maxX + 4,
            y: selectedTextLabel.frame.midY - 10, width: 20, height: 20))
        selectedTextInfo.isBordered = false
        selectedTextInfo.imagePosition = .imageOnly
        selectedTextInfo.target = self
        selectedTextInfo.action = #selector(showSelectedTextInfo(_:))
        selectedTextInfo.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "How selected-text dragging works")
        selectedTextInfo.contentTintColor = .secondaryLabelColor
        selectedTextInfo.toolTip = "Select text first. Hold the shortcut to show a hint under the pointer, then grab it and drag to an input. After grabbing, you can release the shortcut. Releasing it before grabbing cancels; Escape cancels at any time."
        selectedTextInfo.setAccessibilityHelp(selectedTextInfo.toolTip)
        selectedTextCard.contentView?.addSubview(selectedTextInfo)

        appearance.addSubview(label("Appearance", x: 28, y: 494, width: 560, size: 24))
        let glass = GlassSettingsView { [weak self] in
            self?.onAppearanceChange()
            self?.animations.refresh()
        }
        glass.frame.origin = NSPoint(x: 24, y: 288)
        animations.frame.origin = NSPoint(x: 24, y: 132)
        appearance.addSubview(glass)
        appearance.addSubview(animations)
        appearance.addSubview(dockCard)
        about.addSubview(label("About", x: 28, y: 494, width: 560, size: 24))
        about.addSubview(feedbackButton(at: NSPoint(x: 472, y: 492)))
        let aboutCard = card(NSRect(x: 24, y: 120, width: 592, height: 340))
        about.addSubview(aboutCard)
        let mark = AppIconView(frame: NSRect(x: 246, y: 210, width: 100, height: 100))
        mark.image = AppIcon.image(for: window?.effectiveAppearance ?? NSAppearance(named: .aqua)!)
        mark.imageScaling = .scaleProportionallyUpOrDown
        aboutCard.contentView?.addSubview(mark)
        let name = label("Drag 2.0", x: 16, y: 170, width: 560, size: 24)
        name.alignment = .center
        aboutCard.contentView?.addSubview(name)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
        let versionLabel = label("Version \(version)", x: 16, y: 136, width: 560, secondary: true)
        versionLabel.alignment = .center
        aboutCard.contentView?.addSubview(versionLabel)
        updateButton.frame = NSRect(x: 240, y: 96, width: 112, height: 30)
        updateButton.bezelStyle = .rounded
        updateButton.target = self
        updateButton.action = #selector(updateClicked)
        updateButton.setAccessibilityLabel("Check, install, or restart to update Drag 2.0")
        aboutCard.contentView?.addSubview(updateButton)
        cancelUpdateButton.frame = NSRect(x: 390, y: 96, width: 76, height: 30)
        cancelUpdateButton.bezelStyle = .rounded
        cancelUpdateButton.target = self
        cancelUpdateButton.action = #selector(cancelUpdateClicked)
        aboutCard.contentView?.addSubview(cancelUpdateButton)
        updateStatus.frame = NSRect(x: 16, y: 58, width: 560, height: 32)
        updateStatus.maximumNumberOfLines = 2
        updateStatus.lineBreakMode = .byWordWrapping
        updateStatus.alignment = .center
        updateStatus.font = .systemFont(ofSize: 11)
        updateStatus.textColor = .secondaryLabelColor
        aboutCard.contentView?.addSubview(updateStatus)
        let checksLabel = label("Notify about updates", x: 166, y: 30, width: 200)
        updateCheckSwitch.frame = NSRect(x: 378, y: 29, width: 40, height: 24)
        updateCheckSwitch.target = self
        updateCheckSwitch.action = #selector(updateChecksChanged(_:))
        updateCheckSwitch.setAccessibilityLabel("Notify about updates")
        updateCheckSwitch.toolTip = "Check GitHub at most once a day. Download, installation, and restart require your confirmation."
        aboutCard.contentView?.addSubview(checksLabel)
        aboutCard.contentView?.addSubview(updateCheckSwitch)
        alignSettingsLabels([checksLabel], with: updateCheckSwitch)
        let debugCard = card(NSRect(x: 24, y: 28, width: 592, height: 76))
        debugCard.contentView?.addSubview(label("Debug log", x: 16, y: 42, width: 390, size: 13))
        debugLogStatus.frame = NSRect(x: 16, y: 16, width: 390, height: 20)
        debugLogStatus.font = .systemFont(ofSize: 11)
        debugLogStatus.textColor = .secondaryLabelColor
        debugLogStatus.setAccessibilityLabel("Debug log export status")
        debugCard.contentView?.addSubview(debugLogStatus)
        debugLogButton.frame = NSRect(x: 420, y: 24, width: 156, height: 30)
        debugLogButton.bezelStyle = .rounded
        debugLogButton.target = self
        debugLogButton.action = #selector(exportDebugLog)
        debugLogButton.setAccessibilityLabel("Export Debug Log")
        debugLogButton.toolTip = "Save recent app states and error codes. No captured content, clipboard data, URLs, or user identifiers."
        debugCard.contentView?.addSubview(debugLogButton)
        about.addSubview(debugCard)
        let credit = AttributionLinkField(labelWithString: "")
        credit.frame = NSRect(x: 28, y: -10, width: 230, height: 22)
        credit.isSelectable = true
        credit.allowsEditingTextAttributes = true
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        let attribution = NSMutableAttributedString(string: "Created by Maxim Kich", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ])
        attribution.addAttributes([
            .link: URL(string: "https://github.com/maxim-kich")!,
            .foregroundColor: NSColor.linkColor
        ], range: (attribution.string as NSString).range(of: "Maxim Kich"))
        credit.attributedStringValue = attribution
        credit.frame.size.height = ceil(credit.intrinsicContentSize.height)
        about.addSubview(credit)
        let legalLinks = NSStackView()
        legalLinks.orientation = .horizontal
        legalLinks.spacing = 12
        for (index, title) in ["Website", "Legal & Privacy", "Terms", "Licenses"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(openLegalDocument(_:)))
            button.tag = index
            button.isBordered = false
            button.font = .systemFont(ofSize: 11)
            button.contentTintColor = .secondaryLabelColor
            button.setAccessibilityLabel("Open \(title)")
            legalLinks.addArrangedSubview(button)
        }
        let linksSize = legalLinks.fittingSize
        legalLinks.frame = NSRect(x: aboutCard.frame.maxX - 4 - linksSize.width,
                                  y: credit.frame.midY - linksSize.height / 2,
                                  width: linksSize.width, height: linksSize.height)
        about.addSubview(legalLinks)
        navigation.reloadData()
        navigation.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        pageScrollViews[0].isHidden = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { pageNames.count }
    @objc private func exportDebugLog() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.title = "Export Debug Log"
        panel.message = "Save local diagnostics to review and share with support. No captured content is included, and nothing is sent automatically."
        panel.nameFieldStringValue = "Drag-2.0-Debug-Log.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            self.debugLogButton.isEnabled = false
            self.debugLogStatus.stringValue = "Saving…"
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            DebugLog.shared.export(to: destination, appVersion: version) { [weak self] result in
                self?.debugLogButton.isEnabled = true
                switch result {
                case .success: self?.debugLogStatus.stringValue = "Saved. Review the file before sharing it."
                case .failure: self?.debugLogStatus.stringValue = "Could not save. Try another location."
                }
            }
        }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: SettingsSection.allCases[row].symbol, accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        cell.addSubview(icon)
        let text = NSTextField(labelWithString: pageNames[row])
        text.font = .systemFont(ofSize: 13)
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = text
        cell.imageView = icon
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            text.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8)
        ])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        for (index, viewport) in pageScrollViews.enumerated() { viewport.isHidden = index != navigation.selectedRow }
    }

    @objc private func openFeedback() {
        NSWorkspace.shared.open(URL(string: "https://github.com/maxim-kich/dragtwozero/issues/new/choose")!)
    }

    @objc private func openLegalDocument(_ sender: NSButton) {
        let destinations = [
            "https://dragtwozero.com",
            "https://dragtwozero.com/legal#app-privacy",
            "https://dragtwozero.com/terms",
            "https://dragtwozero.com/licenses"
        ]
        let bundledFallbacks: [String?] = [nil, "legal-privacy", "terms", "licenses"]
        guard destinations.indices.contains(sender.tag),
              let url = URL(string: destinations[sender.tag]) else { return }
        if NSWorkspace.shared.open(url) { return }
        // This fallback handles failure to launch a URL, not browser network errors.
        if let name = bundledFallbacks[sender.tag],
           let localURL = Bundle.main.url(forResource: name, withExtension: "html", subdirectory: "Legal"),
           NSWorkspace.shared.open(localURL) { return }
        let alert = NSAlert()
        alert.messageText = "Unable to open link"
        alert.informativeText = "Open \(url.absoluteString) in your browser."
        alert.runModal()
    }

    @objc private func refreshUpdates() {
        let updates = UpdateChecker.shared
        updateButton.title = updates.primaryTitle
        updateButton.frame.size.width = 170
        updateButton.frame.origin.x = (592 - 170) / 2
        updateButton.isEnabled = updates.primaryEnabled
        cancelUpdateButton.isHidden = !updates.canCancel
        updateStatus.stringValue = showsUpdateStatus || updates.hasUpdate ? updates.message : ""
        updateCheckSwitch.state = updates.automaticChecks ? .on : .off
    }
    @objc private func updateClicked() {
        showsUpdateStatus = true
        UpdateChecker.shared.openUpdate()
        refreshUpdates()
    }
    @objc private func cancelUpdateClicked() {
        showsUpdateStatus = true
        UpdateChecker.shared.cancel()
    }
    @objc private func updateChecksChanged(_ sender: NSSwitch) {
        UpdateChecker.shared.automaticChecks = sender.state == .on
        if sender.state == .on { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } }
    }

    func refreshActivation() {
        activationSwitch.state = isActive() ? .on : .off
    }

    @objc private func dockIconChanged(_ sender: NSSwitch) {
        DebugLog.shared.record(.action(sender.state == .on ? .dockHidden : .dockShown))
        AppPresentationPreferences.setHidesDockIcon(sender.state == .on)
        AppPresentationPreferences.applyDockVisibility()
    }

    @objc private func refreshAccessibility() {
        let granted = isAccessibilityGranted()
        accessibilityStatus.stringValue = granted ? "Allowed" : "Not allowed"
        accessibilityStatus.textColor = .systemGreen
        accessibilityStatus.isHidden = !granted
        accessibilityButton.isHidden = granted
        launchAtLoginView.refresh()
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func activationChanged(_ sender: NSSwitch) {
        onActivationChange(sender.state == .on)
    }

    @objc private func showMultiselectInfo(_ sender: NSButton) {
        showGestureInfo(sender, popover: multiselectInfoPopover, mode: .multiSelect)
    }

    @objc private func showSelectedTextInfo(_ sender: NSButton) {
        showGestureInfo(sender, popover: selectedTextInfoPopover, mode: .selectedText)
    }

    private func showGestureInfo(_ sender: NSButton, popover: NSPopover, mode: MultiselectDemoView.Mode) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        let controller = NSViewController()
        let explanationHeight: CGFloat = mode == .selectedText ? 112 : 48
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 232 + explanationHeight))
        let demo = MultiselectDemoView(frame: NSRect(x: 16, y: 24 + explanationHeight, width: 288, height: 192), mode: mode)
        controller.view.addSubview(demo)
        let explanation = NSTextField(wrappingLabelWithString: sender.toolTip ?? "")
        explanation.font = .systemFont(ofSize: 13)
        explanation.frame = NSRect(x: 16, y: 12, width: 288, height: explanationHeight)
        controller.view.addSubview(explanation)
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func multiselectChanged(_ sender: NSSwitch) {
        CapturePreferences.multiselectEnabled = sender.state == .on
        onStructureChange()
    }

    @objc private func bufferChanged(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        guard enabled != CapturePreferences.bufferEnabled else { return }
        CapturePreferences.bufferEnabled = enabled
        refreshBufferPositionAvailability()
        onBufferChange()
    }
    func refreshBuffer() {
        bufferSwitch.state = CapturePreferences.bufferEnabled ? .on : .off
        refreshBufferPositionAvailability()
    }
    private func refreshBufferPositionAvailability() {
        let enabled = CapturePreferences.bufferEnabled
        bufferPositionControl.isEnabled = enabled
        bufferPositionLabel.textColor = enabled ? .labelColor : .disabledControlTextColor
        bufferPositionControl.toolTip = enabled ? nil : "Turn on Buffer to change its position."
    }
    @objc private func bufferPositionChanged() {
        guard CapturePreferences.bufferEnabled else { return }
        guard BufferPosition.allCases.indices.contains(bufferPositionControl.indexOfSelectedItem) else { return }
        CapturePreferences.bufferPosition = BufferPosition.allCases[bufferPositionControl.indexOfSelectedItem]
        onBufferChange()
    }

    @objc private func selectedTextChanged(_ sender: NSSwitch) {
        CapturePreferences.selectedTextDraggingEnabled = sender.state == .on
        onStructureChange()
    }

    @objc private func structureChanged(_ sender: NSSwitch) {
        CapturePreferences.preserveStructure = sender.state == .on
        onStructureChange()
    }
    @objc private func overwriteClipboardChanged(_ sender: NSSwitch) {
        CapturePreferences.overwriteClipboard = sender.state == .on
    }
    @objc private func hapticsChanged(_ sender: NSSwitch) {
        CapturePreferences.hapticsEnabled = sender.state == .on
        if sender.state == .on { CaptureHaptics().startDrag() }
    }
}
