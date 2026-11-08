import SwiftUI

/// "What do you say?": the opening word or words, then pieces you add one at
/// a time, with a live preview of how it sounds.
struct VoiceSentenceBuilderView: View {
    @Binding var builder: SentenceBuilder
    @Binding var alsoListenFor: [String]
    let config: VoiceLaunchConfig
    /// Makes sure a list exists (People, Projects) before a piece uses it.
    let onEnsureList: (String, [String]) -> Void
    let onTeach: () -> Void

    private enum Adding { case words, marker }
    @State private var adding: Adding?
    @State private var newName = ""

    private var otherLists: [VoiceList] {
        config.lists.filter { list in
            !SpokenPhrase.isPeople(list.name)
                && VoiceLaunchText.normalizedWords(list.name) != VoiceLaunchText.normalizedWords(VoiceCards.projectsList)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text(VoiceBuildCopy.whatDoYouSay).font(.dsSection).foregroundStyle(Color.dsTextPrimary)
            Text(VoiceBuildCopy.whatDoYouSayHelp).font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
            HStack(spacing: DSSpace.xs) {
                SpokenPhraseView(segments: [.opens(SentenceBuilder.collapse(builder.opening).isEmpty ? "…" : SentenceBuilder.collapse(builder.opening))])
                    .frame(width: 130, alignment: .leading)
                TextField(VoiceBuildCopy.openingPlaceholder, text: $builder.opening).textFieldStyle(.roundedBorder)
            }
            ForEach(Array(builder.pieces.enumerated()), id: \.element.id) { index, piece in
                pieceRow(piece, index: index)
            }
            addButtons
            addForm
            if let problem = builder.problem(config: config) {
                Text(problem).font(.dsSecondary).foregroundStyle(Color.dsWarning).fixedSize(horizontal: false, vertical: true)
            }
            preview
            if !builder.opening.trimmingCharacters(in: .whitespaces).isEmpty { alsoListen }
        }
    }

    // MARK: Pieces

