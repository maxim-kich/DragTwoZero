import XCTest
import Sparkle
@testable import DragTwoZero

final class UpdateConsentTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private let update = ReleaseUpdate(version: "0.0.2",
        archive: URL(string: "https://github.com/maxim-kich/dragtwozero/releases/download/v0.0.2/Drag-2.0-v0.0.2-macOS-arm64.zip")!,
        length: 123, feed: URL(string: "https://github.com/maxim-kich/dragtwozero/releases/download/v0.0.2/appcast.xml")!)
    override func setUp() {
        suite = "DragTwoZero.UpdateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "checkForUpdates")
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }
    private func checker(_ confirmation: @escaping (String, String, String) -> Bool = { _, _, _ in true }) -> UpdateChecker {
        let checker = UpdateChecker(defaults: defaults, confirm: confirmation)
        checker.activity = { UpdateActivity() }
        checker.beforeRestart = { _, done in done(true) }
        return checker
    }
    func testDownloadRequiresConsentAndPreservesDailyPreference() {
        var consent = false
        let checker = checker { _, _, button in XCTAssertEqual(button, "Download & Install"); return consent }
        var choices: [SPUUserUpdateChoice] = []
        checker.offerUpdate(update) { choices.append($0) }
        XCTAssertTrue(choices.isEmpty)
        checker.openUpdate()
        XCTAssertTrue(choices.isEmpty)
        consent = true
        checker.openUpdate()
        XCTAssertEqual(choices, [.install])
        XCTAssertEqual(checker.phase, .downloading)
        XCTAssertFalse(checker.automaticChecks)
        XCTAssertFalse(checker.permitsTermination(), "Ordinary Quit must not install on exit without Restart consent")
    }
    func testRestartRequiresSeparateConsentAndEmptyBuffer() {
        var consent = true
        let checker = checker { _, _, _ in consent }
        checker.offerUpdate(update) { _ in }
        checker.openUpdate()
        var result: SPUUserUpdateChoice?
        checker.showReady(toInstallAndRelaunch: { result = $0 })
        XCTAssertNil(result)
        checker.activity = { UpdateActivity(buffer: true) }
        checker.openUpdate()
        XCTAssertNil(result)
        XCTAssertFalse(checker.restartAuthorized)
        XCTAssertTrue(checker.message.contains("Buffer"))
        checker.activity = { UpdateActivity() }
        consent = false
        checker.openUpdate()
        XCTAssertNil(result)
        consent = true
        checker.openUpdate()
        XCTAssertEqual(result, .install)
        XCTAssertTrue(checker.restartAuthorized)
        XCTAssertTrue(checker.permitsTermination())
    }
    func testRestartRechecksActivityAfterModalConfirmationAndAtTermination() {
        var activity = UpdateActivity()
        var confirmations = 0
        let checker = checker { _, _, button in
            if button == "Restart" { activity.transfer = true; confirmations += 1 }
            return true
        }
        checker.activity = { activity }
        checker.offerUpdate(update) { _ in }
        checker.openUpdate()
        var result: SPUUserUpdateChoice?
        checker.showReady(toInstallAndRelaunch: { result = $0 })
        checker.openUpdate()
        XCTAssertEqual(confirmations, 1)
        XCTAssertNil(result)
        XCTAssertFalse(checker.restartAuthorized)
        XCTAssertFalse(checker.permitsTermination())
    }
    func testCancellationOfStagedUpdateUsesSkipRatherThanInstallOnQuitDismissal() {
        let checker = checker()
        checker.offerUpdate(update) { _ in }
        checker.openUpdate()
        var result: SPUUserUpdateChoice?
        checker.showReady(toInstallAndRelaunch: { result = $0 })
        checker.cancel()
        XCTAssertEqual(result, .skip)
        XCTAssertEqual(checker.phase, .idle)
        XCTAssertTrue(checker.permitsTermination())
        XCTAssertFalse(checker.restartAuthorized)
    }
    func testCancellationWhileRestartConfirmationIsOpenInvalidatesItsReply() {
        var checker: UpdateChecker!
        checker = self.checker { _, _, button in
            if button == "Restart" { checker.cancel() }
            return true
        }
        checker.offerUpdate(update) { _ in }
        checker.openUpdate()
        var choices: [SPUUserUpdateChoice] = []
        checker.showReady(toInstallAndRelaunch: { choices.append($0) })
        checker.openUpdate()
        XCTAssertEqual(choices, [.skip])
        XCTAssertFalse(checker.restartAuthorized)
        XCTAssertEqual(checker.phase, .idle)
    }
    func testCancellationDuringExtractionWaitsAndThenDisarmsInstaller() {
        let checker = checker()
        checker.offerUpdate(update) { _ in }
        checker.openUpdate()
        checker.showDownloadDidStartExtractingUpdate()
        checker.cancel()
        XCTAssertEqual(checker.phase, .extracting)
        XCTAssertFalse(checker.permitsTermination())
        var result: SPUUserUpdateChoice?
        checker.showReady(toInstallAndRelaunch: { result = $0 })
        XCTAssertEqual(result, .skip)
    }
    func testDownloadCancellationAndErrorDoNotAuthorizeRestart() {
        let checker = checker()
        checker.offerUpdate(update) { _ in }
        checker.openUpdate()
        var cancelled = false
        checker.showDownloadInitiated { cancelled = true }
        checker.cancel()
        XCTAssertTrue(cancelled)
        XCTAssertFalse(checker.restartAuthorized)
        var acknowledged = false
        checker.showUpdaterError(NSError(domain: "test", code: 1)) { acknowledged = true }
        XCTAssertTrue(acknowledged)
        XCTAssertFalse(checker.restartAuthorized)
    }
    func testWrappedSignatureFailureShowsSafeActionableMessage() {
        let checker = checker()
        let signature = NSError(domain: SUSparkleErrorDomain, code: 3002,
                                userInfo: [NSLocalizedDescriptionKey: "untrusted server text"])
        let installer = NSError(domain: SUSparkleErrorDomain, code: 4005,
                                userInfo: [NSUnderlyingErrorKey: signature])
        checker.showUpdaterError(installer) {}
        XCTAssertTrue(checker.message.contains("signature"))
        XCTAssertFalse(checker.message.contains("untrusted server text"))
        XCTAssertFalse(checker.restartAuthorized)
    }
    func testEveryTransientCaptureAndTransferStateBlocksRestart() {
        XCTAssertNil(UpdateActivity().restartBlock)
        XCTAssertNotNil(UpdateActivity(transfer: true).restartBlock)
        XCTAssertNotNil(UpdateActivity(selection: true).restartBlock)
        XCTAssertNotNil(UpdateActivity(buffer: true).restartBlock)
        let app = AppDelegate()
        XCTAssertNil(app.updateActivity.restartBlock)
        app.state.modifiers(held: true)
        XCTAssertNotNil(app.updateActivity.restartBlock)
        app.state.cancel()
        app.dropping = true
        XCTAssertTrue(app.updateActivity.transfer)
        app.dropping = false
        app.pendingPress = .init(start: .zero, end: .zero)
        XCTAssertTrue(app.updateActivity.transfer)
        app.pendingPress = nil
        _ = app.buffer.store(CapturePayload(title: "test", markdown: "test"), symbol: "text")
        XCTAssertTrue(app.updateActivity.buffer)
    }
    private func stage(_ checker: UpdateChecker, reply: @escaping (SPUUserUpdateChoice) -> Void = { _ in }) {
        checker.offerUpdate(update) { _ in }
        checker.openUpdate()
        checker.showReady(toInstallAndRelaunch: reply)
    }
    func testPreparationWaitsForAcknowledgementAndRejectsLateCompletionAfterCancellation() {
        let checker = checker()
        var completion: ((Bool) -> Void)?
        var valid: (() -> Bool)?
        var abandoned = false
        checker.beforeRestart = { current, done in valid = current; completion = done }
        checker.abandonRestart = { abandoned = true }
        var choices: [SPUUserUpdateChoice] = []
        stage(checker) { choices.append($0) }
        checker.openUpdate()
        XCTAssertEqual(checker.phase, .preparing)
        XCTAssertFalse(checker.permitsTermination())
        XCTAssertTrue(valid?() == true)
        XCTAssertTrue(choices.isEmpty)
        checker.cancel()
        XCTAssertTrue(abandoned)
        XCTAssertFalse(valid?() == true)
        completion?(true)
        XCTAssertEqual(choices, [.skip])
        XCTAssertFalse(checker.restartAuthorized)
        XCTAssertNil(defaults.object(forKey: UpdateRelaunch.key))
        XCTAssertTrue(checker.permitsTermination())
    }
    func testStopAndTerminationRetriesKeepOriginalIntentAndFailureClearsReceipt() {
        let checker = checker()
        var activity = UpdateActivity(activationIntent: true, inputPaused: true)
        checker.activity = { activity }
        var attempt = 0
        checker.beforeRestart = { _, done in
            attempt += 1
            activity.activationIntent = false
            activity.inputPaused = false
            done(attempt > 1)
        }
        stage(checker)
        checker.openUpdate()
        XCTAssertEqual(checker.phase, .ready)
        XCTAssertNil(defaults.object(forKey: UpdateRelaunch.key))
        checker.openUpdate()
        XCTAssertTrue(checker.restartAuthorized)
        var receipt = defaults.dictionary(forKey: UpdateRelaunch.key)!
        XCTAssertEqual(receipt["intent"] as? Bool, true)
        XCTAssertEqual(receipt["paused"] as? Bool, true)
        var retried = false
        checker.showInstallingUpdate(withApplicationTerminated: false) { retried = true }
        checker.openUpdate()
        XCTAssertTrue(retried)
        receipt = defaults.dictionary(forKey: UpdateRelaunch.key)!
        XCTAssertEqual(receipt["intent"] as? Bool, true)
        checker.showUpdaterError(NSError(domain: "test", code: 1)) {}
        XCTAssertNil(defaults.object(forKey: UpdateRelaunch.key))
        XCTAssertFalse(checker.restartAuthorized)
    }
    func testAcknowledgementCannotOverrideNewActivityOrRunTwice() {
        let checker = checker()
        var done: ((Bool) -> Void)?
        var activity = UpdateActivity()
        checker.activity = { activity }
        checker.beforeRestart = { _, completion in done = completion }
        var installs = 0
        stage(checker) { if $0 == .install { installs += 1 } }
        checker.openUpdate()
        activity.transfer = true
        done?(true)
        XCTAssertEqual(installs, 0)
        XCTAssertEqual(checker.phase, .ready)
        activity.transfer = false
        checker.openUpdate()
        done?(true); done?(true)
        XCTAssertEqual(installs, 1)
    }
    func testReceiptIsScopedExpiringAndAlwaysConsumed() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info = ["CFBundleIdentifier": "test.drag.update", "CFBundleShortVersionString": "0.0.2", "CFBundlePackageType": "APPL"]
        let data = try! PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try! data.write(to: root.appendingPathComponent("Contents/Info.plist"))
        let bundle = Bundle(url: root)!
        let version = "0.0.2"
        let now = Date()
        for intent in [false, true] {
            UpdateRelaunch.save(intent, paused: true, version: version, defaults: defaults, bundle: bundle, now: now)
            XCTAssertEqual(UpdateRelaunch.consume(defaults: defaults, bundle: bundle, now: now)?.intent, intent)
            XCTAssertNil(UpdateRelaunch.consume(defaults: defaults, bundle: bundle, now: now))
            for mutation in ["path", "bundle", "version", "expires"] {
                UpdateRelaunch.save(intent, paused: false, version: version, defaults: defaults, bundle: bundle, now: now)
                var receipt = defaults.dictionary(forKey: UpdateRelaunch.key)!
                receipt[mutation] = mutation == "expires" ? now.addingTimeInterval(-1).timeIntervalSince1970 as Any : "mismatch"
                defaults.set(receipt, forKey: UpdateRelaunch.key)
                XCTAssertNil(UpdateRelaunch.consume(defaults: defaults, bundle: bundle, now: now))
                XCTAssertNil(defaults.object(forKey: UpdateRelaunch.key))
            }
        }
    }
    func testAppPreparationPreservesBufferAndRejectsActiveWork() {
        let app = AppDelegate()
        _ = app.buffer.store(CapturePayload(title: "test", markdown: "test"), symbol: "text")
        app.prepareUpdateRestart(stillAuthorized: { true }) { XCTAssertFalse($0) }
        XCTAssertFalse(app.updatePaused)
        XCTAssertNotNil(app.buffer.item)
        app.buffer.clear()
        let acknowledged = expectation(description: "stopped on main queue")
        let intent = app.captureEnabled
        app.prepareUpdateRestart(stillAuthorized: { true }) { success in
            XCTAssertTrue(success)
            XCTAssertTrue(app.updatePaused)
            XCTAssertEqual(app.captureEnabled, intent)
            acknowledged.fulfill()
        }
        wait(for: [acknowledged], timeout: 2)
    }

    func testInstallationErrorRejectsLateReadyAndRestorationCallbacks() {
        let checker = checker()
        var completion: ((Bool) -> Void)?
        checker.beforeRestart = { _, done in completion = done }
        stage(checker)
        checker.openUpdate()
        checker.showUpdaterError(NSError(domain: "test", code: 1)) {}
        completion?(true)
        var reply: SPUUserUpdateChoice?
        checker.showReady { reply = $0 }
        XCTAssertEqual(reply, .skip)
        XCTAssertFalse(checker.restartAuthorized)
        XCTAssertNil(defaults.object(forKey: UpdateRelaunch.key))
    }

}
