import Foundation

// The words "Build a command" show in one place, so a test can check that
// none of them shows how it works underneath (curly or square brackets, or
// words like "slot" or "pattern"). Views use these; the engine is untouched.

enum VoiceBuildCopy {
    // MARK: Page

    static let pageTitle = "Build a command"
    static let pageSummary = "Choose a phrase and the actions it runs."
    static let yourCommands = "Your commands"
    static let unmatchedFooter = "If no command matches, Dictator copies your words to the clipboard and says so."
    static let noCommands = "No commands yet"
    static let noCommandsHelp = "Build one here, or turn on a command from the previous page."
    static let makeYourOwn = "Build a command…"
    static let newCommand = "New command"
    static let editCommand = "Edit command"
    static let nameLabel = "Name"
    static let namePlaceholder = "For example: YouTube"
    static let turnedOn = "Turned on"
    static let giveName = "Give it a name."

    // MARK: What do you say?

    static let whatDoYouSay = "What do you say?"
    static let whatDoYouSayHelp = "Start with the word that runs the command, then add what comes next."
    static let openingLabel = "Opening words"
    static let openingPlaceholder = "For example: WhatsApp"
    static let addSomeone = "+ Someone from People"
    static let addProject = "+ A project"
    static let addOtherList = "+ Something from another list"
    static let addWords = "+ Your words"
    static let addMarker = "+ A word that starts a new part"
    static let wordsNamePrompt = "Give your words a short name, like message or search."
    static let wordsNameDefault = "message"
    static let markerPrompt = "The word you say to start the new part, like subject."
    static let markerPlaceholder = "subject"
    static let addButton = "Add"
    static let cancelButton = "Cancel"
    static let canBeSkipped = "Can be skipped"
    static let howItSounds = "How it sounds"
    static let examplePrefix = "Example: "
    static let alsoListenFor = "Also listen for"
    static let alsoListenPlaceholder = "Other ways it is heard, separated by commas"
    static let teach = "Teach"
    static let teachHelp = "Say the first words a few times so Dictator learns how they are heard."
    static let sentenceOtherWay = "This sentence was set up another way, so it can’t be changed here."
    static let startAgain = "Start again"

    // MARK: What should happen?

    static let whatShouldHappen = "What should happen?"
    static let whatShouldHappenHelp = "Actions run in this order."
    static let addAction = "Add an action"
    static let noActions = "No actions yet. Add one to run."
    static let pauseHelp = "Before anything is sent for real, Dictator pauses so you can press Esc to cancel."
    static let cleanUpTitle = "Clean up my words first"
    static let cleanUpHelp = "Removes “um”s and fixes punctuation. Leave it off for searches."
    static let insertLabel = "Insert:"
    static let edit = "Edit"
    static let done = "Done"
    static let moveUp = "Move up"
    static let moveDown = "Move down"
    static let removeAction = "Remove this action"
    static let moveLeft = "Move left"
    static let moveRight = "Move right"
    static let removePiece = "Remove this piece"

