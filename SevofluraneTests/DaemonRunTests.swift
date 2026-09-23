import Foundation
import Synchronization
import Testing
@testable import Sevoflurane

/// When a bottle command asked of the daemon is run here instead: only when
/// no daemon took it, never when one may have started it.
@Suite(.serialized)
struct DaemonRunTests {
    @Test
    func `a refused connection runs the program here`() async {
        let outcome = await Self.run(answering: .failure(URLError(.cannotConnectToHost)))
        guard case .unreachable = outcome else {
            Issue.record("expected unreachable, got \(outcome)")
            return
        }
    }

    @Test
    func `a timed-out request is a failure, not a second run`() async {
        let outcome = await Self.run(answering: .failure(URLError(.timedOut)))
        guard case .failed = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
    }

    @Test
    func `a connection lost mid-run is a failure, not a second run`() async {
        let outcome = await Self.run(answering: .failure(URLError(.networkConnectionLost)))
        guard case .failed = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
    }

    @Test
    func `the daemon's answer is the result`() async {
        let body = Data(#"{"status":0,"output":"done"}"#.utf8)
        let outcome = await Self.run(answering: .success((200, body)))
        guard case let .answered(result) = outcome else {
            Issue.record("expected answered, got \(outcome)")
            return
        }
        #expect(result.status == 0)
        #expect(result.output == "done")
    }

    @Test
    func `a daemon without the endpoint runs the program here`() async {
        let outcome = await Self.run(answering: .success((404, Data())))
        guard case .unreachable = outcome else {
            Issue.record("expected unreachable, got \(outcome)")
            return
        }
    }

    private static func run(answering answer: Result<(Int, Data), URLError>) async -> ClientLifecycle.DaemonRun {
        StubDaemon.answer.withLock { $0 = answer }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubDaemon.self]
        let session = URLSession(configuration: configuration)
        let request = ClientLifecycle.daemonRunRequest(["reg.exe", "add"], timeout: .seconds(5))!
        return await ClientLifecycle.daemonRun(request, session: session)
    }
}

/// A daemon that answers every request one fixed way.
private final class StubDaemon: URLProtocol, @unchecked Sendable {
    static let answer = Mutex<Result<(Int, Data), URLError>>(.failure(URLError(.unknown)))

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.answer.withLock({ $0 }) {
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        case let .success((status, body)):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil,
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
