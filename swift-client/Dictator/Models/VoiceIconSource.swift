import Foundation

/// What stands for a Voice launch card: the icon of where its action goes.
/// Tried in order: an installed app, then the app that opens a link kind
/// (WhatsApp, Mail), then the website's own icon. When none is found the
/// card shows `fallback`: a symbol for the kind of action, or the first
/// letter of its name for a website. Pure, so the order can be tested.
struct VoiceIconSource: Hashable {
    enum Candidate: Hashable {
        /// An app's bundle identifier.
        case app(String)
        /// A link scheme, like "whatsapp" or "mailto": the app that opens it.
        case scheme(String)
        /// A website's host, like "www.youtube.com".
        case site(String)
    }

    enum Fallback: Hashable {
        case symbol(String)
        case letter(String)
    }

    var candidates: [Candidate]
    var fallback: Fallback

    static let shortcutsApp = "com.apple.shortcuts"
    static let terminalApp = "com.apple.Terminal"

    /// From a card's hints (apps and a website from the catalog) and its actions.
    static func make(apps: [String] = [], site: String? = nil, steps: [VoiceStep], title: String) -> VoiceIconSource {
        var candidates = apps.map(Candidate.app)
        if let site = cleanHost(site) { candidates.append(.site(site)) }
        var fallback = Fallback.symbol("waveform")
        if let step = steps.first(where: { $0.kind != .confirm && $0.kind != .waitForTextField }) {
            switch step.kind {
            case .openLink:
                let link = step.link ?? ""
                let scheme = link.split(separator: ":", maxSplits: 1).first.map { $0.lowercased() } ?? ""
                if scheme == "http" || scheme == "https" {
                    if let host = host(of: link) { candidates.append(.site(host)) }
                    let letter = title.first.map { String($0).uppercased() } ?? "?"
                    fallback = .letter(letter)
                } else {
                    if !scheme.isEmpty { candidates.append(.scheme(scheme)) }
                    fallback = .symbol(scheme == "mailto" ? "envelope.fill" : "link")
                }
            case .openApp:
                if let id = step.bundleId, !id.isEmpty { candidates.append(.app(id)) }
                fallback = .symbol("app.dashed")
            case .runWorkspace:
                fallback = .symbol("rectangle.3.group")
            case .runInTerminal:
                if step.background != true { candidates.append(.app(terminalApp)) }
                fallback = .symbol("terminal")
            case .runAppleShortcut:
                candidates.append(.app(shortcutsApp))
                fallback = .symbol("square.2.layers.3d")
            case .webhook:
                fallback = .symbol("paperplane.fill")
            case .appendToFile:
                fallback = .symbol("doc.text")
            case .typeText, .pressKey:
                fallback = .symbol("keyboard")
            case .confirm, .waitForTextField:
                break
            }
        }
        var seen = Set<Candidate>()
        return VoiceIconSource(candidates: candidates.filter { seen.insert($0).inserted }, fallback: fallback)
    }

    /// The host of a link that may hold `{…}` values, or nil when the host
    /// itself depends on what is said.
    static func host(of link: String) -> String? {
        guard let afterScheme = link.range(of: "://") else { return nil }
        let rest = link[afterScheme.upperBound...]
        let host = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" && $0 != ":" }
        return cleanHost(String(host))
    }

    /// A plain host name, lowercased, or nil when it isn't one.
    static func cleanHost(_ text: String?) -> String? {
        guard let text else { return nil }
        let host = text.lowercased()
        guard !host.isEmpty, host.count <= 253, host.contains("."),
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
        return host
    }
}