    static let websiteFromExample = "Build it from an example"
    static let websiteExampleHelp = "Search the site for the word TEST, then paste the address here."
    static let pasteAddressPlaceholder = "Paste the address"
    static let useThisAddress = "Use this address"
    static let putInPlaceOfTest = "Put in place of TEST:"
    static let editAddress = "Edit the address"
    static let addressLabel = "Address"
    static let addressAdded = "The word TEST will be replaced by what you say."
    static let testNotFound = "TEST isn’t in that address. Search the site for TEST again and paste the new address."
    static let notAnAddress = "That doesn’t look like a web address."
    static let needWordsFirst = "Add your words to the sentence first, so there is something to put in."
    static let chooseApp = "Choose app…"
    static let noAppChosen = "No app chosen"
    static let chooseFolder = "Choose…"
    static let folderLabel = "Folder"
    static let aFolderIChoose = "A folder I choose"
    static let assistantLabel = "Coding agent"
    static let openInLabel = "Open it in"
    static let openInHelp = "This Mac only."
    static let whatToGiveIt = "What to give it"
    static let whatToType = "What to type"
    static let whatToShow = "What to show"
    static let giveUpAfter = "Give up after"
    static let keyLabel = "Key"
    static let appleShortcutName = "Name of the Apple Shortcut"
    static let chooseShortcut = "Shortcut"
    static let chooseShortcutPlaceholder = "Choose a Shortcut"
    static let refreshShortcuts = "Refresh"
    static let openInShortcuts = "Open in Shortcuts"
    static let newShortcutButton = "New Shortcut"
    static let shortcutHelp = "Your Shortcut gets what you said. Add “Get Dictionary from Input” in it to use each part."
    static let shortcutResponsibility = "Your words go to the Apple Shortcut. Its actions run as you built them."
    static let shortcutListFailed = "Couldn’t read the Shortcuts on this Mac. You can type the name instead."
    static let shortcutNotInList = "Not among this Mac’s Shortcuts"
    static let sendEverything = "Everything I said (recommended)"
    static let sendJustWords = "Just my words"
    static let whatToSend = "What it gets"
    static let timeLimit = "Give up after"
    static let doesntSend = "Doesn’t send or change anything"
    static let doesntSendHelp = "For one that only looks something up. Dictator then doesn’t pause before it."
    static let typeItsAnswer = "Type its answer where my cursor is"
    static let typeTheAnswer = "Type the answer"
    static let answerPartsLabel = "Parts of its answer to use"
    static let answerPartsPlaceholder = "Names separated by commas, like title, date"
    static let answerPartsHelp = "If it answers with named parts, list them to use each one."
    static func seconds(_ value: Int) -> String { "\(value) seconds" }
    static func answerTooEarly(_ action: Int) -> String {
        "Action \(action) uses an answer before the Apple Shortcut that gives it has run. Move that Shortcut up."
    }
    static let webhookAddress = "Address to send to"
    static let webhookHelp = "Sends what you said to that address."
    static let fileLabel = "File"
    static let lineToAdd = "Line to add"
    static let chooseFileMessage = "Choose a file to add lines to. To start a new one, type its path instead."

    // MARK: Lists

    static let yourLists = "Your lists"
    static let listsFooter = "People, projects and anything else you can say by name."
    static let noLists = "No lists yet"
    static let noListsHelp = "Turning on a card creates the list it needs."
    static let newList = "New list…"
    static let newListRow = "New list"
    static let editList = "Edit list"
    static let listNameLabel = "Name of the list"
    static let detailsTitle = "Details for each entry"
    static let detailsHelp = "Things an action can use, like a phone number or a folder."
    static let addDetailPlaceholder = "Add a detail, like phone"
    static let entriesTitle = "Entries"
    static let entryNamePlaceholder = "Name"
    static let alsoCalledPlaceholder = "Also called, separated by commas"
    static let addEntry = "Add an entry"
    static let entriesHelp = "“Also called” is for other ways it might be said or heard, like a nickname."
    static let removeEntry = "Remove this entry"

    // MARK: Try it

    static let tryIt = "Try it"
    static let tryItFooter = "Nothing runs here. It shows what would happen."
    static let tryItPlaceholder = "WhatsApp Dana I’ll be late"
    static let wouldDo = "Would do"

    /// Shared with Workspace launch so its help follows this Mac's Commands keys.
    static func howToSay(keys: KeyCombo, phrase: String? = nil) -> String {
        let keys = keys.symbolName
        return phrase.map { "Hold \(keys) and say “\($0)”." } ?? "Hold \(keys) and say what you want."
    }

    // MARK: Problems

    static let needOpening = "Start with the word or words you say first, like “WhatsApp”."
    static let openingNeedsLetters = "The first word needs letters or digits."
    static let markerNeedsWord = "A word that starts a new part can’t be empty."
    static let duplicateNames = "Two pieces have the same name. Give each its own name."
    static let sentenceTooLong = "That sentence is too long."
    static let wordsNeedMarker = "Your words need to come last, or be followed by a word that starts a new part."
    static let skippedWordsNeedMarker = "Words that can be skipped need a word that starts a new part after them, or must come last."
    static let sentenceNotReady = "Dictator can’t follow this sentence. Try moving or removing a piece."
    static let needAnAction = "Add something for it to do."
    static let notReady = "This can’t be saved yet. Check what you say and what should happen."
    static let sameSentence = "Another command is said the same way."
    static let needCancelPause = "Add “Wait for me to cancel” before an action that sends something for real."

