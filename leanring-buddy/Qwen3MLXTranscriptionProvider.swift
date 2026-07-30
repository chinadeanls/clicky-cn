//
//  Qwen3MLXTranscriptionProvider.swift
//  leanring-buddy
//
//  Local bilingual STT via mlx-qwen3-asr HTTP server (Apple Silicon + MLX).
//

import AVFoundation
import Foundation

struct Qwen3MLXTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

final class Qwen3MLXTranscriptionProvider: BuddyTranscriptionProvider {
    private let serverBaseURL: String
    private let apiKey: String

    let displayName = "Qwen3-ASR (MLX)"
    let requiresSpeechRecognitionPermission = false

    init(
        serverBaseURL: String? = AppBundleConfiguration.stringValue(forKey: "Qwen3ASRServerURL"),
        apiKey: String? = AppBundleConfiguration.stringValue(forKey: "Qwen3ASRServerAPIKey")
    ) {
        self.serverBaseURL = (serverBaseURL ?? "http://127.0.0.1:8765")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey ?? "local"
    }

    var isConfigured: Bool { true }

    var unavailableExplanation: String? { nil }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        Qwen3MLXTranscriptionSession(
            serverBaseURL: serverBaseURL,
            apiKey: apiKey,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class Qwen3MLXTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 12.0

    private static let targetSampleRate = 16_000

    private let transcriptionURL: URL
    private let apiKey: String
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.clicky.qwen3.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(targetSampleRate)
    )
    private let urlSession: URLSession

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var transcriptionTask: Task<Void, Never>?

    init(
        serverBaseURL: String,
        apiKey: String,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.transcriptionURL = URL(string: "\(serverBaseURL)/v1/audio/transcriptions")!
        self.apiKey = apiKey
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError

        let urlSessionConfiguration = URLSessionConfiguration.default
        urlSessionConfiguration.timeoutIntervalForRequest = 120
        urlSessionConfiguration.timeoutIntervalForResource = 180
        self.urlSession = URLSession(configuration: urlSessionConfiguration)
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let pcm16AudioData = self.bufferedPCM16AudioData
            self.transcriptionTask = Task { [weak self] in
                await self?.transcribeBufferedAudio(pcm16AudioData)
            }
        }
    }

    func cancel() {
        transcriptionTask?.cancel()
        stateQueue.async {
            self.isCancelled = true
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }
        urlSession.invalidateAndCancel()
    }

    private func transcribeBufferedAudio(_ pcm16AudioData: Data) async {
        guard !Task.isCancelled else { return }

        let shouldSkip = stateQueue.sync {
            isCancelled || pcm16AudioData.isEmpty
        }
        if shouldSkip {
            deliverFinalTranscript("")
            return
        }

        do {
            let transcript = try await requestTranscription(for: pcm16AudioData)
            guard !Task.isCancelled, !stateQueue.sync(execute: { isCancelled }) else { return }

            if !transcript.isEmpty {
                onTranscriptUpdate(transcript)
            }
            deliverFinalTranscript(transcript)
        } catch {
            guard !Task.isCancelled, !stateQueue.sync(execute: { isCancelled }) else { return }
            print("[Qwen3 Transcription] ❌ Upload failed (audio size: \(pcm16AudioData.count) bytes): \(error.localizedDescription)")
            onError(error)
        }
    }

    private func requestTranscription(for pcm16AudioData: Data) async throws -> String {

        let wavAudioData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: pcm16AudioData,
            sampleRate: Self.targetSampleRate
        )

        let temporaryWAVURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-qwen3-input-\(UUID().uuidString).wav")
        try wavAudioData.write(to: temporaryWAVURL)
        defer { try? FileManager.default.removeItem(at: temporaryWAVURL) }

        var request = URLRequest(url: transcriptionURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"voice-input.wav\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(wavAudioData)
        body.appendString("\r\n")
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.appendString("Qwen/Qwen3-ASR-0.6B\r\n")
        body.appendString("--\(boundary)--\r\n")
        request.httpBody = body

        let (responseData, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw Qwen3MLXTranscriptionProviderError(message: "Invalid response from Qwen3-ASR server.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw Qwen3MLXTranscriptionProviderError(
                message: "Qwen3-ASR error (\(httpResponse.statusCode)): \(errorBody)"
            )
        }

        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let text = json["text"] as? String {
            return Self.cleanTranscript(text)
        }

        if let plainText = String(data: responseData, encoding: .utf8), !plainText.isEmpty {
            return Self.cleanTranscript(plainText)
        }

        throw Qwen3MLXTranscriptionProviderError(message: "Empty transcript from Qwen3-ASR server.")
    }

    private static func cleanTranscript(_ rawText: String) -> String {
        if let asrRange = rawText.range(of: "<asr_text>") {
            return String(rawText[asrRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if rawText.lowercased().hasPrefix("language ") {
            let parts = rawText.split(separator: ">", maxSplits: 1).map(String.init)
            if parts.count == 2 { return parts[1].trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        transcriptionTask?.cancel()
        urlSession.invalidateAndCancel()
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(string.data(using: .utf8)!)
    }
}
