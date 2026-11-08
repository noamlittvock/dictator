import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Editor decisions and action descriptions, independent of live windows and app inventory.
enum WorkspaceGroupEditorLogic {
    static func showsControls(for routine: WorkspaceRoutine) -> Bool { !routine.actions.isEmpty }
    static func isEnabled(_ routine: WorkspaceRoutine) -> Bool { routine.showOnly == true }

    static func setEnabled(_ enabled: Bool, in routine: inout WorkspaceRoutine) {
        routine.showOnly = enabled
        // Keep the person's exceptions when they turn the option off temporarily.
    }

    static func parkedNotice(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 window is out of the way" : "\(count) windows are out of the way"
    }

    static let runExplanation = "Preview shows the planned changes without changing anything. Run carries out the steps and hides other apps if you choose Show only this routine's windows. Undo restores window positions and hidden apps until Dictator quits; it doesn't close tabs."

    static func runHelp(_ routine: WorkspaceRoutine, otherMacs: [String]) -> String {
        let scope = otherMacs.isEmpty ? "" : " on this Mac and \(WorkspaceWords.list(otherMacs))"
        if isEnabled(routine) {
            return "Hides other apps and brings this routine's windows forward\(scope). Undo brings hidden apps back and restores window positions; it doesn't close tabs."
        }
        if routine.onlyOpensTabs {
            return "Brings back these browser windows if still open, or opens them again\(scope). Undo doesn't close tabs."
        }
        return "Runs the steps now\(scope). Undo restores window positions and hidden apps; it doesn't close tabs."
    }

    static func previewHelp(_ routine: WorkspaceRoutine) -> String {
        if isEnabled(routine) { return "Shows the planned windows and which other apps will hide. Nothing changes yet." }
        return routine.onlyOpensTabs ? "Shows which browser windows will open or come back. Nothing opens yet."
            : "Shows where each window will go. Nothing changes yet."
    }
}

/// A user-controlled way to put chosen app windows back where they belong.
/// Until the first routine works, the page leads with three numbered steps;
/// ready-made routines open the editor already filled in.
struct WorkspaceLaunchView: View {
    @State private var controller: WorkspaceLaunchController
    @State private var settings: AppSettings
    @State private var draft: WorkspaceRoutine?
    @State private var draftIsNew = false
    @State private var confirmingReset = false
    @State private var confirmingDelete: WorkspaceRoutine?

    init(controller: WorkspaceLaunchController = .shared, settings: AppSettings = .shared) {
        _controller = State(initialValue: controller)
        _settings = State(initialValue: settings)
    }

    private var routines: [WorkspaceRoutine] { settings.workspaceLaunch.routines }
    private var needsSetup: Bool { !controller.isAccessibilityGranted || routines.isEmpty }

    var body: some View {
        DSPage(
            title: "Workspaces",
            summary: BrandVoice.windowsSummary,
            brief: HelpLibrary.brief(.workspaces)
        ) {
            if let notice = WorkspaceGroupEditorLogic.parkedNotice(controller.parkedWindowCount) {
                SettingsNotice(tone: .neutral, text: Text(notice)) {
                    Button(WorkspaceTabWords.bringBack(controller.parkedWindowCount)) {
                        Task { await controller.returnParkedWindows() }
                    }
                    .disabled(controller.isBusy)
                    .help("Brings back the browser windows Dictator moved out of the way on this Mac.")
                }
            }
            if needsSetup { gettingStarted }
            if let warning = controller.savedSettingsWarning {
                SettingsSectionCard(title: "Saved routines") {
                    VStack(alignment: .leading, spacing: DSSpace.xs) {
                        Text(warning).font(.dsBody)
                        if controller.canClearUnreadableSettings {
                            Button("Clear saved routines…") { confirmingReset = true }
                                .buttonStyle(.dsDestructive)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(DSSpace.m)
                }
            }
            if !routines.isEmpty { routinesSection }
            if !controller.hotkeyWarnings.isEmpty { shortcutWarnings }
            if controller.previewPicture != nil || !controller.previewLines.isEmpty { previewSection }
            if !controller.status.isEmpty || controller.canRestore { statusNotice }
            rememberCard
            startersSection
        }
        .frame(minWidth: 650, minHeight: 480)
        .task { controller.refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshPermission()
        }
        .sheet(item: $draft) { routine in
            WorkspaceRoutineEditor(routine: routine, isNew: draftIsNew, controller: controller) { saved in
                controller.saveRoutine(saved)
            }
        }
        .confirmationDialog("Delete all saved routines?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Delete all routines", role: .destructive) { controller.resetSavedRoutines() }
        } message: {
            Text("This deletes your saved routines and their voice commands on all your connected Macs. Undo for the last run still works.")
        }
        .confirmationDialog(
            "Delete \(confirmingDelete?.name ?? "this routine")?",
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete routine", role: .destructive) {
                if let routine = confirmingDelete { controller.deleteRoutine(id: routine.id) }
                confirmingDelete = nil
            }
        } message: {
            if let routine = confirmingDelete {
                let phrases = VoiceWorkspaceLink.commands(for: routine.id, in: settings.voiceLaunch)
                    .map { "“\(SentenceBuilder.exampleSentence(pattern: $0.pattern, config: settings.voiceLaunch))”" }
                Text(phrases.isEmpty ? "This deletes the routine on all your connected Macs."
                     : "This also removes this routine from its voice commands: \(phrases.joined(separator: ", ")). Other actions in those commands stay.")
            }
        }
    }

    // MARK: Getting started

    private var gettingStarted: some View {
        SettingsSectionCard(title: "Get started") {
            WorkspaceStepRow(number: 1, done: controller.isAccessibilityGranted, title: "Let Dictator move windows",
                             detail: controller.isAccessibilityGranted
                                 ? "Done. Dictator moves windows only when you run a routine."
                                 : "macOS asks once. In Privacy & Security › Accessibility, turn on Dictator, then come back here.") {
                if !controller.isAccessibilityGranted {
                    Button("Open System Settings") { controller.requestPermission() }
                }
            }
            SettingsDivider()
            WorkspaceStepRow(number: 2, done: !routines.isEmpty, title: "Make a routine",
                             detail: routines.isEmpty
                                 ? "Arrange your windows and press Remember below, or pick a starting point and choose its apps."
                                 : "Done. Add more below whenever you like.") { EmptyView() }
            SettingsDivider()
            WorkspaceStepRow(number: 3, done: false, title: "Try it",
                             detail: WorkspaceGroupEditorLogic.runExplanation + " Give a routine a keyboard shortcut to run it from any app.") { EmptyView() }
        }
    }

    // MARK: Routines

    private var routinesSection: some View {
        SettingsSectionCard(
            title: "Your routines",
            footer: WorkspaceGroupEditorLogic.runExplanation
        ) {
            ForEach(Array(routines.enumerated()), id: \.element.id) { index, routine in
                if index > 0 { SettingsDivider() }
                routineRow(routine)
            }
        }
    }

