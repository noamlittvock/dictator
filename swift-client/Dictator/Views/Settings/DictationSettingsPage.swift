import SwiftUI

/// Settings › Dictation: what happens to your words after you speak.
struct DictationSettingsPage: View {
    @State private var settings = AppSettings.shared
    @State private var viewModel = DictatorViewModel.shared
    @Environment(\.repositoryHub) private var hub
    @State private var cleanupSummary: String?

    var body: some View {
        SettingsPage(title: "Dictation", summary: "What happens to your words after you speak.") {
            SettingsSectionCard(title: "Cleaning up your words", footer: cleanupFooter) {
                SettingsChoiceRow(
                    title: RefineLevel.exact.title,
                    detail: "Keep your words as they were heard. Your dictionary still applies.",
                    selected: settings.refineLevel == .exact
                ) { settings.refineLevel = .exact }
                SettingsDivider()
                SettingsChoiceRow(
                    title: RefineLevel.medium.title,
                    detail: "Removes “um”s and repeated words, and fixes punctuation and capital letters.",
                    selected: settings.refineLevel == .medium
                ) { settings.refineLevel = .medium }
                SettingsDivider()
                SettingsChoiceRow(
                    title: RefineLevel.polished.title,
                    detail: "Also fixes grammar and tightens sentences. This can change your wording.",
                    selected: settings.refineLevel == .polished
                ) { settings.refineLevel = .polished }
                SettingsDivider()
                SettingsRow(title: "You say: \(Self.example(.exact))", detail: "Dictator types: \(Self.example(settings.refineLevel))") { EmptyView() }
                if let cleanupSummary {
                    SettingsDivider()
                    SettingsRow(title: "How it’s going", detail: cleanupSummary) {
                        Button("See on Home") { AppNavigation.shared.mainSelection = .home }
                    }
                }
                if cleanupStatus == .notSetUp {
                    SettingsDivider()
                    SettingsRow(title: "Add an AI model for clean-up") {
                        Button("Your Macs") { AppNavigation.shared.settingsSection = .macs }
                    }
                }
            }

            SettingsSectionCard(title: "Languages", footer: "Tells the speech model which languages to expect. Mixing languages can change or lose words.") {
                SettingsRow(title: "Languages you speak") {
                    HStack(spacing: DSSpace.xs) {
                        ForEach(settings.dictationLanguages, id: \.self) { code in
                            HStack(spacing: DSSpace.xxs) {
                                Text(Self.languageName(code)).font(.dsSecondary)
                                if settings.dictationLanguages.count > 1 {
                                    Button {
                                        setLanguages(settings.dictationLanguages.filter { $0 != code })
                                    } label: {
                                        Image(systemName: "xmark").font(.dsIconSmall)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove \(Self.languageName(code))")
                                    .help("Remove \(Self.languageName(code))")
                                }
                            }
                            .padding(.horizontal, DSSpace.xs)
                            .padding(.vertical, DSSpace.hair)
                            .background(Color.dsSurfaceRaised, in: Capsule())
                        }
                        Menu("Add") {
                            ForEach(Self.commonLanguages.filter { !settings.dictationLanguages.contains($0) }, id: \.self) { code in
                                Button(Self.languageName(code)) { setLanguages(settings.dictationLanguages + [code]) }
                            }
                        }
                        .fixedSize()
                    }
                }
            }

            SettingsSectionCard(title: "Spelling") {
                SettingsRow(title: "Your words and fields", detail: "Dictator learns spellings. Star words and choose fields in Dictionary.") {
                    Button("Open Dictionary") { AppNavigation.shared.mainSelection = .dictionary }
                }
            }

            SettingsSectionCard(title: "Datasets") {
                SettingsRow(title: "Prepare your history for analysis", detail: "Filter and export your prompts, the apps they went to and their timings.") {
                    Button("Open Datasets") { AppNavigation.shared.openDatasets() }
                }
            }
        }
        .task(id: hub?.historyVersion) {
            guard let hub, let entries = try? await hub.current.history.page(limit: 50, before: nil) else { return }
            cleanupSummary = CleanupSummary(entries).line
        }
    }

    /// The same sentence at the chosen level, so the choice can be seen.
    /// These are real results from the default clean-up model.
    static func example(_ level: RefineLevel) -> String {
        switch level {
        case .exact: "so um me and sarah was thinking we could like try a different approach"
        case .medium: "So me and Sarah was thinking we could like try a different approach."
        case .polished: "Sarah and I were thinking we could try a different approach."
        }
    }

    private func setLanguages(_ codes: [String]) {
        settings.updateSetupRouting { $0.languages = codes }
    }

    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    /// Common language choices offered in the Add menu; not an accuracy guarantee.
    static let commonLanguages = ["en", "he", "ar", "es", "fr", "de", "it", "pt", "nl", "ru", "uk", "pl", "cs", "sv", "da", "no", "fi",
                                  "tr", "el", "hi", "ja", "ko", "zh", "vi", "th", "id", "ms", "ro", "hu", "ca"]
        .sorted { languageName($0) < languageName($1) }

    private var cleanupStatus: CleanupStatus {
        CleanupStatus.evaluate(refineLevel: settings.refineLevel, routing: settings.setupRouting, snapshot: viewModel.setupSnapshot)
    }

    /// Which AI model cleans up and on which Mac, when known.
    private var cleanupFooter: String? {
        if cleanupStatus == .notSetUp {
            return "Clean-up needs an AI model; until you add one in Your Macs, words are typed as they were heard."
        }
        guard settings.refineLevel != .exact,
              let snapshot = viewModel.setupSnapshot, let speech = snapshot.speech,
              let modelID = speech.cleanupModel else { return nil }
        let model = ModelCatalog.name(of: modelID)
        let mac = snapshot.machineName(speech.cleanupMachineId) ?? "the speech server"
        if settings.coreRole == .edge, !viewModel.isConnectedEdgeRole {
            return "Your main Mac isn’t connected. Check clean-up availability in Your Macs."
        }
        if !speech.reachable {
            return "Clean-up is done by \(model) on \(mac), which can’t be reached right now."
        }
        return "Clean-up is done by \(model) on \(mac)."
    }
}
