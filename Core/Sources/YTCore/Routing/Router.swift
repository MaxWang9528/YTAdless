// Router — owner: Module B (PLAN.md §6.2). Phase 0 stub: signatures only, safe defaults.
//
// B implements these against TestVectors/routing.json (shared with router.js).

import Foundation

public enum Router {
    /// www./music./bare youtube.com → m.youtube.com, http → https, youtu.be/ID → /watch?v=ID.
    /// Phase 0 stub: returns the URL unchanged.
    public static func normalize(_ url: URL) -> URL {
        url
    }

    /// Phase 0 stub: no opinion.
    public static func classify(_ url: URL) -> LinkKind {
        .ignore
    }

    /// Phase 0 stub: everything stays where it is.
    public static func decide(_ url: URL, role: WebRole, trigger: NavigationTrigger) -> RouteDecision {
        .allow
    }
}