    private func routineRow(_ routine: WorkspaceRoutine) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            HStack(spacing: DSSpace.xs) {
                Text(routine.name.isEmpty ? "Untitled routine" : routine.name)
                    .font(.dsBodyMedium).foregroundStyle(Color.dsTextPrimary)
                shortcutChip(routine.hotkey)
                Spacer()
                Toggle(routine.enabled ? "On" : "Off", isOn: routineEnabledBinding(routine.id))
                    .labelsHidden()
                    .toggleStyle(.switch).controlSize(.small)
                    .help("When a routine is off, its shortcut does nothing and it can't be previewed or run.")
            }
            Text(WorkspaceWords.summary(routine, macID: WorkspaceMacIdentity.current, appName: WorkspaceAppNames.name))
                .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(routine.enabled ? 1 : 0.6)
            if !routine.enabled {
                Text("Off. Turn it on to use Preview, Run and its shortcut.")
                    .font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
            } else if routine.hotkey != nil, let problem = controller.hotkeyFailures[routine.id] {
                Label("\(problem). Edit the routine to choose another.", systemImage: "exclamationmark.triangle.fill")
                    .font(.dsCaption).foregroundStyle(Color.dsWarning)
            }
            if routine.enabled, let minutes = routine.actions.filter({ $0.kind == .hideIdleApps }).map(\.idleMinutes).min() {
                TimelineView(.everyMinute) { context in
                    Text(WorkspaceIdleWords.status(trackingSince: controller.trackingStartedAt, idleMinutes: minutes, now: context.date))
                        .font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            let others = controller.otherMacs(in: routine)
            if routine.enabled, !others.isEmpty {
                Text("Run carries out the steps on this Mac and \(WorkspaceWords.list(others)).")
                    .font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
            }
            WorkspaceVoiceCommandRow(routine: routine, settings: settings)
            HStack(spacing: DSSpace.xs) {
                Button("Preview") { controller.preview(routineID: routine.id) }
                    .disabled(controller.isBusy || !routine.enabled || !controller.canRun(routine))
                    .help(WorkspaceGroupEditorLogic.previewHelp(routine))
                Button("Run") { controller.run(routineID: routine.id) }
                    .buttonStyle(.dsPrimary)
                    .disabled(controller.isBusy || !routine.enabled || !controller.canRun(routine))
                    .help(WorkspaceGroupEditorLogic.runHelp(routine, otherMacs: others))
                if !controller.canRun(routine) {
                    Text("Finish step 1 first.").font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
                }
                Spacer()
                Button("Edit") { draftIsNew = false; draft = routine }
                Button { confirmingDelete = routine } label: { Image(systemName: "trash").font(.dsIcon) }
                    .buttonStyle(.dsQuiet)
                    .accessibilityLabel("Delete \(routine.name)")
            }
        }
        .padding(.horizontal, DSSpace.m)
        .padding(.vertical, DSSpace.s)
    }

    @ViewBuilder private func shortcutChip(_ hotkey: WorkspaceHotkey?) -> some View {
        if let hotkey {
            Text(WorkspaceHotkeyFormat.display(hotkey))
                .font(.dsCaptionMedium).foregroundStyle(Color.dsTextSecondary)
                .padding(.horizontal, DSSpace.xs).padding(.vertical, DSSpace.hair)
                .background(Color.dsSurfaceSunken, in: Capsule())
                .help("Press these keys in any app to run this routine.")
        } else {
            Text("No shortcut").font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
                .help("Add a keyboard shortcut in Edit to run this routine from any app.")
        }
    }

    private var shortcutWarnings: some View {
        SettingsSectionCard(title: "Keyboard shortcuts") {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                ForEach(Array(controller.hotkeyWarnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(DSSpace.m)
        }
    }

    // MARK: Preview and result

    private var previewRoutine: WorkspaceRoutine? {
        controller.previewRoutineID.flatMap { id in routines.first { $0.id == id } }
    }

    private var previewSection: some View {
        SettingsSectionCard(title: previewRoutine.map { "Preview: \($0.name)" } ?? "What the last run did") {
            VStack(alignment: .leading, spacing: DSSpace.s) {
                if let picture = controller.previewPicture, !picture.screens.isEmpty {
                    WorkspacePreviewDiagram(picture: picture).frame(height: 190)
                }
                VStack(alignment: .leading, spacing: DSSpace.xxs) {
                    ForEach(Array(controller.previewLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: DSSpace.xs) {
                    if let routine = previewRoutine {
                        Button("Run it now") { controller.run(routineID: routine.id) }
                            .buttonStyle(.dsPrimary)
                            .disabled(controller.isBusy || !controller.canRun(routine))
                            .help(WorkspaceGroupEditorLogic.runHelp(routine, otherMacs: controller.otherMacs(in: routine)))
                    }
                    Button("Close") { controller.clearPreview() }.buttonStyle(.dsQuiet)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(DSSpace.m)
        }
    }

    private var statusNotice: some View {
        let scope = controller.undoSummary
        let lines = [controller.status, scope ?? ""].filter { !$0.isEmpty }
        return SettingsNotice(tone: controller.lastRunStoppedPartway ? .warning : .neutral,
                              text: Text(lines.isEmpty ? "You can undo the last run." : lines.joined(separator: "\n"))) {
            if controller.canRestore {
                if controller.lastRunStoppedPartway {
                    Button("Undo") { controller.restoreLastReset() }
                        .buttonStyle(.dsPrimary)
                        .disabled(controller.isBusy)
                        .help((scope ?? "Puts the windows from the last run back where they were.") + " Works until Dictator quits.")
                } else {
                    Button("Undo") { controller.restoreLastReset() }
                        .disabled(controller.isBusy)
                        .help((scope ?? "Puts the windows from the last run back where they were.") + " Works until Dictator quits.")
                }
            }
        }
    }

    // MARK: Remember the windows as they are

    private var rememberCard: some View {
        let others = controller.otherConnectedMacs
        return VStack(alignment: .leading, spacing: DSSpace.xs) {
            HStack(alignment: .top, spacing: DSSpace.s) {
                Image(systemName: "macwindow.on.rectangle").font(.dsIconLarge).foregroundStyle(Color.dsAccent).frame(width: 28)
                VStack(alignment: .leading, spacing: DSSpace.hair) {
                    Text(BrandVoice.rememberLayout).font(.dsSection).foregroundStyle(Color.dsTextPrimary)
                    Text(others.isEmpty
                         ? "Arrange your windows, then press Remember. Running the routine brings back minimized windows and puts these in place, with the same ones in front. Windows on another desktop stay there."
                         : "Arrange windows on this Mac and \(WorkspaceWords.list(others)), then press Remember. Running the routine brings back minimized windows and puts these in place, with the same ones in front. Windows on another desktop stay there.")
                        .font(.dsSecondary).foregroundStyle(Color.dsTextTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: DSSpace.xs) {
                if controller.isRemembering {
                    ProgressView().controlSize(.small)
                    Text("Looking at your windows…").font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                } else if others.isEmpty {
                    Button("Remember this layout") { remember(everywhere: false) }.buttonStyle(.dsPrimary)
                } else {
                    Button("Remember on all my Macs") { remember(everywhere: true) }.buttonStyle(.dsPrimary)
                    Button("This Mac only") { remember(everywhere: false) }
                }
                if !controller.isAccessibilityGranted {
                    Text("Finish step 1 first.").font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
                }
            }
            .disabled(!controller.isAccessibilityGranted || controller.isBusy)
            .padding(.leading, DSSpace.xxl)
        }
        .padding(DSSpace.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCardSurface(border: Color.dsAccent.opacity(0.35))
    }

    private func remember(everywhere: Bool) {
        Task { @MainActor in
            guard let layouts = await controller.rememberLayouts(everywhere: everywhere) else { return }
            draftIsNew = true
            draft = .remembering(layouts, existing: routines)
        }
    }

    // MARK: Starting points

    private var startersSection: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text(routines.isEmpty ? "Or pick a starting point" : "Or start from an idea")
                .font(.dsSection).foregroundStyle(Color.dsTextPrimary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: DSSpace.xs), GridItem(.flexible(), spacing: DSSpace.xs)], spacing: DSSpace.xs) {
                ForEach(WorkspaceStarter.allCases) { starter in
                    WorkspaceStarterCard(starter: starter) { draftIsNew = true; draft = starter.routine() }
                }
            }
            HStack(spacing: DSSpace.xxs) {
                Text("Want something else?").font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
                Button("Start from scratch") { draftIsNew = true; draft = WorkspaceRoutine(name: "", actions: []) }
                    .buttonStyle(.dsLink)
            }
        }
    }

    private func routineEnabledBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settings.workspaceLaunch.routines.first { $0.id == id }?.enabled ?? false },
            set: { enabled in
                guard var routine = settings.workspaceLaunch.routines.first(where: { $0.id == id }) else { return }
                routine.enabled = enabled
                _ = controller.saveRoutine(routine)
            }
        )
    }
}

/// Shared settings only: available even when this Mac cannot run the routine.
private struct WorkspaceVoiceCommandRow: View {
    let routine: WorkspaceRoutine
    let settings: AppSettings
    @State private var editing = false

    private var linked: [VoiceCommand] { VoiceWorkspaceLink.commands(for: routine.id, in: settings.voiceLaunch) }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xxs) {
            Text("Voice command").font(.dsSection)
            if let voiceCommand = linked.first {
                HStack(spacing: DSSpace.xs) {
                    Text("“\(SentenceBuilder.exampleSentence(pattern: voiceCommand.pattern, config: settings.voiceLaunch))”")
                        .foregroundStyle(voiceCommand.enabled ? Color.dsTextSecondary : Color.dsTextTertiary)
                    if !voiceCommand.enabled {
                        Text("Off").foregroundStyle(Color.dsTextTertiary)
                        Button("Turn on") {
                            settings.updateVoiceLaunch { config in
                                if let index = config.commands.firstIndex(where: { $0.id == voiceCommand.id }) { config.commands[index].enabled = true }
                            }
                        }
                    }
                    Spacer()
                    Button("Edit") { editing = true }.buttonStyle(.dsQuiet)
                    Button("Remove") { settings.updateVoiceLaunch { VoiceWorkspaceLink.remove(routine.id, commandId: voiceCommand.id, from: &$0) } }
                        .buttonStyle(.dsDestructive)
                }
                Button("Not being heard? Teach it") {
                    AppNavigation.shared.openVoiceCommand(voiceCommand.id)
                }
                .buttonStyle(.dsLink)
                .font(.dsCaption)
                .foregroundStyle(Color.dsTextTertiary)
                if linked.count > 1 {
                    Text("and \(linked.count - 1) more in Commands").foregroundStyle(Color.dsTextTertiary)
                }
            } else {
                Button("Add a voice command") { editing = true }
            }
        }
        .font(.dsSecondary)
        .sheet(isPresented: $editing) {
            WorkspaceVoiceCommandSheet(routine: routine, voiceCommand: linked.first, settings: settings)
        }
    }
}

