//
//  TeachModeTranscriptCollector.swift
//  leanring-buddy
//
//  Drives a continuous (not push-to-talk) AssemblyAI streaming session
//  for the duration of a teach-mode demonstration so the recorder can
//  write a real voice transcript instead of the legacy
//  `{"placeholder": true}` payload.
//
//  Mirrors BuddyDictationManager's lifecycle (mic permission check ->
//  AssemblyAI provider session -> AVAudioEngine tap pumping PCM buffers
//  into the session). Differences:
//
//   1. The session is NOT bound to a key press; it stays open for the
//      full teach-mode duration and is torn down explicitly on stop().
//   2. We do NOT call requestFinalTranscript() to coax a single
//      final-blob result out of AssemblyAI. Instead we accumulate every
//      finalized turn (delivered via onTranscriptUpdate as the model
//      formats each turn) and snapshot them into TranscriptTurn structs
//      with start/end seconds relative to the recording wall-clock
//      start. Each turn becomes one row in the on-disk transcript.json.
//   3. We expose @Published mic state (isRecording, audio level, last
//      error) so the menu bar panel can render a "listening" indicator
//      next to the teach toggle row while a session is live.
//

import AVFoundation
import Combine
import Foundation

/// One finalized turn captured during a teach-mode recording. start/end
/// seconds are relative to the recordingStartWallClockTime passed into
/// start(), so they line up against the matching events.jsonl timeline.
/// Snake-case CodingKeys keep the on-disk transcript.json shape
/// consistent with the rest of the § A.2 wire format (events.jsonl and
/// manifest.json both use snake_case keys).
struct TranscriptTurn: Codable, Equatable {
    let startSeconds: Double
    let endSeconds: Double
    let text: String

    enum CodingKeys: String, CodingKey {
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
        case text
    }
}

/// Wire-format envelope for the on-disk transcript.json. The shape is
/// `{ "turns": [...] }` even when the array is empty (mic permission
/// denied, user didn't speak, AssemblyAI errored mid-session) so the
/// worker always sees a parseable JSON object with a stable field.
struct TeachModeTranscriptFile: Codable, Equatable {
    let turns: [TranscriptTurn]
}

@MainActor
final class TeachModeTranscriptCollector: ObservableObject {
    /// True between a successful start() and the subsequent stop().
    /// Surfaced to the UI so the teach-row subtitle can flip into a
    /// "listening" indicator.
    @Published private(set) var isRecording: Bool = false

    /// Live RMS audio level (0...1) from the active mic tap. The teach
    /// panel doesn't render a full waveform — it only checks
    /// isRecording — but we publish the level anyway so future UI work
    /// (e.g. a small bouncing bar next to the toggle) doesn't have to
    /// re-thread audio buffers through here.
    @Published private(set) var liveMicAudioLevel: Float = 0

    /// Surfaced for the menu bar panel's amber warning subtitle. Stays
    /// non-nil after a failed start/stop until the next start() clears
    /// it, so the user has time to read it.
    @Published private(set) var lastErrorMessage: String?

    private let transcriptionProvider: AssemblyAIStreamingTranscriptionProvider
    private let audioEngine = AVAudioEngine()
    private var activeTranscriptionSession: (any BuddyStreamingTranscriptionSession)?
    private var recordingStartWallClockTime: Date = Date()
    private var hasInstalledAudioTap: Bool = false

    /// Finalized turns captured so far in this session, indexed by the
    /// monotonic order the provider delivered them. Updated under the
    /// @MainActor; read into a sorted [TranscriptTurn] on stop().
    private var accumulatedTurnsInArrivalOrder: [TranscriptTurn] = []

    /// Cached "best-known" full transcript text the AssemblyAI provider
    /// has emitted via onTranscriptUpdate. Used to derive the latest
    /// turn's text when we don't have an explicit turn boundary — the
    /// existing AssemblyAI provider concatenates all formatted turns
    /// plus the in-flight unformatted turn into one string, so we
    /// diff against the previous snapshot to extract the newest segment.
    private var latestFullTranscriptText: String = ""

