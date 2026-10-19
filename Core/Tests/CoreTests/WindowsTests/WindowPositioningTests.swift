import Core
import Testing

@Test func testFrameNearCursorPlacesBelowWhenNotEnoughSpace() async throws {
    let currentFrame = WindowPositioning.Rect(
        origin: .init(x: 0, y: 0),
        size: .init(width: 40, height: 20)
    )
    let screenRect = WindowPositioning.Rect(
        origin: .init(x: 0, y: 0),
        size: .init(width: 100, height: 100)
    )
    let cursorLocation = WindowPositioning.Point(x: 50, y: 10)
    let desiredSize = WindowPositioning.Size(width: 40, height: 30)

    let frame = WindowPositioning.frameNearCursor(
        currentFrame: currentFrame,
        screenRect: screenRect,
        cursorLocation: cursorLocation,
        desiredSize: desiredSize
    )

    #expect(frame.origin == WindowPositioning.Point(x: 50, y: 26))
    #expect(frame.size == desiredSize)
}

@Test func testFrameNearCursorAdjustsRightEdge() async throws {
    let currentFrame = WindowPositioning.Rect(
        origin: .init(x: 0, y: 0),
        size: .init(width: 20, height: 20)
    )
    let screenRect = WindowPositioning.Rect(
        origin: .init(x: 0, y: 0),
        size: .init(width: 100, height: 100)
    )
    let cursorLocation = WindowPositioning.Point(x: 95, y: 50)
    let desiredSize = WindowPositioning.Size(width: 20, height: 20)

    let frame = WindowPositioning.frameNearCursor(
        currentFrame: currentFrame,
        screenRect: screenRect,
        cursorLocation: cursorLocation,
        desiredSize: desiredSize
    )

    #expect(frame.origin == WindowPositioning.Point(x: 80, y: 14))
}

// On a secondary display left of the main one (negative origin.x), the window is still
// placed at a natural position near the cursor. Regression test: minX/maxX/minY/maxY
// math must not break for a screenRect with a negative origin.
@Test func testFrameNearCursorPlacesNearCursorOnSecondaryScreenWithNegativeOrigin() async throws {
    let currentFrame = WindowPositioning.Rect(
        origin: .init(x: 0, y: 0),
        size: .init(width: 40, height: 20)
    )
    let screenRect = WindowPositioning.Rect(
        origin: .init(x: -1920, y: 0),
        size: .init(width: 1920, height: 1080)
    )
    // Cursor near the center of the secondary display
    let cursorLocation = WindowPositioning.Point(x: -1000, y: 500)
    let desiredSize = WindowPositioning.Size(width: 40, height: 30)

    let frame = WindowPositioning.frameNearCursor(
        currentFrame: currentFrame,
        screenRect: screenRect,
        cursorLocation: cursorLocation,
        desiredSize: desiredSize
    )

    // Placed above: origin.y = 500 - 30 - 16 = 454
    #expect(frame.origin == WindowPositioning.Point(x: -1000, y: 454))
    #expect(frame.size == desiredSize)
    #expect(frame.minX >= screenRect.minX)
    #expect(frame.maxX <= screenRect.maxX)
}

// When the window is wider than the screen, the right-edge clamp must not push origin.x
// left of screenRect.minX (extra check of the left-edge clamp).
@Test func testFrameNearCursorClampsToLeftEdgeWhenWindowWiderThanScreen() async throws {
    let currentFrame = WindowPositioning.Rect(
        origin: .init(x: 0, y: 0),
        size: .init(width: 60, height: 30)
    )
    let screenRect = WindowPositioning.Rect(
        origin: .init(x: 0, y: 0),
        size: .init(width: 50, height: 100)
    )
    let cursorLocation = WindowPositioning.Point(x: 40, y: 50)
    let desiredSize = WindowPositioning.Size(width: 60, height: 30)

    let frame = WindowPositioning.frameNearCursor(
        currentFrame: currentFrame,
        screenRect: screenRect,
        cursorLocation: cursorLocation,
        desiredSize: desiredSize
    )

    // The right-edge clamp gives origin.x = 50 - 60 = -10, but the left-edge clamp pins it to minX.
    #expect(frame.origin.x == screenRect.minX)
}

