// SPDX-License-Identifier: GPL-3.0-or-later
// Original clean-room implementation for OpenDisplay; no proprietary source used.
import Foundation
import DisplayDomain

public enum EDIDError: LocalizedError, Equatable, Sendable {
    case invalidLength, invalidHeader, extensionCountMismatch, checksum(block: Int), invalidManufacturer
    public var errorDescription: String? {
        switch self {
        case .invalidLength: "EDID size must be 128 to 32768 bytes and a multiple of 128."
        case .invalidHeader: "Invalid EDID header."
        case .extensionCountMismatch: "The EDID extension count does not match the file size."
        case .checksum(let block): "Invalid checksum in EDID block #\(block + 1)."
        case .invalidManufacturer: "Invalid EDID manufacturer code."
        }
    }
}

/// Strict EDID base-block identity extraction. Unsupported extensions are preserved byte-for-byte.
public struct EDIDDocument: Sendable, Equatable {
    public let data: Data
    public let manufacturer: String
    public let productID: UInt16
    public let serialNumber: UInt32
    public let displayName: String?
    public let extensionCount: Int

    public init(data: Data) throws {
        let bytes = Array(data)
        guard bytes.count >= 128, bytes.count % 128 == 0, bytes.count <= 32768 else {
            throw EDIDError.invalidLength
        }
        guard Array(bytes.prefix(8)) == [0, 255, 255, 255, 255, 255, 255, 0] else {
            throw EDIDError.invalidHeader
        }
        guard Int(bytes[126]) + 1 == bytes.count / 128 else { throw EDIDError.extensionCountMismatch }
        for block in 0..<(bytes.count / 128) {
            guard bytes[(block * 128)..<(block * 128 + 128)].reduce(0, { $0 + Int($1) }) % 256 == 0 else {
                throw EDIDError.checksum(block: block)
            }
        }
        let vendor = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        let letters = [Int((vendor >> 10) & 31), Int((vendor >> 5) & 31), Int(vendor & 31)]
        guard vendor & 0x8000 == 0, letters.allSatisfy({ (1...26).contains($0) }) else {
            throw EDIDError.invalidManufacturer
        }
        guard let base = EDID.parse(bytes) else { throw EDIDError.invalidHeader }
        self.data = data
        manufacturer = base.manufacturerID
        productID = UInt16(base.productCode)
        serialNumber = base.serialNumber
        extensionCount = base.extensionCount
        displayName = base.monitorName

    }

    /// Export only: installing overrides requires a separately reviewed privileged workflow.
    public func overridePropertyList() throws -> Data {
        let vendor = UInt16(data[data.startIndex + 8]) << 8 | UInt16(data[data.startIndex + 9])
        var plist: [String: Any] = ["DisplayVendorID": Int(vendor), "DisplayProductID": Int(productID), "IODisplayEDID": data]
        if let displayName, !displayName.isEmpty { plist["DisplayProductName"] = displayName }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}

public enum HiDPIPlanError: LocalizedError, Equatable {
    case invalidDimensions, exceedsLimit
    public var errorDescription: String? {
        switch self {
        case .invalidDimensions: "Width and height must be positive."
        case .exceedsLimit: "Logical dimensions must not exceed 8192 pixels."
        }
    }
}

/// A planning document, never a claim that macOS or the connected monitor accepts a custom mode.
public struct HiDPIConfigurationPlan: Codable, Sendable, Equatable {
    public let logicalWidth: Int
    public let logicalHeight: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let installationStatus: String
    public let recoverySteps: [String]

    public init(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw HiDPIPlanError.invalidDimensions }
        guard width <= 8192, height <= 8192 else { throw HiDPIPlanError.exceedsLimit }
        logicalWidth = width; logicalHeight = height
        pixelWidth = width * 2; pixelHeight = height * 2
        installationStatus = "Plan only: the public provider cannot add custom modes to a physical display."
        recoverySteps = ["Before making external changes, write down the current resolution and refresh rate.",
                         "Before installing, back up the existing display configuration files.",
                         "If the picture disappears, use a working display or Safe Mode and restore the exact backup.",
                         "Remove only the new configuration, restart the computer, and check the original mode."]
    }
}
