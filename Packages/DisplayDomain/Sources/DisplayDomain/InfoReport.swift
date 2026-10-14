// SPDX-License-Identifier: GPL-3.0-or-later
// Original clean-room implementation for FreeDisplay.
import Foundation

/// A read-only report as labelled rows in titled sections — what the per-display information
/// report and the decoded EDID view both render, and what both copy and export as plain text.
/// Pure value type, so formatting is unit-tested; the app only puts it on screen or in a file.
public struct InfoReport: Hashable, Sendable {
    public struct Row: Hashable, Sendable {
        public var label: String
        public var value: String

        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public struct Section: Hashable, Sendable, Identifiable {
        public var title: String
        public var rows: [Row]
        /// Qualifiers that belong to the section as a whole ("estimated", "not verified"), kept
        /// beside the rows rather than folded into a value where they would be lost on copy.
        public var notes: [String]

        public init(title: String, rows: [Row] = [], notes: [String] = []) {
            self.title = title
            self.rows = rows
            self.notes = notes
        }

        public var id: String { title }
        public var isEmpty: Bool { rows.isEmpty && notes.isEmpty }
    }

    public var title: String
    /// Lines under the title: what produced the report and when.
    public var header: [String]
    public var sections: [Section]
    /// Closing lines, e.g. the privacy notice — part of every copy and export.
    public var footer: [String]

    public init(title: String, header: [String] = [], sections: [Section], footer: [String] = []) {
        self.title = title
        self.header = header
        self.sections = sections
        self.footer = footer
    }

    /// The report as UTF-8-safe plain text: title, header, one block per non-empty section with
    /// "Label: value" rows (continuation lines of a multi-line value indented under it), then the
    /// footer. Nothing is dropped or shortened — the export is the whole report.
    public func plainText() -> String {
        var lines: [String] = [title]
        lines.append(contentsOf: header)
        for section in sections where !section.isEmpty {
            lines.append("")
            lines.append("== \(section.title) ==")
            for row in section.rows {
                let valueLines = row.value.split(separator: "\n", omittingEmptySubsequences: false)
                if valueLines.count <= 1 {
                    lines.append("\(row.label): \(row.value)")
                } else {
                    lines.append("\(row.label):")
                    lines.append(contentsOf: valueLines.map { "    " + $0 })
                }
            }
            for note in section.notes { lines.append("* " + note) }
        }
        if !footer.isEmpty {
            lines.append("")
            lines.append(contentsOf: footer)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Supplies the words and number formatting a report is written in. The package states every
/// label in English and asks the localizer for it; the app answers from its string catalog (the
/// keys are listed there by hand) and formats decimals for the interface language. Tests use
/// `.english`, which returns the keys and formats with a "." separator.
public struct ReportLocalizer: Sendable {
    public var text: @Sendable (String) -> String
    /// A decimal with at most `fractionDigits` digits after the separator, trailing zeros dropped.
    public var decimal: @Sendable (_ value: Double, _ fractionDigits: Int) -> String

    public init(text: @escaping @Sendable (String) -> String,
                decimal: @escaping @Sendable (Double, Int) -> String) {
        self.text = text
        self.decimal = decimal
    }

    public static let english = ReportLocalizer(text: { $0 }, decimal: ReportLocalizer.posixDecimal)

    public func callAsFunction(_ key: String) -> String { text(key) }

    /// Looks `template` up, then replaces %1, %2, … with `arguments` in order. Positional markers
    /// let a translation reorder them.
    public func fill(_ template: String, _ arguments: String...) -> String {
        var result = text(template)
        // Highest index first, so %1 never eats the start of %10.
        for (index, argument) in arguments.enumerated().reversed() {
            result = result.replacingOccurrences(of: "%\(index + 1)", with: argument)
        }
        return result
    }

    public func yesNo(_ value: Bool) -> String { value ? text("Yes") : text("No") }

    /// "." separator, no grouping, trailing zeros trimmed — deterministic on every platform.
    public static func posixDecimal(_ value: Double, _ fractionDigits: Int) -> String {
        guard value.isFinite else { return String(value) }
        let digits = max(0, fractionDigits)
        var text = String(format: "%.\(digits)f", value)
        if digits > 0, text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }
}
