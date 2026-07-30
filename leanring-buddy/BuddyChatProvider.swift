//
//  BuddyChatProvider.swift
//  leanring-buddy
//
//  Vision + streaming chat via local pi-mono ai-server (Ollama / Gemma).
//

import Foundation

protocol BuddyChatProvider: AnyObject {
    var displayName: String { get }
    var model: String { get set }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval)
}

enum BuddyChatProviderFactory {
    static func makeDefaultProvider(initialModel: String) -> any BuddyChatProvider {
        let provider = PiMonoChatProvider(model: initialModel)
        print("🤖 Chat: using \(provider.displayName) (\(provider.model))")
        return provider
    }
}

final class PiMonoChatProvider: BuddyChatProvider {
    let displayName = "pi-mono (Gemma local)"
    private let client: OpenAICompatibleChatAPI

    var model: String {
        get { client.model }
        set { client.model = newValue }
    }

    init(model: String) {
        client = OpenAICompatibleChatAPI(
            chatCompletionsURL: PiMonoChatConfiguration.chatCompletionsURL,
            model: PiMonoChatConfiguration.normalizedModelID(model),
            authToken: PiMonoChatConfiguration.authToken
        )
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        try await client.analyzeImageStreaming(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            onTextChunk: onTextChunk
        )
    }
}

enum PiMonoChatConfiguration {
    static var piMonoRoot: String {
        AppBundleConfiguration.stringValue(forKey: "PiMonoRoot") ?? "/Users/dean/Projects/pi-mono"
    }

    static var defaultProvider: String {
        AppBundleConfiguration.stringValue(forKey: "PiMonoChatProvider") ?? "ollama"
    }

    static var baseURL: String {
        if let configuredBaseURL = AppBundleConfiguration.stringValue(forKey: "PiMonoChatBaseURL"),
           !configuredBaseURL.isEmpty {
            return configuredBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        return "http://127.0.0.1:4141"
    }

    static var chatCompletionsURL: String { "\(baseURL)/v1/chat/completions" }

    static var authToken: String? {
        let token = AppBundleConfiguration.stringValue(forKey: "PiMonoChatAuthToken")
        guard let token, !token.isEmpty else { return nil }
        return token
    }

    static var defaultModel: String {
        AppBundleConfiguration.stringValue(forKey: "PiMonoChatModel") ?? "gemma4:e4b"
    }

    static func normalizedModelID(_ model: String) -> String {
        if model.contains("/") {
            return model
        }
        return "\(defaultProvider)/\(model)"
    }
}
