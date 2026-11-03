import Foundation

/// The questions only `steam.exe` answers, asked of a client that otherwise
/// probes healthy, and the reading of what comes back.
///
/// Three questions, because one is not enough: through the stall of
/// 2026-10-12 to 14 the install manager's state kept answering while app
/// details, the proxy info and every message post timed out, so the single
/// question the probe used to ask never saw the client's main thread parked.
/// The page's expression asks all three at once and reports each as
/// `answered`, `silent` (nothing within ``timeout``, or the bridge's own
/// deadline rejecting the call) or `n/a` (the page could not ask: the API is
/// missing or refused outright, which is not a stall).
nonisolated enum MainThreadProbe {
    /// How long each question has. The bridge rejects a call into the client
    /// after ``CDPBudget/callCap``, which this exceeds, so a stalled call is
    /// classed by that rejection and only a call that never settles waits
    /// this long.
    static let timeout: Duration = .seconds(6)

    /// The app whose details the probe asks for: any app the store knows
    /// answers, owned or not, and this one has since the probe was written.
    static let detailsAppID = 730

    /// The questions, by the names the answer carries.
    static let questions = ["install", "proxy", "details"]

    /// The page's expression: a promise for a JSON object naming each
    /// question's outcome.
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

    /// What the client answered: the questions it left unanswered, and the
    /// ones the page could not ask.
    struct Answer: Equatable, Sendable {
        var silent: [String] = []
        var unavailable: [String] = []

        /// A client whose main thread is parked leaves at least one question
        /// unanswered; a question the page could not ask says nothing.
        var stuck: Bool { !silent.isEmpty }
    }

    /// Reads the expression's JSON object from `/__eval`'s `v`, where the
    /// bridge JSON-encodes the value once more: the expression resolves a
    /// string, so the object arrives inside a JSON string literal. `nil` for
    /// anything else, which is the page not answering rather than the client.
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
