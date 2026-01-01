//
//  OnlineAIConnector.swift
//  BananaAI
//
//  Connect to online AI services (ChatGPT, Claude) when enabled
//

import Foundation

/// Connector for online AI services
actor OnlineAIConnector {
    private let settings: SettingsManager

    init(settings: SettingsManager) {
        self.settings = settings
    }

    // MARK: - ChatGPT (OpenAI)

    func queryOpenAI(
        messages: [ChatMessage],
        model: String = "gpt-4o-mini"
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let apiKey = settings.apiKey, !apiKey.isEmpty else {
            throw OnlineAIError.missingAPIKey
        }

        let url = URL(string: "https://api.openai.com/v1/chat/completions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let formattedMessages = messages.map { msg -> [String: String] in
            let role: String
            switch msg.role {
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .system: role = "system"
            }
            return ["role": role, "content": msg.content]
        }

        let body: [String: Any] = [
            "model": model,
            "messages": formattedMessages,
            "stream": true,
            "max_tokens": settings.maxTokens,
            "temperature": settings.temperature
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        throw OnlineAIError.requestFailed
                    }

                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let jsonString = String(line.dropFirst(6))
                            if jsonString == "[DONE]" { break }

                            if let data = jsonString.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let choices = json["choices"] as? [[String: Any]],
                               let delta = choices.first?["delta"] as? [String: Any],
                               let content = delta["content"] as? String {
                                continuation.yield(content)
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Claude (Anthropic)

    func queryAnthropic(
        messages: [ChatMessage],
        model: String = "claude-3-haiku-20240307"
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let apiKey = settings.apiKey, !apiKey.isEmpty else {
            throw OnlineAIError.missingAPIKey
        }

        let url = URL(string: "https://api.anthropic.com/v1/messages")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let formattedMessages = messages.compactMap { msg -> [String: String]? in
            let role: String
            switch msg.role {
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .system: return nil // System handled separately
            }
            return ["role": role, "content": msg.content]
        }

        var body: [String: Any] = [
            "model": model,
            "messages": formattedMessages,
            "max_tokens": settings.maxTokens,
            "stream": true
        ]

        // Add system message if present
        if let systemMessage = messages.first(where: { $0.role == .system }) {
            body["system"] = systemMessage.content
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        throw OnlineAIError.requestFailed
                    }

                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let jsonString = String(line.dropFirst(6))

                            if let data = jsonString.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let type = json["type"] as? String {

                                if type == "content_block_delta",
                                   let delta = json["delta"] as? [String: Any],
                                   let text = delta["text"] as? String {
                                    continuation.yield(text)
                                }

                                if type == "message_stop" {
                                    break
                                }
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Errors

enum OnlineAIError: LocalizedError {
    case missingAPIKey
    case requestFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "API key not configured. Please add your API key in Settings."
        case .requestFailed:
            return "The request to the AI service failed."
        case .invalidResponse:
            return "Received an invalid response from the AI service."
        }
    }
}