// macOS uses a y-up coordinate system, so minY is the bottom edge of the screen.
// Even in the above placement (the branch that puts the window above the cursor), if
// minY < screenRect.minY, the window is pinned to minY (the bottom edge). This reproduces
// the case where the window goes below the bottom edge by cursorHeight.
@Test func testFrameNearCursorClampsToBottomEdgeWhenAbovePlacementOverflows() async throws {
    let currentFrame = WindowPositioning.Rect(
        origin: .init(x: 0, y: 0),
        size: .init(width: 20, height: 30)
    )
    let screenRect = WindowPositioning.Rect(
        origin: .init(x: 0, y: 0),
        size: .init(width: 100, height: 100)
    )
    // cursorY - height = 0 (= minY), so ">= minY" picks the above placement.
    // origin.y = 30 - 30 - 16 = -16, which is below minY.
    let cursorLocation = WindowPositioning.Point(x: 50, y: 30)
    let desiredSize = WindowPositioning.Size(width: 20, height: 30)

    let frame = WindowPositioning.frameNearCursor(
        currentFrame: currentFrame,
        screenRect: screenRect,
        cursorLocation: cursorLocation,
        desiredSize: desiredSize
    )

    #expect(frame.minY == screenRect.minY)
}

// Top-edge clamp: when the window is taller than screenRect, it is first pinned to the
// top edge on the maxY side. If minY < screenRect.minY after that, it finally moves to
// minY (the bottom edge). The goal here is to hit the maxY > screenRect.maxY case first.
@Test func testFrameNearCursorClampsToTopEdgeWhenWindowTallerThanScreen() async throws {
    let currentFrame = WindowPositioning.Rect(
        origin: .init(x: 0, y: 0),
        size: .init(width: 20, height: 200)
    )
    let screenRect = WindowPositioning.Rect(
        origin: .init(x: 0, y: 0),
        size: .init(width: 100, height: 100)
    )
    // cursorY - height = -190 < 0, so the window is placed below. origin.y = 10 + 16 = 26,
    // and maxY = 226 > 100 triggers the maxY clamp.
    let cursorLocation = WindowPositioning.Point(x: 50, y: 10)
    let desiredSize = WindowPositioning.Size(width: 20, height: 200)

    let frame = WindowPositioning.frameNearCursor(
        currentFrame: currentFrame,
        screenRect: screenRect,
        cursorLocation: cursorLocation,
        desiredSize: desiredSize
    )

    // maxY clamp: origin.y = 100 - 200 = -100. The minY clamp right after corrects it to 0.
    #expect(frame.minY == screenRect.minY)
}

@Test func testFrameRightOfAnchorClampsToVisibleFrame() async throws {
    let currentFrame = WindowPositioning.Rect(
        origin: .init(x: 0, y: 0),
        size: .init(width: 30, height: 20)
    )
    let screenRect = WindowPositioning.Rect(
        origin: .init(x: 0, y: 0),
        size: .init(width: 100, height: 100)
    )
    let anchorFrame = WindowPositioning.Rect(
        origin: .init(x: 80, y: 10),
        size: .init(width: 30, height: 20)
    )

    let frame = WindowPositioning.frameRightOfAnchor(
        currentFrame: currentFrame,
        anchorFrame: anchorFrame,
        screenRect: screenRect,
        gap: 8
    )

    #expect(frame.origin == WindowPositioning.Point(x: 70, y: 10))
    #expect(frame.size == currentFrame.size)
}

