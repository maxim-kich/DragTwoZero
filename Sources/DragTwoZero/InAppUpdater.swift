import AppKit
import Sparkle
import UserNotifications

struct ReleaseUpdate: Equatable {
    let version: String
    let archive: URL
    let length: UInt64
    let feed: URL

    func matches(_ item: SUAppcastItem) -> Bool {
        item.versionString == version && item.displayVersionString == version
            && item.fileURL == archive && item.contentLength == length
            && item.installationType == "application" && !item.isInformationOnlyUpdate
            && item.phasedRolloutInterval == nil
    }
}

/// Read synchronously on the main thread; never probe another app to decide if quitting is safe.
struct UpdateActivity {
    var transfer = false
    var selection = false
    var buffer = false
    var clipboard = false
    var activationIntent = false
    var inputPaused = false
    var restartBlock: String? {
        if clipboard { return "Copy something new before restarting to release the pending paste." }
        if transfer { return "Finish or cancel the active transfer before restarting." }
        if selection { return "Finish or cancel the current capture before restarting." }
        if buffer { return "Use or explicitly clear the Buffer content before restarting." }
        return nil
    }
}

/// Only activation intent crosses replacement. Never serialize Buffer or pending work.
enum UpdateRelaunch {
    static let key = "updateRelaunchOnce"
    static func save(_ intent: Bool, paused: Bool, version: String, defaults: UserDefaults, bundle: Bundle, now: Date = Date()) {
        defaults.set(["intent": intent, "paused": paused, "version": version,
                      "path": bundle.bundleURL.standardizedFileURL.path, "bundle": bundle.bundleIdentifier ?? "",
                      "expires": now.addingTimeInterval(600).timeIntervalSince1970], forKey: key)
        defaults.synchronize()
    }
    static func clear(_ defaults: UserDefaults) { defaults.removeObject(forKey: key); defaults.synchronize() }
    static func consume(defaults: UserDefaults = .standard, bundle: Bundle = .main, now: Date = Date()) -> (intent: Bool, paused: Bool)? {
        let receipt = defaults.dictionary(forKey: key)
        clear(defaults)
        guard let receipt, receipt["path"] as? String == bundle.bundleURL.standardizedFileURL.path,
              receipt["bundle"] as? String == bundle.bundleIdentifier ?? "",
              receipt["version"] as? String == bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let expires = receipt["expires"] as? Double, expires > now.timeIntervalSince1970,
              expires <= now.addingTimeInterval(600).timeIntervalSince1970,
              let intent = receipt["intent"] as? Bool, let paused = receipt["paused"] as? Bool else { return nil }
        return (intent, paused)
    }
}

