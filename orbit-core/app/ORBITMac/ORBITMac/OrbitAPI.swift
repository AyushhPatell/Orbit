//
//  OrbitAPI.swift
//  ORBITMac
//

import Foundation

/// Wall clock from the user’s Mac, sent on every `/chat` so the model knows real local time.
enum OrbitClientClock {
    static func snapshotForAPI() -> (iso8601: String, timeZoneId: String) {
        let tz = TimeZone.current
        let tzId = tz.identifier
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
        formatter.timeZone = tz
        let iso = formatter.string(from: Date())
        return (iso, tzId)
    }
}

struct ChatRequest: Encodable {
    let session_id: String
    let message: String
    let route_hint: String?
    /// Calendar / tool text; orbit-core injects when `route` is tooling.
    let tooling_context: String?
    let client_local_iso: String?
    let client_tz: String?
    let include_memory_debug: Bool?
    /// When false the backend skips appending this turn to conversation history and semantic memory.
    let save_memory: Bool?

    enum CodingKeys: String, CodingKey {
        case session_id
        case message
        case route_hint
        case tooling_context
        case client_local_iso
        case client_tz
        case include_memory_debug
        case save_memory
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(session_id, forKey: .session_id)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(route_hint, forKey: .route_hint)
        try container.encodeIfPresent(tooling_context, forKey: .tooling_context)
        try container.encodeIfPresent(client_local_iso, forKey: .client_local_iso)
        try container.encodeIfPresent(client_tz, forKey: .client_tz)
        try container.encodeIfPresent(include_memory_debug, forKey: .include_memory_debug)
        try container.encodeIfPresent(save_memory, forKey: .save_memory)
    }
}

struct MemoryDebugInfo: Decodable {
    let recent_turn_count: Int
    let semantic_hits: [String]
}

/// Generic JSON value for decoding arbitrary tool params from the server.
enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self)   { self = .bool(v);   return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if c.decodeNil()                      { self = .null;       return }
        throw DecodingError.typeMismatch(
            JSONValue.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON type")
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v):   try c.encode(v)
        case .null:          try c.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }
}

struct ToolCallInfo: Decodable {
    let tool: String
    let params: [String: JSONValue]
    let id: String
}

struct ChatResponse: Decodable {
    let reply: String
    let route: String
    let model: String
    let memory_debug: MemoryDebugInfo?
    /// One request can carry several actions ("dim the screen and turn on sleep mode").
    let tool_calls: [ToolCallInfo]?
    /// Contract version from orbit-core; absent means a backend older than the handshake.
    let `protocol`: Int?
}

struct ToolResultItem: Encodable {
    let tool: String
    let tool_call_id: String
    let params: [String: JSONValue]
    let result: String
}

private struct ToolResultBody: Encodable {
    let session_id: String
    let original_message: String
    let results: [ToolResultItem]
    let client_local_iso: String?
    let client_tz: String?
}

private struct FactCreateBody: Encodable {
    let fact: String
}

struct FactRecord: Codable, Identifiable {
    let id: Int
    let fact: String
}

struct FactListAPIResponse: Decodable {
    let items: [FactRecord]
}

struct SemanticMemoryRecord: Codable, Identifiable {
    let id: Int
    let text: String
    let source: String
    let importance: Double
}

private struct SemanticMemoryListAPIResponse: Decodable {
    let items: [SemanticMemoryRecord]
}

private struct SemanticMemoryCreateBody: Encodable {
    let text: String
    let source: String
    let importance: Double?
}

private struct SemanticMemoryImportanceBody: Encodable {
    let importance: Double
}

private struct SemanticMemoryPurgeAPIResponse: Decodable {
    let deleted_count: Int
}

enum StreamChunk {
    case token(String)
    case done(route: String, model: String, reply: String, memoryDebug: MemoryDebugInfo?)
}

enum OrbitAPIError: Error, LocalizedError {
    case badURL
    case badStatus(Int)
    case decode
    case protocolMismatch(server: Int)

    var errorDescription: String? {
        switch self {
        case .protocolMismatch(let server):
            return server < OrbitAPI.protocolVersion
                ? "ORBIT core is running older code than this app build, so my actions can't run. Restart it with orbit-restart in Terminal."
                : "This app build is older than ORBIT core, so my actions can't run. Rebuild ORBITMac in Xcode (Cmd+R)."
        case .badURL:
            return "Internal URL error while contacting ORBIT core."
        case .badStatus(let code):
            if code == 503 {
                return "ORBIT core is unavailable right now (503). Make sure local services are running."
            }
            if code == 413 {
                return "Request was too large for /chat (413). Try a shorter page or smaller extract."
            }
            if code == -1 {
                return "Invalid response from ORBIT core."
            }
            return "ORBIT core returned HTTP \(code)."
        case .decode:
            return "Could not parse ORBIT core response."
        }
    }
}

