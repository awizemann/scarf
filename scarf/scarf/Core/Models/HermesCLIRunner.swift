import Foundation
import ScarfCore

/// Injectable stand-in for `ServerContext.runHermes(_:timeout:)`.
///
/// `ServerContext` is a `Sendable` **struct** and `runHermes` is a concrete
/// extension method that shells out through `HermesFileService`, so there is
/// no subclass or protocol seam a test can substitute. A view model that has
/// to prove it does not block the main actor (charter C10) therefore takes
/// this closure instead: production passes the context's own `runHermes`,
/// tests pass a fake that sleeps or counts.
///
/// `@Sendable` and parameterised by timeout so every call site names its own
/// cap rather than inheriting the 60 s default silently.
typealias HermesCLIRunner = @Sendable (_ args: [String], _ timeout: TimeInterval)
    -> (output: String, exitCode: Int32)

extension ServerContext {
    /// The production `HermesCLIRunner` for this context.
    nonisolated var cliRunner: HermesCLIRunner {
        { [self] args, timeout in self.runHermes(args, timeout: timeout) }
    }
}
