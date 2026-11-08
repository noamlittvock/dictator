import SwiftUI

// Small pictures of Dictator at work, drawn from the app's own shapes so they
// follow the theme and the chosen key. Each one plays once when it appears,
// replays on hover and rests on its last frame.

/// Plays a scene.
struct HelpSceneView: View {
    let scene: HelpScene
    var keys: HotkeyTriggers = .current
    /// Holds one frame (the snapshots use it).
    var frozenFrame: Int? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame = 0
    @State private var plays = 0

    private var shown: Int { frozenFrame ?? (reduceMotion ? scene.lastFrame : frame) }

    var body: some View {
        HelpSceneArt(scene: scene, keys: keys, frame: shown)
            .padding(DSSpace.s)
            .frame(maxWidth: .infinity, minHeight: DSLayout.helpScene, maxHeight: DSLayout.helpScene)
            .background(Color.dsSurfaceSunken, in: RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous))
            .clipped()
            .onHover { if $0 { plays += 1 } }
            .accessibilityElement(children: scene == .cleanup ? .contain : .ignore)
            .accessibilityLabel(scene.description)
            .task(id: plays) { await play() }
    }

    private func play() async {
        guard frozenFrame == nil, !reduceMotion, scene.lastFrame > 0 else { return }
        frame = 0
        for next in 1...scene.lastFrame {
            try? await Task.sleep(for: .seconds(0.75))
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.3)) { frame = next }
        }
    }
}

private struct HelpSceneArt: View {
    let scene: HelpScene
    let keys: HotkeyTriggers
    let frame: Int

    var body: some View {
        switch scene {
        case .dictate: dictate
        case .command: command
        case .routine: HelpWindowsArt(tidy: frame >= 2, pressed: frame == 1)
        case .cleanup: HelpCleanupArt()
        case .fixWord: fixWord
        case .recover: recover
        case .build: build
        case .actions: actions
        case .share: share
        case .monitors: monitors
        case .macs: macs
        case .privacy: privacy
        case .datasets: datasets
        case .keys: keyChoices
        }
    }

    private var dictate: some View {
        VStack(spacing: DSSpace.s) {
            HelpTextField(text: frame >= 3 ? "See you at three." : "")
            HStack(spacing: DSSpace.s) {
                HelpKeyCaps(combo: keys.dictation, down: frame == 1 || frame == 2)
                HelpWave(active: frame == 2).opacity(frame == 1 || frame == 2 ? 1 : 0.25)
            }
        }
    }

    private var command: some View {
        VStack(spacing: DSSpace.s) {
            HelpKeyCaps(combo: keys.commands, down: frame == 1 || frame == 2)
            HStack(spacing: DSSpace.s) {
                PhraseChip(segment: .opens("Open Safari"))
                    .opacity(frame >= 2 ? 1 : 0)
                    .scaleEffect(frame >= 2 ? 1 : 0.9)
                Image(systemName: "arrow.right").font(.dsIconSmall).foregroundStyle(Color.dsTextTertiary)
                    .opacity(frame >= 3 ? 1 : 0)
                HelpActionTile(symbol: "safari", title: "Safari")
                    .opacity(frame >= 3 ? 1 : 0)
                    .scaleEffect(frame >= 3 ? 1 : 0.8)
            }
        }
    }