    /// The transcript text we had already committed into
    /// accumulatedTurnsInArrivalOrder. Used to detect when the
    /// provider's onTranscriptUpdate adds a freshly-finalized turn vs.
    /// just updating the active in-flight turn.
    ///
    /// The AssemblyAI provider's `composeFullTranscript()` joins all
    /// stored (finalized) turns with " " then appends the active
    /// (unfinalized) turn. So `latestFullTranscriptText` =
    /// `committedTranscriptText` + (" " + activeUnfinalizedTurnText)?.
    /// When committedTranscriptText grows, a new turn just finalized.
    private var committedTranscriptText: String = ""

    /// Wall-clock instant at which the first audio level / turn arrived
    /// for the current in-flight turn. Stamped from
    /// Date().timeIntervalSince(recordingStartWallClockTime) so we have
    /// approximate per-turn start timestamps even though AssemblyAI's
    /// public v3 API doesn't surface them directly.
    private var currentTurnStartSeconds: Double?

    /// The wall-clock instant the most recent committed turn ended.
    /// Used as the start fallback for the very next turn when we don't
    /// have a tighter signal.
    private var lastCommittedTurnEndSeconds: Double = 0

    init(
        transcriptionProvider: AssemblyAIStreamingTranscriptionProvider? = nil
    ) {
        // Defaults are constructed inside the @MainActor init body
        // instead of as default-arg expressions because Swift evaluates
        // default args in the caller's isolation context, which can be
        // nonisolated and fails to call into @MainActor-isolated
        // initializers. Same foot-gun pattern as TeachModeManager.
        self.transcriptionProvider = transcriptionProvider ?? AssemblyAIStreamingTranscriptionProvider()
    }

    /// Opens an AssemblyAI streaming session and starts the local mic
    /// tap. Throws if microphone permission is denied or the provider
    /// fails to come up.
    func start(recordingStartWallClockTime: Date) async throws {
        guard !isRecording else { return }

        lastErrorMessage = nil
        accumulatedTurnsInArrivalOrder.removeAll(keepingCapacity: false)
        latestFullTranscriptText = ""
        committedTranscriptText = ""
        currentTurnStartSeconds = nil
        lastCommittedTurnEndSeconds = 0
        self.recordingStartWallClockTime = recordingStartWallClockTime

        // Guard on microphone permission BEFORE we ask the provider to
        // open a websocket. The user may have denied mic access; the
        // push-to-talk path's permission flow runs the same checks in
        // BuddyDictationManager.requestMicrophonePermissionIfNeeded()
        // — we mirror it here so the teach-mode caller doesn't have to.
        let hasMicrophonePermission = await requestMicrophonePermissionIfNeeded()
        guard hasMicrophonePermission else {
            let microphonePermissionError = TeachModeTranscriptCollectorError.microphonePermissionDenied
            lastErrorMessage = microphonePermissionError.localizedDescription
            throw microphonePermissionError
        }

        do {
            let openedTranscriptionSession = try await transcriptionProvider.startStreamingSession(
                keyterms: [],
                onTranscriptUpdate: { [weak self] runningTranscriptText in
                    Task { @MainActor [weak self] in
                        self?.handleRunningTranscriptUpdate(runningTranscriptText)
                    }
                },
                onFinalTranscriptReady: { [weak self] _ in
                    // Teach mode never calls requestFinalTranscript(),
                    // so this callback only fires on session shutdown.
                    // We still flush any in-flight turn here as a
                    // belt-and-suspenders measure.
                    Task { @MainActor [weak self] in
                        self?.flushInFlightTurnIfAny()
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor [weak self] in
                        self?.handleTranscriptionError(error)
                    }
                }
            )
            self.activeTranscriptionSession = openedTranscriptionSession
        } catch {
            lastErrorMessage = "Voice transcription failed to start: \(error.localizedDescription)"
            throw error
        }

        do {
            try startAudioEngineAndInstallTap()
        } catch {
            // If the audio engine fails to come up after the provider
            // opened, tear down the provider so we don't leak a dangling
            // websocket that will never receive audio.
            activeTranscriptionSession?.cancel()
            activeTranscriptionSession = nil
            lastErrorMessage = "Microphone capture failed to start: \(error.localizedDescription)"
            throw error
        }

        isRecording = true
    }

    /// Tears down the AssemblyAI session and the mic tap, then returns
    /// the full ordered list of turns captured during this session.
    /// Always returns — never throws — because callers (the
    /// DemonstrationRecorder finalize path) treat an empty turns array
    /// as a soft failure and write `{"turns": []}` to disk regardless.
    func stop() async -> [TranscriptTurn] {
        guard isRecording else { return accumulatedTurnsInArrivalOrder }

        // Stop the mic tap first so no more PCM gets queued behind the
        // session we're about to cancel.
        if hasInstalledAudioTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledAudioTap = false
        }
        audioEngine.stop()