    static func missingList(_ list: String) -> String { "“\(list)” isn’t one of your lists yet." }
    static func duplicateName(_ name: String) -> String { "Two pieces are called “\(name)”. Give each its own name." }
    static func teachTitle(_ words: String) -> String { "Teach Dictator “\(words)”" }
    static func teachHelpFor(_ words: String) -> String {
        "If Dictator keeps mishearing “\(words)”, Teach listens to you say it and adds the ways it was heard."
    }
    static func removeNamed(_ name: String) -> String { "Remove \(name)" }
    static func unknownValue(_ action: Int, _ name: String) -> String {
        "Action \(action) uses “\(name)”, which isn’t in what you say."
    }
    static func actionNeeds(_ action: Int, _ what: String) -> String { "Action \(action): \(what)" }

    // MARK: Actions

    /// Every action, in the order the menu offers them.
    static let actionOrder: [VoiceStep.Kind] = [
        .openLink, .openApp, .runWorkspace, .waitForTextField, .typeText, .runInTerminal, .confirm,
        .pressKey, .runAppleShortcut, .webhook, .appendToFile,
    ]

    static func actionLabel(_ kind: VoiceStep.Kind) -> String {
        switch kind {
        case .openLink: "Open a website"
        case .openApp: "Open an app"
        case .runWorkspace: "Run a routine"
        case .waitForTextField: "Wait until I can type"
        case .typeText: "Type my words"
        case .runInTerminal: "Run a command in a folder"
        case .confirm: "Wait for me to cancel (3 seconds)"
        case .pressKey: "Press a key"
        case .runAppleShortcut: "Run an Apple Shortcut"
        case .webhook: "Send to n8n, Zapier or another webhook"
        case .appendToFile: "Add a line to a file"
        }
    }

    /// What the menu offers: every action this build can run.
    static func addable(supported: Set<VoiceStep.Kind> = VoiceLaunchExecutor.supportedKinds) -> [VoiceStep.Kind] {
        actionOrder.filter { supported.contains($0) }
    }

    /// The card title. The pause shows its real length.
    static func cardTitle(_ step: VoiceStep) -> String {
        if step.kind == .typeText, let text = step.text, VoiceTemplate.segments(text).count == 1,
           case .reference(let slot, nil)? = VoiceTemplate.segments(text).first, slot.hasPrefix(VoiceStep.answerPrefix) {
            return typeTheAnswer
        }
        guard step.kind == .confirm else { return actionLabel(step.kind) }
        let seconds = Int(step.seconds ?? VoiceStep.defaultConfirmSeconds)
        return "Wait for me to cancel (\(seconds) second\(seconds == 1 ? "" : "s"))"
    }

    static func keyChoice(_ key: String) -> String {
        switch key {
        case "return": "Return (send)"
        case "cmdReturn": "⌘Return (send)"
        case "tab": "Tab"
        case "escape": "Esc"
        default: "a key"
        }
    }

    /// One line in plain words about what an action will do.
    /// One plain line about what a shortcut does: "Opens youtube.com, then presses Return".
    static func summary(of steps: [VoiceStep], routines: [WorkspaceRoutine] = []) -> String {
        steps.filter { $0.kind != .confirm }.map { summary($0, routines: routines) }.enumerated().map { index, phrase in
            index == 0 ? phrase : phrase.prefix(1).lowercased() + phrase.dropFirst()
        }.joined(separator: ", then ")
    }

