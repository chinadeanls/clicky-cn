//
//  BuddyTTSProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for text-to-speech backends.
//

import Foundation

@MainActor
protocol BuddyTTSProvider: AnyObject {
    var displayName: String { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }
    var isPlaying: Bool { get }

    func speakText(_ text: String) async throws
    func stopPlayback()
}

enum BuddyTTSProviderFactory {
    private enum PreferredProvider: String {
        case apple
        case qwen3MLX = "qwen3"
        case elevenLabs = "elevenlabs"
    }

    static func makeDefaultProvider(workerTTSProxyURL: String) -> any BuddyTTSProvider {
        let provider = resolveProvider(workerTTSProxyURL: workerTTSProxyURL)
        print("🔊 TTS: using \(provider.displayName)")
        return provider
    }

    private static func resolveProvider(workerTTSProxyURL: String) -> any BuddyTTSProvider {
        let preferredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "VoiceTTSProvider")?
            .lowercased()
        let preferredProvider = preferredProviderRawValue.flatMap(PreferredProvider.init(rawValue:))

        let appleProvider = AppleSystemTTSClient()
        let qwen3MLXProvider = Qwen3MLXTTSClient()
        let elevenLabsProvider = ElevenLabsTTSClient(proxyURL: workerTTSProxyURL)

        if preferredProvider == .apple {
            return appleProvider
        }

        if preferredProvider == .elevenLabs {
            return elevenLabsProvider
        }

        if preferredProvider == .qwen3MLX {
            return qwen3MLXProvider
        }

        // Default for local development: no Worker / cloud TTS required.
        if WorkerConfiguration.isUsingLocalDevelopmentProxy {
            return qwen3MLXProvider
        }

        return elevenLabsProvider
    }
}
