import Carbon
import Foundation
import Observation

/// The seam the controller uses, so tests can watch registration without Carbon.
@MainActor
protocol WorkspaceHotkeyRegistering: AnyObject {
    var onTrigger: ((String) -> Void)? { get set }
    var onCommandTrigger: ((String) -> Void)? { get set }
    func register(_ definitions: [WorkspaceRoutine], commands: [VoiceCommand]) -> WorkspaceHotkeyRegistry.Registration
    func clear()
}

/// Carbon registers just the selected key combinations; it does not record
/// keystrokes or add another event tap to Dictator's dictation path.
@MainActor
final class WorkspaceHotkeyRegistry: WorkspaceHotkeyRegistering {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private var targets: [UInt32: Target] = [:]
    fileprivate enum Target { case routine(String), command(String) }
    var onTrigger: ((String) -> Void)?
    var onCommandTrigger: ((String) -> Void)?
    private static let signature: OSType = 0x44575253 // DWRS

    /// Routine id to the reason its shortcut could not be turned on, plus a general warning.
    struct Registration: Equatable {
        var failures: [String: String] = [:]
        var general: [String] = []
        var commandFailures: [String: String] = [:]

        fileprivate mutating func fail(_ target: Target, _ reason: String) {
            switch target {
            case .routine(let id): failures[id] = reason
            case .command(let id): commandFailures[id] = reason
            }
        }
    }

    func register(_ definitions: [WorkspaceRoutine], commands: [VoiceCommand] = []) -> Registration {
        clear()
        var registration = Registration()
        var active: [(Target, WorkspaceHotkey)] = definitions.compactMap {
            guard $0.enabled, let key = $0.hotkey, key.isValid else { return nil }
            return (.routine($0.id), key)
        }
        active += commands.compactMap {
            guard $0.enabled, let key = $0.hotkey, key.isValid,
                  !VoiceCommandWithoutSpeech.needsSpokenWords($0) else { return nil }
            return (.command($0.id), key)
        }
        // Refuse every participant in a clash, including mirrored or hand-edited settings.
        let counts = Dictionary(grouping: active, by: { $0.1 }).mapValues(\.count)
        active = active.filter { target, key in
            guard counts[key] == 1 else {
                registration.fail(target, "Another command or routine uses this keyboard shortcut")
                return false
            }
            return true
        }
        guard !active.isEmpty else { return registration }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotkeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
            guard status == noErr, hotkeyID.signature == WorkspaceHotkeyRegistry.signature else { return OSStatus(eventNotHandledErr) }
            let registry = Unmanaged<WorkspaceHotkeyRegistry>.fromOpaque(context).takeUnretainedValue()
            let id = hotkeyID.id
            Task { @MainActor in
                switch registry.targets[id] {
                case .routine(let id): registry.onTrigger?(id)
                case .command(let id): registry.onCommandTrigger?(id)
                case nil: break
                }
            }
            return noErr
        }
        let status = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &event,
                                         Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            registration.general = ["Dictator couldn’t turn on keyboard shortcuts. You can still run routines here."]
            return registration
        }
        for (target, key) in active {
            let id = nextID
            nextID &+= 1
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(key.keyCode, key.modifiers,
                                             EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                targets[id] = target
            } else {
                registration.fail(target, WorkspaceHotkeyConflict.registrationMessage(status: status))
            }
        }
        return registration
    }

    func clear() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        targets.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}

/// One observer owns registration for both mirrored settings on either Mac.
/// The closures let tests change synthetic configurations without UserDefaults or Carbon.
@MainActor
final class WorkspaceHotkeyCoordinator {
    private let registry: WorkspaceHotkeyRegistering
    private let routines: () -> [WorkspaceRoutine]
    private let commands: () -> [VoiceCommand]
    private var started = false
    private var suspended = false
    var onRegistration: (WorkspaceHotkeyRegistry.Registration) -> Void = { _ in }

    init(registry: WorkspaceHotkeyRegistering, routines: @escaping () -> [WorkspaceRoutine],
         commands: @escaping () -> [VoiceCommand]) {
        self.registry = registry
        self.routines = routines
        self.commands = commands
    }

    func start() {
        guard !started else { return }
        started = true
        observe()
        refresh()
    }

    private func observe() {
        withObservationTracking {
            _ = routines()
            _ = commands()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.started else { return }
                self.observe()
                self.refresh()
            }
        }
    }

    func refresh() {
        guard started, !suspended else { return }
        // Only commands that may own a shortcut reach the registry, whichever registry it is.
        let commands = commands().filter { $0.enabled && $0.hotkey != nil && !VoiceCommandWithoutSpeech.needsSpokenWords($0) }
        onRegistration(registry.register(routines(), commands: commands))
    }

    func suspend() { suspended = true; registry.clear() }
    func resume() { suspended = false; refresh() }
}

/// Shared recorder/save checks. Disabled commands and routines still own their keys.
enum VoiceCommandHotkeys {
    static func problem(for command: VoiceCommand, commands: [VoiceCommand], routines: [WorkspaceRoutine], triggers: HotkeyTriggers) -> String? {
        guard let key = command.hotkey else { return nil }
        if VoiceCommandWithoutSpeech.needsSpokenWords(command) {
            return "A command that needs spoken words cannot have a keyboard shortcut."
        }
        if let reason = WorkspaceHotkeyConflict.problem(for: key, routineID: nil, routines: routines, triggers: triggers) {
            return reason
        }
        return conflict(key, commands: commands.filter { $0.id != command.id })
    }

    static func conflict(_ key: WorkspaceHotkey, commands: [VoiceCommand]) -> String? {
        commands.contains { $0.hotkey == key } ? "Another command already uses this keyboard shortcut." : nil
    }
}
