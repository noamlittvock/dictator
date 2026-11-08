import AppKit
import ApplicationServices

struct TextInsertionSnapshot {
    /// Owner of the actual AX field, not whichever app happens to be in front
    /// after the probe finishes. Nil when AX cannot establish its identity.
    let processID: pid_t?
    fileprivate let element: AXUIElement
    fileprivate let value: String
    fileprivate let selectedRange: NSRange

    init(processID: pid_t? = nil, element: AXUIElement, value: String, selectedRange: NSRange) {
        self.processID = processID
        self.element = element
        self.value = value
        self.selectedRange = selectedRange
    }

    /// The text just before where an insertion lands.
    var precedingText: String {
        InsertionSeam.preceding(value, caret: selectedRange.location)
    }
}

enum CaretLocator {
    /// Captures enough focused-field state to prove a subsequent insertion.
    /// Some secure fields and web editors intentionally expose no value; those
    /// callers must treat a synthetic paste as unverified and retain the text.
    static func textInsertionSnapshot() -> TextInsertionSnapshot? {
        guard let element = findBestTextElement(),
              let value = stringAttribute(element, kAXValueAttribute),
              let range = selectedRange(of: element) else { return nil }
        var processID: pid_t = 0
        let owner = AXUIElementGetPid(element, &processID) == .success && processID > 0 ? processID : nil
        return TextInsertionSnapshot(processID: owner, element: element, value: value, selectedRange: range)
    }

    /// Finder’s file pane turns a paste into a clipping file. Recheck only
    /// the directly focused AX element: a text child/parent elsewhere in the
    /// same process does not authorize a paste into the current focus.
    static func isFocusedEditableTarget(_ snapshot: TextInsertionSnapshot?, expectedProcessID: pid_t?) -> Bool {
        guard let snapshot, let expectedProcessID, expectedProcessID > 0,
              snapshot.processID == expectedProcessID,
              let focused = directlyFocusedElement(), CFEqual(focused, snapshot.element) else { return false }
        var processID: pid_t = 0
        guard AXUIElementGetPid(focused, &processID) == .success, processID == expectedProcessID else { return false }
        func isSettable(_ attribute: String) -> Bool {
            var settable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(focused, attribute as CFString, &settable) == .success && settable.boolValue
        }
        return PasteDecision.isEditableTextField(
            role: stringAttribute(focused, kAXRoleAttribute),
            valueSettable: isSettable(kAXValueAttribute),
            selectedTextSettable: isSettable(kAXSelectedTextAttribute)
        )
    }

    /// What the field shows after pasting `text`: true (it took the paste),
    /// false (unchanged) or nil (unreadable). See `PasteDecision.insertionState`.
    static func insertionState(_ text: String, from snapshot: TextInsertionSnapshot) -> Bool? {
        PasteDecision.insertionState(
            matchesExpected: didInsert(text, from: snapshot),
            snapshotValue: snapshot.value,
            currentValue: stringAttribute(snapshot.element, kAXValueAttribute)
        )
    }

    /// What the field should hold once `text` replaces `range`, or nil when
    /// the range is unusable. It comes from another app: kCFNotFound is -1,
    /// which `NSString` answers by throwing.
    static func expectedValue(after text: String, replacing range: NSRange, in value: String) -> String? {
        let original = value as NSString
        guard range.location >= 0, range.length >= 0, range.location <= original.length else { return nil }
        let safeLength = min(range.length, original.length - range.location)
        return original.replacingCharacters(in: NSRange(location: range.location, length: safeLength), with: text)
    }

    static func didInsert(_ text: String, from snapshot: TextInsertionSnapshot) -> Bool {
        guard let currentValue = stringAttribute(snapshot.element, kAXValueAttribute)
        else { return false }

        guard let expected = expectedValue(after: text, replacing: snapshot.selectedRange, in: snapshot.value) else { return false }
        return currentValue == expected
    }

    // MARK: - Context

    // MARK: - Element search

    private static func directlyFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        guard let appRef = copyAttribute(systemWide, kAXFocusedApplicationAttribute),
              CFGetTypeID(appRef) == AXUIElementGetTypeID() else { return nil }
        let app = appRef as! AXUIElement

        guard let focusedRef = copyAttribute(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        return focusedRef as! AXUIElement
    }

    private static func findBestTextElement() -> AXUIElement? {
        guard let focused = directlyFocusedElement() else { return nil }
        if hasTextContent(focused) { return focused }
        if let child = findTextElement(in: focused, depth: 0, maxDepth: 5) { return child }
        if let parent = parent(of: focused), hasTextContent(parent) { return parent }
        return focused
    }

    private static func findTextElement(in element: AXUIElement, depth: Int, maxDepth: Int) -> AXUIElement? {
        guard depth < maxDepth else { return nil }

        if let focusedRef = copyAttribute(element, kAXFocusedUIElementAttribute),
           CFGetTypeID(focusedRef) == AXUIElementGetTypeID() {
            let child = focusedRef as! AXUIElement
            if hasTextContent(child) { return child }
            if let deeper = findTextElement(in: child, depth: depth + 1, maxDepth: maxDepth) {
                return deeper
            }
        }

        guard let childrenRef = copyAttribute(element, kAXChildrenAttribute),
              let children = childrenRef as? [AXUIElement] else { return nil }

        for child in children.prefix(20) {
            let role = stringAttribute(child, kAXRoleAttribute) ?? ""
            if isTextLikeRole(role), hasTextContent(child) {
                return child
            }
            if role == "AXWebArea" || role == (kAXGroupRole as String) {
                if let found = findTextElement(in: child, depth: depth + 1, maxDepth: maxDepth) {
                    return found
                }
            }
        }

        return nil
    }

    private static func isTextLikeRole(_ role: String) -> Bool {
        role == (kAXTextFieldRole as String) ||
            role == (kAXTextAreaRole as String) ||
            role == (kAXComboBoxRole as String) ||
            role == "AXWebArea"
    }

    private static func hasTextContent(_ element: AXUIElement) -> Bool {
        stringAttribute(element, kAXValueAttribute) != nil || selectedRange(of: element) != nil
    }

    // MARK: - AX helpers

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return err == .success ? value : nil
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copyAttribute(element, attribute),
              CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as! CFString as String
    }

    private static func selectedRange(of element: AXUIElement) -> NSRange? {
        guard let rangeValue = copyAttribute(element, kAXSelectedTextRangeAttribute),
              isAXValue(rangeValue) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        guard let parentRef = copyAttribute(element, kAXParentAttribute),
              CFGetTypeID(parentRef) == AXUIElementGetTypeID() else { return nil }
        return (parentRef as! AXUIElement)
    }

    private static func isAXValue(_ value: CFTypeRef) -> Bool {
        CFGetTypeID(value) == AXValueGetTypeID()
    }

}
