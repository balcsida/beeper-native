import Foundation

public enum BeeperError: LocalizedError {
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .http(401, _): "Beeper rejected the access token."
        case .http(let code, let body): "Beeper Desktop API error \(code): \(body.prefix(200))"
        }
    }
}

/// Thin client for the local Beeper Desktop API. Beeper Desktop must be running.
public struct BeeperClient: Sendable {
    public var baseURL: URL
    public var token: String

    public init(token: String, baseURL: URL = URL(string: "http://localhost:23373")!) {
        self.token = token
        self.baseURL = baseURL
    }

    /// Path components and query values are encoded one by one, so an ID or search text can't alter the route.
    static func url(_ base: URL, _ path: [String], _ query: [String: String?]) -> URL {
        var components = URLComponents(url: path.reduce(base) { $0.appending(component: $1) }, resolvingAgainstBaseURL: false)!
        let items = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        if !items.isEmpty {
            components.queryItems = items
            // URLComponents leaves "+" bare, which servers read as a space
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url!
    }

    private func request(
        _ method: String, _ path: [String], query: [String: String?] = [:],
        json: (any Encodable)? = nil, body: Data? = nil, contentType: String? = nil
    ) async throws -> Data {
        let url = Self.url(baseURL, path, query)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try json.map { try JSONEncoder().encode($0) } ?? body
        if req.httpBody != nil {
            req.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw BeeperError.http(status, String(decoding: data, as: UTF8.self))
        }
        return data
    }

    private func get<T: Decodable>(_ path: [String], query: [String: String?] = [:]) async throws -> T {
        try JSONDecoder.beeper.decode(T.self, from: try await request("GET", path, query: query))
    }

    /// Chats, most recently active first. Pass the previous page's `oldestCursor` for the next page.
    public func chats(before cursor: String? = nil) async throws -> Page<Chat> {
        try await get(["v1", "chats"], query: ["cursor": cursor, "direction": cursor == nil ? nil : "before"])
    }

    public func chat(_ chatID: String) async throws -> Chat {
        try await get(["v1", "chats", chatID])
    }

    public func messages(chatID: String, before cursor: String? = nil) async throws -> Page<Message> {
        try await get(["v1", "chats", chatID, "messages"], query: ["cursor": cursor, "direction": cursor == nil ? nil : "before"])
    }

    public enum Inbox: String, Sendable, CaseIterable {
        case primary, lowPriority = "low-priority", archive
    }

    /// Matching chats, without `preview`. Pass `oldestCursor` for the next page.
    public func searchChats(_ query: String, inbox: Inbox? = nil, before cursor: String? = nil) async throws -> Page<Chat> {
        try await get(["v1", "chats", "search"], query: [
            "query": query.isEmpty ? nil : query, "inbox": inbox?.rawValue,
            "cursor": cursor, "direction": cursor == nil ? nil : "before",
        ])
    }

    /// Number of unmuted primary-inbox chats with unread messages, capped at 200.
    public func unreadChatCount() async throws -> Int {
        let page: Page<Chat> = try await get(["v1", "chats", "search"], query: ["inbox": "primary", "unreadOnly": "true", "includeMuted": "false", "limit": "200"])
        return page.items.count
    }

    private struct Outgoing: Encodable {
        struct Attachment: Encodable { var uploadID: String }
        var text: String?
        var replyToMessageID: String?
        var attachment: Attachment?
    }

    public func send(_ text: String?, to chatID: String, replyTo: String? = nil, uploadID: String? = nil) async throws {
        let message = Outgoing(text: text, replyToMessageID: replyTo, attachment: uploadID.map { .init(uploadID: $0) })
        _ = try await request("POST", ["v1", "chats", chatID, "messages"], json: message)
    }

    /// Hands a local file to Beeper and returns the upload ID to pass to `send`.
    public func upload(_ file: URL) async throws -> String {
        struct Upload: Decodable { var uploadID: String?, error: String? }
        let boundary = UUID().uuidString
        let name = file.lastPathComponent.replacingOccurrences(of: #"["\\\r\n]"#, with: "_", options: .regularExpression)
        // shortcut: reads the whole file into memory, switch to a streamed upload if large videos matter
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        body += try Data(contentsOf: file)
        body += Data("\r\n--\(boundary)--\r\n".utf8)
        let data = try await request("POST", ["v1", "assets", "upload"], body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        let upload = try JSONDecoder().decode(Upload.self, from: data)
        guard let id = upload.uploadID else { throw BeeperError.http(200, upload.error ?? "Upload failed") }
        return id
    }

    public func setReaction(_ key: String, on messageID: String, in chatID: String, added: Bool) async throws {
        if added {
            _ = try await request("POST", ["v1", "chats", chatID, "messages", messageID, "reactions"], json: ["reactionKey": key])
        } else {
            _ = try await request("DELETE", ["v1", "chats", chatID, "messages", messageID, "reactions", key])
        }
    }

    public func edit(_ messageID: String, in chatID: String, text: String) async throws {
        _ = try await request("PUT", ["v1", "chats", chatID, "messages", messageID], json: ["text": text])
    }

    /// Deletes for everyone where the network allows it, otherwise only locally.
    public func delete(_ messageID: String, in chatID: String) async throws {
        _ = try await request("DELETE", ["v1", "chats", chatID, "messages", messageID], query: ["forEveryone": "true"])
    }

    /// Messages containing all the words, newest first. Pass `oldestCursor` for the next page.
    public func searchMessages(_ query: String, before cursor: String? = nil) async throws -> MessageHits {
        try await get(["v1", "messages", "search"], query: ["query": query, "cursor": cursor, "direction": cursor == nil ? nil : "before"])
    }

    public func setArchived(_ archived: Bool, chatID: String) async throws {
        _ = try await request("POST", ["v1", "chats", chatID, "archive"], json: ["archived": archived])
    }

    public func markUnread(chatID: String) async throws {
        _ = try await request("POST", ["v1", "chats", chatID, "unread"], json: [String: String]())
    }

    public func markRead(chatID: String) async throws {
        _ = try await request("POST", ["v1", "chats", chatID, "read"], json: [String: String]())
    }

    /// Bytes of an avatar or attachment URL (`mxc://`, `localmxc://`, `https://`) as Beeper serves it.
    public func asset(_ url: String) async throws -> Data {
        // chat avatars come back as bare file paths, which the endpoint rejects
        try await request("GET", ["v1", "assets", "serve"], query: ["url": url.hasPrefix("/") ? "file://" + url : url])
    }

    /// Live events for all chats. The stream ends with an error when the socket drops; the caller reconnects.
    public func events() -> AsyncThrowingStream<Event, any Error> {
        var components = URLComponents(url: baseURL.appending(path: "v1/ws"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        var req = URLRequest(url: components.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: req)
        socket.maximumMessageSize = 16 << 20  // message entries carry full payloads

        return AsyncThrowingStream { continuation in
            let task = Task {
                socket.resume()
                do {
                    try await socket.send(.string(#"{"type":"subscriptions.set","requestID":"1","chatIDs":["*"]}"#))
                    while true {
                        guard case .string(let text) = try await socket.receive() else { continue }
                        if let event = try? JSONDecoder.beeper.decode(Event.self, from: Data(text.utf8)) {
                            continuation.yield(event)
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }
}
