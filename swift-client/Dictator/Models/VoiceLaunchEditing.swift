import Foundation

// The logic behind the Voice launch tab: list edits, the step menu, the
// pattern chips, the "Try it" answer, and how a step reads in plain words.
// Plain data in, plain data out, so the views stay thin and it can be tested.

// MARK: - Steps the editor offers

extension VoiceStep.Kind {
    /// What the "Add a step" menu offers, in this order: every step this
    /// build can run (`VoiceLaunchExecutor.supportedKinds`).
    static func addable(supported: Set<VoiceStep.Kind> = VoiceLaunchExecutor.supportedKinds) -> [VoiceStep.Kind] {
        allCases.filter { supported.contains($0) }
    }

    /// A new step of this kind with sensible starting values.
    func makeStep() -> VoiceStep {
        switch self {
        case .openLink: VoiceStep(kind: self, link: "https://")
        case .openApp, .runWorkspace: VoiceStep(kind: self, text: "")
        case .waitForTextField: VoiceStep(kind: self, seconds: VoiceStep.defaultWaitSeconds)
        case .typeText: VoiceStep(kind: self, text: "")
        case .pressKey: VoiceStep(kind: self, key: "return")
        case .runInTerminal: VoiceStep(kind: self, folder: "", command: VoiceLaunchConfig.defaultAgentCommand, argument: "")
        case .confirm: VoiceStep(kind: self, text: "", seconds: VoiceStep.defaultConfirmSeconds)
        case .runAppleShortcut: VoiceStep(kind: self, text: "", shortcutName: "", inputMode: VoiceStep.inputJSON)
        case .webhook: VoiceStep(kind: self, link: "https://")
        case .appendToFile: VoiceStep(kind: self, text: "", path: "")
        }
    }
}

extension VoiceStep {
    /// What the automatic pause shows: "Sending to {person}: {message}" when
    /// the pattern has a list slot, else "Sending: {message}".
    static func defaultConfirmSummary(pattern: String, cleanUpSlot: String? = nil) -> String {
        guard case .success(let parsed) = VoicePattern.parse(pattern) else { return "Press Esc to cancel this command." }
        let texts = parsed.slots.filter { $0.list == nil }
        let text = texts.first { $0.name == cleanUpSlot } ?? texts.last
        let person = parsed.slots.first { $0.list != nil }
        switch (person, text) {
        case (let person?, let text?): return "Sending to {\(person.name)}: {\(text.name)}"
        case (nil, let text?): return "Sending: {\(text.name)}"
        case (let person?, nil): return "Sending to {\(person.name)}"
        case (nil, nil): return "Press Esc to cancel this command."
        }
    }
}

extension VoiceCommandCatalog {
    /// Ready-made shortcuts this build can run, including those that need a list.
    func runnable(supported: Set<VoiceStep.Kind> = VoiceLaunchExecutor.supportedKinds) -> [Template] {
        available.filter { template in template.steps.allSatisfy { supported.contains($0.kind) } }
    }
}

extension Array where Element == VoiceStep {
    /// Adds a step of `kind` at the end. A step that sends or does something
    /// for real gets a "Wait for me to cancel" step in front of it when none
    /// comes earlier. Returns true when that step was added too.
    @discardableResult
    mutating func addStep(_ kind: VoiceStep.Kind, pattern: String, cleanUpSlot: String? = nil) -> Bool {
        let step = kind.makeStep()
        var insertedConfirm = false
        if step.isActing, !contains(where: { $0.kind == .confirm }) {
            var confirm = VoiceStep.Kind.confirm.makeStep()
            confirm.text = VoiceStep.defaultConfirmSummary(pattern: pattern, cleanUpSlot: cleanUpSlot)
            append(confirm)
            insertedConfirm = true
        }
        append(step)
        return insertedConfirm
    }

    /// Adds "Type the answer" for the last Apple Shortcut before the end.
    /// False when there is no Shortcut whose answer it could type.
    @discardableResult
    mutating func addTypeAnswer() -> Bool {
        guard let source = last(where: { $0.kind == .runAppleShortcut }) else { return false }
        append(VoiceStep(kind: .typeText, text: "{\(source.answerKey)}"))
        return true
    }

    /// The step right after this Shortcut that types its answer, if any.
    func typingAnswer(of id: String) -> VoiceStep? {
        guard let index = firstIndex(where: { $0.id == id }), index + 1 < count else { return nil }
        let next = self[index + 1]
        return next.kind == .typeText && next.text == "{\(self[index].answerKey)}" ? next : nil
    }

