import AppKit
import Carbon

enum AppPresentationPreferences {
    static let hideDockIconKey = "hideAppIconFromDock"

    static func hidesDockIcon(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: hideDockIconKey) as? Bool ?? true
    }

    static func setHidesDockIcon(_ hidden: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(hidden, forKey: hideDockIconKey)
    }

    static func activationPolicy(in defaults: UserDefaults = .standard) -> NSApplication.ActivationPolicy {
        hidesDockIcon(in: defaults) ? .accessory : .regular
    }

    @discardableResult
    static func applyDockVisibility(window: NSWindow? = nil) -> Bool {
        DockPresentation.shared.request(hidden: hidesDockIcon(), window: window)
    }
}

/// Changes process presentation without ordering Settings out or reopening it.
/// A short serialization interval lets the native Dock handoff finish; focus
/// restoration is driven by activation notifications, never by that interval.
final class DockPresentation {
    static let shared = DockPresentation()
    private weak var settings: NSWindow?
    private weak var focusTarget: NSWindow?
    private var savedCanHide: Bool?
    private var busy = false
    private var latestRequest: Bool?
    private var observers: [NSObjectProtocol] = []
    private let transform: (Bool) -> Bool
    private let schedule: (@escaping () -> Void) -> Void

    init(transform: @escaping (Bool) -> Bool = DockPresentation.transformProcess,
         schedule: @escaping (@escaping () -> Void) -> Void = { completion in
             DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: completion)
         }) {
        self.transform = transform
        self.schedule = schedule
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification,
                     NSApplication.didBecomeActiveNotification,
                     NSApplication.willHideNotification,
                     NSApplication.willUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.applicationChanged(note.name)
            })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    @discardableResult
    func request(hidden: Bool, window: NSWindow? = nil) -> Bool {
        if let window, settings !== window {
            restoreWindowHiding()
            settings = window
            savedCanHide = window.canHide
        }
        if busy {
            latestRequest = hidden
            return true
        }
        settings?.canHide = hidden ? false : (savedCanHide ?? true)
        let desired: NSApplication.ActivationPolicy = hidden ? .accessory : .regular
        guard NSApp.activationPolicy() != desired else { return true }
        busy = true
        if NSApp.isActive, let settings, settings.isKeyWindow, settings.isOnActiveSpace {
            focusTarget = settings
        }
        guard transform(hidden) else {
            busy = false
            focusTarget = nil
            restoreWindowHiding()
            return false
        }
        restoreFocusIfEligible()
        schedule { [weak self] in
            guard let self else { return }
            self.busy = false
            self.focusTarget = nil
            if let hidden = self.latestRequest {
                self.latestRequest = nil
                self.request(hidden: hidden)
            }
        }
        return true
    }

    private func applicationChanged(_ name: Notification.Name) {
        switch name {
        case NSApplication.willHideNotification:
            // Explicit Hide cancels restoration, including during a handoff.
            focusTarget = nil
            restoreWindowHiding()
        case NSApplication.willUnhideNotification:
            if NSApp.activationPolicy() == .accessory { settings?.canHide = false }
        case NSApplication.didBecomeActiveNotification:
            restoreFocusIfEligible()
            focusTarget = nil
        case NSApplication.didResignActiveNotification:
            if busy { restoreFocusIfEligible() }
        default: break
        }
    }

    private func restoreFocusIfEligible() {
        guard let window = focusTarget, window.isVisible,
              !window.isMiniaturized, window.isOnActiveSpace else { return }
        if #available(macOS 14, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        window.makeKey()
    }

    private func restoreWindowHiding() {
        if let savedCanHide { settings?.canHide = savedCanHide }
    }

    static func transformProcess(hidden: Bool) -> Bool {
        var process = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
        let kind = hidden ? kProcessTransformToUIElementApplication : kProcessTransformToForegroundApplication
        return TransformProcessType(&process, ProcessApplicationTransformState(kind)) == noErr
    }
}

/// Completion belongs to this presentation, including when replaying the guide.
struct OnboardingSession {
    static let finalStep = 5
    var step = 0
    private(set) var completed = false

    var showsMenuBarIcon: Bool { step == Self.finalStep || completed }
    var shouldQuitOnClose: Bool { !completed }

    @discardableResult
    mutating func finish() -> Bool {
        guard step == Self.finalStep else { return false }
        completed = true
        return true
    }
}
