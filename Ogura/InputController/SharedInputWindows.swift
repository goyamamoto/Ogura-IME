import Cocoa

/// Holds the input method's helper windows (conversion candidates and prediction candidates).
/// There is only one set per process.
///
/// An `IMKInputController` is created for each connected client (an app or a text field).
/// `IMKServer` keeps holding it, so in practice it is never freed. If each controller created
/// its own windows, invisible windows would pile up every time the user switches apps, and
/// WindowServer would stay under constant heavy load (#348). Only one controller is active at a
/// time, so the windows are shared, and the active controller borrows them in `activateServer`.
@MainActor
final class SharedInputWindows {
    static let shared = SharedInputWindows()

    private static let candidateWindowInitialSize = CGSize(width: 400, height: 1000)

    let candidatesViewController: CandidatesViewController
    let predictionViewController: PredictionCandidatesViewController

    let candidatesWindow: NSWindow
    let predictionWindow: NSWindow

    private init() {
        self.candidatesViewController = CandidatesViewController()
        self.predictionViewController = PredictionCandidatesViewController()

        self.candidatesWindow = Self.makeCandidateWindow(contentViewController: self.candidatesViewController)
        self.predictionWindow = Self.makeCandidateWindow(contentViewController: self.predictionViewController)
    }

    private static func makeCandidateWindow(contentViewController: NSViewController) -> NSWindow {
        let window = NSWindow(contentViewController: contentViewController)
        window.styleMask = [.borderless]
        window.level = .popUpMenu

        // Do not query the client during setup, to avoid a deadlock in Chromium-based apps
        // (Chromium issue 503787240).
        // The window is ordered out right after this, so the user never sees its origin.
        // refreshCandidateWindow() moves it to the right position when candidates are first shown.
        var frame = NSRect.zero
        frame.size = candidateWindowInitialSize
        window.setFrame(frame, display: true)
        window.setIsVisible(false)
        window.orderOut(nil)
        return window
    }

    /// Hides all candidate windows. Call this when switching controllers.
    func hideCandidateWindows() {
        for window in [self.candidatesWindow, self.predictionWindow] {
            window.setIsVisible(false)
            window.orderOut(nil)
        }
        self.candidatesViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        self.candidatesViewController.hide()
    }
}
