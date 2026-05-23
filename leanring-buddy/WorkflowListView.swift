//
//  WorkflowListView.swift
//  leanring-buddy
//
//  Menu bar panel section that lists every saved workflow profile, with a
//  per-row Run button. Sits directly under the Teach toggle in
//  CompanionPanelView.
//
//  Three states:
//    1. Currently learning a workflow → ProgressView + "Learning workflow…"
//    2. No workflows saved → empty-state hint copy
//    3. >=1 workflow → list rows
//
//  Clicking Run on a row sets `sheetWorkflow` on the parent, which presents
//  WorkflowRunSheet via `.sheet(item:)`. The actual start_job ws send lives
//  in that sheet — this view stays purely presentational + selection.
//

import SwiftUI

struct WorkflowListView: View {
    @ObservedObject var workflowLibrary: WorkflowLibrary
    @ObservedObject var workflowLearner: WorkflowLearner

    /// Set by tapping Run on a row. The parent CompanionPanelView observes
    /// this via a binding and presents WorkflowRunSheet on a non-nil value.
    @Binding var workflowSelectedForRun: SavedWorkflowProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader

            if workflowLearner.isLearning {
                learningInProgressState
            } else if workflowLibrary.workflowProfiles.isEmpty {
                emptyState
            } else {
                workflowList
            }

            if let errorMessage = workflowLearner.lastLearnErrorMessage,
               !workflowLearner.isLearning {
                Text(errorMessage)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.warning)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Header

    private var sectionHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 14)
            Text("Workflows")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .textCase(.uppercase)
            Spacer()
            // Numeric badge so the user can confirm at a glance that a
            // freshly-learned workflow landed in the library.
            if !workflowLibrary.workflowProfiles.isEmpty {
                Text("\(workflowLibrary.workflowProfiles.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    // MARK: - States

    private var learningInProgressState: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.75)
            Text("Learning workflow…")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("No workflows yet.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Text("Flip teach mode on and demonstrate one.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private var workflowList: some View {
        VStack(spacing: 4) {
            ForEach(workflowLibrary.workflowProfiles) { workflowProfile in
                WorkflowListRow(
                    workflowProfile: workflowProfile,
                    onRunTapped: {
                        workflowSelectedForRun = workflowProfile
                    }
                )
            }
        }
    }
}

/// One row in the workflow list. Pulled into its own struct so its hover
/// state doesn't invalidate sibling rows on each pointer movement.
private struct WorkflowListRow: View {
    let workflowProfile: SavedWorkflowProfile
    let onRunTapped: () -> Void

    @State private var isHovered: Bool = false

    /// Human-readable display name — falls back to the id if name is nil.
    private var displayName: String {
        workflowProfile.name ?? workflowProfile.id
    }

    /// "4 parameters" / "1 parameter" / "no parameters". Pluralization
    /// matters because a sentence-case row reads weird otherwise.
    private var parameterCountSubtitle: String {
        let parameterCount = workflowProfile.parameters.count
        if parameterCount == 0 { return "No parameters" }
        if parameterCount == 1 { return "1 parameter" }
        return "\(parameterCount) parameters"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.accentText)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(parameterCountSubtitle)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer()

            Button(action: onRunTapped) {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Run")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(DS.Colors.accent)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.06) : Color.white.opacity(0.04))
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
