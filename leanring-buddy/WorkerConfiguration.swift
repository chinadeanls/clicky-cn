//
//  WorkerConfiguration.swift
//  leanring-buddy
//
//  Reads Cloudflare Worker proxy URL from Info.plist for local or deployed backends.
//

import Foundation

enum WorkerConfiguration {
    private static let placeholderWorkerHost = "your-worker-name.your-subdomain.workers.dev"

    static var baseURL: String {
        if let configuredBaseURL = AppBundleConfiguration.stringValue(forKey: "WorkerBaseURL"),
           !configuredBaseURL.isEmpty,
           !configuredBaseURL.contains(placeholderWorkerHost) {
            return configuredBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        return "http://localhost:8787"
    }

    static var ttsProxyURL: String { "\(baseURL)/tts" }
    static var transcribeTokenProxyURL: String { "\(baseURL)/transcribe-token" }

    static var isUsingLocalDevelopmentProxy: Bool {
        baseURL.hasPrefix("http://localhost") || baseURL.hasPrefix("http://127.0.0.1")
    }
}
