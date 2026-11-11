// Presentation state machine + mini-player geometry — owner: Module C (PLAN.md §6.3).
// Phase 0 stub: signatures C is expected to flesh out (and may change; nothing else calls them
// yet), returning safe defaults. Plain Doubles rather than CoreGraphics types: CGSize/CGPoint
// conformances differ between Darwin and Linux Foundation.

import Foundation

/// A 2-D point, size or velocity in points (points/second for velocities).
public struct PlanarVector: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = PlanarVector(0, 0)
}

/// A gesture or control that may change the player's presentation.
public enum PresentationGesture: Equatable, Sendable {
    case tap
    case dragEnded(translation: PlanarVector, velocity: PlanarVector)
    case expandButton
    case closeButton
}

extension PlayerPresentation {
    /// Phase 0 stub: no transitions.
    public func next(after gesture: PresentationGesture) -> PlayerPresentation {
        self
    }
}

public enum MiniPlayerGeometry {
    /// Height of the docked 16:9 strip for a given container width.
    public static func dockedHeight(forWidth width: Double) -> Double {
        (width * 9 / 16).rounded()
    }

    /// Phase 0 stub: always the default corner.
    public static func snapCorner(position: PlanarVector, velocity: PlanarVector, container: PlanarVector) -> PlayerPresentation.Corner {
        .bottomTrailing
    }
}