// With a secondary display left of the main one (negative origin.x) and an anchor at
// negative coordinates, frameRightOfAnchor must not break and must stay inside the
// secondary display. Regression test for placing the prediction window
// (positionPredictionWindowRightOfCandidateWindow).
@Test func testFrameRightOfAnchorOnSecondaryScreenWithNegativeOrigin() async throws {
    let currentFrame = WindowPositioning.Rect(
        origin: .init(x: 0, y: 0),
        size: .init(width: 200, height: 100)
    )
    let screenRect = WindowPositioning.Rect(
        origin: .init(x: -1920, y: 0),
        size: .init(width: 1920, height: 1080)
    )
    // Anchor near the center of the secondary display. There is enough room on its right with gap=8.
    let anchorFrame = WindowPositioning.Rect(
        origin: .init(x: -1000, y: 500),
        size: .init(width: 300, height: 200)
    )

    let frame = WindowPositioning.frameRightOfAnchor(
        currentFrame: currentFrame,
        anchorFrame: anchorFrame,
        screenRect: screenRect,
        gap: 8
    )

    #expect(frame.origin.x == anchorFrame.maxX + 8) // = -692
    #expect(frame.origin.y == anchorFrame.origin.y) // = 500
    #expect(frame.size == currentFrame.size)
    #expect(frame.minX >= screenRect.minX)
    #expect(frame.maxX <= screenRect.maxX)
}

// When the anchor is right at the right edge of the secondary display, the window cannot go
// on its right, so it is clamped to the left and stays inside screenRect (the clamp fires on
// the secondary display).
@Test func testFrameRightOfAnchorClampsLeftWithinSecondaryScreen() async throws {
    let currentFrame = WindowPositioning.Rect(
        origin: .init(x: 0, y: 0),
        size: .init(width: 200, height: 100)
    )
    let screenRect = WindowPositioning.Rect(
        origin: .init(x: -1920, y: 0),
        size: .init(width: 1920, height: 1080)
    )
    // anchor.maxX = -50. With +gap=8 the prediction window starts at -42, and maxX = 158
    // goes past the right edge of the secondary display (0). The clamp corrects origin.x to 0 - 200 = -200.
    let anchorFrame = WindowPositioning.Rect(
        origin: .init(x: -350, y: 100),
        size: .init(width: 300, height: 200)
    )

    let frame = WindowPositioning.frameRightOfAnchor(
        currentFrame: currentFrame,
        anchorFrame: anchorFrame,
        screenRect: screenRect,
        gap: 8
    )

    #expect(frame.origin.x == screenRect.maxX - currentFrame.width)
    #expect(frame.maxX <= screenRect.maxX)
    #expect(frame.minX >= screenRect.minX)
}

@Test func testPromptWindowOriginMovesAboveWhenBelowWouldOverflow() async throws {
    let screenRect = WindowPositioning.Rect(
        origin: .init(x: 0, y: 0),
        size: .init(width: 100, height: 100)
    )
    let cursorLocation = WindowPositioning.Point(x: 10, y: 10)
    let windowSize = WindowPositioning.Size(width: 40, height: 30)

    let origin = WindowPositioning.promptWindowOrigin(
        cursorLocation: cursorLocation,
        windowSize: windowSize,
        screenRect: screenRect
    )

    #expect(origin == WindowPositioning.Point(x: 20, y: 40))
}

@Test func testPromptWindowOriginClampsToRightEdge() async throws {
    let screenRect = WindowPositioning.Rect(
        origin: .init(x: 0, y: 0),
        size: .init(width: 100, height: 100)
    )
    let cursorLocation = WindowPositioning.Point(x: 95, y: 50)
    let windowSize = WindowPositioning.Size(width: 40, height: 30)

    let origin = WindowPositioning.promptWindowOrigin(
        cursorLocation: cursorLocation,
        windowSize: windowSize,
        screenRect: screenRect
    )

    #expect(origin == WindowPositioning.Point(x: 40, y: 50))
}
