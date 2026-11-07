import Foundation

/// Only fixed event names, booleans, numeric error codes and bounded app-state
/// tokens can enter the log. Never pass Error descriptions or captured content.
enum DebugEvent {
    enum Action: String {
        case launched, quitting, settingsOpened, settingsClosed, onboardingOpened
        case captureArmed, captureResumed, captureStopped, dockHidden, dockShown
    }
    case action(Action)
    case health(accessibility: Bool, listener: Bool, paused: Bool, phase: CaptureState.Phase, buffer: Bool, transfer: Bool)
    case inputInterrupted(timeout: Bool)
    case slowInputHandler(milliseconds: Int)
    case acceptance(stage: StaticString, reason: StaticString)
    case update(phase: UpdateChecker.Phase, codes: [Int])
    case haptic(pattern: Int, active: Bool, keyWindow: Bool)
    case backdrop(light: Bool?)

    fileprivate var fields: [String: Any] {
        switch self {
        case let .action(action): return ["event": action.rawValue]
        case let .health(accessibility, listener, paused, phase, buffer, transfer):
            return ["event": "health", "accessibility": accessibility, "listener": listener,
                    "paused": paused, "phase": String(describing: phase), "bufferOccupied": buffer, "transfer": transfer]
        case let .inputInterrupted(timeout): return ["event": "inputInterrupted", "timeout": timeout]
        case let .slowInputHandler(milliseconds): return ["event": "slowInputHandler", "milliseconds": milliseconds]
        case let .acceptance(stage, reason): return ["event": "acceptance", "stage": String(describing: stage), "reason": String(describing: reason)]
        case let .update(phase, codes): return ["event": "update", "phase": String(describing: phase), "errorCodes": Array(codes.prefix(16))]
        case let .haptic(pattern, active, keyWindow): return ["event": "haptic", "pattern": pattern, "active": active, "keyWindow": keyWindow]
        case let .backdrop(light): return ["event": "backdrop", "tone": light.map { $0 ? "light" : "dark" } ?? "native-fallback"]
        }
    }
}

final class DebugLog {
    static let shared = DebugLog(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DragTwoZero", isDirectory: true),
        enabled: Bundle.main.bundleIdentifier == "com.maximkich.drop-to-t3")
    private let directory: URL
    private let limit: Int
    private let enabled: Bool
    private let queue = DispatchQueue(label: "drag.debug-log", qos: .utility)
    private var lastPayload: Data?
    private var current: URL { directory.appendingPathComponent("status.log") }
    private var previous: URL { directory.appendingPathComponent("status.previous.log") }

    init(directory: URL, limit: Int = 256 * 1024, enabled: Bool = true) {
        self.directory = directory
        self.limit = max(512, limit)
        self.enabled = enabled
    }

    func record(_ event: DebugEvent) {
        guard enabled else { return }
        let date = Date().timeIntervalSince1970
        queue.async { [self] in
            var fields = event.fields
            guard Self.safe(fields), let payload = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
                  payload != lastPayload else { return }
            fields["timestamp"] = date
            guard var data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
            data.append(10)
            guard data.count <= limit else { return }
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                // Refuse symlinks instead of writing through an unexpected path.
                for url in [current, previous] {
                    if let type = try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType,
                       type != .typeRegular { return }
                }
                let size = (try? fm.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
                if size > limit - data.count {
                    let tail = try boundedRead(current)
                    try tail.write(to: previous, options: .atomic)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previous.path)
                    try Data().write(to: current, options: .atomic)
                }
                if !fm.fileExists(atPath: current.path) {
                    guard fm.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
                }
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
                let handle = try FileHandle(forWritingTo: current)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                lastPayload = payload
            } catch { /* Logging must never interrupt capture or UI. */ }
        }
    }

    /// Serialized with pending writes; called off-main by export and directly by tests.
    func snapshot(appVersion: String) throws -> Data {
        try queue.sync { try makeSnapshot(appVersion: appVersion) }
    }

    func export(to destination: URL, appVersion: String, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            let result = Result { try makeSnapshot(appVersion: appVersion).write(to: destination, options: .atomic) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func makeSnapshot(appVersion: String) throws -> Data {
        let version = appVersion.range(of: "^[0-9]+(\\.[0-9]+){0,3}$", options: .regularExpression) != nil && appVersion.count < 32 ? appVersion : "unknown"
        var result = Data("Drag 2.0 debug log — version \(version)\nLocal diagnostics. Exported by the user; nothing is sent automatically.\nNo captured content, clipboard data, URLs, app names, paths, or user/device identifiers.\n\n".utf8)
        for url in [previous, current] {
            for line in try boundedRead(url).split(separator: 10) {
                // Older plaintext logs and malformed/unrecognized entries are
                // omitted. Export never bundles crash reports or other logs.
                guard let fields = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], Self.safe(fields),
                      let clean = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { continue }
                result.append(clean); result.append(10)
            }
        }
        return result
    }

    private func boundedRead(_ url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else { return Data() }
        let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        guard type == .typeRegular else { return Data() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size > UInt64(limit) ? size - UInt64(limit) : 0)
        var data = try handle.read(upToCount: limit) ?? Data()
        if size > UInt64(limit), let newline = data.firstIndex(of: 10) { data.removeSubrange(...newline) }
        return data
    }

    private static func safe(_ fields: [String: Any]) -> Bool {
        let events: Set<String> = ["launched", "quitting", "settingsOpened", "settingsClosed", "onboardingOpened", "captureArmed", "captureResumed", "captureStopped", "dockHidden", "dockShown", "health", "inputInterrupted", "slowInputHandler", "acceptance", "update", "haptic", "backdrop"]
        let phases: Set<String> = ["idle", "armed", "resolving", "selecting", "ready", "dragging", "locked", "checking", "available", "downloading", "extracting", "preparing", "installing", "cancelling"]
        guard let event = fields["event"] as? String, events.contains(event) else { return false }
        for (key, value) in fields {
            switch key {
            case "event": continue
            case "phase": guard let value = value as? String, phases.contains(value) else { return false }
            case "tone": guard let value = value as? String, ["light", "dark", "native-fallback"].contains(value) else { return false }
            case "stage", "reason":
                guard let value = value as? String, value.count <= 80,
                      value.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else { return false }
            case "timestamp", "pattern", "milliseconds": guard value is NSNumber else { return false }
            case "accessibility", "listener", "paused", "bufferOccupied", "transfer", "timeout", "active", "keyWindow": guard value is NSNumber else { return false }
            case "errorCodes": guard let codes = value as? [Int], codes.count <= 16 else { return false }
            default: return false
            }
        }
        return true
    }
}