private struct WorkspaceVoiceCommandSheet: View {
    let routine: WorkspaceRoutine
    let commandId: String
    let isNew: Bool
    let settings: AppSettings
    @State private var phrase: String
    @State private var saveProblem: String?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(routine: WorkspaceRoutine, voiceCommand: VoiceCommand?, settings: AppSettings) {
        self.routine = routine
        self.settings = settings
        self.commandId = voiceCommand?.id ?? UUID().uuidString
        self.isNew = voiceCommand == nil
        _phrase = State(initialValue: voiceCommand.map { SentenceBuilder.exampleSentence(pattern: $0.pattern, config: settings.voiceLaunch) } ?? routine.name)
    }

    private var problem: String? {
        guard let current = settings.workspaceLaunch.routines.first(where: { $0.id == routine.id }) else { return "This routine was removed." }
        let config = settings.voiceLaunch
        var voiceCommand: VoiceCommand
        if isNew {
            voiceCommand = VoiceWorkspaceLink.draft(workspaceId: routine.id, name: current.name, phrase: phrase, id: commandId)
        } else {
            guard let saved = config.commands.first(where: { $0.id == commandId }) else { return "This voice command was removed. Add it again." }
            voiceCommand = saved
            voiceCommand.pattern = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return VoiceBuildProblems.workspacePhrase(phrase, editing: voiceCommand, in: config)
    }

    var body: some View {
        DSSheet(title: "Voice command", width: .standard) {
            VStack(alignment: .leading, spacing: DSSpace.s) {
                TextField("What you say", text: $phrase).textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { save() }
                Text(VoiceBuildCopy.howToSay(keys: settings.hotkeyTriggers.commands, phrase: phrase))
                    .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                if let reason = problem ?? saveProblem {
                    Text(reason).font(.dsSecondary).foregroundStyle(Color.dsWarning)
                }
            }
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(problem != nil)
                .buttonStyle(.dsPrimary)
        }
        .task {
            focused = true
            await Task.yield()
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
        }
        .onChange(of: phrase) { _, _ in saveProblem = nil }
    }

    private func save() {
        guard problem == nil, let current = settings.workspaceLaunch.routines.first(where: { $0.id == routine.id }) else { return }
        settings.updateVoiceLaunch { config in
            if isNew {
                saveProblem = VoiceWorkspaceLink.add(workspaceId: routine.id, name: current.name, phrase: phrase, id: commandId, to: &config)
            } else {
                saveProblem = VoiceWorkspaceLink.changePhrase(phrase, commandId: commandId, in: &config)
            }
        }
        if saveProblem == nil { dismiss() }
    }
}

/// App names for bundle ids: the running app's name, else the installed app's, else the id's last part.
enum WorkspaceAppNames {
    static func name(for bundleID: String) -> String {
        if let name = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })?.localizedName { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
    struct App: Identifiable, Equatable { var id: String; var name: String; var open: Bool }

    @MainActor
    static func runningApps() -> [App] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier else { return nil }
            return App(id: id, name: app.localizedName ?? id, open: true)
        }
    }

    static func merging(_ current: [App], installed: [VoiceInstalledApp]) -> [App] {
        var found = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for app in installed {
            guard let id = app.bundleID, id != Bundle.main.bundleIdentifier, found[id] == nil else { continue }
            found[id] = App(id: id, name: app.name, open: false)
        }
        return found.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

}

/// A numbered setup step that turns into a check mark when done.
private struct WorkspaceStepRow<Control: View>: View {
    let number: Int
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .top, spacing: DSSpace.s) {
            DSStepBadge(number: number, done: done)
            VStack(alignment: .leading, spacing: DSSpace.hair) {
                Text(title).font(.dsBodyMedium).foregroundStyle(Color.dsTextPrimary)
                Text(detail).font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, DSSpace.m).padding(.vertical, DSSpace.s)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title). \(done ? "Done." : detail)")
    }
}

private struct WorkspaceStarterCard: View {
    let starter: WorkspaceStarter
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: DSSpace.s) {
                WorkspaceScreenSketch(tiles: Self.sketch(starter), faded: starter == .hideIdle ? [1] : [])
                    .frame(width: 64)
                VStack(alignment: .leading, spacing: DSSpace.hair) {
                    Text(starter.title).font(.dsBodyMedium).foregroundStyle(Color.dsTextPrimary)
                    Text(starter.detail).font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(DSSpace.m)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .dsCardSurface(hovering ? Color.dsSurfaceRaised : Color.dsSurfaceCard,
                           border: hovering ? Color.dsBorderStrong : Color.dsBorderSubtle)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(starter.title). \(starter.detail)")
    }

    static func sketch(_ starter: WorkspaceStarter) -> [WorkspaceRect] {
        let unit = WorkspaceRect(x: 0, y: 0, width: 1, height: 1)
        switch starter {
        case .sideBySide: return WorkspacePlanner.tileFrames(in: unit, count: 2, layout: .halves)
        case .grid: return WorkspacePlanner.tileFrames(in: unit, count: 4, layout: .quarters)
        case .centerWindow: return [WorkspaceRect(x: 0.22, y: 0.18, width: 0.56, height: 0.64)]
        case .hideIdle: return WorkspacePlanner.tileFrames(in: unit, count: 2, layout: .halves)
        }
    }
}

/// A small drawing of one screen with window tiles, given in 0…1 coordinates from the top left.
struct WorkspaceScreenSketch: View {
    var tiles: [WorkspaceRect]
    var faded: Set<Int> = []

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous).fill(Color.dsSurfaceSunken)
                RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous).strokeBorder(Color.dsBorderStrong, lineWidth: 1)
                ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                    let isFaded = faded.contains(index)
                    RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
                        .fill(isFaded ? Color.clear : Color.dsAccentQStrong)
                        .overlay(RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
                            .strokeBorder(isFaded ? Color.dsBorderStrong : Color.dsAccent, style: StrokeStyle(lineWidth: 1, dash: isFaded ? [2, 2] : [])))
                        .frame(width: max(0, tile.width * geo.size.width - 4), height: max(0, tile.height * geo.size.height - 4))
                        .offset(x: tile.x * geo.size.width + 2, y: tile.y * geo.size.height + 2)
                }
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The preview drawn to scale: every screen of this Mac, and each window where it will land.
struct WorkspacePreviewDiagram: View {
    let picture: WorkspacePreviewPicture

