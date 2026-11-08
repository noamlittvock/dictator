import AppKit
import SwiftUI

struct DatasetNotice: View {
    let text: String
    var tone: DSBadge.Tone = .neutral
    var onClose: (() -> Void)?
    var actionTitle: String?
    var action: (() -> Void)?

    private var icon: String {
        switch tone {
        case .warning: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        default: "info.circle.fill"
        }
    }

    private var color: Color {
        switch tone {
        case .warning: .dsWarning
        case .success: .dsSuccess
        default: .dsTextTertiary
        }
    }

    private var background: Color {
        switch tone {
        case .warning: .dsWarningQuiet
        case .success: .dsSuccessQuiet
        default: .dsSurfaceCard
        }
    }

    var body: some View {
        if tone == .warning {
            DSEmptyState(symbol: icon, title: text) {
                HStack(spacing: DSSpace.xs) {
                    if let onClose {
                        Button("Dismiss", action: onClose).buttonStyle(.dsQuiet)
                    }
                    if let actionTitle, let action {
                        Button(actionTitle, action: action)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                HStack(alignment: .top, spacing: DSSpace.xs) {
                    Image(systemName: icon)
                        .font(.dsIcon)
                        .foregroundStyle(color)
                        .frame(width: 18)
                    Text(text)
                        .font(.dsBody)
                        .foregroundStyle(Color.dsTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DSSpace.xs)
                    if let onClose {
                        Button("Dismiss", action: onClose)
                            .buttonStyle(.dsLink)
                            .font(.dsBody)
                    }
                }
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                }
            }
            .padding(DSSpace.m)
            .dsCardSurface(background)
        }
    }
}

extension Date {
    /// "Sep 25" / "Sep 25, 2025".
    var datasetShort: String {
        let sameYear = Calendar.current.isDate(self, equalTo: Date(), toGranularity: .year)
        return formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }
}

/// A collapsed row that states its current settings, so the defaults can be
/// trusted at a glance and opened only when they need changing.
struct DatasetDisclosure<Content: View>: View {
    let title: String
    let summary: String
    var tone: DSBadge.Tone = .neutral
    /// Wording for the closed and open states.
    var actions: (closed: String, open: String) = ("Change", "Done")
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: DSSpace.s) {
                    VStack(alignment: .leading, spacing: DSSpace.hair) {
                        Text(title)
                            .font(.dsBodyMedium)
                            .foregroundStyle(Color.dsTextPrimary)
                        Text(summary)
                            .font(.dsSecondary)
                            .foregroundStyle(tone == .warning ? Color.dsWarning : Color.dsTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: DSSpace.xs)
                    Text(isExpanded ? actions.open : actions.closed)
                        .font(.dsBodyMedium)
                        .foregroundStyle(Color.dsAccent)
                    Image(systemName: "chevron.right")
                        .font(.dsIconSmall)
                        .foregroundStyle(Color.dsTextTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title): \(summary)")
            .accessibilityHint(isExpanded ? "Hides these options" : "Shows these options")

            if isExpanded {
                content
                    .padding(.top, DSSpace.xs)
                    .padding(.bottom, DSSpace.xs)
                    .transition(.opacity)
            }
        }
    }
}

/// A copy action that confirms in place instead of raising a notice.
struct DatasetCopyButton: View {
    let title: String
    var systemImage = "doc.on.doc"
    var prominent = false
    let value: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value(), forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : systemImage)
        }
        .buttonStyle(DSButtonStyle(kind: prominent ? .primary : .secondary))
        .accessibilityLabel(copied ? "Copied" : title)
    }
}
