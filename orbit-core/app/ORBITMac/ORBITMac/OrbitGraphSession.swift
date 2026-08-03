//
//  OrbitGraphSession.swift
//  ORBITMac
//
//  Microsoft Graph via OAuth 2.0 device code flow (no custom URL scheme). Read-only mail/chat previews.
//

import Combine
import Foundation
import Security

@MainActor
final class OrbitGraphSession: ObservableObject {
    static let shared = OrbitGraphSession()

    private let tokenEndpoint = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
    private let deviceCodeEndpoint = "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode"
    private let graphBase = "https://graph.microsoft.com/v1.0"

    private let keychainService = "Ayush.ORBITMac.graph"
    private let keychainAccount = "graph_refresh_token"

    @Published private(set) var lastError: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isSignedIn: Bool = false
    @Published private(set) var isSigningIn: Bool = false

    /// Paste an Azure "Application (client) ID" from portal.azure.com (public client + allow public client flows).
    var clientId: String {
        get { UserDefaults.standard.string(forKey: "OrbitGraphClientId") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "OrbitGraphClientId") }
    }

    private var accessToken: String?
    private var accessExpiry: Date?

    private init() {
        isSignedIn = loadRefreshToken() != nil
    }

    func signOut() {
        deleteRefreshToken()
        accessToken = nil
        accessExpiry = nil
        isSignedIn = false
        statusMessage = "Signed out of Microsoft 365."
    }

    /// Shows device code immediately, then polls in the background until you finish in the browser.
    func signInWithDeviceCode() {
        lastError = nil
        statusMessage = nil
        let cid = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cid.isEmpty else {
            lastError = "Add your Azure Application (client) ID in the Microsoft 365 section first."
            return
        }
        guard !isSigningIn else { return }
        isSigningIn = true
        Task { await runDeviceCodeFlow(clientId: cid) }
    }

    private func runDeviceCodeFlow(clientId: String) async {
        defer { isSigningIn = false }
        do {
            let device = try await requestDeviceCode(clientId: clientId)
            let interval = max(device.interval ?? 5, 5)
            statusMessage = """
            Microsoft sign-in: open \(device.verificationUri) in a browser and enter code **\(device.userCode)**.

            Waiting for you to finish signing in…
            """
            let token = try await pollDeviceCode(clientId: clientId, deviceCode: device.deviceCode, interval: interval)
            guard let refresh = token.refreshToken, !refresh.isEmpty else {
                throw OrbitGraphError.missingRefresh
            }
            try storeRefreshToken(refresh)
            accessToken = token.accessToken
            accessExpiry = Date().addingTimeInterval(TimeInterval(max(token.expiresIn - 60, 60)))
            isSignedIn = true
            lastError = nil
            statusMessage = "Microsoft 365 is connected (read-only)."
        } catch {
            lastError = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    /// Short preview of recent mail (read-only).
    func fetchRecentMailPreview(max: Int = 5) async -> String {
        await ensureAccessToken()
        guard let tok = accessToken else { return "Not signed in. Use Sign in to Microsoft 365 first." }
        let url = URL(string: "\(graphBase)/me/messages?$top=\(max)&$select=subject,from,receivedDateTime,bodyPreview&$orderby=receivedDateTime%20desc")!
        do {
            let (data, response) = try await graphData(url: url, token: tok)
            try throwIfGraphError(data: data, response: response)
            let decoded = try JSONDecoder().decode(GraphMessageList.self, from: data)
            if decoded.value.isEmpty { return "No recent messages returned." }
            let lines = decoded.value.map { m -> String in
                let from = m.from?.emailAddress?.name ?? m.from?.emailAddress?.address ?? "?"
                let sub = m.subject ?? "(no subject)"
                let prev = (m.bodyPreview ?? "").replacingOccurrences(of: "\n", with: " ")
                let clip = prev.count > 120 ? String(prev.prefix(120)) + "…" : prev
                return "• \(sub) — from \(from)\n  \(clip)"
            }
            return "Recent mail (read-only):\n" + lines.joined(separator: "\n")
        } catch {
            return "Mail preview failed: \(error.localizedDescription)"
        }
    }

    /// Short preview of chats (read-only). Requires `Chat.Read`.
    func fetchRecentChatsPreview(max: Int = 5) async -> String {
        await ensureAccessToken()
        guard let tok = accessToken else { return "Not signed in. Use Sign in to Microsoft 365 first." }
        let url = URL(string: "\(graphBase)/me/chats?$top=\(max)")!
        do {
            let (data, response) = try await graphData(url: url, token: tok)
            try throwIfGraphError(data: data, response: response)
            let decoded = try JSONDecoder().decode(GraphChatList.self, from: data)
            if decoded.value.isEmpty { return "No chats returned (permissions or no Teams data)." }
            let lines = decoded.value.map { c -> String in
                let topic = c.topic ?? "Chat \(String(c.id.prefix(8)))"
                return "• \(topic) (\(c.chatType ?? "unknown"))"
            }
            return "Recent chats (read-only):\n" + lines.joined(separator: "\n")
        } catch {
            return "Chats preview failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Device code

    private struct DeviceCodeResponse: Decodable {
        let userCode: String
        let deviceCode: String
        let verificationUri: String
        let expiresIn: Int
        let interval: Int?

        enum CodingKeys: String, CodingKey {
            case userCode = "user_code"
            case deviceCode = "device_code"
            case verificationUri = "verification_uri"
            case expiresIn = "expires_in"
            case interval
        }
    }

    private struct TokenResponse: Decodable {
        let tokenType: String
        let scope: String?
        let expiresIn: Int
        let accessToken: String
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case tokenType = "token_type"
            case scope
            case expiresIn = "expires_in"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }

    private struct GraphErrorEnvelope: Decodable {
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    private func requestDeviceCode(clientId: String) async throws -> DeviceCodeResponse {
        var req = URLRequest(url: URL(string: deviceCodeEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let scope = "offline_access User.Read Mail.Read Chat.Read"
        let enc = scope.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? scope
        let body = "client_id=\(clientId)&scope=\(enc)"
        req.httpBody = body.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw OrbitGraphError.badStatus(String(data: data, encoding: .utf8) ?? "device code")
        }
        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    private func pollDeviceCode(clientId: String, deviceCode: String, interval: Int) async throws -> TokenResponse {
        let pollInterval = max(interval, 5)
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(pollInterval) * 1_000_000_000)
            var req = URLRequest(url: URL(string: tokenEndpoint)!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let encCode = deviceCode.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceCode
            let body = "grant_type=urn:ietf:params:oauth:grant-type:device_code&client_id=\(clientId)&device_code=\(encCode)"
            req.httpBody = body.data(using: .utf8)
            let (data, _) = try await URLSession.shared.data(for: req)
            if let tok = try? JSONDecoder().decode(TokenResponse.self, from: data), !tok.accessToken.isEmpty {
                return tok
            }
            if let env = try? JSONDecoder().decode(GraphErrorEnvelope.self, from: data) {
                let code = env.error ?? ""
                if code == "authorization_pending" || code == "slow_down" {
                    continue
                }
                throw OrbitGraphError.oauth(env.errorDescription ?? env.error ?? "oauth")
            }
        }
        throw OrbitGraphError.timeout
    }

    // MARK: - Token refresh

    private func ensureAccessToken() async {
        if let tok = accessToken, let exp = accessExpiry, Date() < exp { return }
        guard let refresh = loadRefreshToken() else {
            accessToken = nil
            isSignedIn = false
            return
        }
        let cid = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cid.isEmpty else { return }
        var req = URLRequest(url: URL(string: tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let enc = refresh.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? refresh
        let body =
            "grant_type=refresh_token&client_id=\(cid)&refresh_token=\(enc)&scope=offline_access%20User.Read%20Mail.Read%20Chat.Read"
        req.httpBody = body.data(using: .utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
                lastError = String(data: data, encoding: .utf8)
                return
            }
            let tok = try JSONDecoder().decode(TokenResponse.self, from: data)
            accessToken = tok.accessToken
            accessExpiry = Date().addingTimeInterval(TimeInterval(max(tok.expiresIn - 60, 60)))
            if let newR = tok.refreshToken, !newR.isEmpty {
                try? storeRefreshToken(newR)
            }
            isSignedIn = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func graphData(url: URL, token: String) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await URLSession.shared.data(for: req)
    }

    private func throwIfGraphError(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard http.statusCode >= 400 else { return }
        if let env = try? JSONDecoder().decode(GraphErrorEnvelope.self, from: data) {
            throw OrbitGraphError.oauth(env.errorDescription ?? env.error ?? "graph")
        }
        throw OrbitGraphError.badStatus(String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)")
    }

    // MARK: - Keychain

    private func storeRefreshToken(_ token: String) throws {
        deleteRefreshToken()
        guard let data = token.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw OrbitGraphError.keychain(status) }
    }

    private func loadRefreshToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private func deleteRefreshToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Graph DTOs

private struct GraphMessageList: Decodable {
    let value: [GraphMessage]
}

private struct GraphMessage: Decodable {
    let subject: String?
    let bodyPreview: String?
    let receivedDateTime: String?
    let from: GraphFrom?
}

private struct GraphFrom: Decodable {
    let emailAddress: GraphEmailAddress?
}

private struct GraphEmailAddress: Decodable {
    let name: String?
    let address: String?
}

private struct GraphChatList: Decodable {
    let value: [GraphChat]
}

private struct GraphChat: Decodable {
    let id: String
    let topic: String?
    let chatType: String?
}

enum OrbitGraphError: LocalizedError {
    case badStatus(String)
    case oauth(String)
    case timeout
    case missingRefresh
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .badStatus(let s): return s
        case .oauth(let s): return s.replacingOccurrences(of: "+", with: " ")
        case .timeout: return "Sign-in timed out. Try again."
        case .missingRefresh: return "No refresh token from Microsoft."
        case .keychain(let s): return "Keychain error (\(s))."
        }
    }
}
