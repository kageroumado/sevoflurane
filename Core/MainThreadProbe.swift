import Foundation

/// The questions only `steam.exe` answers, asked of a client that otherwise
/// probes healthy, and the reading of what comes back.
///
/// Never reduce this to one question: during a stall the install manager's
/// state can keep answering while app details, the proxy info and message
/// posts time out. Each question reports `answered`, `silent` (nothing within
/// ``timeout``, or the bridge's deadline rejecting the call) or `n/a` (the API
/// is missing or refused outright, which is no stall).
nonisolated enum MainThreadProbe {
    /// Longer than ``CDPBudget/callCap``, so a stalled call is classed by the
    /// bridge's rejection and only a call that never settles waits this long.
    static let timeout: Duration = .seconds(6)

    /// Any app the store knows answers, owned or not.
    static let detailsAppID = 730

    static let questions = ["install", "proxy", "details"]

    /// A promise for a JSON object naming each question's outcome.
    static var expression: String {
        let milliseconds = Int(timeout.components.seconds) * 1000
        return """
        new Promise(function (resolve) {
          var names = \(JSLiteral.inlineString(questions.joined(separator: " "))).split(" ");
          var verdicts = {};
          var pending = names.length;
          function settle(name, verdict) {
            if (verdicts[name]) return;
            verdicts[name] = verdict;
            if (--pending === 0) resolve(JSON.stringify(verdicts));
          }
          function refused(name) {
            return function (reason) {
              settle(name, /deadline|timeout|timed out/i.test(String(reason)) ? "silent" : "n/a");
            };
          }
          function ask(name, body) {
            try { body(function () { settle(name, "answered"); }); } catch (e) { settle(name, "n/a"); }
          }
          ask("install", function (done) {
            SteamClient.Installs.GetInstallManagerInfo().then(done, refused("install"));
          });
          ask("proxy", function (done) {
            SteamClient.System.Network.GetProxyInfo().then(done, refused("proxy"));
          });
          ask("details", function (done) {
            var registration = SteamClient.Apps.RegisterForAppDetails(\(detailsAppID), function () {
              done();
              try { registration.unregister(); } catch (e) {}
            });
          });
          setTimeout(function () {
            for (var i = 0; i < names.length; i++) settle(names[i], "silent");
          }, \(milliseconds));
        })
        """
    }

    struct Answer: Equatable, Sendable {
        var silent: [String] = []
        var unavailable: [String] = []

        /// A parked main thread leaves at least one question unanswered.
        var stuck: Bool { !silent.isEmpty }
    }

    /// Reads the expression's JSON object from `/__eval`'s `v`, which arrives
    /// double-encoded inside a JSON string literal. `nil` means the page, not
    /// the client, failed to answer.
    static func answer(from value: String?) -> Answer? {
        guard let value, let decoded = try? JSONSerialization.jsonObject(
            with: Data(value.utf8), options: [.fragmentsAllowed],
        ) else { return nil }
        let object = (decoded as? String).flatMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8))
        } ?? decoded
        guard let verdicts = object as? [String: String] else { return nil }
        var answer = Answer()
        for name in questions {
            switch verdicts[name] {
            case "answered": continue
            case "silent": answer.silent.append(name)
            default: answer.unavailable.append(name)
            }
        }
        return answer
    }
}
