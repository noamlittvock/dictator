import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// AX is touched only on insertion and a move-on event, with a short IPC
/// timeout. Secure input and secure AX fields are rejected before text reads.
@MainActor final class NativeEditAccessibilityReader: EditAccessibilityReader {
    var onMoveOn: (() -> Void)?
    private var field: AXUIElement?
    private var observer: AXObserver?
    private var appObserver: NSObjectProtocol?

    func begin(inserted: String, expectedBundleID: String?) -> EditSpanSnapshot? {
        stop()
        guard !IsSecureEventInputEnabled(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.15)
        guard expectedBundleID == app.bundleIdentifier,
              let focus = attribute(element, kAXFocusedUIElementAttribute), CFGetTypeID(focus) == AXUIElementGetTypeID() else { return nil }
        let field = unsafeBitCast(focus, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(field, 0.15)
        guard !secure(field), let value = attribute(field, kAXValueAttribute) as? String,
              value.count <= RepoRequestLimits.maxTextLength * 2,
              let selected = attribute(field, kAXSelectedTextRangeAttribute), CFGetTypeID(selected) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(selected, to: AXValue.self), .cfRange, &range), range.length == 0 else { return nil }
        // InsertionSeam may add a space or lowercase the first word. Locate the
        // actual payload at the caret, preserving the original for diffing.
        let candidates = [inserted, " " + inserted, inserted.prefix(1).lowercased() + inserted.dropFirst(),
                          " " + inserted.prefix(1).lowercased() + inserted.dropFirst()]
        guard let snapshot = candidates.compactMap({ EditSpanSnapshot.match(value: value, caret: range.location, inserted: $0) }).first else { return nil }
        self.field = field
        var focusObserver: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let owner = Unmanaged<NativeEditAccessibilityReader>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor [weak owner] in owner?.onMoveOn?() }
        }
        if AXObserverCreate(app.processIdentifier, callback, &focusObserver) == .success, let focusObserver {
            observer = focusObserver
            AXObserverAddNotification(focusObserver, element, kAXFocusedUIElementChangedNotification as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(focusObserver), .commonModes)
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.onMoveOn?() }
            }
        return snapshot
    }

    func editedSpan(_ snapshot: EditSpanSnapshot) -> String? {
        guard let field, !IsSecureEventInputEnabled(), !secure(field),
              let length = attribute(field, kAXNumberOfCharactersAttribute) as? Int else { return nil }
        let delta = length - snapshot.originalFieldLength
        let count = snapshot.originalWindowLength + delta
        guard count >= 0, count <= RepoRequestLimits.maxTextLength + 64,
              snapshot.offset + count <= length else { return nil }
        var range = CFRange(location: snapshot.offset, length: count)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString,
            parameter, &result) == .success, let text = result as? String else { return nil }
        return snapshot.locate(in: text)
    }

    func stop() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil; field = nil
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
    }

    private func secure(_ field: AXUIElement) -> Bool {
        let role = attribute(field, kAXSubroleAttribute) as? String
        return role == kAXSecureTextFieldSubrole || role?.localizedCaseInsensitiveContains("secure") == true
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }
}
