import Core
import KanaKanjiConverterModuleWithDefaultDictionary
import XCTest

@testable import Ogura

/// The candidate window goes right below the line of the text it lists candidates for, with the candidates starting
/// where that text starts, as the system's input methods and Mozc place theirs
@MainActor
final class CandidateWindowLayoutTests: XCTestCase {
    private func presentations(_ texts: [String]) -> [CandidatePresentation] {
        texts.map { CandidatePresentation(candidate: Candidate(text: $0, value: 0, composingCount: .surfaceCount(0), lastMid: 0, data: [])) }
    }

    private func showCandidates(showIndex: Bool, lineRect: CGRect) throws -> (NSWindow, CandidatesViewController) {
        let controller = CandidatesViewController()
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.borderless]
        controller.showCandidateIndex = showIndex
        controller.updateCandidatePresentations(self.presentations(["変換", "返還", "偏差"]), selectionIndex: 0, lineRect: lineRect)
        window.layoutIfNeeded()
        return (window, controller)
    }

    // Whole points, as the window server places windows on them
    private func line(on screen: NSScreen) -> CGRect {
        CGRect(x: screen.visibleFrame.midX.rounded(), y: screen.visibleFrame.midY.rounded(), width: 1, height: 20)
    }

    /// Where a row's candidate text starts on the screen: a label's alignment rect is where its text is, while its
    /// frame reaches past it
    private func textStart(_ window: NSWindow, _ controller: CandidatesViewController) throws -> CGFloat {
        let cell = try XCTUnwrap(controller.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? CandidateTableCellView)
        let field = cell.candidateTextField
        let superview = try XCTUnwrap(field.superview)
        return window.frame.minX + superview.convert(field.alignmentRect(forFrame: field.frame), to: nil).minX
    }

    func testCandidatesStartUnderTheClauseWithNumbers() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let line = self.line(on: screen)
        let (window, controller) = try self.showCandidates(showIndex: true, lineRect: line)
        XCTAssertEqual(window.frame.maxY, line.minY - 2, "行のすぐ下に出る")
        XCTAssertEqual(try self.textStart(window, controller), line.minX, accuracy: 0.5, "候補の文字の頭が文節の頭にそろう")
    }

    func testCandidatesStartUnderTheTextWithoutNumbers() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let line = self.line(on: screen)
        let (window, controller) = try self.showCandidates(showIndex: false, lineRect: line)
        XCTAssertEqual(try self.textStart(window, controller), line.minX, accuracy: 0.5)
    }

    // Near the bottom of the screen the window goes above the line, not over it
    func testCandidatesGoAboveTheLineNearTheBottomOfTheScreen() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let line = CGRect(x: screen.visibleFrame.midX.rounded(), y: screen.visibleFrame.minY + 10, width: 1, height: 20)
        let (window, _) = try self.showCandidates(showIndex: true, lineRect: line)
        XCTAssertEqual(window.frame.minY, line.maxY + 2)
    }
}
