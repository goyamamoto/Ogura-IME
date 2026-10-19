import Cocoa
import ContinuationMLX
import Core
import InputMethodKit
import KanaKanjiConverterModuleWithDefaultDictionary

/// A thin adapter between IMK and `InputSession`.
///
/// It converts key events to `KeyEventCore` and passes them to `InputSession`. As the
/// `InputSessionHost`, it applies committed text, marked (uncommitted) text, and input mode
/// changes. The only drawing done here is the candidate window and the prediction window.
/// It makes no input decisions at all.
@objc(OguraInputController)
class OguraInputController: IMKInputController, NSMenuItemValidation {
    let session: InputSession
    var segmentsManager: SegmentsManager {
        MainActor.assumeIsolated {
            self.session.segmentsManager
        }
    }
    var liveConversionEnabled: Bool {
        Config.LiveConversion().value
    }

    var appMenu: NSMenu
    var liveConversionToggleMenuItem: NSMenuItem

    // Helper windows are not created per controller. One set is shared per process (#348).
    // An IMKInputController is created for each client and kept alive, so if a controller
    // owned its windows, invisible windows would pile up.
    private var sharedWindows: SharedInputWindows {
        MainActor.assumeIsolated {
            SharedInputWindows.shared
        }
    }
    private var candidatesWindow: NSWindow {
        self.sharedWindows.candidatesWindow
    }
    private var candidatesViewController: CandidatesViewController {
        self.sharedWindows.candidatesViewController
    }
    private var predictionWindow: NSWindow {
        self.sharedWindows.predictionWindow
    }
    private var predictionViewController: PredictionCandidatesViewController {
        self.sharedWindows.predictionViewController
    }
    private var lastPredictionCandidates: [String] = []
    private var lastPredictionUpdateTime: TimeInterval = 0
    private var predictionHideWorkItem: DispatchWorkItem?

    func appendDebugMessage(_ message: String) {
        self.segmentsManager.appendDebugMessage(message)
    }

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        let segmentsManager = SegmentsManager(
            kanaKanjiConverter: (NSApplication.shared.delegate as? AppDelegate)!.kanaKanjiConverter,
            applicationDirectoryURL: AppContainer.memoryDirectoryURL(),
            personalizationDirectoryURL: AppContainer.personalizationDirectoryURL()
        )
        self.session = MainActor.assumeIsolated {
            InputSession(segmentsManager: segmentsManager)
        }
        self.appMenu = NSMenu(title: "Ogura")
        self.liveConversionToggleMenuItem = NSMenuItem()

        super.init(server: server, delegate: delegate, client: inputClient)

