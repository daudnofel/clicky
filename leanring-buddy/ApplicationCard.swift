//
//  ApplicationCard.swift
//  leanring-buddy
//
//  One card in the apprentice-mode review queue. Shows the company +
//  role header, an inline-editable drafted text body, and the three
//  action buttons: Approve & Submit (sends approve_submit ws message),
//  Edit in browser (V1 placeholder), Discard (sends discard ws
//  message).
//
//  The inline edit path writes through to QueueStore with a small
//  debounce — keystroke-per-write would be wasteful both for SQLite and
//  for the @Published refresh cascade.
//

import Combine
import SwiftUI

@MainActor
struct ApplicationCard: View {
    /// The current snapshot of the item being rendered. Re-supplied by
    /// the parent on every QueueStoreObservable refresh, so this view
    /// stays a value type and never holds state across re-creations
    /// other than the locally-edited draft buffer.
    let queueItem: QueueItem

    /// Closure handlers for the three actions. Hoisted to the parent so
    /// this card can stay focused on layout + edit-buffer management.
    var onApprove: (QueueItem) -> Void
    var onEditInBrowser: (QueueItem) -> Void
    var onDiscard: (QueueItem) -> Void

    /// Closure invoked on every debounced draft-text mutation. The
    /// parent owns the QueueStore write-through; we just notify it
    /// when the user has stopped typing for a beat.
    var onDraftedTextCommit: (QueueItem, String) -> Void

    /// Local edit buffer for the TextEditor. Initialized from
    /// `queueItem.draftedText` and kept in sync via `onChange` of the
    /// incoming queueItem so cards from agent updates don't fight the
    /// user's typing.
    @State private var localDraftedTextBuffer: String = ""

    /// PassthroughSubject + debounce to coalesce keystrokes before we
    /// hit the parent. 400ms feels responsive without thrashing SQLite
    /// during a fast-typing edit.
    @State private var draftedTextChangeSubject = PassthroughSubject<String, Never>()

    /// Cancellable for the debounce subscription. Held in @State so the
    /// subscription survives view re-creation as long as @State does.
    @State private var debounceCancellable: AnyCancellable?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader

            inlineEditableDraftedText

            cardActionButtonsRow
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
        .onAppear(perform: configureDebouncedDraftedTextPipeline)
        // If the agent re-pushes a card (e.g. a re-draft on the same
        // queue_id), pick up the new text — but only when the user
        // hasn't been actively editing. This is a conservative rule:
        // we only sync from the model if the local buffer matches what
        // the model previously had, so we can't clobber in-flight edits.
        .onChange(of: queueItem.draftedText ?? "") { newDraftedTextFromModel in
            if localDraftedTextBuffer.isEmpty {
                localDraftedTextBuffer = newDraftedTextFromModel
            }
        }
    }

    // MARK: - Header

    private var cardHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(queueItem.company ?? "Unknown company")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)

            Spacer()

            if let role = queueItem.role, !role.isEmpty {
                Text(role)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Inline Editable Drafted Text

    private var inlineEditableDraftedText: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DRAFTED RESPONSE")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)

            // TextEditor renders the editable body. We size it with a
            // min height so empty drafts still have a clickable target,
            // and allow it to grow with content up to a sensible cap.
            TextEditor(text: $localDraftedTextBuffer)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .background(DS.Colors.surface2)
                .frame(minHeight: 80, maxHeight: 240)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
                // Forward every keystroke into the debounce subject;
                // the subject's subscription fires after 400ms of quiet.
                .onChange(of: localDraftedTextBuffer) { newDraftedTextValue in
                    draftedTextChangeSubject.send(newDraftedTextValue)
                }
        }
    }

    // MARK: - Action Buttons

    private var cardActionButtonsRow: some View {
        HStack(spacing: 8) {
            Button(action: { onApprove(queueItem) }) {
                Text("Approve & Submit")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            // ⏎ for the primary action is a standard macOS affordance.
            .keyboardShortcut(.return, modifiers: [.command])

            Button(action: { onEditInBrowser(queueItem) }) {
                Text("Edit in browser")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            // V1 stub — see editInBrowserComingSoonHint.
            .nativeTooltip("Coming soon — opens the live page in your browser to finish manually.")

            Spacer()

            Button(action: { onDiscard(queueItem) }) {
                Text("Discard")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.destructiveText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.destructive.opacity(0.30), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: - Debounce pipeline

    /// Sets up the keystroke-coalescing pipeline. Configured exactly once
    /// per view-onAppear so we don't leak duplicate subscriptions if the
    /// card is recycled. The 400ms window is short enough that the user
    /// perceives saves as "instant" but long enough that we don't write
    /// SQLite + refresh @Published arrays on every character.
    private func configureDebouncedDraftedTextPipeline() {
        // Seed the local buffer from the current model snapshot on the
        // first mount only. After that, future agent-pushed drafted_text
        // updates flow in via .onChange(of: queueItem.draftedText) above
        // and we only adopt them when the buffer is empty.
        if localDraftedTextBuffer.isEmpty {
            localDraftedTextBuffer = queueItem.draftedText ?? ""
        }

        guard debounceCancellable == nil else { return }
        debounceCancellable = draftedTextChangeSubject
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { debouncedDraftedText in
                onDraftedTextCommit(queueItem, debouncedDraftedText)
            }
    }
}
