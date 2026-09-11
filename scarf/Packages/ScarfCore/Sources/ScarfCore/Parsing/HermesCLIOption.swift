import Foundation

/// The one spelling Scarf uses for an option that carries **user text**.
///
/// `--` does not help here. It ends the options and everything after it is a
/// POSITIONAL, so it protects a dash-leading title or prompt and nothing
/// else: `parse_args(["--name", "-nightly"])` is still
/// `error: argument --name: expected one argument`, exit 2, because argparse
/// reads `-nightly` as another option string before `--name` ever gets its
/// value. Scarf's cron and kanban editors are free-text fields — "-nightly",
/// "--dry-run is ignored", "-30% week" are all things a person types — and
/// every one of them aborted the whole verb.
///
/// The single-token form `--name=-nightly` is argparse's own answer:
/// `_parse_optional` splits on the FIRST `=` and hands the remainder over as
/// the value without ever testing it for option-ness
/// (`argparse.ArgumentParser._parse_optional`, `if '=' in arg_string:
/// option_string, explicit_arg = arg_string.split('=', 1)`), so any value at
/// all round-trips — including the empty string, which several `cron edit`
/// flags use as their documented "clear this field" gesture
/// (`hermes_cli/subcommands/cron.py:100-102`, `:117-127` @ `v2026.9.7`).
///
/// **It is only valid for a plain single-value option.** Every option this is
/// used on was walked at `v2026.9.7` and is a bare `add_argument(...)` with
/// no `nargs`: the cron builders (`hermes_cli/subcommands/cron.py:25-31`,
/// `:51-62`, `:66-88`, `:91-128`) and the kanban ones
/// (`hermes_cli/kanban_parser.py:59`, `:81`, `:263-316`, and the create specs)
/// take `store` or `append` options, and `append` splits identically per
/// occurrence. It would NOT be valid for an `nargs="+"` option such as
/// kanban's `--ids` (`kanban_parser.py:64`), where the `=` form can carry only
/// the first element — those stay two tokens, and positionals stay behind `--`.
public enum HermesCLIOption {

    /// `["--name", value]` → `"--name=value"`.
    ///
    /// `flag` must be the long spelling including the leading dashes; a short
    /// flag (`-p value`) has no `=` form in argparse and is not accepted here.
    public static func joined(_ flag: String, _ value: String) -> String {
        precondition(flag.hasPrefix("--"), "the =value form is long-option only: \(flag)")
        return flag + "=" + value
    }

    /// `joined` as a one-element argv fragment, for the `args += …` call sites
    /// that read better as a list.
    public static func argv(_ flag: String, _ value: String) -> [String] {
        [joined(flag, value)]
    }

    /// Split a token produced by `joined` back into `(flag, value)`, or `nil`
    /// for a token that is not an `=`-bearing long option. Exists so tests —
    /// and any future argv inspector — can assert what an option carries
    /// without re-deriving the split rule that argparse uses.
    public static func split(_ token: String) -> (flag: String, value: String)? {
        guard token.hasPrefix("--"), let eq = token.firstIndex(of: "=") else { return nil }
        return (String(token[token.startIndex..<eq]), String(token[token.index(after: eq)...]))
    }
}

// MARK: - Reading an argv back

extension HermesCLIOption {

    /// Whether `argv` carries `flag` at all, in either spelling — the
    /// single-token `--flag=value`, a bare switch (`--json`), or the
    /// two-token `--flag value` an `nargs`-bearing option still uses.
    ///
    /// Deliberately tolerant of both: this answers "is the option present",
    /// which is a question about the command line, not about which spelling
    /// this phase happens to emit. A test that means to pin the SPELLING
    /// must assert the literal token instead.
    public static func contains(_ flag: String, in argv: [String]) -> Bool {
        index(of: flag, in: argv) != nil
    }

    /// The position of `flag` in `argv`, in either spelling.
    public static func index(of flag: String, in argv: [String]) -> Int? {
        argv.firstIndex { $0 == flag || $0.hasPrefix(flag + "=") }
    }

    /// The value `flag` carries, in either spelling — the text after the
    /// first `=` for the single-token form, the next element otherwise.
    /// `nil` when the flag is absent (or is a trailing two-token flag with
    /// nothing after it, which is the argparse exit-2 shape).
    public static func value(of flag: String, in argv: [String]) -> String? {
        guard let i = index(of: flag, in: argv) else { return nil }
        if let split = split(argv[i]), split.flag == flag { return split.value }
        let next = argv.index(after: i)
        return next < argv.endIndex ? argv[next] : nil
    }

    /// Every value `flag` carries, for the repeatable (`action="append"`)
    /// options — `--skill`, `--parent`, `--add-skill`.
    public static func values(of flag: String, in argv: [String]) -> [String] {
        var out: [String] = []
        var i = argv.startIndex
        while i < argv.endIndex {
            if let split = split(argv[i]), split.flag == flag {
                out.append(split.value)
            } else if argv[i] == flag, argv.index(after: i) < argv.endIndex {
                out.append(argv[argv.index(after: i)])
                i = argv.index(after: i)
            }
            i = argv.index(after: i)
        }
        return out
    }
}
