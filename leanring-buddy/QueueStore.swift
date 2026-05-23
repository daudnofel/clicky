//
//  QueueStore.swift
//  leanring-buddy
//
//  SQLite-backed persistence for the apprentice-mode review queue. Each
//  row represents one queued application instance produced by the
//  `clicky-agent` Node subprocess: company + role + drafted text + the
//  raw selectors needed to actually submit when the user approves.
//
//  Storage uses GRDB.swift on top of a single SQLite file at
//    ~/Library/Application Support/Clicky/queue.db
//
//  Why GRDB instead of raw sqlite3:
//   - Codable + FetchableRecord + PersistableRecord eliminates the
//     bind/columnText boilerplate that dominates raw sqlite3 wrappers
//     and that we'd otherwise have to keep in sync with the schema.
//   - DatabaseQueue gives us serialized access by construction, so the
//     ws receive loop on the main actor and any future background
//     migration task can both write without us hand-rolling locks.
//   - In-memory `DatabaseQueue()` constructor mirrors the file-backed
//     one almost exactly, so tests touch the same code paths as prod.
//
//  Concurrency note: GRDB writes are synchronous by design (the queue
//  serializes them), so callers that absolutely cannot block on disk
//  IO should hop to a detached Task. In the apprentice-mode usage
//  pattern (one upsert per inbound ws message, a handful of seconds
//  apart) the wait is negligible and we accept it on the main actor.
//

import Foundation
import GRDB

/// One queue item exactly as defined in § A.6 of the apprentice-mode
/// implementation plan. The mapping between the Swift property names
/// and the snake_case schema columns is handled inside the migrator
/// below (GRDB's default is to use the property name verbatim — we
/// keep the property names camelCase for Swift conventions and write
/// the table with matching camelCase column names so encoding "just
/// works" without a CodingKeys map).
struct QueueItem: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    /// Lifecycle states for a single queue item. The values are also the
    /// raw strings stored in the `status` column — keep these stable.
    enum Status: String, Codable, CaseIterable {
        case drafting    // agent is mid-replay; no card shown to user yet
        case ready       // halted at submit-ready; awaiting user approval
        case approved    // user clicked Approve; submit ws message in flight
        case submitted   // agent confirmed successful form submission
        case failed      // agent reported an error during replay or submit
        case discarded   // user explicitly trashed the card
    }

    static let databaseTableName = "queue_items"

    let id: String
    let workflowId: String
    let sessionId: String
    let parametersJson: String
    var company: String?
    var role: String?
    var draftedText: String?
    var filledFieldsJson: String?
    /// First-class field per the 2026-05-22 § A.4 amendment. Stored on
    /// the row so the Approve & Submit path can re-issue the click
    /// even if the agent process has rotated between sessions.
    var submitSelector: String?
    var status: Status
    var agentSessionAlive: Bool
    let createdAt: Date
    var updatedAt: Date
}

/// Thrown when the store can't initialize. Surfaces in `init` so callers
/// can decide whether to fall back to an in-memory store or just log.
enum QueueStoreError: Error {
    case applicationSupportDirectoryUnavailable
    case couldNotCreateClickyDirectory(underlyingError: Error)
}

final class QueueStore {
    /// The serialized access point to SQLite. Exposed as `let` so callers
    /// can build their own read/write blocks if QueueStore's helpers don't
    /// cover a use case — but in practice everything should funnel through
    /// the methods below so the schema stays encapsulated here.
    let databaseQueue: DatabaseQueue

    /// Initializes the store. Pass `inMemoryDatabase: true` from unit
    /// tests so the GRDB DatabaseQueue lives in `:memory:` rather than
    /// stomping the real Application Support file.
    init(inMemoryDatabase: Bool = false) throws {
        if inMemoryDatabase {
            // GRDB's DatabaseQueue() with no path creates an anonymous
            // in-memory store. Perfect for `@Test` cases — fast, isolated,
            // disappears the moment the queue is deallocated.
            databaseQueue = try DatabaseQueue()
        } else {
            let resolvedDatabaseFileUrl = try QueueStore.resolveOnDiskDatabaseFileUrl()
            databaseQueue = try DatabaseQueue(path: resolvedDatabaseFileUrl.path)
        }
        try runMigrations()
    }

    // MARK: - Public API

