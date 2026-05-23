//
//  TeachModeManager.swift
//  leanring-buddy
//
//  Owns the teach-mode lifecycle: starts the demonstration recorder,
//  installs the global event capture tap, and exposes ObservableObject
//  state so the menu bar panel can render a single "Teach me a workflow"
//  toggle.
//
//  This sits between CompanionPanelView (the UI) and
//  DemonstrationRecorder / EventCaptureTap (the plumbing). Wiring the
//  AssemblyAI live transcript into the recording is deferred per the
//  apprentice-mode plan's Task 3 Step 4 — transcript.json is written
//  as a placeholder for now.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class TeachModeManager: ObservableObject {
    @Published private(set) var isActive: Bool = false
    @Published private(set) var lastRecordingDirectoryUrl: URL?
    @Published private(set) var lastTeachModeErrorMessage: String?

    private let demonstrationRecorder: DemonstrationRecorder
    private let eventCaptureTap: EventCaptureTap

    // Defaults are constructed inside the @MainActor init body instead of as
    // default-arg expressions because Swift evaluates default args in the
    // caller's isolation context, which can be nonisolated and fails to
    // call into @MainActor-isolated initializers like DemonstrationRecorder().
    init(
        demonstrationRecorder: DemonstrationRecorder? = nil,
        eventCaptureTap: EventCaptureTap? = nil
    ) {
        self.demonstrationRecorder = demonstrationRecorder ?? DemonstrationRecorder()
        self.eventCaptureTap = eventCaptureTap ?? EventCaptureTap()
    }

    func startTeaching(initialUrl: String?) async {
        guard !isActive else { return }
        lastTeachModeErrorMessage = nil

        do {
            try await demonstrationRecorder.start(initialUrl: initialUrl)
        } catch {
            lastTeachModeErrorMessage = "Could not start teach mode: \(error.localizedDescription)"
            print("⚠️ TeachModeManager: failed to start demonstration recorder: \(error)")
            return
        }

        let recordingStartWallClockTime = Date()
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
}
