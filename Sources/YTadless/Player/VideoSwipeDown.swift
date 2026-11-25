// VideoSwipeDown — owner: Module C (PLAN.md §6.3).
//
// Swipe down on the video itself to minimize, like the YouTube app. SwiftUI gestures can't see
// touches that land in the player WKWebView, so this is a UIKit pan recognizer added once to the
// webview (never re-parented, D2). It only begins in the expanded view, for a mostly-downward drag
// that starts on the video (the top 16:9 band of the watch page, where layout.js pins the player).
// Drags lower down still scroll the page; horizontal drags still reach the seek bar.

import UIKit

@MainActor
final class VideoSwipeDown: NSObject, UIGestureRecognizerDelegate {
    /// Expanded portrait only; PlayerLayoutView keeps this current.
    var isActive = false
    var onChanged: (CGSize) -> Void = { _ in }
    var onEnded: (CGSize, CGSize) -> Void = { _, _ in }
    var onCancelled: () -> Void = {}

    private weak var webView: UIView?
    private var scrollPan: UIPanGestureRecognizer?
    private lazy var pan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = true
        pan.maximumNumberOfTouches = 1
        return pan
    }()

    /// Down must beat sideways by this much, so scrubbing and horizontal swipes stay with the page.
    private static let verticalDominance: CGFloat = 1.5

    func install(on webView: UIView, scrollPan: UIPanGestureRecognizer?) {
        guard self.webView == nil else { return }
        self.webView = webView
        self.scrollPan = scrollPan
        webView.addGestureRecognizer(pan)
    }

    @objc private func handle(_ pan: UIPanGestureRecognizer) {
        // Window coordinates: the webview itself moves with the finger.
        let t = pan.translation(in: nil)
        switch pan.state {
        case .began:
            // Stop the page from bouncing along with the player.
            if let scrollPan { scrollPan.isEnabled = false; scrollPan.isEnabled = true }
            onChanged(CGSize(width: t.x, height: t.y))
        case .changed:
            onChanged(CGSize(width: t.x, height: t.y))
        case .ended:
            let v = pan.velocity(in: nil)
            onEnded(CGSize(width: t.x, height: t.y), CGSize(width: v.x, height: v.y))
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === pan, isActive, let view = recognizer.view else { return false }
        let start = pan.location(in: view)
        let videoHeight = view.bounds.width * 9 / 16
        guard start.y >= 0, start.y <= videoHeight else { return false }
        let v = pan.velocity(in: view)
        return v.y > 0 && v.y > Self.verticalDominance * abs(v.x)
    }

    // WebKit's own recognizers keep running until ours begins; then the scroll pan is cancelled.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
