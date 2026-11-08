import Foundation

/// Reader retains an opaque field handle, never a typed transcript. The final
/// read is bounded to the original insertion plus its short neighbour anchors.
@MainActor protocol EditAccessibilityReader: AnyObject {
    var onMoveOn: (() -> Void)? { get set }
    func begin(inserted: String, expectedBundleID: String?) -> EditSpanSnapshot?
    func editedSpan(_ snapshot: EditSpanSnapshot) -> String?
    func stop()
}

struct EditSpanSnapshot: Equatable {
    var inserted: String
    var left: String
    var right: String
    var offset: Int // UTF-16 location of the bounded read, before left anchor
    var originalFieldLength: Int
    var originalWindowLength: Int

    /// Require a unique insertion ending at the reported caret. Only anchors
    /// and the inserted span survive this function; the field value does not.
    static func match(value: String, caret: Int, inserted: String) -> EditSpanSnapshot? {
        let text = value as NSString
        let length = (inserted as NSString).length
        guard !inserted.isEmpty, caret >= length, caret <= text.length else { return nil }
        let range = NSRange(location: caret - length, length: length)
        guard text.substring(with: range) == inserted else { return nil }
        let start = max(0, range.location - 32), end = min(text.length, caret + 32)
        let window = text.substring(with: NSRange(location: start, length: end - start))
        guard unique(window, in: value),
              (range.location == 0 || !wordCharacter(text.substring(with: NSRange(location: range.location - 1, length: 1)))),
              (caret == text.length || !wordCharacter(text.substring(with: NSRange(location: caret, length: 1)))) else { return nil }
        return EditSpanSnapshot(inserted: inserted,
            left: text.substring(with: NSRange(location: start, length: range.location - start)),
            right: text.substring(with: NSRange(location: caret, length: end - caret)),
            offset: start, originalFieldLength: text.length, originalWindowLength: end - start)
    }

    private static func wordCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.union(.nonBaseCharacters).contains($0) || $0 == "_" }
    }

    private static func unique(_ needle: String, in text: String) -> Bool {
        guard let first = text.range(of: needle) else { return false }
        return text.range(of: needle, range: text.index(after: first.lowerBound)..<text.endIndex) == nil
    }

    /// Exact anchors must still bracket one span. Ambiguity or an edit to a
    /// neighbour abandons learning rather than capturing unrelated typing.
    func locate(in window: String) -> String? {
        guard window.hasPrefix(left), window.hasSuffix(right),
              window.utf16.count >= left.utf16.count + right.utf16.count else { return nil }
        let value = window as NSString
        let range = NSRange(location: (left as NSString).length,
                            length: value.length - (left as NSString).length - (right as NSString).length)
        let span = value.substring(with: range)
        guard span.count <= RepoRequestLimits.maxTextLength,
              (left.isEmpty || Self.unique(left, in: window)),
              (right.isEmpty || Self.unique(right, in: window)),
              CorrectionLearner.ownsEdit(inserted: inserted, edited: span) else { return nil }
        return span
    }
}

/// Event driven: exactly one post-insertion read and one move-on read. There
/// is no key listener, text-change observer, timer polling or typing buffer.
@MainActor final class EditWatcher {
    private let reader: EditAccessibilityReader
    private let allowed: (CaptureContext) -> Bool
    private let deliver: (CorrectionReport) -> Void
    private let prepare: (CorrectionReport, CaptureContext) -> [CorrectionReport]
    private var pending: (snapshot: EditSpanSnapshot, id: UUID?, context: CaptureContext)?
    private var deadline: Task<Void, Never>?
    let timeCap: TimeInterval

    init(reader: EditAccessibilityReader, timeCap: TimeInterval = 60,
         allowed: @escaping (CaptureContext) -> Bool,
         prepare: @escaping (CorrectionReport, CaptureContext) -> [CorrectionReport] = { report, _ in [report] },
         deliver: @escaping (CorrectionReport) -> Void) {
        self.reader = reader; self.timeCap = timeCap
        self.allowed = allowed; self.deliver = deliver; self.prepare = prepare
        reader.onMoveOn = { [weak self] in self?.finish() }
    }

    func inserted(_ text: String, entryID: UUID?, context: CaptureContext) {
        finish()
        guard allowed(context), let snapshot = reader.begin(inserted: text, expectedBundleID: context.appBundleID) else { reader.stop(); return }
        pending = (snapshot, entryID, context)
        deadline = Task { [weak self, timeCap] in
            try? await Task.sleep(for: .seconds(timeCap))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    func finish() {
        deadline?.cancel(); deadline = nil
        guard let take = pending else { return }
        pending = nil
        defer { reader.stop() }
        // Revoking permission, pausing or turning learning off cancels even the read.
        guard allowed(take.context), let after = reader.editedSpan(take.snapshot), after != take.snapshot.inserted else { return }
        // Do not turn appended/composed typing into an edited history stage.
        // Ordinary-word filtering is deferred to the main Mac; it may still
        // save a genuine correction that isn't suitable for the dictionary.
        guard CorrectionLearner.ownsEdit(inserted: take.snapshot.inserted, edited: after) else { return }
        let report = CorrectionReport(heard: take.snapshot.inserted, corrected: after, entryID: take.id, context: take.context)
        for prepared in prepare(report, take.context) { deliver(prepared) }
    }

    func cancel() { deadline?.cancel(); deadline = nil; pending = nil; reader.stop() }
}
