import AppKit
import SwiftUI

/// Converts between the stored text (with `{message}` references) and text
/// where each value is a coloured bubble with a plain name.
enum ValueBubbleText {
    static let valueKey = NSAttributedString.Key("dictator.value")

    static func baseAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor(Color.dsTextPrimary)]
    }

    static func attributed(from template: String, values: [InsertableValue], font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for part in ValueText.parts(template, values: values) {
            switch part {
            case .text(let text): result.append(NSAttributedString(string: text, attributes: baseAttributes(font: font)))
            case .value(let value): result.append(bubble(for: value, font: font))
            }
        }
        return result
    }

    /// The stored text again.
    static func template(from attributed: NSAttributedString) -> String {
        var parts: [ValueText.Part] = []
        let string = attributed.string as NSString
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
            let text = string.substring(with: range)
            if let template = attributes[valueKey] as? String {
                // One run can hold several bubbles for the same value.
                var pending = ""
                for character in text {
                    if character == "\u{FFFC}" {
                        if !pending.isEmpty { parts.append(.text(pending)); pending = "" }
                        parts.append(.value(InsertableValue(template: template, name: "", kind: .words)))
                    } else {
                        pending.append(character)
                    }
                }
                if !pending.isEmpty { parts.append(.text(pending)) }
            } else {
                parts.append(.text(text.replacingOccurrences(of: "\u{FFFC}", with: "")))
            }
        }
        return ValueText.template(parts)
    }

    static func color(_ kind: InsertableValue.Kind) -> NSColor {
        switch kind {
        case .words: NSColor(Color.dsDataSlate)
        case .someone: NSColor(Color.dsDataOchre)
        case .detail: NSColor(Color.dsDataTeal)
        case .answer: NSColor(Color.dsDataPlum)
        }
    }

    static func bubble(for value: InsertableValue, font: NSFont) -> NSAttributedString {
        let size = max(11, font.pointSize - 1)
        let labelFont = NSFont.systemFont(ofSize: size, weight: .medium)
        let label = NSAttributedString(string: value.name, attributes: [.font: labelFont, .foregroundColor: NSColor(Color.dsTextPrimary)])
        let textSize = label.size()
        let width = ceil(textSize.width) + DSSpace.m
        let height = ceil(textSize.height) + DSSpace.xxs
        let tint = color(value.kind)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: rect.height / 2, yRadius: rect.height / 2)
            tint.withAlphaComponent(0.25).setFill()
            path.fill()
            tint.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1
            path.stroke()
            label.draw(at: NSPoint(x: DSSpace.xs, y: (rect.height - textSize.height) / 2))
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: font.descender - 1, width: width, height: height)
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes([valueKey: value.template, .font: font], range: NSRange(location: 0, length: result.length))
        return result
    }
}

/// Lets the Insert buttons reach the text view that sits beside them.
final class ValueFieldHandle {
    weak var textView: NSTextView?
    var values: [InsertableValue] = []

    func insert(_ value: InsertableValue) {
        guard let textView, let storage = textView.textStorage else { return }
        let font = textView.font ?? NSFont.systemFont(ofSize: 13)
        var range = textView.selectedRange()
        if range.location > storage.length { range = NSRange(location: storage.length, length: 0) }
        guard textView.shouldChangeText(in: range, replacementString: "\u{FFFC}") else { return }
        storage.replaceCharacters(in: range, with: ValueBubbleText.bubble(for: value, font: font))
        textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
        textView.didChangeText()
        textView.window?.makeFirstResponder(textView)
    }
}

/// A text box where spoken values are bubbles. `lines` is how tall it is.
private struct ValueTextView: NSViewRepresentable {
    @Binding var text: String
    let values: [InsertableValue]
    let handle: ValueFieldHandle
    let lines: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        let textView = NSTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: DSSpace.xxs, height: DSSpace.xxs)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.delegate = context.coordinator
        scroll.documentView = textView
        handle.textView = textView
        context.coordinator.load(into: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        handle.values = values
        guard let textView = scroll.documentView as? NSTextView else { return }
        handle.textView = textView
        let stored = ValueBubbleText.template(from: textView.attributedString())
        let signature = values.map { $0.id + "|" + $0.name }.joined()
        if stored != text || context.coordinator.valuesSignature != signature {
            context.coordinator.load(into: textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ValueTextView
        var valuesSignature = ""
        private var loading = false

        init(_ parent: ValueTextView) { self.parent = parent }

        func load(into textView: NSTextView) {
            loading = true
            defer { loading = false }
            let font = textView.font ?? NSFont.systemFont(ofSize: 13)
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(ValueBubbleText.attributed(from: parent.text, values: parent.values, font: font))
            textView.typingAttributes = ValueBubbleText.baseAttributes(font: font)
            let length = textView.textStorage?.length ?? 0
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            valuesSignature = parent.values.map { $0.id + "|" + $0.name }.joined()
        }

        func textDidChange(_ notification: Notification) {
            guard !loading, let textView = notification.object as? NSTextView else { return }
            textView.typingAttributes = ValueBubbleText.baseAttributes(font: textView.font ?? NSFont.systemFont(ofSize: 13))
            let template = ValueBubbleText.template(from: textView.attributedString())
            if template != parent.text { parent.text = template }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // One line, or a few: Return never inserts a new line.
            selector == #selector(NSResponder.insertNewline(_:))
        }
    }
}

/// A text or link box where what you say goes in as bubbles, with a row of
/// "Insert:" buttons for the values the sentence offers.
struct VoiceValueField: View {
    @Binding var text: String
    let values: [InsertableValue]
    var lines = 1
    @State private var handle = ValueFieldHandle()

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            ValueTextView(text: $text, values: values, handle: handle, lines: lines)
                .frame(height: CGFloat(lines) * 18 + 10)
                .background(Color.dsSurfaceControl, in: RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous).strokeBorder(Color.dsBorderSubtle, lineWidth: 1))
            if !values.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: DSSpace.xs) {
                    Text(VoiceBuildCopy.insertLabel).font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
                    FlowRow(spacing: DSSpace.xs) {
                        ForEach(values) { value in
                            Button(value.name) { handle.insert(value) }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}