    private func pieceRow(_ piece: SentencePiece, index: Int) -> some View {
        HStack(spacing: DSSpace.xs) {
            pill(piece).frame(width: 130, alignment: .leading)
            if piece.isMarker {
                TextField(VoiceBuildCopy.markerPlaceholder, text: Binding(
                    get: { if case .marker(let words) = piece.kind { words } else { "" } },
                    set: { new in if let i = builder.pieces.firstIndex(where: { $0.id == piece.id }) { builder.pieces[i].kind = .marker(new) } }))
                    .textFieldStyle(.roundedBorder)
            } else {
                Spacer(minLength: 0)
            }
            HStack(spacing: DSSpace.xxs) {
                Text(VoiceBuildCopy.canBeSkipped).font(.dsSecondary)
                Toggle(VoiceBuildCopy.canBeSkipped, isOn: Binding(
                    get: { piece.canSkip },
                    set: { on in if let i = builder.pieces.firstIndex(where: { $0.id == piece.id }) { builder.pieces[i].canSkip = on } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            .fixedSize()
            Button { builder.move(piece.id, by: -1) } label: { Image(systemName: "arrow.left").font(.dsIcon) }.buttonStyle(.dsQuiet)
                .disabled(index == 0).accessibilityLabel(VoiceBuildCopy.moveLeft)
            Button { builder.move(piece.id, by: 1) } label: { Image(systemName: "arrow.right").font(.dsIcon) }.buttonStyle(.dsQuiet)
                .disabled(index == builder.pieces.count - 1).accessibilityLabel(VoiceBuildCopy.moveRight)
            Button { builder.remove(piece.id) } label: { Image(systemName: "trash").font(.dsIcon) }.buttonStyle(.dsQuiet)
                .accessibilityLabel(VoiceBuildCopy.removePiece)
        }
    }

    @ViewBuilder private func pill(_ piece: SentencePiece) -> some View {
        switch piece.kind {
        case .list(_, let list):
            let text = SpokenPhrase.isPeople(list) ? "someone" : (VoiceLaunchText.normalizedWords(list) == VoiceLaunchText.normalizedWords(VoiceCards.projectsList) ? "a project" : list)
            SpokenPhraseView(segments: [SpokenPhrase.listSegment(text, listName: list)])
        case .words(let slot):
            SpokenPhraseView(segments: [SpokenPhrase.wordsSegment(slot.replacingOccurrences(of: "_", with: " "), slot: slot)])
        case .marker(let words):
            Text(SentenceBuilder.collapse(words).isEmpty ? "…" : SentenceBuilder.collapse(words))
                .font(.dsSecondary).foregroundStyle(Color.dsTextPrimary)
                .padding(.horizontal, DSSpace.xs).padding(.vertical, DSSpace.hair)
                .overlay(Capsule().strokeBorder(Color.dsBorderSubtle, lineWidth: 1))
        }
    }

    // MARK: Adding

    private var addButtons: some View {
        FlowRow(spacing: DSSpace.xs) {
            Button(VoiceBuildCopy.addSomeone) {
                ensure(VoiceCards.peopleList, fields: ["phone", "email"])
                builder.addList(config.list(named: VoiceCards.peopleList)?.name ?? VoiceCards.peopleList)
            }
            Button(VoiceBuildCopy.addProject) {
                ensure(VoiceCards.projectsList, fields: ["folder"])
                builder.addList(config.list(named: VoiceCards.projectsList)?.name ?? VoiceCards.projectsList)
            }
            if !otherLists.isEmpty {
                Menu(VoiceBuildCopy.addOtherList) {
                    ForEach(otherLists) { list in Button("Something from \(list.name)") { builder.addList(list.name) } }
                }.fixedSize()
            }
            Button(VoiceBuildCopy.addWords) { adding = .words; newName = VoiceBuildCopy.wordsNameDefault }
            Button(VoiceBuildCopy.addMarker) { adding = .marker; newName = "" }
        }
        .controlSize(.small)
    }

    @ViewBuilder private var addForm: some View {
        if let adding {
            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                Text(adding == .words ? VoiceBuildCopy.wordsNamePrompt : VoiceBuildCopy.markerPrompt)
                    .font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
                HStack {
                    TextField(adding == .words ? VoiceBuildCopy.wordsNameDefault : VoiceBuildCopy.markerPlaceholder, text: $newName)
                        .textFieldStyle(.roundedBorder).frame(width: 200).onSubmit { commitNew(adding) }
                    Button(VoiceBuildCopy.addButton) { commitNew(adding) }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button(VoiceBuildCopy.cancelButton) { self.adding = nil }
                }
            }
        }
    }

    private func commitNew(_ kind: Adding) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if kind == .words { builder.addWords(named: name) } else { builder.addMarker(name) }
        adding = nil
    }

    private func ensure(_ list: String, fields: [String]) {
        if config.list(named: list) == nil { onEnsureList(list, fields) }
    }

    // MARK: Preview and other ways of hearing it

    @ViewBuilder private var preview: some View {
        let pattern = builder.pattern
        if builder.problem(config: config) == nil {
            DSCard { VStack(alignment: .leading, spacing: DSSpace.xxs) {
                Text(VoiceBuildCopy.howItSounds).font(.dsSection).foregroundStyle(Color.dsTextSecondary)
                SpokenPhraseView(segments: SentenceBuilder.exampleSegments(pattern: pattern, config: config))
                Text(VoiceBuildCopy.examplePrefix + SentenceBuilder.exampleSentence(pattern: pattern, config: config))
                    .font(.dsSecondary).foregroundStyle(Color.dsTextTertiary).textSelection(.enabled)
            } }
        }
    }

    private var alsoListen: some View {
        let words = SentenceBuilder.collapse(builder.opening)
        return VStack(alignment: .leading, spacing: DSSpace.xxs) {
            Text(VoiceBuildCopy.alsoListenFor).font(.dsSection).foregroundStyle(Color.dsTextSecondary)
            HStack(spacing: DSSpace.xs) {
                TextField(VoiceBuildCopy.alsoListenPlaceholder, text: Binding(
                    get: { alsoListenFor.joined(separator: ", ") },
                    set: { alsoListenFor = VoiceListEntry.names(from: $0) }))
                Button(VoiceBuildCopy.teach, action: onTeach).help(VoiceBuildCopy.teachHelp)
            }
            Text(VoiceBuildCopy.teachHelpFor(words)).font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
