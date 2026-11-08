import XCTest
@testable import Dictator

/// The speech-source chain: any failure moves to the next source, an
/// unreachable one is skipped quickly, and a hung one is abandoned.
final class SpeechFallbackTests: XCTestCase {
    private let a = SetupRouting.SpeechSource.server("http://a.example:1")
    private let b = SetupRouting.SpeechSource.server("http://b.example:1")
    private let c = SetupRouting.SpeechSource.mac("mac-c", model: "whisper")

    private struct Boom: Error {}

    func testServerErrorFallsThroughToNextSource() async throws {
        let done = try await SpeechSourceChain.run(sources: [a, b], audioSeconds: 2, attempt: { source, _ in
            if source == self.a { throw TranscriptionError.serverError(500, "boom") }
            return "from b"
        })
        XCTAssertEqual(done.value, "from b")
        XCTAssertEqual(done.index, 1)
    }

    func testMissingKeyStillAllowsWorkingBackup() async throws {
        let done = try await SpeechSourceChain.run(sources: [a, b], audioSeconds: 1, attempt: { source, _ in
            if source == self.a { throw TranscriptionError.authenticationRequired }
            return "backup words"
        })
        XCTAssertEqual(done.value, "backup words")
        XCTAssertEqual(done.source, b)
    }

    func testMissingKeyIsExplainedWhenBackupAlsoFails() async {
        do {
            _ = try await SpeechSourceChain.run(sources: [a, b], audioSeconds: 1, attempt: { source, _ -> String in
                if source == self.a { throw TranscriptionError.authenticationRequired }
                throw URLError(.cannotConnectToHost)
            })
            XCTFail("Must fail")
        } catch let failure as SpeechSourceChain.Failure {
            XCTAssertEqual(failure.source, a)
            guard case TranscriptionError.authenticationRequired = failure.error else { return XCTFail("Lost key failure") }
        } catch { XCTFail("Unexpected \(error)") }
    }

    func testUnsafeSavedAddressIsExplainedWhenBackupAlsoFails() async {
        do {
            _ = try await SpeechSourceChain.run(
                sources: [a, b], audioSeconds: 1,
                reach: { source, _ in
                    if source == self.a { _ = try SpeechEndpoint.validated("http://public.example") }
                    throw URLError(.cannotConnectToHost)
                },
                attempt: { _, _ -> String in XCTFail("No requests"); return "" }
            )
            XCTFail("Must fail")
        } catch let failure as SpeechSourceChain.Failure {
            XCTAssertEqual(failure.source, a)
            XCTAssertTrue(failure.error is SpeechEndpointError)
        } catch { XCTFail("Unexpected \(error)") }
    }

    func testClientErrorAndDecodeErrorAlsoFallThrough() async throws {
        var calls: [SetupRouting.SpeechSource] = []
        let done = try await SpeechSourceChain.run(sources: [a, b, c], audioSeconds: 2, attempt: { source, _ in
            calls.append(source)
            if source == self.a { throw TranscriptionError.serverError(413, "too big") }
            if source == self.b { throw TranscriptionError.invalidResponse }
            return "from c"
        })
        XCTAssertEqual(done.value, "from c")
        XCTAssertEqual(calls, [a, b, c])
    }

    func testTimeoutErrorFallsThrough() async throws {
        let done = try await SpeechSourceChain.run(sources: [a, b], audioSeconds: 2, attempt: { source, _ in
            if source == self.a { throw URLError(.timedOut) }
            return "ok"
        })
        XCTAssertEqual(done.index, 1)
    }

    func testUnreachableSourceIsSkippedWithoutAttempt() async throws {
        var attempted: [SetupRouting.SpeechSource] = []
        let done = try await SpeechSourceChain.run(
            sources: [a, b], audioSeconds: 2,
            reach: { source, _ in if source == self.a { throw URLError(.cannotConnectToHost) } },
            attempt: { source, _ in attempted.append(source); return "ok" }
        )
        XCTAssertEqual(attempted, [b])
        XCTAssertEqual(done.source, b)
    }

    func testHungSourceIsAbandonedByTheWatchdog() async throws {
        let started = Date()
        let done = try await SpeechSourceChain.run(sources: [a, b], audioSeconds: 2, limit: 0.3, attempt: { source, _ in
            if source == self.a { try await Task.sleep(nanoseconds: 30_000_000_000) }
            return "b answered"
        })
        XCTAssertEqual(done.value, "b answered")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testAllSourcesFailingThrowsTheLastFailure() async {
        do {
            _ = try await SpeechSourceChain.run(sources: [a, b], audioSeconds: 2, attempt: { source, _ -> String in
                throw source == self.a ? URLError(.cannotConnectToHost) as Error : TranscriptionError.serverError(503, "")
            })
            XCTFail("should have thrown")
        } catch let failed as SpeechSourceChain.Failure {
            XCTAssertEqual(failed.source, b)
            guard case TranscriptionError.serverError(503, _) = failed.error else { return XCTFail("wrong error") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testProcessingLimitScalesWithAudioAndIsCapped() {
        XCTAssertLessThan(SpeechSourceChain.processingLimit(audioSeconds: 5), SpeechSourceChain.processingLimit(audioSeconds: 60))
        XCTAssertEqual(SpeechSourceChain.processingLimit(audioSeconds: 10_000), 300)
        XCTAssertLessThanOrEqual(SpeechSourceChain.connectTimeout, 5)
    }

    func testInAppSpeechSourceWorksThroughTheChainForRecovery() async throws {
        let done = try await SpeechSourceChain.run(sources: [c], audioSeconds: 1, attempt: { source, _ in
            XCTAssertEqual(source.machineId, "mac-c")
            return "recovered in app"
        })
        XCTAssertEqual(done.value, "recovered in app")
    }

    @MainActor
    func testRecoveryTranscribesThroughAChainWithInAppSpeech() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpeechFallbackTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecordingCheckpointStore(directory: dir)
        let pcm = [Float](repeating: 0.1, count: 1_600).withUnsafeBufferPointer { Data(buffer: $0) }
        store.saveReceivedTake(takeId: "edge-s1", sessionId: "s1", sampleRate: 16_000, edgeName: "Mac", data: pcm)
        var saved: String?
        let sources = [a, c]
        let service = RecoveryService(
            store: store,
            transcribe: { audio in
                let done = try await SpeechSourceChain.run(sources: sources, audioSeconds: audio.durationSeconds, attempt: { source, _ in
                    if source.serverURL != nil { throw URLError(.cannotConnectToHost) }
                    return "in-app words"
                })
                return TranscriptionResult(text: done.value, inferenceMs: nil)
            },
            saveEntry: { text, _, _, _ in saved = text }
        )
        service.refresh()
        await service.transcribe(try XCTUnwrap(service.takes.first))
        XCTAssertEqual(saved, "in-app words")
    }
}
