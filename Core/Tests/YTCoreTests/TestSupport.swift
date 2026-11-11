// Shared helpers for YTCoreTests (P0). Other modules may use these; add new helpers in your own
// files (this directory is add-only).

import Foundation
import Testing

enum Repo {
    /// The repository root (…/Core/Tests/YTCoreTests/TestSupport.swift → four levels up).
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // YTCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // Core
        .deletingLastPathComponent()  // repo root

    static func url(_ relativePath: String) -> URL {
        relativePath.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url(relativePath))
    }

    /// A JSON file parsed with JSONSerialization (the same representation WebKit hands native).
    static func json(_ relativePath: String) throws -> Any {
        try JSONSerialization.jsonObject(with: data(relativePath))
    }

    static func jsonObject(_ relativePath: String) throws -> [String: Any] {
        try #require(json(relativePath) as? [String: Any], "\(relativePath) is a JSON object")
    }

    static func files(in relativeDirectory: String, withExtension ext: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url(relativeDirectory).path)
            .filter { $0.hasSuffix("." + ext) }
            .sorted()
    }
}

/// Canonical JSON text for comparing parsed values (sorted keys).
func canonicalJSON(_ value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    return String(decoding: data, as: UTF8.self)
}
