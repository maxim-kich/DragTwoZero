import AppKit
import XCTest
@testable import DragTwoZero

final class SelectedTextHintTests: XCTestCase {
    private func selection(_ text: String = "Only selected words", location: Int = 3) -> CaptureCandidate {
        var result = CaptureCandidate(payload: .init(title: "Selected text", markdown: text), frame: CGRect(x: 100, y: 100, width: 1, height: 1))
        result.anchor = AXUIElementCreateApplication(101)
        result.context = CaptureElementContext(window: AXUIElementCreateApplication(201), document: nil, documentURL: nil)
        result.selectedTextRange = CFRange(location: location, length: text.utf16.count)
        result.textFrames = []
        return result
    }
    private func wait(_ predicate: () -> Bool) {
        let end = Date().addingTimeInterval(1.5)
        while !predicate() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    private func withDelegate(_ resolve: @escaping (CGPoint, () -> Bool) -> SelectedTextLookup,
                              source: ((CGPoint, SelectionCaptureSession) -> SourceCaptureLookup)? = nil,
                              run: (AppDelegate) -> Void) {
        _ = NSApplication.shared
        let keys = ["captureShortcut", "animationsEnabled", "multiselectEnabled", CapturePreferences.bufferEnabledKey]
        let defaults = UserDefaults.standard, saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        CaptureShortcut.current = .defaultValue; CapturePreferences.animationsEnabled = false; CapturePreferences.bufferEnabled = false
        CapturePreferences.multiselectEnabled = false
        let delegate = AppDelegate(sourceLookupResolver: source, backdropToneResolver: { _ in nil }, destinationLookupResolver: { _ in nil }, selectedTextPickupResolver: resolve)
        defer { delegate.cancel(); delegate.bufferOverlay.close(); delegate.overlay.close() }
        delegate.captureEnabled = true; delegate.state.modifiers(held: true); delegate.pointer = CGPoint(x: 100, y: 100)
        run(delegate)
    }
    private func event(_ type: CGEventType, at point: CGPoint, held: Bool = true) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.type = type; event.location = point
        event.flags = held ? [.maskCommand, .maskAlternate] : []
        return event
    }
    private func grab(_ delegate: AppDelegate) throws {
        delegate.prepareSelectedTextHint(at: delegate.pointer)
        wait { !delegate.selectedTextPickupPending }
        XCTAssertEqual(delegate.state.phase, .ready)
        let hint = try XCTUnwrap(delegate.overlay.dragHintFrame)
        XCTAssertTrue(delegate.handle(.leftMouseDown, event(.leftMouseDown, at: CGPoint(x: hint.midX, y: hint.midY))))
        wait { !delegate.validatingSource }
    }

    func testHintShowsSelectionBeginningWithWhitespaceCollapsedAndPreservesItOnGrab() throws {
        let selected = selection("  First words\n\tthen more words  ")
        var failure: Error?
        withDelegate({ _, _ in .selected(selected) }) { delegate in
            delegate.prepareSelectedTextHint(at: delegate.pointer)
            wait { !delegate.selectedTextPickupPending }
            XCTAssertEqual(delegate.overlay.dragHintText, "First words then more words")
            do {
                let hint = try XCTUnwrap(delegate.overlay.dragHintFrame)
                XCTAssertTrue(delegate.handle(.leftMouseDown, event(.leftMouseDown, at: CGPoint(x: hint.midX, y: hint.midY))))
                wait { !delegate.validatingSource }
            } catch { failure = error; return }
            XCTAssertEqual(delegate.overlay.dragHintText, "First words then more words")
            XCTAssertEqual(delegate.captured?.payload.text, selected.payload.text)
        }
        if let failure { throw failure }
    }

