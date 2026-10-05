import Digoxin
import Foundation
import Testing
@testable import Sevoflurane

/// The app's own Digoxin client against a local Digoxin service: choosing
/// counting registers this Mac and sends the day's check-in, and choosing off
/// deletes it on the server. Runs only when `SEVOFLURANE_DIGOXIN_URL` and
/// `SEVOFLURANE_DIGOXIN_ADMIN` name a service serving the app `sevoflurane`
/// (through `xcodebuild test`, with the `TEST_RUNNER_` prefix). The key and
/// its state live in the test run's home.
/// The local service's admin listener, from the environment.
private let localDigoxinAdmin = ProcessInfo.processInfo.environment["SEVOFLURANE_DIGOXIN_ADMIN"].flatMap(URL.init(string:))

@Suite(.serialized, .enabled(if: localDigoxinAdmin != nil))
struct UsageCountingEndToEndTests {
    /// One admin endpoint's JSON.
    private static func adminJSON(_ path: String) async throws -> Any {
        let url = try #require(localDigoxinAdmin).appending(path: path)
        let (data, _) = try await URLSession.shared.data(from: url)
        note("GET \(path): \(String(decoding: data, as: UTF8.self))")
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Appends `line` to the file `SEVOFLURANE_DIGOXIN_EVIDENCE` names: a
    /// hosted test's standard output reaches no log.
    private static func note(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["SEVOFLURANE_DIGOXIN_EVIDENCE"],
              let handle = FileHandle(forWritingAtPath: path) ?? {
                  FileManager.default.createFile(atPath: path, contents: nil)
                  return FileHandle(forWritingAtPath: path)
              }()
        else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }

    /// The app's installs and heartbeats on the service.
    private static func counts() async throws -> (installs: Int, heartbeats: Int) {
        let apps = try #require(try await adminJSON("admin/apps") as? [[String: Any]])
        let app = try #require(apps.first { $0["app"] as? String == UsageCounting.app })
        let installs = (app["installs"] as? [String: Int] ?? [:]).values.reduce(0, +)
        return (installs, app["heartbeats"] as? Int ?? 0)
    }

    /// Polls `condition` for up to 30 seconds: the client sends on its own task.
    private static func eventually(_ condition: () async throws -> Bool) async throws -> Bool {
        for _ in 0 ..< 60 {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    @Test
    func `counting sends a check-in and off deletes it`() async throws {
        #expect(UsageCounting.baseURL.absoluteString == ProcessInfo.processInfo.environment["SEVOFLURANE_DIGOXIN_URL"])
        #expect(try await Self.counts() == (0, 0))

        UsageCounting.choose(.counting)
        #expect(Preferences.usageCounting == .counting)
        #expect(try await Self.eventually { try await Self.counts() == (1, 1) })
        let stats = try #require(try await Self.adminJSON("admin/\(UsageCounting.app)/stats") as? [String: Any])
        await Self.note("status: \(UsageCounting.client.status)")
        #expect(stats["properties"] == nil || (stats["properties"] as? [String: Any])?.isEmpty == true)

        UsageCounting.choose(.off)
        #expect(Preferences.usageCounting == .off)
        #expect(try await Self.eventually { try await Self.counts() == (0, 0) })
        #expect(await UsageCounting.client.status == .off)
        await Self.note("status: \(UsageCounting.client.status)")
    }
}
