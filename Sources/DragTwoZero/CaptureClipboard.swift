import AppKit

/// A temporary paste payload. Only this exact clipboard revision may be restored.
final class CaptureClipboard {
    static let marker = NSPasteboard.PasteboardType("com.maximkich.dragtwozero.temporary-context")
    private static let retainedMarker = NSPasteboard.PasteboardType("com.maximkich.dragtwozero.retained-context")
    private static let legacyMarker = NSPasteboard.PasteboardType("com.maximkich.drop-to-t3.temporary-context")
    private final class WeakOwner {
        weak var value: CaptureClipboard?
        init(_ value: CaptureClipboard) { self.value = value }
    }
    private static let ownerLock = NSLock()
    private static var owners: [String: WeakOwner] = [:]

    struct Preparation {
        fileprivate let board: NSPasteboard
        fileprivate let saved: [[NSPasteboard.PasteboardType: Data]]
        fileprivate let originalChange: Int
    }
    private let prepared: Preparation
    private let restoreAfterPaste: Bool
    private var ownedChange: Int?
    private var captureID: String?

    /// Reading promised data may take time. Never modify the clipboard here.
    static func prepare(board: NSPasteboard = .general) -> Preparation {
        let originalChange = board.changeCount
        func visibleContents() -> [[NSPasteboard.PasteboardType: Data]] {
            (board.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.filter { $0 != marker && $0 != retainedMarker && $0 != legacyMarker }.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
            }
        }
        let saved: [[NSPasteboard.PasteboardType: Data]]
        if (board.types?.contains(marker) == true || board.types?.contains(legacyMarker) == true) && board.types?.contains(retainedMarker) != true {
            // A cancelled posted paste may still be waiting to restore. Carry
            // its original clipboard through a newer transaction, rather than
            // treating that app-owned temporary payload as the user's copy.
            let identifier = board.string(forType: marker)
            ownerLock.lock()
            let owner = identifier.flatMap { owners[$0]?.value }
            ownerLock.unlock()
            saved = owner.flatMap {
                $0.prepared.board.name == board.name && $0.isCurrent && board.changeCount == originalChange ? $0.prepared.saved : nil
            // After a restart (or an externally rewritten revision), the old
            // in-memory backup is unavailable. Preserve today's visible copy,
            // without stale metadata, rather than restoring an empty board.
            } ?? visibleContents()
        } else {
            saved = visibleContents()
        }
        return Preparation(board: board, saved: saved, originalChange: originalChange)
    }

    init(prepared: Preparation, restoreAfterPaste: Bool = true) { self.prepared = prepared; self.restoreAfterPaste = restoreAfterPaste }

    deinit {
        if let captureID {
            Self.ownerLock.lock(); Self.owners.removeValue(forKey: captureID); Self.ownerLock.unlock()
        }
    }

    convenience init(text: String, board: NSPasteboard = .general, restoreAfterPaste: Bool = true) {
        self.init(prepared: Self.prepare(board: board), restoreAfterPaste: restoreAfterPaste)
        _ = install(text: text)
    }

    /// Reject a copy made while promised clipboard data was being materialized.
    @discardableResult
    func install(text: String, isCurrent: () -> Bool = { true }) -> Bool {
        guard ownedChange == nil, isCurrent() else { return false }
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        let identifier = UUID().uuidString
        item.setString(identifier, forType: Self.marker)
        if !restoreAfterPaste { item.setString("retained", forType: Self.retainedMarker) }
        let board = prepared.board
        guard board.changeCount == prepared.originalChange, isCurrent() else { return false }
        let clearedChange = board.clearContents()
        // NSPasteboard has no atomic compare-and-swap. Recheck the revision
        // returned by our clear before writing, so an intervening copy wins.
        guard board.changeCount == clearedChange, isCurrent() else {
            ownedChange = clearedChange
            return false
        }
        ownedChange = clearedChange
        guard board.writeObjects([item]) else { return false }
        let writtenChange = board.changeCount
        guard board.string(forType: Self.marker) == identifier, board.changeCount == writtenChange else {
            ownedChange = nil
            return false
        }
        ownedChange = writtenChange
        captureID = identifier
        Self.ownerLock.lock(); Self.owners[identifier] = WeakOwner(self); Self.ownerLock.unlock()
        return true
    }

    var needsRestoration: Bool { restoreAfterPaste && isCurrent }

    var isCurrent: Bool {
        guard let ownedChange, let captureID else { return false }
        let board = prepared.board
        return board.changeCount == ownedChange && board.string(forType: Self.marker) == captureID
            && board.changeCount == ownedChange
    }

    /// An unposted transaction restores immediately. Once posted, only positive
    /// confirmation permits restoration: a timeout cannot prove the recipient
    /// has read the payload. Every path still requires exact revision ownership.
    func abortBeforePaste() { restore() }
    func finish(confirmed: Bool) {
        if restoreAfterPaste && confirmed { restore() }
    }

    private func restore() {
        let board = prepared.board
        guard let ownedChange, board.changeCount == ownedChange else { return }
        // Materialize restore objects before the last ownership check.
        let items = prepared.saved.filter { !$0.isEmpty }.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        guard board.changeCount == ownedChange else { return }
        let clearedChange = board.clearContents()
        self.ownedChange = nil
        guard board.changeCount == clearedChange else { return }
        if !items.isEmpty { board.writeObjects(items) }
    }
}
