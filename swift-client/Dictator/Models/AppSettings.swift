import Foundation
import Darwin
import SwiftUI

enum ServiceEndpointError: Error, LocalizedError, Equatable {
    case invalidURL(label: String)
    case notConfigured(label: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let label):
            "\(label) must be a complete http:// or https:// URL with a host."
        case .notConfigured(let label):
            "\(label) is not configured."
        }
    }
}

enum ServiceEndpoint {
    static func validated(_ rawValue: String, label: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ServiceEndpointError.notConfigured(label: label)
        }
        let authority: Substring?
        if let separator = trimmed.range(of: "://") {
            authority = trimmed[separator.upperBound...]
                .prefix { character in character != "/" && character != "?" && character != "#" }
        } else {
            authority = nil
        }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              authority?.last != ":",
              components.rangeOfPort == nil
                || components.port.map({ (1...65_535).contains($0) }) == true,
              components.query == nil,
              components.fragment == nil
        else {
            throw ServiceEndpointError.invalidURL(label: label)
        }

        components.scheme = scheme
        guard let url = components.url else {
            throw ServiceEndpointError.invalidURL(label: label)
        }
        return url
    }
}

enum SpeechEndpointError: Error, LocalizedError {
    case unencrypted

    var errorDescription: String? {
        "Use https:// for the speech server, or use a Tailscale or loopback address with http://. Change it in Settings › Advanced."
    }
}

/// Speech carries recordings and a key. Other service addresses keep their own rules.
enum SpeechEndpoint {
    static func validated(_ rawValue: String, label: String = "Speech server") throws -> URL {
        let url = try ServiceEndpoint.validated(rawValue, label: label)
        guard url.scheme == "https" || allowsHTTP(host: url.host ?? "") else {
            throw SpeechEndpointError.unencrypted
        }
        return url
    }

    private static func allowsHTTP(host: String) -> Bool {
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        // DNS names may end in a root dot; IP addresses are parsed, never prefix-matched.
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || (host.hasSuffix(".ts.net") && host.count > ".ts.net".count) { return true }
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            return withUnsafeBytes(of: ipv4) { allowedIPv4(Array($0)) }
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return true }
            if Array(bytes.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] { return true }
            // IPv4-mapped IPv6 must satisfy the same IPv4 ranges.
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
                return allowedIPv4(Array(bytes.suffix(4)))
            }
        }
        return false
    }

    private static func allowedIPv4(_ bytes: [UInt8]) -> Bool {
        bytes[0] == 127 || (bytes[0] == 100 && (64...127).contains(bytes[1]))
    }
}

/// This install's role in the cross-machine dictation handoff. Every
/// role runs the same `SessionBroker` — `standalone` just means "Core with
/// only my own in-process edge, no listener."
enum CoreRole: String, CaseIterable, Codable {
    case standalone
    case core
    case edge
}

enum RefineLevel: String, CaseIterable, Codable {
    case exact = "exact"
    case medium = "medium"
    /// Uses the retired `strong` value: older Macs and speech servers already
    /// treat it as `medium`, so choosing this needs no protocol change.
    case polished = "strong"

    /// Older installs and peers can still supply the retired `light` level.
    static func storedValue(_ raw: String) -> Self? {
        if raw == "light" { return .medium }
        return Self(rawValue: raw)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self.storedValue(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown clean-up level")
        }
        self = value
    }

    /// The same words in Settings and the menu bar.
    var title: String {
        switch self {
        case .exact: "Skip AI clean-up"
        case .medium: "Clean up the text"
        case .polished: "Polish the text"
        }
    }
}