    static func summary(_ step: VoiceStep, values: [InsertableValue] = [], routines: [WorkspaceRoutine] = []) -> String {
        func plain(_ text: String?) -> String { ValueText.plain(text ?? "", values: values) }
        switch step.kind {
        case .openLink:
            let url = URL(string: (step.link ?? "").replacingOccurrences(of: "{", with: "x").replacingOccurrences(of: "}", with: "x"))
            let scheme = url?.scheme?.lowercased() ?? ""
            if scheme == "whatsapp" { return "Opens WhatsApp" }
            if ["http", "https"].contains(scheme), let host = url?.host { return "Opens \(host)" }
            return scheme.isEmpty || scheme == "https" || scheme == "http" ? "Opens a website" : "Opens a link"
        case .openApp:
            let id = step.bundleId ?? ""
            return id.isEmpty ? ((step.text ?? "").isEmpty ? "Opens an app" : "Opens “\(plain(step.text))”") : "Opens \(VoiceAppNames.name(for: id) ?? id)"
        case .runWorkspace:
            if let id = step.workspaceId {
                return routines.first { $0.id == id }.map { "Runs routine “\($0.name)”" } ?? "Runs a routine that was removed"
            }
            return (step.text ?? "").isEmpty ? "Runs a routine" : "Runs routine “\(plain(step.text))”"
        case .waitForTextField:
            return "Waits up to \(Int(step.seconds ?? VoiceStep.defaultWaitSeconds)) seconds for a place to type"
        case .typeText:
            return (step.text ?? "").isEmpty ? "Types nothing yet" : "Types “\(plain(step.text))”"
        case .runInTerminal:
            if step.background == true {
                let command = (step.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return command.isEmpty ? "Needs a command to run in the background" : "Runs “\(command)” in the background"
            }
            let assistant = CodingAssistant.named(forCommand: step.command ?? VoiceLaunchConfig.defaultAgentCommand).name
            let folder = step.folder ?? ""
            if folder.isEmpty { return "Starts \(assistant) in a folder" }
            if folder.hasPrefix("{") { return "Starts \(assistant) in \(plain(folder))" }
            return "Starts \(assistant) in \((folder as NSString).lastPathComponent)"
        case .confirm:
            return "Shows what is about to happen and waits"
        case .pressKey:
            return "Presses \(keyChoice(step.key ?? "return"))"
        case .runAppleShortcut:
            let name = step.shortcutName ?? ""
            guard !name.isEmpty else { return "Runs an Apple Shortcut" }
            if VoiceStep.isTemplate(name) { return "Runs the Shortcut you name, with everything you said" }
            return step.sendsEverything ? "Runs “\(name)” with everything you said" : "Runs “\(name)”"
        case .webhook:
            return "Sends to \(URL(string: step.link ?? "")?.host ?? "a web address")"
        case .appendToFile:
            let file = ((step.path ?? "") as NSString).lastPathComponent
            return file.isEmpty ? "Adds a line to a file" : "Adds a line to \(file)"
        }
    }

    /// Every fixed string above, and samples of the ones with a name in them,
    /// so a test can check the wording rules on all of it.
    static var allText: [String] {
        var text = [
            pageTitle, pageSummary, yourCommands, unmatchedFooter, noCommands, noCommandsHelp, makeYourOwn, newCommand,
            editCommand, nameLabel, namePlaceholder, turnedOn, giveName,
            whatDoYouSay, whatDoYouSayHelp, openingLabel, openingPlaceholder, addSomeone, addProject, addOtherList, addWords,
            addMarker, wordsNamePrompt, wordsNameDefault, markerPrompt, markerPlaceholder, addButton, cancelButton, canBeSkipped,
            howItSounds, examplePrefix, alsoListenFor, alsoListenPlaceholder, teach, teachHelp, sentenceOtherWay, startAgain,
            whatShouldHappen, whatShouldHappenHelp, addAction, noActions, pauseHelp, cleanUpTitle, cleanUpHelp, insertLabel,
            edit, done, moveUp, moveDown, removeAction, moveLeft, moveRight, removePiece,
            websiteFromExample, websiteExampleHelp, pasteAddressPlaceholder, useThisAddress, putInPlaceOfTest, editAddress,
            addressLabel, addressAdded, testNotFound, notAnAddress, needWordsFirst, chooseApp, noAppChosen, chooseFolder,
            folderLabel, aFolderIChoose, assistantLabel, openInLabel, openInHelp, whatToGiveIt, whatToType, whatToShow,
            giveUpAfter, keyLabel, appleShortcutName, chooseShortcut, chooseShortcutPlaceholder, refreshShortcuts, openInShortcuts,
            newShortcutButton, shortcutHelp, shortcutResponsibility, shortcutListFailed, shortcutNotInList, sendEverything,
            sendJustWords, whatToSend, timeLimit, doesntSend, doesntSendHelp, typeItsAnswer, typeTheAnswer, answerPartsLabel,
            answerPartsPlaceholder, answerPartsHelp, seconds(30), answerTooEarly(2), webhookAddress, webhookHelp, fileLabel, lineToAdd, chooseFileMessage,
            yourLists, listsFooter, noLists, noListsHelp, newList, newListRow, editList, listNameLabel, detailsTitle, detailsHelp,
            addDetailPlaceholder, entriesTitle, entryNamePlaceholder, alsoCalledPlaceholder, addEntry, entriesHelp, removeEntry,
            tryIt, tryItFooter, tryItPlaceholder, wouldDo,
            needOpening, openingNeedsLetters, markerNeedsWord, duplicateNames, sentenceTooLong, wordsNeedMarker,
            skippedWordsNeedMarker, sentenceNotReady, needAnAction, notReady, sameSentence, needCancelPause,
            missingList("Places"), duplicateName("message"), teachTitle("WhatsApp"), teachHelpFor("WhatsApp"),
            removeNamed("Dana"), unknownValue(2, "message"), actionNeeds(1, "Choose an app to open."),
        ]
        text += VoiceStep.keys.map(keyChoice)
        text += actionOrder.map(actionLabel)
        text += actionOrder.map { cardTitle($0.makeStep()) }
        text += actionOrder.map { summary($0.makeStep()) }
        text += [summary(VoiceStep(kind: .runAppleShortcut, shortcutName: "Remind", inputMode: VoiceStep.inputJSON)),
                 summary(VoiceStep(kind: .typeText, text: "{answer_1}")), cardTitle(VoiceStep(kind: .typeText, text: "{answer_1}"))]
        text += CodingAssistant.allCases.map(\.name)
        return text
    }
}

// MARK: - Coding assistants

/// The coding assistants the action offers. Each is a command underneath.
enum CodingAssistant: String, CaseIterable, Identifiable {
    case claude, codex, gemini, opencode

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .opencode: "OpenCode"
        }
    }

    var command: String { rawValue }

    /// The assistant for a command; a command of your own is shown as it is.
    static func named(forCommand command: String) -> (name: String, assistant: CodingAssistant?) {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if let match = allCases.first(where: { $0.command == trimmed.lowercased() }) { return (match.name, match) }
        return (trimmed.isEmpty ? Self.claude.name : trimmed, trimmed.isEmpty ? .claude : nil)
    }
}

