import AppKit
import Core
import CoreGraphics

extension WindowPositioning.Point {
    init(_ point: CGPoint) {
        self.init(x: Double(point.x), y: Double(point.y))
    }

    var cgPoint: CGPoint {
        CGPoint(x: CGFloat(x), y: CGFloat(y))
    }
}

extension WindowPositioning.Size {
    init(_ size: CGSize) {
        self.init(width: Double(size.width), height: Double(size.height))
    }

    var cgSize: CGSize {
        CGSize(width: CGFloat(width), height: CGFloat(height))
    }
}

extension WindowPositioning.Rect {
    init(_ rect: CGRect) {
        self.init(origin: WindowPositioning.Point(rect.origin), size: WindowPositioning.Size(rect.size))
    }

    var cgRect: CGRect {
        CGRect(origin: origin.cgPoint, size: size.cgSize)
    }
}

enum ScreenLookup {
    /// Returns the `NSScreen` that contains the given global point.
    ///
    /// The hit test uses `NSScreen.frame` (the whole display, including the menu bar and Dock).
    /// A test against `visibleFrame` can miss points just below the menu bar or near the Dock,
    /// so hit testing and the usable area are kept separate on purpose. (Callers are expected
    /// to pass `visibleFrame` when they clamp.)
    ///
    /// If no screen contains the point, the fallback order is:
    /// 1. The `NSScreen` closest to the point (so points in gaps between displays or on a
    ///    border settle smoothly)
    /// 2. `fallbackWindow?.screen` (a minimum guarantee when the caller has a window)
    /// 3. `NSScreen.main`
    ///
    /// `fallbackWindow?.screen` comes after the closest screen on purpose. The main goal of this
    /// helper is to avoid the problem where `window.screen` differs from the display that holds
    /// the cursor, and we do not want to return a stale screen for unusual points.
    static func screen(containing point: CGPoint, fallbackWindow: NSWindow? = nil) -> NSScreen? {
        if let hit = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            return hit
        }
        if let nearest = NSScreen.screens.min(by: { lhs, rhs in
            squaredDistance(from: point, to: lhs.frame) < squaredDistance(from: point, to: rhs.frame)
        }) {
            return nearest
        }
        if let windowScreen = fallbackWindow?.screen {
            return windowScreen
        }
        return NSScreen.main
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y
        return dx * dx + dy * dy
    }
}