/// Settings persisted to UserDefaults.
///
/// Properties must be stored (loaded once in init, written back in
/// didSet) — @Observable only instruments stored properties, so
/// UserDefaults-backed computed properties silently break SwiftUI
/// bindings (toggles don't register).
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private static let defaults: UserDefaults = {
        // Hosted tests must never read or overwrite the user's app settings.
        if NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return UserDefaults(suiteName: "dev.noamlitt.dictator.tests.\(UUID().uuidString)")!
        }
        return .standard
    }()

    var serverURL: String {
        didSet { Self.defaults.set(serverURL, forKey: "serverURL") }
    }

    /// Which Mac does which job (cleanup Mac and model, backup speech
    /// servers) as JSON — mirrored Core↔Edge like the surface policy.
    var setupRoutingJSON: String {
        didSet {
            Self.defaults.set(setupRoutingJSON, forKey: "setupRoutingJSON")
            _setupRouting = SetupRouting.decode(setupRoutingJSON) ?? SetupRouting()
        }
    }
    @ObservationIgnored private var _setupRouting = SetupRouting()

    var setupRouting: SetupRouting {
        _ = setupRoutingJSON
        return _setupRouting
    }

    func updateSetupRouting(_ edit: (inout SetupRouting) -> Void) {
        var routing = setupRouting
        edit(&routing)
        guard routing != setupRouting else { return }
        setupRoutingJSON = routing.encoded()
    }

    /// Voice launch lists and shortcuts as JSON (a `VoiceLaunchConfig`,
    /// version 2), mirrored Core↔Edge like the other shared settings.
    /// Empty means none yet.
    var voiceLaunchJSON: String {
        didSet {
            Self.defaults.set(voiceLaunchJSON, forKey: "voiceLaunchJSON")
            _voiceLaunch = VoiceLaunchConfig.decode(voiceLaunchJSON) ?? .empty
        }
    }
    @ObservationIgnored private var _voiceLaunch = VoiceLaunchConfig.empty

    var voiceLaunch: VoiceLaunchConfig {
        _ = voiceLaunchJSON
        return _voiceLaunch
    }

    func updateVoiceLaunch(_ edit: (inout VoiceLaunchConfig) -> Void) {
        var config = voiceLaunch
        edit(&config)
        guard config != voiceLaunch else { return }
        voiceLaunchJSON = config.encoded()
    }

    /// Shared routine definitions. Execution and recovery remain on this Mac.
    var workspaceLaunchJSON: String {
        didSet {
            Self.defaults.set(workspaceLaunchJSON, forKey: "workspaceResetJSON")
            _workspaceLaunch = WorkspaceLaunchConfig.decodeForEditing(workspaceLaunchJSON) ?? .empty
        }
    }
    @ObservationIgnored private var _workspaceLaunch = WorkspaceLaunchConfig.empty

    var workspaceLaunch: WorkspaceLaunchConfig {
        _ = workspaceLaunchJSON
        return _workspaceLaunch
    }

    @discardableResult
    func updateWorkspaceLaunch(_ edit: (inout WorkspaceLaunchConfig) -> Void) -> Bool {
        guard workspaceLaunchJSON.isEmpty || WorkspaceLaunchConfig.decodeForEditing(workspaceLaunchJSON) != nil else { return false }
        var config = workspaceLaunch
        edit(&config)
        guard let encoded = config.encoded() else { return false }
        // Compare the stored text: a legacy config can decode to the same value
        // and still need rewriting.
        let previous = workspaceLaunch.routines
        let changed = config != workspaceLaunch
        if encoded != workspaceLaunchJSON { workspaceLaunchJSON = encoded }
        if changed {
            updateVoiceLaunch { voice in
                for old in previous {
                    if let current = config.routines.first(where: { $0.id == old.id }) {
                        VoiceWorkspaceLink.rename(old.id, from: old.name, to: current.name, in: &voice)
                    } else {
                        VoiceWorkspaceLink.remove(old.id, from: &voice)
                    }
                }
            }
        }
        return true
    }

    /// Which app opens a coding assistant's command file: this Mac only,
    /// never mirrored. "terminal" (default) or "iterm".
    var voiceCommandTerminalApp: String {
        didSet { Self.defaults.set(voiceCommandTerminalApp, forKey: "shortcutTerminalApp") }
    }

    /// Speech servers tried in order when `serverURL` can't be reached.
    var backupServerURLs: [String] { setupRouting.backupServerURLs }

    /// Where speech is turned into text, in order (Settings › Your Macs).
    var speechSources: [SetupRouting.SpeechSource] {
        if let sources = setupRouting.speechSources, !sources.isEmpty { return sources }
        return ([serverURL] + backupServerURLs)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(SetupRouting.SpeechSource.server)
    }

    /// Changes the speech sources, starting from what's in effect now.
    func updateSpeechSources(_ edit: (inout [SetupRouting.SpeechSource]) -> Void) {
        var sources = speechSources
        edit(&sources)
        var seen = Set<SetupRouting.SpeechSource>()
        let unique = sources.filter { seen.insert($0).inserted }
        updateSetupRouting { $0.speechSources = unique }
    }

    /// The languages the user speaks (Settings › Dictation).
    var dictationLanguages: [String] {
        if let languages = setupRouting.languages, !languages.isEmpty { return languages }
        var codes: [String] = []
        for identifier in Locale.preferredLanguages {
            if let code = Locale(identifier: identifier).language.languageCode?.identifier, !codes.contains(code) { codes.append(code) }
        }
        return codes.isEmpty ? ["en"] : Array(codes.prefix(3))
    }

    /// The first dictation key, kept for older builds of this Mac's settings.
    var hotkeyKeyCode: Int {
        didSet {
            Self.defaults.set(hotkeyKeyCode, forKey: "hotkeyKeyCode")
            if Int(dictationKeys.primary) != hotkeyKeyCode { dictationKeys = KeyCombo(DictationKey(setting: hotkeyKeyCode)) }
        }
    }

    /// What starts dictation on this Mac. Each Mac has its own keyboard, so
    /// this is not a mirrored setting.
    var dictationKeys: KeyCombo {
        didSet {
            Self.defaults.set(dictationKeys.keyCodes.map(Int.init), forKey: "dictationKeys")
            if hotkeyKeyCode != Int(dictationKeys.primary) { hotkeyKeyCode = Int(dictationKeys.primary) }
        }
    }

    /// What runs a command on this Mac. Nil follows the dictation keys.
    var customCommandKeys: KeyCombo? {
        didSet {
            if let customCommandKeys {
                Self.defaults.set(customCommandKeys.keyCodes.map(Int.init), forKey: "commandKeys")
            } else {
                Self.defaults.removeObject(forKey: "commandKeys")
            }
        }
    }

    var hotkeyTriggers: HotkeyTriggers { HotkeyTriggers(dictation: dictationKeys, commands: customCommandKeys) }

    /// Hands-free dictation (default off = hold-to-talk): tap Right Option
    /// once to start, tap again to stop, instead of holding it down. Only
    /// takes effect via `DictatorViewModel.applyHandsFree()`, which mirrors
    /// it onto `CoreHost.handsFree` — the Core owns the mode and pushes it
    /// to every connected Edge over `config` (see `SessionBroker`).
    var hotkeyHandsFree: Bool {
        didSet { Self.defaults.set(hotkeyHandsFree, forKey: "hotkeyHandsFree") }
    }

    var audioInputDeviceUID: String {
        didSet { Self.defaults.set(audioInputDeviceUID, forKey: "audioInputDeviceUID") }
    }

    /// Learns names from the user’s corrections to dictated text. On by
    /// default; mirrored to connected Macs.
    var learnFromCorrections: Bool {
        didSet { Self.defaults.set(learnFromCorrections, forKey: "learnFromCorrections") }
    }

    /// History persistence (default on for a fresh install — the History
    /// feed and the cross-machine dataset are the product; an explicit
    /// `false` in UserDefaults is still honoured). When disabled, dictation
    /// transcripts are pasted but never stored; the History feed stays empty.
    var persistHistory: Bool {
        didSet { Self.defaults.set(persistHistory, forKey: "persistHistory") }
    }

    /// Cached surface policy JSON string.
    var cachedSurfacePolicyJSON: String {
        didSet {
            Self.defaults.set(cachedSurfacePolicyJSON, forKey: "cachedSurfacePolicyJSON")
            _cachedSurfacePolicy = Self.parseSurfacePolicy(from: cachedSurfacePolicyJSON)
        }
    }

    /// Prompt saving paused until this moment (this Mac only). `distantFuture`
    /// means "until I resume". Dictation is not affected.
    var promptCapturePausedUntil: Date? {
        didSet {
            if let promptCapturePausedUntil {
                Self.defaults.set(promptCapturePausedUntil, forKey: "promptCapturePausedUntil")
            } else {
                Self.defaults.removeObject(forKey: "promptCapturePausedUntil")
            }
        }
    }

    /// First-run "Which AI tools should Dictator keep your prompts from?"
    /// has been answered on this Mac.
    var didCompletePromptSetup: Bool {
        didSet { Self.defaults.set(didCompletePromptSetup, forKey: "didCompletePromptSetup") }
    }

    /// Pack policy is shared; installed applications are discovered on each Mac.
    var vocabularyPacksAutomatic: Bool {
        didSet { Self.defaults.set(vocabularyPacksAutomatic, forKey: "vocabularyPacksAutomatic") }
    }
    var vocabularyPacksOn: [String] {
        didSet { Self.defaults.set(vocabularyPacksOn, forKey: "vocabularyPacksOn") }
    }
    var vocabularyPacksOff: [String] {
        didSet { Self.defaults.set(vocabularyPacksOff, forKey: "vocabularyPacksOff") }
    }

    /// This Mac's first dictation has happened, so its one-time notice
    /// never shows again. Per Mac, not mirrored.
    var didPassFirstDictation: Bool {
        didSet { Self.defaults.set(didPassFirstDictation, forKey: "didPassFirstDictation") }
    }

    /// The first-run welcome (dictation key, permissions, then the optional
    /// typed history) has been finished on this Mac. Until then, start-up
    /// doesn't show system permission requests on its own.
    var didCompleteWelcome: Bool {
        didSet { Self.defaults.set(didCompleteWelcome, forKey: "didCompleteWelcome") }
    }

    /// How each tool's prompts are captured on this Mac (connectors are per
    /// machine): `hook`, `transcript` or `keystrokes`. A tool with no entry
    /// hasn't been set up here yet.
    var captureMethods: [String: String] {
        didSet { Self.defaults.set(captureMethods, forKey: "captureMethods") }
    }

    @ObservationIgnored
    private var _cachedSurfacePolicy: SurfacePolicy = .fallback

    var surfacePolicy: SurfacePolicy {
        // Register readers of the decoded cache for local and mirrored edits.
        _ = cachedSurfacePolicyJSON
        return _cachedSurfacePolicy
    }

    var refineLevel: RefineLevel {
        didSet { Self.defaults.set(refineLevel.rawValue, forKey: "refineLevel") }
    }

    var customSystemPrompt: String {
        didSet { Self.defaults.set(customSystemPrompt, forKey: "customSystemPrompt") }
    }

    /// Cross-machine role. The pairing token for an Edge's Core is never
    /// stored here — it lives in `PairingCredentialStore`, keyed by
    /// `coreAddress`.
    var coreRole: CoreRole {
        didSet { Self.defaults.set(coreRole.rawValue, forKey: "coreRole") }
    }

    /// Host, or host:port, of the Core this machine connects to as an Edge.
    var coreAddress: String {
        didSet { Self.defaults.set(coreAddress, forKey: "coreAddress") }
    }

    /// User's preferred mic owner (an `EdgeID`), empty = automatic
    /// (whoever initiates, if it has a mic) — mirrors `micOwnerPreference`.
    var micOwnerEdgeID: String {
        didSet { Self.defaults.set(micOwnerEdgeID, forKey: "micOwnerEdgeID") }
    }

    /// Override for this machine's Edge display name; empty means
    /// `EdgeRuntime` falls back to the Mac's host name.
    var edgeDisplayName: String {
        didSet { Self.defaults.set(edgeDisplayName, forKey: "edgeDisplayName") }
    }

    /// The settings the main Mac mirrors to connected Macs. Reading it
    /// inside `withObservationTracking` observes every one of them.
    var mirroredSettings: CoreSettingsDTO {
        CoreSettingsDTO(
            refineLevel: refineLevel.rawValue,
            customSystemPrompt: customSystemPrompt,
            persistHistory: persistHistory,
            surfacePolicyJSON: cachedSurfacePolicyJSON,
            setupRoutingJSON: setupRoutingJSON,
            voiceLaunchJSON: voiceLaunchJSON,
            workspaceLaunchJSON: workspaceLaunchJSON,
            vocabularyPacksAutomatic: vocabularyPacksAutomatic,
            vocabularyPacksOn: vocabularyPacksOn,
            vocabularyPacksOff: vocabularyPacksOff,
            learnFromCorrections: learnFromCorrections,
            micOwnerEdgeID: micOwnerEdgeID
        )
    }

    /// The one place save/ignore is decided — typed capture, connectors and
    /// dictation all come through here (and `HistoryRepository.record`).
    func captureDecision(for context: CaptureContext, modality: String, at date: Date = Date()) -> CaptureDecision {
        guard persistHistory else { return CaptureDecision(action: .ignore, reason: "history-off") }
        if modality != "voice", isPromptCapturePaused(at: date) {
            return CaptureDecision(action: .ignore, reason: "paused")
        }
        return surfacePolicy.decide(context, modality: modality)
    }

    /// Learning has its own switch. Default-off typed history still permits
    /// filtered pairs, but an explicit exclusion in either modality forbids AX.
    func correctionObservationAllowed(for context: CaptureContext, at date: Date = Date()) -> Bool {
        guard learnFromCorrections, !isPromptCapturePaused(at: date),
              surfacePolicy.decide(context, modality: "voice").isSave else { return false }
        let typed = surfacePolicy.decide(context, modality: "typed")
        return typed.isSave || typed.reason == "default:typed" || typed.reason.hasPrefix("tool-unset:")
    }

    func isPromptCapturePaused(at date: Date = Date()) -> Bool {
        guard let until = promptCapturePausedUntil else { return false }
        return date < until
    }

    /// Writes a policy edit. On an Edge `CoreSettingsMirror` sends it to the
    /// Core; on a Core the Edges pick it up — the same path as every other
    /// shared setting, no separate service involved.
    func updateSurfacePolicy(_ edit: (inout SurfacePolicy) -> Void) {
        var policy = surfacePolicy
        edit(&policy)
        updateCachedSurfacePolicy(policy)
    }

    /// Presentation-only master-switch state for the History empty view.
    var isHistoryCaptureEnabled: Bool { persistHistory }

    func updateCachedSurfacePolicy(_ policy: SurfacePolicy) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(policy),
           let string = String(data: data, encoding: .utf8) {
            cachedSurfacePolicyJSON = string
        }
    }

    /// A Mac that never stored a policy (a fresh Core) writes the default
    /// now, so Core and Edges converge on one stored JSON.
    func storeDefaultSurfacePolicyIfNeeded() {
        if cachedSurfacePolicyJSON.isEmpty { updateCachedSurfacePolicy(surfacePolicy) }
    }

    private static func parseSurfacePolicy(from json: String) -> SurfacePolicy {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SurfacePolicy.self, from: data) else {
            return .fallback
        }
        return decoded
    }

    private init() {
        let d = Self.defaults
        serverURL = d.string(forKey: "serverURL") ?? ""
        let routingJSON = d.string(forKey: "setupRoutingJSON") ?? ""
        setupRoutingJSON = routingJSON
        _setupRouting = SetupRouting.decode(routingJSON) ?? SetupRouting()
        let launchJSON = d.string(forKey: "voiceLaunchJSON") ?? ""
        voiceLaunchJSON = launchJSON
        _voiceLaunch = VoiceLaunchConfig.decode(launchJSON) ?? .empty
        let resetJSON = d.string(forKey: "workspaceResetJSON") ?? ""
        workspaceLaunchJSON = resetJSON
        _workspaceLaunch = WorkspaceLaunchConfig.decodeForEditing(resetJSON) ?? .empty
        voiceCommandTerminalApp = d.string(forKey: "shortcutTerminalApp") ?? "terminal"
        let keyCode = d.integer(forKey: "hotkeyKeyCode")
        hotkeyKeyCode = keyCode == 0 ? 61 : keyCode // 61 = Right Option
        dictationKeys = KeyCombo(stored: d.array(forKey: "dictationKeys"))
            ?? KeyCombo(DictationKey(setting: keyCode == 0 ? 61 : keyCode))
        customCommandKeys = KeyCombo(stored: d.array(forKey: "commandKeys"))
        hotkeyHandsFree = d.bool(forKey: "hotkeyHandsFree")
        audioInputDeviceUID = d.string(forKey: "audioInputDeviceUID") ?? ""
        // `object(forKey:)` distinguishes "never set" (→ on) from an
        // explicit false. Before this default, a Core whose owner never
        // opened the History tab silently dropped every dictation.
        learnFromCorrections = d.object(forKey: "learnFromCorrections") == nil ? true : d.bool(forKey: "learnFromCorrections")
        persistHistory = d.object(forKey: "persistHistory") == nil
            ? true : d.bool(forKey: "persistHistory")
        let cachedJSON = d.string(forKey: "cachedSurfacePolicyJSON") ?? ""
        cachedSurfacePolicyJSON = cachedJSON
        _cachedSurfacePolicy = Self.parseSurfacePolicy(from: cachedJSON)
        promptCapturePausedUntil = d.object(forKey: "promptCapturePausedUntil") as? Date
        didCompletePromptSetup = d.bool(forKey: "didCompletePromptSetup")
        didCompleteWelcome = d.bool(forKey: "didCompleteWelcome")
        vocabularyPacksAutomatic = d.object(forKey: "vocabularyPacksAutomatic") == nil ? true : d.bool(forKey: "vocabularyPacksAutomatic")
        vocabularyPacksOn = d.stringArray(forKey: "vocabularyPacksOn") ?? []
        vocabularyPacksOff = d.stringArray(forKey: "vocabularyPacksOff") ?? []
        didPassFirstDictation = d.bool(forKey: "didPassFirstDictation")
        captureMethods = d.dictionary(forKey: "captureMethods") as? [String: String] ?? [:]
        refineLevel = d.string(forKey: "refineLevel")
            .flatMap { RefineLevel.storedValue($0) } ?? .medium
        customSystemPrompt = d.string(forKey: "customSystemPrompt") ?? ""
        coreRole = d.string(forKey: "coreRole").flatMap { CoreRole(rawValue: $0) } ?? .standalone
        coreAddress = d.string(forKey: "coreAddress") ?? ""
        micOwnerEdgeID = d.string(forKey: "micOwnerEdgeID") ?? ""
        edgeDisplayName = d.string(forKey: "edgeDisplayName") ?? ""
    }
}
