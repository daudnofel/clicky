//
//  ReviewQueuePanel.swift
//  leanring-buddy
//
//  Resizable floating NSPanel that hosts the SwiftUI ReviewQueueView via
//  NSHostingView. Pattern mirrors POVWindowPanel.swift — the Review Queue
//  is also a "real" utility window the user interacts with (clicks
//  Approve, edits text), not a glanceable HUD, so it ships with full
//  window chrome (titled / closable / miniaturizable / resizable).
//
//  Critically, the style mask does NOT include .utilityWindow. Unlike
//  the POV window which is a passive viewer, this panel hosts a
//  TextEditor inside ApplicationCard — `.utilityWindow` would force
//  the slim utility-style chrome and (more importantly) prevent the
//  panel from becoming key reliably enough for text input to land.
//

import AppKit
import SwiftUI

/// NSPanel subclass that opts in to becoming the key window even when
/// the styleMask says nonactivatingPanel. Without this override the
/// inline-edit TextEditor inside ApplicationCard would never receive
/// keyboard focus and edits would silently drop on the floor.
private final class KeyableReviewQueueNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ReviewQueuePanel: NSObject, NSWindowDelegate {
    private let queueStoreObservable: QueueStoreObservable
    private let agentWebSocketClient: AgentWebSocketClient

    private var hostingPanel: NSPanel?

    /// True when the panel should be on screen. Tracked separately from
    /// the NSPanel's own visibility flag for the same reason POVWindowPanel
    /// does — they diverge during animation and during programmatic
    /// orderOut, and we always want the source-of-truth here.
    private(set) var isShowing: Bool = false

    /// Called when the user clicks the close (x) traffic light. The owner
    /// (CompanionManager) uses this to flip its `isReviewQueueVisible`
    /// flag so the menu bar toggle reflects reality.
    var onUserClosedPanel: (() -> Void)?

    private let defaultPanelWidth: CGFloat = 500
    private let defaultPanelHeight: CGFloat = 600

    init(
        queueStoreObservable: QueueStoreObservable,
        agentWebSocketClient: AgentWebSocketClient
    ) {
        self.queueStoreObservable = queueStoreObservable
        self.agentWebSocketClient = agentWebSocketClient
        super.init()
    }

    // MARK: - Public lifecycle

    func show() {
        if hostingPanel == nil {
            createPanel()
        }
        guard let panel = hostingPanel else { return }
        // makeKeyAndOrderFront: text input needs key status to receive
        // characters. POVWindowPanel deliberately AVOIDS this — that one
        // is passive — but for an editable review surface we want focus.
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        isShowing = true
    }

    func hide() {
        hostingPanel?.orderOut(nil)
        isShowing = false
    }

    /// Wire up the close-callback. Settable after init so CompanionManager
    /// can pass a closure that captures `self` weakly — POVWindowPanel
    /// uses the same pattern.
    func setOnUserClosedPanel(_ closure: @escaping () -> Void) {
        onUserClosedPanel = closure
    }

    // MARK: - Panel construction

    private func createPanel() {
        let initialContentFrame = computeInitialFrameForCursorScreen(
            width: defaultPanelWidth,
            height: defaultPanelHeight
        )

        // Notes on the style mask:
        //   .titled + .closable + .miniaturizable + .resizable: standard
        //     chrome the user expects to drag, close, resize.
        //   .nonactivatingPanel: keep underlying app in focus when the
        //     panel becomes key (so the user doesn't get yanked out of
        //     their flow when they click an Approve button).
        //   NO .utilityWindow: editing text requires reliable key-window
        //     behavior; the utility variant disrupts it on some macOS
        //     versions.
        let panel = KeyableReviewQueueNSPanel(
            contentRect: initialContentFrame,
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .nonactivatingPanel
            ],
            backing: .buffered,
            defer: false
        )

        panel.title = "Review Queue"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        // Keep the same panel instance across hide/show so the user's
        // drag-position and resize survive toggling the menu bar switch.
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]
        panel.delegate = self

        let reviewQueueRootView = ReviewQueueView(
            queueStoreObservable: queueStoreObservable,
            agentWebSocketClient: agentWebSocketClient
        )
        let hostingView = NSHostingView(rootView: reviewQueueRootView)
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: initialContentFrame.width,
            height: initialContentFrame.height
        )
        panel.contentView = hostingView

        hostingPanel = panel
    }

    // MARK: - NSWindowDelegate

    /// Mirror POVWindowPanel's pattern: hide rather than release, so the
    /// next show() reuses the same instance and the user's drag position
    /// persists across close/reopen cycles.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hostingPanel?.orderOut(nil)
        isShowing = false
        onUserClosedPanel?()
        return false
    }

    // MARK: - Initial positioning

    /// Centers the panel on the screen that currently holds the cursor.
    /// Differs from POVWindowPanel's bottom-right anchoring because the
    /// review queue is a focus-of-attention surface (the user is actively
    /// reading/editing it), not a glanceable side panel.
    private func computeInitialFrameForCursorScreen(
        width: CGFloat,
        height: CGFloat
    ) -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let cursorScreen = NSScreen.screens.first(where: { screen in
            screen.frame.contains(mouseLocation)
        }) ?? NSScreen.main ?? NSScreen.screens.first

        guard let cursorScreen else {
            // Headless / no-screen test fallback — return SOMETHING valid.
            return NSRect(x: 100, y: 100, width: width, height: height)
        }

        let visibleFrame = cursorScreen.visibleFrame
        let originX = visibleFrame.midX - width / 2
        let originY = visibleFrame.midY - height / 2
        return NSRect(x: originX, y: originY, width: width, height: height)
    }
}
