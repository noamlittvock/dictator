import AppKit
import SwiftUI

/// An invitation to join this Mac's setup: the main Mac's Tailscale
/// address and pairing token in one string, so the other Mac needs a
/// single paste instead of two technical values.
struct SetupInvitation: Codable, Equatable {
    var version = 1
    var name: String
    var address: String
    var token: String

    static let prefix = "dictator-invite:"

    var encoded: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return Self.prefix + data.base64EncodedString()
    }

    static func decode(_ text: String) -> SetupInvitation? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix),
              let data = Data(base64Encoded: String(trimmed.dropFirst(prefix.count))),
              let invitation = try? JSONDecoder().decode(SetupInvitation.self, from: data),
              invitation.version == 1, !invitation.token.isEmpty,
              // Dictator's connection has no encryption of its own: it relies on Tailscale.
              TailscaleInterface.isTailscaleAddress(invitation.address) else { return nil }
        return invitation
    }
}

/// Settings › Your Macs › Add a Mac. While it's open, this Mac takes join
/// requests: the joining Mac finds it on the network (or by name), both
/// show the same code, and the user approves here.
struct AddMacSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings.shared
    @State private var viewModel = DictatorViewModel.shared
    @State private var copied = false
    /// Why the invitation couldn't be copied, in plain words.
    @State private var copyProblem: String?
    @State private var showOtherWays = false
    @State private var knownAtStart: Set<EdgeID> = []
    @State private var becameMain = false

    var body: some View {
        DSSheet(title: BrandVoice.addMac) {
            VStack(alignment: .leading, spacing: DSSpace.m) {
                if settings.coreRole == .edge {
                    joinThroughMain
                } else if let request = viewModel.pendingJoin {
                    confirm(request)
                } else if let joined = newlyJoined {
                    joinedView(joined)
                } else {
                    steps
                }
            }
        } leadingActions: {
            if settings.coreRole != .edge, viewModel.pendingJoin != nil {
                Button("No, Don’t Add It") { viewModel.answerJoin(approve: false) }
                    .buttonStyle(.dsQuiet)
            }
        } actions: {
            if settings.coreRole != .edge, viewModel.pendingJoin != nil {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            } else {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.dsPrimary)
            }
            if settings.coreRole != .edge, viewModel.pendingJoin != nil {
                Button("Yes, Add It") { viewModel.answerJoin(approve: true) }
                    .buttonStyle(.dsPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            knownAtStart = Set(viewModel.connectedEdges.map(\.id))
            if settings.coreRole != .edge {
                becameMain = settings.coreRole == .standalone
                viewModel.acceptNewMacs(true)
            }
        }
        .onDisappear {
            if settings.coreRole != .edge { viewModel.acceptNewMacs(false) }
        }
    }

    // MARK: On a connected Mac

    private var joinThroughMain: some View {
        let main = viewModel.setupSnapshot?.mainMacName ?? "your main Mac"
        return VStack(alignment: .leading, spacing: DSSpace.hair) {
            Text("New Macs join through \(main)")
                .font(.dsSection)
            Text("\(main) keeps the main copy of your history, so it’s the Mac that lets others in. On \(main), open Dictator › Settings › Your Macs and choose Add a Mac.")
                .font(.dsBody)
                .foregroundStyle(Color.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Waiting for a Mac

    @ViewBuilder
    private var steps: some View {
        if becameMain {
            SettingsNotice(tone: .neutral, text: Text("This Mac is now your main Mac: it keeps the main copy of your history, and the others sync with it."))
        }
        step(1, "Install Dictator on your other Mac and open it.")
        VStack(alignment: .leading, spacing: DSSpace.s) {
            step(2, "Make sure both Macs are signed in to Tailscale with the same account.")
            tailscaleStatus.padding(.leading, DSSpace.xl)
        }
        step(3, "On the other Mac, open Settings › Your Macs and choose Join Another Mac’s Setup. This Mac shows up there.")

        HStack(spacing: DSSpace.xs) {
            ProgressView().controlSize(.small)
            Text(viewModel.isAcceptingNewMacs ? "Waiting for your other Mac… (for the next 10 minutes)" : "Not taking new Macs right now.")
                .font(.dsSecondary)
                .foregroundStyle(Color.dsTextSecondary)
        }
        .padding(.leading, DSSpace.xl)

        DisclosureGroup("It doesn’t show up?", isExpanded: $showOtherWays) {
            VStack(alignment: .leading, spacing: DSSpace.s) {
                if let name = tailscaleName {
                    Text("On the other Mac, type this Mac’s Tailscale name instead: \(name)")
                        .font(.dsSecondary)
                        .foregroundStyle(Color.dsTextSecondary)
                        .textSelection(.enabled)
                }
                HStack(spacing: DSSpace.s) {
                    Button(copied ? "Copied" : "Copy an Invitation", action: copyInvitation)
                        .disabled(TailscaleInterface.currentAddress() == nil)
                    Text(TailscaleInterface.currentAddress() == nil
                         ? "Available once this Mac is signed in to Tailscale (step 2)."
                         : "Paste it on the other Mac under Join Another Mac’s Setup. Only paste it on your own Macs.")
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let copyProblem {
                    Label(copyProblem, systemImage: "exclamationmark.triangle")
                        .font(.dsCaption)
                        .foregroundStyle(Color.dsWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, DSSpace.xs)
        }
        .font(.dsSecondary)
    }

    @ViewBuilder
    private var tailscaleStatus: some View {
        if TailscaleInterface.currentAddress() == nil {
            HStack(spacing: DSSpace.s) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Color.dsWarning).font(.dsIcon)
                Text("Tailscale isn’t on here. It’s a free, private link between your own devices that lets your Macs reach each other from anywhere.")
                    .font(.dsSecondary)
                    .foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Get Tailscale") { NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!) }
            }
        } else {
            Label("Tailscale is on here.", systemImage: "checkmark.circle.fill")
                .font(.dsSecondary)
                .foregroundStyle(Color.dsSuccess)
        }
    }

    /// This Mac's Tailscale name, when macOS can look it up.
    private var tailscaleName: String? {
        guard let ip = TailscaleInterface.currentAddress() else { return nil }
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &sin.sin_addr) == 1 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard result == 0 else { return nil }
        let name = String(cString: host)
        return name.split(separator: ".").first.map(String.init)
    }

    // MARK: A Mac asks to join

    private func confirm(_ request: CoreServer.PairRequest) -> some View {
        VStack(spacing: DSSpace.m) {
            Text("\(request.name) wants to join")
                .font(.dsSection)
            Text("Does \(request.name) show this code?")
                .font(.dsBody)
                .foregroundStyle(Color.dsTextSecondary)
            Text(Self.spaced(request.code))
                .font(.dsStat.monospacedDigit())
                .tracking(4)
            Text("The code makes sure it’s your Mac joining, not another one on your network.")
                .font(.dsSecondary)
                .foregroundStyle(Color.dsTextTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, DSSpace.l)
    }

    private func joinedView(_ joined: BrokerEdgeInfo) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.s) {
            SettingsNotice(tone: .ok, text: Text("\(joined.name) joined your setup."))
            Text("It keeps its own copy of your history and syncs with this Mac.")
                .font(.dsBody)
                .foregroundStyle(Color.dsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if (joined.caps.machine?.memoryGB ?? 0) >= 16 {
                Text("\(joined.name) has enough memory to run AI models. Add one from its card in Your Macs.")
                    .font(.dsBody)
                    .foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func spaced(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }

    private var newlyJoined: BrokerEdgeInfo? {
        viewModel.connectedEdges.first { !knownAtStart.contains($0.id) && $0.id != viewModel.localEdgeId }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpace.s) {
            DSStepBadge(number: number)
            Text(text)
                .font(.dsBody)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Copies the invitation, or says why it can't instead of doing
    /// nothing.
    private func copyInvitation() {
        copied = false
        guard let address = TailscaleInterface.currentAddress() else {
            copyProblem = "This Mac isn’t connected to Tailscale, so the other Mac couldn’t reach it. Open Tailscale, sign in, then try again."
            return
        }
        let token: String
        do {
            token = try LocalSecret.sharedToken(fileName: "core-pairing.token")
        } catch {
            copyProblem = "Dictator couldn’t read this Mac’s invitation key, so nothing was copied. Quit and reopen Dictator, then try again."
            return
        }
        copyProblem = nil
        let name = settings.edgeDisplayName.isEmpty ? (Host.current().localizedName ?? "Main Mac") : settings.edgeDisplayName
        let invitation = SetupInvitation(name: name, address: address, token: token)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(invitation.encoded, forType: .string)
        copied = true
    }
}

/// Settings › Your Macs › Join Another Mac's Setup.
struct JoinSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings.shared
    @State private var viewModel = DictatorViewModel.shared
    @State private var browser = SetupBrowser()
    @State private var client = PairingClient()
    @State private var typedName = ""
    @State private var invitationText = ""
    @State private var showOtherWays = false
    @State private var joinedByInvitation = false
    @State private var invitationProblem: String?

    var body: some View {
        DSSheet(title: "Join another Mac’s setup", height: 420) {
            VStack(alignment: .leading, spacing: DSSpace.m) {
                content
            }
        } actions: {
            Button(isDone ? "Done" : "Cancel") {
                client.cancel()
                dismiss()
            }
            .buttonStyle(isDone ? .dsPrimary : .dsSecondary)
            .keyboardShortcut(.cancelAction)
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private var isDone: Bool {
        if joinedByInvitation { return true }
        if case .approved = client.state { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch client.state {
        case .idle, .failed:
            if case .failed(let message) = client.state {
                SettingsNotice(tone: .warning, text: Text(message))
            }
            if joinedByInvitation {
                connected
            } else {
                chooser
            }
        case .connecting(let name):
            HStack(spacing: DSSpace.xs) {
                ProgressView().controlSize(.small)
                Text("Asking \(name)…").font(.dsBody)
            }
        case .showingCode(let code, let mainName):
            VStack(spacing: DSSpace.m) {
                Text("Check the code on \(mainName)").font(.dsSection)
                Text(AddMacSheet.spaced(code))
                    .font(.dsStat.monospacedDigit())
                    .tracking(4)
                Text("If \(mainName) shows the same code, click Yes, Add It there.")
                    .font(.dsBody)
                    .foregroundStyle(Color.dsTextSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, DSSpace.l)
        case .approved:
            connected
        }
    }

    private var connected: some View {
        let status = viewModel.connectionSummary
        return SettingsNotice(tone: status.ok ? .ok : .neutral, text: Text(status.ok ? status.text : "Connecting… \(status.text)"))
    }

    @ViewBuilder
    private var chooser: some View {
        if TailscaleInterface.currentAddress() == nil {
            SettingsNotice(tone: .warning, text: Text("Tailscale isn’t on here. Your Macs use it to reach each other, including when you’re away from home.")) {
                Button("Get Tailscale") { NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!) }
            }
        }
        Text("On your main Mac, open Settings › Your Macs › Add a Mac. It shows up here.")
            .font(.dsBody)
            .foregroundStyle(Color.dsTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        VStack(spacing: 0) {
            if browser.found.isEmpty {
                HStack(spacing: DSSpace.xs) {
                    ProgressView().controlSize(.small)
                    Text("Looking on this network…").font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
                    Spacer()
                }
                .padding(DSSpace.m)
            }
            ForEach(Array(browser.found.enumerated()), id: \.element.id) { index, mac in
                if index > 0 { SettingsDivider() }
                SettingsRow(title: mac.name, detail: "On this network") {
                    Button("Join") { client.join(host: mac.tailscaleIP, displayName: mac.name) }
                }
            }
        }
        .dsCardSurface()

        DisclosureGroup("Don’t see it?", isExpanded: $showOtherWays) {
            VStack(alignment: .leading, spacing: DSSpace.s) {
                Text("If the Macs are on different networks, type the main Mac’s name as Tailscale shows it (click Tailscale in its menu bar).")
                    .font(.dsSecondary)
                    .foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DSSpace.xs) {
                    TextField("Its Tailscale name", text: $typedName, prompt: Text("e.g. mac-mini"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(joinTyped)
                    Button("Join", action: joinTyped)
                        .disabled(typedName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Or paste an invitation copied on the main Mac:")
                    .font(.dsSecondary)
                    .foregroundStyle(Color.dsTextSecondary)
                HStack(spacing: DSSpace.xs) {
                    TextField("Invitation", text: $invitationText, prompt: Text("dictator-invite:…"))
                        .textFieldStyle(.roundedBorder)
                    Button("Join") {
                        if let invitation = SetupInvitation.decode(invitationText) { joinWithInvitation(invitation) }
                    }
                    .disabled(SetupInvitation.decode(invitationText) == nil)
                }
                if !invitationText.isEmpty, SetupInvitation.decode(invitationText) == nil {
                    Text("That isn’t a Dictator invitation. Copy it again on the main Mac.")
                        .font(.dsSecondary)
                        .foregroundStyle(Color.dsWarning)
                } else if let invitationProblem {
                    Text(invitationProblem)
                        .font(.dsSecondary)
                        .foregroundStyle(Color.dsWarning)
                }
            }
            .padding(.top, DSSpace.xs)
        }
        .font(.dsSecondary)
    }

    private func joinTyped() {
        let name = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        client.join(host: name, displayName: name)
    }

    private func joinWithInvitation(_ invitation: SetupInvitation) {
        do {
            try PairingCredentialStore.save(token: invitation.token, forCore: invitation.address)
        } catch {
            invitationProblem = "This Mac couldn’t save the invitation. Check there’s disk space, then paste it again."
            return
        }
        invitationProblem = nil
        settings.coreAddress = invitation.address
        settings.coreRole = .edge
        viewModel.applyRole()
        joinedByInvitation = true
    }
}
