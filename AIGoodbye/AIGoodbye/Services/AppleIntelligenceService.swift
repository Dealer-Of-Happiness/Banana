//
//  AppleIntelligenceService.swift
//  AIGoodbye
//
//  Wrapper around Apple's Foundation Models framework (iOS 26+).
//  Provides instant, no-download, on-device text chat on devices with
//  Apple Intelligence. Used as the "Apple Intelligence" engine option and
//  as the instant fallback while a vision model downloads.
//

import Foundation
import Combine

#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class AppleIntelligenceService: ObservableObject {

    enum Availability: Equatable {
        case available
        case unavailable(String)
    }

    @Published private(set) var availability: Availability = .unavailable(
        L10n.text("Apple Intelligence is not available on this device.")
    )

    #if canImport(FoundationModels)
    private var session: LanguageModelSession?
    #endif

    init() {
        refreshAvailability()
    }

    func refreshAvailability() {
        #if DEBUG
        // Test hook: lets the simulator exercise the no-Apple-Intelligence path
        // (iPhone 13-class devices). Launch with AIG_FORCE_NO_AI=1 to activate.
        // Compiled out of release builds entirely.
        if ProcessInfo.processInfo.environment["AIG_FORCE_NO_AI"] == "1" {
            availability = .unavailable(L10n.text("This device doesn't support Apple Intelligence."))
            return
        }
        #endif
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            availability = .available
        case .unavailable(let reason):
            availability = .unavailable(Self.describe(reason))
        @unknown default:
            availability = .unavailable(L10n.text("Apple Intelligence is not available."))
        }
        #endif
    }

    var isAvailable: Bool { availability == .available }

    // MARK: - Session

    /// Start (or restart) a session, optionally seeding condensed history so the
    /// model remembers earlier turns of a reopened conversation.
    func startSession(history: [(role: String, content: String)], instructions baseInstructions: String) {
        #if canImport(FoundationModels)
        guard isAvailable else { return }

        var instructions = baseInstructions
        let trimmed = MLXService.trimHistory(history, tokenBudget: 2500)
        if !trimmed.isEmpty {
            let transcript = trimmed
                .map { "\($0.role == "user" ? "User" : "Assistant"): \($0.content)" }
                .joined(separator: "\n")
            instructions += "\n\nEarlier in this conversation:\n\(transcript)"
        }

        session = LanguageModelSession(instructions: instructions)
        session?.prewarm()
        #endif
    }

    var hasSession: Bool {
        #if canImport(FoundationModels)
        return session != nil
        #else
        return false
        #endif
    }

    /// Drop the live session. The next conversation turn rebuilds it with
    /// history via startSession — mirrors MLXService.dropSession, so reopened
    /// conversations get their past turns seeded correctly.
    func dropSession() {
        #if canImport(FoundationModels)
        session = nil
        #endif
    }

    // MARK: - Generation

    /// Stream a response with snapshot semantics (each event is the full text so far).
    /// Only the newest snapshot is buffered; older ones are superseded anyway.
    func respondStream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            #if canImport(FoundationModels)
            guard let session = self.session else {
                continuation.finish(throwing: AppleIntelligenceError.notReady)
                return
            }

            let task = Task {
                do {
                    var lastText = ""
                    let stream = session.streamResponse(to: prompt)
                    for try await partial in stream {
                        if Task.isCancelled { break }
                        let text = String(describing: partial.content)
                        // Foundation Models streams cumulative snapshots; if a
                        // snapshot ever revises earlier text, trust the newest
                        // snapshot rather than concatenating (which would
                        // duplicate the whole response).
                        lastText = text
                        continuation.yield(lastText)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AppleIntelligenceError.generation(Self.friendlyMessage(error)))
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
            #else
            continuation.finish(throwing: AppleIntelligenceError.notReady)
            #endif
        }
    }

    // MARK: - Helpers

    #if canImport(FoundationModels)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return L10n.text("This device doesn't support Apple Intelligence.")
        case .appleIntelligenceNotEnabled:
            return L10n.text("Apple Intelligence is turned off. Enable it in Settings to use the built-in model.")
        case .modelNotReady:
            return L10n.text("Apple Intelligence is still preparing on this device. Try again in a few minutes.")
        @unknown default:
            return L10n.text("Apple Intelligence is not available right now.")
        }
    }

    private static func friendlyMessage(_ error: Error) -> String {
        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .guardrailViolation:
                return L10n.text("Apple Intelligence declined this request. Try rephrasing, or switch to a downloaded model in Settings.")
            case .exceededContextWindowSize:
                return L10n.text("This conversation is too long for Apple Intelligence. Start a new chat or switch to a downloaded model.")
            default:
                return error.localizedDescription
            }
        }
        return error.localizedDescription
    }
    #endif
}

enum AppleIntelligenceError: LocalizedError {
    case notReady
    case generation(String)

    var errorDescription: String? {
        switch self {
        case .notReady:
            return L10n.text("Apple Intelligence isn't ready. Choose a downloaded model in Settings.")
        case .generation(let message):
            return message
        }
    }
}
