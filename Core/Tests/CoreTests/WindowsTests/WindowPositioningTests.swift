import Core
import Testing

private var screen: WindowPositioning.Rect {
    WindowPositioning.Rect(origin: .init(x: 0, y: 0), size: .init(width: 1000, height: 800))
}

// Right below the line, moved left so that the candidates start where the clause starts
@Test func testCandidateWindowFrameIsBelowTheLineWithTheTextAligned() async throws {
    let line = WindowPositioning.Rect(origin: .init(x: 300, y: 500), size: .init(width: 1, height: 20))
    let frame = WindowPositioning.candidateWindowFrame(
        lineRect: line,
        textOffset: 36,
        size: .init(width: 200, height: 150),
        screenRect: screen
    )
    #expect(frame == WindowPositioning.Rect(origin: .init(x: 264, y: 348), size: .init(width: 200, height: 150)))
}

// No room below the line: right above it, never over the line's text
@Test func testCandidateWindowFrameIsAboveTheLineWhenNoRoomBelow() async throws {
    let line = WindowPositioning.Rect(origin: .init(x: 300, y: 100), size: .init(width: 1, height: 20))
    let frame = WindowPositioning.candidateWindowFrame(
        lineRect: line,
        textOffset: 36,
        size: .init(width: 200, height: 150),
        screenRect: screen
    )
    #expect(frame.minY == 122)
    #expect(frame.minX == 264)
}

// A client that reports a point (no line height) is taken as a line of the default height
@Test func testCandidateWindowFrameTakesAPointAsALine() async throws {
    let line = WindowPositioning.Rect(origin: .init(x: 300, y: 100), size: .init(width: 0, height: 0))
    let frame = WindowPositioning.candidateWindowFrame(
        lineRect: line,
        textOffset: 0,
        size: .init(width: 200, height: 150),
        screenRect: screen
    )
    #expect(frame.minY == 118)
}

// At the screen's right edge the window moves left to fit; at the left edge it stops at the edge
@Test func testCandidateWindowFrameStaysInsideTheScreenHorizontally() async throws {
    let size = WindowPositioning.Size(width: 200, height: 150)
    let right = WindowPositioning.candidateWindowFrame(
        lineRect: .init(origin: .init(x: 950, y: 500), size: .init(width: 1, height: 20)),
        textOffset: 36,
        size: size,
        screenRect: screen
    )
    #expect(right.maxX == screen.maxX)
    let left = WindowPositioning.candidateWindowFrame(
        lineRect: .init(origin: .init(x: 10, y: 500), size: .init(width: 1, height: 20)),
        textOffset: 36,
        size: size,
        screenRect: screen
    )
    #expect(left.minX == screen.minX)
}

// A window wider than the screen keeps its left edge on the screen
@Test func testCandidateWindowFrameWiderThanTheScreenStartsAtItsLeftEdge() async throws {
    let frame = WindowPositioning.candidateWindowFrame(
        lineRect: .init(origin: .init(x: 500, y: 500), size: .init(width: 1, height: 20)),
        textOffset: 36,
        size: .init(width: 1200, height: 150),
        screenRect: screen
    )
    #expect(frame.minX == screen.minX)
}

// Neither below nor above has room (a window taller than the screen): it stays inside the screen, from its bottom edge
@Test func testCandidateWindowFrameTallerThanTheScreenStartsAtItsBottomEdge() async throws {
    let frame = WindowPositioning.candidateWindowFrame(
        lineRect: .init(origin: .init(x: 500, y: 400), size: .init(width: 1, height: 20)),
        textOffset: 36,
        size: .init(width: 200, height: 1000),
        screenRect: screen
    )
    #expect(frame.minY == screen.minY)
}

// On a secondary display left of the main one (negative origin.x), the placement is the same as on the main one
@Test func testCandidateWindowFrameOnSecondaryScreenWithNegativeOrigin() async throws {
    let secondary = WindowPositioning.Rect(origin: .init(x: -1920, y: 0), size: .init(width: 1920, height: 1080))
    let frame = WindowPositioning.candidateWindowFrame(
        lineRect: .init(origin: .init(x: -1000, y: 500), size: .init(width: 1, height: 20)),
        textOffset: 36,
        size: .init(width: 200, height: 150),
        screenRect: secondary
    )
    #expect(frame.origin == WindowPositioning.Point(x: -1036, y: 348))
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
