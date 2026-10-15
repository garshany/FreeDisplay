import Foundation

/// The `opendisplay` command line, parsed: a verb, its positional arguments, and the options it was
/// given. Pure so the dispatch rules are unit-tested rather than discovered by running the CLI.
///
/// The grammar is deliberately strict. Before this existed, every `--token` was collected into a
/// set and everything else was positional, so `opendisplay --help` and `opendisplay --bogus` both
/// fell through to the default `list`, and `brightness … --dry-run` performed a real write: the
/// verb never read the flag. An option a verb doesn't honour is now an error, never a silent no-op.
public struct CLIInvocation: Hashable, Sendable {
    /// The verb (`list` when no arguments were given at all).
    public var command: String
    /// Arguments after the verb, in order, with options and their values removed.
    public var positional: [String]
    /// Valueless options that were given (`--json`, `--dry-run`, `--bundle`).
    public var flags: Set<String>
    /// Options that take a value (`--out <path>`), keyed by option name.
    public var values: [String: String]

    public init(command: String, positional: [String] = [], flags: Set<String> = [],
                values: [String: String] = [:]) {
        self.command = command
        self.positional = positional
        self.flags = flags
        self.values = values
    }

    /// The first positional argument after the verb (usually a selector or subcommand).
    public var argument1: String? { positional.first }
    /// The second positional argument after the verb.
    public var argument2: String? { positional.count > 1 ? positional[1] : nil }
}

/// What the parser decided to do with a command line.
public enum CLIParseResult: Hashable, Sendable {
    /// Print the help text and exit successfully, touching nothing.
    case help
    /// Run this verb.
    case run(CLIInvocation)
}

/// A command line the parser refuses. Each is a usage error (exit code 2), reported before any
/// provider is touched.
public enum CLIArgumentError: Error, Hashable, Sendable, CustomStringConvertible {
    /// An option no verb understands.
    case unknownOption(String)
    /// An option that needs a value (`--out`) was last on the line.
    case missingValue(String)
    /// A real option, but not one this verb honours.
    case unsupportedOption(option: String, command: String)

    public var description: String {
        switch self {
        case .unknownOption(let option):
            return "unknown option '\(option)' (see: opendisplay --help)"
        case .missingValue(let option):
            return "option '\(option)' needs a value"
        case .unsupportedOption(let option, let command):
            return "'\(command)' does not accept '\(option)' (see: opendisplay --help)"
        }
    }
}

public enum CLIGrammar {
    /// Tokens that ask for help wherever they appear. `help` counts only as the verb, so a display
    /// aliased "help" can still be named as a selector.
    public static let helpOptions: Set<String> = ["--help", "-h"]
    /// Options that never take a value.
    public static let valuelessOptions: Set<String> = ["--json", "--dry-run", "--bundle"]
    /// Options followed by exactly one value. The value is taken as given even when it starts with
    /// `-`, so `--offset -5%` works while a bare `-5%` stays an unknown option: a minus sign alone
    /// never turns an absolute level into a relative change.
    public static let valuedOptions: Set<String> = ["--out", "--method", "--offset", "--timeout"]

    /// Which options each verb honours. A verb missing from this table accepts none; an unknown
    /// verb is left for the dispatcher to reject, so its message can list the real verbs.
    public static let supportedOptions: [String: Set<String>] = [
        "list": ["--json"],
        "diagnose": ["--json", "--bundle"],
        "lux": ["--json"],
        "lid": ["--json"],
        "disconnect": ["--json", "--dry-run"],
        "reconnect": ["--json"],
        "recover": ["--json"],
        "scene": ["--json"],
        "layout": ["--json"],
        "group": ["--json"],
        "brightness": ["--json", "--method", "--offset"],
        "mode": ["--json"],
        "commands": ["--json"],
        "capabilities": ["--json"],
        "contrast": ["--json"],
        "main": ["--json"],
        "profile": ["--json"],
        "profiles": ["--json"],
        "command": ["--json", "--dry-run"],
        "ready": ["--json"],
        "ddc": ["--json"],
        "edid": ["--out"],
    ]

    /// Every verb the dispatcher implements, so an option check can tell "verb takes no options"
    /// from "not a verb at all".
    public static let commands: Set<String> = [
        "list", "diagnose", "lux", "lid", "listen", "alias", "tag", "recover", "disconnect",
        "reconnect", "scene", "layout", "group", "brightness", "ddc", "edid", "favorite",
        "favourite", "mode", "commands", "capabilities", "_rotate-exp", "help",
        "contrast", "main", "profile", "profiles", "command", "ready",
    ]

    public static func parse(_ arguments: [String]) throws -> CLIParseResult {
        if arguments.contains(where: helpOptions.contains) { return .help }
        var positional: [String] = []
        var flags: Set<String> = []
        var values: [String: String] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let token = arguments[index]
            index += 1
            guard token.hasPrefix("-"), token.count > 1 else {
                positional.append(token)
                continue
            }
            if valuelessOptions.contains(token) {
                flags.insert(token)
            } else if valuedOptions.contains(token) {
                guard index < arguments.endIndex else { throw CLIArgumentError.missingValue(token) }
                values[token] = arguments[index]
                index += 1
            } else {
                throw CLIArgumentError.unknownOption(token)
            }
        }
        // No arguments at all keeps the long-standing default of listing displays. Options alone
        // (`opendisplay --json`) still name no verb, so they list too — but only options `list`
        // honours, checked below like any other verb.
        let command = positional.isEmpty ? "list" : positional.removeFirst()
        if command == "help" { return .help }
        if commands.contains(command) {
            let allowed = (supportedOptions[command] ?? []).union(CLIAppRequest.commands.contains(command) ? ["--timeout"] : [])
            let given = flags.union(values.keys)
            if let rejected = given.sorted().first(where: { !allowed.contains($0) }) {
                throw CLIArgumentError.unsupportedOption(option: rejected, command: command)
            }
        }
        return .run(CLIInvocation(command: command, positional: positional, flags: flags, values: values))
    }
}

/// The CLI's documented exit statuses. Scripts branch on these, so they are part of the contract.
public enum CLIExitCode: Int32, Sendable {
    /// Everything requested happened (or was already so). A write the provider accepted but no
    /// read-back confirmed still counts — the output says `sent` rather than `verified`.
    case success = 0
    /// The command failed: nothing it was asked to change was changed, or a read was impossible.
    case failure = 1
    /// The command line itself was wrong (unknown verb/option, bad arguments). Nothing ran.
    case usage = 2
    /// Some of the request happened and some did not (a scene with skipped or unapplied fields,
    /// a group where one member's write failed). The output lists which.
    case partial = 3

    /// The exit status a result envelope implies.
    public init(_ status: ResultEnvelope.Status) {
        switch status {
        case .committed, .noOp: self = .success
        case .partial: self = .partial
        case .failed, .rolledBack: self = .failure
        }
    }
}