/// Sparkle owns verification, staging and atomic replacement. This driver owns consent.
/// In particular, .skip cancels a staged installation; .dismiss would install it on quit.
final class UpdateChecker: NSObject, SPUUpdaterDelegate, SPUUserDriver, UNUserNotificationCenterDelegate {
    static let shared = UpdateChecker()
    static let changed = Notification.Name("DragUpdateStateChanged")
    enum Phase { case idle, checking, available, downloading, extracting, ready, preparing, installing, cancelling }
    private(set) var phase: Phase = .idle
    private(set) var message = "Check for a newer version."
    private(set) var release: ReleaseUpdate?
    var activity: () -> UpdateActivity = { UpdateActivity(transfer: true) } // Fail closed until attached to the app.
    var beforeRestart: (@escaping () -> Bool, @escaping (Bool) -> Void) -> Void = { _, done in done(false) }
    var abandonRestart: () -> Void = {}
    private var originalIntent: (enabled: Bool, paused: Bool)?
    private var preparation = UUID()
    var restartInProgress: Bool { phase == .preparing || phase == .installing }
    private(set) var restartAuthorized = false
    private(set) var failureCode: Int?
    private(set) var failureCodes: [Int] = []
    private(set) var downloadedBytes: UInt64 = 0
    private var downloadAuthorized = false
    private var cancelRequested = false
    private var choice: ((SPUUserUpdateChoice) -> Void)?
    private var cancellation: (() -> Void)?
    private var retryTermination: (() -> Void)?
    private var updater: SPUUpdater?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var checkGeneration = UUID()
    private let defaults: UserDefaults
    private let bundle: Bundle
    private let confirm: (String, String, String) -> Bool
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main,
         confirm: @escaping (String, String, String) -> Bool = UpdateChecker.confirmWithAlert) {
        self.defaults = defaults; self.bundle = bundle; self.confirm = confirm
        super.init()
    }
    private static func confirmWithAlert(_ title: String, _ detail: String, _ button: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: button); alert.addButton(withTitle: "Cancel")
        // Return must not accidentally consent to a download or a restart.
        alert.buttons[0].keyEquivalent = ""; alert.buttons[1].keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }
    var checking: Bool { phase == .checking }
    var hasUpdate: Bool { [.available, .downloading, .extracting, .ready, .preparing, .installing, .cancelling].contains(phase) }
    var primaryTitle: String {
        switch phase {
        case .idle: return "Check for Updates"
        case .checking: return "Checking…"
        case .available: return "Download & Install"
        case .downloading: return "Downloading…"
        case .extracting: return "Verifying…"
        case .ready: return "Restart"
        case .preparing: return "Stopping…"
        case .installing: return retryTermination == nil ? "Restarting…" : "Restart"
        case .cancelling: return "Cancelling…"
        }
    }
    var primaryEnabled: Bool { (phase == .idle && updater?.sessionInProgress != true) || [.available, .ready].contains(phase) || (phase == .installing && retryTermination != nil) }
    var canCancel: Bool { [.checking, .available, .downloading, .extracting, .ready, .preparing].contains(phase) && !cancelRequested }
    var automaticChecks: Bool {
        get { defaults.object(forKey: "checkForUpdates") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "checkForUpdates")
            if newValue { checkIfDue() }
            broadcast()
        }
    }
    func start() {
        guard timer == nil else { return }
        UNUserNotificationCenter.current().delegate = self
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
    }
    private func checkIfDue() {
        guard automaticChecks, phase == .idle,
              Date.timeIntervalSinceReferenceDate - defaults.double(forKey: "lastUpdateCheck") >= 86400 else { return }
        check()
    }
    func check() {
        guard phase == .idle, updater?.sessionInProgress != true else { return }
        guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            set(.idle, "Update signing is not configured in this development build."); return
        }
        cancelRequested = false; release = nil; failureCode = nil; failureCodes = []
        let generation = UUID()
        checkGeneration = generation
        set(.checking, "Checking for updates…")
        defaults.set(Date.timeIntervalSinceReferenceDate, forKey: "lastUpdateCheck")
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/maxim-kich/dragtwozero/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("DragTwoZero-Updater", forHTTPHeaderField: "User-Agent")
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let (bytes, response) = try await self.session.bytes(for: request)
                defer { bytes.task.cancel() }
                let data = try await BoundedReleaseBody.read(bytes, expectedLength: response.expectedContentLength)
                try Task.checkCancellation()
                await MainActor.run {
                    guard !self.cancelRequested, self.checkGeneration == generation else { return }
                    self.task = nil
                    switch (response as? HTTPURLResponse)?.statusCode {
                    case 404: self.set(.idle, "No published release is available yet.")
                    case 403, 429: self.set(.idle, "GitHub limit reached. Try again later.")
                    case 200:
                        guard let published = try? JSONDecoder().decode(PublishedRelease.self, from: data) else {
                            self.set(.idle, "Couldn’t read release information."); return
                        }
                        let current = self.bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
                        guard let release = published.update(current: current) else {
                            self.set(.idle, "No newer compatible published update is available."); return
                        }
                        self.beginCheck(for: release)
                    default: self.set(.idle, "Couldn’t check. Try again when online.")
                    }
                }
            } catch {
                await MainActor.run {
                    guard !self.cancelRequested, self.checkGeneration == generation else { return }
                    self.task = nil; self.set(.idle, "Couldn’t check. Try again when online.")
                }
            }
        }
    }
    func beginCheck(for release: ReleaseUpdate) {
        self.release = release
        set(.checking, "Checking signed update information…")
        do {
            if updater == nil {
                let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
                // Our existing scheduler/preference is authoritative. No Sparkle scheduling or identifiers.
                updater.automaticallyChecksForUpdates = false
                updater.automaticallyDownloadsUpdates = false
                updater.sendsSystemProfile = false
                updater.userAgentString = "DragTwoZero-Updater"
                try updater.start()
                self.updater = updater
            }
            // Sparkle's background-check API creates a persistent random phased-
            // rollout identifier even for unphased feeds. Both check paths use
            // our quiet custom driver and the manual API to avoid that identifier.
            updater?.checkForUpdates()
        } catch { set(.idle, "The updater could not start. Try again later.") }
    }
    func openUpdate() {
        switch phase {
        case .idle: check()
        case .available:
            guard let choice, let release,
                  confirm("Install Drag 2.0 \(release.version)?",
                          "Download and verify the signed update, then prepare it for installation. Drag 2.0 stays open until you confirm Restart. You can cancel before restarting.",
                          "Download & Install") else { return }
            guard phase == .available, !cancelRequested, self.choice != nil else { return }
            self.choice = nil; downloadAuthorized = true
            set(.downloading, "Downloading signed update…")
            choice(.install)
        case .ready, .installing:
            guard let action = retryTermination ?? choice.map({ reply in { reply(.install) } }) else { return }
            if let reason = activity().restartBlock { message = reason; broadcast(); return }
            guard confirm("Restart Drag 2.0?", "Install the verified update and reopen Drag 2.0. Your settings and permissions are retained.", "Restart") else { return }
            guard !cancelRequested, downloadAuthorized, [.ready, .installing].contains(phase),
                  choice != nil || retryTermination != nil else { return }
            // The modal dialog pumps the run loop: read real state again after consent.
            if let reason = activity().restartBlock { message = reason; broadcast(); return }
            if originalIntent == nil {
                let current = activity()
                originalIntent = (current.activationIntent, current.inputPaused)
            }
            let previousPhase = phase
            let token = UUID(); preparation = token
            restartAuthorized = false
            UpdateRelaunch.clear(defaults)
            set(.preparing, "Stopping safely before restarting…")
            beforeRestart({ [weak self] in
                self?.preparation == token && self?.phase == .preparing && self?.cancelRequested == false
            }) { [weak self] success in
                guard let self, self.preparation == token, self.phase == .preparing, !self.cancelRequested else { return }
                guard success, self.activity().restartBlock == nil else {
                    self.abandonRestart()
                    self.set(previousPhase, "Could not stop safely. Try again, or cancel the update.")
                    return
                }
                guard let intent = self.originalIntent, let release = self.release else { return }
                UpdateRelaunch.save(intent.enabled, paused: intent.paused, version: release.version, defaults: self.defaults, bundle: self.bundle)
                self.restartAuthorized = true; self.choice = nil; self.retryTermination = nil
                self.set(.installing, "Installing and restarting…")
                action()
            }
        default: break
        }
    }
    func cancel() {
        guard canCancel else { return }
        cancelRequested = true; checkGeneration = UUID(); task?.cancel(); task = nil
        clearHandoff()
        let waitForSparkle = updater?.sessionInProgress == true
        let wasExtracting = phase == .extracting
        if waitForSparkle { set(.cancelling, "Cancelling update…") }
        if let choice {
            self.choice = nil; choice(.skip)
        } else if let cancellation {
            self.cancellation = nil; cancellation()
        } else if wasExtracting || waitForSparkle {
            // Sparkle cannot cancel extraction. Cancel its staged installer as soon as it replies.
            message = "Cancelling update…"; broadcast(); return
        }
        // Installer replies are asynchronous. Keep the quit guard until Sparkle
        // confirms the staged installer is gone, rather than racing install-on-quit.
        if waitForSparkle { return }
        downloadAuthorized = false; release = nil
        set(.idle, "Update cancelled.")
    }
    /// Sparkle can install a staged update on ordinary quit. Block that path until restart consent.
    func permitsTermination() -> Bool {
        guard downloadAuthorized else { return true }
        guard restartAuthorized, activity().restartBlock == nil else {
            restartAuthorized = false
            UpdateRelaunch.clear(defaults)
            message = activity().restartBlock ?? "Restart or cancel the pending update before quitting."
            broadcast(); return false
        }
        return true
    }
    private func clearHandoff() {
        preparation = UUID(); restartAuthorized = false; originalIntent = nil
        UpdateRelaunch.clear(defaults)
        abandonRestart()
    }
    private func set(_ phase: Phase, _ message: String) { self.phase = phase; self.message = message; broadcast() }
    private func broadcast() {
        DebugLog.shared.record(.update(phase: phase, codes: failureCodes.isEmpty ? failureCode.map { [$0] } ?? [] : failureCodes))
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    // MARK: Sparkle policy. API metadata selects an ordinary release; the signed feed must match it.
    func feedURLString(for updater: SPUUpdater) -> String? { release?.feed.absoluteString }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { [] }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
    func feedParameters(for updater: SPUUpdater, sendingSystemProfile: Bool) -> [[String: String]] { [] }
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool { false }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard release?.matches(item) == true else {
            throw NSError(domain: "DragTwoZero.Updater", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The signed update does not match the ordinary GitHub release."])
        }
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        choice = nil; cancellation = nil; retryTermination = nil
        clearHandoff()
        downloadAuthorized = false; restartAuthorized = false
        release = nil
        if cancelRequested { set(.idle, "Update cancelled.") }
        else if let error {
            failureCode = (error as NSError).code
            failureCodes = Self.errorCodes(error)
            set(.idle, Self.failureMessage(error))
        }
        else if phase != .idle { set(.idle, "Update dismissed.") }
    }
    private static func failureMessage(_ error: Error) -> String {
        let error = error as NSError
        guard error.domain == SUSparkleErrorDomain else { return "Update could not finish. Try again later." }
        if errorCodes(error).contains(where: { [3001, 3002].contains($0) }) {
            return "Update signature verification failed. The update was rejected."
        }
        switch error.code {
        case 1001: return "No newer compatible update is available."
        case 3001, 3002: return "Update signature verification failed. The update was rejected."
        case 4007: return "Update installation cancelled."
        case 1000, 1002: return "Couldn’t verify or read the update feed. Try again later."
        case 2001: return "Couldn’t download the update. Check your connection and try again."
        default: return "Update could not finish. Try again later."
        }
    }
    private static func errorCodes(_ error: Error) -> [Int] {
        var codes: [Int] = []
        var next: NSError? = error as NSError
        // Sparkle may wrap an installer validation failure. Retain codes only,
        // never filesystem paths or downloaded server text from the error.
        for _ in 0..<8 {
            guard let current = next else { break }
            if current.domain == SUSparkleErrorDomain { codes.append(current.code) }
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
            if next === current { break }
        }
        return codes
    }

    // MARK: User driver. All actions remain visible in About, including background-check results.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { self.cancellation = cancellation }
    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancellation = nil
        guard !cancelRequested, state.stage != .installing, let release, release.matches(item) else { reply(.skip); return }
        offerUpdate(release, reply: reply)
    }
    func offerUpdate(_ release: ReleaseUpdate, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        self.release = release
        choice = reply
        set(.available, "Version \(release.version) is available.")
        notify(release.version)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        failureCode = (error as NSError).code
        failureCodes = Self.errorCodes(error)
        set(.cancelling, "No newer compatible update is available."); acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        // Raw errors can contain filesystem paths or server payloads; keep diagnostics generic.
        failureCode = (error as NSError).code
        clearHandoff()
        set(.cancelling, Self.failureMessage(error)); acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        if cancelRequested || !downloadAuthorized || phase != .downloading { cancellation(); return }
        downloadedBytes = 0
        set(.downloading, "Downloading signed update…")
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard phase == .downloading, !cancelRequested else { return }
        let (total, overflow) = downloadedBytes.addingReportingOverflow(length)
        downloadedBytes = overflow ? UInt64.max : total
        if let release, release.length > 0 {
            let percent = Int(min(1, Double(downloadedBytes) / Double(release.length)) * 100)
            message = "Downloading signed update… \(percent)%"; broadcast()
        }
    }
    func showDownloadDidStartExtractingUpdate() {
        guard [.downloading, .cancelling].contains(phase) else { return }
        cancellation = nil; set(.extracting, cancelRequested ? "Cancelling after verification…" : "Verifying and preparing update…")
    }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !cancelRequested, downloadAuthorized, [.downloading, .extracting].contains(phase) else { reply(.skip); return }
        choice = reply; cancellation = nil
        set(.ready, activity().restartBlock ?? "Verified update ready. Restart when you’re ready.")
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        if !applicationTerminated, phase == .installing, downloadAuthorized, !cancelRequested {
            // A termination veto must require another explicit Restart click.
            self.retryTermination = retryTerminatingApplication
            broadcast()
        }
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() { cancellation = nil; choice = nil }
    func showUpdateInFocus() { NotificationCenter.default.post(name: Notification.Name("DragShowAbout"), object: nil) }

    private func notify(_ version: String) {
        guard automaticChecks, defaults.string(forKey: "lastNotifiedRelease") != version else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            DispatchQueue.main.async {
                guard self.automaticChecks, self.phase == .available else { return }
                let content = UNMutableNotificationContent()
                content.title = "Drag 2.0 update available"
                content.body = "\(version) is available. Open About to review and install it."
                center.add(UNNotificationRequest(identifier: "drag-update-\(version)", content: content, trigger: nil)) { error in
                    if error == nil { self.defaults.set(version, forKey: "lastNotifiedRelease") }
                }
            }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Notification.Name("DragShowAbout"), object: nil) }
        completionHandler()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner]) }
}
