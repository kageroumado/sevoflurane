import Foundation

/// Sends a report zip, whole, as the request body, with the install token and
/// app version as headers; only the status is read.
nonisolated struct ReportUpload: Sendable {
    /// Where reports go: Caddy on the droplet writes the bytes and answers 204.
    static let endpoint = URL(string: "https://reports.kagerou.glass/v1/sevoflurane")!
    /// The largest zip the endpoint accepts. Checked here first, so a report
    /// that could not be taken never leaves the machine.
    static let maximumBytes = 20 * 1024 * 1024
    static let installHeader = "X-Sevoflurane-Install"
    static let versionHeader = "X-Sevoflurane-Version"

    enum Outcome: Equatable, Sendable {
        /// The endpoint stored the report.
        case accepted
        /// Any other status.
        case refused(status: Int)
    }

    enum Failure: Error, Equatable {
        /// The zip is over ``maximumBytes``.
        case tooLarge(bytes: Int)
        case unreadable(String)
        /// The request never got an answer.
        case unreachable(String)
    }

    var endpoint = Self.endpoint
    var installToken: String
    /// `<marketing>+<build>`.
    var version: String
    var session = URLSession.shared

    /// The running app's own upload: its install token and its version.
    static func forThisApp() -> ReportUpload {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return ReportUpload(installToken: Preferences.installToken, version: "\(marketing)+\(build)")
    }

    func send(_ zip: URL) async throws -> Outcome {
        let size = (try? zip.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= Self.maximumBytes else { throw Failure.tooLarge(bytes: size) }
        guard let body = try? Data(contentsOf: zip) else {
            throw Failure.unreadable(zip.lastPathComponent)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        request.setValue(installToken, forHTTPHeaderField: Self.installHeader)
        request.setValue(version, forHTTPHeaderField: Self.versionHeader)
        request.timeoutInterval = Self.timeout
        let response: URLResponse
        do {
            (_, response) = try await session.upload(for: request, from: body)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (200 ..< 300).contains(status) ? .accepted : .refused(status: status)
    }

    /// Long enough for 20 MB on a slow uplink.
    private static let timeout: TimeInterval = 120
}
