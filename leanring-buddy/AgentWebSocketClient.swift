//
//  AgentWebSocketClient.swift
//  leanring-buddy
//
//  Local websocket client that talks to the spawned `clicky-agent` Node
//  subprocess on ws://127.0.0.1:<port>/. The protocol (defined in the
//  apprentice-mode implementation plan § A.4) is JSON-text in both
//  directions.
//
//  The client decodes Node → Swift messages into @Published state:
//    - `latestFrame` for the POV window image stream
//    - `queueItems` for the menu bar badge + the future Review Queue panel
//    - `connected` for general health
//
//  Swift → Node messages are sent via `send(_:)`. Senders construct the
//  JSON dictionary themselves — there's only a small handful of outbound
//  message shapes and they may grow, so a dictionary keeps the call sites
//  flexible without us having to maintain a parallel enum.
//

import AppKit
import Combine
import Foundation

/// One queue item as tracked from agent events. Mirrors § A.4 fields.
///
/// `submitSelector` is a first-class top-level field per the 2026-05-22
/// contract amendment in Section C — it must NOT be smuggled inside
/// `filledFields`, because a real web form could literally contain a
/// field named "submit_selector" and stomp the metadata.
struct QueueItemViewModel: Identifiable, Equatable {
    enum Status: String {
        case drafting
        case ready
        case approved
        case submitted
        case failed
        case discarded
    }

    let id: String
    var status: Status
    var jobUrl: String?
    var companyGuess: String?
    var draftedText: String?
    var filledFields: [String: String]
    var submitSelector: String?
    /// Populated on `queue_item_ready` for workflows whose
    /// `output_format == "results-list"`. § A.4 amendment 2026-05-23.
    /// `nil` for review-queue-card workflows so the existing
    /// ApplicationCard path is undisturbed.
    var results: [ResultsListItem]?
    var lastIntent: String?
    var lastErrorMessage: String?
    var resultMessage: String?
    var updatedAt: Date
}

/// One of the queue-event message types from § A.4. The websocket
/// client publishes these to subscribers (e.g. CompanionManager) so
/// downstream side-effects — like writing the apprentice-mode SQLite
/// store — can react to the same stream that drives `queueItems`
/// without us having to fork the decoding logic.
enum AgentQueueEvent {
    case started(queueId: String, jobUrl: String?, companyGuess: String?)
    case progress(queueId: String, step: Int?, intent: String?)
    /// `results` is the § A.4 amendment 2026-05-23 peer to `submitSelector`.
    /// Populated for results-list workflows; nil for review-queue-card
    /// workflows. Both fields can coexist in principle, though in practice
    /// a workflow is one mode or the other.
    case ready(
        queueId: String,
        draftedText: String?,
        filledFields: [String: String],
        submitSelector: String?,
        results: [ResultsListItem]?
    )
    case submitted(queueId: String, didSucceed: Bool, resultMessage: String?)
    case errored(queueId: String, errorMessage: String?)
}

@MainActor
final class AgentWebSocketClient: ObservableObject {
    @Published private(set) var latestFrame: NSImage?
    @Published private(set) var queueItems: [QueueItemViewModel] = []
    @Published private(set) var connected: Bool = false
    @Published private(set) var lastConnectionErrorMessage: String?

    /// Optional sink for queue-event side effects (e.g. SQLite persist).
    /// Kept as a single closure rather than a Combine publisher because
    /// the apprentice-mode review queue is the only consumer today and
    /// a closure is a quarter as much code. If we add a second consumer,
    /// swap this for a PassthroughSubject.
    var onQueueEvent: ((AgentQueueEvent) -> Void)?

    /// Most-recently-used port; persisted so reconnect attempts know
    /// where to dial after a transient drop.
    private var currentWebSocketPort: Int?
    private var currentWebSocketTask: URLSessionWebSocketTask?

    /// We keep a dedicated URLSession because the global shared session
    /// is reused for ElevenLabs / Claude streaming and a stray ws upgrade
    /// shouldn't trip up that pool's keepalives.
    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    // MARK: - Lifecycle

