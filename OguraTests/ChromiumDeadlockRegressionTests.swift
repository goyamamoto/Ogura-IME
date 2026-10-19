/// Regression tests for the Chromium IME deadlock workaround.
///
/// Right after a page with a large JS bundle opens in Chrome or another Chromium-based browser,
/// calling `client.attributes(forCharacterIndex:)` inside azooKey's activateServer deadlocks
/// (Chromium issue 503787240). These tests protect the change that avoids this.
///
/// Why it is safe:
/// - activateServer passes an empty candidate array, so `resizeWindowToFitContent` in
///   BaseCandidateViewController returns early on `numberOfVisibleRows == 0`, and
///   cursorLocation is not used to compute the window position.
/// - As long as this stays true, removing the client query in activateServer does not
///   affect any feature.

import XCTest
import Core
import KanaKanjiConverterModuleWithDefaultDictionary
@testable import Ogura

@MainActor
final class ChromiumDeadlockRegressionTests: XCTestCase {
    /// Checks that numberOfVisibleRows is 0 after calling updateCandidatePresentations
    /// with an empty candidate array.
    ///
    /// This keeps the early return on `numberOfVisibleRows == 0` in
    /// resizeWindowToFitContent working.
    func test空配列でupdateCandidatePresentationsを呼ぶとnumberOfVisibleRowsが0になる() {
        let vc = CandidatesViewController()
        _ = vc.view // Force loadView to run
        vc.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        XCTAssertEqual(
            vc.numberOfVisibleRows,
            0,
            "空の候補配列では numberOfVisibleRows は 0 でなければならない"
        )
    }

    /// Checks that the candidates property is empty after calling
    /// updateCandidatePresentations with an empty candidate array.
    func test空配列でupdateCandidatePresentationsを呼ぶとcandidatesが空になる() {
        let vc = CandidatesViewController()
        _ = vc.view
        vc.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        XCTAssertTrue(vc.candidates.isEmpty, "空の候補配列を渡した後、candidates は空でなければならない")
    }

    /// Checks that numberOfVisibleRows goes back to 0 when a non-empty candidate array
    /// is followed by an update with an empty array.
    func test候補が存在する状態から空配列に更新するとnumberOfVisibleRowsが0になる() {
        let vc = CandidatesViewController()
        _ = vc.view
        let dummy = CandidatePresentation(candidate: Candidate(text: "テスト", value: 0, composingCount: .surfaceCount(0), lastMid: 0, data: []))
        vc.updateCandidatePresentations([dummy], selectionIndex: nil, cursorLocation: .zero)
        XCTAssertEqual(vc.numberOfVisibleRows, 1, "候補が1件の状態を前提とする")

        vc.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        XCTAssertEqual(
            vc.numberOfVisibleRows,
            0,
            "空配列に更新した後は numberOfVisibleRows が 0 でなければならない"
        )
    }
}
