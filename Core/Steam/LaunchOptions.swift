import Foundation

/// One way Steam can start an app, as `GetLaunchOptionsForApp` lists them: Play, a benchmark tool,
/// a compatibility variant.
nonisolated struct LaunchOption: Equatable, Sendable {
    /// What Steam is answered with: `ContinueGameAction(actionID, String(index))`.
    let index: Int
    /// The label Steam shows for it.
    let description: String
    /// Steam's `ELaunchOptionType`; 0 is the plain launch.
    let type: Int
}

/// Steam's "how should this app start" question: its options, its per-app remembered answer, and
/// the scripts that answer it.
///
/// Steam asks through `RegisterForGameActionUserRequest` with `ShowLaunchOption`; its UI answers
/// from the choice remembered after "Forever", else with a dialog. That choice lives under a
/// `SteamClient.Storage` key built from the app id and a hash of the options' JSON, both mirrored
/// here so the app can honor and clear it.
nonisolated enum LaunchOptions {
    /// The options in index order, labeled in words. A localization token takes the option's
    /// description from `descriptions` (the app's `appinfo.vdf`, read only when a token is
    /// present), else ``label(_:game:)``; repeated labels get their list number. Never alter the
    /// JSON: Steam keys the remembered choice by its hash. Entries without `nIndex` are skipped;
    /// malformed JSON is an empty list.
    static func parse(_ json: String, descriptions: () -> [Int: String] = { [:] }) -> [LaunchOption] {
        guard let data = json.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        let tokens = entries.contains { ($0["strDescription"] as? String)?.hasPrefix("#") == true }
        let own = tokens ? descriptions() : [:]
        let options = entries.compactMap { entry -> LaunchOption? in
            guard let index = (entry["nIndex"] as? NSNumber)?.intValue else { return nil }
            let description = entry["strDescription"] as? String ?? ""
            return LaunchOption(
                index: index,
                description: description.hasPrefix("#")
                    ? own[index] ?? label(description, game: entry["strGameName"] as? String)
                    : description,
                type: (entry["eType"] as? NSNumber)?.intValue ?? 0,
            )
        }.sorted { $0.index < $1.index }
        return distinguished(options)
    }

    /// A description in words. `#Steam_LaunchOption_Game` is "Play <game>"; any other token drops
    /// `#`, `Steam_` and `LaunchOption_` and reads underscores as spaces
    /// (`#LaunchOption_Play_Safe_Mode` is "Play Safe Mode").
    static func label(_ description: String, game: String? = nil) -> String {
        guard description.hasPrefix("#") else { return description }
        var token = Substring(description.dropFirst())
        if token == "Steam_LaunchOption_Game" {
            guard let game, !game.isEmpty else { return String(localized: "Play") }
            return String(localized: "Play \(game)")
        }
        for prefix in ["Steam_", "LaunchOption_"] where token.hasPrefix(prefix) {
            token = token.dropFirst(prefix.count)
        }
        return token.replacingOccurrences(of: "_", with: " ")
    }

    /// Repeated labels followed by the option's list number, counted from 1 as `sevo app launch
    /// --option` counts.
    static func distinguished(_ options: [LaunchOption]) -> [LaunchOption] {
        let counts = Dictionary(options.map { ($0.description, 1) }, uniquingKeysWith: +)
        return options.enumerated().map { number, option in
            guard counts[option.description, default: 0] > 1 else { return option }
            return LaunchOption(
                index: option.index,
                description: String(localized: "\(option.description) (option \(number + 1))"),
                type: option.type,
            )
        }
    }

    /// The stored answer, when it still names an option in the list.
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

    /// The `SteamClient.Storage` key for an app's remembered option, given the options JSON exactly
    /// as `GetLaunchOptionsForApp` serializes it.
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

    /// The same key as a JavaScript function `(appid, options) -> key`.
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

    /// Starts an app after clearing its remembered option, so Steam asks again; answers
    /// `"started"`.
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

    /// Starts an app and answers its `ShowLaunchOption` request with `option`, from the client's
    /// `SharedJSContext`. The remembered option is cleared first so Steam's UI cannot answer ahead;
    /// the registration ends with the answer or after two minutes.
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

    /// The options list for an app, as JSON.
    static func listScript(appID: Int) -> String {
        "SteamClient.Apps.GetLaunchOptionsForApp(\(appID)).then(function (options) { return JSON.stringify(options || []); })"
    }
}
