import Foundation

/// One part of setting Steam up, in the order a pass runs them.
nonisolated enum SetupStage: Int, CaseIterable, Sendable {
    /// Closing a Steam that runs somewhere else, before the choice moves.
    case steamStop
    case rosetta
    case engine
    case bottle
    case installer
    case client
    case dependencies
}

/// Where one stage of a pass stands.
nonisolated enum SetupStageState: Equatable, Sendable {
    case pending
    /// Under way; the fraction is the part of it done, where that is known.
    case working(fraction: Double?)
    case done
    case failed
}

/// One stage with its state, for a list of the pass.
nonisolated struct SetupStageReport: Equatable, Identifiable, Sendable {
    let stage: SetupStage
    let state: SetupStageState

    var id: SetupStage {
        stage
    }
}

/// Why a pass stopped: the stage, the cause as one sentence in plain words,
/// and what to do about it where something can be done. The cause is empty
/// where naming the stage that failed says all there is to say.
nonisolated struct SetupFailure: Equatable, Sendable {
    let stage: SetupStage?
    let cause: String
    let advice: String?

    /// The cause and the advice as one line.
    var text: String {
        [cause, advice ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Turns an error into words a person can act on. The full description goes
/// to the log, where its codes and addresses are of use.
nonisolated enum SetupFailureText {
    /// The error as one sentence: the system's own words for a system error,
    /// the error's description for one of the app's.
    static func sentence(_ error: any Error) -> String {
        let system = error as NSError
        let isSystemError = [NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain].contains(system.domain)
        if !isSystemError, !(error is any LocalizedError), let own = error as? any CustomStringConvertible {
            return asSentence(own.description)
        }
        return asSentence(system.localizedDescription)
    }

    /// What to do about the error, where the error says: a network failure
    /// is retried once the connection is back.
    static func advice(_ error: any Error) -> String? {
        (error as NSError).domain == NSURLErrorDomain ? networkAdvice : nil
    }

    static var networkAdvice: String {
        String(localized: "Check the connection, then try again.")
    }

    /// Starts with a capital where the first word is a plain word, and ends
    /// with a full stop.
    static func asSentence(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.last else { return text }
        let firstWord = text.prefix { !$0.isWhitespace }
        let head = firstWord.allSatisfy(\.isLetter) ? text.prefix(1).uppercased() + text.dropFirst() : text
        return ".!?…。！？".contains(last) ? head : head + "."
    }
}