        MainActor.assumeIsolated {
            self.session.host = self
        }
        self.setupMenu()
    }

    // MARK: - IMK Lifecycle

    @MainActor
    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        MainActor.assumeIsolated {
            self.updateContinuationProvider()
        }
        // Point the shared candidate window's delegate at this controller, which just became active
        self.candidatesViewController.delegate = self
        self.prepareApplicationSupportDirectory()
        CustomInputTableStore.registerIfExists()
        self.updateLiveConversionToggleMenuItem(newValue: self.liveConversionEnabled)
        self.session.activate()

        if let client = sender as? IMKTextInput {
            client.overrideKeyboard(withKeyboardNamed: Config.KeyboardLayout().value.layoutIdentifier)
        }
        // If a Chromium-based app activates us while it is compiling JS, a synchronous call to
        // client.attributes(forCharacterIndex:) deadlocks, so do not call it
        // (Chromium issue 503787240).
        // refreshCandidateWindow / refreshPredictionWindow can call client.attributes(...) in the
        // composing/selecting states, so do not use them during activation. Close the windows
        // explicitly instead.
        self.sharedWindows.hideCandidateWindows()
        self.hidePredictionWindow()
    }

    @MainActor
    override func deactivateServer(_ sender: Any!) {
        self.session.deactivate()
        // MLX models are heavy, so free the model if Ogura is not used for a while
        MLXContinuationProvider.releaseModel(after: Self.localModelReleaseDelay)
        (NSApplication.shared.delegate as? AppDelegate)?.scheduleLearningDataCommit()
        self.candidatesWindow.orderOut(nil)
        self.predictionWindow.orderOut(nil)
        self.candidatesViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        super.deactivateServer(sender)
    }

    @MainActor
    override func commitComposition(_ sender: Any!) {
        self.session.commitComposition()
        self.refreshWindows()
    }

    /// Called when the input mode is switched from the menu bar or a shortcut
    @MainActor
    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        defer {
            super.setValue(value, forTag: tag, client: sender)
        }
        if let value = value as? NSString {
            self.client()?.overrideKeyboard(withKeyboardNamed: Config.KeyboardLayout().value.layoutIdentifier)
            self.session.inputModeDidChange(to: value == "com.apple.inputmethod.Roman" ? .english : .japanese)
            self.refreshWindows()
        }
    }

    override func menu() -> NSMenu! {
        self.appMenu
    }

    @MainActor override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        defer {
            (NSApplication.shared.delegate as? AppDelegate)?.postponeLearningDataCommit()
        }
        guard let event, let client = sender as? IMKTextInput else {
            return false
        }
        if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.control) || event.keyCode == UserAction.continuationKeyCode {
            // Apply the "続きを書く" (continue writing) setting when a key that can trigger it arrives
            self.updateContinuationProvider()
        }
        guard event.type == .keyDown else {
            return false
        }

        let charactersForOptionDirectInput = event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.option))
        if Config.OptionDirectFullWidthInput().value,
           let text = OptionDirectInputResolver.resolve(
            characters: charactersForOptionDirectInput,
            modifierFlags: KeyEventCore.ModifierFlag(from: event.modifierFlags),
            inputLanguage: self.session.inputLanguage,
            inputState: self.session.inputState,
            typeBackSlash: Config.TypeBackSlash().value
           ) {
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            return true
        }

        let handled = self.session.handle(event.keyEventCore)
        if handled {
            self.refreshWindows()
        }
        return handled
    }

    // MARK: - Drawing Helper Windows

    @MainActor
    private func refreshWindows() {
        self.refreshCandidateWindow()
        self.refreshPredictionWindow()
    }

    @MainActor
    private func cursorLocation() -> CGPoint {
        var rect: NSRect = .zero
        self.client()?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        return rect.origin
    }

    @MainActor
    func refreshCandidateWindow() {
        switch self.session.candidateWindow {
        case .selecting(let candidates, let selectionIndex):
            self.showCandidates(candidates, selectionIndex: selectionIndex, showIndex: true)
        case .composing(let candidates, let selectionIndex):
            self.showCandidates(candidates, selectionIndex: selectionIndex, showIndex: false)
        case .hidden:
            self.candidatesWindow.setIsVisible(false)
            self.candidatesWindow.orderOut(nil)
            self.candidatesViewController.hide()
        }
    }

    @MainActor
    private func showCandidates(_ candidates: [Candidate], selectionIndex: Int?, showIndex: Bool) {
        self.candidatesViewController.showCandidateIndex = showIndex
        self.candidatesViewController.updateCandidatePresentations(
            self.segmentsManager.makeCandidatePresentations(candidates),
            selectionIndex: selectionIndex,
            cursorLocation: self.cursorLocation()
        )
        self.candidatesWindow.orderFront(nil)
    }

    @MainActor
    func refreshPredictionWindow() {
        let predictions = self.session.predictionCandidates
        if predictions.isEmpty {
            let now = Date().timeIntervalSince1970
            let elapsed = now - self.lastPredictionUpdateTime
            if self.session.inputState == .composing, elapsed < 1.0, !self.lastPredictionCandidates.isEmpty {
                self.showPredictionTexts(self.lastPredictionCandidates)
                self.schedulePredictionHide(after: max(0, 1.0 - elapsed))
                return
            }
            self.hidePredictionWindow()
            return
        }

        self.predictionHideWorkItem?.cancel()
        self.lastPredictionCandidates = predictions.map(\.displayText)
        self.lastPredictionUpdateTime = Date().timeIntervalSince1970
        self.showPredictionTexts(self.lastPredictionCandidates)
    }

    @MainActor
    private func showPredictionTexts(_ texts: [String]) {
        guard !texts.isEmpty else {
            return
        }
        let candidates = texts.map { text in
            Candidate(text: text, value: 0, composingCount: .surfaceCount(text.count), lastMid: 0, data: [])
        }
        self.predictionViewController.updateCandidatePresentations(
            candidates.map { .init(candidate: $0) },
            selectionIndex: nil,
            cursorLocation: self.cursorLocation()
        )
        if !self.liveConversionEnabled, self.candidatesWindow.isVisible {
            self.positionPredictionWindowRightOfCandidateWindow()
        }
        self.predictionWindow.orderFront(nil)
    }

    @MainActor
    private func positionPredictionWindowRightOfCandidateWindow(gap: CGFloat = 8) {
        // Use the screen that holds the center of the candidate window, which is the anchor.
        // predictionWindow.screen / candidatesWindow.screen can return the old display right
        // after a move between displays, so test the center point of the frame directly.
        let anchorFrame = self.candidatesWindow.frame
        let anchorCenter = CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)
        guard let screen = ScreenLookup.screen(containing: anchorCenter, fallbackWindow: self.candidatesWindow) else {
            return
        }

        let frame = WindowPositioning.frameRightOfAnchor(
            currentFrame: WindowPositioning.Rect(self.predictionWindow.frame),
            anchorFrame: WindowPositioning.Rect(anchorFrame),
            screenRect: WindowPositioning.Rect(screen.visibleFrame),
            gap: Double(gap)
        )
        self.predictionWindow.setFrame(frame.cgRect, display: true)
    }

    private func schedulePredictionHide(after delay: TimeInterval) {
        self.predictionHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            let now = Date().timeIntervalSince1970
            if now - self.lastPredictionUpdateTime >= 1.0 {
                self.hidePredictionWindow()
            }
        }
        self.predictionHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func hidePredictionWindow() {
        self.predictionWindow.setIsVisible(false)
        self.predictionWindow.orderOut(nil)
        self.lastPredictionCandidates = []
        self.lastPredictionUpdateTime = 0
        self.predictionHideWorkItem?.cancel()
        self.predictionHideWorkItem = nil
    }
}

