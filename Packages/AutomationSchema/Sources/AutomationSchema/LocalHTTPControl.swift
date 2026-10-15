// Original OpenDisplay work, GPL-3.0-or-later.
import Foundation
import CoreFoundation

/// Deliberately small HTTP subset: authenticated readback, bounded brightness and recovery commands,
/// and the typed command route of the shared automation model (FD-066). No URL-driven mutations,
/// CORS, cookies, chunking, pipelining or free-form command strings: every body is a flat JSON object
/// whose fields go through `AutomationRequestParser`, the same parser the URL scheme uses.
public enum LocalHTTPControl {
    public static let maximumRequestBytes = 8192
    public enum ParseResult: Equatable, Sendable {
        case incomplete
        /// Refused at the HTTP layer (framing, authentication, route) with this status.
        case rejected(Int)
        case reconnectAll
        case displays
        /// `POST /v1/brightness` in its original form, `{"displayId": …, "value": 0…1}`.
        case brightness(displayId: String, value: Double)
        /// A typed request: `POST /v1/brightness` with the newer fields, or `POST /v1/command`.
        case command(AutomationRequest, style: ResponseStyle)
        /// `GET /v1/commands`: the command catalog.
        case catalog
        /// Authenticated and well-framed, but the request itself is invalid; answer with the issue.
        case invalid(AutomationIssue)

        /// The HTTP status a refusal is answered with, or nil when the request goes on to the handler.
        public var rejectionStatus: Int? {
            switch self {
            case .rejected(let status): return status
            case .invalid(let issue): return AutomationHTTPStatus.code(for: issue)
            default: return nil
            }
        }
    }

    /// How a typed request's answer is shaped.
    public enum ResponseStyle: String, Equatable, Sendable {
        /// The original `/v1/brightness` body (`status`, `displayId`, `value`, …) plus the new fields.
        case legacyBrightness
        /// An `AutomationResult`.
        case result
    }

    private static let routes: Set<String> = [
        "POST /v1/reconnect-all HTTP/1.1", "POST /v1/brightness HTTP/1.1", "POST /v1/command HTTP/1.1",
        "GET /v1/displays HTTP/1.1", "GET /v1/commands HTTP/1.1",
    ]

    public static func parse(_ data: Data, token: String) -> ParseResult {
        guard data.count <= maximumRequestBytes else { return .rejected(413) }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[..<separator.lowerBound], encoding: .utf8) else {
            return .rejected(400)
        }
        let lines = head.components(separatedBy: "\r\n")
        let route = lines.first ?? ""
        guard routes.contains(route) else { return .rejected(404) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return .rejected(400) }
            let name = String(line[..<colon]).lowercased()
            guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                  headers[name] == nil else { return .rejected(400) }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let isGet = route.hasPrefix("GET ")
        // A body-less GET omits Content-Length in curl/browsers/URLSession (RFC 9110 §8.6), so it
        // means zero there; POST must still declare its length explicitly.
        guard headers["transfer-encoding"] == nil, headers["origin"] == nil,
              (isGet || headers["content-type"] == "application/json"), headers["host"] != nil,
              let lengthText = headers["content-length"] ?? (isGet ? "0" : nil),
              !lengthText.isEmpty, lengthText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let length = Int(lengthText), length <= 256 else { return .rejected(400) }
        guard !token.isEmpty, constantTimeEqual(headers["authorization"] ?? "", "Bearer " + token) else {
            return .rejected(401)
        }
        let body = data[separator.upperBound...]
        guard body.count >= length else { return .incomplete }
        guard body.count == length else { return .rejected(400) }
        if isGet {
            guard length == 0 else { return .rejected(400) }
            return route == "GET /v1/commands HTTP/1.1" ? .catalog : .displays
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(body)),
              let dictionary = object as? [String: Any] else { return .rejected(400) }
        switch route {
        case "POST /v1/reconnect-all HTTP/1.1":
            return dictionary.isEmpty ? .reconnectAll : .rejected(400)
        case "POST /v1/command HTTP/1.1":
            return command(dictionary)
        default:
            return brightness(dictionary)
        }
    }

    /// `POST /v1/brightness`. The original body stays exactly as it was; the newer fields (`display`
    /// with the selector grammar, `offset`, `method`, a `"40%"` string value) make it a typed request.
    private static func brightness(_ dictionary: [String: Any]) -> ParseResult {
        if let id = dictionary["displayId"] {
            // The original field keeps its original strictness: an id, not a selector.
            guard let id = id as? String, !id.isEmpty, id.utf8.count <= 128,
                  id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-:.".contains($0)) }) else {
                return .invalid(.invalidValue("displayId", "not a display id"))
            }
        }
        let parameters: [String: AutomationParameterValue]
        switch parameterValues(dictionary) {
        case .success(let values): parameters = values
        case .failure(let issue): return .invalid(issue)
        }
        guard dictionary["value"] != nil || dictionary["offset"] != nil else {
            return .invalid(.missing("value", for: "brightness"))
        }
        let request: AutomationRequest
        do {
            request = try AutomationRequestParser.parse(verb: "brightness", parameters: parameters)
        } catch {
            return .invalid(error)
        }
        if Set(dictionary.keys) == ["displayId", "value"], case .setBrightness(let level, .automatic) = request.command,
           case .number = parameters["value"], let id = dictionary["displayId"] as? String {
            return .brightness(displayId: id, value: level.normalized)
        }
        return .command(request, style: .legacyBrightness)
    }

    /// `POST /v1/command`: `{"command": "<name or alias>", …parameters}`.
    private static func command(_ dictionary: [String: Any]) -> ParseResult {
        guard let verb = dictionary["command"] as? String else {
            return .invalid(AutomationIssue(.missingParameter, "the body needs a 'command' string", subject: "command"))
        }
        var rest = dictionary
        rest.removeValue(forKey: "command")
        switch parameterValues(rest) {
        case .failure(let issue):
            return .invalid(issue)
        case .success(let parameters):
            do {
                return .command(try AutomationRequestParser.parse(verb: verb, parameters: parameters), style: .result)
            } catch {
                return .invalid(error)
            }
        }
    }

    /// A flat JSON object as typed parameter values: strings, finite numbers and booleans only.
    private static func parameterValues(_ dictionary: [String: Any]) -> Result<[String: AutomationParameterValue], AutomationIssue> {
        var values: [String: AutomationParameterValue] = [:]
        for (key, raw) in dictionary {
            if let number = raw as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    values[key] = .bool(number.boolValue)
                } else {
                    guard number.doubleValue.isFinite else { return .failure(.invalidValue(key, "not a finite number")) }
                    values[key] = .number(number.doubleValue)
                }
            } else if let text = raw as? String {
                values[key] = .string(text)
            } else {
                return .failure(.invalidValue(key, "expected a string, number or boolean"))
            }
        }
        return .success(values)
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    public static func response(status: Int, body: Data = Data("{}".utf8)) -> Data {
        let phrase = AutomationHTTPStatus.reasonPhrase(status)
        var data = Data("HTTP/1.1 \(status) \(phrase)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
        data.append(body)
        return data
    }
}
