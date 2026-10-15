import DisplayDomain
import Foundation

/// A display as automation can name it — one row of the shared candidate list every surface resolves
/// selectors against (FD-066). Surfaces build these from their own data (the app from its live
/// model, the CLI from its provider snapshot and the persisted stores); the matching rules live here
/// once, so `alias:Desk` or `tag:studio` means the same display on every surface.
public struct AutomationDisplayCandidate: Hashable, Sendable, Codable, Identifiable {
    public enum Availability: String, Hashable, Sendable, Codable {
        /// Connected and part of the desktop.
        case active
        /// Connected but not a desktop of its own (e.g. a mirror member).
        case inactive
        /// Not connected: turned off by FreeDisplay, unplugged, or only remembered.
        case disconnected
    }

    /// The observation record id — what every surface reports and what an explicit `id:` targets.
    public var id: DisplayRecordID
    /// The persisted registry record behind it, when it differs and is known. `id:` matches it too.
    public var registryID: DisplayRecordID?
    public var cgDisplayID: UInt32?
    /// The name the app shows (the alias when there is one).
    public var name: String
    public var alias: String?
    public var tags: Set<String>
    /// Names of the display groups that list this display.
    public var groups: Set<String>
    public var availability: Availability
    public var reachability: Reachability
    public var isMain: Bool
    public var isBuiltIn: Bool
    public var vendorID: Int?
    public var productID: Int?
    public var serial: String?
    /// Whether the pointer is on this display; nil when the surface can't tell.
    public var containsPointer: Bool?

    public init(id: DisplayRecordID, registryID: DisplayRecordID? = nil, cgDisplayID: UInt32? = nil,
                name: String, alias: String? = nil, tags: Set<String> = [], groups: Set<String> = [],
                availability: Availability, reachability: Reachability? = nil, isMain: Bool = false,
                isBuiltIn: Bool = false, vendorID: Int? = nil, productID: Int? = nil, serial: String? = nil,
                containsPointer: Bool? = nil) {
        self.id = id
        self.registryID = registryID
        self.cgDisplayID = cgDisplayID
        self.name = name
        self.alias = alias
        self.tags = tags
        self.groups = groups
        self.availability = availability
        self.reachability = reachability ?? {
            switch availability {
            case .active: return .active
            case .inactive: return .discoveredInactive
            case .disconnected: return .systemAbsent
            }
        }()
        self.isMain = isMain && availability == .active
        self.isBuiltIn = isBuiltIn
        self.vendorID = vendorID
        self.productID = productID
        self.serial = serial
        self.containsPointer = containsPointer
    }
}

/// Every display a surface can name right now, plus the group names that exist (so `group:x` can tell
/// "no such group" from "its members aren't here") and the topology generation the list came from.
public struct AutomationDisplaySet: Hashable, Sendable, Codable {
    public var candidates: [AutomationDisplayCandidate]
    public var knownGroups: [String]
    public var topologyGeneration: UInt64

    public init(candidates: [AutomationDisplayCandidate], knownGroups: [String] = [], topologyGeneration: UInt64 = 0) {
        self.candidates = candidates
        self.knownGroups = knownGroups
        self.topologyGeneration = topologyGeneration
    }
}

/// The selector grammar shared by the CLI, URL, HTTP and console (FD-066): everything
/// `DisplaySelector` parses (`id:` `alias:` `tag:` `name:` `vendor:… product:… serial:…` `main`
/// `builtin` `pointer` `focus` `state:` `leftOf:`…), plus forms that only make sense for automation
/// targets:
///
/// - bare text (no `scheme:`) — a display's exact name, like `name:`;
/// - a bare number or `cgid:<n>` — the transient Core Graphics display id;
/// - `group:<name>` — every member of a display group (case-insensitive name);
/// - `nameLike:<text>` — every display whose name or alias contains the text (case- and
///   diacritic-insensitive).
public enum AutomationSelector: Hashable, Sendable, Codable {
    case display(DisplaySelector)
    case cgDisplayID(UInt32)
    case group(String)
    case nameContains(String)

