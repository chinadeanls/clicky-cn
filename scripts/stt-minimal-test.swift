#!/usr/bin/env swift
//
// Minimal bilingual STT smoke test using Apple Speech (no API keys).
//
// Usage:
//   ./scripts/stt-minimal-test.swift --mic 5          # record 5s from mic, then print transcript
//   ./scripts/stt-minimal-test.swift --file audio.wav # transcribe an existing WAV/AIFF/M4A file
//

import AVFoundation
import Foundation
import Speech

enum MinimalSTTError: Error, CustomStringConvertible {
    case usage
    case permissionDenied(String)
    case recognizerUnavailable
    case noTranscript
    case fileNotFound(String)

    var description: String {
        switch self {
        case .usage:
            return """
            Usage:
              stt-minimal-test.swift --mic <seconds>
              stt-minimal-test.swift --file <audio-path>
            """
        case .permissionDenied(let detail):
            return "Permission denied: \(detail)"
        case .recognizerUnavailable:
            return "No available SFSpeechRecognizer for zh-CN / en-US."
        case .noTranscript:
            return "Recognition finished with an empty transcript."
        case .fileNotFound(let path):
            return "Audio file not found: \(path)"
        }
    }
}

@MainActor
final class MinimalSTTRunner {
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func runFromMicrophone(durationSeconds: TimeInterval) async throws -> String {
        try await requestPermissions()

        guard let speechRecognizer = makeSpeechRecognizer() else {
            throw MinimalSTTError.recognizerUnavailable
        }

        print("🎙️ Recording for \(durationSeconds)s — speak now (中文/English)...")

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.taskHint = .dictation
        recognitionRequest.addsPunctuation = true
        if speechRecognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
        }
        self.recognitionRequest = recognitionRequest

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        return try await withCheckedThrowingContinuation { continuation in
            var latestText = ""
            var hasResumed = false

            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { result, error in
                if let result {
                    latestText = result.bestTranscription.formattedString
                    if !latestText.isEmpty {
                        print("… \(latestText)")
                    }

                    if result.isFinal, !hasResumed {
                        hasResumed = true
                        continuation.resume(returning: latestText)
                    }
                }

                if let error, !hasResumed {
                    if !latestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        hasResumed = true
                        continuation.resume(returning: latestText)
                    } else {
                        hasResumed = true
                        continuation.resume(throwing: error)
                    }
                }
            }

            inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
                recognitionRequest.append(buffer)
            }

            do {
                audioEngine.prepare()
                try audioEngine.start()
            } catch {
                if !hasResumed {
                    hasResumed = true
                    continuation.resume(throwing: error)
                }
                return
            }

            Task {
                try await Task.sleep(nanoseconds: UInt64(durationSeconds * 1_000_000_000))
                recognitionRequest.endAudio()
                inputNode.removeTap(onBus: 0)
                audioEngine.stop()

                try await Task.sleep(nanoseconds: 2_000_000_000)
                if !hasResumed {
                    hasResumed = true
                    if latestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        continuation.resume(throwing: MinimalSTTError.noTranscript)
                    } else {
                        continuation.resume(returning: latestText)
                    }
                }
            }
        }
    }

    func runFromAudioFile(at audioFilePath: String) async throws -> String {
        try await requestPermissions()

        guard FileManager.default.fileExists(atPath: audioFilePath) else {
            throw MinimalSTTError.fileNotFound(audioFilePath)
        }

        guard let speechRecognizer = makeSpeechRecognizer() else {
            throw MinimalSTTError.recognizerUnavailable
        }

        let audioFileURL = URL(fileURLWithPath: audioFilePath)
        let recognitionRequest = SFSpeechURLRecognitionRequest(url: audioFileURL)
        recognitionRequest.shouldReportPartialResults = false
        recognitionRequest.taskHint = .dictation
        recognitionRequest.addsPunctuation = true
        if speechRecognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
        }

        print("🎧 Transcribing file: \(audioFilePath)")

        return try await withCheckedThrowingContinuation { continuation in
            speechRecognizer.recognitionTask(with: recognitionRequest) { result, error in
                if let result {
                    let transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        continuation.resume(returning: transcript)
                    }
                    return
                }

                if let error {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func requestPermissions() async throws {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard speechStatus == .authorized else {
            throw MinimalSTTError.permissionDenied(
                "Speech recognition not authorized (status=\(speechStatus.rawValue)). Enable in System Settings → Privacy → Speech Recognition."
            )
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
            guard micGranted else {
                throw MinimalSTTError.permissionDenied("Microphone access denied.")
            }
        default:
            throw MinimalSTTError.permissionDenied(
                "Microphone not authorized. Enable in System Settings → Privacy → Microphone for Terminal/Cursor."
            )
        }
    }

    private func makeSpeechRecognizer() -> SFSpeechRecognizer? {
        let preferredLocales = [
            Locale(identifier: "zh-CN"),
            Locale(identifier: "zh-Hans"),
            Locale(identifier: "en-US"),
            Locale.autoupdatingCurrent,
        ]

        for locale in preferredLocales {
            if let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable {
                print("✅ Using recognizer locale: \(locale.identifier)")
                return recognizer
            }
        }

        return nil
    }
}

func parseArguments() throws -> (mode: String, value: String) {
    let arguments = CommandLine.arguments.dropFirst()
    guard arguments.count == 2 else {
        throw MinimalSTTError.usage
    }

    let mode = arguments.first!
    let value = arguments.dropFirst().first!
    guard mode == "--mic" || mode == "--file" else {
        throw MinimalSTTError.usage
    }
    return (mode, value)
}

@MainActor
func main() async {
    do {
        let (mode, value) = try parseArguments()
        let runner = MinimalSTTRunner()
        let transcript: String

        if mode == "--mic" {
            guard let durationSeconds = Double(value), durationSeconds > 0 else {
                throw MinimalSTTError.usage
            }
            transcript = try await runner.runFromMicrophone(durationSeconds: durationSeconds)
        } else {
            transcript = try await runner.runFromAudioFile(at: value)
        }

        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            throw MinimalSTTError.noTranscript
        }

        print("\n✅ Final transcript:\n\(trimmedTranscript)\n")
    } catch {
        fputs("❌ \(error)\n", stderr)
        exit(1)
    }
}

await main()
