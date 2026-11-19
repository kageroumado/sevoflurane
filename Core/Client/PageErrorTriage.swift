import Foundation

/// Sorts what the Steam UI's error guard reports into the errors worth a
/// reader's alarm and the refusals every session produces.
///
/// The UI leaves rejected promises unhandled: it sets a SteamVR path property
/// at every boot and keeps posting messages while the client closes. The
/// client refuses both, as it does on Windows.
nonisolated enum PageErrorTriage {
    enum Verdict: Equatable {
        /// A real page error, logged as it arrived.
        case error
        /// An expected refusal, logged once per boot in plain words.
        case expected(String)
        /// A call to a Chromium API WebKit lacks (``ChromiumSurface``),
        /// named so the log says which one the shim must supply.
        case missingChromiumAPI(String)
    }

    static func verdict(for detail: String) -> Verdict {
        let message = Self.message(in: detail)
        if message.contains("SteamClient.OpenVR."), message.contains("not found") {
            return .expected("the Steam UI asked for SteamVR, which this bottle does not have — the client refused the call")
        }
        if let api = ChromiumSurface.chromiumOnly.first(where: {
            message.contains("\($0.token) is not a function") || message.contains("\($0.token) is not a constructor")
        }) {
            return .missingChromiumAPI(api.name)
        }
        if message.hasSuffix("rejected: closed") {
            return .expected("the Steam UI kept calling a client that is closing — the calls were refused")
        }
        return .error
    }

    /// The `message` field of the guard's JSON, or the whole text when it is
    /// something else.
    private static func message(in detail: String) -> String {
        guard let data = detail.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String
        else { return detail }
        return message
    }
}