    /// Turns "Type its answer" on or off for a Shortcut.
    mutating func setTypingAnswer(of id: String, _ on: Bool) {
        guard let index = firstIndex(where: { $0.id == id }) else { return }
        if on {
            guard typingAnswer(of: id) == nil, count < VoiceLaunchConfig.maxStepsPerCommand else { return }
            insert(VoiceStep(kind: .typeText, text: "{\(self[index].answerKey)}"), at: index + 1)
        } else if let typing = typingAnswer(of: id) {
            removeAll { $0.id == typing.id }
        }
    }

    /// Moves a step one place up or down; ignores moves off the ends.
    mutating func move(_ id: String, by offset: Int) {
        guard let index = firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard indices.contains(target) else { return }
        swapAt(index, target)
    }
}

// MARK: - Lists

extension VoiceLaunchConfig {
    /// Adds an empty list and returns it. A name that is already taken gets a number.
    @discardableResult
    mutating func addList(named name: String, fields: [String] = []) -> VoiceList {
        let list = newListDraft(named: name, fields: fields)
        lists.append(list)
        return list
    }

    /// An empty list with a free name, not yet added: "New list" opens the
    /// editor on this, and only its Save adds it (`save(_:)`), so Cancel
    /// leaves nothing behind.
    func newListDraft(named name: String, fields: [String] = []) -> VoiceList {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "New list" }
        var candidate = base
        var n = 2
        while list(named: candidate) != nil { candidate = "\(base) \(n)"; n += 1 }
        return VoiceList(name: candidate, fields: fields)
    }

    /// Shortcuts whose pattern uses this list.
    func commands(using list: VoiceList) -> [VoiceCommand] {
        let wanted = VoiceLaunchText.normalizedWords(list.name)
        return commands.filter { voiceCommand in
            guard case .success(let parsed) = VoicePattern.parse(voiceCommand.pattern) else { return false }
            return parsed.slots.contains { $0.list.map(VoiceLaunchText.normalizedWords) == wanted }
        }
    }

    /// Saves an edited list. Renaming it updates the patterns that use it.
    /// Returns a plain reason when the result would not be valid.
    mutating func save(_ edited: VoiceList) -> String? {
        var candidate = self
        if let index = candidate.lists.firstIndex(where: { $0.id == edited.id }) {
            let old = candidate.lists[index]
            if VoiceLaunchText.normalizedWords(old.name) != VoiceLaunchText.normalizedWords(edited.name) {
                candidate.renameListInPatterns(from: old.name, to: edited.name)
            }
            candidate.lists[index] = edited
        } else {
            candidate.lists.append(edited)
        }
        if let reason = candidate.validate() { return reason }
        self = candidate
        return nil
    }

    /// Removes a list unless a shortcut still uses it; returns the reason if so.
    mutating func removeList(id: String) -> String? {
        guard let list = lists.first(where: { $0.id == id }) else { return nil }
        let users = commands(using: list)
        if !users.isEmpty {
            let names = users.map { "“\($0.name)”" }.joined(separator: ", ")
            return "“\(list.name)” is used by \(names). Change or remove that first."
        }
        lists.removeAll { $0.id == id }
        return nil
    }

    private mutating func renameListInPatterns(from old: String, to new: String) {
        let oldWords = VoiceLaunchText.normalizedWords(old)
        guard let regex = try? NSRegularExpression(pattern: "\\{([^{}:]*):([^{}]*)\\}") else { return }
        for index in commands.indices {
            var pattern = commands[index].pattern
            let ns = pattern as NSString
            for match in regex.matches(in: pattern, range: NSRange(location: 0, length: ns.length)).reversed() {
                let listName = ns.substring(with: match.range(at: 2))
                guard VoiceLaunchText.normalizedWords(listName) == oldWords else { continue }
                let slot = ns.substring(with: match.range(at: 1))
                pattern = (pattern as NSString).replacingCharacters(in: match.range, with: "{\(slot):\(new.trimmingCharacters(in: .whitespaces))}")
            }
            commands[index].pattern = pattern
        }
    }
}

