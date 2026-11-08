import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Import history: prompts written in other apps become History rows, so
/// Dataset can prepare them too. Shows exactly what will be added first; every
/// import can be removed as a whole.
struct ImportHistorySheet: View {
    let store: DatasetStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove: DatasetStore.PastImport?

    var body: some View {
        DSSheet(title: title, width: .wide, height: sheetHeight) {
            switch store.importSession.stage {
            case .choosing: chooser
            case .reading: progress("Reading \(sourceName)…")
            case .preview: previewView
            case .importing: progress("Importing \(sourceName)…")
            case .done(let count): doneView(count)
            case .failed(let message): failedView(message)
            }
        } leadingActions: {
            switch store.importSession.stage {
            case .choosing:
                if let kind = store.importSession.kind {
                    let info = ImportSourceInfo.info(for: kind)
                    if info.readsFromThisMac {
                        Button("Choose another location…") { pick(info) }
                    }
                }
            case .preview, .failed:
                Button("Back") { store.chooseImportSource(store.importSession.kind ?? .chatgpt) }
            case .done:
                if let batch = store.importSession.batchID {
                    Button("Undo import") { Task { await store.removeImport(batchID: batch) } }
                        .buttonStyle(.dsDestructive)
                }
                Button("Import another source") { store.resetImport() }
            default: EmptyView()
            }
        } actions: {
            if case .done = store.importSession.stage {
                Button("Close") { dismiss() }
                    .buttonStyle(.dsPrimary)
                    .keyboardShortcut(.defaultAction)
                    .background {
                        // Keep Escape as well as Return without showing Close twice.
                        Button("Close") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                            .frame(width: 0, height: 0)
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
            } else {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            switch store.importSession.stage {
            case .choosing:
                if let kind = store.importSession.kind {
                    let info = ImportSourceInfo.info(for: kind)
                    if info.readsFromThisMac {
                        Button("Preview prompts") { Task { await store.readImport(from: nil) } }
                            .buttonStyle(.dsPrimary)
                    } else {
                        Button("Choose file…") { pick(info) }
                            .buttonStyle(.dsPrimary)
                    }
                }
            case .preview:
                let count = store.importSession.preview?.toImport.count ?? 0
                Button(count == 0 ? "Nothing to import" : "Import \(count.formatted()) prompts") {
                    Task { await store.runImport() }
                }
                .buttonStyle(.dsPrimary)
                .disabled(count == 0)
            default: EmptyView()
            }
        }
        .alert(item: $confirmRemove) { past in
            Alert(
                title: Text("Delete this import?"),
                message: Text("\(past.count.formatted()) prompts imported from \(past.name) will be deleted from this Mac. Update Dictator on your other Macs and let them reconnect to receive the deletion."),
                primaryButton: .destructive(Text("Delete import")) { Task { await store.removeImport(batchID: past.id) } },
                secondaryButton: .cancel()
            )
        }
    }

    private var sheetHeight: CGFloat? {
        switch store.importSession.stage {
        case .choosing, .preview: 640
        default: nil
        }
    }

    private var title: String {
        if case .choosing = store.importSession.stage { return "Import history" }
        return store.importSession.kind.map { ImportSourceInfo.info(for: $0).name } ?? "Import history"
    }

    private var sourceName: String {
        store.importSession.kind.map { ImportSourceInfo.info(for: $0).name } ?? ""
    }

    // MARK: Choose

    private var chooser: some View {
        VStack(alignment: .leading, spacing: DSSpace.m) {
            Text("Imported prompts are added to History and available in Datasets. Dictator imports only your own messages, never the AI's replies. Files that don't mark who wrote each line are imported in full.")
                .font(.dsBody)
                .foregroundStyle(Color.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: DSSpace.xs), GridItem(.flexible(), spacing: DSSpace.xs)], spacing: DSSpace.xs) {
                ForEach(ImportSourceKind.allCases) { kind in
                    let info = ImportSourceInfo.info(for: kind)
                    let selected = store.importSession.kind == kind
                    Button {
                        store.chooseImportSource(kind)
                    } label: {
                        VStack(alignment: .leading, spacing: DSSpace.hair) {
                            Text(info.name).font(.dsBodyMedium).foregroundStyle(Color.dsTextPrimary)
                            Text(info.how).font(.dsSecondary).foregroundStyle(Color.dsTextTertiary).multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .padding(DSSpace.m)
                        .dsCardSurface(selected ? .dsAccentQuiet : .dsSurfaceCard,
                                       border: selected ? .dsAccent : .dsBorderSubtle)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            if let kind = store.importSession.kind {
                let info = ImportSourceInfo.info(for: kind)
                if info.readsFromThisMac {
                    Text("Nothing is added until you confirm.")
                        .font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
                } else if let hint = info.fileHint {
                    Text("Usually named \(hint)")
                        .font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
                }
            }
            pastImports
        }
    }

    private var pastImports: some View {
        let past = store.pastImports
        return VStack(alignment: .leading, spacing: DSSpace.xs) {
            if !past.isEmpty {
                Text("Previous imports")
                    .font(.dsSection)
                    .padding(.top, DSSpace.xs)
                ForEach(past) { item in
                    Divider().overlay(Color.dsDivider)
                    HStack(spacing: DSSpace.xs) {
                        Text(item.name).font(.dsBodyMedium)
                        Text("\(item.count.formatted()) prompts" + (item.date.map { ", \($0.datasetShort)" } ?? ""))
                            .font(.dsBody)
                            .foregroundStyle(Color.dsTextSecondary)
                        Spacer()
                        Button("Delete import…") { confirmRemove = item }
                            .buttonStyle(.dsDestructive)
                            .font(.dsBody)
                    }
                    .frame(minHeight: 36)
                }
            }
        }
    }

    private func pick(_ info: ImportSourceInfo) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = info.readsFromThisMac || info.kind == .chatgpt || info.kind == .gemini
        panel.allowsMultipleSelection = false
        panel.message = "Choose the \(info.name) \(info.readsFromThisMac ? "folder or file" : "export file")."
        if let location = info.defaultLocation {
            panel.directoryURL = URL(fileURLWithPath: (location as NSString).expandingTildeInPath).deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            Task { await store.readImport(from: url) }
        }
    }

    // MARK: Preview

    private var previewView: some View {
        let preview = store.importSession.preview
        let info = store.importSession.kind.map { ImportSourceInfo.info(for: $0) }
        let count = preview?.toImport.count ?? 0
        return VStack(alignment: .leading, spacing: DSSpace.m) {
            DSCard {
                VStack(alignment: .leading, spacing: DSSpace.m) {
                    (Text("\(count.formatted()) prompts").foregroundColor(.dsAccent) + Text(dateRange(preview)))
                        .font(.dsStat)
                    Text(duplicateLine(preview))
                        .font(.dsBody)
                        .foregroundStyle(Color.dsTextSecondary)
                    if let info {
                        VStack(alignment: .leading, spacing: DSSpace.xs) {
                            Text("Details available in this source").font(.dsBody).foregroundStyle(Color.dsTextTertiary)
                            HStack(spacing: DSSpace.m) {
                                field("Prompt text", info.fields.contains(.text))
                                field("Date", info.fields.contains(.date))
                                field("Project", info.fields.contains(.project))
                                field("Spoken or typed", info.fields.contains(.spokenOrTyped))
                                field("Duration", info.fields.contains(.duration))
                            }
                        }
                    }
                    if let url = store.importSession.url {
                        Text((url.path as NSString).abbreviatingWithTildeInPath)
                            .font(.dsMono)
                            .foregroundStyle(Color.dsTextTertiary)
                    }
                }
            }
            if let sample = preview?.toImport.suffix(3), !sample.isEmpty {
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    Text("Latest prompts").font(.dsBody).foregroundStyle(Color.dsTextTertiary)
                    ForEach(Array(sample.reversed().enumerated()), id: \.offset) { _, prompt in
                        Text(prompt.text)
                            .font(.dsBody)
                            .foregroundStyle(Color.dsTextSecondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private func field(_ label: String, _ present: Bool) -> some View {
        HStack(spacing: DSSpace.xxs) {
            Image(systemName: present ? "checkmark" : "minus")
                .font(.dsIconSmall)
                .foregroundStyle(present ? Color.dsSuccess : Color.dsTextTertiary)
            Text(label).font(.dsBody).foregroundStyle(present ? Color.dsTextPrimary : Color.dsTextTertiary)
        }
    }

    private func dateRange(_ preview: ImportPreview?) -> String {
        guard let first = preview?.earliest, let last = preview?.latest else { return ", no dates." }
        let format = Date.FormatStyle.dateTime.month(.wide).year()
        let a = first.formatted(format), b = last.formatted(format)
        return a == b ? ", \(a)." : ", \(a) to \(b)."
    }

    private func duplicateLine(_ preview: ImportPreview?) -> String {
        guard let preview else { return "" }
        var parts: [String] = []
        parts.append(preview.alreadyInHistory > 0
            ? "\(preview.alreadyInHistory.formatted()) are already in History and will be skipped."
            : "None are in History yet.")
        if preview.previouslyDeleted > 0 {
            parts.append("Already deleted: \(preview.previouslyDeleted.formatted()). These will stay deleted.")
        }
        if preview.duplicatesInSource > 0 {
            parts.append("\(preview.duplicatesInSource.formatted()) repeats within the source are counted once.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Progress / result

    private func progress(_ text: String) -> some View {
        HStack(spacing: DSSpace.xs) {
            ProgressView().controlSize(.small)
            Text(text).font(.dsBody).foregroundStyle(Color.dsTextSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    private func doneView(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.m) {
            HStack(spacing: DSSpace.xs) {
                Image(systemName: "checkmark.circle.fill").font(.dsIcon).foregroundStyle(Color.dsSuccess)
                Text("Imported \(count.formatted()) prompts. Find them in History and Datasets.")
                    .font(.dsBody)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DSSpace.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCardSurface(.dsSuccessQuiet)

        }
    }

    private func failedView(_ message: String) -> some View {
        DSEmptyState(symbol: "exclamationmark.triangle", title: message)
    }
}
