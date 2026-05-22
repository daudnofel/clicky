//
//  EventCaptureTap.swift
//  leanring-buddy
//
//  Listen-only CGEvent tap that observes mouse clicks and keystrokes
//  globally while teach mode is active. Mirrors the pattern in
//  GlobalPushToTalkShortcutMonitor.swift — same tap creation, same run loop
//  source plumbing, same callback-to-instance bridging via Unmanaged.
//
//  Emits RecordingEvent values to a continuation owned by TeachModeManager,
//  which forwards them to DemonstrationRecorder.
//
//  PII handling:
//    - Password fields (kAXSecureTextFieldRole on the AX focused element)
//      cause text events to be replaced with {"type": "text_redacted",
//      "field_kind": "password"}.
//    - Any other text that PIIRedactor.looksSensitive flags as a credit
//      card or SSN gets replaced with the "sensitive" variant.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

@MainActor
final class EventCaptureTap {
    /// Callback for emitted events. TeachModeManager assigns this on install();
    /// the tap never holds a long-lived reference back into the manager beyond
    /// what this closure captures, which lets the tap be torn down cleanly.
    var onEventCaptured: ((RecordingEvent) -> Void)?

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?

    /// Accumulated text typed into the currently focused element. Flushed
    /// as a single "text" or "text_redacted" event when focus changes or the
    /// tap is stopped. This matches the § A.2 contract: one text event per
    /// focused-input session, not one event per keystroke.
    private var bufferedTypedText: String = ""

    /// Bookkeeping for the focused-input session. We snapshot at the time
    /// typing begins because re-querying AX after a long burst can be racy.
    private var focusedFieldIsSecureSnapshot: Bool = false

    /// Wall-clock start of the recording, supplied by TeachModeManager so the
    /// tap can stamp event timestamps without crossing actor boundaries from
    /// the CGEvent callback.
    private var recordingStartWallClockTime: Date = Date()

