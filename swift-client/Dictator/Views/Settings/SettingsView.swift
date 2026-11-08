import AVFoundation
import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @State private var selection: SettingsSection = .general
    @State private var navigation = AppNavigation.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DSSpace.s) {
                DSPageHeader(title: "Settings", brief: HelpLibrary.brief(HelpPage(settings: selection)))
                DSTabs(selection: tabSelection, items: SettingsSection.tabs.map { (value: $0, title: $0.title) })
            }
            .padding(.top, DSSpace.l)
            .padding(.bottom, DSSpace.s)
            .dsPageFrame()
            Rectangle().fill(Color.dsDivider).frame(height: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.dsBgContent)
        .onAppear { consumeNavigation() }
        .onChange(of: navigation.settingsSection) { _, _ in consumeNavigation() }
    }

    /// The typed-apps page belongs to the History & Privacy tab.
    private var tabSelection: Binding<SettingsSection> {
        Binding(get: { selection == .typedApps ? .history : selection }, set: { selection = $0 })
    }

    private func consumeNavigation() {
        if let section = navigation.settingsSection {
            selection = section
            navigation.settingsSection = nil
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general: GeneralSettingsPage()
        case .macs: YourMacsSettingsPage()
        case .dictation: DictationSettingsPage()
        case .history: HistoryPrivacySettingsPage()
        case .typedApps: TypedAppsSettingsPage()
        case .advanced: AdvancedSettingsPage()
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case macs
    case dictation
    case history
    /// "Also save what you type in apps you choose" — reached from
    /// History & Privacy, not listed in the sidebar.
    case typedApps
    case advanced

    var id: String { rawValue }

    static let tabs: [SettingsSection] = [.general, .macs, .dictation, .history, .advanced]

    var title: String {
        switch self {
        case .general: "General"
        case .macs: "Your Macs"
        case .dictation: "Dictation"
        case .history, .typedApps: "History & Privacy"
        case .advanced: "Advanced"
        }
    }
}

struct SettingsStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.l) {
                content
            }
            .padding(.vertical, DSSpace.m)
            .dsPageFrame()
        }
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            DSSection(title: title)

            DSCard {
                VStack(alignment: .leading, spacing: DSSpace.s) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct SettingsLabeledControl<Content: View>: View {
    let label: String
    let help: String?
    @ViewBuilder let content: Content

    init(_ label: String, help: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.help = help
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DSSpace.s) {
                labelView

                controlStack
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                Text(label)
                    .font(.dsBodyMedium)
                    .foregroundStyle(Color.dsTextPrimary)
                controlStack
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var labelView: some View {
        Text(label)
            .font(.dsBodyMedium)
            .foregroundStyle(Color.dsTextPrimary)
            .frame(width: 150, alignment: .trailing)
            .padding(.top, DSSpace.hair)
    }

    private var controlStack: some View {
        VStack(alignment: .leading, spacing: DSSpace.xxs) {
            content

            if let help {
                Text(help)
                    .settingsHelpText()
            }
        }
    }
}

extension View {
    func settingsHelpText() -> some View {
        font(.dsSecondary)
            .foregroundStyle(Color.dsTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
