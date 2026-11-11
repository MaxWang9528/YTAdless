// Bridge: native → JS commands (PLAN.md §5.4). Owner: P0 (frozen contract).
//
// Native calls `callAsyncJavaScript(JSCommand.functionBody, arguments: ["name": name, "args":
// argumentsJSON], in: nil, contentWorld: .page)`. Arguments always travel as a JSON string and
// are never interpolated into source. `TestVectors/commands.json` lists every name and its args.

import Foundation

public enum AppLifecycle: String, Codable, CaseIterable, Sendable { case active, inactive, background }
public enum PageLayout: String, Codable, CaseIterable, Sendable { case page, video }

public enum JSCommand: Equatable, Sendable {
    case play, pause, seek(to: Double), seekBy(Double), pip(enter: Bool), state
    case lifecycle(AppLifecycle), audioInterruption(began: Bool, shouldResume: Bool)
    case layout(PageLayout), capture

    /// The function body passed to `callAsyncJavaScript`. It reads the two named arguments
    /// `name` and `args`; it never contains data.
    public static let functionBody =
        "return window.\(ScriptConfig.namespace) ? window.\(ScriptConfig.namespace).cmd(name, args) : {error: 'no-bridge'}"

    /// The handler name registered with `__ytadless.command(name, fn)`.
    public var name: String {
        switch self {
        case .play: "play"
        case .pause: "pause"
        case .seek: "seek"
        case .seekBy: "seekBy"
        case .pip: "pip"
        case .state: "state"
        case .lifecycle: "lifecycle"
        case .audioInterruption: "audioInterruption"
        case .layout: "layout"
        case .capture: "capture"
        }
    }

    /// The handler's argument object as a JSON string (keys sorted). Non-finite numbers become 0.
    public var argumentsJSON: String {
        let object: [String: Any]
        switch self {
        case .play, .pause, .state, .capture: object = [:]
        case .seek(let to): object = ["to": Self.finite(to)]
        case .seekBy(let delta): object = ["delta": Self.finite(delta)]
        case .pip(let enter): object = ["enter": enter]
        case .lifecycle(let state): object = ["state": state.rawValue]
        case .audioInterruption(let began, let shouldResume):
            object = ["phase": began ? "began" : "ended", "shouldResume": shouldResume]
        case .layout(let mode): object = ["mode": mode.rawValue]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    private static func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }
}

public enum JSCommandError: Error, Equatable, Sendable {
    /// The page answered `{error: message}`: no bridge, unknown command, no video, a handler threw…
    case rejected(String)
    /// The result couldn't be turned into JSON.
    case invalidResult
}

/// Turns the value `callAsyncJavaScript` returned into the JSON string `PlayerControlling.send`
/// returns. `nil`/`NSNull` (a handler that returned nothing) → `nil`. An object whose `error`
/// is a string throws `JSCommandError.rejected`.
public enum JSCommandResult {
    public static func json(from result: Any?) throws -> String? {
        guard let result, !(result is NSNull) else { return nil }
        if let dict = result as? [String: Any], let message = dict["error"] as? String {
            throw JSCommandError.rejected(message)
        }
        let wrapped: [Any] = [result]
        guard JSONSerialization.isValidJSONObject(wrapped),
              let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8)
        else { throw JSCommandError.invalidResult }
        return json
    }
}
