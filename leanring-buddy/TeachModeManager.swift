//
//  TeachModeManager.swift
//  leanring-buddy
//
//  Owns the teach-mode lifecycle: starts the demonstration recorder,
//  installs the global event capture tap, drives the live AssemblyAI
//  transcript collector, and exposes ObservableObject state so the menu
//  bar panel can render a single "Teach me a workflow" toggle.
//
//  This sits between CompanionPanelView (the UI) and
//  DemonstrationRecorder / EventCaptureTap / TeachModeTranscriptCollector
//  (the plumbing). The transcript collector pulls live narration from
//  AssemblyAI and hands a [TranscriptTurn] array to the recorder on
//  stop, which writes it to transcript.json in the § A.2 wire format.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class TeachModeManager: ObservableObject {
    @Published private(set) var isActive: Bool = false
    @Published private(set) var lastRecordingDirectoryUrl: URL?
    @Published private(set) var lastTeachModeErrorMessage: String?

    /// Mirrors `transcriptCollector.isRecording` via a Combine
    /// subscription so the CompanionPanelView teach row can flip its
    /// subtitle to a "listening" indicator without depending on the
    /// collector directly.
    @Published private(set) var isVoiceTranscriptActive: Bool = false

    /// Mirrors `transcriptCollector.lastErrorMessage`. When non-nil the
    /// teach row shows a small amber warning subtitle under the toggle
    /// ("Voice transcription failed: ... — proceeding without narration").
    @Published private(set) var lastVoiceTranscriptError: String?

    private let demonstrationRecorder: DemonstrationRecorder
    private let eventCaptureTap: EventCaptureTap
    private let transcriptCollector: TeachModeTranscriptCollector

    /// Subscriptions that re-publish the transcript collector's state
    /// onto our own @Published surface. Lives for the lifetime of the
    /// TeachModeManager instance.
    private var transcriptCollectorIsRecordingObservation: AnyCancellable?
    private var transcriptCollectorErrorObservation: AnyCancellable?

    // Defaults are constructed inside the @MainActor init body instead of as
    // default-arg expressions because Swift evaluates default args in the
    // caller's isolation context, which can be nonisolated and fails to
    // call into @MainActor-isolated initializers like DemonstrationRecorder().
    init(
        demonstrationRecorder: DemonstrationRecorder? = nil,
        eventCaptureTap: EventCaptureTap? = nil,
        transcriptCollector: TeachModeTranscriptCollector? = nil
    ) {
        self.demonstrationRecorder = demonstrationRecorder ?? DemonstrationRecorder()
        self.eventCaptureTap = eventCaptureTap ?? EventCaptureTap()
        self.transcriptCollector = transcriptCollector ?? TeachModeTranscriptCollector()

        bindTranscriptCollectorState()
    }

    func startTeaching(initialUrl: String?) async {
        guard !isActive else { return }
        lastTeachModeErrorMessage = nil
        lastVoiceTranscriptError = nil

        do {
            try await demonstrationRecorder.start(initialUrl: initialUrl)
        } catch {
            lastTeachModeErrorMessage = "Could not start teach mode: \(error.localizedDescription)"
            print("⚠️ TeachModeManager: failed to start demonstration recorder: \(error)")
            return
        }

        let recordingStartWallClockTime = Date()

        // Kick off the AssemblyAI live transcript collector. We do NOT
        // fail the entire teach session if narration fails to start —
        // the user may have denied mic access, AssemblyAI may be down,
        // etc. The recording continues with an empty `turns` array.
        // lastVoiceTranscriptError surfaces the failure to the UI.
        do {
            try await transcriptCollector.start(recordingStartWallClockTime: recordingStartWallClockTime)
        } catch {
            // lastVoiceTranscriptError is also mirrored via the Combine
            // observation below — but the collector clears its
            // lastErrorMessage on each start, so we restamp it here so
            // the user sees the failure even if Combine hasn't ticked.
            lastVoiceTranscriptError = "Voice transcription failed: \(error.localizedDescription) — proceeding without narration."
            print("⚠️ TeachModeManager: failed to start transcript collector: \(error)")
        }

        eventCaptureTap.onEventCaptured = { [weak self] capturedEvent in
            guard let self else { return }
            // The tap callback is already on the main thread but we still
            // need to cross into the actor-isolated recorder.
            Task { @MainActor [weak self] in
                await self?.demonstrationRecorder.append(event: capturedEvent)
            }
        }
        eventCaptureTap.install(recordingStartWallClockTime: recordingStartWallClockTime)

        isActive = true
    }

    func stopTeaching() async -> URL? {
        guard isActive else { return nil }

        eventCaptureTap.uninstall()
        eventCaptureTap.onEventCaptured = nil

        // Stop the transcript collector BEFORE we finalize the recorder
        // so any tail-end narration (the user's last sentence) is
        // captured into the turns array. The collector's stop() never
        // throws — an empty array is a valid result.
        let capturedTranscriptTurns = await transcriptCollector.stop()

        // Hand the captured turns to the recorder so it writes
        // transcript.json with the real data instead of the legacy
        // `{"placeholder": true}` payload.
        demonstrationRecorder.setTranscriptTurnsForFinalize(capturedTranscriptTurns)

        do {
            let finishedRecordingDirectoryUrl = try await demonstrationRecorder.stop()
            lastRecordingDirectoryUrl = finishedRecordingDirectoryUrl
            isActive = false
            return finishedRecordingDirectoryUrl
        } catch {
            lastTeachModeErrorMessage = "Could not finalize teach-mode recording: \(error.localizedDescription)"
            print("⚠️ TeachModeManager: failed to stop demonstration recorder: \(error)")
            isActive = false
            return nil
        }
    }

    // MARK: - Private

    private func bindTranscriptCollectorState() {
        transcriptCollectorIsRecordingObservation = transcriptCollector
            .$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isCurrentlyRecording in
                self?.isVoiceTranscriptActive = isCurrentlyRecording
            }

        transcriptCollectorErrorObservation = transcriptCollector
            .$lastErrorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] latestErrorMessage in
                // Only adopt non-nil messages so a successful start
                // (which clears the collector's error to nil) doesn't
                // wipe an error message we already showed the user.
                guard let latestErrorMessage else { return }
                self?.lastVoiceTranscriptError = latestErrorMessage
            }
    }
}