final class OrbitAPI {
    /// Must match `PROTOCOL_VERSION` in orbit-core/app/models.py. A mismatch means one half
    /// was updated without the other; surface it loudly instead of dropping tool calls.
    static let protocolVersion = 2

    private let baseURL = "http://127.0.0.1:8787"

    func chat(
        sessionID: String,
        message: String,
        routeHint: OrbitRoute? = nil,
        toolingContext: String? = nil,
        clientLocalISO8601: String? = nil,
        clientTimeZoneId: String? = nil,
        includeMemoryDebug: Bool? = nil
    ) async throws -> ChatResponse {
        guard let url = URL(string: "\(baseURL)/chat") else { throw OrbitAPIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let saveMemory = UserDefaults.standard.object(forKey: "orbitMac.saveConversationMemory") as? Bool ?? true
        let body = ChatRequest(
            session_id: sessionID,
            message: message,
            route_hint: routeHint?.rawValue,
            tooling_context: toolingContext,
            client_local_iso: clientLocalISO8601,
            client_tz: clientTimeZoneId,
            include_memory_debug: includeMemoryDebug,
            save_memory: saveMemory ? nil : false
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OrbitAPIError.badStatus(-1) }
        guard 200..<300 ~= http.statusCode else { throw OrbitAPIError.badStatus(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw OrbitAPIError.decode
        }
        let serverProtocol = decoded.protocol ?? 1
        guard serverProtocol == Self.protocolVersion else {
            throw OrbitAPIError.protocolMismatch(server: serverProtocol)
        }
        return decoded
    }

    func chatStream(
        sessionID: String,
        message: String,
        routeHint: OrbitRoute? = nil,
        toolingContext: String? = nil,
        clientLocalISO8601: String? = nil,
        clientTimeZoneId: String? = nil,
        includeMemoryDebug: Bool? = nil
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "\(baseURL)/chat/stream") else {
                        continuation.finish(throwing: OrbitAPIError.badURL)
                        return
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let saveMemory = UserDefaults.standard.object(forKey: "orbitMac.saveConversationMemory") as? Bool ?? true
                    let body = ChatRequest(
                        session_id: sessionID,
                        message: message,
                        route_hint: routeHint?.rawValue,
                        tooling_context: toolingContext,
                        client_local_iso: clientLocalISO8601,
                        client_tz: clientTimeZoneId,
                        include_memory_debug: includeMemoryDebug,
                        save_memory: saveMemory ? nil : false
                    )
                    request.httpBody = try JSONEncoder().encode(body)

                    let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: OrbitAPIError.badStatus(-1))
                        return
                    }
                    guard 200..<300 ~= http.statusCode else {
                        continuation.finish(throwing: OrbitAPIError.badStatus(http.statusCode))
                        return
                    }

                    for try await line in asyncBytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard let data = jsonStr.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let errorMsg = obj["error"] as? String {
                            continuation.finish(throwing: OrbitAPIError.badStatus(-1))
                            _ = errorMsg
                            return
                        }
                        if let token = obj["token"] as? String, !token.isEmpty {
                            continuation.yield(.token(token))
                        } else if obj["done"] as? Bool == true {
                            let route = obj["route"] as? String ?? "unknown"
                            let model = obj["model"] as? String ?? "unknown"
                            let reply = obj["reply"] as? String ?? ""
                            var memDebug: MemoryDebugInfo? = nil
                            if let md = obj["memory_debug"] as? [String: Any] {
                                memDebug = MemoryDebugInfo(
                                    recent_turn_count: md["recent_turn_count"] as? Int ?? 0,
                                    semantic_hits: md["semantic_hits"] as? [String] ?? []
                                )
                            }
                            continuation.yield(.done(
                                route: route,
                                model: model,
                                reply: reply,
                                memoryDebug: memDebug
                            ))
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Second leg of brain tool-calling: send every tool execution result to the server.
    func chatToolResult(
        sessionID: String,
        originalMessage: String,
        results: [ToolResultItem],
        clientLocalISO8601: String? = nil,
        clientTimeZoneId: String? = nil
    ) async throws -> ChatResponse {
        guard let url = URL(string: "\(baseURL)/chat/tool-result") else { throw OrbitAPIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ToolResultBody(
            session_id: sessionID,
            original_message: originalMessage,
            results: results,
            client_local_iso: clientLocalISO8601,
            client_tz: clientTimeZoneId
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OrbitAPIError.badStatus(-1) }
        guard 200..<300 ~= http.statusCode else { throw OrbitAPIError.badStatus(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            throw OrbitAPIError.decode
        }
        return decoded
    }

    func listFacts() async throws -> [FactRecord] {
        guard let url = URL(string: "\(baseURL)/facts") else { throw OrbitAPIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OrbitAPIError.badStatus(-1) }
        guard 200..<300 ~= http.statusCode else { throw OrbitAPIError.badStatus(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(FactListAPIResponse.self, from: data) else {
            throw OrbitAPIError.decode
        }
        return decoded.items
    }

    /// Persists a curated fact; ORBIT injects recent facts into every `/chat` system prompt.
    func addFact(_ fact: String) async throws -> [FactRecord] {
        guard let url = URL(string: "\(baseURL)/facts") else { throw OrbitAPIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(FactCreateBody(fact: fact))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OrbitAPIError.badStatus(-1) }
        guard 200..<300 ~= http.statusCode else { throw OrbitAPIError.badStatus(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(FactListAPIResponse.self, from: data) else {
            throw OrbitAPIError.decode
        }
        return decoded.items
    }

    func deleteFact(id: Int) async throws -> [FactRecord] {
        guard let url = URL(string: "\(baseURL)/facts/\(id)") else { throw OrbitAPIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OrbitAPIError.badStatus(-1) }
        guard 200..<300 ~= http.statusCode else { throw OrbitAPIError.badStatus(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(FactListAPIResponse.self, from: data) else {
            throw OrbitAPIError.decode
        }
        return decoded.items
    }

    func clearAllSemanticMemory() async throws -> Int {
        guard let url = URL(string: "\(baseURL)/semantic-memory") else { throw OrbitAPIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OrbitAPIError.badStatus(-1) }
        guard 200..<300 ~= http.statusCode else { throw OrbitAPIError.badStatus(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(SemanticMemoryPurgeAPIResponse.self, from: data) else {
            throw OrbitAPIError.decode
        }
        return decoded.deleted_count
    }

    func listSemanticMemory() async throws -> [SemanticMemoryRecord] {
        guard let url = URL(string: "\(baseURL)/semantic-memory") else { throw OrbitAPIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OrbitAPIError.badStatus(-1) }
        guard 200..<300 ~= http.statusCode else { throw OrbitAPIError.badStatus(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(SemanticMemoryListAPIResponse.self, from: data) else {
            throw OrbitAPIError.decode
        }
        return decoded.items
    }

    func addSemanticMemory(
        _ text: String,
        source: String = "manual",
        importance: Double? = nil
    ) async throws -> [SemanticMemoryRecord] {
        guard let url = URL(string: "\(baseURL)/semantic-memory") else { throw OrbitAPIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            SemanticMemoryCreateBody(text: text, source: source, importance: importance)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OrbitAPIError.badStatus(-1) }
        guard 200..<300 ~= http.statusCode else { throw OrbitAPIError.badStatus(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(SemanticMemoryListAPIResponse.self, from: data) else {
            throw OrbitAPIError.decode
        }
        return decoded.items
    }

    func deleteSemanticMemory(id: Int) async throws -> [SemanticMemoryRecord] {
        guard let url = URL(string: "\(baseURL)/semantic-memory/\(id)") else { throw OrbitAPIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OrbitAPIError.badStatus(-1) }
        guard 200..<300 ~= http.statusCode else { throw OrbitAPIError.badStatus(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(SemanticMemoryListAPIResponse.self, from: data) else {
            throw OrbitAPIError.decode
        }
        return decoded.items
    }

    func updateSemanticMemoryImportance(id: Int, importance: Double) async throws -> [SemanticMemoryRecord] {
        guard let url = URL(string: "\(baseURL)/semantic-memory/\(id)") else { throw OrbitAPIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            SemanticMemoryImportanceBody(importance: max(0.0, min(1.0, importance)))
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OrbitAPIError.badStatus(-1) }
        guard 200..<300 ~= http.statusCode else { throw OrbitAPIError.badStatus(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(SemanticMemoryListAPIResponse.self, from: data) else {
            throw OrbitAPIError.decode
        }
        return decoded.items
    }
}
