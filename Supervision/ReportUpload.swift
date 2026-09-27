import Foundation

/// Sends a report zip to the Sevoflurane developers.
///
/// The zip is the request body, whole; the installation's token and the
/// app's version ride as headers. The answer is a status and nothing else:
/// the endpoint stores bytes, and this code reads nothing back from it.
nonisolated struct ReportUpload: Sendable {
    /// Where reports go: the droplet behind
    /// Caddy, which writes the bytes to disk and answers 204.
    static let endpoint = URL(string: "https://reports.kagerou.glass/v1/sevoflurane")!
    /// The largest zip the endpoint accepts. Checked here first, so a report
    /// that could not be taken never leaves the machine.
    static let maximumBytes = 20 * 1024 * 1024
    static let installHeader = "X-Sevoflurane-Install"
    static let versionHeader = "X-Sevoflurane-Version"

    enum Outcome: Equatable, Sendable {
        /// The endpoint stored the report.
        case accepted
        /// The endpoint answered with a status that says it did not — too
        /// large, too many, or a server that is not itself.
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
