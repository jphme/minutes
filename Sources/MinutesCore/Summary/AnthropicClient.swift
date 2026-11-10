import Foundation

private let log = MinutesLog("Anthropic")

/// Streams a completion from the Anthropic Messages API.
/// Raw HTTP because there is no official Anthropic SDK for Swift; request shape per the API reference.
public struct AnthropicClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2026-10-21"

    public var apiKey: String
    public var model: String
    /// "low" … "max", or nil for the model's default.
    public var effort: String?

    public init(apiKey: String, model: String, effort: String? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
    }

    public struct Completion: Sendable {
        public var text: String
        /// Model that actually answered (differs from the requested one after a server-side fallback).
        public var model: String
        public var inputTokens: Int
        public var outputTokens: Int
        public var seconds: Double

        /// List price in US dollars (per million tokens; see the claude-api skill's models reference).
        public var costUSD: Double {
            let (inPrice, outPrice): (Double, Double)
            if model.contains("haiku") {
                (inPrice, outPrice) = inputTokens > 100_000 ? (0.50, 2.50) : (0.10, 0.50)
            } else if model.contains("opus") {
                (inPrice, outPrice) = (4, 20)
            } else {
                (inPrice, outPrice) = (2, 10)
            }
            return (Double(inputTokens) * inPrice + Double(outputTokens) * outPrice) / 1_000_000
        }
    }

    /// Sends one system + user turn and streams the answer; `onDelta` receives each text fragment.
    /// Retries rate limits, overload and server errors with backoff.
    public func complete(
        system: String, user: String, maxTokens: Int = 32_000, onDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> Completion {
        var attempt = 0
        while true {
            do {
                return try await stream(system: system, user: user, maxTokens: maxTokens, onDelta: onDelta)
            } catch AnthropicError.http(let status, let body) where [408, 429, 500, 502, 503, 504, 529].contains(status) && attempt < 3 {
                attempt += 1
                let delay = pow(2.0, Double(attempt)) * 2
                log.warning("Anthropic API returned \(status), retrying in \(Int(delay)) s: \(body.prefix(200))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func stream(
        system: String, user: String, maxTokens: Int, onDelta: (@Sendable (String) -> Void)?
    ) async throws -> Completion {
        let started = Date()
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        if let effort, !effort.isEmpty { body["output_config"] = ["effort": effort] }
        // On a safety-classifier decline, let the API re-run the request on a fallback model it picks by category.
        // Supported on the Opus/Sonnet 5.x line; Haiku has no server-side fallback.
        if !model.contains("haiku") {
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 {
            var text = ""
            for try await line in bytes.lines { text += line }
            throw AnthropicError.http(status, Self.errorMessage(text))
        }

        var output = ""
        var stopReason: String?
        var usedModel = model
        var inputTokens = 0
        var outputTokens = 0
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            guard let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = event["type"] as? String
            else { continue }
            switch type {
            case "message_start":
                if let message = event["message"] as? [String: Any] {
                    usedModel = message["model"] as? String ?? model
                    let usage = message["usage"] as? [String: Any] ?? [:]
                    inputTokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                        .compactMap { usage[$0] as? Int }.reduce(0, +)
                }
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                    let text = delta["text"] as? String
                {
                    output += text
                    onDelta?(text)
                }
            case "message_delta":
                if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }
                if let usage = event["usage"] as? [String: Any], let out = usage["output_tokens"] as? Int {
                    outputTokens = out
                }
            case "error":
                let message = (event["error"] as? [String: Any])?["message"] as? String ?? "unknown error"
                throw AnthropicError.stream(message)
            default:
                break
            }
        }
        switch stopReason {
        case "refusal":
            throw AnthropicError.refusal
        case "max_tokens":
            log.warning("summary hit max_tokens and may be cut off")
        default:
            break
        }
        return Completion(
            text: output.trimmingCharacters(in: .whitespacesAndNewlines), model: usedModel, inputTokens: inputTokens,
            outputTokens: outputTokens, seconds: Date().timeIntervalSince(started))
    }

    static func errorMessage(_ body: String) -> String {
        if let data = body.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = obj["error"] as? [String: Any], let message = error["message"] as? String
        {
            return message
        }
        return String(body.prefix(300))
    }
}

public enum AnthropicError: LocalizedError {
    case http(Int, String)
    case stream(String)
    case refusal
    case missingKey
    case emptyTranscript

    public var errorDescription: String? {
        switch self {
        case .http(401, _): return "The Anthropic API key was rejected. Check it in Settings → Notes."
        case .http(let status, let message): return "Anthropic API error \(status): \(message)"
        case .stream(let message): return "Anthropic API error: \(message)"
        case .refusal: return "The model declined to summarize this transcript."
        case .emptyTranscript: return "The transcript is empty, so there is nothing to summarize."
        case .missingKey: return "No Anthropic API key. Add one in Settings → Notes (or set ANTHROPIC_API_KEY)."
        }
    }
}
