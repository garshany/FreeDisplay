// SPDX-License-Identifier: GPL-3.0-or-later
// Original clean-room table of the CTA-861 Video Identification Codes (public standard data).
import Foundation

/// The active size, nominal field/frame rate and scan of each CTA-861 Video Identification Code,
/// so a Video Data Block can be shown as resolutions rather than bare numbers. Rates are nominal:
/// "60" stands for the 60 and 59.94 Hz variants the code covers. Widths of pixel-repeated
/// standard-definition codes are the transmitted widths (1440/2880).
public enum CTAVideoFormats {
    public struct Format: Hashable, Sendable {
        public var width: Int
        public var height: Int
        public var refreshHz: Double
        public var interlaced: Bool
        /// Picture aspect ratio as the standard states it ("16:9", "4:3", "64:27", "256:135").
        public var aspect: String
    }

    public static func format(vic: Int) -> Format? { table[vic] }

    private static func f(_ w: Int, _ h: Int, _ hz: Double, _ aspect: String, i: Bool = false) -> Format {
        Format(width: w, height: h, refreshHz: hz, interlaced: i, aspect: aspect)
    }

    private static let table: [Int: Format] = {
        var t: [Int: Format] = [
            1: f(640, 480, 60, "4:3"), 2: f(720, 480, 60, "4:3"), 3: f(720, 480, 60, "16:9"),
            4: f(1280, 720, 60, "16:9"), 5: f(1920, 1080, 60, "16:9", i: true),
            6: f(1440, 480, 60, "4:3", i: true), 7: f(1440, 480, 60, "16:9", i: true),
            8: f(1440, 240, 60, "4:3"), 9: f(1440, 240, 60, "16:9"),
            10: f(2880, 480, 60, "4:3", i: true), 11: f(2880, 480, 60, "16:9", i: true),
            12: f(2880, 240, 60, "4:3"), 13: f(2880, 240, 60, "16:9"),
            14: f(1440, 480, 60, "4:3"), 15: f(1440, 480, 60, "16:9"), 16: f(1920, 1080, 60, "16:9"),
            17: f(720, 576, 50, "4:3"), 18: f(720, 576, 50, "16:9"), 19: f(1280, 720, 50, "16:9"),
            20: f(1920, 1080, 50, "16:9", i: true),
            21: f(1440, 576, 50, "4:3", i: true), 22: f(1440, 576, 50, "16:9", i: true),
            23: f(1440, 288, 50, "4:3"), 24: f(1440, 288, 50, "16:9"),
            25: f(2880, 576, 50, "4:3", i: true), 26: f(2880, 576, 50, "16:9", i: true),
            27: f(2880, 288, 50, "4:3"), 28: f(2880, 288, 50, "16:9"),
            29: f(1440, 576, 50, "4:3"), 30: f(1440, 576, 50, "16:9"), 31: f(1920, 1080, 50, "16:9"),
            32: f(1920, 1080, 24, "16:9"), 33: f(1920, 1080, 25, "16:9"), 34: f(1920, 1080, 30, "16:9"),
            35: f(2880, 480, 60, "4:3"), 36: f(2880, 480, 60, "16:9"),
            37: f(2880, 576, 50, "4:3"), 38: f(2880, 576, 50, "16:9"),
            39: f(1920, 1080, 50, "16:9", i: true), 40: f(1920, 1080, 100, "16:9", i: true),
            41: f(1280, 720, 100, "16:9"), 42: f(720, 576, 100, "4:3"), 43: f(720, 576, 100, "16:9"),
            44: f(1440, 576, 100, "4:3", i: true), 45: f(1440, 576, 100, "16:9", i: true),
            46: f(1920, 1080, 120, "16:9", i: true), 47: f(1280, 720, 120, "16:9"),
            48: f(720, 480, 120, "4:3"), 49: f(720, 480, 120, "16:9"),
            50: f(1440, 480, 120, "4:3", i: true), 51: f(1440, 480, 120, "16:9", i: true),
            52: f(720, 576, 200, "4:3"), 53: f(720, 576, 200, "16:9"),
            54: f(1440, 576, 200, "4:3", i: true), 55: f(1440, 576, 200, "16:9", i: true),
            56: f(720, 480, 240, "4:3"), 57: f(720, 480, 240, "16:9"),
            58: f(1440, 480, 240, "4:3", i: true), 59: f(1440, 480, 240, "16:9", i: true),
            60: f(1280, 720, 24, "16:9"), 61: f(1280, 720, 25, "16:9"), 62: f(1280, 720, 30, "16:9"),
            63: f(1920, 1080, 120, "16:9"), 64: f(1920, 1080, 100, "16:9"),
        ]
        // 65–92: 64:27 variants of 720p/1080p and the 1680×720 / 2560×1080 families.
        let rates: [Double] = [24, 25, 30, 50, 60, 100, 120]
        for (index, hz) in rates.enumerated() {
            t[65 + index] = f(1280, 720, hz, "64:27")
            t[72 + index] = f(1920, 1080, hz, "64:27")
            t[79 + index] = f(1680, 720, hz, "64:27")
            t[86 + index] = f(2560, 1080, hz, "64:27")
        }
        for (index, hz) in [24.0, 25, 30, 50, 60].enumerated() {
            t[93 + index] = f(3840, 2160, hz, "16:9")
            t[98 + index] = f(4096, 2160, hz, "256:135")
            t[103 + index] = f(3840, 2160, hz, "64:27")
        }
        t[108] = f(1280, 720, 48, "16:9"); t[109] = f(1280, 720, 48, "64:27")
        t[110] = f(1680, 720, 48, "64:27"); t[111] = f(1920, 1080, 48, "16:9")
        t[112] = f(1920, 1080, 48, "64:27"); t[113] = f(2560, 1080, 48, "64:27")
        t[114] = f(3840, 2160, 48, "16:9"); t[115] = f(4096, 2160, 48, "256:135")
        t[116] = f(3840, 2160, 48, "64:27"); t[117] = f(3840, 2160, 100, "16:9")
        t[118] = f(3840, 2160, 120, "16:9"); t[119] = f(3840, 2160, 100, "64:27")
        t[120] = f(3840, 2160, 120, "64:27")
        for (index, hz) in [24.0, 25, 30, 48, 50, 60, 100].enumerated() { t[121 + index] = f(5120, 2160, hz, "64:27") }
        t[193] = f(5120, 2160, 120, "64:27")
        let eightK: [Double] = [24, 25, 30, 48, 50, 60, 100, 120]
        for (index, hz) in eightK.enumerated() {
            t[194 + index] = f(7680, 4320, hz, "16:9")
            t[202 + index] = f(7680, 4320, hz, "64:27")
            t[210 + index] = f(10240, 4320, hz, "64:27")
        }
        t[218] = f(4096, 2160, 100, "256:135"); t[219] = f(4096, 2160, 120, "256:135")
        return t
    }()
}
