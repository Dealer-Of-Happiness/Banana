//
//  CloudAIService.swift
//  AIGoodbye
//
//  Cloud AI integrations (ChatGPT, Claude, Google)
//

import Foundation

actor CloudAIService {
    // Store settings values directly to avoid actor isolation issues
    private let chatGPTEnabled: Bool
    private let chatGPTApiKey: String?
    private let claudeEnabled: Bool
    private let claudeApiKey: String?
    private let googleEnabled: Bool
    private let googleApiKey: String?
    private let temperature: Double

    init(
        chatGPTEnabled: Bool = false,
        chatGPTApiKey: String? = nil,
        claudeEnabled: Bool = false,
        claudeApiKey: String? = nil,
        googleEnabled: Bool = false,
        googleApiKey: String? = nil,
        temperature: Double = 0.7
    ) {
        self.chatGPTEnabled = chatGPTEnabled
        self.chatGPTApiKey = chatGPTApiKey
        self.claudeEnabled = claudeEnabled
        self.claudeApiKey = claudeApiKey
        self.googleEnabled = googleEnabled
        self.googleApiKey = googleApiKey
        self.temperature = temperature
    }

    // MARK: - Generate Response

    func generate(
        prompt: String,
        provider: CloudAIProvider? = nil,
        history: [(role: String, content: String)] = []
    ) -> AsyncThrowingStream<String, Error> {
        let selectedProvider = provider ?? getDefaultProvider()

        switch selectedProvider {
        case .chatGPT:
            return streamOpenAI(prompt: prompt, history: history)
        case .claude:
            return streamAnthropic(prompt: prompt, history: history)
        case .google:
            return streamGoogle(prompt: prompt, history: history)
        }
    }

    private func getDefaultProvider() -> CloudAIProvider {
        if chatGPTEnabled && chatGPTApiKey != nil {
            return .chatGPT
        }
        if claudeEnabled && claudeApiKey != nil {
            return .claude
        }
        if googleEnabled && googleApiKey != nil {
            return .google
        }
        return .chatGPT
    }

    // MARK: - OpenAI (ChatGPT)

    private func streamOpenAI(
        prompt: String,
        history: [(role: String, content: String)]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let apiKey = self.chatGPTApiKey else {
                    continuation.finish(throwing: CloudAIError.missingApiKey)
                    return
                }

                var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
                request.httpMethod = "POST"
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                var messages: [[String: String]] = history.map { ["role": $0.role, "content": $0.content] }
                messages.append(["role": "user", "content": prompt])

                let body: [String: Any] = [
                    "model": "gpt-4o-mini",
                    "messages": messages,
                    "stream": true,
                    "max_tokens": 2048,
                    "temperature": self.temperature
                ]

                request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        continuation.finish(throwing: CloudAIError.requestFailed)
                        return
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

    // MARK: - Anthropic (Claude)

    private func streamAnthropic(
        prompt: String,
        history: [(role: String, content: String)]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let apiKey = self.claudeApiKey else {
                    continuation.finish(throwing: CloudAIError.missingApiKey)
                    return
                }

                var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                request.httpMethod = "POST"
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                var messages: [[String: String]] = history.map { ["role": $0.role, "content": $0.content] }
                messages.append(["role": "user", "content": prompt])

                let body: [String: Any] = [
                    "model": "claude-3-haiku-20240307",
                    "messages": messages,
                    "stream": true,
                    "max_tokens": 2048
                ]

                request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        continuation.finish(throwing: CloudAIError.requestFailed)
                        return
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

    // MARK: - Google AI

    private func streamGoogle(
        prompt: String,
        history: [(role: String, content: String)]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let apiKey = self.googleApiKey else {
                    continuation.finish(throwing: CloudAIError.missingApiKey)
                    return
                }

                // URL-encode the API key to handle special characters safely
                guard let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                      let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:streamGenerateContent?key=\(encodedKey)") else {
                    continuation.finish(throwing: CloudAIError.requestFailed)
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                var contents: [[String: Any]] = history.map { message in
                    [
                        "role": message.role == "user" ? "user" : "model",
                        "parts": [["text": message.content]]
                    ]
                }
                contents.append([
                    "role": "user",
                    "parts": [["text": prompt]]
                ])

                let body: [String: Any] = [
                    "contents": contents
                ]

                request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        continuation.finish(throwing: CloudAIError.requestFailed)
                        return
                    }

                    for try await line in bytes.lines {
                        if let data = line.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let candidates = json["candidates"] as? [[String: Any]],
                           let content = candidates.first?["content"] as? [String: Any],
                           let parts = content["parts"] as? [[String: Any]],
                           let text = parts.first?["text"] as? String {
                            continuation.yield(text)
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

enum CloudAIError: LocalizedError {
    case missingApiKey
    case requestFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingApiKey:
            return "API key not configured"
        case .requestFailed:
            return "Request failed"
        case .invalidResponse:
            return "Invalid response"
        }
    }
}
