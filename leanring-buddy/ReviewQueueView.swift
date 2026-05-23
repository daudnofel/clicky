//
//  ReviewQueueView.swift
//  leanring-buddy
//
//  SwiftUI surface for the apprentice-mode Review Queue panel. Renders
//  one ApplicationCard per .ready queue item, stacked in a LazyVStack
//  inside a ScrollView. Empty state is a centered "no applications yet"
//  message so the panel isn't disorienting when the user opens it
//  before any replay job has produced a halt-ready item.
//

import SwiftUI

@MainActor
struct ReviewQueueView: View {
    @ObservedObject var queueStoreObservable: QueueStoreObservable
    @ObservedObject var agentWebSocketClient: AgentWebSocketClient

    var body: some View {
        ZStack {
            // Always paint the panel background, even when empty, so
            // there's no flash of "system window background" between
            // the NSPanel's chrome and the SwiftUI content.
            DS.Colors.background.ignoresSafeArea()

            if queueStoreObservable.readyItems.isEmpty {
                emptyStatePlaceholder
            } else {
                scrollingCardStack
            }
        }
    }

    // MARK: - Empty State

    private var emptyStatePlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 38, weight: .light))
                .foregroundColor(DS.Colors.textTertiary)

            Text("No applications waiting for review")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Text("Cards land here once the agent halts at a submit-ready step.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
        }
        .padding(24)
    }

    // MARK: - Card Stack

    private var scrollingCardStack: some View {
        ScrollView {
            // LazyVStack so we only materialize cards visible in the
            // viewport. A long backlog of ready items won't cost us
            // anything for off-screen rows.
            LazyVStack(spacing: 12) {
                ForEach(queueStoreObservable.readyItems) { queueItem in
                    ApplicationCard(
                        queueItem: queueItem,
                        onApprove: handleApproveAndSubmit(_:),
                        onEditInBrowser: handleEditInBrowserPlaceholder(_:),
                        onDiscard: handleDiscard(_:),
                        onDraftedTextCommit: handleDraftedTextDebouncedCommit(item:newDraftedText:)
                    )
                    .id(queueItem.id)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Action Handlers

    /// Approve & Submit: persist the local status flip optimistically so
    /// the card drops out of `.ready` instantly, then tell the agent to
    /// click the submit button it has cached for this queue id. The
    /// agent will follow up with a `queue_item_submitted` event that
    /// either confirms `.submitted` or flips us to `.failed`.
    private func handleApproveAndSubmit(_ queueItem: QueueItem) {
        queueStoreObservable.setStatusAndRefresh(id: queueItem.id, newStatus: .approved)
        agentWebSocketClient.send([
            "type": "approve_submit",
            "queue_id": queueItem.id
        ])
    }

    /// Edit in browser: V1 placeholder. The contract (a ws message that
    /// reattaches the agent's headless page to a headed Chromium so the
    /// user can finish manually) lives in the design doc but isn't
    /// wired through yet. For now we just leave the card in `.ready`
    /// so the user can come back and approve.
    private func handleEditInBrowserPlaceholder(_ queueItem: QueueItem) {
        // TODO(apprentice V1+): swap this for a real ws "open_in_browser"
        // message that re-launches the agent's page in headed mode. For
        // now, log so QA can spot misclicks.
        print("ℹ️ Review queue: 'Edit in browser' tapped for \(queueItem.id) — not implemented in V1")
    }

    /// Discard: persist the status flip locally so the card disappears
    /// immediately, then tell the agent to abandon its in-memory page
    /// state for this queue id.
    private func handleDiscard(_ queueItem: QueueItem) {
        queueStoreObservable.setStatusAndRefresh(id: queueItem.id, newStatus: .discarded)
        agentWebSocketClient.send([
            "type": "discard",
            "queue_id": queueItem.id
        ])
    }

    /// Debounced inline-edit commit. Writes through to SQLite via the
    /// observable wrapper; the wrapper refreshes the @Published arrays.
    private func handleDraftedTextDebouncedCommit(
        item queueItem: QueueItem,
        newDraftedText: String
    ) {
        queueStoreObservable.updateDraftedTextAndRefresh(
            id: queueItem.id,
            newText: newDraftedText
        )
    }
}
