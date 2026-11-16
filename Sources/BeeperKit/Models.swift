import Foundation

public struct Page<Item: Decodable & Sendable>: Decodable, Sendable {
    public var items: [Item]
    public var hasMore: Bool
    public var oldestCursor: String?
    public var newestCursor: String?
}

/// Message search hits, with the chats they belong to keyed by chat ID.
public struct MessageHits: Decodable, Sendable {
    public var items: [Message]
    public var chats: [String: Chat]
    public var hasMore: Bool
    public var oldestCursor: String?
}

public struct User: Decodable, Sendable, Identifiable {
    public var id: String
    public var fullName: String?
    public var imgURL: String?
    public var isSelf: Bool?
}

public struct Attachment: Decodable, Sendable {
    public var type: String
    public var fileName: String?
    public var mimeType: String?
    public var srcURL: String?
    public var posterImg: String?
}

public struct Reaction: Decodable, Sendable, Identifiable {
    public var id: String
    public var participantID: String
    public var reactionKey: String
}

public struct Message: Decodable, Sendable, Identifiable {
    public var id: String
    public var chatID: String
    public var senderID: String
    public var sortKey: String
    public var timestamp: Date
    public var text: String?
    public var senderName: String?
    public var isSender: Bool?
    public var isDeleted: Bool?
    public var isHidden: Bool?
    public var linkedMessageID: String?
    public var attachments: [Attachment]?
    public var reactions: [Reaction]?
}

public struct Chat: Decodable, Sendable, Identifiable {
    public struct Participants: Decodable, Sendable {
        public var items: [User]
    }

    public var id: String
    public var accountID: String
    public var network: String
    public var title: String
    public var type: String
    public var unreadCount: Int
    public var participants: Participants?
    public var imgURL: String?
    public var isArchived: Bool?
    public var isMuted: Bool?
    public var isPinned: Bool?
    public var isLowPriority: Bool?
    public var isMarkedUnread: Bool?
    public var lastActivity: Date?
    public var preview: Message?
}

/// A live event from `/v1/ws`. Control messages (`ready`, `error`) decode too, with empty `ids`.
public struct Event: Decodable, Sendable {
    public var type: String
    public var chatID: String?
    public var ids: [String]?
    public var entries: [Message]?

    enum CodingKeys: CodingKey { case type, chatID, ids, entries }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        chatID = try c.decodeIfPresent(String.self, forKey: .chatID)
        ids = try c.decodeIfPresent([String].self, forKey: .ids)
        // entries are best-effort and may be partial; a bad one must not drop the event
        entries = try? c.decodeIfPresent([Message].self, forKey: .entries)
    }
}

extension JSONDecoder {
    /// The API sends ISO 8601 timestamps, with or without fractional seconds.
    public static let beeper: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = (try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                ?? (try? Date(s, strategy: .iso8601)) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date: \(s)"))
        }
        return d
    }()
}
