// ContentRules compiler — owner: Module A (PLAN.md §5.6, §6.1).
// Phase 0 stub: the API and the identifier scheme; compiles nothing.

import Foundation

public enum ContentRules {
    /// Compiles `rules/network.txt` and `rules/cosmetic.txt` to WKContentRuleList JSON.
    /// Phase 0 stub: returns an empty list.
    public static func compile(network: String, cosmetic: String) -> CompiledRules {
        let json = "[]"
        return CompiledRules(json: json, identifier: identifier(for: json), diagnostics: [])
    }

    /// `"ytadless-"` + 16 lowercase hex digits of the 64-bit FNV-1a hash of the UTF-8 JSON (D10).
    public static func identifier(for json: String) -> String {
        "ytadless-" + FNV1a.hex64(json)
    }
}

/// 64-bit FNV-1a. CryptoKit isn't available on Linux (D10).
public enum FNV1a {
    public static func hash64<S: Sequence<UInt8>>(_ bytes: S) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }

    public static func hex64(_ string: String) -> String {
        let hex = String(hash64(string.utf8), radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
