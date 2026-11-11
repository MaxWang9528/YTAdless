// YTAssets — Phase 0 contract (PLAN.md §5.5). Owner: P0 (frozen).
//
// The injected scripts, filter rules and manifest ship as resources of this target
// (`YTCore_YTAssets.bundle` inside the .app, D4). The Node tests read the same files from disk.

import Foundation

public enum YTAssetsError: Error, Equatable, Sendable {
    case bundleMissing
    case invalidPath(String)
    case notFound(String)
    case notUTF8(String)
}

public enum YTAssets {
    /// Returns the UTF-8 text of a resource, by path relative to the bundle root:
    /// `"manifest.json"`, `"scripts/bridge.js"`, `"rules/network.txt"`.
    public static func text(_ relativePath: String) throws -> String {
        let url = try url(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw YTAssetsError.notFound(relativePath)
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw YTAssetsError.notUTF8(relativePath)
        }
        return text
    }

    /// File URL of a resource. Rejects absolute paths and `..` components.
    public static func url(_ relativePath: String) throws -> URL {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { throw YTAssetsError.invalidPath(relativePath) }
        guard let base = Bundle.module.resourceURL else { throw YTAssetsError.bundleMissing }
        return parts.reduce(base) { $0.appendingPathComponent(String($1)) }
    }
}
