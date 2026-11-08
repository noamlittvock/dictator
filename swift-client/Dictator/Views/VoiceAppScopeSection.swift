import AppKit
import SwiftUI

struct VoiceAppScopeSection: View {
    @Binding var apps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text("Only in these apps").font(.dsSection).foregroundStyle(Color.dsTextPrimary)
            Text("Leave empty to use this command everywhere.").font(.dsSecondary).foregroundStyle(Color.dsTextTertiary)
            ForEach(Array(apps.enumerated()), id: \.offset) { index, id in
                HStack {
                    Text(VoiceAppPicker.name(id)).font(.dsSecondary)
                    Spacer()
                    Button {
                        apps.remove(at: index)
                    } label: { Image(systemName: "minus.circle").font(.dsIcon) }.buttonStyle(.dsQuiet)
                        .accessibilityLabel("Remove \(VoiceAppPicker.name(id))")
                }
            }
            Button("Choose apps…") {
                for id in VoiceAppPicker.choose(multiple: true) where !apps.contains(id) {
                    if apps.count < VoiceCommand.maxApps { apps.append(id) }
                }
            }
            .disabled(apps.count >= VoiceCommand.maxApps)
        }
    }
}

/// The same native application picker for command actions and app limits.
enum VoiceAppPicker {
    static func choose(multiple: Bool = false) -> [String] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = multiple
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
    }

    static func name(_ bundleID: String) -> String {
        VoiceAppNames.name(for: bundleID) ?? bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    static func scopeNote(_ apps: [String]) -> String? {
        guard let first = apps.first else { return nil }
        if apps.count == 1 { return "Only in \(name(first))" }
        if apps.count == 2 { return "Only in \(name(first)) and \(name(apps[1]))" }
        return "Only in \(name(first)) and \(apps.count - 1) more apps"
    }
}
