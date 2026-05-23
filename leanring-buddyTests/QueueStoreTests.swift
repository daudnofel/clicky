//
//  QueueStoreTests.swift
//  leanring-buddyTests
//
//  Swift Testing coverage for QueueStore. The store is the only durable
//  representation of a review-queue item: the agent ws stream pushes
//  state in, the SwiftUI review panel reads state out, and the
//  Approve/Discard buttons mutate state through here. Bugs in this
//  layer would silently corrupt applications the user thought they'd
//  submitted, so we keep tight unit coverage of the four mutators.
//
//  All tests run against an in-memory DatabaseQueue so they're fast and
//  hermetic — no Application Support directory side effects.
//

import Foundation
import Testing
@testable import leanring_buddy

struct QueueStoreTests {

    // MARK: - Helpers

    /// Constructs a fully-populated QueueItem for tests. Centralized so
    /// individual cases only have to specify the fields they actually
    /// care about exercising.
    private func makeFixtureQueueItem(
        id queueItemIdentifier: String = "queue-item-abc",
        status: QueueItem.Status = .ready,
        company: String? = "Acme",
        role: String? = "Software Engineer",
        draftedText: String? = "hello from clicky",
        submitSelector: String? = "button[type=submit]"
    ) -> QueueItem {
        let now = Date()
        return QueueItem(
            id: queueItemIdentifier,
            workflowId: "workflow-1",
            sessionId: "session-1",
            parametersJson: #"{"job_url":"https://example.com/job"}"#,
            company: company,
            role: role,
            draftedText: draftedText,
            filledFieldsJson: #"{"name":"Daud"}"#,
            submitSelector: submitSelector,
            status: status,
            agentSessionAlive: true,
            createdAt: now,
            updatedAt: now
        )
    }

    // MARK: - Insert + Fetch

    @Test func insertingAndFetchingASingleItemRoundTripsAllFields() async throws {
        let store = try QueueStore(inMemoryDatabase: true)
        let fixture = makeFixtureQueueItem()

        try store.upsert(fixture)

        let allFetched = try store.fetchAll(status: nil)
        #expect(allFetched.count == 1)
        let firstFetched = try #require(allFetched.first)
        #expect(firstFetched.id == fixture.id)
        #expect(firstFetched.company == "Acme")
        #expect(firstFetched.role == "Software Engineer")
        #expect(firstFetched.draftedText == "hello from clicky")
        // submit_selector is the load-bearing § A.4 amendment field —
        // verify it round-trips so a regression like dropping it from
        // the schema would be caught here, not in production.
        #expect(firstFetched.submitSelector == "button[type=submit]")
        #expect(firstFetched.status == .ready)
        #expect(firstFetched.agentSessionAlive == true)
    }

    // MARK: - Status Filter

    @Test func fetchAllWithStatusOnlyReturnsMatchingRows() async throws {
        let store = try QueueStore(inMemoryDatabase: true)

        try store.upsert(makeFixtureQueueItem(id: "q1", status: .drafting))
        try store.upsert(makeFixtureQueueItem(id: "q2", status: .ready))
        try store.upsert(makeFixtureQueueItem(id: "q3", status: .ready))
        try store.upsert(makeFixtureQueueItem(id: "q4", status: .discarded))

        let onlyReadyItems = try store.fetchAll(status: .ready)
        #expect(onlyReadyItems.count == 2)
        #expect(onlyReadyItems.allSatisfy { $0.status == .ready })

        let onlyDiscardedItems = try store.fetchAll(status: .discarded)
        #expect(onlyDiscardedItems.count == 1)
        #expect(onlyDiscardedItems.first?.id == "q4")
    }

    // MARK: - Update Drafted Text

    @Test func updateDraftedTextMutatesOnlyTheTextColumn() async throws {
        let store = try QueueStore(inMemoryDatabase: true)
        let fixture = makeFixtureQueueItem(id: "q-edit", draftedText: "original draft")
        try store.upsert(fixture)

        try store.updateDraftedText(id: "q-edit", newText: "edited by the user inline")

        let updatedRows = try store.fetchAll(status: nil)
        let editedRow = try #require(updatedRows.first { $0.id == "q-edit" })
        #expect(editedRow.draftedText == "edited by the user inline")
        // Verify the other columns weren't accidentally clobbered.
        #expect(editedRow.company == fixture.company)
        #expect(editedRow.submitSelector == fixture.submitSelector)
        #expect(editedRow.status == fixture.status)
    }

    // MARK: - Status Transition

    @Test func setStatusTransitionsTheRowAndBumpsUpdatedAt() async throws {
        let store = try QueueStore(inMemoryDatabase: true)
        let fixture = makeFixtureQueueItem(id: "q-status", status: .ready)
        try store.upsert(fixture)

        // Capture the original timestamp so we can verify it actually moved.
        let originalRow = try #require(try store.fetchAll(status: nil).first { $0.id == "q-status" })
        let originalUpdatedAt = originalRow.updatedAt

        // Sleep a tick so the timestamp comparison can move at least 1ms.
        try? await Task.sleep(nanoseconds: 5_000_000)

        try store.setStatus(id: "q-status", newStatus: .submitted)

        let updatedRow = try #require(try store.fetchAll(status: nil).first { $0.id == "q-status" })
        #expect(updatedRow.status == .submitted)
        #expect(updatedRow.updatedAt > originalUpdatedAt)
    }
}
