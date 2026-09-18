import Foundation

extension Diagnostics {
    /// What the app knows that the shared builder cannot ask: the doctor's
    /// verdicts, from the bundled `sevo` so the zip the app sends is the one
    /// `sevo diag` writes; the daemon's status; the bottle's dependency state.
    static func appFaceReport() async -> FaceReport {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sevo")
        let doctor = await Subprocess.run(helper.path, ["doctor", "--json"], timeout: .seconds(60))
        let status = await DaemonService.get("/status").flatMap { String(data: $0, encoding: .utf8) }
        let bottleState: [String: Any] = [
            "dependencies": BottleReadiness.dependencyReport(),
            "provisioning": BottleReadiness.lastProvision.map(\.dictionary) ?? NSNull(),
        ]
        // `doctor` exits non-zero when a check fails, which is the run worth
        // reporting: the report is kept whenever it is a JSON object.
        let verdicts = doctor.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return FaceReport(
            doctor: verdicts.hasPrefix("{") ? verdicts : nil,
            status: status,
            bottleState: JSONText.string(bottleState, pretty: true),
        )
    }
}