    /// Inserts a new row or replaces an existing one (matched by `id`).
    /// We use `save` instead of `insert` so handlers that re-process the
    /// same `queue_id` (a normal pattern when the agent flips a row from
    /// `drafting` → `ready` → `submitted`) don't have to branch on
    /// "is this an insert or an update?"
    func upsert(_ queueItemToPersist: QueueItem) throws {
        var mutableCopy = queueItemToPersist
        // Always stamp updatedAt at write time so callers don't have to
        // remember. The created_at is set once by the caller on first
        // insert and preserved by GRDB on subsequent saves of the same
        // primary key.
        mutableCopy.updatedAt = Date()
        try databaseQueue.write { databaseConnection in
            try mutableCopy.save(databaseConnection)
        }
    }

    /// Returns rows filtered by status, ordered newest-first. If `status`
    /// is nil, returns everything (used in the "history" tab; live UI
    /// passes `.ready`).
    func fetchAll(status: QueueItem.Status? = nil) throws -> [QueueItem] {
        try databaseQueue.read { databaseConnection in
            if let status {
                return try QueueItem
                    .filter(Column("status") == status.rawValue)
                    .order(Column("updatedAt").desc)
                    .fetchAll(databaseConnection)
            }
            return try QueueItem
                .order(Column("updatedAt").desc)
                .fetchAll(databaseConnection)
        }
    }

    /// Convenience for the inline-edit path: the user is mutating the
    /// drafted body in a TextEditor and we only want to write the one
    /// column, not round-trip the whole row.
    func updateDraftedText(id queueItemIdentifier: String, newText: String) throws {
        try databaseQueue.write { databaseConnection in
            try databaseConnection.execute(
                sql: "UPDATE queue_items SET draftedText = ?, updatedAt = ? WHERE id = ?",
                arguments: [newText, Date(), queueItemIdentifier]
            )
        }
    }

    /// Status transitions get their own helper so view-layer code doesn't
    /// have to load+save the entire row just to flip a string column.
    func setStatus(id queueItemIdentifier: String, newStatus: QueueItem.Status) throws {
        try databaseQueue.write { databaseConnection in
            try databaseConnection.execute(
                sql: "UPDATE queue_items SET status = ?, updatedAt = ? WHERE id = ?",
                arguments: [newStatus.rawValue, Date(), queueItemIdentifier]
            )
        }
    }

    // MARK: - Internals

    /// Resolves and creates `~/Library/Application Support/Clicky/queue.db`
    /// (creating the Clicky directory if needed). Pulled out so the
    /// init can stay readable and so tests can inspect the path resolution
    /// independently if we add coverage for that later.
    private static func resolveOnDiskDatabaseFileUrl() throws -> URL {
        let fileManagerInstance = FileManager.default
        guard let applicationSupportDirectoryUrl = try? fileManagerInstance.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            throw QueueStoreError.applicationSupportDirectoryUnavailable
        }
        let clickyDirectoryUrl = applicationSupportDirectoryUrl.appendingPathComponent(
            "Clicky",
            isDirectory: true
        )
        do {
            try fileManagerInstance.createDirectory(
                at: clickyDirectoryUrl,
                withIntermediateDirectories: true
            )
        } catch {
            throw QueueStoreError.couldNotCreateClickyDirectory(underlyingError: error)
        }
        return clickyDirectoryUrl.appendingPathComponent("queue.db", isDirectory: false)
    }

    /// Single migration block. Uses `DatabaseMigrator` so future schema
    /// changes can be appended as named migrations without touching the
    /// initial one — GRDB tracks which have already been applied.
    private func runMigrations() throws {
        var schemaMigrator = DatabaseMigrator()
        schemaMigrator.registerMigration("v1_create_queue_items") { databaseConnection in
            try databaseConnection.create(
                table: QueueItem.databaseTableName,
                ifNotExists: true
            ) { tableDefinition in
                tableDefinition.column("id", .text).primaryKey()
                tableDefinition.column("workflowId", .text).notNull()
                tableDefinition.column("sessionId", .text).notNull()
                tableDefinition.column("parametersJson", .text).notNull()
                tableDefinition.column("company", .text)
                tableDefinition.column("role", .text)
                tableDefinition.column("draftedText", .text)
                tableDefinition.column("filledFieldsJson", .text)
                // submit_selector lives in its own column per the
                // § A.4 amendment — never nested under filledFieldsJson
                // even though a careless impl might be tempted to.
                tableDefinition.column("submitSelector", .text)
                tableDefinition.column("status", .text).notNull()
                tableDefinition.column("agentSessionAlive", .boolean)
                    .notNull()
                    .defaults(to: true)
                tableDefinition.column("createdAt", .datetime).notNull()
                tableDefinition.column("updatedAt", .datetime).notNull()
            }
            try databaseConnection.create(
                index: "queue_items_status_idx",
                on: QueueItem.databaseTableName,
                columns: ["status"],
                ifNotExists: true
            )
        }
        try schemaMigrator.migrate(databaseQueue)
    }
}
