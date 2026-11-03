import AppKit

final class Delivery {
    private(set) var busy = false
    // Main-owned acknowledgement of an uncertain posted paste. Do not discard
    // its only backup during an update; a newer clipboard revision releases it.
    private var unsettledClipboard: CaptureClipboard?
    var hasUnsettledClipboard: Bool { unsettledClipboard?.needsRestoration == true }
    // Only one transaction can be admitted by the main-owned busy flag. Remote
    // AX and promised clipboard data never run on the event-tap/rendering loop.
    private let queue = DispatchQueue(label: "capture.delivery", qos: .userInitiated)
    // Queue-owned, bounded to the last uncertain transaction. A later transfer
    // can carry its original clipboard through prepare(), even after completion.
    private var unconfirmedClipboard: CaptureClipboard?

    func paste(_ payload: CapturePayload, into target: InputTarget, isCurrent: @escaping () -> Bool = { true },
               commitToken: CaptureCommitToken? = nil, onDispatched: @escaping () -> Void = {},
               diagnostic: @escaping (StaticString) -> Void = { _ in }, completion: @escaping (Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !busy else { diagnostic("delivery-busy"); completion(false); return }
        guard isCurrent() else { diagnostic("delivery-cancelled-before-admission"); completion(false); return }
        diagnostic("delivery-admitted")
        busy = true
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        let restoreClipboard = !CapturePreferences.overwriteClipboard
        // The caller supplies a thread-safe token, never mutable main state.
        let valid = {
            DeliveryGuardDiagnostics.valid(isCurrent: isCurrent,
                beforeDeadline: { ProcessInfo.processInfo.systemUptime < deadline }, diagnostic: diagnostic)
        }
        let receiptValid = {
            let beforeDeadline = ProcessInfo.processInfo.systemUptime < deadline
            guard beforeDeadline else { diagnostic("verification-deadline"); return false }
            if let commitToken {
                let allowed = commitToken.allowsReadOnlyReceipt(beforeDeadline: true)
                if !allowed { diagnostic("verification-not-dispatched") }
                return allowed
            }
            if !isCurrent() { diagnostic("verification-cancelled"); return false }
            return true
        }
        let finish: (Bool) -> Void = { [self] confirmed in
            DispatchQueue.main.async {
                self.busy = false
                completion(confirmed)
            }
        }
        queue.async { [self] in
            let appElement = AXUIElementCreateApplication(target.app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.08)
            AXUIElementSetMessagingTimeout(target.element, 0.08)
            if let cell = target.cellValueElement { AXUIElementSetMessagingTimeout(cell, 0.08) }
            guard Self.currentTarget(target, valid: valid, diagnostic: diagnostic), Self.authorizedSelectionMatches(target, diagnostic: diagnostic) else { diagnostic("initial-target-or-selection-rejected"); finish(false); return }
            DispatchQueue.main.async { [self] in
                guard valid() else { diagnostic("activation-cancelled"); finish(false); return }
                target.app.activate(options: [.activateIgnoringOtherApps])
                queue.async { [self] in
                    guard Self.currentTarget(target, valid: valid, diagnostic: diagnostic), Self.authorizedSelectionMatches(target, diagnostic: diagnostic) else { diagnostic("post-activation-target-or-selection-rejected"); finish(false); return }
                    if target.cellValueElement == nil {
                        guard valid() else { diagnostic("focus-request-invalidated"); finish(false); return }
                        let result = AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                        guard result == .success else {
                            diagnostic(result == .attributeUnsupported ? "focus-request-unsupported" : "focus-request-write-failed")
                            finish(false); return
                        }
                    }
                    queue.asyncAfter(deadline: .now() + 0.15) { [self] in
                        guard Self.currentTarget(target, valid: valid, diagnostic: diagnostic) else { diagnostic("post-focus-target-rejected"); finish(false); return }
                        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.app.processIdentifier else { diagnostic("post-focus-frontmost-changed"); finish(false); return }
                        guard valid() else { diagnostic("post-focus-invalidated"); finish(false); return }
                        if let cell = target.cellValueElement {
                            guard let current = InputTarget.writableCellValue(target.element) else { diagnostic("cell-editor-unavailable"); finish(false); return }
                            guard CFEqual(current, cell) else { diagnostic("cell-editor-identity-changed"); finish(false); return }
                            guard Self.currentTarget(target, valid: valid, diagnostic: diagnostic), valid() else { diagnostic("cell-target-rejected"); finish(false); return }
                            // Direct cell writes do not need a temporary clipboard, but the
                            // explicit overwrite preference also applies to these drops.
                            var clipboard: CaptureClipboard?
                            if !restoreClipboard {
                                let prepared = CaptureClipboard.prepare()
                                guard Self.currentTarget(target, valid: valid, diagnostic: diagnostic), valid() else { diagnostic("cell-preparation-rejected"); finish(false); return }
                                let retained = CaptureClipboard(prepared: prepared, restoreAfterPaste: false)
                                guard retained.install(text: payload.text, isCurrent: valid) else {
                                    retained.abortBeforePaste(); diagnostic("cell-clipboard-install-rejected"); finish(false); return
                                }
                                clipboard = retained
                            }
                            guard Self.currentTarget(target, valid: valid, diagnostic: diagnostic), valid() else {
                                clipboard?.abortBeforePaste(); diagnostic("cell-write-target-rejected"); finish(false); return
                            }
                            guard clipboard?.isCurrent != false else { clipboard?.abortBeforePaste(); diagnostic("cell-write-clipboard-ownership-lost"); finish(false); return }
                            let result = AXUIElementSetAttributeValue(cell, kAXValueAttribute as CFString, payload.text as CFString)
                            guard result == .success else {
                                clipboard?.abortBeforePaste(); diagnostic("cell-value-write-failed"); finish(false); return
                            }
                            commitToken?.recordDispatched()
                            DispatchQueue.main.async(execute: onDispatched)
                            verify(payload: payload, element: cell, before: nil, clipboard: clipboard, valid: receiptValid,
                                   diagnostic: diagnostic, finish: finish)
                            return
                        }
                        guard let editor = axElement(attribute(appElement, kAXFocusedUIElementAttribute)) else { diagnostic("focused-editor-unavailable"); finish(false); return }
                        AXUIElementSetMessagingTimeout(editor, 0.08)
                        guard valid() else { diagnostic("focused-editor-invalidated"); finish(false); return }
                        guard target.containsFocusedEditor(editor) else { diagnostic("focused-editor-outside-target"); finish(false); return }
                        guard target.googleDocsDocument == nil else { diagnostic("focused-editor-unsupported-document"); finish(false); return }
                        // Only the range/value observed when this destination was chosen
                        // is authorized. Focusing must not silently authorize a new selection.
                        guard CFEqual(editor, target.element) else { diagnostic("authorized-editor-proxy-mismatch"); finish(false); return }
                        guard let range = target.insertionRange else { diagnostic("authorized-range-unavailable"); finish(false); return }
                        guard let capturedValue = target.selectionValue else { diagnostic("authorized-value-unavailable"); finish(false); return }
                        guard Self.currentTarget(target, valid: valid, diagnostic: diagnostic), valid() else { diagnostic("authorized-editor-target-rejected"); finish(false); return }
                        let expected = EditorInsertionState(location: range.location, length: range.length, value: capturedValue)
                        guard DeliveryGuardDiagnostics.selectionMatches(expected: expected,
                            read: { Self.insertionState(editor, diagnostic: diagnostic) }, diagnostic: diagnostic) else {
                            diagnostic("post-focus-selection-rejected"); finish(false); return
                        }
                        queue.asyncAfter(deadline: .now() + 0.06) { [self] in
                            guard valid() else { diagnostic("paste-event-creation-invalidated"); finish(false); return }
                            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true) else { diagnostic("paste-keydown-event-unavailable"); finish(false); return }
                            guard let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { diagnostic("paste-keyup-event-unavailable"); finish(false); return }
                            var paragraphReceipt: EditorParagraphReceipt.Before?
                            let clipboard = PasteCommitTransaction.commit(expected: expected, readState: {
                                guard Self.currentTarget(target, valid: valid, diagnostic: diagnostic) else { return nil }
                                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.app.processIdentifier else { diagnostic("commit-frontmost-changed"); return nil }
                                guard let focused = axElement(attribute(appElement, kAXFocusedUIElementAttribute)) else { diagnostic("commit-focus-unavailable"); return nil }
                                guard CFEqual(focused, editor) else { diagnostic("commit-focus-changed"); return nil }
                                guard valid(), let state = Self.insertionState(editor, diagnostic: diagnostic), valid() else { return nil }
                                guard Self.authorizedMarkersMatch(target, editor: editor, diagnostic: diagnostic) else { return nil }
                                if let markers = target.selectionMarkers {
                                    paragraphReceipt = EditorParagraphReceipt.before(editor, selection: markers, rawValue: state.value, valid: valid)
                                }
                                guard valid(), Self.insertionState(editor, diagnostic: diagnostic) == state,
                                      Self.authorizedMarkersMatch(target, editor: editor, diagnostic: diagnostic) else { return nil }
                                return state
                            }, prepareClipboard: {
                                CaptureClipboard.prepare()
                            }, installClipboard: { prepared -> CaptureClipboard? in
                                guard valid() else { return nil }
                                let clipboard = CaptureClipboard(prepared: prepared, restoreAfterPaste: restoreClipboard)
                                guard clipboard.install(text: payload.text, isCurrent: valid) else { clipboard.abortBeforePaste(); return nil }
                                return clipboard
                            }, restoreClipboard: { $0.abortBeforePaste() }, ownsClipboard: { $0.isCurrent && valid() }, postPaste: {
                                guard valid() else { return false }
                                let post = {
                                    for event in [down, up] {
                                        event.flags = .maskCommand
                                        event.setIntegerValueField(.eventSourceUserData, value: 0xD203)
                                        event.post(tap: .cghidEventTap)
                                    }
                                }
                                if let commitToken {
                                    guard commitToken.dispatch(post) else { return false }
                                } else { post() }
                                diagnostic("paste-command-posted")
                                DispatchQueue.main.async(execute: onDispatched)
                                return true
                            }, diagnostic: diagnostic)
                            guard let clipboard else { diagnostic("commit-rejected"); finish(false); return }
                            verify(payload: payload, element: editor, before: expected, clipboard: clipboard,
                                   paragraphReceipt: paragraphReceipt, valid: receiptValid, diagnostic: diagnostic, finish: finish)
                        }
                    }
                }
            }
        }
    }

