import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Only the Commands screen offers import. No document registration or URL hook.
struct CommandFileButtons: View {
    @State private var settings = AppSettings.shared
    @State private var exporting = false
    @State private var importing: CommandFile.Draft?
    @State private var problem: String?

    var body: some View {
        HStack(spacing: DSSpace.xs) {
            Button("Import…", action: chooseFile)
            Button("Export…") { exporting = true }
                .disabled(settings.voiceLaunch.commands.isEmpty)
        }
        .buttonStyle(.dsQuiet)
        .sheet(isPresented: $exporting) { CommandExportSheet(config: settings.voiceLaunch) }
        .sheet(item: $importing) { draft in CommandImportSheet(draft: draft) }
        .alert("Command file", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Import commands"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Bound the read as well as the parser. A size attribute alone can
            // race a changed file, and Data(contentsOf:) could allocate it all.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var data = Data()
            while data.count <= CommandFile.maxBytes {
                let chunk = try handle.read(upToCount: min(65_536, CommandFile.maxBytes + 1 - data.count)) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            importing = try CommandFile.read(data)
        } catch {
            problem = (error as? CommandFile.Problem)?.localizedDescription ?? "This file could not be opened. Choose a readable JSON file."
        }
    }
}

struct CommandExportSheet: View {
    let config: VoiceLaunchConfig
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var includeEntries = Set<String>()
    @State private var includeLocations = false
    @State private var problem: String?

    private var options: CommandFile.ExportOptions {
        .init(commandIDs: selected, listsWithEntries: includeEntries, includeLocations: includeLocations)
    }
    private var lists: [VoiceList] {
        CommandFile.lists(usedBy: config.commands.filter { selected.contains($0.id) }, in: config.lists)
    }

    var body: some View {
        DSSheet(title: "Export commands", subtitle: "Choose commands and check the details you want to share.", width: .wide, height: 620) {
            VStack(alignment: .leading, spacing: DSSpace.m) {
                ForEach(config.commands) { command in
                    Toggle(isOn: membership(command.id, in: $selected)) {
                        Text(CommandFile.visible(command.name + ": " + command.pattern))
                    }
                }
                Divider()
                ForEach(lists) { list in
                    VStack(alignment: .leading, spacing: DSSpace.xs) {
                        Text(CommandFile.visible(list.name)).font(.dsSection)
                        Text("Details: " + CommandFile.visible(list.fields.joined(separator: ", ")))
                        // Details precede the opt-in. No collapsed disclosure
                        // can hide what the checkbox would send.
                        ForEach(list.entries) { entry in
                            Text(CommandFile.entryText(entry))
                                .font(.dsCaption).textSelection(.enabled)
                        }
                        Toggle("Include entries from \(CommandFile.visible(list.name))", isOn: membership(list.id, in: $includeEntries))
                    }
                }
                Divider()
                Text("Folders, files and addresses").font(.dsSection)
                Text("These values may be personal or contain secrets. Leaving them out blanks each whole value that contains one.")
                ForEach((try? CommandFile.locations(in: config, options: options)) ?? [], id: \.self) { value in
                    Text(CommandFile.visible(value)).font(.dsMonoCaption).textSelection(.enabled)
                }
                Toggle("Include these folders, files and addresses", isOn: $includeLocations)
                Text("Keyboard shortcuts and permission to run from other apps are always left out.").font(.dsCaption)
            }
            if let problem { Text(problem).foregroundStyle(Color.dsAccent) }
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save file…", action: save).disabled(selected.isEmpty).buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
        }
    }

    private func membership(_ id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) }, set: { on in
            if on { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) }
        })
    }

    private func save() {
        do {
            let data = try CommandFile.export(config, options: options)
            let panel = NSSavePanel()
            panel.title = "Export commands"
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "Dictator commands.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            dismiss()
        } catch {
            problem = (error as? CommandFile.Problem)?.localizedDescription ?? "The command file could not be saved. Choose another location."
        }
    }
}

struct CommandImportSheet: View {
    @State var draft: CommandFile.Draft
    @State private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?

