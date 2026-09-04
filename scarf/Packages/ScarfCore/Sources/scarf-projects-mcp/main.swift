import Foundation
import ScarfCore
import ScarfProjectsMCPKit

// `scarf-projects` — the MCP server Scarf bundles and registers into the
// local Hermes config, so agents get validated project CRUD instead of
// hand-appending rows to ~/.hermes/scarf/projects.json.
//
// Usage: read from stdin, write to stdout. There are no subcommands.
//   --hermes-home <path>   Hermes home to operate on (tests, multi-home).
//   SCARF_PROJECTS_MCP_HOME  Same, as an environment variable.
//   --version              Print the version and exit.

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--version") {
    print("\(ProjectMCPServer.serverName) \(ProjectMCPServer.serverVersion) "
        + "(MCP \(ProjectMCPServer.protocolVersion))")
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
        \(ProjectMCPServer.serverName) — MCP server for Scarf project CRUD (stdio).

        Speaks JSON-RPC 2.0 over newline-delimited JSON on stdin/stdout; it is
        launched by a Hermes agent, not by hand.

        Options:
          --hermes-home <path>   Hermes home to operate on. Must be absolute and
                                 already exist. Defaults to the resolved local
                                 home, which honours active_profile AS OF
                                 PROCESS START — Hermes respawns this server, so
                                 a profile switch mid-session is not picked up
                                 until it does.
          --version              Print version and exit.

        Environment:
          SCARF_PROJECTS_MCP_HOME  Same as --hermes-home; the flag wins.
        """)
    exit(0)
}

/// Home resolution, in precedence order: the flag, then the env var, then
/// the real local home.
///
/// The override exists so the smoke test can point the binary at a temp
/// directory WITHOUT reaching for the process-global `SCARF_HERMES_HOME`,
/// which is reserved for the app-hosted serial harnesses and races
/// anything parallel.
///
/// It is deliberately strict, because a home override decides where every
/// write in this process lands. The path must be ABSOLUTE and must
/// already EXIST as a directory: a relative path would resolve against
/// whatever directory Hermes happened to be launched from, and a
/// nonexistent one would be created silently by the first `saveRegistry`
/// — producing a phantom registry somewhere nobody looks, while the tool
/// cheerfully reports `"registered": true`. A bad override exits
/// non-zero instead, which the agent sees immediately as a server that
/// won't start.
func resolveHomeOverride() -> URL? {
    func validated(_ path: String, source: String) -> URL {
        guard path.hasPrefix("/") else {
            FileHandle.standardError.write(Data(
                "\(source) must be an absolute path (got \"\(path)\")\n".utf8
            ))
            exit(2)
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            FileHandle.standardError.write(Data(
                "\(source) must name an existing directory (got \"\(url.path)\")\n".utf8
            ))
            exit(2)
        }
        return url
    }

    if let index = arguments.firstIndex(of: "--hermes-home") {
        guard index + 1 < arguments.count else {
            FileHandle.standardError.write(Data("--hermes-home needs a path\n".utf8))
            exit(2)
        }
        return validated(arguments[index + 1], source: "--hermes-home")
    }
    if let value = ProcessInfo.processInfo.environment["SCARF_PROJECTS_MCP_HOME"],
       !value.isEmpty {
        return validated(value, source: "SCARF_PROJECTS_MCP_HOME")
    }
    return nil
}

let context = resolveHomeOverride().map { ServerContext.local(home: $0) } ?? .local
ProjectMCPStdioLoop.run(server: ProjectMCPServer(context: context))
