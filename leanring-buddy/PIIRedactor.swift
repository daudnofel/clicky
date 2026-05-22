//
//  PIIRedactor.swift
//  leanring-buddy
//
//  Heuristic detector for personally identifiable information that must
//  never be written into a teach-mode demonstration recording. Used by
//  EventCaptureTap before emitting any "text" event captured from a
//  focused input field.
//

import Foundation

enum PIIRedactor {
    // Credit card numbers: 13–19 digits, optionally separated by spaces or
    // dashes. Tightened with a leading/trailing word boundary so adjacent
    // tokens don't accidentally extend a non-card number into a match.
    private static let creditCardNumberPattern = #"\b(?:\d[ -]?){13,19}\b"#
    // US Social Security Number — three digits, two digits, four digits.
    private static let socialSecurityNumberPattern = #"\b\d{3}-\d{2}-\d{4}\b"#

    private static let creditCardNumberRegex: NSRegularExpression = {
        // try! is acceptable here: the pattern is a compile-time constant
        // and a malformed pattern would be caught immediately at first launch.
        return try! NSRegularExpression(pattern: creditCardNumberPattern)
    }()

    private static let socialSecurityNumberRegex: NSRegularExpression = {
        return try! NSRegularExpression(pattern: socialSecurityNumberPattern)
    }()

    /// Returns true when the supplied text contains anything that looks
    /// like a credit card number or US SSN. Callers should treat a true
    /// result as "do not persist this string; emit a redacted event instead."
    static func looksSensitive(_ candidateText: String) -> Bool {
        let fullRange = NSRange(candidateText.startIndex..<candidateText.endIndex, in: candidateText)
        if creditCardNumberRegex.firstMatch(in: candidateText, range: fullRange) != nil {
            return true
        }
        if socialSecurityNumberRegex.firstMatch(in: candidateText, range: fullRange) != nil {
            return true
        }
        return false
    }
}