    private static func authorizedSelectionMatches(_ target: InputTarget, diagnostic: (StaticString) -> Void) -> Bool {
        if target.cellValueElement != nil { return true }
        guard let range = target.insertionRange else { diagnostic("authorized-range-unavailable"); return false }
        guard let value = target.selectionValue else { diagnostic("authorized-value-unavailable"); return false }
        let expected = EditorInsertionState(location: range.location, length: range.length, value: value)
        return DeliveryGuardDiagnostics.selectionMatches(expected: expected,
            read: { insertionState(target.element, diagnostic: diagnostic) }, diagnostic: diagnostic)
            && authorizedMarkersMatch(target, editor: target.element, diagnostic: diagnostic)
    }

    private static func authorizedMarkersMatch(_ target: InputTarget, editor: AXUIElement, diagnostic: (StaticString) -> Void) -> Bool {
        guard let expected = target.selectionMarkers else { return true }
        guard SelectedTextMarkers.sameRange(expected, EditorParagraphReceipt.selectedRange(editor)) else {
            diagnostic("authorized-marker-selection-changed-or-unavailable"); return false
        }
        return true
    }

    private static func currentTarget(_ target: InputTarget, valid: () -> Bool, diagnostic: (StaticString) -> Void) -> Bool {
        guard valid() else { return false }
        guard let context = target.context else { diagnostic("target-context-unavailable"); return false }
        guard context == CaptureElementContext(chain: ancestors(target.element, limit: 40)) else { diagnostic("target-context-changed"); return false }
        guard valid() else { return false }
        guard let current = InputTarget.find(at: target.dropPoint, diagnostic: diagnostic) else { diagnostic("target-hit-unavailable"); return false }
        guard valid() else { return false }
        guard target.matchesCurrentTarget(current, at: target.dropPoint) else { diagnostic("target-hit-identity-or-bounds-changed"); return false }
        return valid()
    }

