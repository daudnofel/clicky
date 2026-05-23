//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 380

    /// Observes the agent ws client's queueItems so the menu bar icon
    /// can redraw with a badge when items are awaiting review.
    private var queueItemsSubscription: AnyCancellable?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }

        // Re-render the status item icon whenever the queue gains or loses
        // ready items. We don't filter inside the sink — Equatable on
        // [QueueItemViewModel] handles dedup downstream.
        queueItemsSubscription = companionManager.agentWebSocketClient.$queueItems
            .receive(on: RunLoop.main)
            .sink { [weak self] updatedQueueItems in
                let readyForReviewCount = updatedQueueItems.filter { $0.status == .ready }.count
                self?.refreshStatusItemIcon(readyForReviewBadgeCount: readyForReviewCount)
            }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeClickyMenuBarIcon(badgeCount: 0)
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// Re-renders the menu bar icon with the latest review-ready badge
    /// count. Called by the queueItems Combine subscription whenever
    /// the agent reports items moving in / out of the .ready status.
    private func refreshStatusItemIcon(readyForReviewBadgeCount: Int) {
        guard let button = statusItem?.button else { return }
        let updatedIcon = makeClickyMenuBarIcon(badgeCount: readyForReviewBadgeCount)
        // Templating only works for monochrome icons (the triangle is
        // ok, the badge is not), so we explicitly drop template mode
        // when a badge is drawn. The triangle still reads fine on both
        // light + dark menu bars because we paint it in a contrasting
        // fill below.
        button.image = updatedIcon
        button.image?.isTemplate = (readyForReviewBadgeCount == 0)
    }

    /// Draws the clicky triangle as a menu bar icon. Uses the same shape
    /// and rotation as the in-app cursor so the menu bar icon matches.
    ///
    /// When `badgeCount > 0`, draws a small filled red circle with the
    /// count in the upper-right corner — apprentice-mode review queue
    /// uses this so the user notices ready items without the menu bar
    /// panel being open.
    private func makeClickyMenuBarIcon(badgeCount: Int) -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let triangleSize = iconSize * 0.7
        let triangleCenterX = iconSize * 0.50
        let triangleCenterY = iconSize * 0.50
        let triangleHeight = triangleSize * sqrt(3.0) / 2.0

        let topVertex = CGPoint(x: triangleCenterX, y: triangleCenterY + triangleHeight / 1.5)
        let bottomLeftVertex = CGPoint(x: triangleCenterX - triangleSize / 2, y: triangleCenterY - triangleHeight / 3)
        let bottomRightVertex = CGPoint(x: triangleCenterX + triangleSize / 2, y: triangleCenterY - triangleHeight / 3)

        let rotationAngleRadians = 35.0 * .pi / 180.0
        func rotateAroundTriangleCenter(_ point: CGPoint) -> CGPoint {
            let deltaX = point.x - triangleCenterX
            let deltaY = point.y - triangleCenterY
            let cosineOfAngle = CGFloat(cos(rotationAngleRadians))
            let sineOfAngle = CGFloat(sin(rotationAngleRadians))
            return CGPoint(
                x: triangleCenterX + cosineOfAngle * deltaX - sineOfAngle * deltaY,
                y: triangleCenterY + sineOfAngle * deltaX + cosineOfAngle * deltaY
            )
        }

        let trianglePath = NSBezierPath()
        trianglePath.move(to: rotateAroundTriangleCenter(topVertex))
        trianglePath.line(to: rotateAroundTriangleCenter(bottomLeftVertex))
        trianglePath.line(to: rotateAroundTriangleCenter(bottomRightVertex))
        trianglePath.close()

        NSColor.black.setFill()
        trianglePath.fill()

        if badgeCount > 0 {
            drawReviewQueueBadge(
                badgeCount: badgeCount,
                onTopOfIconOfSize: iconSize
            )
        }

        image.unlockFocus()
        return image
    }

    /// Paints a small filled circle with a number in the upper-right
    /// corner of the menu bar icon. Used by the apprentice-mode review
    /// queue to signal items awaiting user approval.
    private func drawReviewQueueBadge(badgeCount: Int, onTopOfIconOfSize iconSize: CGFloat) {
        let badgeDiameter: CGFloat = 9
        let badgeOriginX = iconSize - badgeDiameter
        let badgeOriginY = iconSize - badgeDiameter
        let badgeRect = NSRect(
            x: badgeOriginX,
            y: badgeOriginY,
            width: badgeDiameter,
            height: badgeDiameter
        )

        let badgeCircle = NSBezierPath(ovalIn: badgeRect)
        // Bright red so the badge reads instantly against any menu bar
        // background. We don't use DS tokens here because the NSImage is
        // template-rendered for the no-badge case; mixing token Colors
        // would require NSColor bridging anyway.
        NSColor.systemRed.setFill()
        badgeCircle.fill()

        // Cap displayed count at 9+ so we don't blow out the badge.
        let displayedCountText = badgeCount > 9 ? "9+" : "\(badgeCount)"
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let attributedDisplayedCount = NSAttributedString(
            string: displayedCountText,
            attributes: textAttributes
        )
        let textSize = attributedDisplayedCount.size()
        let textOriginX = badgeRect.midX - textSize.width / 2
        let textOriginY = badgeRect.midY - textSize.height / 2
        attributedDisplayedCount.draw(at: NSPoint(x: textOriginX, y: textOriginY))
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        let companionPanelView = CompanionPanelView(companionManager: companionManager)
            .frame(width: panelWidth)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4

        // Calculate the panel's content height from the hosting view's fitting size
        // so the panel snugly wraps the SwiftUI content instead of using a fixed height.
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: panelWidth, height: panelHeight)
        let actualPanelHeight = fittingSize.height

        // Horizontally center the panel beneath the status item icon
        let panelOriginX = statusItemFrame.midX - (panelWidth / 2)
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: actualPanelHeight),
            display: true
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss during onboarding.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