    public static func parse(_ raw: String) throws(AutomationIssue) -> AutomationSelector {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            throw AutomationIssue(.invalidSelector, "the display selector is empty", subject: raw)
        }
        if text.allSatisfy({ $0.isASCII && $0.isNumber }) {
            guard let id = UInt32(text) else {
                throw AutomationIssue(.invalidSelector, "'\(raw)' is not a display number", subject: raw)
            }
            return .cgDisplayID(id)
        }
        if let value = value(of: text, scheme: "cgid") {
            guard let id = UInt32(value) else {
                throw AutomationIssue(.invalidSelector, "'\(raw)' is not a display number", subject: raw)
            }
            return .cgDisplayID(id)
        }
        if let value = value(of: text, scheme: "group") {
            guard !value.isEmpty else {
                throw AutomationIssue(.invalidSelector, "'\(raw)' names no group", subject: raw)
            }
            return .group(value)
        }
        if let value = value(of: text, scheme: "namelike") {
            guard !value.isEmpty else {
                throw AutomationIssue(.invalidSelector, "'\(raw)' has no text to match", subject: raw)
            }
            return .nameContains(value)
        }
        // Bare text that isn't a role is a display's exact name (`Studio Display`), the form links and
        // people write. A text with an unknown `scheme:` stays an error rather than a guess.
        if !text.contains(":"), !roleWords.contains(text.lowercased()) {
            return .display(.name(unquote(text)))
        }
        let selector: DisplaySelector
        do {
            selector = try DisplaySelector.parse(text)
        } catch {
            throw AutomationIssue(.invalidSelector, "could not parse selector '\(raw)' (\(error))", subject: raw)
        }
        if case .id(let id) = selector, id.rawValue.isEmpty {
            throw AutomationIssue(.invalidSelector, "'\(raw)' names no display id", subject: raw)
        }
        return .display(selector)
    }

    /// Whether this selector names a set of displays by nature (a tag, a group, a state, a name
    /// pattern) rather than one display — such a selector is never narrowed to "the first" match.
    public var isSetSelector: Bool {
        switch self {
        case .display(let selector): return selector.isSetSelector
        case .group, .nameContains: return true
        case .cgDisplayID: return false
        }
    }

    /// The bare words `DisplaySelector` reads as roles.
    private static let roleWords: Set<String> = ["main", "builtin", "built-in", "pointer", "focus", "focused"]

    private static func unquote(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        return String(text.dropFirst().dropLast())
    }

    private static func value(of text: String, scheme: String) -> String? {
        guard let colon = text.firstIndex(of: ":"),
              text[..<colon].lowercased() == scheme else { return nil }
        return unquote(text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }
}

