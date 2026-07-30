//
//  OpenAICompatibleChatAPI.swift
//  leanring-buddy
//
//  OpenAI Chat Completions client with SSE streaming and vision support.
//  Used for local pi-mono / Gemini proxies.
//

import Foundation

final class OpenAICompatibleChatAPI {
    private static let tlsWarmupLock = NSLock()
    private static var warmedUpHosts = Set<String>()

    private let chatCompletionsURL: URL
    private let authToken: String?
    private let session: URLSession
    var model: String

    init(chatCompletionsURL: String, model: String, authToken: String? = nil) {
        self.chatCompletionsURL = URL(string: chatCompletionsURL)!
        self.model = model
        self.authToken = authToken

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        warmUpTLSConnectionIfNeeded()
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        var request = makeAPIRequest()

        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
            let mediaType = Self.detectImageMediaType(for: image.data)
            contentBlocks.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:\(mediaType);base64,\(image.data.base64EncodedString())"
                ]
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "stream": true,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Local LLM streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw Self.makeError(code: -1, message: "Invalid HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw Self.makeError(code: httpResponse.statusCode, message: "API Error (\(httpResponse.statusCode)): \(errorBody)")
        }

        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            if let errorPayload = eventPayload["error"] as? [String: Any],
               let message = errorPayload["message"] as? String {
                throw Self.makeError(code: httpResponse.statusCode, message: message)
            }

            guard let choices = eventPayload["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let delta = firstChoice["delta"] as? [String: Any],
                  let textChunk = delta["content"] as? String,
                  !textChunk.isEmpty else {
                continue
            }

            accumulatedResponseText += textChunk
            let currentAccumulatedText = accumulatedResponseText
            await onTextChunk(currentAccumulatedText)
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    private func makeAPIRequest() -> URLRequest {
        var request = URLRequest(url: chatCompletionsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authToken, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        return "image/jpeg"
    }

    private func warmUpTLSConnectionIfNeeded() {
        guard let host = chatCompletionsURL.host else { return }

        Self.tlsWarmupLock.lock()
        let shouldWarmUp = !Self.warmedUpHosts.contains(host)
        if shouldWarmUp {
            Self.warmedUpHosts.insert(host)
        }
        Self.tlsWarmupLock.unlock()

        guard shouldWarmUp else { return }

        var warmupURLComponents = URLComponents(url: chatCompletionsURL, resolvingAgainstBaseURL: false)
        warmupURLComponents?.path = "/health"
        warmupURLComponents?.query = nil
        warmupURLComponents?.fragment = nil

        guard let warmupURL = warmupURLComponents?.url else { return }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "GET"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in }.resume()
    }

    private static func makeError(code: Int, message: String) -> NSError {
        NSError(
            domain: "OpenAICompatibleChatAPI",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
