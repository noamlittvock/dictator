import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case home        = "Home"
    case voiceLaunch = "Voice launch"
    case workspaceLaunch = "Workspace launch"
    case dictionary  = "Dictionary"
    case datasets       = "Usage"
    case settings    = "Settings"
    case help        = "Help"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .voiceLaunch: "Commands"
        case .workspaceLaunch: "Workspaces"
        case .datasets: "Datasets"
        default: rawValue
        }
    }

    var icon: String {
        switch self {
        case .home:        "house"
        case .datasets:    "square.and.arrow.up"
        case .workspaceLaunch: "rectangle.3.group"
        case .voiceLaunch: "waveform.badge.mic"
        case .dictionary:  "book"
        case .settings:    "gear"
        case .help:        "questionmark.circle"
        }
    }

    var badge: String? { nil }
}

struct SidebarView: View {
    @Binding var selection: SidebarItem

    var body: some View {
        VStack(spacing: 0) {
            brandArea
            Divider().overlay(Color.dsBorderSubtle)
            navArea
            Divider().overlay(Color.dsBorderSubtle)
            footerArea
        }
        .background(Color.dsBgSidebar)
    }

    // MARK: - Brand

    private var brandArea: some View {
        HStack(alignment: .center, spacing: DSSpace.s) {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.dsTextPrimary)
                .frame(width: DSSpace.l, height: DSSpace.xl)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                Text("Dictator.")
                    .font(DSFont.display(25))
                    .foregroundStyle(Color.dsTextPrimary)
                Text("VOICE TO POWER")
                    .font(DSFont.body(9, weight: .medium))
                    .tracking(1.5)
                    .foregroundStyle(Color.dsTextSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, DSSpace.m)
        .padding(.top, DSSpace.m)
        .padding(.bottom, DSSpace.m)
    }

    // MARK: - Nav

    private var navArea: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: DSSpace.hair) {
                ForEach(SidebarItem.allCases) { item in
                    DSSidebarNavItem(
                        icon: item.icon,
                        label: item.title,
                        active: selection == item,
                        badge: item.badge
                    ) { selection = item }
                }
            }
            .padding(.horizontal, DSSpace.xs)
            .padding(.vertical, DSSpace.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footerArea: some View {
        HStack(spacing: DSSpace.xs) {
            Image(systemName: "lock.fill")
                .font(.dsIconSmall)
                .foregroundStyle(Color.dsTextTertiary)
            Text("Runs on your Macs")
                .font(.dsCaption)
                .foregroundStyle(Color.dsTextTertiary)
        }
        .padding(.horizontal, DSSpace.m)
        .padding(.vertical, DSSpace.s)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
