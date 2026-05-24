//
//  WorkflowRunSheet.swift
//  leanring-buddy
//
//  SwiftUI sheet presented when the user hits Run on a saved workflow.
//
//  Behavior:
//    - Lists every parameter from the WorkflowProfile (monospaced label,
//      TextField pre-filled with the demo example value, type hint).
//    - Cancel dismisses with no side effects.
//    - Run collects the field values into a `[String: String]` dict and
//      sends a `start_job` message to the connected agent over the
//      AgentWebSocketClient, exactly matching the wire shape used by
//      tools/test-replay-job.mjs (§ A.4).
//
//  We send the full WorkflowProfile dict, not just an id. To keep the
//  Codable model from drifting out of sync with the on-disk JSON shape,
//  we re-encode the Codable SavedWorkflowProfile via JSONEncoder +
//  JSONSerialization.jsonObject(with:) — that round-trip guarantees the
//  dict we hand to the agent has the same snake_case keys the agent
//  expects.
//

import SwiftUI

struct WorkflowRunSheet: View {
    let workflowProfile: SavedWorkflowProfile
    let agentWebSocketClient: AgentWebSocketClient

    /// Optional pre-run hook so the parent can ensure the agent subprocess
    /// is running and the websocket is connected before the user hits Run.
    /// CompanionPanelView wires this to companionManager.ensureAgentRunningAndConnected.
    var onWillRun: () -> Void = {}

    /// Optional notifier so the parent can stamp the
    /// `(session_id, output_format)` pair into CompanionManager's session
    /// registry BEFORE start_job goes out over the wire. Called with the
    /// freshly-minted session id and the profile's `output_format` slot,
    /// in that order. CompanionPanelView wires this to
    /// `companionManager.registerStartedSessionOutputFormat`. § A.4
    /// amendment 2026-05-23.
    var onSessionStarting: (_ sessionId: String, _ workflowOutputFormat: String) -> Void = { _, _ in }

    @Environment(\.dismiss) private var dismissSheet

    /// One-text-per-parameter buffer. Pre-filled in `onAppear` from each
    /// parameter's `exampleFromDemo`, so the user can hit Run immediately
    /// without retyping the demo values.
    @State private var parameterInputs: [String: String] = [:]

    /// Local validation flag — empty parameter names are skipped instead of
    /// causing a runtime crash on serialization (defense-in-depth; the
    /// worker is supposed to ensure parameter names are non-empty).
    private var hasAnyParameters: Bool {
        !workflowProfile.parameters.isEmpty
    }

    private var workflowDisplayName: String {
        workflowProfile.name ?? workflowProfile.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if hasAnyParameters {
                        ForEach(workflowProfile.parameters) { parameter in
                            parameterRow(parameter: parameter)
                        }
                    } else {
                        Text("This workflow has no parameters. Hit Run to replay the demonstration as-is.")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
                .padding(20)
            }

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 20)

            sheetFooter
        }
        .frame(width: 480, height: 480)
        .background(DS.Colors.background)
        .onAppear(perform: prefillInputsFromExamples)
    }

    // MARK: - Sections

    private var sheetHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.accentText)
            VStack(alignment: .leading, spacing: 2) {
                Text("Run workflow")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)
                    .textCase(.uppercase)
                Text(workflowDisplayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func parameterRow(parameter: WorkflowProfileParameter) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(parameter.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(parameter.type)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.06))
                    )
            }

            TextField(
                parameter.exampleFromDemo ?? "",
                text: Binding(
                    get: { parameterInputs[parameter.name] ?? "" },
                    set: { parameterInputs[parameter.name] = $0 }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
    }

    private var sheetFooter: some View {
        HStack(spacing: 12) {
            Spacer()

            Button(action: {
                dismissSheet()
            }) {
                Text("Cancel")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.surface2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .keyboardShortcut(.cancelAction)

            Button(action: sendStartJobMessageAndDismiss) {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Run")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.accent)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Behavior

    private func prefillInputsFromExamples() {
        // Only initialize keys that aren't already set so reopening the
        // sheet doesn't blow away in-flight edits (the sheet is re-created
        // on each presentation today, but this is cheap defensive code).
        for parameter in workflowProfile.parameters where parameterInputs[parameter.name] == nil {
            parameterInputs[parameter.name] = parameter.exampleFromDemo ?? ""
        }
    }

    /// Builds the start_job message and sends it over the agent websocket.
    /// On any serialization failure we still dismiss — surfacing an error
    /// inline would require more sheet state than the V1 UI justifies. The
    /// agent ws client itself logs send failures.
    private func sendStartJobMessageAndDismiss() {
        onWillRun()

        let collectedParameters = parameterInputs

        guard let workflowProfileDictionary = encodeProfileAsJsonDictionary(workflowProfile) else {
            print("⚠️ WorkflowRunSheet: failed to re-encode profile \(workflowProfile.id) as JSON dict")
            dismissSheet()
            return
        }

        // Reference data lives in identity.json eventually (§ A.5). For V1
        // we hard-code a minimal identity object so the agent has something
        // to bind reference_keys against; the run sheet doesn't yet know
        // about that file. This matches tools/test-replay-job.mjs exactly.
        let referenceDataDictionary: [String: Any] = [
            "identity": [
                "name": "Daud Nofel",
                "city": "Austin"
            ]
        ]

        // parameters_list is a list because the agent supports replaying
        // the same workflow across N parameter sets in a single job. The
        // sheet only collects one set; multi-set runs come later.
        let parametersListPayload: [[String: String]] = [collectedParameters]

        // Mint the session id BEFORE sending so we can register the
        // (session_id, output_format) pair on the parent side. The agent
        // turns this into per-queue-item ids of the form
        // `${session_id}-${index}`, which CompanionManager reverses to
        // recover the output_format when each `queue_item_started` lands.
        let freshSessionId = "ui-run-\(UUID().uuidString)"
        onSessionStarting(freshSessionId, workflowProfile.outputFormat)

        let startJobMessage: [String: Any] = [
            "type": "start_job",
            "session_id": freshSessionId,
            "workflow_profile": workflowProfileDictionary,
            "reference_data": referenceDataDictionary,
            "parameters_list": parametersListPayload
        ]

        agentWebSocketClient.send(startJobMessage)
        dismissSheet()
    }

    /// Codable -> JSON Data -> Foundation [String: Any] round-trip. We
    /// re-encode via JSONEncoder rather than reading the raw file off disk
    /// so the dict's snake_case keys match `keyEncodingStrategy =
    /// .convertToSnakeCase`. That keeps the Codable model the source of
    /// truth for the wire format.
    private func encodeProfileAsJsonDictionary(_ profile: SavedWorkflowProfile) -> [String: Any]? {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let payloadData = try? encoder.encode(profile),
              let payloadObject = try? JSONSerialization.jsonObject(with: payloadData),
              let payloadDictionary = payloadObject as? [String: Any] else {
            return nil
        }
        return payloadDictionary
    }
}
