import SwiftUI

/// The Help page. Basics is a wall of pictures; Manual, Advanced and FAQ open
/// one topic at a time. One search box covers all of it. The words live in
/// `HelpLibrary` and the pictures in `HelpScenes.swift`.
struct HelpView: View {
    @State private var navigation = AppNavigation.shared
    @State private var settings = AppSettings.shared
    @State private var tab: HelpTab = .basics
    @State private var search: String
    @State private var open: Set<String> = []

    /// `search` fills the box on arrival (the snapshots use it).
    init(search: String = "") { _search = State(initialValue: search) }

    private var keys: HotkeyTriggers { settings.hotkeyTriggers }
    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    private var topics: [HelpTopic] {
        let all = HelpLibrary.topics(keys: keys)
        return searching ? HelpLibrary.search(search, in: all) : all.filter { $0.tab == tab }
    }

    var body: some View {
        let topics = self.topics
        return ScrollViewReader { scroller in
            DSPage(title: SidebarItem.help.title) {
                VStack(alignment: .leading, spacing: DSSpace.s) {
                    TextField("Search Help", text: $search)
                        .textFieldStyle(.roundedBorder)
                    if !searching {
                        DSTabs(selection: $tab, items: HelpTab.allCases.map { (value: $0, title: $0.title) })
                            .accessibilityLabel("Show")
                    }
                }
                if topics.isEmpty {
                    DSEmptyState(symbol: "magnifyingglass", title: "Nothing found") {
                        Button("Show the FAQ") { search = ""; tab = .faq }
                    }
                } else if !searching && tab == .basics {
                    sceneGrid(topics)
                } else {
                    topicList(topics)
                }
                footer
            }
            .onAppear { consumeNavigation(scroller) }
            .onChange(of: navigation.helpTopicID) { _, _ in consumeNavigation(scroller) }
        }
    }

    private func sceneGrid(_ topics: [HelpTopic]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: DSSpace.s), GridItem(.flexible(), spacing: DSSpace.s)],
                  alignment: .leading, spacing: DSSpace.s) {
            ForEach(topics) { HelpSceneCard(topic: $0, keys: keys).id($0.id) }
        }
    }

    private func topicList(_ topics: [HelpTopic]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(topics.enumerated()), id: \.element.id) { index, topic in
                if index > 0 { SettingsDivider() }
                HelpTopicRow(topic: topic, keys: keys, showsTab: searching,
                             expanded: searching && topics.count == 1 || open.contains(topic.id)) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if open.contains(topic.id) { open.remove(topic.id) } else { open.insert(topic.id) }
                    }
                }
                .id(topic.id)
            }
        }
        .padding(.vertical, DSSpace.xxs)
        .dsCardSurface()
    }

    private var footer: some View {
        HStack(spacing: DSSpace.xs) {
            Link("Report a problem on GitHub", destination: HelpView.issuesURL)
                .buttonStyle(.dsLink)
                .controlSize(.small)
            Text(HelpView.footerNote)
                .font(.dsCaption)
                .foregroundStyle(Color.dsTextTertiary)
        }
    }

    private static let issuesURL = URL(string: "https://github.com/noamlittvock/dictator/issues")!

    private static var footerNote: String {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "Dictator \($0). " } ?? ""
        return version + "Leave your dictation history out of the report."
    }

    private func consumeNavigation(_ scroller: ScrollViewProxy) {
        guard let id = navigation.helpTopicID else { return }
        navigation.helpTopicID = nil
        guard let topic = HelpLibrary.topics(keys: keys).first(where: { $0.id == id }) else { return }
        search = ""
        tab = topic.tab
        open.insert(id)
        // The tab's rows have to exist before there is anything to scroll to.
        DispatchQueue.main.async { scroller.scrollTo(id, anchor: .top) }
    }
}

/// A Basics card: the picture, a name and one line.
private struct HelpSceneCard: View {
    let topic: HelpTopic
    let keys: HotkeyTriggers

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            if let scene = topic.scene { HelpSceneView(scene: scene, keys: keys) }
            Text(topic.title).font(.dsSection).foregroundStyle(Color.dsTextPrimary)
            ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in HelpBlockView(block: block) }
            Spacer(minLength: 0)
            if let link = topic.link {
                Button(link.title) { AppNavigation.shared.open(link) }
                    .buttonStyle(.dsLink)
                    .controlSize(.small)
            }
        }
        .padding(DSSpace.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .dsCardSurface()
    }
}

/// One question or subject. Click the title to open it.
private struct HelpTopicRow: View {
    let topic: HelpTopic
    let keys: HotkeyTriggers
    let showsTab: Bool
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: DSSpace.xs) {
                    Image(systemName: "chevron.right")
                        .font(.dsIconSmall)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(Color.dsTextTertiary)
                        .frame(width: DSSpace.s)
                    if let icon = topic.icon {
                        Image(systemName: icon)
                            .font(.dsIcon)
                            .foregroundStyle(Color.dsTextSecondary)
                            .frame(width: DSSpace.m)
                    }
                    Text(topic.title)
                        .font(.dsBodyMedium)
                        .foregroundStyle(Color.dsTextPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: DSSpace.s)
                    if showsTab {
                        Text(topic.tab.title).font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
                    }
                }
                .padding(.horizontal, DSSpace.m)
                .padding(.vertical, DSSpace.s)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(expanded ? .isSelected : [])
            if expanded {
                VStack(alignment: .leading, spacing: DSSpace.s) {
                    if let scene = topic.scene { HelpSceneView(scene: scene, keys: keys) }
                    ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                        HelpBlockView(block: block)
                    }
                    if let link = topic.link {
                        Button(link.title) { AppNavigation.shared.open(link) }
                            .controlSize(.small)
                    }
                }
                .padding(.leading, DSSpace.m + DSSpace.s + DSSpace.xs)
                .padding(.trailing, DSSpace.m)
                .padding(.bottom, DSSpace.m)
            }
        }
    }
}

struct HelpBlockView: View {
    let block: HelpBlock

    var body: some View {
        switch block {
        case .text(let line):
            HelpLine(text: line)
        case .steps(let lines):
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: DSSpace.xs) {
                        DSStepBadge(number: index + 1)
                        HelpLine(text: line)
                    }
                }
            }
        case .items(let items):
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: DSSpace.xs) {
                        Image(systemName: item.symbol)
                            .font(.dsIcon)
                            .foregroundStyle(Color.dsAccent)
                            .frame(width: DSSpace.m + DSSpace.xxs)
                            .accessibilityHidden(true)
                        HelpLine(text: item.text)
                    }
                }
            }
        }
    }
}

/// One line of help, with `**bold**` for the names of things on screen.
struct HelpLine: View {
    let text: String

    var body: some View {
        Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
            .font(.dsBody)
            .foregroundStyle(Color.dsTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}
