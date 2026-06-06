import Foundation

/// Unified LLM service supporting OpenAI-compatible chat completion APIs (Berget, Ollama).
/// Streams responses token-by-token via an AsyncThrowingStream.
final class LLMService: Sendable {
    
    enum Provider: String, Sendable {
        case berget
        case ollama
    }
    
    enum LLMError: LocalizedError {
        case noAPIKey
        case invalidURL
        case httpError(Int, String?)
        case noContent
        case streamingFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "API key is required for this provider"
            case .invalidURL:
                return "Invalid API URL"
            case .httpError(let code, let message):
                return "HTTP \(code): \(message ?? "Unknown error")"
            case .noContent:
                return "No content in response"
            case .streamingFailed(let reason):
                return "Streaming failed: \(reason)"
            }
        }
    }
    
    /// Sends a chat completion request and streams the response text.
    ///
    /// - Parameters:
    ///   - systemPrompt: The system prompt (selected prompt + additional info)
    ///   - userMessage: The transcription text
    ///   - provider: Which LLM provider to use
    ///   - model: The model ID (e.g. "meta-llama/Llama-3.3-70B-Instruct")
    ///   - apiKey: API key (required for Berget, ignored for Ollama)
    ///   - ollamaHost: Ollama base URL (default localhost:11434)
    /// - Returns: An AsyncThrowingStream of String tokens
    func streamCompletion(
        systemPrompt: String,
        userMessage: String,
        provider: Provider,
        model: String,
        apiKey: String = "",
        ollamaHost: String = "http://127.0.0.1:11434"
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let baseURL: String
                    switch provider {
                    case .berget:
                        guard !apiKey.isEmpty else {
                            continuation.finish(throwing: LLMError.noAPIKey)
                            return
                        }
                        baseURL = "https://api.berget.ai/v1"
                    case .ollama:
                        baseURL = ollamaHost + "/v1"
                    }
                    
                    guard let url = URL(string: "\(baseURL)/chat/completions") else {
                        continuation.finish(throwing: LLMError.invalidURL)
                        return
                    }
                    
                    // Build request body
                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "messages": [
                            ["role": "system", "content": systemPrompt],
                            ["role": "user", "content": userMessage]
                        ]
                    ]
                    
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if provider == .berget {
                        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    request.timeoutInterval = 300
                    
                    // Use URLSession bytes for streaming
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: LLMError.httpError(0, "Invalid response"))
                        return
                    }
                    
                    guard (200...299).contains(httpResponse.statusCode) else {
                        // Try to read error body
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                        }
                        continuation.finish(throwing: LLMError.httpError(httpResponse.statusCode, errorBody))
                        return
                    }
                    
                    // Parse SSE stream
                    for try await line in bytes.lines {
                        guard !Task.isCancelled else {
                            continuation.finish()
                            return
                        }
                        
                        // SSE format: "data: {...}"
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonString = String(line.dropFirst(6))
                        
                        // Check for stream end
                        if jsonString == "[DONE]" {
                            break
                        }
                        
                        // Parse the JSON chunk
                        guard let data = jsonString.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String else {
                            continue
                        }
                        
                        continuation.yield(content)
                    }
                    
                    continuation.finish()
                } catch {
                    if !Task.isCancelled {
                        continuation.finish(throwing: error)
                    }
                }
            }
            
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Default system prompt for speaker auto-naming. Exposed so it can seed an
    /// editable user setting.
    static let defaultSpeakerNamingPrompt = """
    You identify speaker names in a transcript. The transcript uses generic labels \
    like "Speaker 1". Using only evidence in the text (self-introductions such as \
    "I'm Anna", or direct address such as "Bob, what do you think?"), map labels to \
    real first names. Respond with ONLY a JSON object mapping label to name, e.g. \
    {"Speaker 1":"Anna"}. Omit any speaker you are not confident about. No prose.
    """

    /// Asks the LLM to infer real speaker names from a labeled transcript.
    /// Returns a map from speaker label (e.g. "Speaker 1") to a name (e.g. "Anna").
    /// Only includes labels the model is confident about; returns `[:]` on any failure.
    /// This is additive — callers should treat an empty result as "keep generic labels".
    /// `systemPrompt` overrides the built-in prompt when non-empty.
    func suggestSpeakerNames(
        utterances: [DiarizedUtterance],
        provider: Provider,
        model: String,
        apiKey: String = "",
        ollamaHost: String = "http://127.0.0.1:11434",
        systemPrompt: String? = nil
    ) async -> [String: String] {
        guard !utterances.isEmpty else { return [:] }

        // Build a compact labeled transcript keyed by the stable speaker ID.
        let transcript = utterances
            .map { "\($0.speakerID): \($0.text)" }
            .joined(separator: "\n")

        let trimmedCustom = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let system = (trimmedCustom?.isEmpty == false ? trimmedCustom! : Self.defaultSpeakerNamingPrompt)

        var collected = ""
        do {
            for try await chunk in streamCompletion(
                systemPrompt: system, userMessage: transcript,
                provider: provider, model: model, apiKey: apiKey, ollamaHost: ollamaHost
            ) {
                collected += chunk
            }
        } catch {
            return [:]
        }

        // Extract the first {...} JSON object from the response.
        guard let start = collected.firstIndex(of: "{"),
              let end = collected.lastIndex(of: "}"),
              start < end else { return [:] }
        let json = String(collected[start...end])
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }

        var result: [String: String] = [:]
        for (key, value) in raw {
            if let name = value as? String,
               !name.trimmingCharacters(in: .whitespaces).isEmpty {
                result[key] = name
            }
        }
        return result
    }
}