// MARK: - New actions

extension VoiceStep.Kind {
    /// The words the sentence keeps for the person: the one that gets cleaned
    /// up, else the last of your words.
    static func mainWords(pattern: String, cleanUpSlot: String?) -> String? {
        guard case .success(let parsed) = VoicePattern.parse(pattern) else { return nil }
        let texts = parsed.slots.filter { $0.list == nil }
        return (texts.first { $0.name == cleanUpSlot } ?? texts.last)?.name
    }
}

extension Array where Element == VoiceStep {
    /// Adds an action at the end, with your main words filled in where they
    /// belong, and the cancel pause in front when the action sends something.
    @discardableResult
    mutating func addAction(_ kind: VoiceStep.Kind, pattern: String, cleanUpSlot: String? = nil) -> Bool {
        let inserted = addStep(kind, pattern: pattern, cleanUpSlot: cleanUpSlot)
        guard let words = VoiceStep.Kind.mainWords(pattern: pattern, cleanUpSlot: cleanUpSlot), !isEmpty else { return inserted }
        let reference = "{\(words)}"
        switch kind {
        case .typeText, .runAppleShortcut, .appendToFile, .openApp, .runWorkspace: self[count - 1].text = reference
        case .runInTerminal: self[count - 1].argument = reference
        default: break
        }
        if kind == .runInTerminal, case .success(let parsed) = VoicePattern.parse(pattern),
           let slot = parsed.slots.first(where: { $0.list != nil }) {
            self[count - 1].folder = "{\(slot.name).folder}"
        }
        return inserted
    }
}

