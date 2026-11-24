// PageLayoutSync — owner: Module C (PLAN.md §6.3, §5.4 `layout`).
//
// Keeps the player page's layout (`page` / `video`, from PresentationLayout) in step with the
// presentation. Each video open is a full load (D15) and layout.js registers its command only at
// document end, so a send can land on a page that can't answer yet (`no-bridge`,
// `unknown-command: layout`) or on the old page just before the new one replaces it. So:
// send on every change, re-send after each load (isLoading → false) and on a new request or
// video, and retry a failed send for a few seconds. layout.js also restores its last mode from
// sessionStorage, so a fresh page starts right in the common case.

import os
import WebKit
import YTCore

@MainActor
final class PageLayoutSync {
    private static let retryInterval = Duration.milliseconds(250)
    private static let maxAttempts = 40  // ~10 s: a slow watch-page load

    private static let logger = Logger(subsystem: "com.example.YTadless", category: "PageLayoutSync")

    private var desired: PageLayout = .page
    private var task: Task<Void, Never>?
    private var loadingObservation: NSKeyValueObservation?

    init() {}

    /// Starts watching the player webview's loads. Idempotent.
    func attach(store: WebViewStore) {
        guard loadingObservation == nil else { return }
        loadingObservation = store.playerWebView.observe(\.isLoading, options: [.new]) { [weak self, weak store] webView, _ in
            MainActor.assumeIsolated {
                guard let self, let store, !webView.isLoading else { return }
                self.resend(store: store)
            }
        }
    }

    func request(_ layout: PageLayout, store: WebViewStore) {
        desired = layout
        resend(store: store)
    }

    /// Sends the current layout again (new document), retrying until the page answers.
    func resend(store: WebViewStore) {
        task?.cancel()
        let layout = desired
        task = Task { [weak store] in
            for attempt in 1...Self.maxAttempts {
                guard !Task.isCancelled, let store else { return }
                do {
                    try await store.send(.layout(layout))
                    return
                } catch {
                    if attempt == Self.maxAttempts {
                        Self.logger.notice("layout \(layout.rawValue, privacy: .public) not applied: \(String(describing: error), privacy: .public)")
                        return
                    }
                }
                try? await Task.sleep(for: Self.retryInterval)
            }
        }
    }
}
