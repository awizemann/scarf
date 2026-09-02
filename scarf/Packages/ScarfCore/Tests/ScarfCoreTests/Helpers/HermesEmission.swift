import Foundation

/// Generates test fixtures with **Hermes's own serializer traits** — the bar
/// set by the convention note "Hermes-authored file fixtures must come from
/// Hermes's own serializer". Hand-written fixtures encode the shape we
/// imagine; these shell out to real python3 + PyYAML with the exact options
/// Hermes's `utils.atomic_yaml_write` / `atomic_json_write` use (verified at
/// Hermes tag v2026.8.31):
///
///   YAML: `yaml.safe_dump(obj, default_flow_style=False, sort_keys=False,
///          allow_unicode=True)` — default width 80 (the folding trait).
///   JSON: `json.dumps(obj, indent=2, ensure_ascii=False)`.
///
/// The object under test is passed as JSON on stdin so no shell quoting can
/// distort it. Returns `nil` when python3/PyYAML is unavailable on the test
/// host — callers should SKIP (not vacuously pass) in that case. A
/// serializer error never masquerades as "python missing": it surfaces as a
/// visible `"ERROR: …"` string that will fail the assertion.
enum HermesEmission {

    /// `atomic_yaml_write`-equivalent emission of a JSON-described object.
    static func yamlDump(json: String) -> String? {
        run(script: """
        import sys, json
        try:
            import yaml
        except Exception:
            sys.stdout.write("__NO_PYYAML__")
            sys.exit(0)
        obj = json.loads(sys.stdin.buffer.read().decode("utf-8"))
        try:
            sys.stdout.write(yaml.safe_dump(
                obj, default_flow_style=False, sort_keys=False, allow_unicode=True))
        except Exception as exc:
            sys.stdout.write("ERROR: %s" % exc)
        """, stdin: json)
    }

    /// `atomic_json_write`-equivalent emission of a JSON-described object.
    static func jsonDump(json: String) -> String? {
        run(script: """
        import sys, json
        obj = json.loads(sys.stdin.buffer.read().decode("utf-8"))
        try:
            sys.stdout.write(json.dumps(obj, indent=2, ensure_ascii=False))
        except Exception as exc:
            sys.stdout.write("ERROR: %s" % exc)
        """, stdin: json)
    }

    /// Load YAML with real PyYAML and return `json.dumps(..., sort_keys=True)`
    /// of the result — "what Hermes would read back", for round-trip checks
    /// on YAML Scarf has written.
    static func pyYAMLLoad(_ yaml: String) -> String? {
        run(script: """
        import sys, json
        try:
            import yaml
        except Exception:
            sys.stdout.write("__NO_PYYAML__")
            sys.exit(0)
        raw = sys.stdin.buffer.read().decode("utf-8")
        try:
            sys.stdout.write(json.dumps(yaml.safe_load(raw), sort_keys=True))
        except Exception as exc:
            sys.stdout.write("ERROR: %s" % exc)
        """, stdin: yaml)
    }

    private static func run(script: String, stdin input: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let out = String(decoding: data, as: UTF8.self)
        return out == "__NO_PYYAML__" ? nil : out
    }
}