    private func verify(payload: CapturePayload, element: AXUIElement, before: EditorInsertionState?, clipboard: CaptureClipboard?,
                        paragraphReceipt: EditorParagraphReceipt.Before? = nil,
                        valid: @escaping () -> Bool,
                        diagnostic: @escaping (StaticString) -> Void, finish: @escaping (Bool) -> Void) {
        queue.asyncAfter(deadline: .now() + 0.1) { [self] in
            let complete: (Bool) -> Void = { [self] confirmed in
                if let clipboard {
                    clipboard.finish(confirmed: confirmed)
                    unconfirmedClipboard = !confirmed && clipboard.isCurrent ? clipboard : nil
                    let unsettled = unconfirmedClipboard
                    DispatchQueue.main.async { self.unsettledClipboard = unsettled }
                }
                finish(confirmed)
            }
            guard valid() else { complete(false); return }
            // Read the exact editor we wrote to. Its ancestors may change as a
            // rich editor lays out inserted content; that must not invalidate
            // an otherwise exact receipt. Never resolve or write a new target.
            var confirmed = false
            if let paragraphReceipt {
                // Once this editor proves its paragraph model, a flattened AX
                // string cannot override it and hide lost/extra real blank lines.
                if let text = EditorParagraphReceipt.text(element, valid: valid) {
                    confirmed = paragraphReceipt.confirms(payload.text, text: text.text, markup: text.markup)
                } else if let text = EditorReceiptText.read(element, valid: valid) {
                    confirmed = paragraphReceipt.state.confirmsInsertion(of: payload.text, observed: text)
                }
            } else {
                let raw = attribute(element, kAXValueAttribute)
                let after = (raw as? String) ?? (before == nil ? (raw as? NSNumber)?.stringValue : nil)
                confirmed = before == nil ? after == payload.text : after.map { before?.confirmsLineNormalizedInsertion(of: payload.text, observed: $0) ?? false } ?? false
                // Full reads stay on this exact editor, never a matching prefix
                // or another control elsewhere in the target application.
                if !confirmed, let before, valid(), let fullText = Self.fullEditorText(element, valid: valid) {
                    confirmed = before.confirmsLineNormalizedInsertion(of: payload.text, observed: fullText)
                }
                if !confirmed, let before, valid(), let text = EditorReceiptText.read(element, valid: valid) {
                    confirmed = before.confirmsInsertion(of: payload.text, observed: text)
                }
            }
            guard valid() else { complete(false); return }
            // Read-only verification can use the whole admission deadline. A
            // slow recipient must not see the old clipboard after two seconds.
            if !confirmed && clipboard?.isCurrent != false {
                verify(payload: payload, element: element, before: before, clipboard: clipboard,
                       paragraphReceipt: paragraphReceipt, valid: valid, diagnostic: diagnostic, finish: finish)
            } else {
                diagnostic(confirmed ? "delivery-confirmed" : "delivery-posted-but-unconfirmed")
                complete(confirmed)
            }
        }
    }

