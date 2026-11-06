import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    var status: NSStatusItem?
    var iconAppearanceObservation: NSKeyValueObservation?
    var tap: CFMachPort?
    private(set) var inputMonitoringSuspended = false
    var state = CaptureState()
    var overlay = Overlay()
    var buffer = CaptureBuffer()
    let bufferOverlay = BufferOverlay()
    var bufferDragID: UUID?
    let nativeBufferDrag = NativeBufferDrag()
    let nativeDropVerifier = NativeDropVerifier()
    var bufferNativePress = false
    private var activeDragPayload: CapturePayload? {
        if let id = bufferDragID { return buffer.item.flatMap { $0.id == id ? $0.payload : nil } }
        return captured?.payload
    }
    private var activeDragSymbol: String {
        if let id = bufferDragID, let item = buffer.item, item.id == id { return item.symbol }
        return captured?.symbol ?? "cursorarrow"
    }
    let delivery = Delivery()
    private let backdropToneResolver: (CGRect) async -> BackdropTone?
    private var samplingBackdrop = false
    let adapters: [SourceAdapter] = [AccessibleTextBlockAdapter(), AccessibleLinkAdapter()]
    var candidate: CaptureCandidate?
    var sourceSession = SelectionCaptureSession()
    var selectedTextHint: CaptureCandidate?
    var selectedTextPickupPending = false
    var selectedTextGesturePrepared = false
    var allowsMarquee = false
    var scrollSelection: CaptureCandidate?
    var captured: CaptureCandidate?
    var swallowedMouseDown = false
    var shortcutKeyState = CaptureShortcutKeyState()
    var dropping = false
    let probeQueue = DispatchQueue(label: "capture.accessibility", qos: .userInteractive)
    var probing = false
    var pendingProbe: CGPoint?
    var pointer = CGPoint.zero
    var generation = 0
    var hoverCadence = HoverProbeCadence()
    var probeWakeup: DispatchWorkItem?
    var target: InputTarget?
    let commitValidation = CaptureValidation()
    var validatingSource = false
    var deliveryToken: CaptureCommitToken?
    var sourceValidationToken: CaptureCommitToken?
    struct PendingPress {
        let start: CGPoint
        var end: CGPoint
        var mouseDown = true
        var shortcutHeld = true
    }
    var pendingPress: PendingPress?
    private let selectionSourceResolver: ([CaptureCandidate], [SourceAdapter], () -> Bool) -> [CaptureCandidate]?
    private let sourceLookupResolver: ((CGPoint, SelectionCaptureSession) -> SourceCaptureLookup)?
    private let destinationLookupResolver: ((CGPoint) -> InputTarget?)?
    private let selectedTextPickupResolver: ((CGPoint, () -> Bool) -> SelectedTextLookup)?
    private let finalSelectionResolver: ((CGPoint, CGRect, AXUIElement?, SelectionScanControl) -> MarqueeDiscovery)?

    init(selectionSourceResolver: @escaping ([CaptureCandidate], [SourceAdapter], () -> Bool) -> [CaptureCandidate]? = SelectionSourceValidation.resolve,
         sourceLookupResolver: ((CGPoint, SelectionCaptureSession) -> SourceCaptureLookup)? = nil,
         finalSelectionResolver: ((CGPoint, CGRect, AXUIElement?, SelectionScanControl) -> MarqueeDiscovery)? = nil,
         backdropToneResolver: ((CGRect) async -> BackdropTone?)? = nil,
         destinationLookupResolver: ((CGPoint) -> InputTarget?)? = nil,
         selectedTextPickupResolver: ((CGPoint, () -> Bool) -> SelectedTextLookup)? = nil) {
        let sampler = BackdropAppearanceSampler()
        self.backdropToneResolver = backdropToneResolver ?? { await sampler.tone(in: $0) }
        self.selectionSourceResolver = selectionSourceResolver
        self.sourceLookupResolver = sourceLookupResolver
        self.destinationLookupResolver = destinationLookupResolver
        self.selectedTextPickupResolver = selectedTextPickupResolver
        self.finalSelectionResolver = finalSelectionResolver
        super.init()
        bufferOverlay.onClose = { [weak self] in self?.closeBuffer() }
        bufferOverlay.onNativeDrag = { [weak self] item, frame, view, event in
            guard let self, self.bufferNativePress, self.buffer.item?.id == item.id,
                  self.prepareBufferDrag() else { return }
            self.nativeBufferDrag.begin(item: item, frame: frame, view: view, event: event)
        }
        nativeBufferDrag.onBegin = { [weak self] transfer, point in
            self?.showBufferLift(item: transfer.item, frame: transfer.frame, at: point)
        }
        nativeBufferDrag.onMove = { [weak self] point in
            guard let self, !self.dropping else { return }
            self.pointer = point; self.overlay.move(to: point); self.probe(point)
        }
        nativeBufferDrag.onEnd = { [weak self] transfer, point, operation, plan in
            self?.finishNativeBufferDrag(transfer, at: point, operation: operation, plan: plan)
        }
    }

    private func source(at point: CGPoint, session: SelectionCaptureSession, shouldStop: () -> Bool = { false }) -> SourceCaptureLookup {
        guard !shouldStop() else { return SourceCaptureLookup(candidate: nil, allowsMarquee: false) }
        if let sourceLookupResolver { return sourceLookupResolver(point, session) }
        guard let element = hitTest(point, diagnostic: { self.reportAcceptance(stage: "source-hit", reason: $0) }) else {
            return SourceCaptureLookup(candidate: nil, allowsMarquee: false)
        }
        let selection = CapturePreferences.selectedTextDraggingEnabled && !selectedTextGesturePrepared ? AccessibleSelectedTextAdapter().lookup(at: element, session: session) : .none
        if case .unavailable = selection, SourceTextPoint.contains(point, in: element) == false {
            return SourceCaptureLookup(candidate: nil, allowsMarquee: true)
        }
        return SourceCaptureLookup.resolve(selection, at: point) {
            guard SourceTextPoint.contains(point, in: element) != false else { return nil }
            return sourceCandidate(at: element, containing: point, adapters: adapters, shouldStop: shouldStop)
        }
    }

    private func destination(at point: CGPoint) -> InputTarget? {
        if let destinationLookupResolver { return destinationLookupResolver(point) }
        return InputTarget.find(at: point)
    }

    private func selectionPickup(at point: CGPoint, owner: AXUIElement? = nil, shouldStop: () -> Bool) -> SelectedTextLookup {
        guard !shouldStop() else { return .unavailable }
        if let selectedTextPickupResolver { return selectedTextPickupResolver(point, shouldStop) }
        guard let hit = owner ?? hitTest(point) else { return .unavailable }
        return AccessibleSelectedTextAdapter().pickup(at: hit, origin: point, shouldStop: shouldStop)
    }

    private func startHoverDiscovery(at point: CGPoint) {
        probe(point)
        selectionScan.cancel(); selectionScan = SelectionScanControl()
        selectionQueryRunning = false; selectionCache = nil; selectionRoot = nil; selectionWindowFrame = nil
        startSelectionDiscovery(at: point)
    }

    func prepareSelectedTextHint(at point: CGPoint) {
        // Buffer is a control, not a source selection. Revealing its empty slot
        // under the pointer must not cancel the new capture gesture.
        if CapturePreferences.bufferEnabled, bufferOverlay.contains(point) {
            selectedTextGesturePrepared = true
            startHoverDiscovery(at: point)
            return
        }
        let token = generation, work = CaptureCommitToken(timeout: 0.8)
        sourceValidationToken?.cancel(); sourceValidationToken = work
        selectedTextPickupPending = true
        let expected: SelectedTextLookup = .none
        commitValidation.validate(expected: expected, resolve: { [self] in
            selectionPickup(at: point, shouldStop: { !work.isValid })
        }, matches: { _, _ in true }, cancellation: work, isCurrent: { [weak self] in
            self?.generation == token && self?.state.phase == .armed && self?.selectedTextPickupPending == true
        }) { [weak self] lookup in
            guard let self else { return }
            self.selectedTextPickupPending = false; self.sourceValidationToken = nil
            switch lookup {
            case .selected(let selected):
                self.selectedTextHint = selected
                self.selectedTextGesturePrepared = true
                self.state.prepareSelectedText()
                self.overlay.highlight(nil)
                self.overlay.show(at: self.pointer, text: selected.payload.text, symbol: selected.symbol, centeredOnPointer: true)
                self.reportAcceptance(stage: "selected-text-pickup", reason: "hint-ready")
            case .some(.none):
                self.selectedTextGesturePrepared = true
                self.startHoverDiscovery(at: self.pointer)
            case .unavailable, nil:
                self.reportAcceptance(stage: "selected-text-pickup", reason: "unavailable")
                self.cancel()
            }
        }
    }

    private func grabSelectedTextHint(_ expected: CaptureCandidate, frame: CGRect, at point: CGPoint) {
        validatingSource = true
        let token = generation, work = CaptureCommitToken(timeout: 0.8)
        sourceValidationToken?.cancel(); sourceValidationToken = work
        commitValidation.validate(expected: expected, resolve: { [self] in
            guard let owner = expected.anchor,
                  case .selected(let current) = selectionPickup(at: point, owner: owner, shouldStop: { !work.isValid }) else { return nil }
            return current
        }, matches: { $0.matchesRetainedSource($1) }, cancellation: work, isCurrent: { [weak self] in
            self?.generation == token && self?.state.phase == .dragging && self?.selectedTextHint != nil
        }) { [weak self] current in
            guard let self else { return }
            self.validatingSource = false; self.sourceValidationToken = nil
            guard let current else { self.cancel(); return }
            self.captured = current
            self.reportAcceptance(stage: "selected-text-pickup", reason: "accepted")
            if CapturePreferences.bufferEnabled { self.bufferOverlay.showCaptureTarget(at: point) }
            self.overlay.liftSelectedTextHint(from: frame, at: self.pointer, text: current.payload.text)
            self.probe(self.pointer)
        }
    }

    private func blockSource(at point: CGPoint, shouldStop: () -> Bool = { false }) -> CaptureCandidate? {
        guard !shouldStop() else { return nil }
        return hitTest(point).flatMap {
            guard SourceTextPoint.contains(point, in: $0) != false else { return nil }
            return sourceCandidate(at: $0, containing: point, adapters: adapters, shouldStop: shouldStop)
        }
    }

    private func freshSource(_ expected: CaptureCandidate, at point: CGPoint, shouldStop: () -> Bool = { false }) -> CaptureCandidate? {
        guard !shouldStop() else { return nil }
        if let sourceLookupResolver { return sourceLookupResolver(point, SelectionCaptureSession()).candidate }
        return SourceCaptureLookup.validate(expected, selection: {
            guard CapturePreferences.selectedTextDraggingEnabled else { return nil }
            return hitTest(point).flatMap { AccessibleSelectedTextAdapter().candidate(at: $0, containing: point) }
        }, block: { blockSource(at: point, shouldStop: shouldStop) })
    }

    private func scheduleHoverRefresh() {
        guard (state.phase == .armed || state.phase == .dragging), !dropping,
              !nativeBufferDrag.releasePending, probeWakeup == nil else { return }
        let token = generation
        let wakeup = DispatchWorkItem { [weak self] in
            guard let self, token == self.generation,
                  self.state.phase == .armed || self.state.phase == .dragging else { return }
            self.probeWakeup = nil
            guard !self.dropping, !self.nativeBufferDrag.releasePending else { return }
            self.probe(self.pointer)
        }
        probeWakeup = wakeup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: wakeup)
    }

    private func validateSourceForDrag(_ expected: CaptureCandidate, at point: CGPoint) {
        sourceValidationToken?.cancel()
        let work = CaptureCommitToken(timeout: 0.8)
        sourceValidationToken = work
        validatingSource = true
        let token = generation
        commitValidation.validate(expected: expected, resolve: { [self] in
            let current = freshSource(expected, at: point, shouldStop: { !work.isValid })
            if current == nil { reportAcceptance(stage: "grab-source", reason: "unavailable") }
            return current
        }, matches: { [weak self] old, current in
            let matches = old.matchesCurrentSource(current, at: point)
            if !matches { self?.reportAcceptance(stage: "grab-source", reason: "identity-or-content-changed") }
            return matches
        }, cancellation: work,
            isCurrent: { [weak self] in
                guard let self else { return false }
                let current = self.generation == token && self.captureEnabled && self.validatingSource && self.state.phase == .dragging
                if !current { self.reportAcceptance(stage: "grab-source", reason: "stale") }
                return current
            }) { [weak self] current in
                guard let self else { return }
                self.validatingSource = false
                self.sourceValidationToken = nil
                guard let current else { self.cancel(); return }
                self.reportAcceptance(stage: "grab-source", reason: "accepted")
                self.captured = current
                if CapturePreferences.bufferEnabled { self.bufferOverlay.showCaptureTarget(at: point) }
                self.overlay.collapse(from: current.frame, to: self.pointer, symbol: current.symbol)
                self.probe(self.pointer)
            }
    }

    private func validateSelectionForDrag() {
        let expected = selectionBlocks
        guard !expected.isEmpty else {
            reportAcceptance(stage: "grab-selection", reason: "empty")
            cancel(); return
        }
        validatingSource = true
        sourceValidationToken?.cancel()
        let work = CaptureCommitToken(timeout: 0.8)
        sourceValidationToken = work
        let token = generation
        commitValidation.validate(expected: expected, resolve: { [self] in
            let current = selectionSourceResolver(expected, adapters, { !work.isValid })
            if current == nil { reportAcceptance(stage: "grab-selection", reason: "source-unavailable-or-changed") }
            return current
        }, matches: { SelectionSourceValidation.matches($0, $1) }, cancellation: work, isCurrent: { [weak self] in
            guard let self else { return false }
            let current = self.generation == token && self.captureEnabled && self.validatingSource && self.state.phase == .dragging
            if !current { self.reportAcceptance(stage: "grab-selection", reason: "stale") }
            return current
        }) { [weak self] current in
            guard let self else { return }
            self.validatingSource = false
            self.sourceValidationToken = nil
            guard let current, let combined = combinedSelection(current) else { self.cancel(); return }
            self.reportAcceptance(stage: "grab-selection", reason: "accepted")
            self.selectionBlocks = current
            self.captured = combined
            if CapturePreferences.bufferEnabled {
                self.bufferOverlay.showCaptureTarget(at: CGPoint(x: combined.frame.midX, y: combined.frame.midY))
            }
            self.overlay.collapse(from: combined.frame, to: self.pointer, symbol: combined.symbol)
            self.probe(self.pointer)
        }
    }

    private func validateDestination(_ expected: InputTarget, at point: CGPoint, token: Int, stage: StaticString,
                                     completion: @escaping (InputTarget) -> Void) {
        // A failed AX read may recover, but never a known changed/occluded
        // destination. Both attempts retain the original selection authority.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        guard let deliveryToken else { cancel(); return }
        commitValidation.validate(expected: expected,
            resolve: { [weak self] in
                BoundedTargetResolution.resolve(expected: expected, deadline: deadline,
                    allowsRecovery: expected.cellValueElement == nil,
                    isCurrent: { deliveryToken.isValid },
                    lookup: { InputTarget.lookup(at: point, diagnostic: { self?.reportAcceptance(stage: stage, reason: $0) }) },
                    matches: { $0.matchesAuthorizedTarget($1, at: point) },
                    diagnostic: { self?.reportAcceptance(stage: stage, reason: $0) })
            }, matches: { [weak self] old, current in
                let matches = old.matchesAuthorizedTarget(current, at: point)
                if !matches { self?.reportAcceptance(stage: stage, reason: "identity-or-context-changed") }
                return matches
            }, cancellation: deliveryToken,
            isCurrent: { [weak self] in
                guard let self else { return false }
                let current = self.generation == token && self.captureEnabled && self.dropping
                if !current { self.reportAcceptance(stage: stage, reason: "stale") }
                return current
            }) { [weak self] current in
                guard let self else { return }
                guard let current else { self.cancel(); return }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    self.reportAcceptance(stage: stage, reason: "resolution-deadline"); self.cancel(); return
                }
                self.reportAcceptance(stage: stage, reason: "accepted")
                completion(current.preservingSelection(from: expected))
            }
    }

    private func commitDrop(_ expected: InputTarget, payload: CapturePayload, at point: CGPoint) {
        dropping = true
        let bufferedID = bufferDragID
        let token = generation
        let deliveryToken = CaptureCommitToken()
        self.deliveryToken = deliveryToken
        reportAcceptance(stage: "drop", reason: "validation-started")
        validateDestination(expected, at: point, token: token, stage: "destination-release") { [weak self] target in
            guard let self else { return }
            self.reportAcceptance(stage: "drop-animation", reason: "started")
            self.overlay.absorb(into: target.highlightFrame(at: point)) { [weak self] in
                guard let self else { return }
                guard self.generation == token, self.captureEnabled else {
                    self.reportAcceptance(stage: "drop-animation", reason: "invalidated"); return
                }
                self.reportAcceptance(stage: "drop-animation", reason: "completed")
                // The target may change during the unchanged absorb animation.
                self.validateDestination(target, at: point, token: token, stage: "destination-after-animation") { [weak self] current in
                    guard let self else { return }
                    self.delivery.paste(payload, into: current, isCurrent: { deliveryToken.isValid },
                        commitToken: deliveryToken, onDispatched: { [weak self] in
                            if let bufferedID { self?.bufferItemDispatched(id: bufferedID) }
                        }, diagnostic: { [weak self] reason in
                        self?.reportAcceptance(stage: "delivery", reason: reason)
                    }) { [weak self] confirmed in
                        guard let self else { return }
                        // Reconcile recovery by item identity even if a newer
                        // gesture has invalidated this delivery's visual state.
                        if let bufferedID { self.bufferItemFinished(id: bufferedID, confirmed: confirmed) }
                        guard self.generation == token, deliveryToken.isValid else { return }
                        self.dropping = false
                        self.deliveryToken = nil
                        self.bufferDragID = nil
                        self.bufferOverlay.endCapture()
                        self.bufferOverlay.refresh(item: self.buffer.item)
                        if self.captureEnabled { self.state.modifiers(held: self.shortcutIsHeld()) }
                        self.status?.button?.toolTip = confirmed ? "Context added" : "Paste cancelled or unconfirmed — check the destination."
                    }
                }
            }
        }
    }
    func probe(_ point: CGPoint) {
        guard !validatingSource, !dropping, !selectedTextPickupPending else { return }
        if state.phase == .dragging, updateBufferDestination(at: point) { return }
        pendingProbe = point
        let dragging = state.phase == .dragging
        guard !probing else { return }
        // A cached rectangle can belong to an obscured window or a previous
        // browser page. Revalidate the actual element under the drag pointer.
        let now = ProcessInfo.processInfo.systemUptime
        let sameBlock = !dragging && candidate?.frame.contains(point) == true
        guard hoverCadence.shouldProbe(at: now, sameBlock: sameBlock) else {
            // Always service the final pointer position, even when the mouse stops moving.
            if probeWakeup == nil {
                let token = generation
                let wakeup = DispatchWorkItem { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.probeWakeup = nil
                    guard self.state.phase == .armed || self.state.phase == .dragging,
                          let next = self.pendingProbe else { return }
                    self.probe(next)
                }
                probeWakeup = wakeup
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0.001, hoverCadence.delayUntilNextProbe(at: now, sameBlock: sameBlock)), execute: wakeup)
            }
            return
        }
        probeWakeup?.cancel(); probeWakeup = nil
        probing = true; pendingProbe = nil
        let token = generation
        // Optional screen sampling is independent of AX readiness and bounded
        // to one request. An unavailable capture service cannot stall text
        // detection or accumulate a new suspended task on every pointer move.
        if !samplingBackdrop && CapturePreferences.liquidGlassEnabled {
            samplingBackdrop = true
            let sampleFrame = CGRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48)
            let resolveTone = backdropToneResolver
            Task { [weak self] in
                let tone = await resolveTone(sampleFrame)
                await MainActor.run {
                    guard let self else { return }
                    self.samplingBackdrop = false
                    guard token == self.generation,
                          self.state.phase == .armed || self.state.phase == .dragging,
                          hypot(self.pointer.x - point.x, self.pointer.y - point.y) < 24 else { return }
                    self.overlay.setBackdropTone(tone)
                    DebugLog.shared.record(.backdrop(light: tone.map { $0 == .light }))
                }
            }
        }
        let session = sourceSession
        let nativeDragging = nativeBufferDrag.isActive
        probeQueue.async { [self] in
            let lookup = dragging ? nil : self.source(at: point, session: session)
            let source = lookup?.candidate
            let destination = dragging ? self.destination(at: point).flatMap {
                nativeDragging && ($0.cellValueElement != nil || $0.googleDocsDocument != nil) ? nil : $0
            } : nil
            Task { [self] in
                let region = source?.frame ?? destination?.frame
                await MainActor.run {
                    self.probing = false
                    if token == self.generation && (dragging || self.sourceSession === session) && (self.state.phase == .armed || self.state.phase == .dragging)
                        && (!nativeDragging || (self.nativeBufferDrag.isActive && !self.nativeBufferDrag.releasePending))
                        && (!dragging || !self.bufferOverlay.contains(self.pointer)),
                       (!dragging && region?.contains(self.pointer) == true)
                        || hypot(self.pointer.x - point.x, self.pointer.y - point.y) < 8 {
                        if dragging {
                            self.target = destination.flatMap { current in
                                guard current.frame.contains(self.pointer) else { return nil }
                                if let authorized = self.target, authorized.matchesCurrentTarget(current, at: self.pointer) {
                                    return current.preservingSelection(from: authorized)
                                }
                                return current
                            }
                            self.overlay.setDestinationReady(self.target != nil)
                            self.overlay.highlight(self.target?.highlightFrame(at: self.pointer), destination: true)
                            self.overlay.show(at: self.pointer, text: self.target == nil ? "Drag into an editor or cell" : (self.target?.cellValueElement != nil ? "Drop to fill this cell" : "Drop to add context"), symbol: self.activeDragSymbol)
                        } else {
                            self.allowsMarquee = lookup?.allowsMarquee ?? false
                            self.scrollSelection = lookup?.selectionForScroll
                            self.candidate = source.flatMap { $0.containsVisiblePoint(self.pointer) ? $0 : nil }
                            if self.candidate != nil, CapturePreferences.bufferEnabled { self.bufferOverlay.showCaptureTarget(at: self.pointer) }
                            if self.candidate?.selectedTextRange != nil {
                                self.overlay.highlightBlocks(self.candidate?.visibleHighlightFrames ?? [], textSelection: true)
                            } else {
                                self.overlay.highlight(self.candidate?.frame)
                            }
                            self.overlay.show(at: self.pointer, text: self.candidate?.payload.title.isEmpty == false ? self.candidate!.payload.title : "Hover item to drag", symbol: self.candidate?.symbol ?? "cursorarrow")
                        }
                    }
                    if let next = self.pendingProbe { self.pendingProbe = nil; self.probe(next) }
                    else if token == self.generation { self.scheduleHoverRefresh() }
                }
            }
        }
    }
    let selectionQueue = DispatchQueue(label: "capture.selection", qos: .userInitiated)
    var selectionScan = SelectionScanControl()
    var selectionSeed: CaptureCandidate?
    var selectionStart: CGPoint?
    var selectionEnd = CGPoint.zero
    var selectionRoot: AXUIElement?
    var selectionWindowFrame: CGRect?
    var selectionDiscoveryOrigin = CGPoint.zero
    var selectionBlocks: [CaptureCandidate] = []
    var selectionQueryRunning = false
    var selectionCache: [CaptureCandidate]?
    var selectionMouseDown = false
    var selectionShortcutHeld = true
    var selectionDiscoveryComplete = false
    var selectionFinalizing = false
    private let finalSelectionQueue = DispatchQueue(label: "capture.selectionRelease", qos: .userInteractive)

    func updateSelection() {
        scrollRevision += 1
        guard state.phase == .selecting, !selectionFinalizing, let start = selectionStart else { return }
        let rect = selectionRect(from: start, to: selectionEnd)
        if let cache = selectionCache {
            selectionBlocks = cache.filter { selectionTouches(rect, $0.frame) }
            if !selectionBlocks.isEmpty, CapturePreferences.bufferEnabled { bufferOverlay.showCaptureTarget(at: start) }
            overlay.highlightBlocks(selectionBlocks.compactMap(\.visibleFrame))
            overlay.show(at: selectionEnd, text: "\(selectionBlocks.count) elements · Release shortcut to drag", symbol: "selection.pin.in.out")
            return
        }
        // Keep the already highlighted starting block while the one-time scan runs.
        overlay.highlightBlocks(selectionBlocks.compactMap(\.visibleFrame))
        overlay.show(at: selectionEnd, text: "Release shortcut to drag", symbol: "selection.pin.in.out")
        startSelectionDiscovery(at: start)
    }
    func startSelectionDiscovery(at start: CGPoint) {
        guard CapturePreferences.multiselectEnabled else { return }
        guard !selectionQueryRunning else { return }
        selectionQueryRunning = true
        selectionDiscoveryOrigin = start
        let savedRoot = selectionRoot
        let scan = selectionScan
        let seed = selectionSeed
        let retained = state.phase == .selecting ? selectionBlocks : []
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        selectionQueue.async { [self] in
            guard !scan.isCancelled else { return }
            let root = savedRoot ?? hitTest(start).flatMap { hit in
                ancestors(hit, limit: 40, shouldStop: { scan.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline })
                    .first { attribute($0, kAXRoleAttribute) as? String == "AXWindow" } ?? hit
            }
            let windowFrame = root.flatMap { bounds($0) }
            DispatchQueue.main.async { [self] in
                guard selectionScan === scan, !scan.isCancelled else { return }
                selectionRoot = root; selectionWindowFrame = windowFrame
            }
            let discovery = root.map { root in
                marqueeCandidates(root: root, rect: windowFrame ?? CGRect(x: start.x, y: start.y, width: 1, height: 1), adapters: adapters,
                    shouldStop: { scan.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline }, near: start, progress: { [weak self] discovered in
                        DispatchQueue.main.async {
                            guard let self, self.selectionScan === scan,
                                  [.armed, .selecting].contains(self.state.phase), !scan.isCancelled else { return }
                            self.selectionCache = selectedBlocks(discovered + retained + (seed.map { [$0] } ?? []), in: .infinite)
                            if self.state.phase == .selecting { self.updateSelection() }
                        }
                    })
            } ?? MarqueeDiscovery(blocks: [], isComplete: false)
            DispatchQueue.main.async { [self] in
                guard selectionScan === scan, !scan.isCancelled else { return }
                selectionQueryRunning = false
                guard state.phase == .armed || state.phase == .selecting else { return }
                selectionRoot = root
                selectionDiscoveryComplete = discovery.isComplete
                selectionCache = selectedBlocks(discovery.blocks + retained + (seed.map { [$0] } ?? []), in: CGRect.infinite)
                if state.phase == .selecting { updateSelection() }
            }
        }
    }
    private let scrollQueue = DispatchQueue(label: "capture.scrollGeometry", qos: .userInteractive)
    private var scrollTimer: Timer?
    private var scrollRefreshRunning = false
    private var lastScrollAt: TimeInterval = 0
    private var scrollRevision = 0
    private var scrollProtectedFrames: [CGRect] = []
    private var scrollNotice: DispatchWorkItem?

    private var visibleSelectionFrames: [CGRect] {
        state.phase == .armed ? ((scrollSelection ?? candidate)?.scrollProtectionFrames ?? []) : selectionBlocks.flatMap(\.scrollProtectionFrames)
    }

    private func cancelForScroll() {
        cancel()
        overlay.beginCapture()
        overlay.show(at: pointer, text: "Selection cleared by scrolling", symbol: "arrow.up.and.down")
        let notice = DispatchWorkItem { [weak self] in
            self?.scrollNotice = nil
            self?.overlay.endCapture()
            self?.overlay.dismiss()
        }
        scrollNotice = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: notice)
    }

    func trackScroll() {
        guard [.armed, .selecting, .ready].contains(state.phase) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if scrollTimer == nil || now - lastScrollAt >= 0.3 {
            scrollProtectedFrames = visibleSelectionFrames
        }
        guard scrollPreservesSelection(at: pointer, frames: scrollProtectedFrames) else {
            cancelForScroll()
            return
        }
        lastScrollAt = now
        sourceSession = SelectionCaptureSession()
        allowsMarquee = false
        // Discovery results from before scrolling must not overwrite fresh geometry.
        selectionScan.cancel(); selectionScan = SelectionScanControl()
        selectionQueryRunning = false
        selectionDiscoveryComplete = false
        if scrollTimer == nil {
            let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] timer in
                guard let self, [.armed, .selecting, .ready].contains(self.state.phase),
                      ProcessInfo.processInfo.systemUptime - self.lastScrollAt < 0.3 else {
                    timer.invalidate(); self?.scrollTimer = nil
                    if let self, self.state.phase == .selecting || self.state.phase == .armed {
                        self.startSelectionDiscovery(at: self.pointer)
                    }
                    return
                }
                self.refreshScrolledGeometry()
            }
            scrollTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    private func refreshScrolledGeometry() {
        guard !scrollRefreshRunning else { return }
        scrollRefreshRunning = true
        let token = generation, revision = scrollRevision
        let blocks = selectionBlocks, hovered = scrollSelection ?? candidate
        scrollQueue.async { [self] in
            let moved = blocks.map { $0.refreshedGeometry() }
            let movedHover = hovered?.refreshedGeometry()
            DispatchQueue.main.async { [self] in
                scrollRefreshRunning = false
                guard token == generation, revision == scrollRevision,
                      [.armed, .selecting, .ready].contains(state.phase) else { return }
                if let before = blocks.first, let after = moved.first, let start = selectionStart {
                    selectionStart = CGPoint(x: start.x + after.frame.minX - before.frame.minX,
                                             y: start.y + after.frame.minY - before.frame.minY)
                }
                // Only selected geometry is needed on the scrolling critical path.
                // Rebuild the visible candidate cache after momentum settles.
                selectionCache = moved
                selectionBlocks = moved
                if state.phase == .armed {
                    scrollSelection = movedHover?.selectedTextRange != nil ? movedHover : nil
                    candidate = movedHover.flatMap { $0.selectedTextRange != nil && !$0.containsVisiblePoint(pointer) ? nil : $0 }
                    overlay.highlightBlocks(candidate?.visibleHighlightFrames ?? [], trackingScroll: true, textSelection: candidate?.selectedTextRange != nil)
                } else {
                    overlay.highlightBlocks(moved.compactMap(\.visibleFrame), trackingScroll: true)
                    if state.phase == .ready {
                        captured = combinedSelection(moved); candidate = captured
                    }
                }
            }
        }
    }
    func finishSelection() {
        guard state.phase == .selecting else { return }
        if !selectionMouseDown && !selectionShortcutHeld { cancel(); return }
        guard !selectionFinalizing else { return }
        let block: CaptureCandidate
        switch SelectionReleaseResolution.resolve(selectionBlocks, discoveryComplete: selectionDiscoveryComplete) {
        case .captured(let captured): block = captured
        case .finishDiscovery: completeSelectionDiscovery(); return
        case .cancel: cancel(); return
        }
        selectionScan.cancel()
        selectionQueryRunning = false
        captured = block; candidate = block
        state.finishSelection(mouseDown: selectionMouseDown)
        generation += 1; pendingProbe = nil; hoverCadence.reset()
        if selectionMouseDown {
            validateSelectionForDrag()
        } else {
            showReadySelection()
        }
    }

    private func showReadySelection() {
        overlay.endCapture()
        NSCursor.arrow.set()
        overlay.highlightBlocks(selectionBlocks.compactMap(\.visibleFrame))
        overlay.show(at: pointer, text: "Drag \(selectionBlocks.count) selected elements", symbol: captured?.symbol ?? "text.alignleft")
    }

    private func completeSelectionDiscovery() {
        guard let start = selectionStart else { cancel(); return }
        selectionFinalizing = true
        selectionScan.cancel()
        let scan = SelectionScanControl()
        selectionScan = scan
        selectionQueryRunning = true
        let token = generation, root = selectionRoot
        let rect = selectionRect(from: start, to: selectionEnd)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        overlay.show(at: pointer, text: "Finishing selection…", symbol: "selection.pin.in.out")
        finalSelectionQueue.async { [self] in
            guard !scan.isCancelled else { return }
            let result: MarqueeDiscovery
            if let finalSelectionResolver {
                result = finalSelectionResolver(start, rect, root, scan)
            } else {
                let currentRoot = root ?? hitTest(start).flatMap { hit in
                    ancestors(hit, limit: 40, shouldStop: { scan.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline })
                        .first { attribute($0, kAXRoleAttribute) as? String == "AXWindow" } ?? hit
                }
                result = currentRoot.map {
                    marqueeCandidates(root: $0, rect: rect, adapters: adapters,
                        shouldStop: { scan.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline })
                } ?? MarqueeDiscovery(blocks: [], isComplete: false)
            }
            DispatchQueue.main.async { [self] in
                guard token == generation, selectionScan === scan, !scan.isCancelled, state.phase == .selecting else { return }
                selectionQueryRunning = false; selectionFinalizing = false
                guard result.isComplete, ProcessInfo.processInfo.systemUptime < deadline else {
                    cancel()
                    overlay.show(at: pointer, text: "Selection unavailable — try again", symbol: "selection.pin.in.out")
                    let notice = DispatchWorkItem { [weak self] in self?.overlay.dismiss() }
                    scrollNotice = notice
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: notice)
                    return
                }
                selectionCache = result.blocks
                selectionBlocks = result.blocks
                selectionDiscoveryComplete = true
                overlay.highlightBlocks(selectionBlocks.compactMap(\.visibleFrame))
                finishSelection()
            }
        }
    }

    private func clearSelectionMembers() {
        selectionScan.cancel()
        selectionSeed = nil; selectionStart = nil; selectionRoot = nil
        selectionBlocks = []; selectionCache = nil; selectionMouseDown = false
        selectionQueryRunning = false; selectionWindowFrame = nil
        selectionDiscoveryComplete = false; selectionFinalizing = false
    }

    private func beginMarquee(from start: CGPoint, to end: CGPoint, mouseDown: Bool, held: Bool) {
        let discoveryStillAtPointer = selectionQueryRunning && selectionWindowFrame == nil
            && hypot(start.x - selectionDiscoveryOrigin.x, start.y - selectionDiscoveryOrigin.y) < 32
        if selectionWindowFrame?.contains(start) != true && !discoveryStillAtPointer {
            clearSelectionMembers()
            selectionScan = SelectionScanControl()
        }
        candidate = nil; captured = nil
        selectionSeed = nil; selectionStart = start; selectionEnd = end
        selectionBlocks = []; selectionMouseDown = mouseDown; selectionShortcutHeld = held
        state.select(enabled: CapturePreferences.multiselectEnabled)
        updateSelection()
        if !mouseDown || !held { finishSelection() }
    }

    private func resolvePendingPress(at point: CGPoint) {
        selectionBlocks = []; captured = nil
        state.resolvePress()
        pendingPress = PendingPress(start: point, end: point)
        let token = generation, session = SelectionCaptureSession()
        let work = CaptureCommitToken(timeout: 0.8)
        sourceValidationToken?.cancel(); sourceValidationToken = work
        let empty = SourceCaptureLookup(candidate: nil, allowsMarquee: false)
        commitValidation.validate(expected: empty, resolve: { [self] in
            source(at: point, session: session, shouldStop: { !work.isValid })
        }, matches: { _, _ in true }, cancellation: work, isCurrent: { [weak self] in
            guard let self else { return false }
            return token == self.generation && self.captureEnabled && self.state.phase == .resolving
        }) { [weak self] lookup in
            guard let self, let press = self.pendingPress else { return }
            self.pendingPress = nil; self.sourceValidationToken = nil
            guard let lookup, work.isValid, press.mouseDown || press.shortcutHeld else { self.cancel(); return }
            self.state.resolvedPress()
            if let candidate = lookup.candidate {
                guard press.mouseDown else { self.cancel(); return }
                self.clearSelectionMembers()
                self.state.begin()
                self.validateSourceForDrag(candidate, at: point)
            } else if CapturePreferences.multiselectEnabled && lookup.allowsMarquee {
                self.beginMarquee(from: press.start, to: press.end, mouseDown: press.mouseDown, held: press.shortcutHeld)
            } else {
                self.reportAcceptance(stage: "selection-start", reason: CapturePreferences.multiselectEnabled ? "source-unavailable" : "multiselect-disabled")
                self.cancel()
                if !CapturePreferences.multiselectEnabled && lookup.allowsMarquee {
                    self.overlay.show(at: point, text: "Multi-select is off — enable it in Settings", symbol: "selection.pin.in.out")
                    let notice = DispatchWorkItem { [weak self] in self?.overlay.dismiss() }
                    self.scrollNotice = notice
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: notice)
                }
            }
        }
    }

    @objc func sourceApplicationDidChange() {
        if [.armed, .resolving, .selecting, .ready].contains(state.phase) {
            reportAcceptance(stage: "capture", reason: "application-or-space-changed")
            cancel()
        }
        if state.phase != .dragging && !dropping { bufferOverlay.repositionForActiveSpace() }
    }
    func closeBuffer() {
        // Closing the shelf cannot revoke read-only verification or clipboard
        // cleanup for a Paste that has already left the app.
        if deliveryToken?.wasDispatched != true { cancel() }
        buffer.clear()
        bufferOverlay.dismiss()
    }
    private func bufferSettingsChanged() {
        settingsWindow?.refreshBuffer()
        if deliveryToken?.wasDispatched != true { cancel() }
        if !CapturePreferences.bufferEnabled { buffer.clear(); bufferOverlay.dismiss() }
        else { bufferOverlay.refresh(item: buffer.item, dragging: bufferDragID != nil) }
    }
    /// Buffer hit testing is local geometry only; no AX reads on the event tap.
    @discardableResult private func updateBufferDestination(at point: CGPoint) -> Bool {
        let inside = CapturePreferences.bufferEnabled && bufferOverlay.contains(point)
        let accepts = inside && bufferOverlay.slotContains(point) && bufferDragID == nil && captured != nil
        bufferOverlay.setDropReady(accepts)
        bufferOverlay.setReceiving(accepts)
        guard inside else { return false }
        pendingProbe = nil; target = nil
        overlay.setDestinationReady(accepts)
        if accepts { overlay.highlightBufferSlot(bufferOverlay.targetFrame) }
        else { overlay.highlight(nil) }
        let prompt = buffer.item == nil ? "Drop to keep in Buffer" : "Drop to replace Buffer content"
        overlay.show(at: point, text: accepts ? prompt : "Buffer", symbol: activeDragSymbol)
        return true
    }
    @discardableResult func prepareBufferDrag() -> Bool {
        guard !updatePaused, captureEnabled, !delivery.busy, !nativeBufferDrag.isActive,
              let item = buffer.item, bufferOverlay.targetFrame != nil else { return false }
        cancel()
        state = CaptureState(); state.modifiers(held: true); state.begin()
        bufferDragID = item.id
        bufferNativePress = false
        return true
    }
    func showBufferLift(item: BufferItem, frame: CGRect, at point: CGPoint) {
        pointer = point
        bufferOverlay.refresh(item: item, dragging: true)
        overlay.beginCapture()
        overlay.liftBufferItem(from: frame, at: point, title: item.payload.title.isEmpty ? item.payload.text : item.payload.title, symbol: item.symbol)
    }
    private func releaseNativeBufferDrag(_ event: CGEvent) {
        guard let id = nativeBufferDrag.stageRelease(event) else { return }
        let point = event.location
        guard let expected = target, expected.frame.contains(point) else {
            nativeBufferDrag.completeRelease(id: id, plan: nil); return
        }
        dropping = true
        let generation = self.generation
        let token = CaptureCommitToken()
        deliveryToken = token
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        commitValidation.validate(expected: NativeDropPlan(target: expected, expectedEdits: []), resolve: { [weak self] in
            guard let current = BoundedTargetResolution.resolve(expected: expected, deadline: deadline,
                allowsRecovery: expected.cellValueElement == nil, isCurrent: { token.isValid },
                lookup: { InputTarget.lookup(at: point) }, matches: { $0.matchesAuthorizedTarget($1, at: point) }),
                  let plan = NativeDropPlan.resolve(current.preservingSelection(from: expected), at: point) else { return nil }
            guard case let .found(last) = InputTarget.lookup(at: point),
                  expected.matchesAuthorizedTarget(last, at: point) else { return nil }
            guard self != nil, token.isValid, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            return plan
        }, matches: { _, _ in true }, cancellation: token, isCurrent: { [weak self] in
            guard let self else { return false }
            return self.captureEnabled && self.generation == generation && self.nativeBufferDrag.transfer?.id == id
        }) { [weak self] plan in
            guard let self else { return }
            if plan != nil { token.recordDispatched() }
            self.nativeBufferDrag.completeRelease(id: id, plan: plan)
        }
    }
    func finishNativeBufferDrag(_ transfer: NativeBufferDrag.Transfer, at point: CGPoint,
                                        operation: NSDragOperation, plan: NativeDropPlan?) {
        guard bufferDragID == transfer.item.id else { return }
        generation += 1; pendingProbe = nil
        probeWakeup?.cancel(); probeWakeup = nil
        guard operation.contains(.copy), let plan, let token = deliveryToken, token.isValid else {
            deliveryToken?.cancel(); deliveryToken = nil
            cancel(); return
        }
        // AppKit reports copy only after the native receiver accepts the drop.
        // Its receipt consumes the snapshot; a later AX value read can be stale,
        // normalized by a rich editor, or interrupted by the next shortcut.
        bufferItemFinished(id: transfer.item.id, confirmed: true)
        dropping = false; bufferDragID = nil
        _ = state.drop(valid: true)
        state.modifiers(held: shortcutIsHeld())
        bufferOverlay.hideUntilNextCapture()
        bufferOverlay.endCapture(); bufferOverlay.refresh(item: buffer.item)
        overlay.endCapture(); overlay.absorb(into: plan.target.highlightFrame(at: point)) {}
        guard CapturePreferences.overwriteClipboard else { deliveryToken = nil; return }
        // Exact insertion verification remains only for the explicit clipboard
        // preference. It must never restore a consumed item or block capture.
        nativeDropVerifier.verify(transfer.item.payload, plan: plan, clipboardRevision: transfer.clipboardRevision,
            overwriteClipboard: true, token: token) { [weak self] _ in
            guard let self, self.deliveryToken === token else { return }
            self.deliveryToken = nil
        }
    }
    func bufferItemDispatched(id: UUID) {
        guard buffer.item?.id == id else { return }
        if bufferDragID == id { bufferOverlay.hideUntilNextCapture() }
    }
    func bufferItemFinished(id: UUID, confirmed: Bool) {
        guard buffer.item?.id == id else { return }
        buffer.finishDelivery(id: id, confirmed: confirmed)
        bufferOverlay.refresh(item: buffer.item, dragging: bufferDragID != nil)
    }
    private func parkInBuffer(_ captured: CaptureCandidate, at frame: CGRect, held: Bool) {
        guard buffer.store(captured.payload, symbol: captured.symbol, replacing: true) else { cancel(); return }
        generation += 1; pendingProbe = nil
        probeWakeup?.cancel(); probeWakeup = nil
        let token = generation
        _ = state.drop(valid: true); state.modifiers(held: held)
        dropping = true
        self.captured = nil; candidate = nil; target = nil
        clearSelectionMembers()
        bufferOverlay.setReceiving(true)
        overlay.parkInBuffer(frame, title: captured.payload.title.isEmpty ? captured.payload.text : captured.payload.title, symbol: captured.symbol) { [weak self] in
            guard let self, self.generation == token else { return }
            self.dropping = false
            self.bufferOverlay.refresh(item: self.buffer.item)
            self.bufferOverlay.endCapture()
        }
    }
    private(set) var updatePaused = false
    var captureEnabled = UserDefaults.standard.object(forKey: "captureEnabled") as? Bool ?? true
    let powerItem = NSMenuItem(title: "Turn Off", action: nil, keyEquivalent: "")
    var timer: Timer?
    private func reportAcceptance(stage: StaticString, reason: StaticString) {
        DebugLog.shared.record(.acceptance(stage: stage, reason: reason))
    }
    func refreshHealth() {
        let trusted = AXIsProcessTrusted()
        let listening = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
        DebugLog.shared.record(.health(accessibility: trusted, listener: listening, paused: inputMonitoringSuspended,
            phase: state.phase, buffer: buffer.item != nil, transfer: updateActivity.transfer))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.shared.record(.action(.launched))
        AppPresentationPreferences.applyDockVisibility()
        let updateRelaunch = UpdateRelaunch.consume()
        if let updateRelaunch {
            captureEnabled = updateRelaunch.intent
            inputMonitoringSuspended = updateRelaunch.paused
        }
        let arguments = CommandLine.arguments
        let opensOnboarding = arguments.contains("--onboarding") ||
            (!arguments.contains("--about") && !arguments.contains("--settings") &&
             !UserDefaults.standard.bool(forKey: OnboardingWindowController.completedKey))
        setMenuBarVisible(!opensOnboarding)
        NSApp.applicationIconImage = AppIcon.image(for: NSApp.effectiveAppearance)
        iconAppearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { application, _ in
            application.applicationIconImage = AppIcon.image(for: application.effectiveAppearance)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(showAboutFromNotification), name: Notification.Name("DragShowAbout"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showOnboarding), name: Notification.Name("DragShowOnboarding"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshUpdateMenu), name: UpdateChecker.changed, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sourceApplicationDidChange), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sourceApplicationDidChange), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        UpdateChecker.shared.activity = { [weak self] in
            self?.updateActivity ?? UpdateActivity(transfer: true)
        }
        UpdateChecker.shared.beforeRestart = { [weak self] valid, done in
            guard let self else { done(false); return }
            self.prepareUpdateRestart(stillAuthorized: valid, completion: done)
        }
        UpdateChecker.shared.abandonRestart = { [weak self] in self?.updatePaused = false }
        UpdateChecker.shared.start()
        startTap()
        refreshHealth()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.tap == nil && AXIsProcessTrusted() { self.startTap() }
            self.refreshHealth()
        }
        // Keep onboarding's existing input gate even when reopening About.
        if opensOnboarding { showOnboarding() }
        if updateRelaunch != nil { showAboutFromNotification() }
        else if !opensOnboarding && arguments.contains("--about") { showAboutFromNotification() }
        else if !opensOnboarding && arguments.contains("--settings") { openSettings() }
    }

    private func setMenuBarVisible(_ visible: Bool) {
        guard visible else {
            if let menu = updateMenuItem.menu { menu.removeItem(updateMenuItem) }
            if let menu = powerItem.menu { menu.removeItem(powerItem) }
            if let status { NSStatusBar.system.removeStatusItem(status) }
            status = nil
            return
        }
        guard status == nil else { return }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status?.button?.image = MenuBarIcon.image
        status?.button?.toolTip = captureEnabled ? "Hold \(CaptureShortcut.current.title) to capture text or a link" : "Drag 2.0 is turned off"
        let menu = NSMenu()
        menu.showsStateColumn = false
        powerItem.title = inputMonitoringSuspended ? "Resume capture" : (captureEnabled ? "Turn Off" : "Turn On")
        powerItem.action = #selector(toggleCapture)
        powerItem.target = self
        menu.addItem(powerItem)
        let settingsItem = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        settingsItem.image = nil
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
        status?.menu = menu
        refreshUpdateMenu()
    }
    @objc func toggleCapture() {
        setCaptureEnabled(inputMonitoringSuspended || !captureEnabled)
    }
    func setCaptureEnabled(_ enabled: Bool) {
        guard !UpdateChecker.shared.restartInProgress else { return }
        let wasSuspended = inputMonitoringSuspended
        guard captureEnabled != enabled || wasSuspended else { return }
        inputMonitoringSuspended = false
        DebugLog.shared.record(.action(enabled ? .captureResumed : .captureStopped))
        captureEnabled = enabled
        // A key-up while disabled bypasses the event tap handler. Do not carry
        // the previous shortcut's consumed key-down into a new enabled session.
        shortcutKeyState.reset()
        UserDefaults.standard.set(captureEnabled, forKey: "captureEnabled")
        cancel()
        state = CaptureState()
        swallowedMouseDown = false
        if !captureEnabled { buffer.clear(); bufferOverlay.dismiss(); overlay.close(); NSCursor.arrow.set() }
        else { overlay = Overlay() }
        if enabled && wasSuspended {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            else { startTap() }
        }
        powerItem.title = captureEnabled ? "Turn Off" : "Turn On"
        settingsWindow?.refreshActivation()
        status?.button?.toolTip = captureEnabled ? "Hold \(CaptureShortcut.current.title) to capture text or a link" : "Drag 2.0 is turned off"
        refreshHealth()
    }
    let updateMenuItem = NSMenuItem(title: "Update available…", action: nil, keyEquivalent: "")
    @objc func refreshUpdateMenu() {
        guard let menu = status?.menu else { return }
        if UpdateChecker.shared.hasUpdate {
            updateMenuItem.title = UpdateChecker.shared.phase == .ready ? "Update ready to restart…" : "Update available…"
            updateMenuItem.target = self
            updateMenuItem.action = #selector(showAboutFromNotification)
            if updateMenuItem.menu == nil { menu.insertItem(updateMenuItem, at: 1) }
        } else if updateMenuItem.menu != nil { menu.removeItem(updateMenuItem) }
    }
    @objc func showAboutFromNotification() {
        prepareSettings()
        settingsWindow?.presentAbout()
    }
    var onboardingWindow: OnboardingWindowController?
    @objc func showOnboarding() {
        DebugLog.shared.record(.action(.onboardingOpened))
        suspendCaptureForAppUI()
        setMenuBarVisible(false)
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindowController(onMenuBarVisibilityChange: { [weak self] visible in
                self?.setMenuBarVisible(visible)
            })
        }
        onboardingWindow?.present()
    }
    var settingsWindow: SettingsWindowController?
    @objc func openSettings() {
        prepareSettings()
        settingsWindow?.present()
    }
    private func prepareSettings() {
        DebugLog.shared.record(.action(.settingsOpened))
        suspendCaptureForAppUI()
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(onStructureChange: { [weak self] in
                self?.cancel()
                self?.selectionCache = nil
            }, onAppearanceChange: { [weak self] in
                guard let self else { return }
                self.cancel()
                self.overlay.close()
                self.overlay = Overlay()
            }, isActive: { [weak self] in
                guard let self else { return false }
                return self.captureEnabled && !self.inputMonitoringSuspended
            }, onActivationChange: { [weak self] enabled in
                self?.setCaptureEnabled(enabled)
            }, onBufferChange: { [weak self] in
                self?.bufferSettingsChanged()
            })
        }
    }
    /// Release transient capture state before presenting app controls. Buffered
    /// content remains intact, and in-flight workers are invalidated by cancel.
    func suspendCaptureForAppUI() {
        cancel()
        shortcutKeyState.reset()
        swallowedMouseDown = false
        state = CaptureState()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = onboardingWindow?.window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else { openSettings() }
        return true
    }
    @objc func enable() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if !AXIsProcessTrusted() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
    var updateActivity: UpdateActivity {
        UpdateActivity(transfer: delivery.busy || dropping || validatingSource || pendingPress != nil
                       || bufferNativePress || bufferDragID != nil || nativeBufferDrag.isActive || deliveryToken != nil,
                       selection: ![.idle, .locked].contains(state.phase), buffer: buffer.item != nil,
                       clipboard: delivery.hasUnsettledClipboard, activationIntent: captureEnabled, inputPaused: inputMonitoringSuspended)
    }
    /// Do not use Turn Off: it clears Buffer and resets an input-interruption pause.
    /// Transfers (including clipboard restoration) acknowledge completion via Delivery.busy.
    func prepareUpdateRestart(stillAuthorized: @escaping () -> Bool, completion: @escaping (Bool) -> Void) {
        guard stillAuthorized(), updateActivity.restartBlock == nil else { completion(false); return }
        updatePaused = true
        suspendCaptureForAppUI() // Synchronous cancellation invalidates all queued capture results.
        DispatchQueue.main.async { [weak self] in
            guard let self else { completion(false); return }
            guard stillAuthorized() else { completion(false); return }
            completion(self.updatePaused && self.updateActivity.restartBlock == nil)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        UpdateChecker.shared.permitsTermination() ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        DebugLog.shared.record(.action(.quitting))
    }
    func startTap() {
        guard tap == nil, !inputMonitoringSuspended, AXIsProcessTrusted() else { return }
        let types: [CGEventType] = [.scrollWheel, .flagsChanged, .keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .mouseMoved]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            let started = ProcessInfo.processInfo.systemUptime
            defer {
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                if elapsed >= 0.05 { DebugLog.shared.record(.slowInputHandler(milliseconds: Int(min(elapsed, 3600) * 1000))) }
            }
            return owner.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            status?.button?.toolTip = "Hold \(CaptureShortcut.current.title) to capture text or a link"
        } else { status?.button?.toolTip = "Accessibility / Input Monitoring permission required. Relaunch after granting." }
    }
    private func shortcutIsHeld() -> Bool {
        let shortcut = CaptureShortcut.current
        return shortcut.isHeld(observedKeyDown: shortcutKeyState.isPressed(for: shortcut))
    }
    func cancel() {
        selectedTextHint = nil; selectedTextPickupPending = false; selectedTextGesturePrepared = false
        bufferNativePress = false
        nativeBufferDrag.cancel()
        if let id = bufferDragID, deliveryToken?.wasDispatched == true {
            buffer.finishDelivery(id: id, confirmed: false)
            bufferOverlay.hideUntilNextCapture()
        }
        bufferDragID = nil
        bufferOverlay.endCapture()
        bufferOverlay.refresh(item: buffer.item)
        scrollSelection = nil
        sourceSession = SelectionCaptureSession(); allowsMarquee = false
        validatingSource = false
        sourceValidationToken?.cancel(); sourceValidationToken = nil; pendingPress = nil
        deliveryToken?.cancel(); deliveryToken = nil
        scrollTimer?.invalidate(); scrollTimer = nil
        scrollProtectedFrames = []
        scrollNotice?.cancel(); scrollNotice = nil
        generation += 1; pendingProbe = nil; target = nil; hoverCadence.reset()
        probeWakeup?.cancel(); probeWakeup = nil
        clearSelectionMembers()
        state.cancel()
        if !shortcutIsHeld() {
            state.modifiers(held: false)
        }
        dropping = false
        overlay.endCapture(); overlay.dismiss(toward: captured?.frame)
        captured = nil; candidate = nil
    }
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        // Once the user authorizes a safe restart, do not start another capture
        // between Sparkle's termination request and the application's final quit.
        if updatePaused || UpdateChecker.shared.restartAuthorized { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Respect macOS releasing the input stream. Re-enabling immediately
            // can repeatedly reclaim input during a slow or broken gesture.
            DebugLog.shared.record(.inputInterrupted(timeout: type == .tapDisabledByTimeout))
            inputMonitoringSuspended = true
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.inputMonitoringSuspended else { return }
                self.suspendCaptureForAppUI()
                self.powerItem.title = "Resume capture"
                self.status?.button?.toolTip = "Capture paused after an input interruption. Choose Resume capture to try again."
                self.settingsWindow?.refreshActivation()
                self.refreshHealth()
            }
            return false
        }
        if inputMonitoringSuspended { return false }
        if event.getIntegerValueField(.eventSourceUserData) == 0xD203 { return false }
        let shortcut = CaptureShortcut.current
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        // Observe paired releases before any UI/power gate. Own synthetic paste
        // events above must never release a physically held custom trigger.
        let releasedConsumedKey = type == .keyUp && shortcutKeyState.releaseKey(keyCode)
        if nativeBufferDrag.isActive {
            if type == .leftMouseUp { releaseNativeBufferDrag(event); return true }
            let moved = (type == .mouseMoved || type == .leftMouseDragged) && nativeBufferDrag.movedSinceStagedRelease(to: event.location)
            if nativeBufferDrag.releasePending && (type == .leftMouseDown || type == .keyDown || moved) {
                deliveryToken?.cancel(); nativeBufferDrag.cancel()
                // The replacement Escape cancels AppKit tracking. Swallow the
                // original so a second Escape cannot leak into the editor.
                if type == .keyDown && keyCode == 53 { return true }
            }
            // AppKit owns native tracking, modifier handling and Escape.
            return false
        }
        if bufferNativePress && (type == .leftMouseDragged || type == .leftMouseUp) {
            if type == .leftMouseUp { bufferNativePress = false }
            return false
        }
        // Onboarding stays inactive even while System Settings has focus.
        // Shortcut recording and modal controls must not arm capture. Settings
        // text remains a valid source. A native drag already in
        // progress above still receives its paired release/cancellation.
        guard captureEnabled, !ShortcutRecorderView.isRecording,
              onboardingWindow?.window?.isVisible != true,
              NSApp.modalWindow == nil else { return false }
        let held = shortcut.isHeld(flags: event.flags, event: event, type: type,
                                   observedKeyDown: shortcutKeyState.isPressed(for: shortcut))
        let matchingKey = (type == .keyDown || type == .keyUp) && shortcut.keyCode.map { Int64($0) == event.getIntegerValueField(.keyboardEventKeycode) } == true
        if selectedTextHint != nil, !held, !dropping, state.phase != .dragging {
            let consume = matchingKey || (swallowedMouseDown && [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(type))
            cancel()
            if type == .leftMouseUp { swallowedMouseDown = false }
            return consume
        }
        if selectedTextPickupPending, type == .leftMouseDown {
            cancel(); return false
        }
        // Repetition of the still-held consumed trigger is part of the same
        // gesture, not new user input. Every other key-down still cancels.
        if dropping && type == .keyDown && shortcutKeyState.consumesAutorepeat(for: shortcut, code: keyCode,
            flags: event.flags, isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0) { return true }
        if dropping && (type == .flagsChanged || matchingKey), state.retryDuringDelivery(held: held) {
            reportAcceptance(stage: "commit", reason: "cancelled-by-new-shortcut")
            cancel()
        }
        if type == .leftMouseDown, CapturePreferences.bufferEnabled, bufferOverlay.contains(event.location) {
            // A parking animation must not let a click on its close/header/slot
            // leak into the app below while cancelling the obsolete transition.
            if dropping && deliveryToken?.wasDispatched != true { cancel() }
            if bufferOverlay.closeContains(event.location) {
                closeBuffer(); swallowedMouseDown = true
            } else if buffer.item != nil && bufferOverlay.slotContains(event.location) {
                guard !delivery.busy else { swallowedMouseDown = true; return true }
                guard let item = buffer.item, let frame = bufferOverlay.targetFrame,
                      prepareBufferDrag() else { swallowedMouseDown = true; return true }
                // Use the same authorized, saved-selection delivery as direct
                // capture. Native dragging delegates insertion to the pointer.
                swallowedMouseDown = true
                showBufferLift(item: item, frame: frame, at: event.location)
                return true
            } else {
                if deliveryToken?.wasDispatched != true { cancel() }
                swallowedMouseDown = true
            }
            return true
        }
        // New user input invalidates a pending commit before it can steal focus.
        if dropping && (type == .leftMouseDown || type == .keyDown) {
            // Once Paste is posted, only read-only verification remains. Let
            // normal input reach the editor and finish clipboard verification.
            if deliveryToken?.wasDispatched == true { return false }
            reportAcceptance(stage: "commit", reason: "cancelled-by-user-input")
            let escape = type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53
            cancel()
            return escape
        }
        if type == .scrollWheel {
            pointer = event.location
            if selectionFinalizing || state.phase == .resolving { cancelForScroll(); return false }
            trackScroll()
            return false
        }
        if type == .mouseMoved || type == .leftMouseDragged {
            pointer = event.location
            if scrollNotice != nil { overlay.move(to: pointer) }
            if scrollTimer != nil, [.armed, .selecting, .ready].contains(state.phase),
               !scrollPreservesSelection(at: pointer, frames: visibleSelectionFrames) {
                cancelForScroll()
            }
        }
        let shortcutKeyEvent = matchingKey && (held || releasedConsumedKey || shortcutKeyState.isPressed(for: shortcut))
        if matchingKey && type == .keyDown && held { shortcutKeyState.consumeKeyDown(keyCode) }
        if type == .flagsChanged || shortcutKeyEvent {
            if state.phase == .resolving {
                pendingPress?.shortcutHeld = held
                if !held && pendingPress?.mouseDown == false { cancel() }
                return shortcutKeyEvent
            }
            if state.phase == .selecting {
                selectionShortcutHeld = held
                if !held {
                    pointer = event.location
                    if selectionMouseDown { finishSelection() } else { cancel() }
                }
                return shortcutKeyEvent
            }
            if state.phase == .ready {
                if !held { cancel() }
                return shortcutKeyEvent
            }
            if !held && state.phase != .dragging && !dropping { cancel() }
            let old = state.phase
            if !dropping || !held { state.modifiers(held: held) }
            if old != .armed && state.phase == .armed {
                deliveryToken?.cancel(); deliveryToken = nil
                scrollNotice?.cancel(); scrollNotice = nil
                DebugLog.shared.record(.action(.captureArmed))
                sourceSession = SelectionCaptureSession(); allowsMarquee = false
                scrollSelection = nil
                clearSelectionMembers(); captured = nil; candidate = nil
                hoverCadence.reset()
                probeWakeup?.cancel(); probeWakeup = nil
                pointer = event.location
                if CapturePreferences.bufferEnabled { bufferOverlay.beginCapture(at: pointer) }
                overlay.beginCapture()
                NSCursor.arrow.set()
                // Resolve and measure the initial target before showing its glass.
                selectedTextGesturePrepared = false
                if CapturePreferences.selectedTextDraggingEnabled { prepareSelectedTextHint(at: pointer) }
                else { startHoverDiscovery(at: pointer) }
            }
            return shortcutKeyEvent
        }
        if state.phase == .resolving {
            pointer = event.location
            if type == .leftMouseDown { cancel(); return false }
            if type == .keyDown { cancel(); return keyCode == 53 }
            if type == .leftMouseDragged || type == .leftMouseUp {
                pendingPress?.end = pointer
                pendingPress?.shortcutHeld = held
                if type == .leftMouseUp {
                    pendingPress?.mouseDown = false; swallowedMouseDown = false
                    if !held { cancel() }
                }
                return true
            }
            return false
        }
        if state.phase == .selecting {
            pointer = event.location
            if type == .leftMouseDown {
                if selectionFinalizing { cancel(); return false }
                swallowedMouseDown = true; selectionMouseDown = true
                return true
            }
            if type == .keyDown { cancel(); return keyCode == 53 }
            if type == .leftMouseDragged {
                selectionShortcutHeld = held
                if !selectionFinalizing { selectionEnd = pointer; updateSelection() }
                // Recover a release observed on the pointer stream even if
                // macOS did not deliver a separate modifier/key-up event.
                if !held { finishSelection() }
                return true
            }
            if type == .leftMouseUp {
                selectionMouseDown = false; swallowedMouseDown = false
                selectionShortcutHeld = held
                if !held { cancel(); return true }
                if !selectionFinalizing { selectionEnd = pointer; updateSelection() }
                overlay.endCapture()
                finishSelection()
                return true
            }
            if !held {
                selectionShortcutHeld = false
                if selectionMouseDown { finishSelection() } else { cancel() }
            }
            return false
        }
        if state.phase == .ready {
            if !held { cancel(); return false }
            if type == .keyDown { cancel(); return keyCode == 53 }
            if type == .leftMouseDown {
                if let selectedTextHint {
                    guard let frame = overlay.dragHintFrame, frame.contains(event.location) else { cancel(); return false }
                    pointer = event.location; swallowedMouseDown = true; state.begin()
                    generation += 1
                    grabSelectedTextHint(selectedTextHint, frame: frame, at: event.location)
                    return true
                }
                let onSelection = selectionBlocks.contains { $0.visibleFrame?.contains(event.location) == true }
                let onHint = overlay.dragHintFrame?.contains(event.location) == true
                guard captured != nil, onSelection || onHint else { cancel(); return false }
                pointer = event.location; swallowedMouseDown = true; state.begin()
                generation += 1
                validateSelectionForDrag()
                return true
            }
            return false
        }
        if type == .leftMouseUp && swallowedMouseDown && state.phase != .dragging {
            swallowedMouseDown = false; return true
        }
        if type == .leftMouseDragged && swallowedMouseDown && state.phase != .dragging { return true }
        guard state.phase == .armed || state.phase == .dragging else { return false }
        if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53 { cancel(); return true }
        if !held && state.phase != .dragging { cancel(); return swallowedMouseDown }
        let point = event.location
        pointer = point
        if type == .mouseMoved && state.phase == .armed {
            NSCursor.arrow.set()
            overlay.move(to: point)
            if candidate?.containsVisiblePoint(point) != true { candidate = nil; overlay.highlight(nil) }
            probe(point)
            // Pass hover to the source so its native hover state stays intact.
            return false
        }
        if type == .leftMouseDown {
            generation += 1; pendingProbe = nil; hoverCadence.reset()
            probeWakeup?.cancel(); probeWakeup = nil
            swallowedMouseDown = true
            // Hover is only a preview. Freeze capture mode from a fresh lookup
            // at this press, including when the last hover probe was elsewhere.
            resolvePendingPress(at: point)
            return true
        }
        if type == .leftMouseDragged {
            NSCursor.closedHand.set()
            overlay.move(to: point)
            if validatingSource { return true }
            if updateBufferDestination(at: point) { return true }
            if target?.frame.contains(point) != true {
                target = nil; overlay.setDestinationReady(false); overlay.highlight(nil)
            }
            probe(point)
            return true
        }
        if type == .leftMouseUp {
            swallowedMouseDown = false
            if validatingSource {
                if held && !selectionBlocks.isEmpty {
                    // A quick release can beat asynchronous AX validation.
                    // Keep the selection and reject that pending result; the
                    // next click validates again before anything can be sent.
                    generation += 1; pendingProbe = nil
                    sourceValidationToken?.cancel(); sourceValidationToken = nil
                    validatingSource = false; selectionMouseDown = false
                    state.preserveSelection()
                    showReadySelection()
                    return true
                }
                reportAcceptance(stage: "drop", reason: "source-validation-pending")
                cancel(); return true
            }
            if CapturePreferences.bufferEnabled, bufferOverlay.contains(point) {
                if bufferDragID == nil, bufferOverlay.slotContains(point),
                   let captured, let frame = bufferOverlay.targetFrame {
                    parkInBuffer(captured, at: frame, held: held)
                } else { cancel() }
                return true
            }
            let target = self.target.flatMap { $0.frame.contains(point) ? $0 : nil }
            if target == nil { reportAcceptance(stage: "drop", reason: "no-authorized-target") }
            let payload = activeDragPayload
            if payload == nil { reportAcceptance(stage: "drop", reason: "no-captured-source") }
            generation += 1; pendingProbe = nil
            let shouldDeliver = state.drop(valid: target != nil)
            // A shortcut released during dragging may have no later flags event.
            // The release is still observed on this physical mouse-up.
            state.modifiers(held: held)
            if shouldDeliver, let target, let payload {
                bufferOverlay.endCapture()
                commitDrop(target, payload: payload, at: point)
                self.captured = nil; candidate = nil
                clearSelectionMembers()
            } else { cancel() }
            return true
        }
        return false
    }
}
// App-local opt-out of Tahoe's inferred action icons; keep this text-only menu
// compact without changing the user's global menu preferences.
UserDefaults.standard.register(defaults: ["NSMenuEnableActionImages": false])
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
