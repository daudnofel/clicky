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
    var lastIntent: String?
    var lastErrorMessage: String?
    var resultMessage: String?
    var updatedAt: Date
}

@MainActor
final class AgentWebSocketClient: ObservableObject {
    @Published private(set) var latestFrame: NSImage?
    @Published private(set) var queueItems: [QueueItemViewModel] = []
    @Published private(set) var connected: Bool = false
    @Published private(set) var lastConnectionErrorMessage: String?

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
        currentWebSocketTask?.cancel(with: .normalClosure, reason: nil)
        currentWebSocketTask = nil
        connected = false
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
        upsertQueueItem(id: queueId) { existingItem in
            var mutated = existingItem ?? QueueItemViewModel(
                id: queueId,
                status: .drafting,
                jobUrl: nil,
                companyGuess: nil,
                draftedText: nil,
                filledFields: [:],
                submitSelector: nil,
                lastIntent: nil,
                lastErrorMessage: nil,
                resultMessage: nil,
                updatedAt: Date()
            )
            mutated.status = .drafting
            mutated.jobUrl = (json["job_url"] as? String) ?? mutated.jobUrl
            mutated.companyGuess = (json["company_guess"] as? String) ?? mutated.companyGuess
            mutated.updatedAt = Date()
            return mutated
        }
    }

    private func handleQueueItemProgressMessage(_ json: [String: Any]) {
        guard let queueId = json["queue_id"] as? String else { return }
        upsertQueueItem(id: queueId) { existingItem in
            guard var mutated = existingItem else { return nil }
            mutated.lastIntent = (json["intent"] as? String) ?? mutated.lastIntent
            mutated.updatedAt = Date()
            return mutated
        }
    }

    private func handleQueueItemReadyMessage(_ json: [String: Any]) {
        guard let queueId = json["queue_id"] as? String else { return }
        upsertQueueItem(id: queueId) { existingItem in
            var mutated = existingItem ?? QueueItemViewModel(
                id: queueId,
                status: .ready,
                jobUrl: nil,
                companyGuess: nil,
                draftedText: nil,
                filledFields: [:],
                submitSelector: nil,
                lastIntent: nil,
                lastErrorMessage: nil,
                resultMessage: nil,
                updatedAt: Date()
            )
            mutated.status = .ready
            mutated.draftedText = (json["drafted_text"] as? String) ?? mutated.draftedText
            if let filledFieldsRaw = json["filled_fields"] as? [String: Any] {
                // The wire format permits arbitrary JSON values; the Swift
                // model coerces everything to String since downstream UI
                // displays them as plain text.
                var coercedFields: [String: String] = [:]
                for (fieldKey, fieldValue) in filledFieldsRaw {
                    if let stringValue = fieldValue as? String {
                        coercedFields[fieldKey] = stringValue
                    } else {
                        coercedFields[fieldKey] = String(describing: fieldValue)
                    }
                }
                mutated.filledFields = coercedFields
            }
            // submit_selector is a first-class field per § A.4 amendment.
            mutated.submitSelector = (json["submit_selector"] as? String) ?? mutated.submitSelector
            mutated.updatedAt = Date()
            return mutated
        }
    }

    private func handleQueueItemSubmittedMessage(_ json: [String: Any]) {
        guard let queueId = json["queue_id"] as? String else { return }
        upsertQueueItem(id: queueId) { existingItem in
            guard var mutated = existingItem else { return nil }
            let result = (json["result"] as? String) ?? "failed"
            mutated.status = result == "success" ? .submitted : .failed
            mutated.resultMessage = (json["error_message"] as? String) ?? mutated.resultMessage
            mutated.updatedAt = Date()
            return mutated
        }
    }

    private func handleAgentErrorMessage(_ json: [String: Any]) {
        guard let queueId = json["queue_id"] as? String else { return }
        upsertQueueItem(id: queueId) { existingItem in
            guard var mutated = existingItem else { return nil }
            mutated.status = .failed
            mutated.lastErrorMessage = (json["error"] as? String) ?? mutated.lastErrorMessage
            mutated.updatedAt = Date()
            return mutated
        }
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
