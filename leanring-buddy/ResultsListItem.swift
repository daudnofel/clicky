//
//  ResultsListItem.swift
//  leanring-buddy
//
//  Wire shape for one row in a "results-list" workflow's halt payload.
//  Mirrors the TypeScript `ResultsListItem` interface in
//  `clicky-agent/src/types.ts` exactly — keep the two definitions in
//  lockstep. § A.3 / § A.4 amendment 2026-05-23.
//
//  Example on-the-wire JSON:
//    {
//      "title": "Senior Data Scientist — Acme",
//      "fields": {
//        "salary": "$220K",
//        "location": "Remote",
//        "company": "Acme"
//      },
//      "url": "https://remoteok.com/job/12345"
//    }
//
//  Decode rules:
//    - `title` is required (non-optional). The worker validator drops
//      items missing a title before they reach Swift.
//    - `fields` is required but may be empty `{}`. The worker validator
//      replaces a missing/malformed `fields` with `{}` per item.
//    - `url` is optional. When present, the ResultsListCard renders an
//      "Open" button that hands the URL to `NSWorkspace.shared.open(_:)`.
//
//  Identity: rows render in a SwiftUI `ForEach` so we need `Identifiable`.
//  We synthesize a stable id by hashing title + the sorted fields tuples.
//  `url` is left out of the id derivation because two rows with the same
//  visible content but different deep-link URLs are still "the same row"
//  for diffing purposes and should not animate as a delete+insert.
//

import Foundation

struct ResultsListItem: Codable, Equatable, Identifiable {
    let title: String
    let fields: [String: String]
    let url: String?

    /// Stable identity derived from title + sorted fields. Used by SwiftUI
    /// ForEach. We hash the tuple-formatted, sorted fields so the id is
    /// reproducible across decodes — `[String: String]` itself has
    /// unordered iteration.
    var id: String {
        // Sort the fields by key so a re-decode (or a hand-crafted equal
        // payload) produces the same id. Join with delimiters that can't
        // appear inside SQL-stored values without escaping (control chars).
        let sortedFieldsString = fields
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)\u{001F}\($0.value)" }
            .joined(separator: "\u{001E}")
        return "\(title)\u{001D}\(sortedFieldsString)"
    }

    // Explicit CodingKeys (rather than relying on default synthesis) so
    // that the in-source property names AND the on-wire JSON keys stay
    // pinned to the same identifiers as the TypeScript ResultsListItem.
    // If somebody renames a Swift property we want a compile error here,
    // not a silent contract drift.
    enum CodingKeys: String, CodingKey {
        case title
        case fields
        case url
    }
}
