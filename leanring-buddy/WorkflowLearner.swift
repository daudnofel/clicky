//
//  WorkflowLearner.swift
//  leanring-buddy
//
//  Uploads a finished demonstration recording to the Cloudflare Worker's
//  POST /workflow/learn endpoint, decodes the returned WorkflowProfile,
//  and persists it via WorkflowLibrary.
//
//  Mirrors `tools/test-workflow-learn.mjs` exactly so the same multipart
//  shape is produced from Swift as from the Node reference script. The
//  worker is liberal about field order but strict about field names —
//  every change here must keep parity with that script.
//
//  The async/await lifecycle is:
//    1. Caller hits `learn(recordingDirectoryUrl:)` after the user toggles
//       teach mode off.
//    2. We synthesize a `multipart/form-data` body in memory (Swift has no
//       built-in multipart builder; we construct boundaries + bodies by
//       hand).
//    3. POST → decode `{ "profile": <SavedWorkflowProfile> }`.
//    4. Hand the profile to WorkflowLibrary.save(...) so the on-disk
//       file becomes the source of truth.
//    5. Update @Published flags so the menu bar UI can react.
//

import Combine
import Foundation

@MainActor
final class WorkflowLearner: ObservableObject {
    @Published private(set) var isLearning: Bool = false
    @Published private(set) var lastLearnedProfileName: String?
    @Published private(set) var lastLearnErrorMessage: String?

    /// Cloudflare Worker base URL. The full endpoint is
    /// `<workerBaseUrl>/workflow/learn`.
    private let workerBaseUrl: String

    /// Shared library — successful learns save into it; the panel observes
    /// it independently so the new row appears without us pushing it.
    private let workflowLibrary: WorkflowLibrary

    /// Dedicated URLSession with a generous timeout because /workflow/learn
    /// can take 30s+ on real recordings (Claude vision + multi-image).
    /// We don't use URLSession.shared because that shares a connection pool
    /// with streaming Claude / TTS calls and a long-running multipart POST
    /// can stall those.
    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 180   // 3 min
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    init(workerBaseURL: String, workflowLibrary: WorkflowLibrary) {
        self.workerBaseUrl = workerBaseURL
        self.workflowLibrary = workflowLibrary
    }

