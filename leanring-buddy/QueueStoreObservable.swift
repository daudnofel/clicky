//
//  QueueStoreObservable.swift
//  leanring-buddy
//
//  @MainActor ObservableObject wrapper around QueueStore. The store is a
//  plain class so it stays usable from unit tests without dragging in
//  SwiftUI; this wrapper layers on the `@Published` arrays that
//  SwiftUI views need to redraw automatically.
//
//  Why two `@Published` arrays instead of one + a `.filter` in the view:
//    - `readyItems` is the hot path for the Review Queue UI (rendered
//      every refresh, possibly large). Pre-filtering here lets us avoid
//      doing the filter inside the view's body, which SwiftUI would
//      otherwise re-run on every diff pass even if `allItems` hadn't
//      changed shape.
//    - `allItems` is exposed for future "history" surfaces (e.g. a
//      "submitted today" tab) without the store needing a second
//      observable.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class QueueStoreObservable: ObservableObject {
    /// Items in the .ready bucket — the cards the Review Queue panel
    /// renders right now. Newest-first ordering (matches QueueStore).
    @Published private(set) var readyItems: [QueueItem] = []

    /// Everything the store currently holds, regardless of status.
    /// Surfaces here so a future "completed" tab doesn't need its own
    /// observable wrapper. Newest-first ordering.
    @Published private(set) var allItems: [QueueItem] = []

    /// The underlying store. Exposed so callers that need to perform a
    /// mutation (approve → setStatus, inline edit → updateDraftedText)
    /// can do so without going through a passthrough on this wrapper —
    /// the wrapper would otherwise grow a method per mutator and we'd
    /// be back to maintaining a parallel API surface.
    ///
    /// Callers MUST call `refreshFromStore()` after any direct mutation
    /// so the @Published arrays catch up.
    let queueStore: QueueStore

    init(queueStore: QueueStore) {
        self.queueStore = queueStore
        // Best-effort initial load — if SQLite is somehow corrupt at boot
        // we still want the app to launch with an empty queue rather than
        // crash on this constructor. Errors are logged for diagnosis.
        refreshFromStore()
    }

    /// Reads both buckets out of the store and republishes them. Callers
    /// should invoke this after any write (or rely on the websocket-event
    /// path which already does so).
    func refreshFromStore() {
        do {
            let freshReadyItems = try queueStore.fetchAll(status: .ready)
            let freshAllItems = try queueStore.fetchAll(status: nil)
            // Only assign if the new value differs to avoid pointless
            // SwiftUI diff passes on no-op refreshes. QueueItem is
            // Equatable so == works without us writing a custom path.
            if freshReadyItems != readyItems {
                readyItems = freshReadyItems
            }
            if freshAllItems != allItems {
                allItems = freshAllItems
            }
        } catch {
            print("⚠️ QueueStoreObservable: refresh failed — \(error)")
        }
    }

    // MARK: - Convenience write-through helpers
    //
    // These wrap the QueueStore mutators and refresh the @Published
    // arrays in one step. View code uses these so the "write then
    // refresh" pair never gets accidentally separated and miss-published.

    func upsertAndRefresh(_ queueItemToPersist: QueueItem) {
        do {
            try queueStore.upsert(queueItemToPersist)
            refreshFromStore()
        } catch {
            print("⚠️ QueueStoreObservable: upsert failed for \(queueItemToPersist.id) — \(error)")
        }
    }

    func updateDraftedTextAndRefresh(id queueItemIdentifier: String, newText: String) {
        do {
            try queueStore.updateDraftedText(id: queueItemIdentifier, newText: newText)
            refreshFromStore()
        } catch {
            print("⚠️ QueueStoreObservable: updateDraftedText failed for \(queueItemIdentifier) — \(error)")
        }
    }

    func setStatusAndRefresh(id queueItemIdentifier: String, newStatus: QueueItem.Status) {
        do {
            try queueStore.setStatus(id: queueItemIdentifier, newStatus: newStatus)
            refreshFromStore()
        } catch {
            print("⚠️ QueueStoreObservable: setStatus failed for \(queueItemIdentifier) — \(error)")
        }
    }
}
