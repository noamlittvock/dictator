import SwiftUI

// The shared frames of the app: pages, tabs, sheets, buttons, panels and
// empty states. A new screen is built from these and the scales in
// `DictatorDesignSystem.swift`, so it can't drift from the rest of the app.

// MARK: - Pages

enum DSPageWidth {
    case reading, wide

    var maxWidth: CGFloat {
        switch self {
        case .reading: DSLayout.readingPage
        case .wide: DSLayout.widePage
        }
    }
}

extension View {
    /// Places page content on the app's left edge and width.
    func dsPageFrame(_ width: DSPageWidth = .reading) -> some View {
        padding(.horizontal, DSLayout.gutter)
            .frame(maxWidth: width.maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The title every page opens with: Anton, a "?" that explains the page, one
/// line of explanation, and any page-level actions on the right.
struct DSPageHeader<Accessory: View>: View {
    let title: String
    var summary: String? = nil
    var brief: PageBrief? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: DSSpace.m) {
            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                HStack(spacing: DSSpace.xs) {
                    Text(title)
                        .font(.dsPageTitle)
                        .foregroundStyle(Color.dsTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    if let brief { DSPageBriefButton(brief: brief) }
                }
                if let summary {
                    Text(summary)
                        .font(.dsBody)
                        .foregroundStyle(Color.dsTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
    }
}

extension DSPageHeader where Accessory == EmptyView {
    init(title: String, summary: String? = nil, brief: PageBrief? = nil) {
        self.init(title: title, summary: summary, brief: brief) { EmptyView() }
    }
}

/// The "?" beside a page title: a short brief, with a way into Help.
struct DSPageBriefButton: View {
    let brief: PageBrief
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.dsIconLarge)
                .foregroundStyle(hovering || showing ? Color.dsAccent : Color.dsTextTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("What this page does")
        .accessibilityLabel("What this page does")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            DSPageBriefCard(brief: brief) {
                showing = false
                AppNavigation.shared.openHelp(topic: brief.topicID)
            }
        }
    }
}

/// What the "?" opens.
struct DSPageBriefCard: View {
    let brief: PageBrief
    let readMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s) {
            if let scene = brief.scene { HelpSceneView(scene: scene) }
            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                Text(brief.title)
                    .font(.dsSection)
                    .foregroundStyle(Color.dsTextPrimary)
                HelpLine(text: brief.summary)
            }
            Button("Read more in Help", action: readMore)
                .buttonStyle(.dsLink)
        }
        .padding(DSSpace.m)
        .frame(width: DSLayout.brief, alignment: .leading)
        .tint(Color.dsAccent)
    }
}

/// A whole scrolling page. Pages with a fixed header above a list use
/// `DSPageHeader` and `dsPageFrame` directly.
struct DSPage<Accessory: View, Content: View>: View {
    let title: String
    var summary: String? = nil
    var brief: PageBrief? = nil
    var width: DSPageWidth = .reading
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.l) {
                DSPageHeader(title: title, summary: summary, brief: brief) { accessory }
                content
            }
            .padding(.top, DSSpace.l)
            .padding(.bottom, DSSpace.xl)
            .dsPageFrame(width)
        }
    }
}

extension DSPage where Accessory == EmptyView {
    init(title: String, summary: String? = nil, brief: PageBrief? = nil, width: DSPageWidth = .reading, @ViewBuilder content: () -> Content) {
        self.init(title: title, summary: summary, brief: brief, width: width, accessory: { EmptyView() }, content: content)
    }
}

// MARK: - Tabs