        // Snapshot any in-flight turn before we close the websocket so
        // we don't drop a partial-but-real narration the user gave at
        // the tail end of the recording.
        flushInFlightTurnIfAny()

        activeTranscriptionSession?.cancel()
        activeTranscriptionSession = nil

        isRecording = false
        liveMicAudioLevel = 0

        let finalizedTurns = accumulatedTurnsInArrivalOrder
        return finalizedTurns
    }

    // MARK: - Private — mic permission

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { isGranted in
                    continuation.resume(returning: isGranted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Private — audio engine

    private func startAudioEngineAndInstallTap() throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Defensive cleanup in case a prior session left a tap installed.
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] audioBuffer, _ in
            guard let self else { return }
            // appendAudioBuffer is nonisolated and safe to call from the
            // AVAudioEngine real-time callback thread.
            self.activeTranscriptionSession?.appendAudioBuffer(audioBuffer)
            self.updateLiveMicAudioLevelFromBuffer(audioBuffer)
        }
        hasInstalledAudioTap = true

        audioEngine.prepare()
        try audioEngine.start()
    }

    private nonisolated func updateLiveMicAudioLevelFromBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let channelData = audioBuffer.floatChannelData else { return }

        let channelSamples = channelData[0]
        let frameCount = Int(audioBuffer.frameLength)
        guard frameCount > 0 else { return }

        var summedSquares: Float = 0
        for sampleIndex in 0..<frameCount {
            let sample = channelSamples[sampleIndex]
            summedSquares += sample * sample
        }

        let rootMeanSquare = sqrt(summedSquares / Float(frameCount))
        let boostedLevel = min(max(rootMeanSquare * 10.2, 0), 1)

        // Cross back to the main actor to publish. The teach-mode UI
        // only renders this at a coarse cadence (subtitle text), so the
        // per-buffer hop is harmless even at 1024-sample buffer sizes.
        Task { @MainActor [weak self] in
            self?.liveMicAudioLevel = boostedLevel
        }
    }

    // MARK: - Private — transcript accumulation

    /// AssemblyAI's provider concatenates committed turns + the active
    /// in-flight turn into a single running string. When that string
    /// shrinks-to-grow (e.g. a turn finalized + a new one started),
    /// or its committed-prefix lengthens, we know a turn just
    /// transitioned from in-flight to finalized — capture it as a
    /// TranscriptTurn at that moment.
    private func handleRunningTranscriptUpdate(_ runningTranscriptText: String) {
        let trimmedRunningTranscriptText = runningTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Stamp a start time for the current turn the first time we see
        // any content for it.
        if currentTurnStartSeconds == nil && !trimmedRunningTranscriptText.isEmpty {
            currentTurnStartSeconds = max(
                lastCommittedTurnEndSeconds,
                Date().timeIntervalSince(recordingStartWallClockTime)
            )
        }

        // Detect a new commitment: if the running text's prefix that
        // matches our committed prefix grew, the new substring is a
        // finalized turn that just dropped.
        if trimmedRunningTranscriptText.count > committedTranscriptText.count
            && trimmedRunningTranscriptText.hasPrefix(committedTranscriptText)
            && trimmedRunningTranscriptText != latestFullTranscriptText {
            // Don't commit a turn yet — we wait for the running text
            // to STOP changing on the trailing edge. The simplest
            // heuristic: when the active unfinalized portion is empty
            // (running text == committed prefix), nothing new is
            // pending. We capture turns at flush points instead — see
            // commitTurnIfCommittedPrefixGrew below.
        }

        commitTurnIfCommittedPrefixGrew(against: trimmedRunningTranscriptText)
        latestFullTranscriptText = trimmedRunningTranscriptText
    }

    /// If the provider's running transcript grew its committed prefix
    /// since the last update, the delta is one or more newly-finalized
    /// turns. Append each as its own TranscriptTurn.
    ///
    /// We approximate per-turn time bounds — AssemblyAI v3's public API
    /// doesn't return per-turn start/end timestamps directly via the
    /// websocket envelopes we currently parse. Worst case the bounds
    /// drift a second; for downstream prompt extraction (Claude reads
    /// the transcript as text) this is good enough.
    private func commitTurnIfCommittedPrefixGrew(against latestRunningTranscriptText: String) {
        // A heuristic for "committed prefix" without modifying the
        // existing provider: assume the previous full text was the
        // committed prefix (since AssemblyAI keeps emitting the same
        // formatted text once a turn finalizes — only the in-flight
        // suffix mutates). When the new running text is shorter or
        // diverges from the previous, the old in-flight suffix has
        // been formalized into the committed prefix.
        //
        // In practice this catches the common case: turn 0 finalizes,
        // turn 1 starts. The running text for turn 1 begins with the
        // formatted turn 0 text, which is longer than what we'd
        // committed before.

        guard latestRunningTranscriptText.count >= committedTranscriptText.count else {
            // The running text shrank — AssemblyAI does this when an
            // in-flight unformatted turn gets dropped/re-emitted. Don't
            // commit; wait for it to recover.
            return
        }

        if latestRunningTranscriptText == committedTranscriptText {
            return
        }

        // If the running text added a new suffix beyond what we've
        // committed, that suffix is the freshly-finalized turn(s) plus
        // the new in-flight turn. We can't separate those two without
        // peeking inside the provider — but we CAN say: at the moment
        // the user STOPS narrating (between sentences), the running
        // text stops changing for ~300ms. That gap is when a turn
        // formalized. For an MVP, we just commit the whole new suffix
        // as ONE turn the moment we see a >=10-char delta or the
        // string contains a sentence-end punctuation. This trades a
        // small bit of turn granularity for never dropping content.

        let newSuffixText: String = {
            if latestRunningTranscriptText.hasPrefix(committedTranscriptText) {
                let suffixStartIndex = latestRunningTranscriptText.index(
                    latestRunningTranscriptText.startIndex,
                    offsetBy: committedTranscriptText.count
                )
                return String(latestRunningTranscriptText[suffixStartIndex...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return latestRunningTranscriptText
        }()

        let containsSentenceEndPunctuation = newSuffixText.contains(".")
            || newSuffixText.contains("?")
            || newSuffixText.contains("!")

        let suffixIsLongEnoughToCommit = newSuffixText.count >= 24

        guard containsSentenceEndPunctuation || suffixIsLongEnoughToCommit else {
            return
        }

        appendNewTurn(
            text: newSuffixText,
            forceEndSecondsAtNow: true
        )
        committedTranscriptText = latestRunningTranscriptText
    }

    /// On stop(), commit anything that's still in flight as a final
    /// turn even if the heuristic above hasn't fired for it yet. This
    /// guarantees the user's last sentence makes it into the file.
    private func flushInFlightTurnIfAny() {
        let trimmedLatest = latestFullTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLatest.count > committedTranscriptText.count else { return }

        let suffixStart = trimmedLatest.index(
            trimmedLatest.startIndex,
            offsetBy: committedTranscriptText.count
        )
        let suffixText = String(trimmedLatest[suffixStart...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suffixText.isEmpty else { return }

        appendNewTurn(text: suffixText, forceEndSecondsAtNow: true)
        committedTranscriptText = trimmedLatest
    }

    private func appendNewTurn(text turnText: String, forceEndSecondsAtNow: Bool) {
        let nowSeconds = Date().timeIntervalSince(recordingStartWallClockTime)
        let startSeconds = currentTurnStartSeconds ?? lastCommittedTurnEndSeconds
        let endSeconds = forceEndSecondsAtNow
            ? max(nowSeconds, startSeconds)
            : nowSeconds

        let committedTurn = TranscriptTurn(
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            text: turnText
        )
        accumulatedTurnsInArrivalOrder.append(committedTurn)
        lastCommittedTurnEndSeconds = endSeconds
        currentTurnStartSeconds = nil
    }

    private func handleTranscriptionError(_ error: Error) {
        lastErrorMessage = "Voice transcription error: \(error.localizedDescription)"
        // Don't auto-stop the recording — teach mode keeps capturing
        // events / frames even when narration breaks. The caller
        // (TeachModeManager) flips off when the user toggles teach off.
        // We do, however, tear down the dead websocket session so we
        // don't keep pumping audio buffers into nothing.
        activeTranscriptionSession?.cancel()
        activeTranscriptionSession = nil
    }
}

enum TeachModeTranscriptCollectorError: LocalizedError {
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is required to capture narration."
        }
    }
}
