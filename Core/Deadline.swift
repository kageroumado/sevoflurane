/// Thrown by ``withDeadline(_:_:)`` when its limit passes before the body
/// returns.
nonisolated struct DeadlineExceeded: Error {}

/// Runs `body` and throws ``DeadlineExceeded`` once `limit` has passed
/// without it returning.
///
/// The body is cancelled at the limit, but a task group waits for its
/// children, so the bound holds only for a body that stops promptly on
/// cancellation.
nonisolated func withDeadline<T: Sendable>(
    _ limit: Duration,
    _ body: @escaping @Sendable () async throws -> T,
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        defer { group.cancelAll() }
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw DeadlineExceeded()
        }
        return try await group.next()!
    }
}
