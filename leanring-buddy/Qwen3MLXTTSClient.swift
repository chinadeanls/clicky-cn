//
//  Qwen3MLXTTSClient.swift
//  leanring-buddy
//
//  Local bilingual TTS via Qwen3-TTS MLX HTTP sidecar (Apple Silicon).
//

import AVFoundation
import Foundation

struct Qwen3MLXTTSClientError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

@MainActor
final class Qwen3MLXTTSClient: BuddyTTSProvider {
    let displayName = "Qwen3-TTS (MLX)"

    private let serverBaseURL: String
    private let apiKey: String
    private let chineseSpeaker: String
    private let englishSpeaker: String
    private let session: URLSession

    private var audioPlayer: AVAudioPlayer?

    init(
        serverBaseURL: String? = AppBundleConfiguration.stringValue(forKey: "Qwen3TTSServerURL"),
        apiKey: String? = AppBundleConfiguration.stringValue(forKey: "Qwen3TTSServerAPIKey"),
        chineseSpeaker: String? = AppBundleConfiguration.stringValue(forKey: "Qwen3TTSVoiceZH"),
        englishSpeaker: String? = AppBundleConfiguration.stringValue(forKey: "Qwen3TTSVoiceEN")
    ) {
        self.serverBaseURL = (serverBaseURL ?? "http://127.0.0.1:8766")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey ?? "local"
        self.chineseSpeaker = chineseSpeaker ?? "Serena"
        self.englishSpeaker = englishSpeaker ?? "Ryan"

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        self.session = URLSession(configuration: configuration)
    }

    var isConfigured: Bool { true }

    var unavailableExplanation: String? { nil }

    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    func speakText(_ text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        stopPlayback()

        let speechURL = URL(string: "\(serverBaseURL)/v1/audio/speech")!
        var request = URLRequest(url: speechURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/wav", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (voice, language) = synthesisParameters(for: trimmedText)
        let body: [String: Any] = [
            "input": trimmedText,
            "voice": voice,
            "language": language,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw Qwen3MLXTTSClientError(message: "Invalid response from Qwen3-TTS server.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw Qwen3MLXTTSClientError(
                message: "Qwen3-TTS error (\(httpResponse.statusCode)): \(errorBody)"
            )
        }

        guard !data.isEmpty else {
            throw Qwen3MLXTTSClientError(message: "Qwen3-TTS returned empty audio.")
        }

        try Task.checkCancellation()

        let player = try AVAudioPlayer(data: data)
        audioPlayer = player
        player.play()
        print("🔊 Qwen3-TTS: playing \(player.duration)s audio (\(voice), \(language))")
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    private func synthesisParameters(for text: String) -> (voice: String, language: String) {
        switch BuddyLanguageSupport.preferredTTSLanguageCode(for: text) {
        case "zh":
            return (chineseSpeaker, "Chinese")
        case "en":
            return (englishSpeaker, "English")
        default:
            return (chineseSpeaker, "Auto")
        }
    }
}
