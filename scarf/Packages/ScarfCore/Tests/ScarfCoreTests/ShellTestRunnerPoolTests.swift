#if os(macOS)
import Testing
import Foundation

/// `ShellTestRunner` must not park a cooperative-pool thread while its child
/// runs. A RENDEZVOUS, not a stopwatch (the OffPool P52 lesson): more
/// children than the pool has threads each announce arrival and wait for
/// all the others. A runner that blocks its caller can only have a
/// pool-width of children alive at once, so the rest never start, the
/// barrier never fills, and every child gives up and reports it. Under the
/// regression the test fails on that report after the children's own cap;
/// it never hangs.
@Suite struct ShellTestRunnerPoolTests {
    @Test func concurrentRunsParkNoPoolThread() async throws {
        let count = ProcessInfo.processInfo.activeProcessorCount + 4
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scarf-rendezvous-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Arrive, then wait (up to ~60 s) until every sibling has arrived.
        let script = """
        touch "$1/arrived-$2"
        i=0
        while [ "$(ls "$1" | grep -c '^arrived-')" -lt \(count) ]; do
          i=$((i + 1)); [ $i -gt 600 ] && { echo gave-up; exit 0; }
          sleep 0.1
        done
        echo met
        """
        let outputs = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<count {
                group.addTask {
                    try await ShellTestRunner.run(arguments: ["-c", script, "sh", dir.path, "\(index)"],
                                                  timeout: 120).stdout
                }
            }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(outputs.count == count)
        #expect(outputs.allSatisfy { $0 == "met\n" }, "\(outputs)")
    }
}
#endif
