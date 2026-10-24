import Foundation

@MainActor final class Gate {
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
    func open() { let saved = waiters; waiters = []; saved.forEach { $0.resume() } }
}

@main struct Tests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        func settle() async { for _ in 0..<100 { await Task.yield() } }
        let reads = SyncRequestCoalescer()
        let gate = Gate()
        var calls = 0
        let operation: @MainActor () async throws -> Data = {
            calls += 1; await gate.wait(); return Data([1])
        }
        let first = Task { try await reads.perform(key: "family-A/read", operation: operation) }
        await settle()
        let second = Task { try await reads.perform(key: "family-A/read", operation: operation) }
        await settle()
        check(calls == 1, "Concurrent identical reads share one HTTP operation")
        gate.open()
        let a = try await first.value, b = try await second.value
        check(a == b, "All waiters receive the result")
        _ = try await reads.perform(key: "family-A/read") { calls += 1; return Data() }
        check(calls == 2, "Completed responses are not cached")

        let old = Task { try await reads.perform(key: "same", operation: operation) }
        await settle()
        reads.invalidate()
        let newGate = Gate()
        let new = Task { try await reads.perform(key: "same") { calls += 1; await newGate.wait(); return Data([2]) } }
        await settle()
        check(calls == 4, "Mutation/push invalidation starts a fresh request")
        gate.open(); _ = try await old.value
        let joined = Task { try await reads.perform(key: "same", operation: operation) }
        await settle()
        check(calls == 4, "Old completion cannot evict the newer in-flight request")
        newGate.open()
        let c = try await new.value, d = try await joined.value
        check(c == Data([2]) && c == d, "New waiters do not receive old responses")

        enum Failure: Error { case offline }
        do { _ = try await reads.perform(key: "retry") { throw Failure.offline }; preconditionFailure() }
        catch Failure.offline { checks += 1 }
        _ = try await reads.perform(key: "retry") { Data() }
        checks += 1
        let scopedA = Task { try await reads.perform(key: "A", operation: operation) }
        let scopedB = Task { try await reads.perform(key: "B", operation: operation) }
        await settle()
        check(calls == 6, "Different scopes/payloads never share requests")
        scopedA.cancel(); gate.open()
        _ = try await scopedA.value; _ = try await scopedB.value
        checks += 1 // Cancellation of one consumer does not cancel the transport.

        let registration = APNSRegistrationCoordinator()
        var sent: [APNSRegistrationCoordinator.Registration] = []
        var uptime: TimeInterval = 100
        let send: @MainActor (APNSRegistrationCoordinator.Registration) async throws -> Void = { sent.append($0) }
        try await registration.register(token: "aa", environment: "sandbox", uptime: { uptime }, send: send)
        try await registration.register(token: "aa", environment: nil, uptime: { uptime }, send: send)
        check(sent.count == 1, "Bootstrap does not resend an acknowledged token")
        try await registration.register(token: "aa", environment: "production", uptime: { uptime }, send: send)
        check(sent.count == 2 && sent.last?.environment == "production", "Xcode/TestFlight environment change is sent")
        try await registration.register(token: "bb", environment: nil, isFresh: true, uptime: { uptime }, send: send)
        check(sent.count == 3 && sent.last?.token == "bb", "Fresh token works even without known environment")
        try await registration.register(token: "aa", environment: nil, uptime: { uptime }, send: send)
        check(sent.count == 3, "Stale bootstrap cannot overwrite a fresh token")
        uptime += 86_400
        try await registration.register(token: "bb", environment: nil, uptime: { uptime }, send: send)
        check(sent.count == 4, "Long running process periodically repairs registration")
        registration.invalidate()
        do {
            try await registration.register(token: "bb", environment: nil, uptime: { uptime }) { _ in throw Failure.offline }
            preconditionFailure()
        } catch Failure.offline { checks += 1 }
        try await registration.register(token: "bb", environment: nil, uptime: { uptime }, send: send)
        check(sent.count == 5, "Failures and device resets are retried")

        let serial = APNSRegistrationCoordinator(), tokenGate = Gate()
        var serialSent: [String] = []
        let oldToken = Task {
            try await serial.register(token: "aa", environment: nil) { value in
                serialSent.append(value.token); await tokenGate.wait()
            }
        }
        await settle()
        let freshToken = Task {
            try await serial.register(token: "bb", environment: "production", send: { serialSent.append($0.token) })
        }
        await settle()
        check(serialSent == ["aa"], "Registration writes are serialized")
        tokenGate.open(); try await oldToken.value; try await freshToken.value
        check(serialSent == ["aa", "bb"], "Fresh token is the final server value")
        print("Passed \(checks) sync efficiency checks")
    }
}
