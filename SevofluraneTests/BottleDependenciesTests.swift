import Foundation
import Testing
@testable import Sevoflurane

/// The install lane: five rows pressed at once must not run at once, and no
/// install may work in a directory another one deletes.
@Suite(.serialized)
struct BottleDependencyInstallTests {
    /// What the playtest hit: five installs sharing one scratch path, each
    /// removing it when it ended, so whichever was still downloading found
    /// its destination gone.
    @Test
    func `every install keeps its own scratch until it ends`() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("sevo-deps-test-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }

        let failures = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for dependency in BottleDependencies.catalog {
                group.addTask {
                    let queue = BottleDependencies.InstallQueue.shared
                    return await queue.enqueue {
                        let scratch = BottleDependencies.Scratch(id: dependency.id, root: root)
                        defer { scratch.remove() }
                        try? FileManager.default.createDirectory(
                            at: scratch.url, withIntermediateDirectories: true,
                        )
                        try? await Task.sleep(for: .milliseconds(20))
                        let file = scratch.directory("payload")
                        try? Data("payload".utf8).write(to: file)
                        try? await Task.sleep(for: .milliseconds(20))
                        guard FileManager.default.fileExists(atPath: file.path) else {
                            return "\(dependency.id): its scratch was removed under it"
                        }
                        return nil
                    } waiting: {}
                }
            }
            return await group.reduce(into: []) { result, failure in
                if let failure { result.append(failure) }
            }
        }

        #expect(failures.isEmpty)
        // Each install removed its own and nothing else's, so the root is
        // empty rather than missing.
        let leftovers = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test
    func `two installs never run at the same time`() async {
        let overlap = Overlap()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 5 {
                group.addTask {
                    _ = await BottleDependencies.InstallQueue.shared.enqueue {
                        await overlap.enter()
                        try? await Task.sleep(for: .milliseconds(10))
                        await overlap.leave()
                        return nil
                    } waiting: {}
                }
            }
        }
        #expect(await overlap.peak == 1)
    }

    @Test
    func `a queued install says it is waiting`() async {
        let notes = Notes()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = await BottleDependencies.InstallQueue.shared.enqueue {
                    try? await Task.sleep(for: .milliseconds(50))
                    return nil
                } waiting: {}
            }
            try? await Task.sleep(for: .milliseconds(5))
            group.addTask {
                _ = await BottleDependencies.InstallQueue.shared.enqueue {
                    nil
                } waiting: { notes.add("waiting") }
            }
        }
        #expect(notes.all == ["waiting"])
    }

    /// Two scratches for the same dependency are still two directories: an
    /// id alone would have collided a retry with the run it retried.
    @Test
    func `each scratch is its own directory`() {
        let first = BottleDependencies.Scratch(id: "corefonts")
        let second = BottleDependencies.Scratch(id: "corefonts")
        #expect(first.url != second.url)
        #expect(first.windowsPath != second.windowsPath)
        #expect(first.windowsPath.hasPrefix(#"C:\windows\temp\sevo-deps\corefonts-"#))
        #expect(first.windowsPath(#"dx\DXSETUP.exe"#) == first.windowsPath + #"\dx\DXSETUP.exe"#)
    }

    private actor Overlap {
        private(set) var peak = 0
        private var current = 0

        func enter() {
            current += 1
            peak = max(peak, current)
        }

        func leave() {
            current -= 1
        }
    }

    private final class Notes: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        func add(_ message: String) {
            lock.withLock { messages.append(message) }
        }

        var all: [String] {
            lock.withLock { messages }
        }
    }
}

/// The download half: a rate-limited host is waited out, a broken file is
/// refused, and a flat refusal is not retried.
@Suite(.serialized)
struct BottleDependencyDownloadTests {
    @Test
    func `a rate-limited host is retried until it answers`() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("sevo-deps-test-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let scratch = BottleDependencies.Scratch(id: "d3dcompiler", root: root)
        StubProtocol.reset(replies: [.status(429), .status(429), .body("the dll")])

        let file = try await BottleDependencies.download(
            "https://stub.invalid/d3dcompiler_47.dll", as: "d3dcompiler_47.dll",
            into: scratch, session: StubProtocol.session(), backoff: [.zero, .zero],
        )

        #expect(StubProtocol.requestCount == 3)
        #expect(try String(contentsOf: file, encoding: .utf8) == "the dll")
    }

    @Test
    func `a host that keeps refusing reports the last refusal`() async {
        let scratch = scratchInTemp()
        StubProtocol.reset(replies: [.status(429), .status(503), .status(429)])

        await #expect(throws: Error.self) {
            try await BottleDependencies.download(
                "https://stub.invalid/d3dcompiler_47.dll", as: "d3dcompiler_47.dll",
                into: scratch, session: StubProtocol.session(), backoff: [.zero, .zero],
            )
        }
        #expect(StubProtocol.requestCount == 3)
    }

    /// 404 is the host's answer, not its mood: retrying it three times only
    /// delays the same failure.
    @Test
    func `a flat refusal is not retried`() async {
        let scratch = scratchInTemp()
        StubProtocol.reset(replies: [.status(404), .body("never reached")])

        await #expect(throws: Error.self) {
            try await BottleDependencies.download(
                "https://stub.invalid/gone.dll", as: "gone.dll",
                into: scratch, session: StubProtocol.session(), backoff: [.zero, .zero],
            )
        }
        #expect(StubProtocol.requestCount == 1)
    }

    @Test
    func `a download that is not the pinned file is refused`() async {
        let scratch = scratchInTemp()
        StubProtocol.reset(replies: [.body("something else entirely")])

        await #expect(throws: Error.self) {
            try await BottleDependencies.download(
                "https://stub.invalid/d3dcompiler_47.dll", as: "d3dcompiler_47.dll",
                into: scratch, sha256: String(repeating: "0", count: 64),
                session: StubProtocol.session(), backoff: [],
            )
        }
        #expect(StubProtocol.requestCount == 1)
    }

    @Test
    func `a download that matches its digest is kept`() async throws {
        let scratch = scratchInTemp()
        StubProtocol.reset(replies: [.body("the dll")])

        let file = try await BottleDependencies.download(
            "https://stub.invalid/d3dcompiler_47.dll", as: "d3dcompiler_47.dll",
            // The sha256 of "the dll".
            into: scratch,
            sha256: "0a852575f6aeb43c391bdba33627c846b3bf4e32809849fcd10db44497121bff",
            session: StubProtocol.session(), backoff: [],
        )
        #expect(try String(contentsOf: file, encoding: .utf8) == "the dll")
    }

    private func scratchInTemp() -> BottleDependencies.Scratch {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sevo-deps-test-\(UUID().uuidString)")
        return BottleDependencies.Scratch(id: "d3dcompiler", root: root)
    }
}

/// A stubbed transport: one scripted reply per request, in order.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case status(Int)
        case body(String)
    }

    private nonisolated(unsafe) static var replies: [Reply] = []
    private nonisolated(unsafe) static var served = 0
    private static let lock = NSLock()

    static func reset(replies: [Reply]) {
        lock.withLock {
            self.replies = replies
            served = 0
        }
    }

    static var requestCount: Int {
        lock.withLock { served }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let reply = Self.lock.withLock { () -> Reply in
            let reply = Self.served < Self.replies.count
                ? Self.replies[Self.served] : .status(500)
            Self.served += 1
            return reply
        }
        let url = request.url ?? URL(string: "https://stub.invalid")!
        let status = switch reply {
        case let .status(code): code
        case .body: 200
        }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil,
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if case let .body(text) = reply {
            client?.urlProtocol(self, didLoad: Data(text.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
