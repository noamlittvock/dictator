import Foundation
import Network
import Observation

/// The main Mac announces itself on the local network while Add a Mac is
/// open, so a Mac that wants to join can list it instead of asking for an
/// address. The announcement carries only a name and the Tailscale address
/// the join goes to; nothing is accepted on the announced port.
final class SetupAdvertiser {
    static let serviceType = "_dictator-setup._tcp"
    private var listener: NWListener?

    func start(name: String, tailscaleIP: String) {
        stop()
        guard let listener = try? NWListener(using: .tcp) else { return }
        var txt = NWTXTRecord()
        txt["ts"] = tailscaleIP
        txt["name"] = String(name.prefix(60))
        listener.service = NWListener.Service(name: String(name.prefix(60)), type: Self.serviceType, txtRecord: txt)
        listener.newConnectionHandler = { $0.cancel() }
        listener.stateUpdateHandler = { _ in }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// Lists main Macs announcing themselves on this network (`SetupAdvertiser`).
@MainActor
@Observable
final class SetupBrowser {
    struct Found: Identifiable, Equatable {
        let name: String
        let tailscaleIP: String
        var id: String { tailscaleIP }
    }

    private(set) var found: [Found] = []
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        stop()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: SetupAdvertiser.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Found? in
                guard case .bonjour(let txt) = result.metadata,
                      let ip = txt["ts"], TailscaleInterface.isTailscaleAddress(ip) else { return nil }
                return Found(name: txt["name"] ?? "A Mac", tailscaleIP: ip)
            }
            Task { @MainActor in self?.found = found.sorted { $0.name < $1.name } }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        found = []
    }
}

/// The joining side of Add a Mac: asks the main Mac to join, shows the code
/// it sends back, and on approval saves the pairing token and connects.
@MainActor
@Observable
final class PairingClient {
    enum State: Equatable {
        case idle
        case connecting(String)
        case showingCode(code: String, mainName: String)
        case approved(mainName: String)
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var address = ""
    /// Bumped by every join and cancel, so name lookup that finishes after
    /// the user has moved on can't start a connection nobody asked for.
    @ObservationIgnored private var attempt = 0

    /// `host` is a Tailscale address, a `*.ts.net` name, or a short
    /// Tailscale name ("studio"); it must resolve into Tailscale's range.
    func join(host: String, displayName: String) {
        cancel()
        state = .connecting(displayName)
        let current = attempt
        Task {
            let resolved = await Self.tailscaleAddress(for: host)
            guard current == attempt else { return }
            guard let ip = resolved else {
                state = .failed("Couldn’t find “\(host)” on your Tailscale network. Check the name in the Tailscale menu on that Mac.")
                return
            }
            address = ip
            connect(to: ip)
        }
    }

    func cancel() {
        attempt += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session = nil
        if case .approved = state { return }
        state = .idle
    }

    private func connect(to ip: String) {
        guard let url = URL(string: "ws://\(ip):\(EdgeProtocol.corePort)") else { return }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.task = task
        task.resume()
        let runtime = DictatorViewModel.shared
        var caps = EdgeCapabilities(hasMic: true, inputDeviceUID: "", accessibility: true, inputMonitoring: true, hotkeyMode: "")
        caps.machine = MachineProfile.current
        let name = AppSettings.shared.edgeDisplayName.isEmpty ? (Host.current().localizedName ?? "Mac") : AppSettings.shared.edgeDisplayName
        guard let data = try? EdgeProtocolCodec.encode(.pairRequest(edgeId: runtime.localEdgeId, name: name, caps: caps)),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            if error != nil {
                Task { @MainActor in self?.fail("Couldn’t reach that Mac. Is Dictator open there, and is Tailscale on for both Macs?") }
            }
        }
        receive()
    }

    private func receive() {
        guard let listening = task else { return }
        listening.receive { [weak self] result in
            Task { @MainActor in
                // A message already on its way when the user cancelled is not
                // an approval they are still waiting for.
                guard let self, listening === self.task else { return }
                switch result {
                case .failure:
                    if case .approved = self.state { return }
                    if case .failed = self.state { return }
                    self.fail("The main Mac stopped answering before this Mac finished joining. Try again.")
                case .success(let message):
                    var data: Data?
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: data = nil
                    }
                    guard let data, let decoded = try? EdgeProtocolCodec.decodeCoreMessage(data) else {
                        self.receive()
                        return
                    }
                    self.handle(decoded)
                }
            }
        }
    }

    private func handle(_ message: CoreMessage) {
        switch message {
        case .pairCode(let code, let coreName):
            state = .showingCode(code: code, mainName: coreName.isEmpty ? "your main Mac" : coreName)
            receive()
        case .pairApproved(let token):
            let mainName: String
            if case .showingCode(_, let name) = state { mainName = name } else { mainName = "your main Mac" }
            do {
                try PairingCredentialStore.save(token: token, forCore: address)
            } catch {
                fail("This Mac couldn’t save its connection to \(mainName). Check there’s disk space, then try again.")
                return
            }
            let settings = AppSettings.shared
            settings.coreAddress = address
            settings.coreRole = .edge
            DictatorViewModel.shared.applyRole()
            state = .approved(mainName: mainName)
            task?.cancel(with: .normalClosure, reason: nil)
        case .pairDenied(let reason):
            fail(reason)
        case .error(_, let text):
            fail(text)
        default:
            receive()
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Resolves `host` and keeps it only if it's a Tailscale address, so a
    /// join never goes anywhere else.
    nonisolated static func tailscaleAddress(for host: String) async -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if TailscaleInterface.isTailscaleAddress(trimmed) { return trimmed }
        guard !trimmed.isEmpty, trimmed.count < 254,
              trimmed.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains($0) }) else { return nil }
        return await Task.detached {
            var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                 ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(trimmed, nil, &hints, &result) == 0, let first = result else { return nil }
            defer { freeaddrinfo(result) }
            for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
                guard let addr = entry.pointee.ai_addr else { continue }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var sin = UnsafeRawPointer(addr).load(as: sockaddr_in.self)
                guard inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(buffer.count)) != nil else { continue }
                let ip = String(cString: buffer)
                if TailscaleInterface.isTailscaleAddress(ip) { return ip }
            }
            return nil
        }.value
    }
}