    var body: some View {
        GeometryReader { geo in
            let screens = picture.screens.map(\.visibleFrame)
            let minX = screens.map(\.x).min() ?? 0, minY = screens.map(\.y).min() ?? 0
            let maxX = screens.map { $0.x + $0.width }.max() ?? 1, maxY = screens.map { $0.y + $0.height }.max() ?? 1
            let scale = min(geo.size.width / max(1, maxX - minX), geo.size.height / max(1, maxY - minY))
            let originX = (geo.size.width - (maxX - minX) * scale) / 2, originY = (geo.size.height - (maxY - minY) * scale) / 2
            let place = { (r: WorkspaceRect) in
                CGRect(x: originX + (r.x - minX) * scale, y: originY + (r.y - minY) * scale, width: r.width * scale, height: r.height * scale)
            }
            ZStack(alignment: .topLeading) {
                ForEach(Array(picture.screens.enumerated()), id: \.offset) { _, screen in
                    let rect = place(screen.visibleFrame)
                    ZStack(alignment: .bottomLeading) {
                        RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous).fill(Color.dsSurfaceSunken)
                        RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous).strokeBorder(Color.dsBorderStrong, lineWidth: 1)
                        if picture.screens.count > 1 {
                            Text(WorkspaceWords.screenName(screen, among: picture.screens)?.capitalizedFirst ?? "")
                                .font(.dsCaption).foregroundStyle(Color.dsTextTertiary).padding(DSSpace.xxs)
                        }
                    }
                    .frame(width: max(0, rect.width - 2), height: max(0, rect.height - 2))
                    .offset(x: rect.minX + 1, y: rect.minY + 1)
                }
                ForEach(Array(picture.tiles.enumerated()), id: \.offset) { _, tile in
                    let rect = place(tile.frame)
                    RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
                        .fill(Color.dsAccentQStrong)
                        .overlay(RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous).strokeBorder(Color.dsAccent, lineWidth: 1))
                        .overlay(Text(tile.appName).font(.dsCaptionMedium).foregroundStyle(Color.dsTextPrimary)
                            .lineLimit(1).padding(DSSpace.xxs))
                        .frame(width: max(0, rect.width - 4), height: max(0, rect.height - 4))
                        .offset(x: rect.minX + 2, y: rect.minY + 2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(picture.lines.joined(separator: ". "))
    }
}

/// Make or change a routine: a name, its steps in order, and an optional
/// shortcut. Save stays off until nothing is missing, and says what is.
struct WorkspaceRoutineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var routine: WorkspaceRoutine
    @State private var saveError = ""
    @State private var editingAppsForAction: String?
    @State private var editingKeepVisible = false
    @State private var rememberNote = ""
    @State private var placementLayouts: [String: WorkspaceSavedLayout] = [:]
    @State private var monitorNote = ""
    @State private var tabDrafts: [String: [WorkspaceTabSetDraft]]
    @State private var tabBrowsers: [String: [WorkspaceBrowserInfo]] = [:]
    let isNew: Bool
    let controller: WorkspaceLaunchController
    let onSave: (WorkspaceRoutine) -> Bool

    init(routine: WorkspaceRoutine, isNew: Bool, controller: WorkspaceLaunchController = .shared, onSave: @escaping (WorkspaceRoutine) -> Bool) {
        _routine = State(initialValue: routine)
        _tabDrafts = State(initialValue: Dictionary(routine.actions.filter(\.isTabStep).map {
            ($0.id, WorkspaceTabSetDraft.editing($0.tabSets ?? []))
        }, uniquingKeysWith: { first, _ in first }))
        self.isNew = isNew
        self.controller = controller
        self.onSave = onSave
    }

    private var missing: [String] {
        let basic = WorkspaceWords.missing(routine)
        let invalid = routine.actions.contains { action in
            guard let placements = action.placements else { return false }
            return placements.isEmpty || placements.contains { !$0.isValid }
                || Set(placements.map { $0.macID + "|" + $0.bundleID }).count != placements.count
        }
        return basic + (invalid ? ["an app and a different app for each row on the same Mac"] : [])
    }

    private var tabProblem: String? {
        for action in routine.actions where action.isTabStep {
            if let problem = WorkspaceTabSetDraft.problem(tabDrafts[action.id] ?? []) { return problem }
        }
        return nil
    }

