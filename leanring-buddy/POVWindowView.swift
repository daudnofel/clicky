//
//  POVWindowView.swift
//  leanring-buddy
//
//  SwiftUI content for the "Clicky's POV" window. Renders the most recent
//  JPEG frame streamed from the spawned clicky-agent over the local
//  websocket, or an idle placeholder when no frame has arrived yet.
//
//  The view is intentionally tiny — `POVWindowPanel` owns the NSPanel
//  chrome + lifecycle, and `AgentWebSocketClient` owns the frame
//  decoding. This file is just the visual layer.
//

import SwiftUI

struct POVWindowView: View {
    @ObservedObject var agentWebSocketClient: AgentWebSocketClient

    var body: some View {
        ZStack {
            // Background fills the resizable window even when no frame
            // is available, so the user sees a coherent dark surface
            // instead of the default white NSPanel content.
            DS.Colors.background
                .ignoresSafeArea()

            if let mostRecentFrame = agentWebSocketClient.latestFrame {
                Image(nsImage: mostRecentFrame)
                    .resizable()
                    // contentMode .fit keeps the headless browser viewport
                    // aspect ratio intact while letting the user resize
                    // the window arbitrarily.
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                idlePlaceholderView
            }
        }
        // Default content size mirrors what POVWindowPanel uses so the
        // initial layout doesn't snap.
        .frame(minWidth: 280, minHeight: 200)
    }

    private var idlePlaceholderView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(DS.Colors.accentText)

            Text("agent idle")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            // The agent is lazy-spawned on first replay job, so before
            // any job runs the user sees this informational copy
            // instead of nothing at all.
            Text(agentWebSocketClient.connected
                 ? "Waiting for the first frame from clicky-agent."
                 : "Clicky's POV will appear here once a replay starts.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