    private static func fullEditorText(_ editor: AXUIElement, valid: () -> Bool) -> String? {
        guard valid(), let count = attribute(editor, kAXNumberOfCharactersAttribute) as? NSNumber else { return nil }
        let length = count.intValue
        guard length >= 0, length <= 1_000_000, valid() else { return nil }
        var range = CFRange(location: 0, length: length)
        guard let rawRange = AXValueCreate(.cfRange, &range) else { return nil }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(editor, kAXStringForRangeParameterizedAttribute as CFString, rawRange, &raw) == .success,
              let text = raw as? String, text.utf16.count == length, valid(),
              let currentCount = attribute(editor, kAXNumberOfCharactersAttribute) as? NSNumber,
              currentCount.intValue == length, valid() else { return nil }
        return text
    }

    private static func insertionState(_ editor: AXUIElement, diagnostic: (StaticString) -> Void) -> EditorInsertionState? {
        func exactRange() -> CFRange? {
            guard let value = attribute(editor, kAXSelectedTextRangeAttribute) else { diagnostic("selection-range-unavailable"); return nil }
            guard CFGetTypeID(value) == AXValueGetTypeID() else { diagnostic("selection-range-type-unsupported"); return nil }
            var range = CFRange()
            guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { diagnostic("selection-range-unreadable"); return nil }
            guard range.location >= 0, range.length >= 0 else { diagnostic("selection-range-invalid"); return nil }
            return range
        }
        guard let first = exactRange() else { return nil }
        guard let value = attribute(editor, kAXValueAttribute) as? String else { diagnostic("selection-value-unreadable"); return nil }
        guard let second = exactRange() else { return nil }
        guard first.location == second.location, first.length == second.length else { diagnostic("selection-range-unstable"); return nil }
        return EditorInsertionState(location: second.location, length: second.length, value: value)
    }
}

/// These gates preserve lazy guard order and diagnose the original observation;
/// no AX reread is performed to explain a rejection.
enum DeliveryGuardDiagnostics {
    static func valid(isCurrent: () -> Bool, beforeDeadline: () -> Bool, diagnostic: (StaticString) -> Void) -> Bool {
        guard isCurrent() else { diagnostic("transaction-cancelled"); return false }
        guard beforeDeadline() else { diagnostic("transaction-deadline"); return false }
        return true
    }

    static func selectionMatches(expected: EditorInsertionState, read: () -> EditorInsertionState?, diagnostic: (StaticString) -> Void) -> Bool {
        guard expected.hasValidRange else { diagnostic("authorized-range-invalid"); return false }
        guard let observed = read() else { diagnostic("authorized-selection-unreadable"); return false }
        guard observed == expected else { diagnostic("authorized-selection-changed"); return false }
        return true
    }
}
