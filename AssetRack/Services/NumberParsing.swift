import Foundation

// MARK: - Locale-aware number parsing for user input
//
// iOS shows a decimal pad whose decimal key matches the device Region. In the
// Netherlands (nl_NL) that key is "," and the grouping separator is "." — the
// exact opposite of en_US. So a user typing "1.234,56" means 1234.56, while the
// same string in the US means 1.23456 (or nonsense). Parsing user input with
// `Double("…")` after blindly stripping commas assumes US conventions and
// silently corrupts values in comma-decimal regions.
//
// Always parse free-form numeric text fields through `NumberParsing.userNumber`
// so the device's own locale decides how to read the separators.

enum NumberParsing {

    /// A `.decimal` formatter pinned to the current locale. Cached — formatter
    /// init is expensive (see CLAUDE.md "Performance"). Not thread-safe to
    /// mutate, but we only read, and parsing happens on the main actor.
    private static let localeDecimal: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = .current
        f.isLenient = true
        return f
    }()

    /// Formatter for pre-filling an editable numeric field: device-locale
    /// decimal separator, NO grouping separator (so it round-trips cleanly
    /// back through `userNumber`), up to 2 fraction digits.
    private static let editableFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = .current
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f
    }()

    /// Format a value for an **editable** text field using the device locale's
    /// decimal separator and no grouping. Use this instead of
    /// `String(format: "%.2f", …)` when pre-filling a free-form numeric field —
    /// otherwise the "%.2f" period decimal misparses on comma-decimal devices.
    static func editableString(_ value: Double) -> String {
        editableFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Parse a number a user typed on **this device**, honouring the device
    /// locale's decimal/grouping separators. Strips currency symbols and
    /// stray letters first. Falls back to a separator-agnostic heuristic so a
    /// value pasted in a foreign format still parses.
    ///
    /// Examples (device locale in brackets):
    ///   "1.234,56" [nl_NL] → 1234.56
    ///   "1,234.56" [en_US] → 1234.56
    ///   "€ 1.500"  [de_DE] → 1500
    ///   "2,5"      [fr_FR] → 2.5
    static func userNumber(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Keep digits, separators, whitespace (some locales group with a
        // non-breaking space), and a leading sign; drop currency symbols etc.
        let cleaned = trimmed
            .replacingOccurrences(of: "[^0-9.,\\s\\-]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }

        if let n = localeDecimal.number(from: cleaned) { return n.doubleValue }
        return heuristicNumber(cleaned)
    }

    /// Locale-independent best-effort parse for **external / file** data such
    /// as CSV, where the source locale is unknown. Copes with both "1,234.56"
    /// and "1.234,56" by treating whichever separator appears last as the
    /// decimal point.
    static func heuristicNumber(_ raw: String) -> Double? {
        var s = raw.replacingOccurrences(of: "[^0-9.,\\-]", with: "", options: .regularExpression)
        guard !s.isEmpty else { return nil }

        let hasComma = s.contains(","), hasDot = s.contains(".")
        if hasComma && hasDot {
            if s.lastIndex(of: ",")! > s.lastIndex(of: ".")! {
                // comma is the decimal: "1.234,56"
                s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                // dot is the decimal: "1,234.56"
                s = s.replacingOccurrences(of: ",", with: "")
            }
        } else if hasComma {
            // Comma only — decimal if it looks like one (single comma, ≤2
            // trailing digits), otherwise a thousands separator.
            let parts = s.split(separator: ",", omittingEmptySubsequences: false)
            if parts.count == 2 && parts[1].count <= 2 {
                s = s.replacingOccurrences(of: ",", with: ".")
            } else {
                s = s.replacingOccurrences(of: ",", with: "")
            }
        }
        return Double(s)
    }
}
