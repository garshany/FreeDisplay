import Foundation

public enum ConsoleInput: Sendable, Equatable {
    case empty
    case help(String?)
    case clear
    case exit
    case command(AutomationRequest)
}

/// Lexical framing only. Command names, selectors, units and validation belong to the shared parser.
public enum ConsoleGrammar {
    public static func tokens(_ input: String) throws(AutomationIssue) -> [String] {
        var tokens: [String] = []
        var token = ""
        var quote: Character?
        var escaped = false
        var started = false
        for character in input {
            if escaped { token.append(character); escaped = false; started = true; continue }
            if character == "\\" { escaped = true; started = true; continue }
            if let current = quote {
                if character == current { quote = nil } else { token.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character; started = true
            } else if character.isWhitespace {
                if started { tokens.append(token); token = ""; started = false }
            } else {
                token.append(character); started = true
            }
        }
        guard quote == nil else { throw .invalidValue("input", "Unclosed quote.") }
        guard !escaped else { throw .invalidValue("input", "Trailing backslash.") }
        if started { tokens.append(token) }
        return tokens
    }

    public static func parse(_ input: String) throws(AutomationIssue) -> ConsoleInput {
        let words = try tokens(input)
        guard let verb = words.first else { return .empty }
        let arguments = Array(words.dropFirst())
        if verb == "help" || CLIGrammar.helpOptions.contains(verb) {
            guard arguments.count <= 1 else { throw .invalidValue("help", "Use help or help <command>.") }
            return .help(arguments.first)
        }
        if verb == "clear" || verb == "exit" {
            guard arguments.isEmpty else { throw .invalidValue(verb, "This console command takes no arguments.") }
            return verb == "clear" ? .clear : .exit
        }
        var parameters: [String: AutomationParameterValue] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0].drop(while: { $0 == "-" }))
            guard !key.isEmpty else { throw .invalidValue("input", "Expected a named parameter.") }
            let value: AutomationParameterValue
            if parts.count == 2 {
                value = .string(String(parts[1]))
            } else if AutomationCatalog.normalize(key) == "dryrun" {
                value = .bool(true)
            } else {
                guard argument.hasPrefix("-"), index < arguments.count else {
                    throw .invalidValue("input", "Use name=value or --name value parameters.")
                }
                value = .string(arguments[index]); index += 1
            }
            guard parameters[key] == nil else { throw AutomationIssue(.conflictingParameters, "Duplicate parameter.", subject: key) }
            parameters[key] = value
        }
        return .command(try AutomationRequestParser.parse(verb: verb, parameters: parameters))
    }
}

/// Session-only state. No capacity is invented here: nil means unbounded, zero retains nothing.
public struct ConsoleSession: Sendable {
    public private(set) var history: [String] = []
    public private(set) var output: [String] = []
    public var draft = ""
    public var historyCapacity: Int? { didSet { trim(&history, to: historyCapacity); cursor = nil } }
    public var outputCapacity: Int? { didSet { trim(&output, to: outputCapacity) } }
    private var cursor: Int?
    private var savedDraft = ""

    public init(historyCapacity: Int?, outputCapacity: Int?) {
        self.historyCapacity = historyCapacity
        self.outputCapacity = outputCapacity
    }

    public mutating func submit() -> String {
        let line = draft
        if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, history.last != line {
            history.append(line); trim(&history, to: historyCapacity)
        }
        draft = ""; savedDraft = ""; cursor = nil
        return line
    }

    public mutating func previous() {
        guard !history.isEmpty else { return }
        if cursor == nil { savedDraft = draft; cursor = history.count }
        cursor = max(0, cursor! - 1)
        draft = history[cursor!]
    }

    public mutating func next() {
        guard let cursor else { return }
        if cursor + 1 >= history.count {
            self.cursor = nil; draft = savedDraft
        } else {
            self.cursor = cursor + 1; draft = history[cursor + 1]
        }
    }

    public mutating func append(_ text: String) {
        output.append(text); trim(&output, to: outputCapacity)
    }

    public mutating func clear() { output.removeAll() }
}

private func trim<T>(_ values: inout [T], to capacity: Int?) {
    if let capacity { values.removeFirst(max(0, values.count - max(0, capacity))) }
}

public enum ConsoleCapacity {
    /// Empty explicitly means no configured bound. Invalid input is never silently reinterpreted.
    public static func parse(_ text: String) throws(AutomationIssue) -> Int? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return nil }
        guard let capacity = Int(value), capacity >= 0 else {
            throw .invalidValue("capacity", "Enter a nonnegative integer, or leave blank for no limit.")
        }
        return capacity
    }
}
