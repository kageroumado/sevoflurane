import WebKit

extension SteamWebHost {
    /// Evaluates a script in the context page; the script must return a
    /// string (JSON for structured results). Wrapped by hand because the
    /// async overlay traps on a `null` value.
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

    /// Runs a `steam://` URL against this page's handlers. `ExecuteSteamURL`
    /// broadcasts to every UI, and the bottle client's raises a visible Wine
    /// window for dialogs like About, so it is only the fallback for URLs no
    /// local handler takes. A booting page answers `-1` and queues the URL.
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
