import Cocoa
import XCTest

@testable import Ogura

/// Regression tests for invisible windows piling up each time an IMKInputController is
/// created (#348). There must be only one set of candidate and prediction windows per process.
@MainActor
final class SharedInputWindowsTests: XCTestCase {
    func test共有ウィンドウは何度参照しても同一インスタンスである() {
        let first = SharedInputWindows.shared
        let windowCountAfterFirstAccess = NSApp.windows.count

        let second = SharedInputWindows.shared

        XCTAssertTrue(first.candidatesWindow === second.candidatesWindow)
        XCTAssertTrue(first.predictionWindow === second.predictionWindow)
        XCTAssertEqual(NSApp.windows.count, windowCountAfterFirstAccess, "再参照でウィンドウが増えてはいけない")
    }

    func test共有ウィンドウは初期状態で非表示である() {
        let windows = SharedInputWindows.shared
        for window in [windows.candidatesWindow, windows.predictionWindow] {
            XCTAssertFalse(window.isVisible)
        }
    }

    func testhideCandidateWindowsで候補系ウィンドウが全て非表示になる() {
        let windows = SharedInputWindows.shared
        windows.candidatesWindow.orderFront(nil)
        windows.predictionWindow.orderFront(nil)

        windows.hideCandidateWindows()

        XCTAssertFalse(windows.candidatesWindow.isVisible)
        XCTAssertFalse(windows.predictionWindow.isVisible)
        XCTAssertEqual(windows.candidatesViewController.numberOfVisibleRows, 0)
    }
}