    private var fixWord: some View {
        VStack(spacing: DSSpace.s) {
            HStack(spacing: DSSpace.xxs) {
                Text("Ask").foregroundStyle(Color.dsTextPrimary)
                Text(frame >= 2 ? "Claude" : "Clawed")
                    .foregroundStyle(frame >= 2 ? Color.dsSuccess : Color.dsTextPrimary)
                    .underline(frame == 1, color: Color.dsAccent)
                    .padding(.horizontal, DSSpace.xxs)
                    .background(frame >= 1 ? (frame >= 2 ? Color.dsSuccessQuiet : Color.dsAccentQuiet) : Color.clear,
                                in: RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous))
                Text("to review it").foregroundStyle(Color.dsTextPrimary)
            }
            .font(.dsBody)
            HStack(spacing: DSSpace.xxs) {
                Text("Clawed").strikethrough().foregroundStyle(Color.dsTextTertiary)
                Image(systemName: "arrow.right").foregroundStyle(Color.dsTextTertiary)
                Text("Claude").foregroundStyle(Color.dsTextPrimary)
                Image(systemName: "star.fill").foregroundStyle(Color.dsAccent)
            }
            .font(.dsCaption)
            .opacity(frame >= 2 ? 1 : 0)
        }
    }

    private var recover: some View {
        VStack(spacing: DSSpace.s) {
            HStack(spacing: DSSpace.xs) {
                Image(systemName: "waveform.badge.exclamationmark").foregroundStyle(Color.dsWarning)
                HelpWave(active: false)
                Image(systemName: "arrow.right").font(.dsIconSmall).foregroundStyle(Color.dsTextTertiary)
                HelpPill(title: "Turn into text", on: frame == 1)
            }
            HStack(spacing: DSSpace.xs) {
                Image(systemName: "doc.on.clipboard.fill").foregroundStyle(Color.dsSuccess)
                Text("See you at three.").font(.dsBody).foregroundStyle(Color.dsTextPrimary)
            }
            .opacity(frame >= 2 ? 1 : 0)
            .offset(y: frame >= 2 ? 0 : DSSpace.xxs)
        }
    }

    private var build: some View {
        VStack(spacing: DSSpace.s) {
            SpokenPhraseView(segments: [.opens("Code"), .init(text: "Atlas", role: .which, label: "project"),
                                        .init(text: "fix the login bug", role: .words, label: nil)], showsCaptions: false)
            HStack(spacing: DSSpace.xs) {
                HelpActionTile(symbol: "folder", title: "Open project").opacity(frame >= 1 ? 1 : 0.2)
                Image(systemName: "arrow.right").font(.dsIconSmall).foregroundStyle(Color.dsTextTertiary)
                HelpActionTile(symbol: "terminal", title: "Start agent").opacity(frame >= 2 ? 1 : 0.2)
            }
        }
    }

    private var actions: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DSSpace.xxs), count: 4), spacing: DSSpace.xs) {
            HelpActionTile(symbol: "app", title: "App")
            HelpActionTile(symbol: "globe", title: "Website")
            HelpActionTile(symbol: "rectangle.3.group", title: "Routine")
            HelpActionTile(symbol: "character.cursor.ibeam", title: "Type")
            HelpActionTile(symbol: "sparkles", title: "Agent")
            HelpActionTile(symbol: "square.2.layers.3d", title: "Shortcut")
            HelpActionTile(symbol: "terminal", title: "Terminal")
            HelpActionTile(symbol: "doc.badge.plus", title: "File")
        }
    }

    private var share: some View {
        HStack(spacing: DSSpace.s) {
            HelpMiniCard(title: "Standup", on: true)
            Image(systemName: "arrow.right").font(.dsIconSmall).foregroundStyle(Color.dsTextTertiary).opacity(frame >= 1 ? 1 : 0.2)
            Image(systemName: "doc.fill").font(.dsIconHero).foregroundStyle(Color.dsAccent).opacity(frame >= 1 ? 1 : 0.2)
            Image(systemName: "arrow.right").font(.dsIconSmall).foregroundStyle(Color.dsTextTertiary).opacity(frame >= 2 ? 1 : 0.2)
            HelpMiniCard(title: "Standup", on: false).opacity(frame >= 2 ? 1 : 0.2)
        }
    }

    private var monitors: some View {
        HStack(alignment: .bottom, spacing: DSSpace.xs) {
            HelpScreen(tiles: [(.dsDataSlate, "Safari", frame >= 1)])
            HelpScreen(tiles: [(.dsDataTeal, "Code", frame >= 2), (.dsDataPlum, "Notes", frame >= 2)])
        }
    }

    private var macs: some View {
        HStack(spacing: DSSpace.xs) {
            HelpMac(kind: .laptop, job: "Records", lit: frame >= 0)
            HelpMacLine(lit: frame >= 1)
            HelpMac(kind: .mini, job: "Keeps history", lit: frame >= 1)
            HelpMacLine(lit: frame >= 2)
            HelpMac(kind: .studio, job: "Runs models", lit: frame >= 2)
        }
    }

    private var privacy: some View {
        VStack(spacing: DSSpace.xs) {
            HelpPrivacyRow(symbol: "mic", title: "Dictation", on: true)
            HelpPrivacyRow(symbol: "keyboard", title: "Typing", on: false)
            Label("On your Macs", systemImage: "lock.fill")
                .font(.dsCaption)
                .foregroundStyle(Color.dsTextTertiary)
        }
    }

    private var datasets: some View {
        HStack(spacing: DSSpace.s) {
            VStack(spacing: DSSpace.xxs) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(frame >= 1 && index % 2 == 1 ? Color.dsTextTertiary.opacity(0.2) : Color.dsTextSecondary)
                        .frame(width: DSSpace.xxl + DSSpace.s, height: DSSpace.xxs + DSSpace.hair)
                }
            }
            Image(systemName: "line.3.horizontal.decrease.circle.fill").font(.dsIconLarge)
                .foregroundStyle(frame >= 1 ? Color.dsAccent : Color.dsTextTertiary)
            Image(systemName: "arrow.right").font(.dsIconSmall).foregroundStyle(Color.dsTextTertiary)
            VStack(spacing: DSSpace.xxs) {
                Image(systemName: "doc.text.fill").font(.dsIconHero).foregroundStyle(Color.dsAccent)
                Text("JSONL").font(.dsCaptionMedium).foregroundStyle(Color.dsTextPrimary)
            }
            .opacity(frame >= 2 ? 1 : 0.2)
        }
    }

    private var keyChoices: some View {
        VStack(alignment: .leading, spacing: DSSpace.s) {
            keyRow("Dictate", keys.dictation, down: frame == 1)
            keyRow("Commands", keys.commands, down: frame == 2)
        }
    }

    private func keyRow(_ title: String, _ combo: KeyCombo, down: Bool) -> some View {
        HStack(spacing: DSSpace.xs) {
            Text(title).font(.dsCaption).foregroundStyle(Color.dsTextSecondary).frame(width: DSSpace.xxl + DSSpace.s, alignment: .leading)
            HelpKeyCaps(combo: combo, down: down)
        }
    }
}