    var body: some View {
        DSSheet(title: isNew ? "New routine" : "Edit routine", width: .wide, height: 680) {
            VStack(alignment: .leading, spacing: DSSpace.l) {
                if !saveError.isEmpty {
                    Text(saveError).foregroundStyle(Color.dsAccent)
                }
                DSCard(padding: 0) {
                    SettingsRow(title: "Routine name") {
                        TextField("Routine name", text: $routine.name, prompt: Text("For example: Writing desk"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .accessibilityLabel("Routine name")
                    }
                }
                ForEach(Array(routine.actions.enumerated()), id: \.element.id) { index, action in
                    routineStepSection(action, index: index)
                }
                if WorkspaceGroupEditorLogic.showsControls(for: routine) { groupSection }
                addStepSection
                SettingsSectionCard(title: "Keyboard shortcut (optional)") {
                    hotkeyControls.padding(DSSpace.m)
                }
            }
        } leadingActions: {
            Group {
                if let tabProblem {
                    Label(tabProblem, systemImage: "info.circle").foregroundStyle(Color.dsTextSecondary)
                } else if missing.isEmpty {
                    Label("Ready to save.", systemImage: "checkmark.circle.fill").foregroundStyle(Color.dsSuccess)
                } else {
                    Label("To save, add \(WorkspaceWords.list(missing)).", systemImage: "info.circle").foregroundStyle(Color.dsTextSecondary)
                }
            }
            .font(.dsSecondary)
            .fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") { if onSave(savedRoutine) { dismiss() } else { saveError = controller.status } }
                .buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
                .disabled(!missing.isEmpty || tabProblem != nil)
        }
        .task {
            // Each of these asks every connected Mac for a capture, so ask for
            // browsers only when a tab step needs them.
            if routine.actions.contains(where: \.isTabStep) { await discoverBrowsers() }
            await discoverMonitors()
        }
        .sheet(isPresented: Binding(get: { editingAppsForAction != nil }, set: { if !$0 { editingAppsForAction = nil } })) {
            WorkspaceAppPicker(selectedIDs: selectedIDsForEditing) { ids in
                if let id = editingAppsForAction, let index = routine.actions.firstIndex(where: { $0.id == id }) { routine.actions[index].bundleIDs = ids }
                editingAppsForAction = nil
            }
        }
        .sheet(isPresented: $editingKeepVisible) {
            WorkspaceAppPicker(selectedIDs: routine.keepVisible ?? [], selectionLimit: 100) { ids in
                routine.keepVisible = ids.isEmpty ? nil : ids
                editingKeepVisible = false
            }
        }
    }

    private var groupSection: some View {
        DSCard(padding: 0) {
            VStack(spacing: 0) {
                SettingsRow(title: "Show only this routine's windows",
                            detail: "Other apps hide when this runs. They stay open, and Undo brings them back.") {
                    Toggle("Show only this routine's windows", isOn: Binding(
                        get: { WorkspaceGroupEditorLogic.isEnabled(routine) },
                        set: { WorkspaceGroupEditorLogic.setEnabled($0, in: &routine) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                if WorkspaceGroupEditorLogic.isEnabled(routine) {
                    SettingsDivider()
                    VStack(alignment: .leading, spacing: DSSpace.xs) {
                        Text("Keep these apps showing").font(.dsBodyMedium)
                        if let ids = routine.keepVisible, !ids.isEmpty {
                            ForEach(ids, id: \.self) { id in
                                Text(WorkspaceAppNames.name(for: id)).foregroundStyle(Color.dsTextSecondary)
                            }
                        } else {
                            Text("None chosen").foregroundStyle(Color.dsTextSecondary)
                        }
                        Button((routine.keepVisible ?? []).isEmpty ? "Choose apps…" : "Change…") { editingKeepVisible = true }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DSSpace.m)
                }
            }
        }
    }

    // MARK: Steps

    private func routineStepSection(_ action: WorkspaceAction, index: Int) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            stepHeader(action, index: index)
            DSCard {
                VStack(alignment: .leading, spacing: DSSpace.s) {
                    actionEditor(action)
                }
            }
            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                Text(action.isTabStep ? WorkspaceTabSetEditor.footer : action.isPlacement ? "Available windows share the app’s chosen position. If none are visible, one minimized window comes back. Full-screen windows stay put." : action.isRememberedLayout ? rememberedFooter : actionFooter(action.kind))
                if (action.isPlacement || action.isRememberedLayout), controller.hasWindowsOnAnotherDesktop(routineID: routine.id) {
                    Text("macOS doesn't let apps move windows between desktops, so these stay where they are.")
                }
            }
            .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepHeader(_ action: WorkspaceAction, index: Int) -> some View {
        HStack(spacing: DSSpace.xs) {
            Text(routine.actions.count > 1 ? "Step \(index + 1): \(title(action))" : title(action))
                .font(.dsSection)
            if action.isTabStep {
                Text(WorkspaceTabWords.summary(action.tabSets ?? [])).font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
            }
            Spacer()
            if routine.actions.count > 1 {
                Button { move(action.id, by: -1) } label: { Image(systemName: "arrow.up").font(.dsIcon) }
                    .buttonStyle(.dsQuiet).disabled(index == 0).help("Do this step earlier")
                Button { move(action.id, by: 1) } label: { Image(systemName: "arrow.down").font(.dsIcon) }
                    .buttonStyle(.dsQuiet).disabled(index == routine.actions.count - 1).help("Do this step later")
            }
            Button(role: .destructive) { routine.actions.removeAll { $0.id == action.id } } label: { Image(systemName: "trash").font(.dsIcon) }
                .buttonStyle(.dsQuiet).help("Remove this step").accessibilityLabel("Remove \(title(action))")
        }
    }

    @ViewBuilder private var addStepSection: some View {
        if routine.actions.isEmpty {
            SettingsSectionCard(title: "What should it do?") {
                VStack(alignment: .leading, spacing: DSSpace.s) {
                    Button("Place apps") { addPlacements() }
                    Button { addTabs() } label: {
                        HStack(spacing: DSSpace.xs) {
                            Image(systemName: "globe").font(.dsIcon).frame(width: 20).foregroundStyle(Color.dsAccent)
                            VStack(alignment: .leading, spacing: DSSpace.hair) {
                                Text("Open tabs").font(.dsBodyMedium).foregroundStyle(Color.dsTextPrimary)
                                Text("Open web pages in a browser you choose.").font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    ForEach(WorkspaceActionKind.allCases, id: \.self) { kind in
                        Button { add(kind) } label: {
                            HStack(spacing: DSSpace.xs) {
                                Image(systemName: actionSymbol(kind)).font(.dsIcon).frame(width: 20).foregroundStyle(Color.dsAccent)
                                VStack(alignment: .leading, spacing: DSSpace.hair) {
                                    Text(actionTitle(kind)).font(.dsBodyMedium).foregroundStyle(Color.dsTextPrimary)
                                    Text(actionDetail(kind)).font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Button { rememberStep(replacing: nil) } label: {
                        HStack(spacing: DSSpace.xs) {
                            Image(systemName: "macwindow.on.rectangle").font(.dsIcon).frame(width: 20).foregroundStyle(Color.dsAccent)
                            VStack(alignment: .leading, spacing: DSSpace.hair) {
                                Text(rememberedTitle).font(.dsBodyMedium).foregroundStyle(Color.dsTextPrimary)
                                Text("Remember up to \(WorkspaceSavedLayout.maxWindows) windows per Mac on the current desktop; minimized and full-screen windows are skipped.")
                                    .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                            }
                            Spacer()
                            if controller.isRemembering { ProgressView().controlSize(.small) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(controller.isRemembering)
                    if !rememberNote.isEmpty { Text(rememberNote).font(.dsSecondary).foregroundStyle(Color.dsTextSecondary) }
                }
                .padding(DSSpace.m)
            }
        } else {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                DSCard {
                    Menu("Add another step") {
                        Button("Place apps") { addPlacements() }
                        Button("Open tabs", systemImage: "globe") { addTabs() }
                        ForEach(WorkspaceActionKind.allCases, id: \.self) { kind in
                            Button(actionTitle(kind)) { add(kind) }
                        }
                        Button("\(rememberedTitle) (remember now)") { rememberStep(replacing: nil) }
                    }
                    .fixedSize()
                }
                Text("Steps run in order, top to bottom.").font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
            }
        }
    }

    @ViewBuilder private func actionEditor(_ action: WorkspaceAction) -> some View {
        if action.isTabStep {
            WorkspaceTabSetEditor(drafts: tabDraftBinding(action.id), macs: controller.placementMacs,
                                  browsers: tabBrowserChoices, displays: displays(for:macName:))
        } else if action.isPlacement {
            placementEditor(action)
        } else if action.isRememberedLayout {
            rememberedEditor(action)
        } else {
            settingsEditor(action)
        }
    }

    @ViewBuilder private func placementEditor(_ action: WorkspaceAction) -> some View {
        let placements = action.placements ?? []
        ForEach(placements.indices, id: \.self) { index in
            let placement = placements[index]
            WorkspacePlacementRow(placement: placementBinding(action.id, index: index),
                                  macs: placementMacOptions(placements),
                                  displays: displays(for: placement)) {
                updatePlacements(action.id) { $0.remove(at: index) }
            }
        }
        HStack(spacing: DSSpace.xs) {
            Button("Add app") {
                let mac = controller.placementMacs[0]
                updatePlacements(action.id) { $0.append(WorkspacePlacement(bundleID: "", appName: "", macID: mac.id, macName: mac.name)) }
            }.disabled(placements.count >= 100)
            Spacer()
            Button("Refresh monitors") { Task { await discoverMonitors() } }
        }
        openingToggle(action)
        if !monitorNote.isEmpty { Text(monitorNote).font(.dsSecondary).foregroundStyle(Color.dsTextSecondary) }
    }

    private func openingToggle(_ action: WorkspaceAction) -> some View {
        HStack(spacing: DSSpace.m) {
            Text("Open these apps if they aren't open").font(.dsBodyMedium)
            Spacer()
            Toggle("Open these apps if they aren't open", isOn: Binding(
                get: { routine.actions.first { $0.id == action.id }?.openMissingApps == true },
                set: { value in
                    if let i = routine.actions.firstIndex(where: { $0.id == action.id }) { routine.actions[i].openMissingApps = value }
                }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func placementMacOptions(_ placements: [WorkspacePlacement]) -> [WorkspaceMacOption] {
        var options = controller.placementMacs
        // A Mac removed from setup, or a hardware identity saved by another build,
        // remains editable until the user chooses a replacement.
        for p in placements where !options.contains(where: { $0.id == p.macID }) {
            options.append(.init(id: p.macID, name: p.macName, online: controller.placementIsLocal(p.macID), isCurrent: controller.placementIsLocal(p.macID)))
        }
        return options
    }

    private func displays(for placement: WorkspacePlacement) -> [WorkspaceDisplay] {
        displays(for: placement.macID, macName: placement.macName)
    }

    private func displays(for macID: String, macName: String) -> [WorkspaceDisplay] {
        if controller.placementIsLocal(macID) { return NativeWorkspaceLaunchAdapter.currentDisplays() }
        guard controller.placementMacs.contains(where: { $0.id == macID && $0.online }) else { return [] }
        return placementLayouts[macID]?.screens
            ?? placementLayouts.values.first { $0.macName == macName }?.screens ?? []
    }

    private func discoverMonitors() async {
        do {
            placementLayouts = try await controller.placementDisplays()
            monitorNote = "Offline Macs keep generic monitor choices and any monitor already saved."
        } catch {
            monitorNote = "Other Macs’ monitors are not available right now. Your saved choices are kept. Reopen this editor to try again."
        }
    }

    private func updatePlacements(_ id: String, change: (inout [WorkspacePlacement]) -> Void) {
        guard let i = routine.actions.firstIndex(where: { $0.id == id }) else { return }
        var placements = routine.actions[i].placements ?? []
        change(&placements)
        routine.actions[i].placements = placements
        routine.actions[i].bundleIDs = Array(Set(placements.map(\.bundleID).filter { !$0.isEmpty })).sorted()
    }

    private func placementBinding(_ id: String, index: Int) -> Binding<WorkspacePlacement> {
        Binding(get: {
            guard let placements = routine.actions.first(where: { $0.id == id })?.placements, placements.indices.contains(index) else {
                return WorkspacePlacement(bundleID: "", appName: "", macID: "", macName: "")
            }
            return placements[index]
        },
                set: { value in updatePlacements(id) { if $0.indices.contains(index) { $0[index] = value } } })
    }

    private var savedRoutine: WorkspaceRoutine {
        var result = routine
        for index in result.actions.indices where result.actions[index].isTabStep {
            let id = result.actions[index].id
            result.actions[index] = WorkspaceTabSetDraft.action(tabDrafts[id] ?? [], id: id)
        }
        return result
    }

    private var tabBrowserChoices: [String: [WorkspaceBrowserInfo]] {
        var choices = tabBrowsers
        if let local = controller.placementMacs.first(where: \.isCurrent), let browsers = choices[local.id] {
            for draft in tabDrafts.values.flatMap({ $0 }) where controller.placementIsLocal(draft.set.macID) {
                choices[draft.set.macID] = browsers
            }
        }
        return choices
    }

    private func tabDraftBinding(_ id: String) -> Binding<[WorkspaceTabSetDraft]> {
        Binding(get: { tabDrafts[id] ?? [] }, set: { drafts in
            tabDrafts[id] = drafts
            guard let index = routine.actions.firstIndex(where: { $0.id == id }) else { return }
            routine.actions[index] = WorkspaceTabSetDraft.action(drafts, id: id)
        })
    }

    private func discoverBrowsers() async {
        tabBrowsers = await controller.availableBrowsers()
        guard !Task.isCancelled else { return }
        // A new blank step may have been added before discovery finished.
        for action in routine.actions where action.isTabStep {
            var drafts = tabDrafts[action.id] ?? []
            for index in drafts.indices where drafts[index].set.browserBundleID.isEmpty {
                if let browser = tabBrowserChoices[drafts[index].set.macID]?.first { drafts[index].chooseBrowser(browser) }
            }
            tabDraftBinding(action.id).wrappedValue = drafts
        }
    }

    private func addTabs() {
        guard let mac = controller.placementMacs.first(where: \.isCurrent) ?? controller.placementMacs.first else { return }
        let drafts: [WorkspaceTabSetDraft] = [.newWindow(mac: mac, browsers: tabBrowsers[mac.id] ?? [])]
        let action = WorkspaceTabSetDraft.action(drafts)
        tabDrafts[action.id] = drafts
        routine.actions.append(action)
        if routine.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { routine.name = "Open tabs" }
        if tabBrowsers.isEmpty { Task { await discoverBrowsers() } }
    }

    private func addPlacements() {
        let mac = controller.placementMacs[0]
        routine.actions.append(.placing([WorkspacePlacement(bundleID: "", appName: "", macID: mac.id, macName: mac.name)]))
        if routine.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { routine.name = "Place apps" }
    }

    /// Each Mac's remembered windows, drawn, with Remember again and Forget.
    @ViewBuilder private func rememberedEditor(_ action: WorkspaceAction) -> some View {
        let here = WorkspaceMacIdentity.current
        let layouts = action.remembered ?? [:]
        let keys = layouts.keys.sorted { a, b in
            a == here ? true : b == here ? false : layouts[a]!.macName.localizedCaseInsensitiveCompare(layouts[b]!.macName) == .orderedAscending
        }
        ForEach(keys, id: \.self) { key in
            if let layout = layouts[key] {
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    HStack(spacing: DSSpace.xs) {
                        Text(key == here ? "\(layout.macName) (this Mac)" : layout.macName).font(.dsBodyMedium)
                        Spacer()
                        Text("\(layout.countSummary) · \(layout.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                        Button { forget(key, in: action.id) } label: { Image(systemName: "trash").font(.dsIcon) }
                            .buttonStyle(.dsQuiet).help("Forget the windows remembered on \(layout.macName)")
                            .accessibilityLabel("Forget \(layout.macName)")
                    }
                    WorkspacePreviewDiagram(picture: layout.picture).frame(height: 120)
                }
                .padding(.vertical, DSSpace.xxs)
            }
        }
        HStack(spacing: DSSpace.xs) {
            if controller.isRemembering {
                ProgressView().controlSize(.small)
                Text("Looking at your windows…").foregroundStyle(Color.dsTextSecondary)
            } else {
                Button(controller.otherConnectedMacs.isEmpty ? "Remember again" : "Remember again on all my Macs") { rememberStep(replacing: action.id) }
                    .help("Replaces what was remembered with where the windows are right now.")
            }
            Spacer()
        }
        openingToggle(action)
        if !rememberNote.isEmpty { Text(rememberNote).font(.dsSecondary).foregroundStyle(Color.dsTextSecondary).fixedSize(horizontal: false, vertical: true) }
    }

    @ViewBuilder private func settingsEditor(_ action: WorkspaceAction) -> some View {
        if action.kind == .arrangeWindows || action.kind == .hideIdleApps {
            LabeledContent(action.kind == .hideIdleApps ? "Apps it may hide" : "Apps") {
                HStack(spacing: DSSpace.xs) {
                    if action.bundleIDs.isEmpty {
                        Text("None yet").foregroundStyle(Color.dsWarning)
                    } else {
                        Text(WorkspaceWords.list(action.bundleIDs.map(WorkspaceAppNames.name)))
                            .foregroundStyle(Color.dsTextSecondary).lineLimit(2).multilineTextAlignment(.trailing)
                    }
                    Button(action.bundleIDs.isEmpty ? "Choose apps…" : "Change…") { editingAppsForAction = action.id }
                }
            }
        }
        if action.kind == .arrangeWindows {
            LabeledContent("Layout") {
                HStack(spacing: DSSpace.xs) {
                    ForEach(WorkspaceLayout.allCases, id: \.self) { layout in
                        layoutChoice(layout, action: action)
                    }
                }
            }
        }
        if action.kind == .arrangeWindows || action.kind == .centerLastWindow {
            Picker("Screen", selection: actionBinding(action.id, \.display, fallback: action.display)) {
                Text("Main screen").tag(WorkspaceDisplayTarget.main)
                Text("Left screen").tag(WorkspaceDisplayTarget.left)
                Text("Right screen").tag(WorkspaceDisplayTarget.right)
            }.pickerStyle(.segmented)
            WorkspaceThisMacScreen(choice: thisMacBinding(action.id))
        }
        if action.kind == .hideIdleApps {
            Picker("Hide after", selection: actionBinding(action.id, \.idleMinutes, fallback: action.idleMinutes)) {
                Text("30 minutes").tag(30); Text("1 hour").tag(60); Text("2 hours").tag(120); Text("3 hours").tag(180)
            }
        }
    }

    /// A drawing of where windows go with this layout, for as many apps as are chosen.
    private func layoutChoice(_ layout: WorkspaceLayout, action: WorkspaceAction) -> some View {
        let selected = action.layout == layout
        let count = max(2, min(action.bundleIDs.count, 6))
        return Button { setLayout(layout, for: action.id) } label: {
            VStack(spacing: DSSpace.xxs) {
                WorkspaceScreenSketch(tiles: WorkspacePlanner.tileFrames(in: WorkspaceRect(x: 0, y: 0, width: 1, height: 1), count: count, layout: layout))
                    .frame(width: 56)
                Text(layoutName(layout)).font(.dsSecondary).foregroundStyle(selected ? Color.dsTextPrimary : Color.dsTextSecondary)
            }
            .padding(DSSpace.xs)
            .background(selected ? Color.dsAccentQuiet : Color.clear, in: RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous).strokeBorder(selected ? Color.dsAccent : Color.dsBorderSubtle, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(layoutName(layout))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(action.bundleIDs.count > 1 ? "How \(action.bundleIDs.count) windows are laid out" : "How the windows are laid out")
    }

    private var hotkeyControls: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            HStack(spacing: DSSpace.xs) {
                Text("Run from any app with").font(.dsBodyMedium)
                Spacer()
                WorkspaceHotkeyRecorder(hotkey: $routine.hotkey) { key in
                    WorkspaceHotkeyConflict.problem(for: key, routineID: routine.id, routines: AppSettings.shared.workspaceLaunch.routines,
                                                    triggers: AppSettings.shared.hotkeyTriggers)
                        ?? VoiceCommandHotkeys.conflict(key, commands: AppSettings.shared.voiceLaunch.commands)
                }
            }
            if let problem = WorkspaceLaunchController.shared.hotkeyFailures[routine.id], routine.enabled, routine.hotkey != nil,
               AppSettings.shared.workspaceLaunch.routines.first(where: { $0.id == routine.id })?.hotkey == routine.hotkey {
                Text(problem).font(.dsSecondary).foregroundStyle(Color.dsWarning)
            }
            Text("Click the box, then hold at least two of ⌃ ⌥ ⌘ and press a key. Esc cancels; Delete removes the shortcut. You can always use Run on the Workspaces page instead.")
                .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Words

    private let rememberedTitle = "Put windows back where they were"
    private let rememberedFooter = "Running the routine brings back minimized windows and puts these in place, with the same ones in front. Windows on another desktop stay there."

    private func title(_ action: WorkspaceAction) -> String {
        action.isTabStep ? "Open tabs" : action.isPlacement ? "Place apps" : action.isRememberedLayout ? rememberedTitle : actionTitle(action.kind)
    }

    private func actionTitle(_ kind: WorkspaceActionKind) -> String {
        switch kind {
        case .arrangeWindows: "Arrange windows"
        case .centerLastWindow: "Center the window you're using"
        case .hideIdleApps: "Hide apps you haven't used"
        }
    }

    private func actionDetail(_ kind: WorkspaceActionKind) -> String {
        switch kind {
        case .arrangeWindows: "Lay out the windows of apps you choose, side by side or in a grid."
        case .centerLastWindow: "Move your current window to the middle of a screen."
        case .hideIdleApps: "Hide apps you choose once they've gone unused for a while."
        }
    }

    private func actionSymbol(_ kind: WorkspaceActionKind) -> String {
        switch kind {
        case .arrangeWindows: "rectangle.split.2x2"
        case .centerLastWindow: "rectangle.center.inset.filled"
        case .hideIdleApps: "eye.slash"
        }
    }

    private func actionFooter(_ kind: WorkspaceActionKind) -> String {
        switch kind {
        case .arrangeWindows: "Only open windows on the current desktop move. Minimized and full-screen windows are left alone."
        case .centerLastWindow: "Uses the window you were in just before you ran the routine."
        case .hideIdleApps: "Dictator only knows which apps you've used since it started with this routine on, so after it restarts the wait begins again. Hidden apps stay open: click one in the Dock to bring it back."
        }
    }

    private func layoutName(_ layout: WorkspaceLayout) -> String {
        switch layout {
        case .quarters: "Quarters"
        case .halves: "Halves"
        case .columns: "Columns"
        }
    }

    // MARK: Editing

    private var selectedIDsForEditing: [String] {
        guard let id = editingAppsForAction else { return [] }
        return routine.actions.first { $0.id == id }?.bundleIDs ?? []
    }

    private func add(_ kind: WorkspaceActionKind) {
        routine.actions.append(WorkspaceAction(kind: kind))
        if routine.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, routine.actions.count == 1 { routine.name = actionTitle(kind) }
    }

    /// Remembers the windows now and puts them in step `id`, or in a new step.
    private func rememberStep(replacing id: String?) {
        Task { @MainActor in
            let layouts = await controller.rememberLayouts(everywhere: !controller.otherConnectedMacs.isEmpty)
            rememberNote = controller.status
            guard let layouts else { return }
            if let id, let index = routine.actions.firstIndex(where: { $0.id == id }) {
                routine.actions[index] = .remembering(layouts, id: id, openMissingApps: routine.actions[index].openMissingApps)
            } else {
                routine.actions.append(.remembering(layouts))
                if routine.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { routine.name = "My layout" }
            }
        }
    }

    private func forget(_ macKey: String, in id: String) {
        guard let index = routine.actions.firstIndex(where: { $0.id == id }) else { return }
        var layouts = routine.actions[index].remembered ?? [:]
        layouts.removeValue(forKey: macKey)
        if layouts.isEmpty { routine.actions.remove(at: index) } else { routine.actions[index] = .remembering(layouts, id: id, openMissingApps: routine.actions[index].openMissingApps) }
    }

    private func setLayout(_ layout: WorkspaceLayout, for id: String) {
        guard let index = routine.actions.firstIndex(where: { $0.id == id }) else { return }
        routine.actions[index].layout = layout
    }

    private func actionBinding<Value>(_ id: String, _ keyPath: WritableKeyPath<WorkspaceAction, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { routine.actions.first { $0.id == id }?[keyPath: keyPath] ?? fallback }, set: { value in
            guard let index = routine.actions.firstIndex(where: { $0.id == id }) else { return }
            routine.actions[index][keyPath: keyPath] = value
        })
    }

    private func thisMacBinding(_ id: String) -> Binding<WorkspaceDisplayChoice?> {
        let mac = WorkspaceMacIdentity.current
        return Binding(
            get: { routine.actions.first { $0.id == id }?.displayOverrides?[mac] },
            set: { choice in
                guard let index = routine.actions.firstIndex(where: { $0.id == id }) else { return }
                var overrides = routine.actions[index].displayOverrides ?? [:]
                overrides[mac] = choice
                routine.actions[index].displayOverrides = overrides.isEmpty ? nil : overrides
            }
        )
    }

    private func move(_ id: String, by delta: Int) {
        guard let index = routine.actions.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + delta
        guard routine.actions.indices.contains(destination) else { return }
        routine.actions.swapAt(index, destination)
    }
}

/// A row binds one app to one Mac, monitor and position.
private struct WorkspacePlacementRow: View {
    @Binding var placement: WorkspacePlacement
    let macs: [WorkspaceMacOption]
    let displays: [WorkspaceDisplay]
    let remove: () -> Void
    @State private var choosingApp = false

    private var monitors: [WorkspaceMonitorChoice] {
        WorkspaceEditorMonitorChoices.choices(displays: displays, saved: placement.monitor)
    }

    var body: some View {
        HStack(alignment: .top, spacing: DSSpace.xs) {
            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                Text("App").font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                Button(placement.appName.isEmpty ? "Choose app…" : placement.appName) { choosingApp = true }
                    .lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                Text("Mac").font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                Picker("Mac", selection: Binding(get: { placement.macID }, set: { id in
                    guard let mac = macs.first(where: { $0.id == id }) else { return }
                    placement.macID = id; placement.macName = mac.name
                    placement.monitor = .generic(.main)
                })) {
                    ForEach(macs) { mac in
                        Text(mac.name + (mac.isCurrent ? " (this Mac)" : mac.online ? "" : " (offline)"))
                            .tag(mac.id)
                    }
                }.labelsHidden()
            }.frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                Text("Monitor").font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                Picker("Monitor", selection: $placement.monitor) {
                    ForEach(monitors, id: \.self) { monitor in Text(monitor.label).tag(monitor) }
                }.labelsHidden()
            }.frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                Text("Position").font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                Picker("Position", selection: $placement.position) {
                    ForEach(WorkspacePosition.allCases, id: \.self) { position in Text(position.label).tag(position) }
                }.labelsHidden()
            }.frame(maxWidth: .infinity)
            Button(action: remove) { Image(systemName: "minus.circle").font(.dsIcon) }
                .buttonStyle(.dsQuiet).accessibilityLabel("Remove app").padding(.top, DSSpace.l)
        }
        .sheet(isPresented: $choosingApp) {
            WorkspacePlacementAppPicker(stored: placement) { id, name in placement.bundleID = id; placement.appName = name }
        }
    }
}

/// Local inventory only. A bundle ID can also be entered for an app on another Mac.
private struct WorkspacePlacementAppPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var bundleID = ""
    @State private var appName = ""
    @State private var search = ""
    @State private var note = ""
    @State private var apps: [WorkspaceAppNames.App]

    init(stored: WorkspacePlacement, choose: @escaping (String, String) -> Void) {
        var initial = WorkspaceAppNames.runningApps()
        if !stored.bundleID.isEmpty, !initial.contains(where: { $0.id == stored.bundleID }) {
            initial.append(.init(id: stored.bundleID, name: stored.appName, open: false))
        }
        _apps = State(initialValue: initial)
        self.choose = choose
    }
    let choose: (String, String) -> Void

    var body: some View {
        DSSheet(title: "Choose an app", width: .standard, height: 600) {
            VStack(alignment: .leading, spacing: DSSpace.s) {
                TextField("Find a running or installed app", text: $search).textFieldStyle(.roundedBorder)
                List(apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }, id: \.id) { app in
                    Button { choose(app.id, app.name); dismiss() } label: {
                        HStack(spacing: DSSpace.xs) {
                            Text(app.name).font(.dsBodyMedium)
                            Spacer()
                            Text(app.open ? "open" : "installed").font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                        }
                    }.buttonStyle(.plain)
                }
                .frame(height: 240)
                .scrollContentBackground(.hidden)
                Text("For an app only on another Mac, enter its bundle ID and name below.").font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                TextField("Bundle ID", text: $bundleID).textFieldStyle(.roundedBorder)
                TextField("App name", text: $appName).textFieldStyle(.roundedBorder)
                if !note.isEmpty { Text(note).font(.dsSecondary).foregroundStyle(Color.dsTextSecondary) }
            }
        } leadingActions: {
            Button("Choose…") { chooseFile() }
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Use bundle ID") { choose(bundleID.trimmingCharacters(in: .whitespacesAndNewlines), appName.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
                .buttonStyle(.dsPrimary)
                .disabled(bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bundleID.count > 255
                          || appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appName.count > 120)
        }
        .task {
            let installed = await VoiceInstalledApps.load()
            guard !Task.isCancelled else { return }
            apps = WorkspaceAppNames.merging(apps, installed: installed)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let id = Bundle(url: url)?.bundleIdentifier else { note = "This app doesn't have a bundle ID. Choose another app."; return }
        let name = FileManager.default.displayName(atPath: url.path)
        choose(id, name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
        dismiss()
    }
}

/// The per-Mac screen choice, folded away until it is wanted.
private struct WorkspaceThisMacScreen: View {
    @Binding var choice: WorkspaceDisplayChoice?
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded || choice != nil }, set: { expanded = $0 })) {
            Picker("On this Mac", selection: $choice) {
                Text("Same as above").tag(WorkspaceDisplayChoice?.none)
                ForEach(WorkspaceDisplayChoice.allCases, id: \.self) { choice in
                    Text(WorkspaceDisplayResolver.label(choice)).tag(WorkspaceDisplayChoice?.some(choice))
                }
            }
            Text("Only changes this Mac. Your other Macs keep using the screen chosen above. Useful for a laptop you also use away from your desk.")
                .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary).fixedSize(horizontal: false, vertical: true)
        } label: {
            Text("Use a different screen on this Mac").font(.dsBody)
        }
    }
}

private struct WorkspaceAppPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>
    let onSave: ([String]) -> Void
    private let selectionLimit: Int?
    private let apps: [(id: String, name: String, icon: NSImage?, isOpen: Bool)]

    init(selectedIDs: [String], selectionLimit: Int? = nil, onSave: @escaping ([String]) -> Void) {
        _selected = State(initialValue: Set(selectedIDs))
        self.onSave = onSave
        self.selectionLimit = selectionLimit
        let ownID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var apps: [(id: String, name: String, icon: NSImage?, isOpen: Bool)] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  let id = app.bundleIdentifier, id != ownID,
                  let name = app.localizedName, !name.isEmpty, seen.insert(id).inserted else { return nil }
            return (id, name, app.icon, true)
        }
        // Apps chosen earlier stay listed even when they are not open right now.
        for id in selectedIDs where seen.insert(id).inserted {
            let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
            apps.append((id, WorkspaceAppNames.name(for: id), icon, false))
        }
        self.apps = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        DSSheet(title: "Choose apps", width: .standard, height: 520) {
            VStack(alignment: .leading, spacing: DSSpace.s) {
                Text("The apps open right now are listed. To add another app, open it, then come back to this list.")
                    .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary).fixedSize(horizontal: false, vertical: true)
                List(apps, id: \.id) { app in
                    HStack(spacing: DSSpace.xs) {
                        if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                        Text(app.name).font(.dsBodyMedium)
                        if !app.isOpen { Text("not open").font(.dsSecondary).foregroundStyle(Color.dsTextSecondary) }
                        Spacer()
                        Toggle(app.name, isOn: Binding(
                            get: { selected.contains(app.id) },
                            set: { on in if on { selected.insert(app.id) } else { selected.remove(app.id) } }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!selected.contains(app.id) && selectionLimit.map { selected.count >= $0 } == true)
                    }
                }
                .frame(height: 300)
                .scrollContentBackground(.hidden)
            }
        } leadingActions: {
            Text(selected.isEmpty ? "None chosen" : selected.count == 1 ? "1 app chosen" : "\(selected.count) apps chosen")
                .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Done") { onSave(Array(selected).sorted()); dismiss() }
                .buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
                .disabled(selectionLimit.map { selected.count > $0 } == true)
        }
    }
}

/// Click, then press the keys. A local monitor sees keys only while this
/// control is recording and only inside Dictator's own window.
struct WorkspaceHotkeyRecorder: View {
    @Binding var hotkey: WorkspaceHotkey?
    let problem: (WorkspaceHotkey) -> String?
    private var triggers: HotkeyTriggers { AppSettings.shared.hotkeyTriggers }
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message = ""

    var body: some View {
        VStack(alignment: .trailing, spacing: DSSpace.xxs) {
            HStack(spacing: DSSpace.xs) {
                Button(action: { recording ? stop() : start() }) {
                    Text(recording ? "Press the keys…" : (hotkey.map { WorkspaceHotkeyFormat.display($0) } ?? "Click, then press the keys"))
                        .frame(minWidth: 170)
                }
                .accessibilityLabel("Keyboard shortcut")
                if hotkey != nil && !recording {
                    Button { hotkey = nil; message = "" } label: { Image(systemName: "xmark.circle.fill").font(.dsIcon) }
                        .buttonStyle(.dsQuiet).accessibilityLabel("Remove shortcut")
                }
            }
            if !message.isEmpty { Text(message).font(.dsSecondary).foregroundStyle(Color.dsWarning).multilineTextAlignment(.trailing) }
        }
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in stop() }
    }

    private func start() {
        message = ""
        recording = true
        // Turn off routine shortcuts first, so the keys pressed here cannot run a routine.
        WorkspaceLaunchController.shared.beginShortcutRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event) ? nil : event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        WorkspaceLaunchController.shared.endShortcutRecording()
    }

    /// Returns true when the key was consumed by the recorder.
    private func handle(_ event: NSEvent) -> Bool {
        guard recording else { return false }
        if event.type == .flagsChanged {
            // A lone modifier press (such as Right ⌥) never reaches keyDown; refuse it only if it is the dictation key.
            if let issue = WorkspaceHotkeyConflict.modifierOnlyProblem(keyCode: UInt32(event.keyCode), triggers: triggers) { message = issue }
            return false
        }
        guard !event.isARepeat else { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= WorkspaceHotkey.command }
        if flags.contains(.shift) { modifiers |= WorkspaceHotkey.shift }
        if flags.contains(.option) { modifiers |= WorkspaceHotkey.option }
        if flags.contains(.control) { modifiers |= WorkspaceHotkey.control }
        if modifiers == 0 && event.keyCode == 53 { stop(); return true }
        if modifiers == 0 && (event.keyCode == 51 || event.keyCode == 117) { hotkey = nil; message = ""; stop(); return true }
        let key = WorkspaceHotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        if WorkspaceHotkeyConflict.dictationModifierHeld(triggers: triggers, deviceFlags: event.modifierFlags.rawValue) {
            message = WorkspaceHotkeyConflict.dictationPartMessage
        } else if let issue = problem(key) {
            message = issue
        } else {
            hotkey = key
            message = ""
        }
        stop()
        return true
    }
}
