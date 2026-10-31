import Foundation

/// The engine's word that a decoder was fed and produced nothing: one
/// `… ERROR WINE wg_transform.c:…: transform 0x… decoded none of N buffers
/// (video/x-h264 -> video/x-raw)` line in the Wine log, which dormison r9 and
/// later write once per transform, when its input runs dry, at a flush and
/// at its end. A game stuck on a blank video is exactly this from outside:
/// presents go on, the CPU rests, and the decoder answers nothing.
///
/// GStreamer's log line starts with its running clock, then the Unix pid,
/// which is the pid the engine's `sevo:run` lines name.
nonisolated enum VideoStarvation {
    /// One decoded-nothing line.
    struct Starved: Equatable, Sendable {
        var pid: Int
        var buffers: Int
        /// The stream's type as GStreamer names it, `video/x-h264`.
        var input: String
        var output: String

        /// Whether the stream is a picture rather than a sound.
        var isVideo: Bool { input.hasPrefix("video/") }
    }

    /// Every such line in `text`, in order.
    static func all(in text: String) -> [Starved] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.contains(marker), let match = line.firstMatch(of: pattern) else { return nil }
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = Int(fields[1]), let buffers = Int(match.output.1) else { return nil }
            return Starved(pid: pid, buffers: buffers, input: String(match.output.2), output: String(match.output.3))
        }
    }

    /// The first video stream one of `pids` decoded nothing from.
    static func video(forProcesses pids: Set<Int>, in text: String) -> Starved? {
        all(in: text).first { $0.isVideo && pids.contains($0.pid) }
    }

    /// What a run of `appID` keeps when one of its processes decoded nothing
    /// from a video, with the decoding the game ran under. The processes are
    /// the ones the engine's `sevo:run` lines in `lines` attribute to the app.
    static func video(forApp appID: Int, in lines: String, bottle: String = SteamBottle.name) -> RunRecord.Video? {
        guard let starved = video(forProcesses: WineProvenance.processes(forApp: appID, in: lines), in: lines)
        else { return nil }
        return RunRecord.Video(
            buffers: starved.buffers, stream: starved.input,
            decoding: GameConfig.videoDecoding(bottle: bottle, game: appID).value.rawValue,
        )
    }

    /// What every such line contains; the cheap test before the pattern.
    static let marker = "decoded none of"

    private nonisolated(unsafe) static let pattern = /transform \S+ decoded none of (\d+) buffers \((\S+) -> (\S+)\)/
}

/// Whether a run whose video decoded nothing earns the offer of the other
/// decoder: hardware for a game on software, software for one on hardware.
nonisolated enum VideoDecodingDiagnosis {
    struct Suggestion: Equatable, Sendable {
        let video: RunRecord.Video
        /// What the game ran with.
        let current: VideoDecoding

        /// What it is offered.
        var offered: VideoDecoding { current.other }
    }

    /// The suggestion for `record`, or nil when its videos decoded, the
    /// game's decoding has changed since the run, or the user asked not to
    /// hear it.
    ///
    /// - Parameters:
    ///   - current: The game's video decoding as it resolves now.
    ///   - asks: Whether the offer is still wanted for this game.
    static func suggestion(for record: RunRecord, current: VideoDecoding, asks: Bool = true) -> Suggestion? {
        guard asks, let video = record.video, video.decoding == current.rawValue else { return nil }
        return Suggestion(video: video, current: current)
    }
}