// MARK: - Pieces

/// The keys of a combination, side by side.
private struct HelpKeyCaps: View {
    let combo: KeyCombo
    let down: Bool

    var body: some View {
        HStack(spacing: DSSpace.xxs) {
            ForEach(Array(combo.keyCodes.enumerated()), id: \.offset) { index, code in
                if index > 0 { Text("+").font(.dsCaption).foregroundStyle(Color.dsTextTertiary) }
                HelpKeyCap(text: DictationKey(keyCode: code).symbolName, down: down)
            }
        }
    }
}

/// A key on the keyboard, pressed or not.
struct HelpKeyCap: View {
    let text: String
    var down = false

    var body: some View {
        Text(text)
            .font(.dsCaptionMedium)
            .foregroundStyle(down ? Color.dsAccent : Color.dsTextPrimary)
            .padding(.horizontal, DSSpace.xs)
            .padding(.vertical, DSSpace.xxs + DSSpace.hair)
            .background(down ? Color.dsAccentQStrong : Color.dsSurfaceControl,
                        in: RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
                .strokeBorder(down ? Color.dsAccent : Color.dsBorder, lineWidth: 1))
            .offset(y: down ? 1 : 0)
    }
}

/// Bars that move while someone is speaking.
private struct HelpWave: View {
    let active: Bool
    private let shape: [CGFloat] = [0.4, 0.8, 0.55, 1, 0.65, 0.9, 0.45]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !active)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: DSSpace.hair) {
                ForEach(shape.indices, id: \.self) { index in
                    let swing = active ? 0.65 + 0.35 * sin(time * 9 + Double(index) * 1.4) : 0.7
                    Capsule()
                        .fill(active ? Color.dsAccent : Color.dsTextTertiary)
                        .frame(width: DSSpace.hair + 1, height: DSSpace.l * shape[index] * swing)
                }
            }
            .frame(height: DSSpace.l)
        }
    }
}

