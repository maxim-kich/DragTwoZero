import AppKit

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

    static func applyDockVisibility() {
        let desired = activationPolicy()
        if NSApp.activationPolicy() != desired { NSApp.setActivationPolicy(desired) }
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
