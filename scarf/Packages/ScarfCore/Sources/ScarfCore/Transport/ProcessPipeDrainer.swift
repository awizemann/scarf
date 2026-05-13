import Foundation

#if !os(iOS)
/// Concurrently drains stdout and stderr for subprocesses that are otherwise
/// waited on synchronously by `runProcess`.
///
/// Waiting for a process to exit before reading its pipes deadlocks once either
/// pipe crosses the kernel buffer size. The child blocks on write, never exits,
/// and the caller only sees a timeout. Start this immediately after attaching
/// pipes so output is consumed while the process is still running.
enum ProcessPipeDrainer {
    fileprivate final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func set(_ value: Data) {
            lock.lock()
            data = value
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    struct Capture {
        private let group: DispatchGroup
        private let stdout: LockedData
        private let stderr: LockedData

        fileprivate init(group: DispatchGroup, stdout: LockedData, stderr: LockedData) {
            self.group = group
            self.stdout = stdout
            self.stderr = stderr
        }

        func wait() -> (stdout: Data, stderr: Data) {
            group.wait()
            return (stdout.snapshot(), stderr.snapshot())
        }
    }

    static func start(stdout stdoutHandle: FileHandle, stderr stderrHandle: FileHandle) -> Capture {
        let group = DispatchGroup()
        let stdout = LockedData()
        let stderr = LockedData()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout.set((try? stdoutHandle.readToEnd()) ?? Data())
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr.set((try? stderrHandle.readToEnd()) ?? Data())
            group.leave()
        }

        return Capture(group: group, stdout: stdout, stderr: stderr)
    }
}
#endif
