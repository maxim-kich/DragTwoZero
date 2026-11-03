import XCTest
import AppKit
import ApplicationServices
@testable import DragTwoZero

final class AppPresentationTests: XCTestCase {
    func testAccessibilityStatusRemainsExplicitWhenPermissionIsGranted() {
        XCTAssertEqual(OnboardingWindowController.permissionStatusText(granted: true), "Accessibility is enabled.")
        XCTAssertFalse(OnboardingWindowController.permissionStatusText(granted: false).isEmpty)
    }

    @MainActor
    func testOnboardingKeepsReadableSemanticLabelsInLightSystemAppearance() throws {
        _ = NSApplication.shared
        let previous = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        defer { NSApp.appearance = previous }
        let controller = OnboardingWindowController(onIncompleteClose: {})
        let root = try XCTUnwrap(controller.window?.contentView)
        XCTAssertEqual(root.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        var labelBrightness: CGFloat = 0
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            labelBrightness = NSColor.labelColor.usingColorSpace(.deviceRGB)!.redComponent
        }
        XCTAssertGreaterThan(labelBrightness, 0.7, "Semantic foreground must stay light on the dark video")
        controller.close()
    }

    @MainActor
    func testClosingUnfinishedOnboardingRequestsAppTermination() {
        _ = NSApplication.shared
        var requestedQuit = false
        let controller = OnboardingWindowController(onIncompleteClose: { requestedQuit = true })
        controller.close()
        XCTAssertTrue(requestedQuit)
        XCTAssertFalse(controller.window?.isVisible ?? true)
    }