    deinit {
        // CFMachPort cleanup is safe to do from any thread.
        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        }
        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
        }
    }

    func install(recordingStartWallClockTime: Date) {
        guard globalEventTap == nil else { return }
        self.recordingStartWallClockTime = recordingStartWallClockTime

        let monitoredEventTypes: [CGEventType] = [.leftMouseDown, .rightMouseDown, .keyDown, .flagsChanged]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let eventCaptureTap = Unmanaged<EventCaptureTap>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            return eventCaptureTap.handleGlobalEventTap(eventType: eventType, event: event)
        }

        guard let createdEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ EventCaptureTap: couldn't create CGEvent tap")
            return
        }

        guard let createdRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            createdEventTap,
            0
        ) else {
            CFMachPortInvalidate(createdEventTap)
            print("⚠️ EventCaptureTap: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = createdEventTap
        self.globalEventTapRunLoopSource = createdRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), createdRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: createdEventTap, enable: true)
    }

    func uninstall() {
        // Flush any buffered typed text so it doesn't get lost when the
        // recording ends mid-typing.
        flushBufferedTypedTextIfNeeded()

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }
        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    // MARK: - CGEvent callback handler

    /// Runs on the main run loop (the tap was added to CFRunLoopGetMain()), so
    /// even though the function isn't marked @MainActor it is in practice
    /// invoked on the main thread. We still nonisolated this so the compiler
    /// doesn't reject the CGEventTapCallBack bridging.
    private nonisolated func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            // We can't safely re-enable from here without crossing actor
            // isolation. Bounce to the main actor for re-enable; in the
            // common case this branch never fires.
            Task { @MainActor in
                if let globalEventTap = self.globalEventTap {
                    CGEvent.tapEnable(tap: globalEventTap, enable: true)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // Bridge back to the main actor to mutate buffers and emit events.
        // The CGEvent callback runs on the main thread already, but Swift
        // 6's isolation rules require an explicit hop.
        let eventLocation = event.location
        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        Task { @MainActor in
            self.processCapturedEvent(eventType: eventType, eventLocation: eventLocation, eventKeyCode: eventKeyCode)
        }

        return Unmanaged.passUnretained(event)
    }

    private func processCapturedEvent(eventType: CGEventType, eventLocation: CGPoint, eventKeyCode: UInt16) {
        let secondsSinceRecordingStart = Date().timeIntervalSince(recordingStartWallClockTime)

        switch eventType {
        case .leftMouseDown, .rightMouseDown:
            // A click changes focus, so any text buffered from the previous
            // field needs to flush before the click event is emitted.
            flushBufferedTypedTextIfNeeded()

            let clickScreenIndex = Self.screenIndexContainingPoint(eventLocation)
            let clickEvent = RecordingEvent(
                t: secondsSinceRecordingStart,
                type: "click",
                x: Int(eventLocation.x),
                y: Int(eventLocation.y),
                screenIndex: clickScreenIndex
            )
            onEventCaptured?(clickEvent)

        case .keyDown:
            handleKeyDown(eventKeyCode: eventKeyCode, secondsSinceRecordingStart: secondsSinceRecordingStart)

        case .flagsChanged:
            // We don't surface modifier transitions on their own — clicks and
            // character keys are enough signal for the worker's procedure
            // extraction prompt.
            break

        default:
            break
        }
    }

    private func handleKeyDown(eventKeyCode: UInt16, secondsSinceRecordingStart: Double) {
        // Tab / Return / Escape / arrows are emitted as discrete "key" events.
        // Character keys append to bufferedTypedText so the recording carries
        // one text event per focused-input session.
        if let nonCharacterKeyName = Self.nonCharacterKeyName(forKeyCode: eventKeyCode) {
            flushBufferedTypedTextIfNeeded()
            let nonCharacterKeyEvent = RecordingEvent(
                t: secondsSinceRecordingStart,
                type: "key",
                key: nonCharacterKeyName
            )
            onEventCaptured?(nonCharacterKeyEvent)
            return
        }

        // First keystroke of a new focused-input session — snapshot the AX
        // role so we know whether to redact when we eventually flush.
        if bufferedTypedText.isEmpty {
            focusedFieldIsSecureSnapshot = Self.focusedAxElementIsSecureTextField()
        }

        if let characterFromKeyCode = Self.characterFromKeyCode(eventKeyCode) {
            bufferedTypedText.append(characterFromKeyCode)
        }
    }

    private func flushBufferedTypedTextIfNeeded() {
        guard !bufferedTypedText.isEmpty else { return }
        let textToEmit = bufferedTypedText
        bufferedTypedText = ""
        let secondsSinceRecordingStart = Date().timeIntervalSince(recordingStartWallClockTime)

        if focusedFieldIsSecureSnapshot {
            onEventCaptured?(RecordingEvent(
                t: secondsSinceRecordingStart,
                type: "text_redacted",
                fieldKind: "password"
            ))
            return
        }

        if PIIRedactor.looksSensitive(textToEmit) {
            onEventCaptured?(RecordingEvent(
                t: secondsSinceRecordingStart,
                type: "text_redacted",
                fieldKind: "sensitive"
            ))
            return
        }

        onEventCaptured?(RecordingEvent(
            t: secondsSinceRecordingStart,
            type: "text",
            value: textToEmit
        ))
    }

    // MARK: - AX focus inspection

    /// Returns true when the system-wide accessibility focused element reports
    /// kAXSecureTextFieldRole. Used to redact password field input.
    private static func focusedAxElementIsSecureTextField() -> Bool {
        let systemWideAxElement = AXUIElementCreateSystemWide()
        var focusedElementValue: AnyObject?
        let focusedElementError = AXUIElementCopyAttributeValue(
            systemWideAxElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        guard focusedElementError == .success, let focusedElementCFTypeRef = focusedElementValue else {
            return false
        }
        let focusedAxElement = focusedElementCFTypeRef as! AXUIElement

        var roleValue: AnyObject?
        let roleError = AXUIElementCopyAttributeValue(focusedAxElement, kAXRoleAttribute as CFString, &roleValue)
        guard roleError == .success, let roleString = roleValue as? String else {
            return false
        }
        return roleString == (kAXSecureTextFieldRole as String)
    }

    // MARK: - Key code → character / non-character key name

    /// Translates the key code on a CGEvent into a printable character, using
    /// the current keyboard layout. Returns nil for non-printable keys
    /// (arrows, function keys, escape, etc.) — callers should treat those
    /// via nonCharacterKeyName(forKeyCode:) instead.
    private static func characterFromKeyCode(_ keyCode: UInt16) -> String? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        guard let layoutDataRef = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataRef).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var unicodeStringLength = 0
        var unicodeCharacterBuffer = [UniChar](repeating: 0, count: 4)

        let translationResult = layoutData.withUnsafeBytes { rawBufferPointer -> OSStatus in
            guard let layoutPointer = rawBufferPointer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return -1
            }
            return UCKeyTranslate(
                layoutPointer,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                unicodeCharacterBuffer.count,
                &unicodeStringLength,
                &unicodeCharacterBuffer
            )
        }
        guard translationResult == noErr, unicodeStringLength > 0 else { return nil }
        let translatedString = String(utf16CodeUnits: unicodeCharacterBuffer, count: unicodeStringLength)
        // Filter out control characters that slip through (e.g. backspace).
        if translatedString.unicodeScalars.allSatisfy({ $0.value < 0x20 || $0.value == 0x7F }) {
            return nil
        }
        return translatedString
    }

    /// Names for non-character keys we want surfaced as discrete "key" events
    /// in events.jsonl. Anything not in this map is either a character key
    /// (handled above) or a key we deliberately ignore.
    private static func nonCharacterKeyName(forKeyCode keyCode: UInt16) -> String? {
        switch keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Backspace"
        case 53: return "Escape"
        case 76: return "Enter"
        case 117: return "Delete"
        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"
        default: return nil
        }
    }

    // MARK: - Multi-screen helpers

    /// Returns the 0-based index of the NSScreen containing the supplied
    /// global-coordinate point. Falls back to 0 when no screen matches —
    /// this happens off the visible bounds, which shouldn't occur for real
    /// click events but is safe to default rather than crash.
    private static func screenIndexContainingPoint(_ point: CGPoint) -> Int {
        for (screenIndex, screen) in NSScreen.screens.enumerated() {
            if screen.frame.contains(point) {
                return screenIndex
            }
        }
        return 0
    }
}
