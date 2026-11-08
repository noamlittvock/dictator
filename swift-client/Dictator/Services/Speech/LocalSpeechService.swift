import AVFoundation
import Foundation
import Observation
import Speech
import WhisperKit

/// Speech-to-text models that run inside Dictator on this Mac — Whisper
/// through WhisperKit, or Apple's own recognizer — so any Mac can turn
/// speech into text without the speech server.
///
/// A model is named by an id with its engine as prefix:
/// `whisperkit:openai_whisper-large-v3-v20240930_turbo`, `apple:he-IL`.
@MainActor
@Observable
final class LocalSpeechService {
    static let shared = LocalSpeechService()

    enum Engine: String { case whisperkit, apple }

    enum SpeechError: Error, LocalizedError {
        case unknownModel
        case notInstalled
        case appleNeedsNewerMacOS
        case languageNotSupported(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unknownModel: "That speech model isn’t known."
            case .notInstalled: "That speech model isn’t on this Mac."
            case .appleNeedsNewerMacOS: "Apple’s speech recognition needs macOS 26 or later."
            case .languageNotSupported(let language): "Apple’s speech recognition doesn’t support \(language) on this Mac."
            case .failed(let message): message
            }
        }
    }

    /// Models installed on this Mac (ids), reported to the Core.
    private(set) var installed: [String] = []
    @ObservationIgnored var onChange: (([String]) -> Void)?

    @ObservationIgnored private var loaded: (id: String, pipe: WhisperKit)?
    @ObservationIgnored private let appleKey = "appleSpeechLocales"

    static let modelsFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Dictator/SpeechModels", isDirectory: true)
    }()

    private static let completeMarker = ".dictator-complete"

    nonisolated static func engine(of id: String) -> Engine? {
        id.split(separator: ":", maxSplits: 1).first.flatMap { Engine(rawValue: String($0)) }
    }

    nonisolated static func name(of id: String) -> String {
        String(id.split(separator: ":", maxSplits: 1).last ?? Substring(id))
    }

    nonisolated static var appleAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    init() {
        refresh()
    }

    // MARK: Installed models

    func refresh() {
        var ids: [String] = []
        let root = Self.modelsFolder.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        if let folders = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            for folder in folders.sorted()
            where FileManager.default.fileExists(atPath: root.appendingPathComponent(folder).appendingPathComponent(Self.completeMarker).path) {
                ids.append("whisperkit:" + folder)
            }
        }
        if Self.appleAvailable {
            ids += (UserDefaults.standard.stringArray(forKey: appleKey) ?? []).map { "apple:" + $0 }
        }
        guard ids != installed else { return }
        installed = ids
        onChange?(ids)
    }

    private func folder(forWhisper variant: String) -> URL {
        Self.modelsFolder.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)", isDirectory: true)
    }

    /// Downloads a model (Whisper) or installs a language (Apple).
    func install(_ id: String) -> AsyncThrowingStream<ModelPullProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    switch Self.engine(of: id) {
                    case .whisperkit:
                        let variant = Self.name(of: id)
                        guard Self.isValidVariant(variant) else { throw SpeechError.unknownModel }
                        try FileManager.default.createDirectory(at: Self.modelsFolder, withIntermediateDirectories: true)
                        let folder = try await WhisperKit.download(variant: variant, downloadBase: Self.modelsFolder) { progress in
                            continuation.yield(ModelPullProgress(
                                status: "downloading", completed: progress.completedUnitCount, total: progress.totalUnitCount, done: false
                            ))
                        }
                        FileManager.default.createFile(atPath: folder.appendingPathComponent(Self.completeMarker).path, contents: Data())
                    case .apple:
                        guard #available(macOS 26, *) else { throw SpeechError.appleNeedsNewerMacOS }
                        let identifier = Self.name(of: id)
                        try await AppleSpeech.install(locale: Locale(identifier: identifier)) { fraction in
                            continuation.yield(ModelPullProgress(status: "installing", completed: Int64(fraction * 1000), total: 1000, done: false))
                        }
                        var locales = UserDefaults.standard.stringArray(forKey: self.appleKey) ?? []
                        if !locales.contains(identifier) { locales.append(identifier) }
                        UserDefaults.standard.set(locales, forKey: self.appleKey)
                    case nil:
                        throw SpeechError.unknownModel
                    }
                    self.refresh()
                    continuation.yield(ModelPullProgress(status: "success", done: true))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func remove(_ id: String) {
        switch Self.engine(of: id) {
        case .whisperkit:
            if loaded?.id == id { loaded = nil }
            try? FileManager.default.removeItem(at: folder(forWhisper: Self.name(of: id)))
        case .apple:
            let identifier = Self.name(of: id)
            UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: appleKey) ?? []).filter { $0 != identifier }, forKey: appleKey)
        case nil:
            break
        }
        refresh()
    }

    nonisolated static func isValidVariant(_ variant: String) -> Bool {
        !variant.isEmpty && variant.count < 120 && !variant.contains("..") && !variant.contains("/")
            && variant.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0) }
    }

    // MARK: Transcribing

    /// Turns 16 kHz mono samples into text. `languages` are the ones this
    /// user speaks (Whisper chooses among them); `vocabulary` are words to
    /// expect (the dictionary).
    func transcribe(_ id: String, samples: [Float], languages: [String], vocabulary: [String]) async throws -> String {
        guard installed.contains(id) else { throw SpeechError.notInstalled }
        switch Self.engine(of: id) {
        case .whisperkit:
            let pipe = try await whisper(for: id)
            return try await Self.runWhisper(pipe, samples: samples, languages: languages, vocabulary: vocabulary)
        case .apple:
            guard #available(macOS 26, *) else { throw SpeechError.appleNeedsNewerMacOS }
            return try await AppleSpeech.transcribe(samples: samples, locale: Locale(identifier: Self.name(of: id)), vocabulary: vocabulary)
        case nil:
            throw SpeechError.unknownModel
        }
    }

    /// Keeps one Whisper model loaded; loading another unloads it.
    private func whisper(for id: String) async throws -> WhisperKit {
        if let loaded, loaded.id == id { return loaded.pipe }
        if let previous = loaded { await previous.pipe.unloadModels() }
        loaded = nil
        let config = WhisperKitConfig(
            modelFolder: folder(forWhisper: Self.name(of: id)).path,
            tokenizerFolder: Self.modelsFolder,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        let pipe = try await WhisperKit(config)
        loaded = (id, pipe)
        return pipe
    }

    /// Read-only preview. Never loads/downloads speech assets or calls a service.
    /// Without an already loaded tokenizer, label the conservative estimate.
    func dictionaryPreview(terms: [String], language: String?) -> (terms: [String], fullness: Double, estimated: Bool) {
        let tokenizer = loaded?.pipe.tokenizer
        let measure: (String) -> Int = { list in
            let text = " " + VocabularyHint.prompt([list], language: language)
            return tokenizer?.encode(text: text).count ?? Int(ceil(Double(text.utf8.count) / 3))
        }
        let fitted = VocabularyHint.fit(terms, budget: VocabularyHint.budget, tokens: measure)
        let used = fitted.isEmpty ? 0 : measure(fitted.joined(separator: ", "))
        return (fitted, min(1, Double(used) / Double(VocabularyHint.budget)), tokenizer == nil)
    }

    private static func runWhisper(_ pipe: WhisperKit, samples: [Float], languages: [String], vocabulary: [String]) async throws -> String {
        // Choose among the user's languages only: on a short command,
        // unrestricted detection has heard English as German.
        var language: String? = languages.count == 1 ? languages[0] : nil
        if (languages.count > 1 || (languages.isEmpty && !vocabulary.isEmpty)), let detected = try? await pipe.detectLangauge(audioArray: Array(samples.prefix(16_000 * 30))) {
            language = languages.isEmpty ? detected.language : languages.max { (detected.langProbs[$0] ?? -.infinity) < (detected.langProbs[$1] ?? -.infinity) }
        }
        var promptTokens: [Int]?
        if !vocabulary.isEmpty, let tokenizer = pipe.tokenizer {
            let ordered = VocabularyHint.orderedTerms(VocabularyHintInput(packs: vocabulary))
            let fitted = VocabularyHint.fit(ordered, budget: VocabularyHint.budget) {
                tokenizer.encode(text: " " + VocabularyHint.prompt([$0], language: language)).count
            }
            if !fitted.isEmpty {
                promptTokens = tokenizer.encode(text: " " + VocabularyHint.prompt(fitted, language: language))
                    .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            }
        }
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 5,
            // WhisperKit 1.1 copies these options (including promptTokens) to
            // every VAD chunk. Prefill must also be on in automatic language mode.
            usePrefillPrompt: language != nil || promptTokens != nil,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokens,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6,
            chunkingStrategy: .vad
        )
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
        return CleanupPrompt.stripDegenerate(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Apple's on-device recognizer (macOS 26+). Uses the newer
/// SpeechTranscriber where it supports the language, and the dictation
/// recognizer otherwise (it covers more languages, Hebrew among them).
@available(macOS 26, *)
enum AppleSpeech {
    /// Languages Apple can recognise on this Mac, as BCP 47 identifiers.
    static func supportedLanguages() async -> [String] {
        let modern = await SpeechTranscriber.supportedLocales
        let dictation = await DictationTranscriber.supportedLocales
        return Set((modern + dictation).map { $0.identifier(.bcp47) }).sorted()
    }

    private static func usesModern(_ locale: Locale) async -> Bool {
        await SpeechTranscriber.supportedLocales.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    private static func module(for locale: Locale) async throws -> any SpeechModule {
        if await usesModern(locale) {
            return SpeechTranscriber(locale: locale, preset: .transcription)
        }
        guard await DictationTranscriber.supportedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw LocalSpeechService.SpeechError.languageNotSupported(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
        }
        return DictationTranscriber(locale: locale, preset: .longDictation)
    }

    static func install(locale: Locale, progress: @escaping (Double) -> Void) async throws {
        let module = try await module(for: locale)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
            progress(1)
            return
        }
        let watcher = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
        progress(1)
    }

    static func transcribe(samples: [Float], locale: Locale, vocabulary: [String]) async throws -> String {
        let module = try await module(for: locale)
        let analyzer = SpeechAnalyzer(modules: [module])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(VocabularyHint.orderedTerms(VocabularyHintInput(packs: vocabulary)).prefix(100))
            try await analyzer.setContext(context)
        }
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw LocalSpeechService.SpeechError.failed("Couldn’t prepare the recording.")
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) ?? source
        let buffer = try convert(input, to: target)

        let collector: Task<String, Error>
        if let transcriber = module as? SpeechTranscriber {
            collector = Task { try await transcriber.results.reduce(into: "") { $0 += String($1.text.characters) } }
        } else if let dictation = module as? DictationTranscriber {
            collector = Task { try await dictation.results.reduce(into: "") { $0 += String($1.text.characters) } }
        } else {
            throw LocalSpeechService.SpeechError.failed("Apple’s speech recognition couldn’t start.")
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()
        if let last = try await analyzer.analyzeSequence(stream) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1024) else {
            throw LocalSpeechService.SpeechError.failed("Couldn’t convert the recording.")
        }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return output
    }
}