extension VoiceListEntry {
    /// "Dana, Danny" as the names you say.
    static func names(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Plain words for a step

enum VoiceStepDescription {
    /// "Open mail.google.com" — one short line, for the progress notice.
    static func short(_ step: VoiceStep) -> String {
        switch step.kind {
        case .openLink:
            let url = URL(string: step.link ?? "")
            let isWeb = ["http", "https"].contains(url?.scheme?.lowercased() ?? "")
            return (isWeb ? url?.host : nil).map { "Open \($0)" } ?? "Open a link"
        case .openApp: return "Open \(appName(step.bundleId) ?? step.text ?? "the app")"
        case .runWorkspace: return "Run routine “\(step.text ?? "")”"
        case .waitForTextField: return "Wait for a place to type"
        case .typeText: return "Type your words"
        case .pressKey: return "Press \(keyName(step.key))"
        case .runInTerminal:
            let folder = (step.folder ?? "") as NSString
            let assistant = CodingAssistant.named(forCommand: step.command ?? VoiceLaunchConfig.defaultAgentCommand).name
            return "Start \(assistant) in \(folder.lastPathComponent.isEmpty ? "a folder" : folder.lastPathComponent)"
        case .confirm: return "Wait for me to cancel"
        case .runAppleShortcut: return VoiceStep.isTemplate(step.shortcutName) ? "Run the Shortcut you name" : "Run “\(step.shortcutName ?? "")”"
        case .webhook: return "Send to \(URL(string: step.link ?? "")?.host ?? "a web address")"
        case .appendToFile: return "Add a line to \(((step.path ?? "") as NSString).lastPathComponent)"
        }
    }

    /// What the step will use, with the words already filled in, for "Try it".
    static func detail(_ original: VoiceStep) -> String {
        // A step that waits for an earlier answer shows what it will use.
        let step = VoiceStepRenderer.resolve(original, answers: [:], mac: "", placeholderAnswers: true)
        return switch step.kind {
        case .openLink, .webhook: step.link ?? ""
        case .openApp: appName(step.bundleId) ?? step.bundleId ?? step.text ?? ""
        case .runWorkspace: step.text ?? ""
        case .waitForTextField: "up to \(Int(step.seconds ?? VoiceStep.defaultWaitSeconds)) seconds"
        case .runAppleShortcut where step.sendsEverything: "everything you said"
        case .typeText, .confirm, .runAppleShortcut, .appendToFile: step.text ?? ""
        case .pressKey: keyName(step.key)
        case .runInTerminal: "in \(step.folder ?? ""): \(step.command ?? "") \(step.argument ?? "")"
        }
    }

    static func keyName(_ key: String?) -> String {
        switch key {
        case "return": "Return"
        case "cmdReturn": "⌘Return"
        case "tab": "Tab"
        case "escape": "Escape"
        default: "a key"
        }
    }

    private static func appName(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return VoiceAppNames.name(for: id)
    }
}

// MARK: - Try it

/// The answer the "Try it" box shows. Nothing is run to get it.
enum VoiceTryItResult: Equatable {
    struct Row: Equatable {
        var title: String
        var detail: String
    }
    case matched(voiceCommand: String, slots: [VoicePlanSlot], steps: [Row])
    case noMatch(String)
    /// Nothing would run, but one click could fix it.
    case nearMiss(VoiceNearMiss)

    static func result(for sentence: String, in config: VoiceLaunchConfig) -> VoiceTryItResult {
        switch VoiceLaunchEngine.plan(for: sentence, in: config) {
        case .plan(let plan):
            .matched(voiceCommand: plan.commandName, slots: plan.slots,
                     steps: plan.steps.map { Row(title: VoiceStepDescription.short($0), detail: VoiceStepDescription.detail($0)) })
        case .noMatch(let reason):
            .noMatch(explain(reason))
        case .nearMiss(let miss):
            .nearMiss(miss)
        }
    }

    /// What the matched shortcut would do, in plain words: "Opens wa.me, then types “running late”".
    static func actionSentence(for sentence: String, in config: VoiceLaunchConfig, routines: [WorkspaceRoutine] = []) -> String? {
        guard case .plan(let plan) = VoiceLaunchEngine.plan(for: sentence, in: config) else { return nil }
        let phrases = plan.steps.map { step -> String in
            step.kind == .confirm
                ? "waits \(Int(step.seconds ?? VoiceStep.defaultConfirmSeconds)) seconds so you can cancel"
                : VoiceBuildCopy.summary(step, routines: routines)
        }
        guard !phrases.isEmpty else { return nil }
        return phrases.enumerated().map { index, phrase in
            index == 0 ? phrase : phrase.prefix(1).lowercased() + phrase.dropFirst()
        }.joined(separator: ", then ")
    }

    static func explain(_ reason: NoMatchReason) -> String {
        switch reason {
        case .nothingSaid: "Type a sentence to see what would happen."
        case .noCommands: "No commands are turned on yet. In Commands mode, your words would stay on the clipboard."
        case .noneMatched: BrandVoice.noVoiceCommandFits
        case .tie(let names):
            "More than one command fits equally well (\(names.joined(separator: ", "))), so none would run. Your words would stay on the clipboard. Change how one of them is said so they differ."
        }
    }
}


extension VoiceLaunchConfig {
    /// A matching phrase belongs to a template only when its origin or actions agree.
    func owns(_ voiceCommand: VoiceCommand, template: VoiceCommandCatalog.Template, family: [String], catalog: VoiceCommandCatalog = .shared) -> Bool {
        if voiceCommand.templateId.map(family.contains) == true { return true }
        func actions(_ steps: [VoiceStep]) -> [VoiceStep] {
            steps.map { var step = $0; step.id = ""; return step }
        }
        return ([template] + catalog.templates.filter { family.contains($0.id) }).contains { actions(voiceCommand.steps) == actions($0.steps) }
    }

    func patternConflict(_ pattern: String, template: VoiceCommandCatalog.Template, family: [String], catalog: VoiceCommandCatalog = .shared) -> String? {
        guard let existing = voiceCommand(matchingPattern: pattern), !owns(existing, template: template, family: family, catalog: catalog) else { return nil }
        return "You already have a command that listens for these words: \(existing.name). Turn it on or change it."
    }

    func voiceCommand(matchingPattern pattern: String) -> VoiceCommand? {
        guard case .success(let parsed) = VoicePattern.parse(pattern) else { return nil }
        return commands.first {
            guard case .success(let other) = VoicePattern.parse($0.pattern) else { return false }
            return parsed.matchingKey == other.matchingKey
        }
    }
}

// MARK: - A routine's own voice command

/// No settings or I/O here. Callers save every change through updateVoiceLaunch.
enum VoiceWorkspaceLink {
    static func commands(for workspaceId: String, in config: VoiceLaunchConfig) -> [VoiceCommand] {
        config.commands.filter { voiceCommand in
            voiceCommand.steps.contains { $0.kind == .runWorkspace && $0.workspaceId == workspaceId }
        }
    }

    static func find(_ workspaceId: String, in config: VoiceLaunchConfig) -> VoiceCommand? {
        commands(for: workspaceId, in: config).first
    }

    static func draft(workspaceId: String, name: String, phrase: String, id: String = UUID().uuidString) -> VoiceCommand {
        VoiceCommand(id: id, name: name, pattern: phrase.trimmingCharacters(in: .whitespacesAndNewlines),
                            steps: [VoiceStep(kind: .runWorkspace, workspaceId: workspaceId)])
    }

    @discardableResult
    static func add(workspaceId: String, name: String, phrase: String, id: String = UUID().uuidString,
                    to config: inout VoiceLaunchConfig) -> String? {
        let voiceCommand = draft(workspaceId: workspaceId, name: name, phrase: phrase, id: id)
        if let problem = VoiceBuildProblems.workspacePhrase(voiceCommand.pattern, editing: voiceCommand, in: config) { return problem }
        config.commands.append(voiceCommand)
        return nil
    }

    @discardableResult
    static func changePhrase(_ phrase: String, commandId: String, in config: inout VoiceLaunchConfig) -> String? {
        guard let index = config.commands.firstIndex(where: { $0.id == commandId }) else { return "This voice command was removed. Add it again." }
        var voiceCommand = config.commands[index]
        voiceCommand.pattern = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = VoiceBuildProblems.workspacePhrase(phrase, editing: voiceCommand, in: config) { return problem }
        config.commands[index] = voiceCommand
        return nil
    }

    /// Remove just this routine's actions, retaining any work added in Voice launch.
    static func remove(_ workspaceId: String, commandId: String? = nil, from config: inout VoiceLaunchConfig) {
        config.commands = config.commands.compactMap { original in
            guard commandId == nil || original.id == commandId,
                  original.steps.contains(where: { $0.kind == .runWorkspace && $0.workspaceId == workspaceId }) else { return original }
            var voiceCommand = original
            voiceCommand.steps.removeAll { $0.kind == .runWorkspace && $0.workspaceId == workspaceId }
            return voiceCommand.steps.isEmpty ? nil : voiceCommand
        }
    }

    static func rename(_ workspaceId: String, from oldName: String, to newName: String, in config: inout VoiceLaunchConfig) {
        let linked = Set(commands(for: workspaceId, in: config).map(\.id))
        for index in config.commands.indices where linked.contains(config.commands[index].id) && config.commands[index].name == oldName {
            config.commands[index].name = newName
        }
    }
}
