import SwiftUI

/// A sentence with each part shown by what it does, used wherever Voice
/// launch shows words. Each part has its own shape, so colour is never the
/// only clue: the start word is a solid key, a person or project is an
/// outlined pill with a symbol, and your own words are plain italics.
/// Captions under the parts are optional; the Voice launch page explains the
/// shapes once instead. Built from `textColor`, so it reads in light and dark
/// and on the dark notices.
struct SpokenPhraseView: View {
    let segments: [PhraseSegment]
    var fontSize: CGFloat = 13
    /// Text colour for words outside a pill; the dark notices pass white.
    var textColor: Color = .dsTextPrimary
    var captionColor: Color = .dsTextSecondary
    /// The text on the solid start-word key: the opposite of `textColor`.
    var keyTextColor: Color = .dsBgContent
    var symbolColor: Color = .dsAccent
    var showsCaptions = true

    var body: some View {
        FlowRow(spacing: DSSpace.xs) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                part(segment)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(segments.map { segment in segment.label.map { "\(segment.text), \($0)" } ?? segment.text }.joined(separator: ". "))
    }

    @ViewBuilder private func part(_ segment: PhraseSegment) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.hair) {
            PhraseChip(segment: segment, fontSize: fontSize, textColor: textColor, keyTextColor: keyTextColor, symbolColor: symbolColor)
            if showsCaptions, let label = segment.label {
                Text(label).font(.dsCaption).foregroundStyle(captionColor)
                    .padding(.horizontal, segment.role == .words ? 0 : DSSpace.xs)
            }
        }
    }
}

/// One part of a spoken sentence, in the shape for its role.
struct PhraseChip: View {
    let segment: PhraseSegment
    var fontSize: CGFloat = 13
    var textColor: Color = .dsTextPrimary
    var keyTextColor: Color = .dsBgContent
    var symbolColor: Color = .dsAccent

    var body: some View {
        let vertical = DSSpace.xxs
        switch segment.role {
        case .opens:
            Text(segment.text)
                .font(.dsBodyMedium)
                .foregroundStyle(keyTextColor)
                .padding(.horizontal, DSSpace.xs).padding(.vertical, vertical)
                .background(textColor.opacity(0.88), in: RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous))
        case .who, .which:
            HStack(spacing: DSSpace.xxs) {
                if let symbol = segment.symbol {
                    Image(systemName: symbol).font(.dsIconSmall).foregroundStyle(symbolColor)
                }
                Text(segment.text).font(.dsBodyMedium).foregroundStyle(textColor)
            }
            .padding(.horizontal, DSSpace.xs).padding(.vertical, vertical)
            .background(textColor.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(textColor.opacity(0.3), lineWidth: 1))
        case .words:
            Text(segment.text).font(.dsBody.italic()).foregroundStyle(textColor.opacity(0.8))
                .padding(.vertical, vertical)
        case .plain:
            Text(segment.text).font(.dsBody).foregroundStyle(textColor.opacity(0.8))
                .padding(.vertical, vertical)
        }
    }
}
