// VideoSwipeDown — owner: Module C (PLAN.md §6.3).
//
// Swipe down on the video itself to minimize, like the YouTube app. SwiftUI gestures can't see
// touches that land in the player WKWebView, so this is a UIKit pan recognizer. It sits on the
// webview's *superview* (SwiftUI's host for WebViewContainer, which D2 keeps fixed): WebKit defers
// every recognizer on the webview or inside it until the page's touch handlers have run, and the
// YouTube player handles touches on the video, so a recognizer on the webview itself never began
// (device, 2026-11-24). It only begins in the expanded view, for a mostly-downward drag
// that starts on the video where it is on screen *now*. layout.js puts the player at the top of
// the watch page and lets it scroll away with the page, so the video is the document band
// y 0…(16:9 height). The touch is located in the webview's scroll view, whose bounds origin is the
// content offset, so that band is tested in document coordinates: once the page is scrolled, the
// top of the webview is page content and a downward drag there scrolls the page, and with the
// video scrolled fully off it never begins. Drags lower down still scroll (or bounce) the page;
// horizontal drags still reach the seek bar.

import UIKit
import YTCore

@MainActor
final class VideoSwipeDown: NSObject, UIGestureRecognizerDelegate {
    /// Expanded portrait only; PlayerLayoutView keeps this current.
    var isActive = false
    var onChanged: (CGSize) -> Void = { _ in }
    var onEnded: (CGSize, CGSize) -> Void = { _, _ in }
    var onCancelled: () -> Void = {}
    var log: (LogLevel, String) -> Void = { _, _ in }

    private weak var webView: UIView?
    private weak var host: UIView?
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

    /// Adds the recognizer to the webview's superview once SwiftUI has hosted it.
    func install(on webView: UIView, scrollPan: UIPanGestureRecognizer?) async {
        guard host == nil else { return }
        self.webView = webView
        self.scrollPan = scrollPan
        for _ in 0..<50 {
            if let superview = webView.superview {
                host = superview
                superview.addGestureRecognizer(pan)
                log(.info, "video swipe installed on \(type(of: superview))")
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        log(.error, "video swipe not installed: the player webview has no superview")
    }

    @objc private func handle(_ pan: UIPanGestureRecognizer) {
        // Window coordinates: the webview itself moves with the finger.
        let t = pan.translation(in: nil)
        switch pan.state {
        case .began:
            // Stop the page from bouncing along with the player.
            if let scrollPan { scrollPan.isEnabled = false; scrollPan.isEnabled = true }
            log(.debug, "video swipe began")
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
        guard recognizer === pan, isActive, let view = webView else { return false }
        // Document coordinates (scroll view bounds origin = contentOffset); the webview itself as
        // a fallback, which treats the page as unscrolled.
        let start = pan.location(in: scrollPan?.view as? UIScrollView ?? view)
        let videoHeight = view.bounds.width * 9 / 16
        guard start.y >= 0, start.y <= videoHeight else { return false }
        let v = pan.velocity(in: view)
        let begins = v.y > 0 && v.y > Self.verticalDominance * abs(v.x)
        if !begins { log(.debug, "video swipe skipped: velocity \(Int(v.x)),\(Int(v.y))") }
        return begins
    }

    // WebKit's own recognizers keep running until ours begins; then the scroll pan is cancelled.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
