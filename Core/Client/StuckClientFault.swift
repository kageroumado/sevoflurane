import Foundation

/// A fault Wine's log names that has left the Steam client stuck before.
nonisolated enum StuckClientFault: Equatable, Sendable {
    /// rpcrt4's named-pipe server thread ended at the 64 handles one wait
    /// takes, so the next COM call that needs it waits forever. Steam reaches
    /// it by rebuilding its taskbar jump list.
    case rpcListenerLimit
    /// A process called a function Wine does not have and aborted; whatever
    /// waits on that process waits forever. The function is named as Wine
    /// prints it, `GDI32.dll.D3DKMTSetProcessSchedulingPriorityClass`.
    case unimplementedFunction(String)
    /// Steam's own watchdog found its engine thread stalled, which is when
    /// Steam writes `assert_steam.exe_*.dmp`.
    case engineLoopStalled

    /// What the event log says of the fault.
    var sentence: String {
        switch self {
        case .rpcListenerLimit:
            "Wine's RPC server thread ended at its 64-listener limit (rpcrt4, error 87); "
                + "the next COM call in steam.exe waits on it forever"
        case let .unimplementedFunction(name):
            "a process aborted on \(name), a function Wine does not implement"
        case .engineLoopStalled:
            "Steam's own watchdog found its engine thread stalled for over 15 seconds"
        }
    }

    /// The known faults in `tail`, the end of Wine's log, in the order the log
    /// first names each. Only the lines since the client last started count:
    /// each fault lasts as long as the client's processes do.
    static func faults(in tail: String) -> [StuckClientFault] {
        var found: [StuckClientFault] = []
        for line in clientSession(of: tail).split(whereSeparator: \.isNewline) {
            guard let fault = fault(in: line), !found.contains(fault) else { continue }
            found.append(fault)
        }
        return found
    }

    /// The part of `tail` after the last header a client start wrote
    /// (``WineLog/header(label:at:debugMode:)``), or all of it without one.
    static func clientSession(of tail: String) -> Substring {
        guard let header = tail.ranges(of: clientHeader).last else { return tail[...] }
        return tail[header.upperBound...]
    }

    private static func fault(in line: Substring) -> StuckClientFault? {
        if line.contains("rpcrt4_protseq_np_wait_for_new_connection wait failed with error 87") {
            return .rpcListenerLimit
        }
        if let match = line.firstMatch(of: unimplemented) {
            return .unimplementedFunction(String(match.output.1))
        }
        if line.contains("CSteamEngine::BMainLoop appears to have stalled") {
            return .engineLoopStalled
        }
        return nil
    }

    private nonisolated(unsafe) static let clientHeader = #/==== \S+ client \(/#
    private nonisolated(unsafe) static let unimplemented = #/wine: Call from \S+ to unimplemented function (\S+), aborting/#
}
