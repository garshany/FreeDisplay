import DisplayDomain
import Foundation

/// One parameter value as a key/value surface delivers it: a URL query item (always a string), a
/// JSON body field (string, number or boolean), a console word.
public enum AutomationParameterValue: Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)

    var text: String? {
        switch self {
        case .string(let value): return value
        case .number, .bool: return nil
        }
    }
}

/// Turns a verb plus named parameters into a typed `AutomationRequest` (FD-066) — the one parser the
/// URL scheme, the HTTP command route and the console share, so a value or selector is accepted or
/// refused identically wherever it arrives. The CLI keeps its positional grammar (`CLIGrammar`) but
/// feeds its values through the same `AutomationValueParser` and `AutomationSelector`.
///
/// Rules:
/// - verbs and parameter names are matched case-insensitively, ignoring `-` and `_`;
/// - a parameter the command doesn't take is an error, never ignored;
/// - `display` takes the selector grammar, `displayId` exactly one record id (the legacy HTTP field)
///   — giving both is a conflict;
/// - `brightness` is a get without `value`/`offset`, a set with `value`, an adjust with `offset`
///   (both is a conflict); `mode` is a get without `mode` and a set with it; `profile` likewise;
/// - `value` is an absolute level (`0…1` number, `"0.4"`, `"40%"`); `offset` a signed change.
public enum AutomationRequestParser {
    /// Parameter names every command may carry in addition to its own.
    private static let common: Set<String> = ["dryrun"]

    public static func parse(verb: String, parameters raw: [String: AutomationParameterValue]) throws(AutomationIssue) -> AutomationRequest {
        var parameters: [String: AutomationParameterValue] = [:]
        for (key, value) in raw {
            let normalized = AutomationCatalog.normalize(key)
            guard parameters[normalized] == nil else {
                throw AutomationIssue(.conflictingParameters, "'\(key)' is given more than once", subject: key)
            }
            parameters[normalized] = value
        }
        let name = try commandName(verb: verb, parameters: parameters)
        let descriptor = AutomationCatalog.descriptor(for: name)

        let accepted = Set(descriptor.parameters.map { AutomationCatalog.normalize($0.name) })
            .union(common)
            .union(descriptor.target == .none ? [] : ["displayid"])
        if let unknown = parameters.keys.sorted().first(where: { !accepted.contains($0) }) {
            throw AutomationIssue(.unknownParameter, "'\(name.rawValue)' doesn't take '\(unknown)'", subject: unknown)
        }

        var request = AutomationRequest(try command(name, parameters: parameters))
        request.dryRun = try bool(parameters["dryrun"], parameter: "dryRun") ?? false
        if descriptor.target != .none {
            let (selector, text) = try target(parameters, command: name)
            request.target = selector
            request.targetText = text
        }
        return request
    }

    // MARK: Verb

    private static func commandName(verb: String, parameters: [String: AutomationParameterValue]) throws(AutomationIssue) -> AutomationCommandName {
        let key = AutomationCatalog.normalize(verb)
        guard !key.isEmpty else { throw AutomationIssue(.unknownCommand, "no command given") }
        if let exact = AutomationCommandName.allCases.first(where: { $0.rawValue.lowercased() == key }) { return exact }
        // Aliases that choose between a read and a write by what they were given.
        switch key {
        case "brightness":
            switch (parameters["value"], parameters["offset"]) {
            case (.some, .some):
                throw AutomationIssue(.conflictingParameters, "give either 'value' or 'offset', not both", subject: "offset")
            case (.some, nil): return .setBrightness
            case (nil, .some): return .adjustBrightness
            case (nil, nil): return .getBrightness
            }
        case "contrast":
            return parameters["value"] == nil ? .getContrast : .setContrast
        case "mode":
            return parameters["mode"] != nil ? .setMode : .getMode
        case "profile", "colorprofile":
            return parameters["profile"] != nil ? .setColorProfile : .getColorProfile
        default:
            break
        }
        if let descriptor = AutomationCatalog.descriptors.first(where: { $0.aliases.contains(key) }) { return descriptor.name }
        throw AutomationIssue(.unknownCommand, "unknown command '\(verb)'", subject: verb)
    }

    // MARK: Arguments

