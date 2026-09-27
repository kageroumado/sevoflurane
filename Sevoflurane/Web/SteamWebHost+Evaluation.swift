import WebKit

extension SteamWebHost {
    /// Evaluates a script in the hidden context page and returns its result,
    /// which the script must produce as a string — structured results cross
    /// as JSON. The completion-handler API is wrapped by hand because the
    /// async overlay traps when the script's value is `null`; here a stray
    /// null answers `nil` instead of crashing.
    func evaluateInContext(_ script: String) async -> String? {
        guard let webView = context?.webView else { return nil }
        return await evaluateInWebView(script, webView: webView)
    }

    /// Evaluates a script in any of this host's web views, through ``evaluator``.
    func evaluateInWebView(
        _ script: String, webView: WKWebView, timeout: Duration = .seconds(20),
    ) async -> String? {
        await evaluator.evaluateInWebView(script, webView: webView, timeout: timeout)
    }

    /// Runs a `steam://` URL against the handlers this page registered — the
    /// dispatch CEF's scheme interception ends in, without the client round
    /// trip. `ExecuteSteamURL` broadcasts to every UI including the bottle
    /// client's own, which then raises a real (visible) Wine window for
    /// dialogs like About; the local path keeps it in this process. The round
    /// trip remains as fallback for URLs only the client resolves.
    ///
    /// A page that is still booting answers `-1`: the URL is queued on the
    /// readiness promise and will run in this process, so the fallback that
    /// would raise a Wine window stays down.
    func executeSteamURL(_ url: URL) {
        let literal = JSLiteral.string(url.absoluteString)
        Task(name: "Run \(url.absoluteString)") {
            let handled = await evaluateInContext(
                "String(window.__sevoRunSteamURL ? __sevoRunSteamURL(\(literal)) : 0)",
            )
            if handled == nil || handled == "0" {
                _ = await evaluateInContext(
                    "SteamClient.URL.ExecuteSteamURL(\(literal)), \"sent\"",
                )
            }
        }
    }
}
