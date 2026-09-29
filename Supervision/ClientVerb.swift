import Foundation

/// The control port's verbs that move the client, the bottle or an adopted
/// program. Every one is a `POST`: a read never changes what the supervisor
/// wants.
nonisolated enum ClientVerb: Equatable, Sendable {
    case restart
    case showLibraryWhenHealthy
    case wake
    case start
    case stop
    case forceQuit
    case quit
    case clearShaderCache
    case launchGame
    case runInBottle
    case launchInBottle
    case launchProgram
    case runProgram

    static let paths: [String: ClientVerb] = [
        "/client/restart": .restart,
        "/library/show-when-healthy": .showLibraryWhenHealthy,
        "/supervisor/wake": .wake,
        "/client/start": .start,
        "/client/stop": .stop,
        "/client/forcequit": .forceQuit,
        "/quit": .quit,
        "/bottle/clear-shader-cache": .clearShaderCache,
        "/game/launch": .launchGame,
        "/bottle/run": .runInBottle,
        "/bottle/launch": .launchInBottle,
        "/program/launch": .launchProgram,
        "/program/run": .runProgram,
    ]

    /// The verb a request names, or nil when its method and path name none.
    init?(method: String, path: String) {
        guard method == "POST", let verb = Self.paths[path] else { return nil }
        self = verb
    }

    /// Whether the verb means "there should be a client": a daemon that has
    /// not been asked launches nothing.
    var asksForAClient: Bool {
        switch self {
        case .start, .restart, .forceQuit, .launchGame, .showLibraryWhenHealthy: true
        default: false
        }
    }

    /// How a request fared at ``admit(method:path:wantClient:)``.
    enum Admission {
        case verb(ClientVerb)
        /// The answer to a request that names no verb.
        case refused(HTTPResponse)
    }

    /// Routes one request. `wantClient` hears of a verb that asks for a
    /// client only once the method and path are known to name it, so a
    /// request refused here has changed nothing: 405 for a verb's path under
    /// another method, 404 for a path that is no verb's.
    static func admit(method: String, path: String, wantClient: (String) -> Void) -> Admission {
        guard let verb = ClientVerb(method: method, path: path) else {
            guard paths[path] != nil else { return .refused(.error(404, "Not Found")) }
            var response = HTTPResponse.error(405, "Method Not Allowed")
            response.headers.append(("Allow", "POST"))
            return .refused(response)
        }
        if verb.asksForAClient {
            wantClient("\(path) was asked for")
        }
        return .verb(verb)
    }
}
