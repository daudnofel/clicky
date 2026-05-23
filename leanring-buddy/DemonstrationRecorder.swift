//
//  DemonstrationRecorder.swift
//  leanring-buddy
//
//  Writes a teach-mode demonstration to disk in the format defined in
//  the apprentice-mode plan's § A.2:
//
//    ~/Library/Application Support/Clicky/recordings/<uuid>/
//      manifest.json
//      frames/NNNN.jpg
//      events.jsonl
//      transcript.json
//
//  Owned by TeachModeManager. The recorder mints a UUID on start(),
//  spawns a background screen capture loop, and serializes append(event:)
//  calls through a serial actor-isolated queue so the JSONL file is
//  monotonically time-ordered.
//
//  transcript.json is populated from the live AssemblyAI streaming
//  session driven by TeachModeTranscriptCollector. The collector hands
//  TeachModeManager a [TranscriptTurn] on stop, which TeachModeManager
//  forwards to setTranscriptTurnsForFinalize(_:) right before
//  calling stop() on the recorder. On empty narration the recorder
//  writes `{"turns": []}` — always a parseable shape for the worker.
//

import AppKit
import Foundation

struct RecordingManifest: Codable {
    let uuid: String
    let startedAt: Date
    var endedAt: Date?
    var appBundleId: String?
    var initialUrl: String?

    enum CodingKeys: String, CodingKey {
        // The § A.2 wire format names: started_at, ended_at, app, url_at_start.
        // In-Swift property names stay camelCase; this map keeps both happy.
        case uuid
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case appBundleId = "app"
        case initialUrl = "url_at_start"
    }
}

struct RecordingEvent: Codable {
    let t: Double
    let type: String
    var x: Int?
    var y: Int?
    var screenIndex: Int?
    var key: String?
    var value: String?
    var url: String?
    var filename: String?
    var fieldKind: String?

    enum CodingKeys: String, CodingKey {
        case t
        case type
        case x
        case y
        // Match the § A.2 wire format exactly — events.jsonl uses snake_case
        // for the screen-index and field-kind fields even though the in-Swift
        // property names are camelCase.
        case screenIndex = "screen_index"
        case key
        case value
        case url
        case filename
        case fieldKind = "field_kind"
    }
}

enum DemonstrationRecorderError: Error {
    case notRecording
    case alreadyRecording
    case couldNotCreateRecordingDirectory(URL, underlyingError: Error)
    case couldNotWriteManifest(URL, underlyingError: Error)
    case couldNotEncodeEvent(underlyingError: Error)
}

@MainActor
final class DemonstrationRecorder {
    private(set) var isRecording = false
    private(set) var currentRecordingDirectoryUrl: URL?

    private var recordingUuid: String = ""
    private var recordingStartWallClockTime: Date = Date()
    private var currentManifest: RecordingManifest?
    private var nextFrameIndex: Int = 0
    private var screenCaptureLoopTask: Task<Void, Never>?

    /// Transcript turns to write into transcript.json on stop(). Set by
    /// TeachModeManager via setTranscriptTurnsForFinalize(_:) right
    /// before it calls stop(). When nil or empty, stop() writes
    /// `{"turns": []}` instead of the legacy `{"placeholder": true}`
    /// payload so the worker always sees a parseable shape with a
    /// stable field. § A.2 transcript.json amendment 2026-05-23.
    private var pendingTranscriptTurnsForFinalize: [TranscriptTurn] = []

    /// JSONEncoder used for both manifest.json and events.jsonl. Configured
    /// with ISO-8601 dates so the wire format matches § A.2 exactly.
    private let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    func start(initialUrl: String?) async throws {
        guard !isRecording else {
            throw DemonstrationRecorderError.alreadyRecording
        }

        let newRecordingUuid = UUID().uuidString
        let recordingDirectoryUrl = Self.recordingsRootDirectoryUrl()
            .appendingPathComponent(newRecordingUuid, isDirectory: true)
        let framesDirectoryUrl = recordingDirectoryUrl.appendingPathComponent("frames", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: framesDirectoryUrl, withIntermediateDirectories: true)
        } catch {
            throw DemonstrationRecorderError.couldNotCreateRecordingDirectory(framesDirectoryUrl, underlyingError: error)
        }