/// Resolves selectors against a candidate list with one set of rules (FD-066). No match, an unknown
/// group, a form this surface can't evaluate and — for commands that need one display — more than
/// one match are all errors naming the selector; nothing is ever narrowed to a guess or redirected
/// to the main or built-in display.
public enum AutomationSelectorResolver {
    /// Every candidate the selector matches (at least one).
    public static func resolve(_ selector: AutomationSelector, text: String? = nil,
                               in set: AutomationDisplaySet) throws(AutomationIssue) -> [AutomationDisplayCandidate] {
        let shown = text ?? describe(selector)
        let candidates = set.candidates
        let matches: [AutomationDisplayCandidate]
        switch selector {
        case .cgDisplayID(let id):
            matches = candidates.filter { $0.cgDisplayID == id }
        case .group(let name):
            guard set.knownGroups.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw AutomationIssue(.unknownGroup, "no display group named '\(name)'", subject: name)
            }
            matches = candidates.filter { candidate in
                candidate.groups.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            }
        case .nameContains(let needle):
            matches = candidates.filter { contains($0.name, needle) || ($0.alias.map { contains($0, needle) } ?? false) }
        case .display(let selector):
            matches = try resolve(selector, shown: shown, in: candidates)
        }
        guard !matches.isEmpty else {
            throw AutomationIssue(.displayNotFound, "no display matches '\(shown)'", subject: shown)
        }
        return matches
    }

    /// The single display a selector names; several matches are an ambiguity error listing them.
    public static func resolveOne(_ selector: AutomationSelector, text: String? = nil,
                                  in set: AutomationDisplaySet) throws(AutomationIssue) -> AutomationDisplayCandidate {
        let matches = try resolve(selector, text: text, in: set)
        guard matches.count == 1 else {
            let shown = text ?? describe(selector)
            let ids = matches.map(\.id.rawValue)
            throw AutomationIssue(.ambiguousSelector,
                                  "'\(shown)' is ambiguous (\(matches.count) displays): \(ids.joined(separator: ", "))",
                                  subject: shown, candidates: ids)
        }
        return matches[0]
    }

    /// The issue for a resolved display that isn't usable for a command needing `requirement`, or
    /// nil when it is.
    public static func availabilityIssue(_ candidate: AutomationDisplayCandidate,
                                         requirement: AutomationTargetRequirement) -> AutomationIssue? {
        switch (requirement, candidate.availability) {
        case (.none, _), (.anyDisplay, _), (.connectedDisplay, .active), (.connectedDisplay, .inactive),
             (.activeDisplay, .active):
            return nil
        case (.activeDisplay, .inactive):
            return AutomationIssue(.displayInactive,
                                   "\(candidate.name) is connected but isn't showing its own desktop (for example, it's mirroring another display)",
                                   subject: candidate.id.rawValue)
        case (.activeDisplay, .disconnected), (.connectedDisplay, .disconnected):
            return AutomationIssue(.displayNotConnected, "\(candidate.name) isn't connected",
                                   subject: candidate.id.rawValue)
        }
    }

    // MARK: DisplaySelector rules

    private static func resolve(_ selector: DisplaySelector, shown: String,
                                in candidates: [AutomationDisplayCandidate]) throws(AutomationIssue) -> [AutomationDisplayCandidate] {
        switch selector {
        case .id(let id):
            return candidates.filter { $0.id == id || $0.registryID == id }
        case .alias(let alias):
            return candidates.filter { $0.alias == alias }
        case .tag(let tag):
            return candidates.filter { $0.tags.contains(tag) }
        case .name(let name):
            return candidates.filter { equal($0.name, name) || ($0.alias.map { equal($0, name) } ?? false) }
        case .fingerprint(let vendor, let product, let serial):
            return candidates.filter { candidate in
                (vendor == nil || candidate.vendorID == vendor)
                    && (product == nil || candidate.productID == product)
                    && (serial == nil || candidate.serial == serial)
            }
        case .role(.main):
            return candidates.filter { $0.isMain && $0.availability == .active }
        case .role(.builtin):
            return candidates.filter(\.isBuiltIn)
        case .role(.pointer):
            guard candidates.contains(where: { $0.containsPointer != nil }) else {
                throw AutomationIssue(.unsupportedSelector,
                                      "'\(shown)' can't be resolved here: the pointer's display isn't known on this surface",
                                      subject: shown)
            }
            return candidates.filter { $0.containsPointer == true }
        case .role(.focus):
            throw AutomationIssue(.unsupportedSelector,
                                  "'\(shown)' isn't supported: finding the focused window's display needs window access FreeDisplay doesn't request",
                                  subject: shown)
        case .state(let reachability):
            return candidates.filter { $0.reachability == reachability }
        case .topology:
            throw AutomationIssue(.unsupportedSelector,
                                  "'\(shown)' isn't supported yet (use id:, alias:, tag:, name:, main, builtin or a display number)",
                                  subject: shown)
        }
    }

    private static func equal(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func describe(_ selector: AutomationSelector) -> String {
        switch selector {
        case .cgDisplayID(let id): return String(id)
        case .group(let name): return "group:\(name)"
        case .nameContains(let text): return "nameLike:\(text)"
        case .display(let selector): return String(describing: selector)
        }
    }
}
