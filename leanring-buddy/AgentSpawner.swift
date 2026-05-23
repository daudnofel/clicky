//
//  AgentSpawner.swift
//  leanring-buddy
//
//  Spawns the `clicky-agent` Node + Playwright subprocess that drives
//  workflow replays. The Swift app passes `--ws-port` and `--worker-url`
//  CLI flags so the subprocess knows where to listen and which Cloudflare
//  Worker proxy to call.
//
//  Lifecycle:
//    1. CompanionManager constructs an AgentSpawner with the worker URL.
//    2. On the first replay job, CompanionManager calls `spawn()` (lazy).
//    3. AgentWebSocketClient.connect(port:) opens the local socket.
//    4. On app shutdown CompanionManager calls `terminate()` to kill the
//       subprocess so it doesn't outlive the parent.
//

import Foundation

@MainActor
final class AgentSpawner {
    /// Local port the spawned agent listens on. Hardcoded for V1 — there's
    /// only ever one agent. If we ever want to support more than one
    /// simultaneously we'll dynamically pick a free port and emit it.
    let webSocketPort: Int

    /// Cloudflare Worker base URL passed through to the agent so it can
    /// hit `/workflow/replay-step`.
    let workerBaseUrl: String

    private var runningProcess: Process?
    private var standardOutputPipe: Pipe?
    private var standardErrorPipe: Pipe?

    init(workerBaseUrl: String, webSocketPort: Int = 9876) {
        self.workerBaseUrl = workerBaseUrl
        self.webSocketPort = webSocketPort
    }

    /// True iff the subprocess is currently running (we have a PID and
    /// `isRunning` confirms it).
    var isSpawned: Bool {
        guard let runningProcess else { return false }
        return runningProcess.isRunning
    }

    /// Spawns the Node subprocess. Idempotent — re-calls while a previous
    /// run is still alive are no-ops.
    ///
    /// TODO (apprentice-mode V1 follow-up): bundling Node + the
    /// playwright browsers into the .app is non-trivial. For V1 the .app
    /// expects a sibling `clicky-agent/` directory next to the .app bundle
    /// (or inside `Bundle.main.resourceURL`) containing a built `dist/`
    /// folder. First launch must also run `npm install && npx playwright
    /// install chromium` once — we do NOT implement first-launch
    /// bootstrapping here. A README install step covers it for now.
    func spawn() throws {
        if isSpawned { return }

        let agentDirectoryUrl = try resolveBundledAgentDirectoryUrl()
        let agentEntryScriptUrl = agentDirectoryUrl.appendingPathComponent("dist/index.js")

        let process = Process()
        process.currentDirectoryURL = agentDirectoryUrl
        // /usr/bin/env honors the user's PATH and avoids hardcoding /usr/local/bin/node
        // (which doesn't exist on Apple Silicon homebrew installs).
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "node",
            agentEntryScriptUrl.path,
            "--ws-port", String(webSocketPort),
            "--worker-url", workerBaseUrl
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        standardOutputPipe = outputPipe
        standardErrorPipe = errorPipe

        // Stream subprocess stdout/stderr to the parent Xcode console so we
        // can debug Playwright launches without attaching a separate logger.
        outputPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let chunkData = fileHandle.availableData
            guard !chunkData.isEmpty, let chunkText = String(data: chunkData, encoding: .utf8) else { return }
            print("[clicky-agent stdout] \(chunkText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        errorPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let chunkData = fileHandle.availableData
            guard !chunkData.isEmpty, let chunkText = String(data: chunkData, encoding: .utf8) else { return }
            print("[clicky-agent stderr] \(chunkText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        process.terminationHandler = { terminatedProcess in
            print("[clicky-agent] subprocess exited with status \(terminatedProcess.terminationStatus)")
        }

        try process.run()
        runningProcess = process
        print("[clicky-agent] spawned pid=\(process.processIdentifier) port=\(webSocketPort)")
    }

    /// SIGTERMs the subprocess. Safe to call repeatedly.
    func terminate() {
        guard let process = runningProcess else { return }
        if process.isRunning {
            process.terminate()
        }
        standardOutputPipe?.fileHandleForReading.readabilityHandler = nil
        standardErrorPipe?.fileHandleForReading.readabilityHandler = nil
        runningProcess = nil
        standardOutputPipe = nil
        standardErrorPipe = nil
    }

    // MARK: - Path resolution

    /// Returns the on-disk directory the agent should run from. Production
    /// builds expect the agent to be bundled inside the .app's Resources
    /// directory. Dev builds fall back to the workspace-side `clicky-agent`
    /// path next to the Xcode project so engineers can iterate without
    /// rebuilding the .app.
    private func resolveBundledAgentDirectoryUrl() throws -> URL {
        let fileManager = FileManager.default

        if let bundledResourceUrl = Bundle.main.resourceURL {
            let candidate = bundledResourceUrl.appendingPathComponent("clicky-agent")
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // Dev-mode fallback: walk up from the Xcode-built .app to the workspace
        // and use the source `clicky-agent` directory.
        if let bundleUrl = Bundle.main.bundleURL.deletingLastPathComponent() as URL? {
            let candidate = bundleUrl
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("clicky-agent")
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw NSError(
            domain: "AgentSpawner",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Could not locate clicky-agent directory. Expected it bundled in Resources/clicky-agent or sibling to the .app for dev builds."
            ]
        )
    }
}
