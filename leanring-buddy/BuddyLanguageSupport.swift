//
//  BuddyLanguageSupport.swift
//  leanring-buddy
//
//  Shared helpers for bilingual Chinese + English speech input and output.
//

import Foundation

enum BuddyLanguageSupport {
    /// ISO 639-1 codes passed to AssemblyAI to bias streaming STT toward expected languages.
    static var bilingualSpeechLanguageCodes: [String] {
        if let configuredLanguageCodes = AppBundleConfiguration
            .stringValue(forKey: "VoiceSpeechLanguageCodes") {
            let parsedLanguageCodes = configuredLanguageCodes
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }

            if !parsedLanguageCodes.isEmpty {
                return parsedLanguageCodes
            }
        }

        return ["en", "zh"]
    }

    /// ElevenLabs model that supports low-latency bilingual zh+en synthesis.
    static let defaultTTSModelIdentifier = "eleven_flash_v2_5"

    /// Returns an ISO 639-1 language code when text is predominantly one language.
    /// Returns nil for mixed zh+en text so the TTS model can auto-detect per sentence.
    static func preferredTTSLanguageCode(for text: String) -> String? {
        var cjkCharacterCount = 0
        var latinLetterCount = 0

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF:
                cjkCharacterCount += 1
            case 0x41...0x5A, 0x61...0x7A:
                latinLetterCount += 1
            default:
                break
            }
        }

        let meaningfulCharacterCount = cjkCharacterCount + latinLetterCount
        guard meaningfulCharacterCount > 0 else { return nil }

        let cjkRatio = Double(cjkCharacterCount) / Double(meaningfulCharacterCount)

        if cjkRatio >= 0.55 {
            return "zh"
        }

        if cjkRatio <= 0.15 {
            return "en"
        }

        return nil
    }

    /// Context prompt for cloud STT providers to improve zh+en recognition.
    static func bilingualTranscriptionContextPrompt(keyterms: [String]) -> String? {
        let normalizedKeyterms = keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if normalizedKeyterms.isEmpty {
            return """
            Bilingual push-to-talk transcript in English and/or Mandarin Chinese. \
            Preserve code-switching; do not translate between languages.
            """
        }

        return """
        Bilingual push-to-talk transcript in English and/or Mandarin Chinese. \
        Preserve code-switching; do not translate between languages. \
        Expect product names, technical terms, and app-specific vocabulary such as: \
        \(normalizedKeyterms.joined(separator: ", ")).
        """
    }
}