    private static func command(_ name: AutomationCommandName,
                                parameters: [String: AutomationParameterValue]) throws(AutomationIssue) -> AutomationCommand {
        switch name {
        case .listDisplays: return .listDisplays
        case .getCapabilities: return .getCapabilities
        case .getBrightness: return .getBrightness(method: try method(parameters))
        case .setBrightness:
            guard let value = parameters["value"] else { throw .missing("value", for: name.rawValue) }
            return .setBrightness(try level(value), method: try method(parameters))
        case .adjustBrightness:
            guard let offset = parameters["offset"] else { throw .missing("offset", for: name.rawValue) }
            return .adjustBrightness(try delta(offset), method: try method(parameters))
        case .getContrast: return .getContrast
        case .setContrast:
            guard let value = parameters["value"] else { throw .missing("value", for: name.rawValue) }
            return .setContrast(try level(value))
        case .listModes: return .listModes
        case .getMode: return .getMode
        case .setMode:
            guard let text = try string(parameters["mode"], parameter: "mode") else {
                throw .missing("mode", for: name.rawValue)
            }
            return .setMode(try AutomationModeSpec.parse(text))
        case .setMain: return .setMain
        case .listColorProfiles: return .listColorProfiles
        case .getColorProfile: return .getColorProfile
        case .setColorProfile:
            guard let text = try string(parameters["profile"], parameter: "profile") else {
                throw .missing("profile", for: name.rawValue)
            }
            return .setColorProfile(try AutomationProfileSpec.parse(text))
        case .resetColorProfile: return .resetColorProfile
        case .reconnectAll: return .reconnectAll
        case .disconnect: return .disconnect
        case .feedIntegration:
            guard let text = try string(parameters["control"], parameter: "control"), let control = UUID(uuidString: text) else {
                throw .invalidValue("control", "a configured control UUID is required")
            }
            // Parser responses preserve newlines. They are data, unlike command/selector tokens.
            guard case .string(let response) = parameters["response"] else {
                throw .missing("response", for: name.rawValue)
            }
            return .feedIntegration(control: control, response: response)
        }
    }

    private static func target(_ parameters: [String: AutomationParameterValue],
                               command: AutomationCommandName) throws(AutomationIssue) -> (AutomationSelector, String) {
        let display = try string(parameters["display"], parameter: "display")
        let displayID = try string(parameters["displayid"], parameter: "displayId")
        switch (display, displayID) {
        case (.some, .some):
            throw AutomationIssue(.conflictingParameters, "give either 'display' or 'displayId', not both", subject: "displayId")
        case (.some(let text), nil):
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { throw .missing("display", for: command.rawValue) }
            return (try AutomationSelector.parse(text), text)
        case (nil, .some(let id)):
            guard !id.isEmpty else { throw .missing("displayId", for: command.rawValue) }
            return (.display(.id(DisplayRecordID(rawValue: id))), "id:\(id)")
        case (nil, nil):
            throw .missing("display", for: command.rawValue)
        }
    }

    private static func method(_ parameters: [String: AutomationParameterValue]) throws(AutomationIssue) -> BrightnessMethodRequest {
        guard let text = try string(parameters["method"], parameter: "method") else { return .automatic }
        return try BrightnessMethodRequest.parse(text)
    }

    static func level(_ value: AutomationParameterValue) throws(AutomationIssue) -> AutomationLevel {
        switch value {
        case .number(let number): return try AutomationValueParser.level(number: number)
        case .string(let text): return try AutomationValueParser.level(text)
        case .bool: throw .invalidValue("value", "a level is a number (0…1) or a percentage, not true/false")
        }
    }

    static func delta(_ value: AutomationParameterValue) throws(AutomationIssue) -> AutomationLevelDelta {
        switch value {
        case .number(let number): return try AutomationValueParser.delta(number: number)
        case .string(let text): return try AutomationValueParser.delta(text)
        case .bool: throw .invalidValue("offset", "an offset is a signed number or percentage, not true/false")
        }
    }

    private static func string(_ value: AutomationParameterValue?, parameter: String) throws(AutomationIssue) -> String? {
        guard let value else { return nil }
        guard let text = value.text else { throw .invalidValue(parameter, "expected text") }
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw .invalidValue(parameter, "contains control characters")
        }
        return text
    }

    private static func bool(_ value: AutomationParameterValue?, parameter: String) throws(AutomationIssue) -> Bool? {
        switch value {
        case nil: return nil
        case .bool(let flag)?: return flag
        case .string(let text)?:
            switch text.lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: throw .invalidValue(parameter, "'\(text)' is not true or false")
            }
        case .number?: throw .invalidValue(parameter, "expected true or false")
        }
    }
}