private struct HelpTextField: View {
    let text: String

    var body: some View {
        HStack(spacing: DSSpace.hair) {
            Text(text.isEmpty ? " " : text).font(.dsBody).foregroundStyle(Color.dsTextPrimary)
            Rectangle().fill(Color.dsAccent).frame(width: 1, height: DSSpace.m)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DSSpace.xs)
        .padding(.vertical, DSSpace.xxs + DSSpace.hair)
        .frame(maxWidth: DSLayout.helpSceneContent)
        .background(Color.dsSurfaceCard, in: RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous).strokeBorder(Color.dsBorderSubtle))
    }
}

private struct HelpActionTile: View {
    let symbol: String
    let title: String

    var body: some View {
        VStack(spacing: DSSpace.xxs) {
            Image(systemName: symbol).font(.dsIconLarge).foregroundStyle(Color.dsAccent)
            Text(title).font(.dsCaption).foregroundStyle(Color.dsTextSecondary).lineLimit(1)
        }
    }
}

private struct HelpPill: View {
    let title: String
    var on = false

    var body: some View {
        Text(title)
            .font(.dsCaptionMedium)
            .foregroundStyle(on ? Color.dsOnAccent : Color.dsTextPrimary)
            .padding(.horizontal, DSSpace.xs)
            .padding(.vertical, DSSpace.xxs)
            .background(on ? Color.dsAccent : Color.dsSurfaceControl, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? Color.clear : Color.dsBorder))
    }
}

private struct HelpSwitch: View {
    let on: Bool

    var body: some View {
        Capsule()
            .fill(on ? Color.dsAccent : Color.dsSurfaceControl)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(on ? Color.dsOnAccent : Color.dsTextSecondary).padding(DSSpace.hair)
            }
            .overlay(Capsule().strokeBorder(Color.dsBorder))
            .frame(width: DSSpace.l, height: DSSpace.m - DSSpace.hair)
    }
}

private struct HelpMiniCard: View {
    let title: String
    let on: Bool

    var body: some View {
        VStack(spacing: DSSpace.xxs) {
            Text(title).font(.dsCaptionMedium).foregroundStyle(Color.dsTextPrimary)
            HelpSwitch(on: on)
        }
        .padding(DSSpace.xs)
        .dsCardSurface()
    }
}

private struct HelpPrivacyRow: View {
    let symbol: String
    let title: String
    let on: Bool

    var body: some View {
        HStack(spacing: DSSpace.xs) {
            Image(systemName: symbol).font(.dsIcon).foregroundStyle(Color.dsTextSecondary).frame(width: DSSpace.m)
            Text(title).font(.dsBody).foregroundStyle(Color.dsTextPrimary)
            Spacer(minLength: DSSpace.s)
            HelpSwitch(on: on)
        }
        .frame(maxWidth: DSLayout.helpSceneContent / 1.4)
    }
}

/// A monitor with apps on it.
private struct HelpScreen: View {
    let tiles: [(color: Color, title: String, placed: Bool)]

