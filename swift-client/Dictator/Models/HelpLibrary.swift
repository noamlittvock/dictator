import Foundation

// Everything the Help page and the "?" briefs say. It is data, so it can be
// searched and tested. When a feature changes, change its words here too.
//
// `**bold**` marks the name of something on screen. Text follows the key the
// user chose, so instructions match their keyboard.

enum HelpTab: String, CaseIterable, Identifiable {
    case basics, manual, advanced, faq

    var id: String { rawValue }

    var title: String {
        switch self {
        case .basics: "Basics"
        case .manual: "Manual"
        case .advanced: "Advanced"
        case .faq: "FAQ"
        }
    }
}

/// A small picture of something happening. Help shows first and explains
/// second, so most topics and briefs have one.
enum HelpScene: CaseIterable {
    case dictate, command, routine, cleanup, fixWord, recover
    case build, actions, share, monitors, macs, privacy, datasets, keys

    /// Frames play once in order and the last one stays on screen.
    var lastFrame: Int {
        switch self {
        case .cleanup, .actions, .privacy: 0
        case .routine, .fixWord, .recover, .build, .share, .datasets: 2
        case .macs, .monitors, .keys: 2
        case .dictate, .command: 3
        }
    }

    /// What the picture shows, for VoiceOver.
    var description: String {
        switch self {
        case .dictate: "Hold the dictation key and speak. When you let go, your words appear in the text field."
        case .command: "Hold both keys and say Open Safari. Safari opens."
        case .routine: "Scattered windows move into your saved layout."
        case .cleanup: "The same sentence at each clean-up level."
        case .fixWord: "The misheard word Clawed is replaced with Claude."
        case .recover: "A kept recording becomes text on the clipboard."
        case .build: "A spoken phrase runs two actions, one after the other."
        case .actions: "The kinds of actions a command can run."
        case .share: "A command is exported to a file and imported turned off."
        case .monitors: "A routine places apps on two monitors."
        case .macs: "A laptop records, a Mac mini keeps the history and a Mac Studio runs the AI models."
        case .privacy: "Dictations are saved. Typing is off until you choose apps."
        case .datasets: "Saved prompts are filtered into one dataset file."
        case .keys: "The keys that start dictation and run a command, which you can change."
        }
    }
}

enum HelpBlock: Equatable {
    case text(String)
    case steps([String])
    case items([HelpItem])

    var lines: [String] {
        switch self {
        case .text(let line): [line]
        case .steps(let lines): lines
        case .items(let items): items.map(\.text)
        }
    }
}

/// One short line with a symbol that carries the meaning.
struct HelpItem: Equatable {
    let symbol: String
    let text: String

    init(_ symbol: String, _ text: String) {
        self.symbol = symbol
        self.text = text
    }
}

/// A place in the app a topic can take you to.
enum HelpLink: Equatable {
    case page(SidebarItem)
    case settings(SettingsSection)

    var title: String {
        switch self {
        case .page(let item): "Open \(item.title)"
        case .settings(let section): "Open \(section.title) settings"
        }
    }
}

struct HelpTopic: Identifiable, Equatable {
    let id: String
    let tab: HelpTab
    let title: String
    var icon: String? = nil
    var scene: HelpScene? = nil
    var blocks: [HelpBlock] = []
    var link: HelpLink? = nil

    /// All the words of the topic, without the bold marks.
    var searchText: String {
        ([title] + blocks.flatMap(\.lines)).joined(separator: " ").replacingOccurrences(of: "**", with: "")
    }
}

/// The pages with a "?" next to their title.
enum HelpPage: CaseIterable {
    case home, commands, buildCommand, workspaces, dictionary, datasets
    case settingsGeneral, settingsMacs, settingsDictation, settingsHistory, settingsAdvanced

    init(settings section: SettingsSection) {
        switch section {
        case .general: self = .settingsGeneral
        case .macs: self = .settingsMacs
        case .dictation: self = .settingsDictation
        case .history, .typedApps: self = .settingsHistory
        case .advanced: self = .settingsAdvanced
        }
    }
}