        let startWallClockTime = Date()
        let manifest = RecordingManifest(
            uuid: newRecordingUuid,
            startedAt: startWallClockTime,
            endedAt: nil,
            appBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            initialUrl: initialUrl
        )
        try writeManifest(manifest, to: recordingDirectoryUrl)

        // Touch the events file so append(event:) can append even if the
        // first event arrives before the screen capture loop has produced one.
        let eventsFileUrl = recordingDirectoryUrl.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: eventsFileUrl.path) {
            FileManager.default.createFile(atPath: eventsFileUrl.path, contents: nil)
        }

        self.recordingUuid = newRecordingUuid
        self.recordingStartWallClockTime = startWallClockTime
        self.currentManifest = manifest
        self.currentRecordingDirectoryUrl = recordingDirectoryUrl
        self.nextFrameIndex = 0
        self.isRecording = true

        startScreenCaptureLoop(framesDirectoryUrl: framesDirectoryUrl)
    }

    func stop() async throws -> URL {
        guard isRecording, let recordingDirectoryUrl = currentRecordingDirectoryUrl else {
            throw DemonstrationRecorderError.notRecording
        }

        // Stop the screen capture loop first so no more frames sneak in
        // after the manifest's endedAt timestamp is finalized.
        screenCaptureLoopTask?.cancel()
        screenCaptureLoopTask = nil

        if var manifest = currentManifest {
            manifest.endedAt = Date()
            try writeManifest(manifest, to: recordingDirectoryUrl)
            currentManifest = manifest
        }

        // Write the captured AssemblyAI transcript turns to transcript.json
        // in the § A.2 wire format. If the collector handed us an empty
        // array (mic denied / user didn't speak / AssemblyAI errored),
        // we still write `{"turns": []}` so the worker side always sees
        // a stable shape — never the legacy `{"placeholder": true}`
        // payload. The pending-turns array is reset here so a recorder
        // instance can be reused for a second teach session safely.
        let transcriptUrl = recordingDirectoryUrl.appendingPathComponent("transcript.json")
        let transcriptFilePayload = TeachModeTranscriptFile(turns: pendingTranscriptTurnsForFinalize)
        let encodedTranscriptData = try jsonEncoder.encode(transcriptFilePayload)
        try encodedTranscriptData.write(to: transcriptUrl, options: .atomic)
        pendingTranscriptTurnsForFinalize = []

        isRecording = false
        let finishedRecordingDirectoryUrl = recordingDirectoryUrl
        currentRecordingDirectoryUrl = nil
        return finishedRecordingDirectoryUrl
    }

    /// Set by TeachModeManager just before it calls stop() so the
    /// recorder can write the real captured narration into
    /// transcript.json. Passing an empty array (or never calling this
    /// at all) writes `{"turns": []}` — always a parseable shape for
    /// the worker side.
    func setTranscriptTurnsForFinalize(_ turnsForFinalize: [TranscriptTurn]) {
        pendingTranscriptTurnsForFinalize = turnsForFinalize
    }

    /// Appends an event to events.jsonl. Caller does NOT supply the timestamp —
    /// the recorder stamps `t` itself from the recording's start time so the
    /// JSONL is monotonically ordered regardless of how the caller buffers.
    func append(event incomingEvent: RecordingEvent) async {
        guard isRecording, let recordingDirectoryUrl = currentRecordingDirectoryUrl else { return }

        var stampedEvent = incomingEvent
        // Honor a pre-stamped timestamp if the caller already computed one
        // (frame writer does this), otherwise stamp now.
        if stampedEvent.t == 0 {
            stampedEvent = RecordingEvent(
                t: Date().timeIntervalSince(recordingStartWallClockTime),
                type: incomingEvent.type,
                x: incomingEvent.x,
                y: incomingEvent.y,
                screenIndex: incomingEvent.screenIndex,
                key: incomingEvent.key,
                value: incomingEvent.value,
                url: incomingEvent.url,
                filename: incomingEvent.filename,
                fieldKind: incomingEvent.fieldKind
            )
        }

        do {
            let encodedEventData = try jsonEncoder.encode(stampedEvent)
            // events.jsonl is one JSON object per line — append the encoded
            // bytes followed by a single newline.
            var lineData = encodedEventData
            lineData.append(0x0A)
            try appendData(lineData, to: recordingDirectoryUrl.appendingPathComponent("events.jsonl"))
        } catch {
            print("⚠️ DemonstrationRecorder: failed to append event: \(error)")
        }
    }

    // MARK: - Private helpers

    private func startScreenCaptureLoop(framesDirectoryUrl: URL) {
        let loopRecordingStart = recordingStartWallClockTime
        screenCaptureLoopTask = Task { [weak self] in
            // Capture cadence: 2 fps, as specified in § A.2.
            let frameCadenceNanoseconds: UInt64 = 500_000_000
            while !Task.isCancelled {
                do {
                    let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                    // Write only the cursor screen's JPEG. Multi-monitor demos
                    // can be supported later; the worker side only consumes one
                    // frame stream right now.
                    let primaryCapture = screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
                    guard let primaryCapture else {
                        try? await Task.sleep(nanoseconds: frameCadenceNanoseconds)
                        continue
                    }

                    let frameIndex = await self?.takeNextFrameIndex() ?? 0
                    let frameFilename = String(format: "%04d.jpg", frameIndex)
                    let frameUrl = framesDirectoryUrl.appendingPathComponent(frameFilename)
                    do {
                        try primaryCapture.imageData.write(to: frameUrl, options: .atomic)
                        let timestampSinceStart = Date().timeIntervalSince(loopRecordingStart)
                        await self?.append(event: RecordingEvent(
                            t: timestampSinceStart,
                            type: "frame",
                            filename: frameFilename
                        ))
                    } catch {
                        print("⚠️ DemonstrationRecorder: failed to write frame \(frameFilename): \(error)")
                    }
                } catch is CancellationError {
                    return
                } catch {
                    print("⚠️ DemonstrationRecorder: capture failed: \(error)")
                }

                try? await Task.sleep(nanoseconds: frameCadenceNanoseconds)
            }
        }
    }

    private func takeNextFrameIndex() -> Int {
        let frameIndex = nextFrameIndex
        nextFrameIndex += 1
        return frameIndex
    }

    private func writeManifest(_ manifest: RecordingManifest, to recordingDirectoryUrl: URL) throws {
        let manifestFileUrl = recordingDirectoryUrl.appendingPathComponent("manifest.json")
        do {
            let manifestData = try jsonEncoder.encode(manifest)
            try manifestData.write(to: manifestFileUrl, options: .atomic)
        } catch {
            throw DemonstrationRecorderError.couldNotWriteManifest(manifestFileUrl, underlyingError: error)
        }
    }

    private func appendData(_ bytesToAppend: Data, to fileUrl: URL) throws {
        if !FileManager.default.fileExists(atPath: fileUrl.path) {
            try bytesToAppend.write(to: fileUrl, options: .atomic)
            return
        }
        let fileHandle = try FileHandle(forWritingTo: fileUrl)
        defer { try? fileHandle.close() }
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: bytesToAppend)
    }

    /// `~/Library/Application Support/Clicky/recordings/`. Created lazily by
    /// start(); we expose it as a static so other parts of the app (e.g. the
    /// future workflow library view) can enumerate prior recordings.
    static func recordingsRootDirectoryUrl() -> URL {
        let applicationSupportUrl = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupportUrl
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
    }
}
