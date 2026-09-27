import os
import WebKit

/// Runs scripts in web views and answers each with its string result.
@MainActor
final class JavaScriptEvaluator {
    private var evaluationSequence = 0
    private var evaluationPending: [Int: CheckedContinuation<String?, Never>] = [:]
    private var evaluationTimeouts: [Int: Task<Void, Never>] = [:]

    /// Evaluates JavaScript with an app-owned timeout. WebKit does not offer a
    /// cancellation token for this API, so the late callback is ignored after
    /// the continuation has been resolved exactly once by the timeout.
    func evaluateInWebView(
        _ script: String, webView: WKWebView, timeout: Duration = .seconds(20),
    ) async -> String? {
        evaluationSequence += 1
        let id = evaluationSequence
        // The round trip to the web content process and back: what the UI
        // waits on for every question it asks a page.
        let eval = PerfProbe.bridge.beginInterval(
            "WebKitEval", id: PerfProbe.bridge.makeSignpostID(), "eval=\(id, privacy: .public)",
        )
        defer { PerfProbe.bridge.endInterval("WebKitEval", eval, "eval=\(id, privacy: .public)") }
        return await withCheckedContinuation { continuation in
            evaluationPending[id] = continuation
            webView.evaluateJavaScript(script) { value, _ in
                self.finishEvaluation(id, value: value as? String)
            }
            evaluationTimeouts[id] = Task(name: "WebKit evaluation timeout") { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
                self?.finishEvaluation(id, value: nil)
            }
        }
    }

    private func finishEvaluation(_ id: Int, value: String?) {
        evaluationTimeouts.removeValue(forKey: id)?.cancel()
        evaluationPending.removeValue(forKey: id)?.resume(returning: value)
    }
}
