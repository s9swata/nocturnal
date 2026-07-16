import Foundation

/// Reply body for OpenCode `POST /session/{id}/permissions/{permissionID}`.
public enum OpenCodePermissionResponse: String, Sendable, Codable, Hashable {
    /// Approve this single request.
    case once
    /// Approve matching future requests for the rest of the session.
    case always
    /// Deny / reject.
    case reject

    public static func from(approved: Bool, scope: ApprovalScope) -> OpenCodePermissionResponse {
        if !approved { return .reject }
        if scope == .sessionTool { return .always }
        return .once
    }
}

/// Fail-open HTTP client that completes OpenCode permission prompts.
///
/// OpenCode does not use shell-hook stdout for decisions. When the user
/// Allow/Deny in Nocturnal, we POST to a local OpenCode server:
/// `POST /session/{sessionID}/permissions/{permissionID}` with
/// `{ "response": "once" | "always" | "reject" }`.
public struct OpenCodePermissionClient: Sendable {
    public var baseURLs: [URL]
    public var timeout: TimeInterval
    public var session: URLSession

    public init(
        baseURLs: [URL] = OpenCodePermissionClient.defaultBaseURLs(),
        timeout: TimeInterval = 2.0,
        session: URLSession = .shared
    ) {
        self.baseURLs = baseURLs
        self.timeout = max(0.2, timeout)
        self.session = session
    }

    public static func defaultBaseURLs(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var urls: [URL] = []
        if let raw = environment["OPENCODE_SERVER"] ?? environment["OPENCODE_BASE_URL"],
           !raw.isEmpty,
           let url = URL(string: raw)
        {
            urls.append(url)
        }
        // Best-effort: ports currently listening that look like local OpenCode servers.
        for port in discoveredLocalPorts() {
            if let url = URL(string: "http://127.0.0.1:\(port)") {
                urls.append(url)
            }
        }
        // Default standalone serve port; TUI often uses a random port — plugin path covers that.
        if let fallback = URL(string: "http://127.0.0.1:4096") {
            urls.append(fallback)
        }
        // De-dupe while preserving order.
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }

    /// Probe common localhost listeners (best-effort, fail-open).
    public static func discoveredLocalPorts() -> [Int] {
        // Lightweight: try a few high-frequency OpenCode/dev ports without shelling out.
        // Full discovery happens in the plugin via serverUrl.
        [4096, 4097, 3000, 5173, 8080]
    }

    /// Build request URL for a permission reply.
    public static func permissionURL(
        base: URL,
        sessionId: String,
        permissionId: String
    ) -> URL? {
        var root = base.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        // Opaque IDs may contain `/` — encode as single path segments, not free paths.
        let path =
            "\(root)/session/\(encodePathSegment(sessionId))/permissions/\(encodePathSegment(permissionId))"
        return URL(string: path)
    }

    /// Percent-encode a single path segment (slashes must not create extra segments).
    static func encodePathSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    public static func requestBody(response: OpenCodePermissionResponse) -> Data {
        // OpenAPI: { "response": "once" | "always" | "reject" }
        #"{"response":"\#(response.rawValue)"}"#.data(using: .utf8) ?? Data("{}".utf8)
    }

    /// Attempt to deliver a permission decision. Returns `true` if any base URL accepts it.
    public func reply(
        sessionId: String,
        permissionId: String,
        response: OpenCodePermissionResponse
    ) async -> Bool {
        guard !sessionId.isEmpty, !permissionId.isEmpty, sessionId != "unknown" else {
            return false
        }
        let body = Self.requestBody(response: response)
        for base in baseURLs {
            guard let url = Self.permissionURL(
                base: base,
                sessionId: sessionId,
                permissionId: permissionId
            ) else { continue }
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            do {
                let (_, http) = try await session.data(for: request)
                if let http = http as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    return true
                }
            } catch {
                // fail-open: try next base
                continue
            }
        }
        return false
    }

    /// Extract OpenCode correlation ids from an approval request (payload / raw).
    public static func correlation(
        from request: ApprovalRequest
    ) -> (sessionId: String, permissionId: String)? {
        let sessionId = request.sessionId.rawValue
        let permissionId = request.id
        guard !sessionId.isEmpty, sessionId != "unknown", !permissionId.isEmpty else {
            return nil
        }
        return (sessionId, permissionId)
    }
}
