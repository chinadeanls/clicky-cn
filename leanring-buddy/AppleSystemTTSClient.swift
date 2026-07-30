//
//  AppleSystemTTSClient.swift
//  leanring-buddy
//
//  Local text-to-speech via macOS NSSpeechSynthesizer (no network, no API keys).
//

import AppKit
import Foundation

@MainActor
final class AppleSystemTTSClient: BuddyTTSProvider {
    let displayName = "Apple (local)"
    var isConfigured: Bool { true }
    var unavailableExplanation: String? { nil }

    private var synthesizer: NSSpeechSynthesizer?

    func speakText(_ text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        synthesizer?.stopSpeaking()
        let speechSynthesizer = NSSpeechSynthesizer()
        synthesizer = speechSynthesizer

        if BuddyLanguageSupport.preferredTTSLanguageCode(for: trimmedText) == "zh" {
            if let chineseVoice = NSSpeechSynthesizer.availableVoices.first(where: { voiceID in
                let attributes = NSSpeechSynthesizer.attributes(forVoice: voiceID)
                let language = attributes[.localeIdentifier] as? String ?? ""
                return language.hasPrefix("zh")
            }) {
                speechSynthesizer.setVoice(chineseVoice)
            }
        }

        speechSynthesizer.startSpeaking(trimmedText)
        print("🔊 Apple TTS: speaking \(trimmedText.prefix(80))...")
    }

    var isPlaying: Bool {
        synthesizer?.isSpeaking ?? false
    }

    func stopPlayback() {
        synthesizer?.stopSpeaking()
        synthesizer = nil
    }
}
