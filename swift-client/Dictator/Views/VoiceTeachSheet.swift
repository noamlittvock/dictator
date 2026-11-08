import SwiftUI

/// "Teach Dictator how you say it": four takes, each turned into words the
/// same way a real dictation is, then the spellings worth keeping.
struct VoiceTeachSheet: View {
    let title: String
    let phrase: VoiceTeachPhrase
    let isTrigger: Bool
    let target: VoiceTeachTarget
    /// Called with the spellings to add.
    let onSave: ([String]) -> Void

    @State private var session = VoiceTeachSession()
    @State private var showResults = false
    /// Which words of a take are the name, when its fixed words weren't heard right.
    @State private var selection: [Int: Set<Int>] = [:]
    @State private var unchecked: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    // MARK: Derived

    private func heard(_ index: Int) -> VoiceTeachHeard {
        isTrigger ? VoiceTeach.heardForTrigger(session.transcripts[index]) : VoiceTeach.heardForEntry(session.transcripts[index], phrase: phrase)
    }

    private var aliases: [String] {
        session.transcripts.indices.compactMap { index in
            switch heard(index) {
            case .alias(let alias): return alias
            case .chooseWords(let words):
                let alias = VoiceTeach.alias(from: words, selected: selection[index] ?? [])
                return alias.isEmpty ? nil : alias
            case .nothing: return nil
            }
        }
    }

    private var candidates: [(alias: String, status: VoiceAliasStatus)] {
        VoiceTeach.candidates(from: aliases, target: target)
    }

    private var checkedAliases: [String] {
        candidates.filter { $0.status == .fresh && !unchecked.contains(VoiceLaunchText.key($0.alias)) }.map(\.alias)
    }

    // MARK: Body

    var body: some View {
        DSSheet(title: title) {
            VStack(alignment: .leading, spacing: DSSpace.m) {
                if showResults { results } else { recording }
                if let message = session.message {
                    Text(message).font(.dsSecondary).foregroundStyle(Color.dsWarning).fixedSize(horizontal: false, vertical: true)
                }
            }
        } leadingActions: {
            if showResults {
                Button("Start over") { session.reset(); showResults = false; selection = [:]; unchecked = [] }
                    .buttonStyle(.dsLink)
            }
        } actions: {
            Button("Cancel") { session.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            if showResults {
                Button("Save") { onSave(checkedAliases); dismiss() }
                    .buttonStyle(.dsPrimary)
                    .keyboardShortcut(.defaultAction).disabled(checkedAliases.isEmpty)
            } else {
                Button(action: recordTapped) {
                    Label(buttonTitle, systemImage: session.phase == .recording ? "stop.circle.fill" : "mic.fill")
                }
                .buttonStyle(.dsPrimary)
                .disabled(session.phase == .transcribing)
            }
        }
        .onDisappear { session.cancel() }
    }

    // MARK: Recording

    private var recording: some View {
        VStack(alignment: .leading, spacing: DSSpace.s) {
            Text("Say this \(VoiceTeach.takeCount) times, the way you normally would:")
                .font(.dsBody).foregroundStyle(Color.dsTextSecondary)
            Text("“\(phrase.text)”").font(.dsStat).foregroundStyle(Color.dsTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Take \(min(session.transcripts.count + 1, VoiceTeach.takeCount)) of \(VoiceTeach.takeCount)")
                .font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
            if session.phase == .recording {
                ProgressView(value: Double(min(max(session.level * 4, 0), 1))).frame(width: 220)
                TakeStopCountdown(session: session)
            }
            ForEach(Array(session.transcripts.enumerated()), id: \.offset) { index, text in
                HStack(spacing: DSSpace.xs) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.dsSuccess)
                    Text(text.isEmpty ? "Take \(index + 1): nothing heard" : "Take \(index + 1): heard “\(text)”")
                        .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                }
            }
            Text("The microphone is only on while you are recording a take here. The recordings aren’t kept.")
                .font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
        }
    }