    func testSelectionWithoutGlyphBoundsShowsStationaryHintBeforeAnyDrag() {
        let selected = selection(), revision = NSPasteboard.general.changeCount
        withDelegate({ _, _ in .selected(selected) }) { delegate in
            delegate.prepareSelectedTextHint(at: delegate.pointer)
            wait { !delegate.selectedTextPickupPending }
            XCTAssertEqual(delegate.state.phase, .ready)
            XCTAssertNil(delegate.captured, "The user must grab the hint before dragging")
            XCTAssertTrue(delegate.selectedTextHint?.visibleHighlightFrames.isEmpty == true)
            let frame = delegate.overlay.dragHintFrame
            XCTAssertNotNil(frame)
            XCTAssertEqual(frame!.midX, delegate.pointer.x, accuracy: 1)
            XCTAssertEqual(frame!.midY, delegate.pointer.y, accuracy: 1)
            XCTAssertTrue(frame!.contains(delegate.pointer), "The initial click must grab the hint without moving the pointer")
            XCTAssertFalse(delegate.handle(.mouseMoved, event(.mouseMoved, at: CGPoint(x: 400, y: 300))))
            XCTAssertEqual(delegate.overlay.dragHintFrame, frame, "The hint must stay still so it can be grabbed")
            XCTAssertEqual(NSPasteboard.general.changeCount, revision)
        }
    }

    func testGrabbingHintStartsExactSelectionAndInvalidDropDoesNotPaste() throws {
        let selected = selection(), revision = NSPasteboard.general.changeCount
        var failure: Error?
        withDelegate({ _, _ in .selected(selected) }) { delegate in
            do { try grab(delegate) } catch { failure = error; return }
            XCTAssertEqual(delegate.state.phase, .dragging)
            XCTAssertEqual(delegate.captured?.payload.text, "Only selected words")
            XCTAssertEqual(delegate.captured?.selectedTextRange?.location, 3)
            XCTAssertTrue(delegate.handle(.leftMouseUp, event(.leftMouseUp, at: CGPoint(x: 800, y: 700))))
            XCTAssertNil(delegate.captured)
            XCTAssertEqual(NSPasteboard.general.changeCount, revision)
        }
        if let failure { throw failure }
    }

    func testChangedSelectionCannotBecomeAWholeBlockWhenHintIsGrabbed() throws {
        let old = selection(), changed = selection("Changed selection")
        var reads = 0, failure: Error?
        withDelegate({ _, _ in reads += 1; return .selected(reads == 1 ? old : changed) }) { delegate in
            do { try grab(delegate) } catch { failure = error; return }
            XCTAssertNil(delegate.captured)
            XCTAssertNil(delegate.selectedTextHint)
            XCTAssertNotEqual(delegate.state.phase, .dragging)
        }
        if let failure { throw failure }
    }

    func testShortcutReleaseCancelsReadyHintButPreservesStartedDrag() throws {
        let selected = selection()
        var failure: Error?
        for dragging in [false, true] {
            withDelegate({ _, _ in .selected(selected) }) { delegate in
                if dragging { do { try grab(delegate) } catch { failure = error; return } }
                else { delegate.prepareSelectedTextHint(at: delegate.pointer); wait { !delegate.selectedTextPickupPending } }
                XCTAssertFalse(delegate.handle(.flagsChanged, event(.flagsChanged, at: delegate.pointer, held: false)), "The host must receive its modifier release")
                if dragging {
                    XCTAssertNotNil(delegate.selectedTextHint)
                    XCTAssertEqual(delegate.captured?.payload.text, selected.payload.text)
                    XCTAssertEqual(delegate.state.phase, .dragging)
                    XCTAssertTrue(delegate.handle(.leftMouseUp, event(.leftMouseUp, at: delegate.pointer, held: false)))
                    XCTAssertNil(delegate.captured, "An invalid drop still cancels after releasing the shortcut")
                } else {
                    XCTAssertNil(delegate.selectedTextHint); XCTAssertNil(delegate.captured)
                    XCTAssertNotEqual(delegate.state.phase, .dragging)
                }
            }
        }
        if let failure { throw failure }
    }

