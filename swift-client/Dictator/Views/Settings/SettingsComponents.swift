import SwiftUI

// Building blocks for the Settings pages: a titled page, sections of rows
// in a card, and rows that say in plain words what they do.

/// One section of Settings, shown under the page's tabs. The tab already
/// names the section, so `title` is only read out to VoiceOver.
struct SettingsPage<Content: View>: View {
    let title: String
    var summary: String? = nil
    var width: DSPageWidth = .reading
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.l) {
                if let summary {
                    Text(summary)
                        .font(.dsBody)
                        .foregroundStyle(Color.dsTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(.top, DSSpace.m)
            .padding(.bottom, DSSpace.xl)
            .dsPageFrame(width)
        }
        .accessibilityLabel(title)
    }
}

/// A heading over a card of rows separated by dividers.
struct SettingsSectionCard<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            DSSection(title: title)
            VStack(spacing: 0) {
                content
            }
            .dsCardSurface()
            if let footer {
                Text(footer)
                    .font(.dsSecondary)
                    .foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Color.dsDivider).frame(height: 1).padding(.horizontal, DSSpace.m)
    }
}

/// One row: what it does on the left (with an optional short line under
/// it), the control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    var detailColor: Color = .dsTextSecondary
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: DSSpace.m) {
            VStack(alignment: .leading, spacing: DSSpace.hair) {
                Text(title)
                    .font(.dsBodyMedium)
                    .foregroundStyle(Color.dsTextPrimary)
                if let detail {
                    Text(detail)
                        .font(.dsSecondary)
                        .foregroundStyle(detailColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, DSSpace.m)
        .padding(.vertical, DSSpace.s)
    }
}

/// A choice among options, each with a short explanation.
struct SettingsChoiceRow: View {
    let title: String
    let detail: String
    let selected: Bool
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DSSpace.s) {
                ZStack {
                    Circle().strokeBorder(selected ? Color.dsAccent : Color.dsBorderStrong, lineWidth: 2)
                    if selected { Circle().fill(Color.dsAccent).padding(DSSpace.xxs) }
                }
                .frame(width: DSSpace.m, height: DSSpace.m)
                VStack(alignment: .leading, spacing: DSSpace.hair) {
                    Text(title).font(.dsBodyMedium).foregroundStyle(Color.dsTextPrimary)
                    Text(detail)
                        .font(.dsSecondary)
                        .foregroundStyle(Color.dsTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DSSpace.m)
            .padding(.vertical, DSSpace.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A one-line status or notice at the top of a page.
struct SettingsNotice<Trailing: View>: View {
    enum Tone { case ok, warning, neutral }
    let tone: Tone
    let text: Text
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: DSSpace.s) {
            Circle().fill(dot).frame(width: DSSpace.xs, height: DSSpace.xs)
            text
                .font(.dsBody)
                .foregroundStyle(Color.dsTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, DSSpace.m)
        .padding(.vertical, DSSpace.s)
        .dsCardSurface(background, border: border)
    }

    private var dot: Color {
        switch tone {
        case .ok: .dsSuccess
        case .warning: .dsWarning
        case .neutral: .dsTextTertiary
        }
    }

    private var background: Color {
        switch tone {
        case .ok: .dsSuccessQuiet
        case .warning: .dsWarningQuiet
        case .neutral: .dsSurfaceCard
        }
    }

    private var border: Color {
        switch tone {
        case .ok: Color.dsSuccess.opacity(0.35)
        case .warning: Color.dsWarning.opacity(0.35)
        case .neutral: .dsBorderSubtle
        }
    }
}

extension SettingsNotice where Trailing == EmptyView {
    init(tone: Tone, text: Text) {
        self.init(tone: tone, text: text) { EmptyView() }
    }
}