    /// Reads manifest.json + events.jsonl + transcript.json + every frame
    /// in `frames/`, posts the bundle to /workflow/learn, decodes the
    /// returned profile, and saves it to the WorkflowLibrary.
    ///
    /// Errors are surfaced via `lastLearnErrorMessage` rather than thrown
    /// — this is called from a fire-and-forget Task in CompanionManager
    /// after teach mode toggles off, and we don't want to crash the UI
    /// thread on a flaky Worker connection.
    func learn(recordingDirectoryUrl: URL) async {
        guard !isLearning else { return }
        isLearning = true
        lastLearnErrorMessage = nil
        defer { isLearning = false }

        do {
            let multipartPayload = try buildMultipartBody(recordingDirectoryUrl: recordingDirectoryUrl)

            guard let endpointUrl = URL(string: "\(workerBaseUrl)/workflow/learn") else {
                throw WorkflowLearnerError.invalidWorkerUrl(workerBaseUrl)
            }

            var request = URLRequest(url: endpointUrl)
            request.httpMethod = "POST"
            request.setValue(
                "multipart/form-data; boundary=\(multipartPayload.boundary)",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = multipartPayload.body

            print("📨 WorkflowLearner: POSTing \(multipartPayload.body.count) bytes to \(endpointUrl)")
            let (responseData, response) = try await urlSession.data(for: request)

            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(httpStatus) else {
                let responseBody = String(data: responseData, encoding: .utf8) ?? "<non-utf8>"
                throw WorkflowLearnerError.workerReturnedFailure(status: httpStatus, body: responseBody)
            }

            // The worker wraps the profile in `{ "profile": ... }`.
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let envelope = try decoder.decode(WorkflowLearnResponseEnvelope.self, from: responseData)
            let extractedProfile = envelope.profile

            try workflowLibrary.save(profile: extractedProfile)
            lastLearnedProfileName = extractedProfile.name ?? extractedProfile.id
            print("✅ WorkflowLearner: saved profile \(extractedProfile.id) (\(extractedProfile.name ?? "<unnamed>"))")
        } catch {
            lastLearnErrorMessage = error.localizedDescription
            print("⚠️ WorkflowLearner: \(error)")
        }
    }

    // MARK: - Multipart construction

    /// Tuple-like holder for the assembled multipart body + the boundary
    /// string we have to inject into the Content-Type header.
    private struct AssembledMultipartPayload {
        let boundary: String
        let body: Data
    }

    /// Builds a multipart/form-data body matching tools/test-workflow-learn.mjs:
    ///   - field `manifest` (text body of manifest.json)
    ///   - field `events`   (text body of events.jsonl)
    ///   - field `transcript` (text body of transcript.json)
    ///   - one File field per frame: name `frame_<NNNN>` (i.e. filename
    ///     with `.jpg` stripped), filename = original frame filename,
    ///     content-type = image/jpeg.
    ///
    /// The boundary is a random UUID-based string so it cannot accidentally
    /// appear in any of the payload bodies.
    private func buildMultipartBody(recordingDirectoryUrl: URL) throws -> AssembledMultipartPayload {
        let fileManager = FileManager.default
        let manifestUrl = recordingDirectoryUrl.appendingPathComponent("manifest.json")
        let eventsUrl = recordingDirectoryUrl.appendingPathComponent("events.jsonl")
        let transcriptUrl = recordingDirectoryUrl.appendingPathComponent("transcript.json")
        let framesDirectoryUrl = recordingDirectoryUrl.appendingPathComponent("frames", isDirectory: true)

        let manifestText = try String(contentsOf: manifestUrl, encoding: .utf8)
        let eventsText = try String(contentsOf: eventsUrl, encoding: .utf8)
        let transcriptText = try String(contentsOf: transcriptUrl, encoding: .utf8)

        let frameFiles: [URL]
        if fileManager.fileExists(atPath: framesDirectoryUrl.path) {
            frameFiles = try fileManager.contentsOfDirectory(
                at: framesDirectoryUrl,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        } else {
            frameFiles = []
        }

        // Use a clearly Clicky-prefixed boundary so it's identifiable in
        // request dumps and unique per request.
        let boundary = "----ClickyWorkflowLearnBoundary-\(UUID().uuidString)"
        var body = Data()

        appendTextPart(name: "manifest", value: manifestText, boundary: boundary, into: &body)
        appendTextPart(name: "events", value: eventsText, boundary: boundary, into: &body)
        appendTextPart(name: "transcript", value: transcriptText, boundary: boundary, into: &body)

        for frameFileUrl in frameFiles {
            let frameFilename = frameFileUrl.lastPathComponent
            let fieldNameWithoutExtension = frameFilename
                .replacingOccurrences(of: ".jpg", with: "")
                .replacingOccurrences(of: ".JPG", with: "")
            let fieldName = "frame_\(fieldNameWithoutExtension)"
            let frameData = try Data(contentsOf: frameFileUrl)
            appendFilePart(
                name: fieldName,
                filename: frameFilename,
                mimeType: "image/jpeg",
                fileData: frameData,
                boundary: boundary,
                into: &body
            )
        }

        // Closing boundary marker.
        if let trailerBytes = "--\(boundary)--\r\n".data(using: .utf8) {
            body.append(trailerBytes)
        }

        return AssembledMultipartPayload(boundary: boundary, body: body)
    }

    private func appendTextPart(
        name fieldName: String,
        value fieldValue: String,
        boundary: String,
        into body: inout Data
    ) {
        let header = """
        --\(boundary)\r
        Content-Disposition: form-data; name="\(fieldName)"\r
        \r

        """
        if let headerBytes = header.data(using: .utf8) {
            body.append(headerBytes)
        }
        if let valueBytes = fieldValue.data(using: .utf8) {
            body.append(valueBytes)
        }
        if let trailerBytes = "\r\n".data(using: .utf8) {
            body.append(trailerBytes)
        }
    }

    private func appendFilePart(
        name fieldName: String,
        filename: String,
        mimeType: String,
        fileData: Data,
        boundary: String,
        into body: inout Data
    ) {
        let header = """
        --\(boundary)\r
        Content-Disposition: form-data; name="\(fieldName)"; filename="\(filename)"\r
        Content-Type: \(mimeType)\r
        \r

        """
        if let headerBytes = header.data(using: .utf8) {
            body.append(headerBytes)
        }
        body.append(fileData)
        if let trailerBytes = "\r\n".data(using: .utf8) {
            body.append(trailerBytes)
        }
    }
}

// MARK: - Wire format

/// The Worker's /workflow/learn response wraps the profile in a top-level
/// `profile` field — matches the production Worker code.
private struct WorkflowLearnResponseEnvelope: Decodable {
    let profile: SavedWorkflowProfile
}

// MARK: - Errors

enum WorkflowLearnerError: LocalizedError {
    case invalidWorkerUrl(String)
    case workerReturnedFailure(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidWorkerUrl(let raw):
            return "Worker base URL is not a valid URL: \(raw)"
        case .workerReturnedFailure(let status, let body):
            return "Worker returned status \(status). Body: \(body.prefix(500))"
        }
    }
}
