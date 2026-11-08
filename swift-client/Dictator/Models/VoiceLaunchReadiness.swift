import Foundation

enum VoiceLaunchReadiness {
    static let workspaceRunBudget: TimeInterval = 60

    static func terminalBundle(for app: HostApp, appInstalled: (String) -> Bool) -> String? {
        guard app.kind == .terminal, app.runsScripts else { return nil }
        return app.bundleIDs.first(where: appInstalled)
    }

    static func problems(for plan: VoiceLaunchPlan, services: VoiceLaunchServices,
                         appInstalled: (String) -> Bool, folderExists: (String) -> Bool) -> [String] {
        let mac = services.macName().isEmpty ? "this Mac" : services.macName()
        var problems: [String] = []
        let catalog = ToolCatalog.shared
        for step in plan.steps {
            // Deferred template fields are intentionally blank until an
            // earlier Shortcut returns its answer. Readiness cannot validate
            // those values yet.
            switch step.kind {
            case .openApp:
                if step.deferred == nil {
                    let id = step.bundleId ?? ""
                    if !id.isEmpty && !id.contains("://") && !id.lowercased().hasPrefix("mailto:") && !appInstalled(id) {
                        let name = VoiceAppNames.name(for: id) ?? catalog.hostApps.first(where: { $0.bundleIDs.contains(id) })?.name
                            ?? id.split(separator: ".").last.map(String.init) ?? id
                        problems.append("\(name) isn’t on \(mac). Install it here or run this command from a Mac that has it.")
                    }
                }
            case .runInTerminal:
                // A folder that waits on an earlier Shortcut's answer can't be
                // checked yet; one built only from the spoken words can.
                var known: VoiceStep? = step
                if let template = step.deferred?.templates["folder"] {
                    known = VoiceStepRenderer.usesAnswer(template) ? nil : VoiceStepRenderer.resolve(step, answers: [:], mac: mac)
                }
                if let known {
                    let raw = (known.folder ?? "") as NSString
                    let folder = raw.expandingTildeInPath
                    if folder.isEmpty || !folderExists(folder) { problems.append("The folder isn’t on \(mac). Choose a folder that exists here.") }
                }
                // A background command opens no terminal, so none has to be installed.
                if step.background == true { break }
                let selected = catalog.hostApps.first { $0.id == AppSettings.shared.voiceCommandTerminalApp && $0.kind == .terminal }
                if let selected {
                    if selected.runsScripts && terminalBundle(for: selected, appInstalled: appInstalled) == nil {
                        problems.append("\(selected.name) isn’t on \(mac). Install it here or choose another terminal.")
                    } else if !selected.runsScripts {
                        problems.append("\(selected.name) can’t start a coding assistant for Dictator on \(mac). Choose Terminal or iTerm.")
                    }
                } else {
                    problems.append("The chosen terminal isn’t available on \(mac). Choose a terminal installed here.")
                }
            default: break
            }
        }
        if plan.steps.contains(where: { [.waitForTextField, .typeText, .pressKey, .runWorkspace].contains($0.kind) }) && !services.isAccessibilityTrusted() {
            problems.append("Dictator needs Accessibility access on \(mac). Turn it on in System Settings › Privacy & Security › Accessibility.")
        }
        return problems
    }
}