    @MainActor
    func testSettingsExposeDockPreferenceAndActualAccessibilityStatus() throws {
        _ = NSApplication.shared
        let controller = SettingsWindowController(onStructureChange: {}, onAppearanceChange: {},
            isActive: { true }, onActivationChange: { _ in })
        controller.alignPageContentWithSidebar()
        let root = try XCTUnwrap(controller.window?.contentView)
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let views = descendants(root)
        let dock = try XCTUnwrap(views.compactMap { $0 as? NSSwitch }.first {
            $0.accessibilityLabel() == "Hide app icon from Dock"
        })
        XCTAssertEqual(dock.state, AppPresentationPreferences.hidesDockIcon() ? .on : .off)
        let status = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first {
            $0.accessibilityLabel() == "Accessibility permission status"
        })
        XCTAssertEqual(status.stringValue, AXIsProcessTrusted() ? "Allowed" : "Not allowed")
        XCTAssertTrue(views.compactMap { $0 as? NSButton }.contains {
            $0.accessibilityLabel() == "Manage Accessibility permission"
        })
        XCTAssertTrue(views.compactMap { $0 as? NSButton }.contains {
            $0.accessibilityLabel() == "Export Debug Log"
        })
        let labels = views.compactMap { $0 as? NSTextField }
        let activate = try XCTUnwrap(labels.first { $0.stringValue == "Activate" })
        let accessibility = try XCTUnwrap(labels.first { $0.stringValue == "Accessibility" })
        let shortcut = try XCTUnwrap(labels.first { $0.stringValue == "Trigger Shortcut" })
        XCTAssertGreaterThan(activate.convert(activate.bounds, to: root).midY,
                             accessibility.convert(accessibility.bounds, to: root).midY)
        XCTAssertGreaterThan(accessibility.convert(accessibility.bounds, to: root).midY,
                             shortcut.convert(shortcut.bounds, to: root).midY)
        // Optional review artifact; no windows are shown and no event tap is installed.
        if let directory = ProcessInfo.processInfo.environment["DRAGTWOZERO_UI_REVIEW_DIR"],
           let page = views.first(where: { view in
               view.bounds.width >= 600 && view.subviews.contains { ($0 as? NSTextField)?.stringValue == "General" }
           }) {
            let bitmap = try XCTUnwrap(page.bitmapImageRepForCachingDisplay(in: page.bounds))
            page.cacheDisplay(in: page.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("general-settings.png"))
        }
    }

    func testDockIconIsHiddenByDefaultAndChoicePersistsWithoutChangingOtherPreferences() throws {
        let name = "local.drag2.presentation-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "checkForUpdates")
        defaults.set(true, forKey: "bufferEnabled")
        XCTAssertTrue(AppPresentationPreferences.hidesDockIcon(in: defaults))
        XCTAssertEqual(AppPresentationPreferences.activationPolicy(in: defaults), .accessory)
        AppPresentationPreferences.setHidesDockIcon(false, in: defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: name))
        XCTAssertFalse(AppPresentationPreferences.hidesDockIcon(in: reopened))
        XCTAssertEqual(AppPresentationPreferences.activationPolicy(in: reopened), .regular)
        AppPresentationPreferences.setHidesDockIcon(true, in: reopened)
        XCTAssertEqual(AppPresentationPreferences.activationPolicy(in: defaults), .accessory)
        XCTAssertFalse(defaults.bool(forKey: "checkForUpdates"))
        XCTAssertTrue(defaults.bool(forKey: "bufferEnabled"))
    }

    @MainActor
    func testDockRequestsSerializeAndKeepLatestChoiceWithoutReopeningWindow() {
        _ = NSApplication.shared
        let hidden = NSApp.activationPolicy() != .accessory
        var requests: [Bool] = []
        var completions: [() -> Void] = []
        let controller = DockPresentation(transform: { requests.append($0); return true },
                                          schedule: { completions.append($0) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        XCTAssertTrue(controller.request(hidden: hidden, window: window))
        XCTAssertTrue(controller.request(hidden: !hidden))
        XCTAssertTrue(controller.request(hidden: hidden))
        XCTAssertEqual(requests, [hidden])
        window.close()
        completions.removeFirst()()
        XCTAssertEqual(requests, [hidden, hidden], "Only the latest queued request is applied")
        XCTAssertFalse(window.isVisible, "Finishing a transition must not reopen closed Settings")
        completions.removeFirst()()
    }

    @MainActor
    func testFailedDockChangeRestoresWindowHidingAndCanRetry() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.canHide = true
        var attempts = 0
        let controller = DockPresentation(transform: { _ in attempts += 1; return false },
                                          schedule: { _ in XCTFail("Failed changes must not schedule a transition") })
        let hidden = NSApp.activationPolicy() != .accessory
        XCTAssertFalse(controller.request(hidden: hidden, window: window))
        XCTAssertTrue(window.canHide)
        XCTAssertFalse(controller.request(hidden: hidden, window: window))
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(window.isVisible)
    }

    func testClosingAnyUnfinishedOnboardingStepQuitsIncludingTheLastScreen() {
        for step in 0...OnboardingSession.finalStep {
            var session = OnboardingSession()
            session.step = step
            XCTAssertTrue(session.shouldQuitOnClose)
        }
    }

    func testMenuBarIconAppearsOnlyAtFinalStepAndHidesWhenGoingBack() {
        var session = OnboardingSession()
        for step in 0..<OnboardingSession.finalStep {
            session.step = step
            XCTAssertFalse(session.showsMenuBarIcon)
        }
        session.step = OnboardingSession.finalStep
        XCTAssertTrue(session.showsMenuBarIcon)
        session.step -= 1
        XCTAssertFalse(session.showsMenuBarIcon)
    }

    func testGetStartedKeepsAppRunningButCannotCompleteAnEarlierStep() {
        var session = OnboardingSession()
        XCTAssertFalse(session.finish())
        XCTAssertTrue(session.shouldQuitOnClose)
        session.step = OnboardingSession.finalStep
        XCTAssertTrue(session.finish())
        XCTAssertFalse(session.shouldQuitOnClose)
        XCTAssertTrue(session.showsMenuBarIcon)
        // Replaying onboarding is a new incomplete session, regardless of saved completion.
        session = OnboardingSession()
        XCTAssertTrue(session.shouldQuitOnClose)
        XCTAssertFalse(session.showsMenuBarIcon)
    }
}
