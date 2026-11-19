import Foundation

extension SteamWebHost {
    /// Logs a call Steam's client refused, once per message per app run.
    func noteSteamCallFailure(_ line: String) {
        let message = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, loggedSteamCallFailures.insert(message).inserted else { return }
        EventLog.shared.log(.client, "Steam refused a call: \(message)")
    }

    /// Forwards the client console lines in which Steam refuses a
    /// `SteamClient` call, as `__steamCallFailure`. A refused call still
    /// resolves its promise, so a Steam update that changes a method's
    /// arguments shows up only here.
    static let callFailureScript = """
    (function () {
      if (window.__sevoCallFailures) return "already registered";
      if (!window.SteamClient || !SteamClient.Console
          || !SteamClient.Console.RegisterForSpewOutput) return "unavailable";
      window.__sevoCallFailures = true;
      SteamClient.Console.RegisterForSpewOutput(function (line) {
        var text = String((line && line.spew) || "");
        if (text.indexOf("RaiseJSException") === -1 && text.indexOf("Method call failed") === -1) return;
        try {
          window.webkit.messageHandlers.sevoWindow.postMessage({ fn: "__steamCallFailure", args: [text.slice(0, 500)] });
        } catch (e) {}
      });
      return "registered";
    })()
    """
}
