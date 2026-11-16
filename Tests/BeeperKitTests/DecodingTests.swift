import Foundation
import Testing
@testable import BeeperKit

@Test func decodesChatPage() throws {
    let json = #"""
    {"items":[{"id":"!a:b.local-whatsapp.localhost","accountID":"wa","network":"WhatsApp","title":"Anna",
      "type":"single","unreadCount":2,"participants":{"items":[{"id":"u1","fullName":"Anna"}],"hasMore":false,"total":1},
      "lastActivity":"2026-11-16T10:00:00.123Z",
      "preview":{"id":"m1","accountID":"wa","chatID":"!a:b.local-whatsapp.localhost","senderID":"u1","sortKey":"1",
        "timestamp":"2026-11-16T10:00:00Z","text":"hi","seen":{"u2":true}}}],
     "hasMore":true,"oldestCursor":"c1","newestCursor":null}
    """#
    let page = try JSONDecoder.beeper.decode(Page<Chat>.self, from: Data(json.utf8))
    #expect(page.items[0].preview?.text == "hi")
    #expect(page.items[0].lastActivity != nil)
    #expect(page.oldestCursor == "c1")
}

@Test func eventSurvivesPartialEntries() throws {
    let json = #"{"type":"message.upserted","seq":1,"ts":1,"chatID":"c","ids":["m1"],"entries":[{"id":"m1","reactions":[]}]}"#
    let event = try JSONDecoder.beeper.decode(Event.self, from: Data(json.utf8))
    #expect(event.ids == ["m1"])
    #expect(event.entries == nil)
}

/// Runs only with BEEPER_TOKEN set and Beeper Desktop open: checks the models against the real API.
@Test(.enabled(if: ProcessInfo.processInfo.environment["BEEPER_TOKEN"] != nil))
func liveAPI() async throws {
    let client = BeeperClient(token: ProcessInfo.processInfo.environment["BEEPER_TOKEN"]!)
    let chats = try await client.chats()
    let first = try #require(chats.items.first)
    #expect(try await client.chats(before: chats.oldestCursor).items.first?.id != first.id)
    #expect(try await !client.messages(chatID: first.id).items.isEmpty)
    if let avatar = chats.items.compactMap(\.imgURL).first {
        #expect(try await !client.asset(avatar).isEmpty)
    }
    // the socket must accept the subscription; "ready" arrives without any chat activity
    var events = client.events().makeAsyncIterator()
    #expect(try await events.next()?.type == "ready")
}

/// Uploading only stages a temp file in Beeper; nothing is sent to any chat.
@Test(.enabled(if: ProcessInfo.processInfo.environment["BEEPER_TOKEN"] != nil))
func liveUploadAndSearch() async throws {
    let client = BeeperClient(token: ProcessInfo.processInfo.environment["BEEPER_TOKEN"]!)
    let file = FileManager.default.temporaryDirectory.appending(path: "beeper \"probe\".txt")
    try Data("hello".utf8).write(to: file)
    #expect(try await !client.upload(file).isEmpty)
    #expect(try await !client.searchChats("", inbox: .primary).items.isEmpty)
}

/// Writes to the user's own "Note to self" chat and deletes what it wrote. Opt in with BEEPER_SELF_TEST=1.
@Test(.enabled(if: ProcessInfo.processInfo.environment["BEEPER_SELF_TEST"] != nil))
func liveNoteToSelf() async throws {
    let client = BeeperClient(token: ProcessInfo.processInfo.environment["BEEPER_TOKEN"]!)
    let chat = try #require(try await client.searchChats("Note to self").items.first {
        $0.participants?.items.allSatisfy { $0.isSelf == true } == true
    })
    let marker = "beeper-native test \(UUID().uuidString.prefix(8))"

    func find(_ text: String) async throws -> Message {
        for _ in 0..<20 {
            if let hit = try await client.messages(chatID: chat.id).items.first(where: { $0.text?.contains(text) == true && Int($0.id) != nil }) { return hit }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw BeeperError.http(0, "message never appeared: \(text)")
    }

    try await client.send(marker, to: chat.id)
    let sent = try await find(marker)
    #expect(sent.isSender == true)

    try await client.send("\(marker) reply", to: chat.id, replyTo: sent.id)
    let reply = try await find("\(marker) reply")
    #expect(reply.linkedMessageID == sent.id)

    try await client.setReaction("👍", on: sent.id, in: chat.id, added: true)
    try await Task.sleep(for: .seconds(2))
    let reacted = try await client.messages(chatID: chat.id).items.first { $0.id == sent.id }
    #expect(reacted?.reactions?.contains { $0.reactionKey == "👍" } == true)
    try await client.setReaction("👍", on: sent.id, in: chat.id, added: false)

    try await client.edit(reply.id, in: chat.id, text: "\(marker) edited")
    let edited = try await find("\(marker) edited")
    #expect(edited.id == reply.id)

    let file = FileManager.default.temporaryDirectory.appending(path: "\(marker).txt")
    try Data("hello".utf8).write(to: file)
    try await client.send(nil, to: chat.id, uploadID: try await client.upload(file))
    try await Task.sleep(for: .seconds(3))
    let withFile = try #require(try await client.messages(chatID: chat.id).items.first { $0.attachments?.first?.fileName?.contains(marker) == true })

    #expect(try await client.searchMessages(marker).items.contains { $0.chatID == chat.id })
    #expect(try await client.unreadChatCount() >= 0)

    for id in [sent.id, reply.id, withFile.id] { try await client.delete(id, in: chat.id) }
    try await Task.sleep(for: .seconds(2))
    let left = try await client.messages(chatID: chat.id).items.filter { $0.isDeleted != true && ($0.text?.contains(marker) == true || $0.attachments?.first?.fileName?.contains(marker) == true) }
    #expect(left.isEmpty)
}

@Test func urlEncodesEachPart() {
    let url = BeeperClient.url(URL(string: "http://localhost:23373")!, ["v1", "chats", "!a/../b:c", "messages"], ["query": "c++ a&b", "skip": nil])
    #expect(url.absoluteString == "http://localhost:23373/v1/chats/!a%2F..%2Fb:c/messages?query=c%2B%2B%20a%26b")
}