/// Sections inside a page. Native segmented controls stay for choosing a
/// value in a form; this is for moving around.
struct DSTabs<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [(value: Value, title: String)]

    var body: some View {
        HStack(spacing: DSSpace.xxs) {
            ForEach(items, id: \.value) { item in
                let selected = item.value == selection
                Button { selection = item.value } label: {
                    Text(item.title)
                        .font(.dsBodyMedium)
                        .foregroundStyle(selected ? Color.dsTextPrimary : Color.dsTextSecondary)
                        .padding(.horizontal, DSSpace.s)
                        .padding(.vertical, DSSpace.xxs + DSSpace.hair)
                        .dsSelectionBackground(selected)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Buttons

enum DSButtonKind {
    case primary, secondary, quiet, destructive, link
}

/// All buttons in the app. `MainWindowView` and `DSSheet` set `.dsSecondary`
/// as the default, so a plain `Button` is already correct; mark the one main
/// action on a surface with `.buttonStyle(.dsPrimary)`.
struct DSButtonStyle: ButtonStyle {
    let kind: DSButtonKind

    func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(kind: kind, configuration: configuration)
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    static var dsPrimary: DSButtonStyle { DSButtonStyle(kind: .primary) }
    static var dsSecondary: DSButtonStyle { DSButtonStyle(kind: .secondary) }
    static var dsQuiet: DSButtonStyle { DSButtonStyle(kind: .quiet) }
    static var dsDestructive: DSButtonStyle { DSButtonStyle(kind: .destructive) }
    static var dsLink: DSButtonStyle { DSButtonStyle(kind: .link) }
}

private struct DSButtonBody: View {
    let kind: DSButtonKind
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var hovering = false

    private var small: Bool { controlSize == .small || controlSize == .mini }

    var body: some View {
        Group {
            if kind == .link {
                configuration.label
                    .font(small ? .dsSecondaryMedium : .dsBodyMedium)
                    .foregroundStyle(hovering || configuration.isPressed ? Color.dsAccentHover : Color.dsAccent)
                    .underline(hovering)
            } else {
                configuration.label
                    .font(small ? .dsSecondaryMedium : .dsBodyMedium)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(foreground)
                    .padding(.horizontal, small ? DSSpace.xs : DSSpace.s)
                    .frame(minHeight: small ? DSSpace.l : DSSpace.xl - DSSpace.xxs)
                    .background(fill, in: shape)
                    .overlay(shape.strokeBorder(border, lineWidth: 1))
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .onHover { hovering = $0 && isEnabled }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
    }

    private var active: Bool { hovering || configuration.isPressed }

    private var foreground: Color {
        switch kind {
        case .primary: .dsOnAccent
        case .secondary: .dsTextPrimary
        case .quiet: active ? .dsTextPrimary : .dsTextSecondary
        case .destructive: .dsAccent
        case .link: .dsAccent
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: active ? .dsAccentHover : .dsAccent
        case .secondary: active ? .dsSurfaceRaised : .dsSurfaceControl
        case .quiet: active ? .dsSurfaceRaised : .clear
        case .destructive: active ? .dsAccentQStrong : .dsAccentQuiet
        case .link: .clear
        }
    }

    private var border: Color {
        kind == .secondary ? .dsBorder : .clear
    }
}

// MARK: - Sheets

enum DSSheetWidth {
    case compact, standard, wide

    var points: CGFloat {
        switch self {
        case .compact: 420
        case .standard: 560
        case .wide: 720
        }
    }
}

/// The frame of every sheet: title at the top, content, actions at the
/// bottom right. Give `height` when the content can outgrow the screen, and
/// it scrolls between the title and the actions. Leave it out and the sheet
/// fits its content.
struct DSSheet<Content: View, Leading: View, Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    var width: DSSheetWidth = .standard
    var height: CGFloat? = nil
    @ViewBuilder var content: Content
    @ViewBuilder var leadingActions: Leading
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                Text(title)
                    .font(.dsSheetTitle)
                    .foregroundStyle(Color.dsTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.dsBody)
                        .foregroundStyle(Color.dsTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DSSpace.l)
            .padding(.top, DSSpace.l)
            .padding(.bottom, DSSpace.m)

            if height != nil {
                ScrollView { sheetContent }
                    .frame(maxHeight: .infinity)
            } else {
                sheetContent
            }

            Rectangle().fill(Color.dsDivider).frame(height: 1)
            HStack(spacing: DSSpace.xs) {
                leadingActions
                Spacer(minLength: DSSpace.m)
                actions
            }
            .padding(.horizontal, DSSpace.l)
            .padding(.vertical, DSSpace.s)
        }
        .frame(width: width.points, height: height)
        .background(Color.dsBgContent)
        .foregroundStyle(Color.dsTextPrimary)
        .font(.dsBody)
        .tint(Color.dsAccent)
        .buttonStyle(.dsSecondary)
    }

    private var sheetContent: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DSSpace.l)
            .padding(.bottom, DSSpace.l)
    }
}

extension DSSheet where Leading == EmptyView {
    init(title: String, subtitle: String? = nil, width: DSSheetWidth = .standard, height: CGFloat? = nil,
         @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.init(title: title, subtitle: subtitle, width: width, height: height,
                  content: content, leadingActions: { EmptyView() }, actions: actions)
    }
}

// MARK: - Empty states

/// Nothing to show yet, or something to fix. One message and at most one action.
struct DSEmptyState<Action: View>: View {
    var symbol: String? = nil
    let title: String
    var detail: String? = nil
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: DSSpace.xs) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.dsIconHero)
                    .foregroundStyle(Color.dsTextTertiary)
                    .accessibilityHidden(true)
                    .padding(.bottom, DSSpace.xxs)
            }
            Text(title)
                .font(.dsSection)
                .foregroundStyle(Color.dsTextPrimary)
            if let detail {
                Text(detail)
                    .font(.dsBody)
                    .foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            action.padding(.top, DSSpace.xs)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, DSSpace.xl)
    }
}

extension DSEmptyState where Action == EmptyView {
    init(symbol: String? = nil, title: String, detail: String? = nil) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

// MARK: - Steps

/// A numbered step, and the tick that replaces the number when it's done.
struct DSStepBadge: View {
    let number: Int
    var done = false

    var body: some View {
        ZStack {
            Circle().fill(done ? Color.dsSuccessQuiet : Color.dsAccentQuiet)
            if done {
                Image(systemName: "checkmark").font(.dsCaptionMedium).foregroundStyle(Color.dsSuccess)
            } else {
                Text("\(number)").font(.dsCaptionMedium).foregroundStyle(Color.dsAccent)
            }
        }
        .frame(width: DSSpace.l - DSSpace.xxs, height: DSSpace.l - DSSpace.xxs)
        .accessibilityLabel(done ? "Step \(number), done" : "Step \(number)")
    }
}

// MARK: - Floating panels

extension View {
    /// Alerts, progress and near-miss cards that float over other apps.
    func dsPanel() -> some View {
        environment(\.colorScheme, .dark)
            .background(Color.dsPanelBackground.opacity(0.97),
                        in: RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                .strokeBorder(Color.dsPanelBorder, lineWidth: 1))
    }
}
