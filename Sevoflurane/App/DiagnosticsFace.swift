import Foundation

extension Diagnostics {
    /// What the shared builder cannot ask: the bundled `sevo doctor`'s
    /// verdicts, the daemon's status, and the bottle's dependency state.
    static func appFaceReport() async -> FaceReport {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sevo")
        let doctor = await Subprocess.run(helper.path, ["doctor", "--json"], timeout: .seconds(60))
        let status = await DaemonService.get("/status").flatMap { String(data: $0, encoding: .utf8) }
        let bottleState: [String: Any] = [
            "dependencies": BottleReadiness.dependencyReport(),
            "provisioning": BottleReadiness.lastProvision.map(\.dictionary) ?? NSNull(),
        ]
        // `doctor` exits non-zero when a check fails, which is the run worth
        // reporting, so any JSON object is kept.
        let verdicts = doctor.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return FaceReport(
            doctor: verdicts.hasPrefix("{") ? verdicts : nil,
            status: status,
            bottleState: JSONText.string(bottleState, pretty: true),
        )
    }
}
