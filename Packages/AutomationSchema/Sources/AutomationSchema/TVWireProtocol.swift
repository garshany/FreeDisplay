import Foundation

/// Clean-room messages using the public-network SSAP and Tizen remote protocols.
/// No vendor certificate/signature asset or service-menu sequence is embedded.
public enum TVWireProtocol {
    public enum Event: Equatable, Sendable {
        case prompt, pin, authorized(String?), authorizationDenied, manifestRejected
        case reply(id: String, success: Bool, muted: Bool?, inputs: [TVInput]?)
        case ignored
    }

    public static func lgRegister(clientKey: String?, requirePIN: Bool, id: String) throws -> String {
        var payload: [String: Any] = [
            "pairingType": requirePIN ? "PIN" : "PROMPT", "forcePairing": false,
            "manifest": ["manifestVersion": 1, "appVersion": "1.0",
                         "permissions": ["CONTROL_AUDIO", "CONTROL_POWER", "READ_CURRENT_CHANNEL",
                                         "READ_INPUT_DEVICE_LIST", "CONTROL_INPUT_TV", "READ_VOLUME"]]
        ]
        if let clientKey { payload["client-key"] = clientKey }
        return try json(["id": id, "type": "register", "payload": payload])
    }

    public static func lgPIN(_ pin: String, id: String) throws -> String {
        guard !pin.isEmpty, pin.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw AutomationIssue.invalidValue("PIN", "expected TV-provided digits")
        }
        return try lgRequest("ssap://pairing/setPin", payload: ["pin": pin], id: id)
    }

    public static func lgMessage(_ action: TVAction, id: String, muted: Bool? = nil) throws -> String {
        let uri: String
        var payload: [String: Any] = [:]
        switch action {
        case .volumeUp: uri = "ssap://audio/volumeUp"
        case .volumeDown: uri = "ssap://audio/volumeDown"
        case .muteToggle:
            guard let muted else { throw AutomationIssue(.notConfirmed, "the current mute state is unknown") }
            uri = "ssap://audio/setMute"; payload["mute"] = !muted
        case .powerOff: uri = "ssap://system/turnOff"
        case .refreshInputs: uri = "ssap://tv/getExternalInputList"
        case .switchInput(let input): uri = "ssap://tv/switchInput"; payload["inputId"] = input
        default: throw AutomationIssue(.capabilityUnavailable, "this is not an LG SSAP action")
        }
        return try lgRequest(uri, payload: payload, id: id)
    }

    public static func lgVolume(id: String) throws -> String {
        try lgRequest("ssap://audio/getVolume", payload: [:], id: id)
    }

    private static func lgRequest(_ uri: String, payload: [String: Any], id: String) throws -> String {
        try json(["id": id, "type": "request", "uri": uri, "payload": payload])
    }

    public static func samsungMessage(_ action: TVAction) throws -> String {
        let key: String
        switch action {
        case .volumeUp: key = "KEY_VOLUP"
        case .volumeDown: key = "KEY_VOLDOWN"
        case .muteToggle: key = "KEY_MUTE"
        case .powerOff: key = "KEY_POWEROFF"
        case .source: key = "KEY_SOURCE"
        case .hdmi: key = "KEY_HDMI"
        default: throw AutomationIssue(.capabilityUnavailable, "Samsung has no direct named-input or absolute-volume command here")
        }
        return try json(["method": "ms.remote.control", "params": [
            "Cmd": "Click", "DataOfCmd": key, "Option": "false", "TypeOfRemote": "SendRemoteKey"]])
    }

    public static func parse(_ text: String, family: TVFamily, registrationID: String) throws -> Event {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AutomationIssue(.executionFailed, "malformed TV protocol message")
        }
        if family == .samsungTizen {
            switch object["event"] as? String {
            case "ms.channel.connect":
                let token = (object["data"] as? [String: Any])?["token"] as? String
                return .authorized(token?.isEmpty == false ? token : nil)
            case "ms.channel.unauthorized": return .authorizationDenied
            default: return .ignored
            }
        }
        let type = object["type"] as? String
        let id = object["id"] as? String ?? ""
        let payload = object["payload"] as? [String: Any] ?? [:]
        if type == "registered", id == registrationID {
            guard let key = payload["client-key"] as? String, !key.isEmpty else {
                throw AutomationIssue(.executionFailed, "LG registration omitted its client key")
            }
            return .authorized(key)
        }
        if id == registrationID {
            if type == "error" {
                let error = (object["error"] as? String ?? "").lowercased()
                return error.contains("manifest") ? .manifestRejected : .authorizationDenied
            }
            if payload["pairingType"] as? String == "PIN" { return .pin }
            if payload["pairingType"] as? String == "PROMPT" { return .prompt }
        }
        guard !id.isEmpty, type == "response" || type == "error" else { return .ignored }
        let success = type != "error" && (payload["returnValue"] as? Bool == true)
        let volume = payload["volumeStatus"] as? [String: Any] ?? payload
        var inputs: [TVInput]?
        if let devices = payload["devices"] as? [[String: Any]] {
            var seen: Set<String> = []
            inputs = try devices.map { item in
                guard let id = item["id"] as? String, !id.isEmpty, seen.insert(id).inserted else {
                    throw AutomationIssue(.executionFailed, "invalid or duplicate LG input identity")
                }
                return TVInput(id: id, label: item["label"] as? String ?? id, connected: item["connected"] as? Bool)
            }
        }
        return .reply(id: id, success: success, muted: volume["muted"] as? Bool, inputs: inputs)
    }

    private static func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}
