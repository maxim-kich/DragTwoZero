import AppKit
import XCTest
@testable import DragTwoZero

final class CaptureClipboardTests: XCTestCase {
    func testUnsettledClipboardBlocksUpdateOnlyWhileBackupIsOwned() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Original", forType: .string)
        let clipboard = CaptureClipboard(text: "Pending paste", board: board)
        clipboard.finish(confirmed: false)
        XCTAssertTrue(clipboard.needsRestoration)
        board.clearContents(); board.setString("Newer copy", forType: .string)
        XCTAssertFalse(clipboard.needsRestoration)
        clipboard.finish(confirmed: true)
        XCTAssertEqual(board.string(forType: .string), "Newer copy")
        let retained = CaptureClipboard(text: "Explicit overwrite", board: board, restoreAfterPaste: false)
        XCTAssertFalse(retained.needsRestoration)
    }
    func testRestartedAppPreservesVisibleOrphanPayloadAndAllFormats() {
        for staleMarker in [CaptureClipboard.marker, .init("com.maximkich.drop-to-t3.temporary-context")] {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let item = NSPasteboardItem()
            item.setString("Visible copy from previous process", forType: .string)
            item.setData(Data("<b>Visible copy</b>".utf8), forType: .html)
            item.setString("previous-process", forType: staleMarker)
            board.writeObjects([item])
            let next = CaptureClipboard(text: "New payload", board: board)
            next.finish(confirmed: true)
            XCTAssertEqual(board.string(forType: .string), "Visible copy from previous process")
            XCTAssertEqual(board.data(forType: .html), Data("<b>Visible copy</b>".utf8))
            XCTAssertNil(board.string(forType: staleMarker))
        }
    }

    func testAStaleMarkerOnANewerRevisionCannotClearThatNewerCopy() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Original", forType: .string)
        let old = CaptureClipboard(text: "Unconfirmed", board: board)
        let marker = board.string(forType: CaptureClipboard.marker)!
        board.clearContents()
        let newer = NSPasteboardItem()
        newer.setString("Newer visible copy", forType: .string)
        newer.setString(marker, forType: CaptureClipboard.marker)
        board.writeObjects([newer])
        XCTAssertFalse(old.isCurrent)
        let next = CaptureClipboard(text: "Next payload", board: board)
        old.finish(confirmed: true)
        next.finish(confirmed: true)
        XCTAssertEqual(board.string(forType: .string), "Newer visible copy")
        XCTAssertNil(board.string(forType: CaptureClipboard.marker))
    }
    func testSuccessRestoresUserClipboardAndRemovesMarker() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("User copy", forType: .string)
        let capture = CaptureClipboard(text: "Captured content", board: board)
        XCTAssertEqual(board.string(forType: .string), "Captured content")
        capture.finish(confirmed: true)
        XCTAssertEqual(board.string(forType: .string), "User copy")
        XCTAssertNil(board.string(forType: CaptureClipboard.marker))
    }
    func testSuccessClearsClipboardWhenPreviousContentWasAnotherCapture() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let failed = CaptureClipboard(text: "Old capture", board: board)
        failed.finish(confirmed: false)
        let next = CaptureClipboard(text: "New capture", board: board)
        next.finish(confirmed: true)
        XCTAssertNil(board.string(forType: .string))
        XCTAssertNil(board.string(forType: CaptureClipboard.marker))
    }
    func testNewerUserCopyIsNeverOverwritten() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let capture = CaptureClipboard(text: "Captured", board: board)
        board.clearContents(); board.setString("New user copy", forType: .string)
        capture.finish(confirmed: true)
        XCTAssertEqual(board.string(forType: .string), "New user copy")
    }
    func testUnconfirmedPasteKeepsRecoveryContent() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let capture = CaptureClipboard(text: "Recovery content", board: board)
        capture.finish(confirmed: false)
        XCTAssertEqual(board.string(forType: .string), "Recovery content")
    }
    func testUnconfirmedBufferPasteStaysAvailableToLateReadersAndConfirmationRestoresAllFormats() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("Original copy", forType: .string)
        item.setData(Data("<b>Original copy</b>".utf8), forType: .html)
        board.writeObjects([item])
        let capture = CaptureClipboard(text: "Buffer payload", board: board)
        // A timeout or cancelled verification says nothing about when the
        // recipient will read. Repeated uncertain completions must not swap it.
        capture.finish(confirmed: false)
        capture.finish(confirmed: false)
        XCTAssertEqual(board.string(forType: .string), "Buffer payload")
        XCTAssertTrue(capture.isCurrent)
        capture.finish(confirmed: true)
        XCTAssertEqual(board.string(forType: .string), "Original copy")
        XCTAssertEqual(board.data(forType: .html), Data("<b>Original copy</b>".utf8))
        XCTAssertNil(board.string(forType: CaptureClipboard.marker))
    }
    func testUnconfirmedBufferPasteNeverRestoresOverANewerUserCopy() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Original", forType: .string)
        let capture = CaptureClipboard(text: "Buffer", board: board)
        board.clearContents(); board.setString("Newer copy", forType: .string)
        capture.finish(confirmed: false)
        capture.finish(confirmed: true)
        XCTAssertEqual(board.string(forType: .string), "Newer copy")
    }
    func testNextConfirmedDeliveryPreservesOriginalAfterAnUncertainTransfer() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Original user copy", forType: .string)
        let first = CaptureClipboard(text: "First payload", board: board)
        first.finish(confirmed: false)
        let second = CaptureClipboard(text: "Second payload", board: board)
        first.finish(confirmed: true)
        XCTAssertEqual(board.string(forType: .string), "Second payload")
        second.finish(confirmed: true)
        XCTAssertEqual(board.string(forType: .string), "Original user copy")
    }
    func testExplicitOverwriteStillKeepsThePayload() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Original", forType: .string)
        let capture = CaptureClipboard(text: "Opted-in payload", board: board, restoreAfterPaste: false)
        capture.finish(confirmed: false)
        capture.finish(confirmed: true)
        XCTAssertEqual(board.string(forType: .string), "Opted-in payload")
    }
    func testOverwriteModeKeepsPayloadAndNextRestoreTreatsItAsUserClipboard() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Original", forType: .string)
        let retained = CaptureClipboard(text: "Retained capture", board: board, restoreAfterPaste: false)
        retained.finish(confirmed: true)
        XCTAssertEqual(board.string(forType: .string), "Retained capture")
        let temporary = CaptureClipboard(text: "Next capture", board: board)
        temporary.finish(confirmed: true)
        XCTAssertEqual(board.string(forType: .string), "Retained capture")
        XCTAssertNil(board.string(forType: CaptureClipboard.marker))
    }

    func testOverwriteModeNeverReplacesNewerCopyAtFinish() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let retained = CaptureClipboard(text: "Capture", board: board, restoreAfterPaste: false)
        board.clearContents(); board.setString("Newer user copy", forType: .string)
        retained.finish(confirmed: true)
        XCTAssertEqual(board.string(forType: .string), "Newer user copy")
    }

    func testOverwriteModeRollsBackIfNoPasteWasPosted() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("Original", forType: .string)
        let retained = CaptureClipboard(text: "Capture", board: board, restoreAfterPaste: false)
        retained.abortBeforePaste()
        XCTAssertEqual(board.string(forType: .string), "Original")
    }
}