    var body: some View {
        DSSheet(title: "Review commands", subtitle: "Every imported command stays off. Nothing runs while you review or import.", width: .wide, height: 680) {
            VStack(alignment: .leading, spacing: DSSpace.m) {
                ForEach($draft.commands) { $command in
                    VStack(alignment: .leading, spacing: DSSpace.xs) {
                        Text(CommandFile.visible(command.name)).font(.dsSection)
                        Text("Phrase: " + CommandFile.visible(command.pattern)).textSelection(.enabled)
                        TextField("Phrase", text: $command.pattern)
                        if !command.triggerAliases.isEmpty {
                            Text("Also listens for: " + CommandFile.visible(command.triggerAliases.joined(separator: ", "))).textSelection(.enabled)
                            Button("Leave out these other phrases") { command.triggerAliases = [] }.buttonStyle(.dsQuiet)
                        }
                        if let clash = CommandFile.clash(for: command, among: settings.voiceLaunch.commands + draft.commands) {
                            Text(clash).foregroundStyle(Color.dsWarning)
                        }
                        warnings(command.name + " " + command.pattern + " " + command.triggerAliases.joined(separator: " "))
                        if !command.onlyInApps.isEmpty {
                            Text("Only in apps: " + CommandFile.visible(command.onlyInApps.joined(separator: ", ")))
                        }
                        ForEach($command.steps) { $step in
                            DSCard { VStack(alignment: .leading, spacing: DSSpace.xxs) {
                                HStack {
                                    Text(CommandFile.visible(VoiceBuildCopy.summary(step, routines: settings.workspaceLaunch.routines))).font(.dsSection)
                                    if CommandFile.checkThis(step) { Text("Check this").foregroundStyle(Color.dsWarning).bold() }
                                }
                                Text(CommandFile.details(step)).font(.dsMonoCaption).textSelection(.enabled)
                                ForEach(CommandFile.warnings(in: step), id: \.self) { warning in
                                    Text(warning).font(.dsCaption).foregroundStyle(Color.dsWarning)
                                }
                                if CommandFile.needsValue(step) {
                                    Text("Needs a value before importing.").foregroundStyle(Color.dsWarning)
                                }
                                missingValue($step)
                            } }
                        }
                    }
                    Divider()
                }
                Text("Lists").font(.dsSection)
                Text("Lists with the same name are combined. Existing entries are kept when names or aliases overlap.")
                ForEach(draft.lists) { list in
                    VStack(alignment: .leading, spacing: DSSpace.xxs) {
                        Text(CommandFile.visible(list.name + " (" + list.fields.joined(separator: ", ") + ")")).bold()
                        ForEach(list.entries) { entry in
                            Text(CommandFile.entryText(entry))
                                .font(.dsCaption).textSelection(.enabled)
                        }
                    }
                }
            }
            if let problem { Text(problem).foregroundStyle(Color.dsAccent) }
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Import commands", action: confirm).disabled(draft.commands.isEmpty).buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
        }
    }

    private func warnings(_ text: String) -> some View {
        ForEach(CommandFile.warnings(in: text), id: \.self) { warning in
            Text(warning).font(.dsCaption).foregroundStyle(Color.dsWarning)
        }
    }

    @ViewBuilder private func missingValue(_ step: Binding<VoiceStep>) -> some View {
        switch step.wrappedValue.kind {
        case .openLink, .webhook: TextField("Address", text: value(step.link))
        case .runInTerminal:
            TextField("Folder", text: value(step.folder))
            TextField("Command", text: Binding(get: { step.wrappedValue.command ?? VoiceLaunchConfig.defaultAgentCommand }, set: { step.wrappedValue.command = $0 }))
        case .appendToFile: TextField("File path", text: value(step.path))
        case .openApp:
            if (step.wrappedValue.bundleId ?? "").isEmpty { TextField("App name", text: value(step.text)) }
        default: EmptyView()
        }
    }

    private func value(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0 })
    }

    private func confirm() {
        do {
            let candidate = try CommandFile.merging(draft, into: settings.voiceLaunch)
            // The same path as an editor save, including the main-Mac mirror.
            settings.updateVoiceLaunch { $0 = candidate }
            dismiss()
        } catch {
            problem = (error as? CommandFile.Problem)?.localizedDescription ?? "These commands could not be imported. Check their values and try again."
        }
    }
}
