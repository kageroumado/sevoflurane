import Foundation

/// One way Steam can start an app, as `SteamClient.Apps.GetLaunchOptionsForApp`
/// lists them: Play, a benchmark tool, a compatibility-mode variant.
nonisolated struct LaunchOption: Equatable, Sendable {
    /// What Steam is answered with: `ContinueGameAction(actionID, String(index))`.
    let index: Int
    /// The label Steam shows for it, in words.
    let description: String
    /// Steam's `ELaunchOptionType`; 0 is the plain launch.
    let type: Int
}

/// Steam's "how should this app start" question: the options it lists, the
/// answer it remembers per app, and the scripts that answer it.
///
/// Steam asks through `RegisterForGameActionUserRequest` with the request
/// `ShowLaunchOption`, and its own UI answers from a remembered choice when the
/// user once picked "Forever", otherwise with a dialog. The remembered choice
/// is a string under a `SteamClient.Storage` key built from the app id and a
/// hash of the options' JSON, so it is only valid while the options are the
/// same ones. Both the key and the hash are Steam's, mirrored here so the app
/// can honor and clear the same memory Steam's dialog writes.
nonisolated enum LaunchOptions {
    /// The options in an app's list, in index order. An entry Steam did not
    /// number is skipped; malformed JSON is an empty list.
    static func parse(_ json: String) -> [LaunchOption] {
        guard let data = json.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry -> LaunchOption? in
            guard let index = (entry["nIndex"] as? NSNumber)?.intValue else { return nil }
            return LaunchOption(
                index: index,
                description: label(entry["strDescription"] as? String ?? ""),
                type: (entry["eType"] as? NSNumber)?.intValue ?? 0,
            )
        }.sorted { $0.index < $1.index }
    }

    /// A description in words. Steam sends some as localization tokens
    /// (`#LaunchOption_Play`): the marker and the token's family go, and the
    /// underscores become spaces.
    static func label(_ description: String) -> String {
        guard description.hasPrefix("#") else { return description }
        var token = String(description.dropFirst())
        if let underscore = token.firstIndex(of: "_") {
            token = String(token[token.index(after: underscore)...])
        }
        return token.replacingOccurrences(of: "_", with: " ")
    }

    /// The index Steam's dialog would start with on its own: the stored
    /// answer, when there is one and it still names an option in the list.
    static func rememberedIndex(_ stored: String?, among options: [LaunchOption]) -> Int? {
        guard let stored, let index = Int(stored.trimmingCharacters(in: .whitespaces)),
              options.contains(where: { $0.index == index }) else { return nil }
        return index
    }

    /// The options as a log names them: `"Play", "Run Benchmark Tool"`.
    static func summary(_ options: [LaunchOption]) -> String {
        options.map { "\u{201C}\($0.description)\u{201D}" }.joined(separator: ", ")
    }

    // MARK: - Steam's memory

    /// The `SteamClient.Storage` key Steam keeps an app's remembered launch
    /// option under, for the options list exactly as `GetLaunchOptionsForApp`
    /// serializes it.
    static func rememberedKey(appID: Int, optionsJSON: String) -> String {
        "Apps\\\(appID)\\DefaultLaunchOption\\\(String(hash(optionsJSON), radix: 16))"
    }

    /// Steam's string hash, unsigned: `h = h * 31 + unit` over UTF-16 code
    /// units, truncated to 32 bits at each step.
    private static func hash(_ text: String) -> UInt32 {
        var hash: Int32 = 0
        for unit in text.utf16 {
            hash = (hash << 5) &- hash &+ Int32(unit)
        }
        return UInt32(bitPattern: hash)
    }

    /// The same key as a JavaScript function `(appid, options) -> key`, for
    /// the scripts that read or clear the memory where the options are.
    static let rememberedKeyScript = """
    (function (appid, options) {
      var text = JSON.stringify(options), hash = 0;
      for (var i = 0; i < text.length; i++) {
        hash = (hash << 5) - hash + text.charCodeAt(i);
        hash |= 0;
      }
      return "Apps\\\\" + appid + "\\\\DefaultLaunchOption\\\\"
        + (hash < 0 ? 4294967295 + hash + 1 : hash).toString(16);
    })
    """

    // MARK: - Answering

    /// Answers a `ShowLaunchOption` request with one option.
    static func continueScript(actionID: Int, index: Int) -> String {
        "SteamClient.Apps.ContinueGameAction(\(actionID), \(JSLiteral.string(String(index)))); \"sent\""
    }

    /// Abandons the launch at its `ShowLaunchOption` request.
    static func cancelScript(actionID: Int) -> String {
        "SteamClient.Apps.CancelGameAction(\(actionID)); \"sent\""
    }

    /// Starts an app after clearing the option Steam remembers for it, so the
    /// question is asked again rather than answered from memory. Answers
    /// `"started"` once the launch is requested.
    static func forgetAndRunScript(appID: Int) -> String {
        """
        (function () {
          var appid = \(appID);
          var key = \(rememberedKeyScript);
          var run = function () {
            SteamClient.Apps.RunGame(String(appid), "", -1, 100);
            return "started";
          };
          return SteamClient.Apps.GetLaunchOptionsForApp(appid)
            .then(function (options) { return SteamClient.Storage.DeleteKey(key(appid, options)); })
            .then(run, run);
        })()
        """
    }

    /// Starts an app and answers its `ShowLaunchOption` request with `option`,
    /// from a context with no app to ask the user: the client's own
    /// `SharedJSContext`. The remembered option is cleared first, so Steam's
    /// own UI has nothing to answer with ahead of this script. The
    /// registrations leave with the answer, or after two minutes for a launch
    /// that never asks.
    static func runAnsweringScript(appID: Int, option: Int) -> String {
        """
        (function () {
          var appid = \(appID), wanted = \(JSLiteral.string(String(option)));
          var key = \(rememberedKeyScript);
          var done = false, ask = null;
          var finish = function () {
            if (done) return;
            done = true;
            try { ask.unregister(); } catch (e) {}
          };
          // Steam calls it with (action id, app id, action, request).
          ask = SteamClient.Apps.RegisterForGameActionUserRequest(function (actionID, gameid, action, request) {
            if (String(gameid) !== String(appid) || request !== "ShowLaunchOption") return;
            SteamClient.Apps.ContinueGameAction(actionID, wanted);
            finish();
          });
          setTimeout(finish, 120000);
          var run = function () {
            SteamClient.Apps.RunGame(String(appid), "", -1, 100);
            return "started";
          };
          return SteamClient.Apps.GetLaunchOptionsForApp(appid)
            .then(function (options) { return SteamClient.Storage.DeleteKey(key(appid, options)); })
            .then(run, run);
        })()
        """
    }

    /// The options list for an app, as JSON, from the client's own context.
    static func listScript(appID: Int) -> String {
        "SteamClient.Apps.GetLaunchOptionsForApp(\(appID)).then(function (options) { return JSON.stringify(options || []); })"
    }
}