    func testShortcutCanBeReleasedWhileGrabValidationIsPending() throws {
        let selected = selection(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var reads = 0
        withDelegate({ _, _ in
            reads += 1
            if reads > 1 { entered.signal(); _ = release.wait(timeout: .now() + 1) }
            return .selected(selected)
        }) { delegate in
            delegate.prepareSelectedTextHint(at: delegate.pointer); wait { !delegate.selectedTextPickupPending }
            XCTAssertTrue(delegate.overlay.dragHintFrame?.contains(delegate.pointer) == true)
            XCTAssertTrue(delegate.handle(.leftMouseDown, event(.leftMouseDown, at: delegate.pointer)))
            XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
            XCTAssertFalse(delegate.handle(.flagsChanged, event(.flagsChanged, at: delegate.pointer, held: false)))
            XCTAssertEqual(delegate.state.phase, .dragging)
            XCTAssertTrue(delegate.validatingSource)
            release.signal(); wait { !delegate.validatingSource }
            XCTAssertEqual(delegate.captured?.payload.text, selected.payload.text)
        }
    }

    func testSelectedTextHintStaysUnderPointerAtDisplayEdges() {
        let screen = CGRect(x: -1440, y: -900, width: 1440, height: 900), size = CGSize(width: 170, height: 48)
        for point in [CGPoint(x: -1432, y: -892), CGPoint(x: -8, y: -8), CGPoint(x: -700, y: -400)] {
            let frame = selectedTextHintFrame(at: point, size: size, screen: screen)
            XCTAssertTrue(frame.insetBy(dx: -0.1, dy: -0.1).contains(point))
            XCTAssertTrue(screen.contains(frame))
        }
    }

    func testClickOutsideHintCancelsAndPreservesNativeClick() {
        let selected = selection()
        withDelegate({ _, _ in .selected(selected) }) { delegate in
            delegate.prepareSelectedTextHint(at: delegate.pointer); wait { !delegate.selectedTextPickupPending }
            XCTAssertFalse(delegate.handle(.leftMouseDown, event(.leftMouseDown, at: CGPoint(x: 700, y: 600))))
            XCTAssertNil(delegate.selectedTextHint); XCTAssertNil(delegate.captured)
        }
    }

    func testLatePickupAfterCancellationCannotReappear() {
        let selected = selection(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        withDelegate({ _, _ in entered.signal(); _ = release.wait(timeout: .now() + 1); return .selected(selected) }) { delegate in
            delegate.prepareSelectedTextHint(at: delegate.pointer)
            XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
            delegate.cancel(); release.signal()
            let end = Date().addingTimeInterval(0.15)
            while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertNil(delegate.selectedTextHint); XCTAssertNil(delegate.captured)
            XCTAssertFalse(delegate.selectedTextPickupPending)
        }
    }

    func testUnreadableSelectionDoesNotInventAPayload() {
        withDelegate({ _, _ in .unavailable }) { delegate in
            delegate.prepareSelectedTextHint(at: delegate.pointer); wait { !delegate.selectedTextPickupPending }
            XCTAssertNil(delegate.selectedTextHint); XCTAssertNil(delegate.captured)
            XCTAssertNotEqual(delegate.state.phase, .ready)
        }
    }

    func testUnavailablePickupKeepsArmedButFreshPressStillRejectsUnresolvedSelection() {
        let revision = NSPasteboard.general.changeCount
        var reads = 0
        withDelegate({ _, _ in .unavailable }, source: { _, _ in
            reads += 1
            return SourceCaptureLookup.resolve(.unavailable, at: .zero) {
                XCTFail("Unresolved selection cannot become a paragraph")
                return nil
            }
        }) { delegate in
            delegate.prepareSelectedTextHint(at: delegate.pointer)
            wait { !delegate.selectedTextPickupPending }
            XCTAssertEqual(delegate.state.phase, .armed)
            XCTAssertFalse(delegate.selectedTextGesturePrepared)
            wait { reads > 0 && !delegate.probing }
            XCTAssertFalse(delegate.allowsMarquee)
            let hoverReads = reads
            XCTAssertTrue(delegate.handle(.leftMouseDown, event(.leftMouseDown, at: delegate.pointer)))
            wait { delegate.pendingPress == nil }
            XCTAssertGreaterThan(reads, hoverReads, "Press must read again without the hover cache")
            XCTAssertEqual(delegate.state.phase, .idle)
            XCTAssertNil(delegate.captured)
            XCTAssertEqual(NSPasteboard.general.changeCount, revision)
        }
    }

    func testUnavailablePickupAllowsFreshEmptySpaceMarquee() {
        withDelegate({ _, _ in .unavailable }, source: { _, _ in
            SourceCaptureLookup(candidate: nil, allowsMarquee: true)
        }) { delegate in
            CapturePreferences.multiselectEnabled = true
            delegate.prepareSelectedTextHint(at: delegate.pointer)
            wait { !delegate.selectedTextPickupPending }
            XCTAssertEqual(delegate.state.phase, .armed)
            XCTAssertFalse(delegate.selectedTextGesturePrepared)
            XCTAssertTrue(delegate.handle(.leftMouseDown, event(.leftMouseDown, at: delegate.pointer)))
            wait { delegate.pendingPress == nil }
            XCTAssertEqual(delegate.state.phase, .selecting)
            XCTAssertNil(delegate.captured)
            XCTAssertNil(delegate.selectedTextHint)
        }
    }

    func testTimedOutPickupStillCancelsRatherThanStartingDiscovery() {
        var sourceReads = 0
        withDelegate({ _, stop in
            let end = Date().addingTimeInterval(1.2)
            while !stop() && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
            // The resolver may return unavailable after the request expires.
            return .unavailable
        }, source: { _, _ in
            sourceReads += 1
            return SourceCaptureLookup(candidate: nil, allowsMarquee: true)
        }) { delegate in
            delegate.prepareSelectedTextHint(at: delegate.pointer)
            wait { !delegate.selectedTextPickupPending }
            XCTAssertEqual(delegate.state.phase, .idle)
            XCTAssertEqual(sourceReads, 0)
        }
    }

    func testLateUnavailablePickupAfterCancellationCannotRestartDiscovery() {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var sourceReads = 0
        withDelegate({ _, _ in
            entered.signal(); _ = release.wait(timeout: .now() + 1)
            return .unavailable
        }, source: { _, _ in
            sourceReads += 1
            return SourceCaptureLookup(candidate: nil, allowsMarquee: true)
        }) { delegate in
            delegate.prepareSelectedTextHint(at: delegate.pointer)
            XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
            delegate.cancel(); release.signal()
            let end = Date().addingTimeInterval(0.15)
            while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertEqual(delegate.state.phase, .idle)
            XCTAssertEqual(sourceReads, 0)
            XCTAssertNil(delegate.captured)
        }
    }

    func testNoSelectionKeepsOrdinaryBlockCaptureAvailable() {
        var block = selection("Ordinary block")
        block.selectedTextRange = nil; block.textFrames = nil
        block = CaptureCandidate(payload: block.payload, frame: CGRect(x: 50, y: 50, width: 200, height: 100))
        withDelegate({ _, _ in .none }, source: { _, _ in SourceCaptureLookup(candidate: block, allowsMarquee: true) }) { delegate in
            delegate.prepareSelectedTextHint(at: delegate.pointer)
            wait { delegate.candidate != nil }
            XCTAssertEqual(delegate.state.phase, .armed)
            XCTAssertNil(delegate.selectedTextHint)
            XCTAssertEqual(delegate.candidate?.payload.text, "Ordinary block")
            XCTAssertTrue(delegate.allowsMarquee)
        }
    }

    func testEscapeCancelsReadyHintAndActiveDragWithoutClipboardChanges() throws {
        let selected = selection(), revision = NSPasteboard.general.changeCount
        var failure: Error?
        for dragging in [false, true] {
            withDelegate({ _, _ in .selected(selected) }) { delegate in
                if dragging { do { try grab(delegate) } catch { failure = error; return } }
                else { delegate.prepareSelectedTextHint(at: delegate.pointer); wait { !delegate.selectedTextPickupPending } }
                let escape = event(.keyDown, at: delegate.pointer)
                escape.setIntegerValueField(.keyboardEventKeycode, value: 53)
                XCTAssertTrue(delegate.handle(.keyDown, escape))
                XCTAssertNil(delegate.selectedTextHint); XCTAssertNil(delegate.captured)
                XCTAssertNotEqual(delegate.state.phase, .dragging)
                XCTAssertEqual(NSPasteboard.general.changeCount, revision)
            }
        }
        if let failure { throw failure }
    }
}