// MARK: - Problems in plain words

enum VoiceBuildProblems {
    /// Literal phrases use the same parser, matcher and save checks as Voice launch.
    static func workspacePhrase(_ phrase: String, editing voiceCommand: VoiceCommand, in config: VoiceLaunchConfig) -> String? {
        if phrase.contains(where: { "{}[]".contains($0) }) { return "Use words without curly or square brackets." }
        if case .failure(let error) = VoicePattern.parse(phrase) { return SentenceBuilder.plain(error) }
        for other in config.commands where other.id != voiceCommand.id && voiceCommand.appScopeClashes(with: other) {
            // Off shortcuts still own their words. Check aliases and filled-in names too.
            var listening = other
            listening.enabled = true
            var isolated = config
            isolated.commands = [listening]
            if case .matched = VoiceLaunchEngine.match(phrase, in: isolated, frontmostAppBundleID: other.onlyInApps.first) {
                return other.enabled
                    ? "“\(other.name)” already listens for those words. Choose different words."
                    : "“\(other.name)” already uses those words, but it's turned off. Choose different words, or change it in Commands."
            }
        }
        return problem(for: config, editing: voiceCommand)
    }

    /// What is wrong with a shortcut, in plain words, or nil.
    static func problem(for voiceCommand: VoiceCommand, config: VoiceLaunchConfig,
                        allowedSchemes: [String] = VoiceCommandCatalog.shared.allowedLinkSchemes) -> String? {
        if let problem = voiceCommand.appScopeProblem { return problem }
        if !voiceCommand.pattern.trimmingCharacters(in: .whitespaces).isEmpty, let builder = SentenceBuilder(pattern: voiceCommand.pattern) {
            if let problem = builder.problem(config: config) { return problem }
        } else if case .failure(let error) = VoicePattern.parse(voiceCommand.pattern) {
            return SentenceBuilder.plain(error)
        }
        if case .success(let parsed) = VoicePattern.parse(voiceCommand.pattern), config.commands.contains(where: {
            guard $0.id != voiceCommand.id, voiceCommand.appScopeClashes(with: $0), case .success(let other) = VoicePattern.parse($0.pattern) else { return false }
            return parsed.matchingKey == other.matchingKey
        }) { return VoiceBuildCopy.sameSentence }
        guard !voiceCommand.steps.isEmpty else { return VoiceBuildCopy.needAnAction }
        let slots: [ParsedPattern.Slot]
        if case .success(let parsed) = VoicePattern.parse(voiceCommand.pattern) { slots = parsed.slots } else { slots = [] }
        var confirmed = false
        var earlier = Set<String>()
        let allAnswers = Set(voiceCommand.steps.filter { $0.kind == .runAppleShortcut }.map(\.answerKey))
        for (index, step) in voiceCommand.steps.enumerated() {
            let number = index + 1
            if step.isActing, !confirmed { return VoiceBuildCopy.needCancelPause }
            if let problem = actionProblem(step, number: number, slots: slots, config: config, allowedSchemes: allowedSchemes,
                                           earlierAnswers: earlier, laterAnswers: allAnswers.subtracting(earlier)) { return problem }
            if step.kind == .confirm { confirmed = true }
            if step.kind == .runAppleShortcut { earlier.insert(step.answerKey) }
        }
        if let engine = config.validate(voiceCommand, allowedSchemes: allowedSchemes) {
            return engine.contains("listens for the same words") ? VoiceBuildCopy.sameSentence : VoiceBuildCopy.notReady
        }
        return nil
    }