    var body: some View {
        VStack(spacing: DSSpace.hair) {
            HStack(spacing: DSSpace.xxs) {
                ForEach(tiles.indices, id: \.self) { index in
                    let tile = tiles[index]
                    RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
                        .fill(tile.color.opacity(tile.placed ? 0.3 : 0.06))
                        .overlay(Text(tile.title).font(.dsCaption).foregroundStyle(tile.color).opacity(tile.placed ? 1 : 0))
                }
            }
            .padding(DSSpace.xxs)
            .frame(width: DSSpace.xxl * 2.3, height: DSSpace.xxl * 1.4)
            .background(Color.dsSurfaceCard, in: RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous).strokeBorder(Color.dsBorder))
            Rectangle().fill(Color.dsBorder).frame(width: DSSpace.s, height: DSSpace.xxs)
        }
    }
}

private struct HelpMac: View {
    let kind: MachineKind
    let job: String
    let lit: Bool

    var body: some View {
        VStack(spacing: DSSpace.hair) {
            MacIllustration(kind: kind, stroke: lit ? Color.dsAccent : Color.dsTextTertiary)
                .frame(width: DSSpace.xxl + DSSpace.xxs, height: DSSpace.xxl)
            Text(job).font(.dsCaption).foregroundStyle(lit ? Color.dsTextPrimary : Color.dsTextTertiary).lineLimit(1)
        }
    }
}

/// The line between two Macs.
private struct HelpMacLine: View {
    let lit: Bool

    var body: some View {
        Capsule()
            .fill(lit ? Color.dsAccent : Color.dsBorder)
            .frame(width: DSSpace.s, height: DSSpace.hair)
            .padding(.bottom, DSSpace.m)
    }
}

/// Scattered windows moving into a layout.
private struct HelpWindowsArt: View {
    let tidy: Bool
    let pressed: Bool

    private struct Window {
        let color: Color
        let scattered: CGRect
        let placed: CGRect
    }

    private let windows = [
        Window(color: .dsDataSlate, scattered: CGRect(x: 0.40, y: 0.32, width: 0.42, height: 0.50), placed: CGRect(x: 0.02, y: 0.04, width: 0.47, height: 0.92)),
        Window(color: .dsDataTeal, scattered: CGRect(x: 0.08, y: 0.10, width: 0.44, height: 0.56), placed: CGRect(x: 0.51, y: 0.04, width: 0.47, height: 0.44)),
        Window(color: .dsDataPlum, scattered: CGRect(x: 0.30, y: 0.54, width: 0.34, height: 0.40), placed: CGRect(x: 0.51, y: 0.52, width: 0.47, height: 0.44)),
    ]

    var body: some View {
        HStack(spacing: DSSpace.s) {
            GeometryReader { box in
                ForEach(windows.indices, id: \.self) { index in
                    let window = windows[index]
                    let rect = tidy ? window.placed : window.scattered
                    RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
                        .fill(window.color.opacity(0.28))
                        .overlay(RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous).strokeBorder(window.color, lineWidth: 1))
                        .frame(width: rect.width * box.size.width, height: rect.height * box.size.height)
                        .position(x: rect.midX * box.size.width, y: rect.midY * box.size.height)
                }
            }
            .frame(width: DSSpace.xxl * 3, height: DSSpace.xxl * 2)
            .background(Color.dsSurfaceCard, in: RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous).strokeBorder(Color.dsBorder))
            HelpPill(title: "Run", on: pressed)
        }
    }
}

/// Try each clean-up level on the same sentence.
private struct HelpCleanupArt: View {
    @State private var level: RefineLevel = .medium

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            HStack(spacing: DSSpace.xxs) {
                pill("Skip", .exact)
                pill("Clean up", .medium)
                pill("Polish", .polished)
            }
            Text(DictationSettingsPage.example(level))
                .font(.dsBody)
                .foregroundStyle(Color.dsTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .id(level)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pill(_ title: String, _ value: RefineLevel) -> some View {
        Button { level = value } label: { HelpPill(title: title, on: level == value) }
            .buttonStyle(.plain)
            .accessibilityAddTraits(level == value ? .isSelected : [])
    }
}