    private var buttonTitle: String {
        switch session.phase {
        case .ready: session.transcripts.isEmpty ? "Record" : "Record next take"
        case .recording: "Listening… click to stop"
        case .transcribing: "Working it out…"
        }
    }

    private func recordTapped() {
        if session.phase == .recording { session.stopNow(); return }
        Task {
            await session.record()
            if session.isComplete { showResults = true }
        }
    }

    // MARK: Results

    private var results: some View {
        VStack(alignment: .leading, spacing: DSSpace.m) {
            Text("What Dictator heard").font(.dsSection).foregroundStyle(Color.dsTextPrimary)
            ForEach(Array(session.transcripts.enumerated()), id: \.offset) { index, text in
                takeRow(index, text)
            }
            Divider()
            Text(isTrigger ? "Other ways to hear it" : "Other ways to hear “\(phrase.text.split(separator: " ").last.map(String.init) ?? phrase.text)”")
                .font(.dsSection).foregroundStyle(Color.dsTextPrimary)
            let list = candidates.filter { $0.status != .sameAsName }
            if list.isEmpty {
                DSEmptyState(title: "There are no new spellings to add yet.")
            }
            ForEach(list, id: \.alias) { candidate in
                candidateRow(candidate.alias, candidate.status)
            }
        }
    }

    @ViewBuilder private func takeRow(_ index: Int, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xxs) {
            Text(text.isEmpty ? "Take \(index + 1): nothing heard" : "Take \(index + 1): “\(text)”")
                .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
            if case .chooseWords(let words) = heard(index) {
                Text("Dictator didn’t hear the first words as expected. Click the words that are the name.")
                    .font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
                FlowRow(spacing: DSSpace.xs) {
                    ForEach(Array(words.enumerated()), id: \.offset) { position, word in
                        let on = selection[index]?.contains(position) ?? false
                        Button {
                            var picked = selection[index] ?? []
                            if on { picked.remove(position) } else { picked.insert(position) }
                            selection[index] = picked
                        } label: {
                            Text(word).font(.dsSecondary)
                                .padding(.horizontal, DSSpace.xs).padding(.vertical, DSSpace.xxs)
                                .background(on ? Color.dsAccentQStrong : Color.dsSurfaceControl, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
        }
    }

    @ViewBuilder private func candidateRow(_ alias: String, _ status: VoiceAliasStatus) -> some View {
        let key = VoiceLaunchText.key(alias)
        switch status {
        case .fresh:
            Toggle(isOn: Binding(get: { !unchecked.contains(key) },
                                 set: { if $0 { unchecked.remove(key) } else { unchecked.insert(key) } })) {
                Text("“\(alias)”").font(.dsBody)
            }
        case .conflict(let problem):
            VStack(alignment: .leading, spacing: DSSpace.hair) {
                Text("“\(alias)”").font(.dsBody).foregroundStyle(Color.dsTextTertiary)
                Text(problem.message).font(.dsCaption).foregroundStyle(Color.dsWarning).fixedSize(horizontal: false, vertical: true)
            }
        case .sameAsName:
            EmptyView()
        }
    }
}

/// Under the level meter while a take records: "Stopping…" with a bar that
/// fills as the quiet goes on (it empties again when you speak), and how
/// many seconds are left before the take ends whatever happens.
struct TakeStopCountdown: View {
    let session: VoiceTeachSession

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xxs) {
            if let progress = session.silenceProgress {
                HStack(spacing: DSSpace.xs) {
                    Text("Stopping…").font(.dsCaptionMedium).foregroundStyle(Color.dsTextSecondary)
                    ProgressView(value: progress).frame(width: 120)
                }
            } else {
                Text("It stops by itself when you go quiet.")
                    .font(.dsCaption).foregroundStyle(Color.dsTextTertiary)
            }
            Text("\(session.secondsLeft) s left")
                .font(.dsCaption).monospacedDigit().foregroundStyle(Color.dsTextTertiary)
        }
    }
}