    /// Opens (or replaces) the websocket connection.
    /// Idempotent: calling repeatedly on the same port reuses the existing task.
    func connect(port: Int) {
        if let existingTask = currentWebSocketTask,
           existingTask.state == .running,
           currentWebSocketPort == port {
            return
        }

        currentWebSocketTask?.cancel(with: .goingAway, reason: nil)
        currentWebSocketTask = nil
        // A user-initiated connect cancels any pending caller-disconnect state
        // so the auto-reconnect loop is allowed to fire on receive failures.
        isExplicitlyDisconnected = false

        guard let url = URL(string: "ws://127.0.0.1:\(port)/") else {
            lastConnectionErrorMessage = "Invalid websocket URL for port \(port)"
            return
        }

        currentWebSocketPort = port
        let newTask = urlSession.webSocketTask(with: url)
        currentWebSocketTask = newTask
        newTask.resume()
        connected = true
        lastConnectionErrorMessage = nil
        beginReceiveLoop(for: newTask)
    }

    func disconnect() {
        isExplicitlyDisconnected = true
        pendingReconnectTask?.cancel()
        pendingReconnectTask = nil
        currentWebSocketTask?.cancel(with: .normalClosure, reason: nil)
        currentWebSocketTask = nil
        connected = false
    }

    /// True only when `disconnect()` was called by application code. The
    /// auto-reconnect path checks this so we don't reconnect after the user
    /// has explicitly turned the POV window off.
    private var isExplicitlyDisconnected: Bool = false

    /// Pending sleep-then-reconnect work. Cancelled on disconnect or replaced
    /// when a fresh reconnect is scheduled (we never want two concurrent
    /// reconnect attempts racing the same port).
    private var pendingReconnectTask: Task<Void, Never>?

    /// Schedules a reconnect attempt after a short delay. Called from the
    /// receive loop's `.failure` branch so the first connect (which usually
    /// races the agent subprocess's port bind) recovers automatically once
    /// the node process is actually listening.
    private func scheduleReconnectIfNeeded() {
        guard !isExplicitlyDisconnected, let portToRetry = currentWebSocketPort else {
            return
        }
        pendingReconnectTask?.cancel()
        // Capture the port at schedule time so a later connect(port:) with a
        // different port doesn't accidentally retry against the stale one.
        let pinnedPort = portToRetry
        pendingReconnectTask = Task { @MainActor [weak self] in
            // 500ms is enough for a fresh `node dist/index.js` to bind the
            // port; it's also short enough that the user's eye doesn't catch
            // the gap between "agent idle" and the first frame arriving.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self,
                  !Task.isCancelled,
                  !self.isExplicitlyDisconnected else { return }
            print("🔁 AgentWebSocketClient reconnecting to port \(pinnedPort) ...")
            self.connect(port: pinnedPort)
        }
    }

    // MARK: - Sending

    /// Encodes `outgoingMessage` as JSON and sends it. Errors are logged
    /// but not thrown — websocket sends are fire-and-forget at the call sites
    /// (e.g. tapping Approve on a queue card), and surfacing them as throws
    /// just litters those call sites with try/do/catch.
    func send(_ outgoingMessage: [String: Any]) {
        guard let task = currentWebSocketTask else {
            print("⚠️ AgentWebSocketClient.send called without an active connection")
            return
        }
        do {
            let payload = try JSONSerialization.data(withJSONObject: outgoingMessage)
            guard let payloadString = String(data: payload, encoding: .utf8) else {
                print("⚠️ AgentWebSocketClient: could not utf8-encode outbound payload")
                return
            }
            // Send as text since the Node server uses `JSON.parse(raw.toString())`
            // and works on either a Buffer or a string — text is the clearer
            // intent.
            task.send(.string(payloadString)) { sendError in
                if let sendError {
                    print("⚠️ AgentWebSocketClient send error: \(sendError)")
                }
            }
        } catch {
            print("⚠️ AgentWebSocketClient: could not JSON-encode outbound message: \(error)")
        }
    }

    // MARK: - Receive Loop

