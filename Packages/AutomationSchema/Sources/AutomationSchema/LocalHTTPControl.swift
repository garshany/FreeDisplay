// Original OpenDisplay work, GPL-3.0-or-later.
import Foundation
import CoreFoundation

/// Deliberately small HTTP subset: authenticated readback, bounded brightness and recovery commands.
/// No URL-driven mutations, CORS, cookies, chunking, pipelining or arbitrary command strings.
public enum LocalHTTPControl {
    public static let maximumRequestBytes = 8192
    public enum ParseResult: Equatable, Sendable {
        case incomplete
        case rejected(Int)
        case reconnectAll
        case displays
        case brightness(displayId: String, value: Double)
    }

    public static func parse(_ data: Data, token: String) -> ParseResult {
        guard data.count <= maximumRequestBytes else { return .rejected(413) }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[..<separator.lowerBound], encoding: .utf8) else {
            return .rejected(400)
        }
        let lines = head.components(separatedBy: "\r\n")
        let route = lines.first ?? ""
        guard ["POST /v1/reconnect-all HTTP/1.1", "POST /v1/brightness HTTP/1.1", "GET /v1/displays HTTP/1.1"].contains(route) else { return .rejected(404) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return .rejected(400) }
            let name = String(line[..<colon]).lowercased()
            guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                  headers[name] == nil else { return .rejected(400) }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil, headers["origin"] == nil,
              (route == "GET /v1/displays HTTP/1.1" || headers["content-type"] == "application/json"), headers["host"] != nil,
              let lengthText = headers["content-length"],
              !lengthText.isEmpty, lengthText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let length = Int(lengthText), length <= 256 else { return .rejected(400) }
        guard !token.isEmpty, constantTimeEqual(headers["authorization"] ?? "", "Bearer " + token) else {
            return .rejected(401)
        }
        let body = data[separator.upperBound...]
        guard body.count >= length else { return .incomplete }
        guard body.count == length else { return .rejected(400) }
        if route == "GET /v1/displays HTTP/1.1" {
            return length == 0 ? .displays : .rejected(400)
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(body)),
              let dictionary = object as? [String: Any] else { return .rejected(400) }
        if route == "POST /v1/reconnect-all HTTP/1.1" {
            return dictionary.isEmpty ? .reconnectAll : .rejected(400)
        }
        guard Set(dictionary.keys) == ["displayId", "value"],
              let id = dictionary["displayId"] as? String, !id.isEmpty, id.utf8.count <= 128,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-:.".contains($0)) }),
              let value = dictionary["value"] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
              (0...1).contains(value.doubleValue) else { return .rejected(400) }
        return .brightness(displayId: id, value: value.doubleValue)
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    public static func response(status: Int, body: Data = Data("{}".utf8)) -> Data {
        let phrase = status == 200 ? "OK" : "Rejected"
        var data = Data("HTTP/1.1 \(status) \(phrase)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
        data.append(body)
        return data
    }
}