// MARK: - InputSessionHost

extension OguraInputController: InputSessionHost {
    func insertText(_ text: String) {
        self.client()?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func updateMarkedText(_ markedText: SegmentsManager.MarkedText) {
        let highlight = self.mark(
            forStyle: kTSMHiliteSelectedConvertedText,
            at: NSRange(location: NSNotFound, length: 0)
        ) as? [NSAttributedString.Key: Any]
        let underline = self.mark(
            forStyle: kTSMHiliteConvertedText,
            at: NSRange(location: NSNotFound, length: 0)
        ) as? [NSAttributedString.Key: Any]
        let ghost: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.secondaryLabelColor]
        let text = NSMutableAttributedString(string: "")
        for part in markedText where !part.content.isEmpty {
            let attributes: [NSAttributedString.Key: Any]? = switch part.focus {
            case .focused: highlight
            case .unfocused: underline
            case .none: [:]
            case .ghost: ghost
            }
            text.append(NSAttributedString(string: part.content, attributes: attributes))
        }
        self.client()?.setMarkedText(
            text,
            selectionRange: markedText.selectionRange,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    func switchInputMode(_ language: InputLanguage) {
        guard let client = self.client() else {
            return
        }
        client.overrideKeyboard(withKeyboardNamed: Config.KeyboardLayout().value.layoutIdentifier)
        switch language {
        case .english:
            client.selectMode("org.if0.inputmethod.ogura.Roman")
        case .japanese:
            client.selectMode("org.if0.inputmethod.ogura.Japanese")
        }
    }

    func candidateRow(forNumberKey number: Int) -> Int {
        self.candidatesViewController.getNumberCandidate(num: number)
    }

    func leftSideContext(maxCount: Int) -> String? {
        let endIndex = self.contextRange().location
        let leftRange = NSRange(location: max(endIndex - maxCount, 0), length: min(endIndex, maxCount))
        var actual = NSRange()
        return self.client()?.string(from: leftRange, actualRange: &actual)
    }

    func rightSideContext(maxCount: Int) -> String? {
        guard let client = self.client() else {
            return nil
        }
        let range = self.contextRange()
        let startIndex = range.location + range.length
        let documentLength = client.length()
        guard startIndex < documentLength else {
            return nil
        }
        let rightRange = NSRange(location: startIndex, length: min(documentLength - startIndex, maxCount))
        var actual = NSRange()
        return client.string(from: rightRange, actualRange: &actual)
    }

    private func contextRange() -> NSRange {
        guard let client = self.client() else {
            return NSRange(location: 0, length: 0)
        }
        let markedRange = client.markedRange()
        if markedRange.location != NSNotFound {
            return markedRange
        }
        let selectedRange = client.selectedRange()
        if selectedRange.location != NSNotFound {
            return selectedRange
        }
        return NSRange(location: 0, length: 0)
    }
}

// MARK: - Candidate Window Callbacks

extension OguraInputController: CandidatesViewControllerDelegate {
    func candidateSubmitted() {
        Task { @MainActor in
            self.session.submitCandidateFromWindow()
            self.refreshWindows()
        }
    }

    func candidateSelectionChanged(_ row: Int) {
        Task { @MainActor in
            self.session.selectCandidateRow(row)
            self.refreshCandidateWindow()
        }
    }
}

extension OguraInputController {
    /// Free the MLX model if it is not used for this many seconds after deactivation
    static let localModelReleaseDelay: TimeInterval = 300

    /// Swap the "続きを書く" (continue writing) model to match the settings. Only on-device models are used
    @MainActor func updateContinuationProvider() {
        switch Config.Continuation().value {
        case .off:
            self.session.continuationProvider = nil
        case .foundationModels:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                self.session.continuationProvider = FoundationModelsContinuationProvider()
                return
            }
            #endif
            self.session.continuationProvider = nil
        case .localModel:
            self.session.continuationProvider = MLXContinuationProvider(modelName: Config.ContinuationLocalModelName().value)
                ?? UnconfiguredLocalModelProvider()
        }
    }
}

/// A stub that only reports that no model is selected
private struct UnconfiguredLocalModelProvider: ContinuationProvider {
    func continuation(after leftContext: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { stream in
            stream.finish(throwing: ContinuationError.unavailable("設定の「続きを書く」で MLX モデルを選んでください"))
        }
    }
}