    /// Drives the read pump. URLSession's receive completion fires once per
    /// inbound frame, so we have to keep re-arming after every message.
    private func beginReceiveLoop(for receivingTask: URLSessionWebSocketTask) {
        receivingTask.receive { [weak self] receiveResult in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // If the task we got a result for is no longer the current one
                // (because someone called disconnect/connect in between),
                // drop the result silently rather than stomping new state.
                guard receivingTask === self.currentWebSocketTask else { return }

                switch receiveResult {
                case .success(let incomingMessage):
                    self.handleIncoming(message: incomingMessage)
                    // Re-arm receive for the next message.
                    self.beginReceiveLoop(for: receivingTask)
                case .failure(let receiveError):
                    print("⚠️ AgentWebSocketClient receive error: \(receiveError)")
                    self.connected = false
                    self.lastConnectionErrorMessage = receiveError.localizedDescription
                    // The first connect typically races the node subprocess
                    // binding its port — schedule a delayed retry so frames
                    // start flowing once the agent is actually listening.
                    self.scheduleReconnectIfNeeded()
                }
            }
        }
    }

    private func handleIncoming(message: URLSessionWebSocketTask.Message) {
        let payloadData: Data
        switch message {
        case .data(let rawData):
            payloadData = rawData
        case .string(let rawString):
            guard let stringEncodedData = rawString.data(using: .utf8) else { return }
            payloadData = stringEncodedData
        @unknown default:
            return
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let messageType = jsonObject["type"] as? String else {
            print("⚠️ AgentWebSocketClient: dropped malformed inbound message")
            return
        }

        switch messageType {
        case "frame":
            handleFrameMessage(jsonObject)
        case "queue_item_started":
            handleQueueItemStartedMessage(jsonObject)
        case "queue_item_progress":
            handleQueueItemProgressMessage(jsonObject)
        case "queue_item_ready":
            handleQueueItemReadyMessage(jsonObject)
        case "queue_item_submitted":
            handleQueueItemSubmittedMessage(jsonObject)
        case "error":
            handleAgentErrorMessage(jsonObject)
        default:
            print("⚠️ AgentWebSocketClient: unknown message type \(messageType)")
        }
    }

    // MARK: - Message Handlers

    private func handleFrameMessage(_ json: [String: Any]) {
        guard let base64EncodedJpeg = json["jpeg_b64"] as? String,
              let rawJpegData = Data(base64Encoded: base64EncodedJpeg),
              let decodedImage = NSImage(data: rawJpegData) else {
            return
        }
        latestFrame = decodedImage
    }

    private func handleQueueItemStartedMessage(_ json: [String: Any]) {
        guard let queueId = json["queue_id"] as? String else { return }
        let jobUrl = json["job_url"] as? String
        let companyGuess = json["company_guess"] as? String
        upsertQueueItem(id: queueId) { existingItem in
            var mutated = existingItem ?? QueueItemViewModel(
                id: queueId,
                status: .drafting,
                jobUrl: nil,
                companyGuess: nil,
                draftedText: nil,
                filledFields: [:],
                submitSelector: nil,
                results: nil,
                lastIntent: nil,
                lastErrorMessage: nil,
                resultMessage: nil,
                updatedAt: Date()
            )
            mutated.status = .drafting
            mutated.jobUrl = jobUrl ?? mutated.jobUrl
            mutated.companyGuess = companyGuess ?? mutated.companyGuess
            mutated.updatedAt = Date()
            return mutated
        }
        // Side-channel notification so downstream side-effects (SQLite,
        // analytics, etc.) can react without each one having to re-decode
        // the wire format.
        onQueueEvent?(.started(
            queueId: queueId,
            jobUrl: jobUrl,
            companyGuess: companyGuess
        ))
    }

    private func handleQueueItemProgressMessage(_ json: [String: Any]) {
        guard let queueId = json["queue_id"] as? String else { return }
        let stepIndex = json["step"] as? Int
        let intentString = json["intent"] as? String
        upsertQueueItem(id: queueId) { existingItem in
            guard var mutated = existingItem else { return nil }
            mutated.lastIntent = intentString ?? mutated.lastIntent
            mutated.updatedAt = Date()
            return mutated
        }
        onQueueEvent?(.progress(
            queueId: queueId,
            step: stepIndex,
            intent: intentString
        ))
    }

    private func handleQueueItemReadyMessage(_ json: [String: Any]) {
        guard let queueId = json["queue_id"] as? String else { return }
        let draftedText = json["drafted_text"] as? String
        var coercedFilledFields: [String: String] = [:]
        if let filledFieldsRaw = json["filled_fields"] as? [String: Any] {
            // The wire format permits arbitrary JSON values; the Swift
            // model coerces everything to String since downstream UI
            // displays them as plain text.
            for (fieldKey, fieldValue) in filledFieldsRaw {
                if let stringValue = fieldValue as? String {
                    coercedFilledFields[fieldKey] = stringValue
                } else {
                    coercedFilledFields[fieldKey] = String(describing: fieldValue)
                }
            }
        }
        // submit_selector is a first-class field per § A.4 amendment.
        let submitSelector = json["submit_selector"] as? String

        // `results` peer field — § A.4 amendment 2026-05-23. Decoded
        // here from the raw JSON via JSONSerialization → JSONDecoder
        // round-trip so the ResultsListItem Codable struct stays the
        // single source of truth for the wire shape (no parallel
        // hand-decode path that could drift out of sync).
        let decodedResults: [ResultsListItem]? = {
            guard let rawResultsArray = json["results"] as? [[String: Any]] else {
                return nil
            }
            // Re-serialize the array fragment to Data so JSONDecoder can
            // own the actual key/type validation. Worker has already
            // sanitized the payload but we still trust JSONDecoder over
            // hand-rolling per-field guards in Swift.
            guard let rawResultsData = try? JSONSerialization.data(withJSONObject: rawResultsArray),
                  let decodedArray = try? JSONDecoder().decode([ResultsListItem].self, from: rawResultsData) else {
                print("⚠️ AgentWebSocketClient: queue_item_ready.results failed to decode; ignoring")
                return nil
            }
            return decodedArray
        }()

        upsertQueueItem(id: queueId) { existingItem in
            var mutated = existingItem ?? QueueItemViewModel(
                id: queueId,
                status: .ready,
                jobUrl: nil,
                companyGuess: nil,
                draftedText: nil,
                filledFields: [:],
                submitSelector: nil,
                results: nil,
                lastIntent: nil,
                lastErrorMessage: nil,
                resultMessage: nil,
                updatedAt: Date()
            )
            mutated.status = .ready
            mutated.draftedText = draftedText ?? mutated.draftedText
            if !coercedFilledFields.isEmpty {
                mutated.filledFields = coercedFilledFields
            }
            mutated.submitSelector = submitSelector ?? mutated.submitSelector
            // Only overwrite results when the agent actually emitted them.
            // A late-arriving second .ready event without a results field
            // shouldn't blow away an earlier list.
            if let decodedResults {
                mutated.results = decodedResults
            }
            mutated.updatedAt = Date()
            return mutated
        }
        onQueueEvent?(.ready(
            queueId: queueId,
            draftedText: draftedText,
            filledFields: coercedFilledFields,
            submitSelector: submitSelector,
            results: decodedResults
        ))
    }

    private func handleQueueItemSubmittedMessage(_ json: [String: Any]) {
        guard let queueId = json["queue_id"] as? String else { return }
        let resultString = (json["result"] as? String) ?? "failed"
        let didSucceed = resultString == "success"
        let resultMessage = json["error_message"] as? String
        upsertQueueItem(id: queueId) { existingItem in
            guard var mutated = existingItem else { return nil }
            mutated.status = didSucceed ? .submitted : .failed
            mutated.resultMessage = resultMessage ?? mutated.resultMessage
            mutated.updatedAt = Date()
            return mutated
        }
        onQueueEvent?(.submitted(
            queueId: queueId,
            didSucceed: didSucceed,
            resultMessage: resultMessage
        ))
    }

    private func handleAgentErrorMessage(_ json: [String: Any]) {
        guard let queueId = json["queue_id"] as? String else { return }
        let errorMessage = json["error"] as? String
        upsertQueueItem(id: queueId) { existingItem in
            guard var mutated = existingItem else { return nil }
            mutated.status = .failed
            mutated.lastErrorMessage = errorMessage ?? mutated.lastErrorMessage
            mutated.updatedAt = Date()
            return mutated
        }
        onQueueEvent?(.errored(queueId: queueId, errorMessage: errorMessage))
    }

    /// Single mutation entry point so the @Published array fires exactly once
    /// per inbound message and the SwiftUI views downstream get a clean diff.
    private func upsertQueueItem(
        id queueItemIdentifier: String,
        transform: (QueueItemViewModel?) -> QueueItemViewModel?
    ) {
        let existingIndex = queueItems.firstIndex(where: { $0.id == queueItemIdentifier })
        let existingItem = existingIndex.map { queueItems[$0] }
        guard let updatedItem = transform(existingItem) else { return }
        if let foundIndex = existingIndex {
            queueItems[foundIndex] = updatedItem
        } else {
            queueItems.append(updatedItem)
        }
    }
}
