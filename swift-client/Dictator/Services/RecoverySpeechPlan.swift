import Foundation

/// How a recovered recording is turned into text: which speech sources to
/// try and in what order, and getting the audio into the shape they expect.
enum RecoverySpeechPlan {
    enum Step: Equatable {
        /// Try these speech sources, in order, from this Mac.
        case sources([SetupRouting.SpeechSource])
        /// Ask the main Mac this Mac is connected to.
        case mainMac
    }

    /// A main Mac or a single Mac runs every source itself. A Mac connected
    /// to a main Mac keeps the configured order: servers it can reach and
    /// its own models run directly; only sources on other Macs go through the
    /// main Mac (and are skipped when it is not connected). If every direct
    /// attempt fails, the main Mac gets the last word: it may hold a key or
    /// reach a server this Mac can't, so a retry works wherever speech runs.
    static func steps(
        role: CoreRole,
        sources: [SetupRouting.SpeechSource],
        localEdgeId: EdgeID,
        connectedToMainMac: Bool
    ) -> [Step] {
        guard role == .edge else { return [.sources(sources)] }
        var steps: [Step] = []
        for source in sources {
            let direct = source.serverURL != nil || source.machineId == localEdgeId
            if direct {
                if case .sources(let group)? = steps.last {
                    steps[steps.count - 1] = .sources(group + [source])
                } else {
                    steps.append(.sources([source]))
                }
            } else if connectedToMainMac, steps.last != .mainMac {
                steps.append(.mainMac)
            }
        }
        if connectedToMainMac, !sources.isEmpty, !steps.contains(.mainMac) { steps.append(.mainMac) }
        return steps
    }

    /// Text that came back from the main Mac is the words as heard. Gives it
    /// what live dictation gives: dictionary replacements, then clean-up
    /// unless the level is "exactly as spoken" or no clean-up model is set.
    static func finish(
        _ text: String,
        dictionary: [[String: String]],
        refineLevel: RefineLevel,
        cleanUp: ((String) async -> String)?
    ) async -> String {
        await TextFinisher.finish(text, dictionary: dictionary, cleanUp: refineLevel != .exact ? cleanUp : nil)
    }

    /// Whether each speech source finishes its own text (dictionary and
    /// clean-up). A connected Mac does not: its detached host can't reach a
    /// clean-up model, so every result is finished once through the main Mac.
    static func sourcesPostProcess(role: CoreRole) -> Bool { role != .edge }

    /// Finishing text that a delegated recovery got back. A connected Mac
    /// asks its main Mac to do the dictionary and clean-up (the way live
    /// dictation and Shortcuts do; its own detached host can't reach a
    /// clean-up model). If that fails, it keeps the dictionary replacements
    /// and the words as heard. Any other Mac cleans up itself.
    static func finishDelegated(
        _ text: String,
        role: CoreRole,
        dictionary: [[String: String]],
        refineLevel: RefineLevel,
        askMainMac: ((_ text: String, _ useAI: Bool) async throws -> String)?,
        cleanUp: ((String) async -> String)?
    ) async -> String {
        if role == .edge {
            if let askMainMac, let done = try? await askMainMac(text, refineLevel != .exact) { return done }
            return CleanupPrompt.applyReplacements(text, dictionary: dictionary)
        }
        return await finish(text, dictionary: dictionary, refineLevel: refineLevel, cleanUp: cleanUp)
    }

    /// Whether an in-app model on `machine` runs directly on this Mac
    /// (no broker needed) rather than through the main Mac's broker.
    static func runsOnThisMac(machine: EdgeID, localEdgeId: EdgeID) -> Bool {
        machine == localEdgeId
    }

    /// Checkpoints are saved at the microphone's own rate; speech engines
    /// expect 16 kHz. Resamples with the same filter live capture uses.
    static func speechReady(_ audio: CapturedAudio) -> CapturedAudio {
        let target = Int(AudioCaptureService.targetSampleRate)
        guard audio.sampleRate != target, audio.sampleRate > 0 else { return audio }
        let samples = audio.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let data = AudioCaptureService.resampleTo16kHz(samples, from: Double(audio.sampleRate))
        let frames = data.count / 4
        return CapturedAudio(data: data, durationSeconds: Double(frames) / Double(target), sampleRate: target, frameCount: frames)
    }
}