    /// Whether a whole setting can be saved; the reason is in plain words.
    static func problem(for config: VoiceLaunchConfig, editing voiceCommand: VoiceCommand,
                        allowedSchemes: [String] = VoiceCommandCatalog.shared.allowedLinkSchemes) -> String? {
        if config.commands.count >= VoiceLaunchConfig.maxCommands && !config.commands.contains(where: { $0.id == voiceCommand.id }) {
            return "You can have up to \(VoiceLaunchConfig.maxCommands) commands. Remove one first."
        }
        var candidate = config
        candidate.commands.removeAll { $0.id == voiceCommand.id }
        candidate.commands.append(voiceCommand)
        if let plain = problem(for: voiceCommand, config: candidate, allowedSchemes: allowedSchemes) { return plain }
        if let engine = candidate.validate(allowedSchemes: allowedSchemes) {
            return engine.contains("listens for the same words") ? VoiceBuildCopy.sameSentence : VoiceBuildCopy.notReady
        }
        return nil
    }

    private static func actionProblem(_ step: VoiceStep, number: Int, slots: [ParsedPattern.Slot],
                                      config: VoiceLaunchConfig, allowedSchemes: [String],
                                      earlierAnswers: Set<String> = [], laterAnswers: Set<String> = []) -> String? {
        for template in step.templates {
            for segment in VoiceTemplate.segments(template) {
                switch segment {
                case .text: break
                case .invalid: return VoiceBuildCopy.actionNeeds(number, "something in it isn’t a value from what you say.")
                case .reference(let slotName, let field):
                    guard let slot = slots.first(where: { $0.name == slotName }) else {
                        if slotName.hasPrefix(VoiceStep.answerPrefix) {
                            if earlierAnswers.contains(slotName) { continue }
                            if laterAnswers.contains(slotName) { return VoiceBuildCopy.answerTooEarly(number) }
                        }
                        return VoiceBuildCopy.unknownValue(number, InsertableValue.friendlyName(slot: slotName, field: field))
                    }
                    if let field, !(slot.list.flatMap { config.list(named: $0)?.fields.contains(field) } ?? false) {
                        return VoiceBuildCopy.unknownValue(number, InsertableValue.friendlyName(slot: slotName, field: field))
                    }
                }
            }
        }
        func blank(_ text: String?) -> Bool { (text ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        switch step.kind {
        case .openLink:
            let link = (step.link ?? "").trimmingCharacters(in: .whitespaces)
            if let colon = link.firstIndex(of: ":"), !link[..<colon].contains("{"), allowedSchemes.contains(link[..<colon].lowercased()) { return nil }
            return VoiceBuildCopy.actionNeeds(number, "the website address must start with https://.")
        case .openApp:
            return blank(step.bundleId) && blank(step.text) ? VoiceBuildCopy.actionNeeds(number, "choose an app or give its name.") : nil
        case .runWorkspace:
            return blank(step.workspaceId) && blank(step.text) ? VoiceBuildCopy.actionNeeds(number, "choose a workspace or give its name.") : nil
        case .runInTerminal:
            if step.background == true {
                if blank(step.command) { return VoiceBuildCopy.actionNeeds(number, "enter a command to run in the background.") }
                if let seconds = step.timeoutSeconds, !VoiceStep.backgroundTimeoutAllowed(seconds) {
                    return VoiceBuildCopy.actionNeeds(number, "choose a time limit between 1 and 600 seconds.")
                }
            }
            let folder = (step.folder ?? "").trimmingCharacters(in: .whitespaces)
            return folder.hasPrefix("/") || folder.hasPrefix("~") || folder.hasPrefix("{")
                ? nil : VoiceBuildCopy.actionNeeds(number, "choose a folder for the command.")
        case .runAppleShortcut:
            return blank(step.shortcutName) ? VoiceBuildCopy.actionNeeds(number, "type the name of the Apple Shortcut.") : nil
        case .webhook:
            let link = (step.link ?? "").lowercased()
            return link.hasPrefix("https://") || link.hasPrefix("http://")
                ? nil : VoiceBuildCopy.actionNeeds(number, "the address to send to must start with https://.")
        case .appendToFile:
            let path = (step.path ?? "").trimmingCharacters(in: .whitespaces)
            return path.hasPrefix("/") || path.hasPrefix("~") ? nil : VoiceBuildCopy.actionNeeds(number, "choose a file.")
        case .confirm:
            return blank(step.text) ? VoiceBuildCopy.actionNeeds(number, "say what to show while it waits.") : nil
        case .waitForTextField, .typeText, .pressKey:
            return nil
        }
    }
}