/// What a page is for: a picture and one line.
struct PageBrief: Equatable {
    let title: String
    let summary: String
    var scene: HelpScene? = nil
    let topicID: String
}

enum HelpLibrary {
    /// Topics that contain every word of the search, title matches first.
    static func search(_ query: String, in topics: [HelpTopic]) -> [HelpTopic] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let matches = topics.filter { topic in
            words.allSatisfy { topic.searchText.localizedCaseInsensitiveContains($0) }
        }
        return matches.filter { topic in words.allSatisfy { topic.title.localizedCaseInsensitiveContains($0) } }
            + matches.filter { topic in !words.allSatisfy { topic.title.localizedCaseInsensitiveContains($0) } }
    }

    // MARK: - Page briefs

    static func brief(_ page: HelpPage, keys: HotkeyTriggers = .current) -> PageBrief {
        switch page {
        case .home:
            PageBrief(title: "Home", summary: "Everything you’ve said, and what ran. Hold **\(keys.dictation.displayName)** to dictate.",
                      scene: .dictate, topicID: "manual-home")
        case .commands:
            PageBrief(title: "Commands", summary: "Turn on a card, hold **\(keys.commands.symbolName)** and say it.",
                      scene: .command, topicID: "manual-commands")
        case .buildCommand:
            PageBrief(title: "Build a command", summary: "One phrase, as many actions as you like.",
                      scene: .build, topicID: "advanced-build")
        case .workspaces:
            PageBrief(title: "Workspaces", summary: "Save a window layout. Bring it back with one phrase.",
                      scene: .routine, topicID: "manual-workspaces")
        case .dictionary:
            PageBrief(title: "Dictionary", summary: "Teach Dictator your names and words.",
                      scene: .fixWord, topicID: "manual-dictionary")
        case .datasets:
            PageBrief(title: "Datasets", summary: "Turn saved prompts into a file for the AI tool you choose.",
                      scene: .datasets, topicID: "manual-datasets")
        case .settingsGeneral:
            PageBrief(title: "General settings", summary: "Your keys, your microphone and startup.",
                      scene: .keys, topicID: "manual-settings")
        case .settingsMacs:
            PageBrief(title: "Your Macs", summary: "Give each of your Macs a job.",
                      scene: .macs, topicID: "advanced-macs")
        case .settingsDictation:
            PageBrief(title: "Dictation settings", summary: "Choose how much your words get cleaned up.",
                      scene: .cleanup, topicID: "basics-cleanup")
        case .settingsHistory:
            PageBrief(title: "History & Privacy", summary: "Choose what stays on your Macs.",
                      scene: .privacy, topicID: "faq-saved")
        case .settingsAdvanced:
            PageBrief(title: "Advanced settings", summary: "Connection details. Change these only if something isn’t working.",
                      topicID: "advanced-macs")
        }
    }

    // MARK: - Topics

    static func topics(keys: HotkeyTriggers = .current) -> [HelpTopic] {
        basics + manual(keys) + advanced + faq(keys)
    }

    private static let basics: [HelpTopic] = [
        HelpTopic(id: "basics-dictate", tab: .basics, title: "Dictate", scene: .dictate, blocks: [
            .text("Hold, talk, let go. Esc cancels."),
        ], link: .settings(.general)),
        HelpTopic(id: "basics-command", tab: .basics, title: "Run a command", scene: .command, blocks: [
            .text("Turn on a card, then say it."),
        ], link: .page(.voiceLaunch)),
        HelpTopic(id: "basics-routine", tab: .basics, title: "Bring back your windows", scene: .routine, blocks: [
            .text("Press **Remember**. Run it any time."),
        ], link: .page(.workspaceLaunch)),
        HelpTopic(id: "basics-cleanup", tab: .basics, title: "Choose your clean-up", scene: .cleanup, blocks: [
            .text("Clean-up needs an AI model in Your Macs."),
        ], link: .settings(.dictation)),
        HelpTopic(id: "basics-fix-word", tab: .basics, title: "Fix a word", scene: .fixWord, blocks: [
            .text("Right-click a dictation on Home."),
        ], link: .page(.dictionary)),
        HelpTopic(id: "basics-recover", tab: .basics, title: "Rescue a dictation", scene: .recover, blocks: [
            .text("Failed recordings wait on Home for 14 days."),
        ], link: .page(.home)),
    ]

    private static func manual(_ keys: HotkeyTriggers) -> [HelpTopic] {
        [
            HelpTopic(id: "manual-home", tab: .manual, title: "Home", icon: SidebarItem.home.icon, scene: .dictate, blocks: [
                .items([HelpItem("clock.arrow.circlepath", "**Recent commands:** what ran on this Mac"),
                        HelpItem("tag", "Click a tag: what was heard, what was typed"),
                        HelpItem("cursorarrow.click.2", "Right-click: fix a word, or delete"),
                        HelpItem("waveform.badge.exclamationmark", "Failed recordings wait here")]),
            ], link: .page(.home)),
            HelpTopic(id: "manual-commands", tab: .manual, title: "Commands", icon: SidebarItem.voiceLaunch.icon, scene: .command, blocks: [
                .text("Hold **\(keys.commands.symbolName)** and say it."),
                .items([HelpItem("switch.2", "**Things to say:** turn on a card"),
                        HelpItem("person.2", "**People:** names you can say"),
                        HelpItem("square.2.layers.3d", "**Apple Shortcuts:** after you turn on **Run a Shortcut**"),
                        HelpItem("hammer", "**Build a command…**: your own phrase and actions"),
                        HelpItem("square.and.arrow.up", "**Import…** and **Export…**: share commands")]),
            ], link: .page(.voiceLaunch)),
            HelpTopic(id: "manual-workspaces", tab: .manual, title: "Workspaces", icon: SidebarItem.workspaceLaunch.icon, scene: .routine, blocks: [
                .items([HelpItem("eye", "**Preview:** see the changes first"),
                        HelpItem("play", "**Run:** do it"),
                        HelpItem("arrow.uturn.backward", "**Undo:** put windows back"),
                        HelpItem("pencil", "**Edit:** steps and keyboard shortcut"),
                        HelpItem("mic", "**Add a voice command:** give it a phrase")]),
            ], link: .page(.workspaceLaunch)),
            HelpTopic(id: "manual-dictionary", tab: .manual, title: "Dictionary", icon: SidebarItem.dictionary.icon, scene: .fixWord, blocks: [
                .items([HelpItem("graduationcap", "**Your fields:** common words for your subjects"),
                        HelpItem("plus", "**Add** a word, or how it gets misheard"),
                        HelpItem("star", "Star a word to keep it up front"),
                        HelpItem("ellipsis.circle", "**More:** learning, import and export")]),
            ], link: .page(.dictionary)),
            HelpTopic(id: "manual-datasets", tab: .manual, title: "Datasets", icon: SidebarItem.datasets.icon, scene: .datasets, blocks: [
                .items([HelpItem("line.3.horizontal.decrease", "Filter by text, date and where it was sent"),
                        HelpItem("wand.and.stars", "**Cleaning and privacy:** choose what stays"),
                        HelpItem("doc", "Make a JSONL, JSON or CSV file"),
                        HelpItem("terminal", "Run a local tool on it"),
                        HelpItem("lock", "Your history never changes")]),
            ], link: .page(.datasets)),
            HelpTopic(id: "manual-settings", tab: .manual, title: "Settings", icon: SidebarItem.settings.icon, scene: .keys, blocks: [
                .items([HelpItem("keyboard", "**General:** your keys, microphone, startup"),
                        HelpItem("macmini", "**Your Macs:** connect Macs, add AI models"),
                        HelpItem("text.badge.checkmark", "**Dictation:** clean-up and languages"),
                        HelpItem("lock", "**History & Privacy:** what gets saved"),
                        HelpItem("wrench.and.screwdriver", "**Advanced:** only if something isn’t working")]),
            ], link: .page(.settings)),
            HelpTopic(id: "manual-menu-bar", tab: .manual, title: "The menu bar icon", icon: "menubar.arrow.up.rectangle", blocks: [
                .items([HelpItem("exclamationmark.circle", "Status, and any problem with its fix"),
                        HelpItem("wand.and.stars", "Clean-up level"),
                        HelpItem("rectangle.3.group", "Your routines"),
                        HelpItem("doc.on.doc", "**Copy Last Dictation** and **Run Again**")]),
            ]),
        ]
    }

    private static let advanced: [HelpTopic] = [
        HelpTopic(id: "advanced-build", tab: .advanced, title: "Build your own command", icon: "hammer", scene: .build, blocks: [
            .steps(["Press **Build a command…** on both Commands screens.",
                    "Fill in **What do you say?**",
                    "Fill in **What should happen?** Actions run in order."]),
        ], link: .page(.voiceLaunch)),
        HelpTopic(id: "advanced-actions", tab: .advanced, title: "What a command can do", icon: "bolt", scene: .actions, blocks: [
            .items([HelpItem("escape", "Esc cancels before anything sends"),
                    HelpItem("terminal", "Terminal gets your words only as a quoted argument")]),
        ]),
        HelpTopic(id: "advanced-tune", tab: .advanced, title: "Fine-tune a command", icon: "slider.horizontal.3", blocks: [
            .items([HelpItem("keyboard", "**Keyboard shortcut:** run it without speaking"),
                    HelpItem("app.badge", "**Only in these apps:** one phrase, different apps"),
                    HelpItem("ear", "**Also listen for:** other ways it’s heard"),
                    HelpItem("mic", "**Teach:** say it a few times")]),
        ]),
        HelpTopic(id: "advanced-share", tab: .advanced, title: "Share commands", icon: "square.and.arrow.up", scene: .share, blocks: [
            .items([HelpItem("switch.2", "Imported commands arrive turned off"),
                    HelpItem("person.crop.circle.badge.xmark", "People’s details stay out unless you add them"),
                    HelpItem("link", "**Let other apps start this:** run it from a dictator:// link")]),
        ], link: .page(.voiceLaunch)),
        HelpTopic(id: "advanced-routines", tab: .advanced, title: "Routines across monitors and Macs", icon: "display.2", scene: .monitors, blocks: [
            .items([HelpItem("rectangle.split.2x1", "**Place apps:** choose the Mac, monitor and position"),
                    HelpItem("globe", "**Open tabs:** your pages, browser and profile"),
                    HelpItem("eye.slash", "**Show only this routine’s windows:** hide the rest")]),
        ], link: .page(.workspaceLaunch)),
        HelpTopic(id: "advanced-macs", tab: .advanced, title: "Use more than one Mac", icon: "macmini", scene: .macs, blocks: [
            .steps(["Sign both Macs in to the same Tailscale account.",
                    "On your main Mac, press **Add a Mac**.",
                    "On the other Mac, choose **Join Another Mac’s Setup…**"]),
        ], link: .settings(.macs)),
        HelpTopic(id: "advanced-typed", tab: .advanced, title: "Save what you type in apps you choose", icon: "keyboard", scene: .privacy, blocks: [
            .items([HelpItem("hand.raised", "Off until you choose apps"),
                    HelpItem("key", "Password boxes are skipped"),
                    HelpItem("pause", "Pause it whenever you like")]),
        ], link: .settings(.history)),
    ]

    private static func faq(_ keys: HotkeyTriggers) -> [HelpTopic] {
        [
            HelpTopic(id: "faq-nothing-typed", tab: .faq, title: "I spoke and nothing was typed", blocks: [
                .items([HelpItem("character.cursor.ibeam", "Click in a text field first"),
                        HelpItem("doc.on.clipboard", "Blocked by the app? Your text is on the clipboard: press ⌘V"),
                        HelpItem("menubar.arrow.up.rectangle", "Check the menu bar icon for a fix"),
                        HelpItem("waveform.badge.exclamationmark", "Failed recordings wait on Home")]),
            ], link: .page(.home)),
            HelpTopic(id: "faq-key", tab: .faq, title: "Pressing the key does nothing", blocks: [
                .text("Your dictation keys are **\(keys.dictation.displayName)**."),
                .items([HelpItem("menubar.arrow.up.rectangle", "Follow any notice in the menu bar icon"),
                        HelpItem("lock.shield", "Turn on Dictator for Microphone, Input Monitoring and Accessibility in System Settings"),
                        HelpItem("arrow.clockwise", "Choose **Try Again** or **Relaunch Dictator**")]),
            ], link: .settings(.general)),
            HelpTopic(id: "faq-command", tab: .faq, title: "My command didn’t run", blocks: [
                .items([HelpItem("switch.2", "Check it’s turned on"),
                        HelpItem("keyboard", "Hold **\(keys.commands.symbolName)**"),
                        HelpItem("text.quote", "Start with its opening words"),
                        HelpItem("ear", "Misheard? Use **Teach** or **Also listen for**"),
                        HelpItem("doc.on.clipboard", "No match? Your words are on the clipboard")]),
            ], link: .page(.voiceLaunch)),
            HelpTopic(id: "faq-cleanup", tab: .faq, title: "My text isn’t being cleaned up", blocks: [
                .text("Clean-up needs an Ollama AI model. Add one in Your Macs."),
            ], link: .settings(.macs)),
            HelpTopic(id: "faq-window", tab: .faq, title: "A routine left a window where it was", blocks: [
                .items([HelpItem("rectangle.on.rectangle", "On another desktop? Switch there and run it again"),
                        HelpItem("lock.shield", "Check the Accessibility permission"),
                        HelpItem("arrow.uturn.backward", "**Undo** puts windows back")]),
            ], link: .page(.workspaceLaunch)),
            HelpTopic(id: "faq-mic", tab: .faq, title: "Why does macOS show the microphone in use?", blocks: [
                .text("The audio engine stays ready for your key. Idle audio is never saved or sent."),
            ]),
            HelpTopic(id: "faq-saved", tab: .faq, title: "What does Dictator save, and where?", scene: .privacy, blocks: [
                .text("Your dictations, on your own Macs. Typing, only in apps you choose."),
            ], link: .settings(.history)),
            HelpTopic(id: "faq-cloud", tab: .faq, title: "Does anything go to the cloud?", blocks: [
                .text("Your voice doesn’t. Speech and clean-up run on your Macs. These do go online:"),
                .items([HelpItem("arrow.down.circle", "Model downloads from Hugging Face, Ollama and Apple"),
                        HelpItem("arrow.triangle.2.circlepath", "Update checks to GitHub, unless you turn them off"),
                        HelpItem("globe", "Websites your commands open, and website icons"),
                        HelpItem("terminal", "Datasets you export, or send to a tool you set up")]),
            ]),
            HelpTopic(id: "faq-keys", tab: .faq, title: "Can I change the keys?", scene: .keys, blocks: [
                .text("Yes. In Settings › General, click a key, then press any key or combination."),
            ], link: .settings(.general)),
            HelpTopic(id: "faq-macs", tab: .faq, title: "Do I need more than one Mac?", blocks: [
                .text("No. One Mac is enough, with no Tailscale needed."),
            ], link: .settings(.macs)),
            HelpTopic(id: "faq-language", tab: .faq, title: "Can I dictate in other languages?", blocks: [
                .text("Yes. Choose them in Settings › Dictation."),
            ], link: .settings(.dictation)),
            HelpTopic(id: "faq-updates", tab: .faq, title: "How do I update Dictator?", blocks: [
                .text("Choose **Check for Updates…** from the menu bar icon."),
            ]),
        ]
    }
}
