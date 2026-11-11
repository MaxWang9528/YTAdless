// PlayerControlling (PLAN.md §5.5). Owner: P0 (frozen). Implemented by WebViewStore (Module B).

import YTCore

@MainActor
protocol PlayerControlling: AnyObject {
    /// Loads `request.watchURL` in the player webview; `.hidden` → `.expanded`.
    func open(_ request: VideoRequest)
    /// Pauses, blanks the player webview, → `.hidden`.
    func close()
    /// Runs a native → JS command in the player webview. Returns the handler's result as JSON
    /// (nil when it returned nothing); throws `JSCommandError` when it answered `{error}`.
    @discardableResult func send(_ command: JSCommand) async throws -> String?
}
