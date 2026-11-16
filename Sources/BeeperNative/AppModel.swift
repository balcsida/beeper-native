import AppKit
import BeeperKit
import Foundation
import Observation
import Security
import UserNotifications

@MainActor @Observable
final class AppModel {
    var chats: [Chat] = []
    var chatsCursor: String?
    var selection: Chat.ID? { didSet { if selection != oldValue { openSelected() } } }
    var messages: [Message] = []
    var messagesCursor: String?
    var error: String?
    /// Whether `error` came from a background refresh, which the next good refresh may clear.
    private var errorIsBackground = false
    /// Set by the composer, so ⌘V is only intercepted while typing a message.
    var composerFocused = false
    var inbox = BeeperClient.Inbox.primary
    /// Set while a search or a non-primary inbox is showing; nil means the live `chats` list.
    var searchResults: [Chat]?
    var searchCursor: String?
    var messageHits: [Message] = []
    var hitChats: [String: Chat] = [:]
    var hitsCursor: String?
    private var query = ""
    /// Whether the user loaded search pages past the first, which a live refresh must then keep.
    private var searchPaged = false
    /// The search hit to reveal once its chat has opened.
    private var pendingHit: Message?
    /// The message the chat view should scroll to and highlight.
    var scrollTarget: Message.ID?
    /// Bumped per jump, so jumping to the same message twice still scrolls.
    var scrollRequests = 0
    /// Identifies the newest jump, so an older one still paging gives way to it.
    private var revealGeneration = 0
    private var isLoadingOlder = false
    /// The selected chat as it was when opened, for chats outside the loaded list.
    private var openedChat: Chat?
    var replyingTo: Message?
    var editing: Message?
    var pendingFile: URL? {
        didSet {
            // pasted images are our own temp files: drop them once sent, replaced or removed
            if let oldValue, oldValue != pendingFile, oldValue.lastPathComponent.hasPrefix(Self.pastedPrefix),
                oldValue.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL
            {
                try? FileManager.default.removeItem(at: oldValue)
            }
        }
    }
    private static let pastedPrefix = "Pasted Image "
    var isSending = false
    private var notifier: Notifier?
    private var notified: Set<Message.ID> = []
    private let launched = Date()
    private(set) var client: BeeperClient?
    private var liveTask: Task<Void, Never>?

    init() {
        // BEEPER_TOKEN skips the Keychain prompt that every unsigned rebuild triggers.
        if let token = ProcessInfo.processInfo.environment["BEEPER_TOKEN"] ?? Keychain.token { connect(token: token) }
        // The text field swallows ⌘V itself, so files and images on the pasteboard are caught here.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                event.charactersIgnoringModifiers == "v"
            else { return event }
            return MainActor.assumeIsolated { self?.stagePasteboardFile() ?? false } ? nil : event  // monitors run on the main thread
        }
        if Notifier.available {
            notifier = Notifier { [weak self] chatID in
                self?.selection = chatID
                NSApp.activate()
            }
        }
    }

    var visibleChats: [Chat] {
        searchResults ?? chats.filter { $0.isArchived != true && $0.isLowPriority != true }
    }

    var selectedChat: Chat? {
        chats.first { $0.id == selection } ?? openedChat
    }

    /// Stages a copied file, or a copied image that has no text form, as the next attachment.
    private func stagePasteboardFile() -> Bool {
        guard selection != nil, composerFocused, editing == nil else { return false }
        let pasteboard = NSPasteboard.general
        if let file = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first {
            pendingFile = file
            return true
        }
        guard pasteboard.string(forType: .string) == nil, let image = NSImage(pasteboard: pasteboard),
            let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return false }
        let file = FileManager.default.temporaryDirectory.appending(path: "\(Self.pastedPrefix)\(UUID().uuidString.prefix(8)).png")
        guard (try? png.write(to: file)) != nil else { return false }
        pendingFile = file
        return true
    }

    /// IDs the networks know the user by, to tell their own reactions apart.
    private var selfIDs: Set<String> {
        Set(chats.flatMap { $0.participants?.items ?? [] }.filter { $0.isSelf == true }.map(\.id))
    }

    func signIn(token: String) {
        Keychain.token = token
        connect(token: token)
        if Keychain.token != token { error = "Couldn't save the token to the Keychain. You'll have to enter it again next time." }
    }

    func signOut() {
        Keychain.token = nil
        liveTask?.cancel()
        client = nil
        chats = []
        searchResults = nil
        messageHits = []
        selection = nil
        error = nil
        NSApp.dockTile.badgeLabel = nil
    }

    private func connect(token: String) {
        let client = BeeperClient(token: token)
        self.client = client
        liveTask?.cancel()
        liveTask = Task {
            while !Task.isCancelled {
                // background: a success here must not wipe an error the user has yet to read
                await refreshChats(background: true)
                await refreshMessages(background: true)  // catch up on what arrived while disconnected
                do {
                    // shortcut: refetches on every event instead of merging it, upgrade if bursts feel slow
                    for try await event in client.events() where event.chatID != nil {
                        await refreshChats(background: true)
                        await refreshSearch()
                        notify(event)
                        guard event.chatID == selection else { continue }
                        if event.type == "message.deleted" { messages.removeAll { event.ids?.contains($0.id) == true } }
                        await refreshMessages(background: true)
                        // only on new messages, so our own read receipt can't loop back here
                        if event.type == "message.upserted" { await markSelectedRead() }
                    }
                } catch {}
                try? await Task.sleep(for: .seconds(3))  // Beeper closed or restarting
            }
        }
    }

    /// Runs `work` and reports its failure in the banner. A background success leaves a user action's error up.
    @discardableResult
    private func attempt(background: Bool = false, _ work: () async throws -> Void) async -> Bool {
        do {
            try await work()
            if !background || errorIsBackground { error = nil }
            return true
        } catch is CancellationError {
        } catch let urlError as URLError where urlError.code == .cancelled {
        } catch BeeperError.http(401, _) {
            // a revoked or mistyped token never recovers: back to the sign-in form instead of retrying forever
            signOut()
            error = BeeperError.http(401, "").localizedDescription
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost {
            error = "Can't reach Beeper Desktop. Is it running, with the Desktop API enabled?"
            errorIsBackground = background
        } catch {
            self.error = error.localizedDescription
            errorIsBackground = background
        }
        return false
    }

    /// Marks the open chat read once the user can actually see it.
    func markSelectedRead() async {
        guard let client, let chatID = selection, NSApp.isActive, let chat = selectedChat,
            chat.unreadCount > 0 || chat.isMarkedUnread == true,
            (try? await client.markRead(chatID: chatID)) != nil
        else { return }
        // older pages and search results are never refetched, so clear their badge here
        func clear(_ chat: inout Chat) { (chat.unreadCount, chat.isMarkedUnread) = (0, false) }
        if let index = chats.firstIndex(where: { $0.id == chatID }) { clear(&chats[index]) }
        if let index = searchResults?.firstIndex(where: { $0.id == chatID }) { clear(&searchResults![index]) }
        if openedChat?.id == chatID { clear(&openedChat!) }
    }

    func refreshChats(background: Bool = false) async {
        guard let client else { return }
        await attempt(background: background) {
            let page = try await client.chats()
            // keep older pages the user already scrolled to
            let fresh = Set(page.items.map(\.id))
            let hadMore = !chats.isEmpty
            chats = page.items + chats.filter { !fresh.contains($0.id) }
            if !hadMore { chatsCursor = page.hasMore ? page.oldestCursor : nil }
            let unread = try await client.unreadChatCount()
            NSApp.dockTile.badgeLabel = unread > 0 ? String(unread) : nil
        }
    }

    /// Shows the live list for an empty query in the primary inbox, otherwise server-side matches.
    func search(_ query: String) async {
        guard let client else { return }
        self.query = query
        if query.isEmpty {
            messageHits = []
            hitsCursor = nil
        }
        if query.isEmpty, inbox == .primary {
            searchResults = nil
            return
        }
        let inbox = inbox
        await attempt {
            let page = try await client.searchChats(query, inbox: inbox)
            guard !Task.isCancelled else { return }
            searchResults = page.items
            searchCursor = page.hasMore ? page.oldestCursor : nil
            searchPaged = false
            guard !query.isEmpty else { return }
            let hits = try await client.searchMessages(query)
            guard !Task.isCancelled else { return }
            messageHits = hits.items
            hitChats = hits.chats
            hitsCursor = hits.hasMore ? hits.oldestCursor : nil
        }
    }

    /// Re-reads the first page of the shown search or inbox after a live event.
    private func refreshSearch() async {
        guard let client, searchResults != nil else { return }
        let (query, inbox) = (query, inbox)
        await attempt(background: true) {
            let page = try await client.searchChats(query, inbox: inbox)
            guard query == self.query, inbox == self.inbox, let shown = searchResults else { return }
            if searchPaged {
                // shortcut: rows on later pages keep their old state, refetch every loaded page if that shows
                let fresh = Set(page.items.map(\.id))
                searchResults = page.items + shown.filter { !fresh.contains($0.id) }
            } else {
                searchResults = page.items
                searchCursor = page.hasMore ? page.oldestCursor : nil
            }
        }
    }

    func loadMoreSearchResults() async {
        guard let client, let cursor = searchCursor else { return }
        searchCursor = nil
        let (query, inbox) = (query, inbox)
        let ok = await attempt {
            let page = try await client.searchChats(query, inbox: inbox, before: cursor)
            guard query == self.query, inbox == self.inbox, let shown = searchResults else { return }
            let known = Set(shown.map(\.id))
            searchResults = shown + page.items.filter { !known.contains($0.id) }
            searchCursor = page.hasMore ? page.oldestCursor : nil
            searchPaged = true
        }
        if !ok, query == self.query, inbox == self.inbox { searchCursor = cursor }
    }

    func loadMoreMessageHits() async {
        guard let client, let cursor = hitsCursor else { return }
        hitsCursor = nil
        let query = query
        let ok = await attempt {
            let hits = try await client.searchMessages(query, before: cursor)
            guard query == self.query else { return }
            let known = Set(messageHits.map(\.id))
            messageHits += hits.items.filter { !known.contains($0.id) }
            hitChats.merge(hits.chats) { $1 }
            hitsCursor = hits.hasMore ? hits.oldestCursor : nil
        }
        if !ok, query == self.query { hitsCursor = cursor }
    }

    func setArchived(_ archived: Bool, chat: Chat) async {
        guard let client else { return }
        await attempt {
            try await client.setArchived(archived, chatID: chat.id)
            if let index = chats.firstIndex(where: { $0.id == chat.id }) { chats[index].isArchived = archived }
            searchResults?.removeAll { $0.id == chat.id }
        }
    }

    func markUnread(_ chat: Chat) async {
        guard let client else { return }
        if selection == chat.id { selection = nil }  // staying in the chat would mark it read again
        await attempt { try await client.markUnread(chatID: chat.id) }
    }

    private func notify(_ event: Event) {
        guard Notifier.available, event.type == "message.upserted" else { return }
        for message in event.entries ?? []
        where message.isSender != true && message.isHidden != true && message.timestamp > launched
            && notified.insert(message.id).inserted
        {
            let chat = chats.first { $0.id == message.chatID }
            if NSApp.isActive && selection == message.chatID || chat?.isMuted == true || chat?.isArchived == true { continue }
            let content = UNMutableNotificationContent()
            content.title = chat?.title ?? message.senderName ?? "New message"
            if chat?.type == "group", let sender = message.senderName { content.subtitle = sender }
            content.body = message.text ?? "Attachment"
            content.sound = .default
            content.threadIdentifier = message.chatID
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: message.id, content: content, trigger: nil))
        }
    }

    func loadMoreChats() async {
        guard let client, let cursor = chatsCursor else { return }
        chatsCursor = nil  // one request at a time
        let ok = await attempt {
            let page = try await client.chats(before: cursor)
            let known = Set(chats.map(\.id))
            chats += page.items.filter { !known.contains($0.id) }
            chatsCursor = page.hasMore ? page.oldestCursor : nil
        }
        if !ok { chatsCursor = cursor }  // a failed page must stay retryable
    }

    private func openSelected() {
        messages = []
        messagesCursor = nil
        replyingTo = nil
        editing = nil
        pendingFile = nil
        openedChat = nil
        scrollTarget = nil
        let hit = pendingHit
        pendingHit = nil
        guard let chatID = selection else { return }
        openedChat = chats.first { $0.id == chatID } ?? searchResults?.first { $0.id == chatID } ?? hitChats[chatID]
        Task {
            // reached from a notification or a stale selection: the chat is in none of the loaded lists
            if openedChat == nil, let client, let chat = try? await client.chat(chatID), selection == chatID { openedChat = chat }
            await refreshMessages()
            await markSelectedRead()
            if let hit, hit.chatID == chatID { await reveal(hit) }
        }
    }

    /// Opens the chat of a search hit and scrolls to the message.
    func open(hit: Message) {
        if selection == hit.chatID {
            Task { await reveal(hit) }
        } else {
            pendingHit = hit
            selection = hit.chatID
        }
    }

    private func reveal(_ hit: Message) async {
        revealGeneration += 1
        let generation = revealGeneration
        var current: Bool { generation == revealGeneration && selection == hit.chatID }
        if messages.isEmpty { await refreshMessages() }
        // The API only pages backwards from the newest message, so walk back until the hit is loaded.
        // shortcut: gives up after 100 pages (about 2000 messages), load a window around the hit if that is too short
        var pages = 0
        while current, !messages.contains(where: { $0.id == hit.id }), pages < 100,
            (messages.first?.timestamp ?? .distantFuture) > hit.timestamp
        {
            if isLoadingOlder {  // someone else's page is in flight, and the cursor is nil until it lands
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            guard let before = messagesCursor else { break }
            await loadOlderMessages()
            pages += 1
            if messagesCursor == before { break }  // the page failed; its error is already in the banner
        }
        guard current else { return }
        if messages.contains(where: { $0.id == hit.id }) {
            scrollTarget = hit.id
            scrollRequests += 1
        } else if error == nil {
            error = "That message is too far back in the chat to jump to."
        }
    }

    func refreshMessages(background: Bool = false) async {
        guard let client, let chatID = selection else { return }
        await attempt(background: background) {
            let page = try await client.messages(chatID: chatID)
            guard selection == chatID else { return }
            let first = messages.isEmpty
            merge(page.items)
            if first { messagesCursor = page.hasMore ? page.oldestCursor : nil }
        }
    }

    func loadOlderMessages() async {
        guard let client, let chatID = selection, let cursor = messagesCursor else { return }
        messagesCursor = nil
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        let ok = await attempt {
            let page = try await client.messages(chatID: chatID, before: cursor)
            guard selection == chatID else { return }
            merge(page.items)
            messagesCursor = page.hasMore ? page.oldestCursor : nil
        }
        if !ok, selection == chatID { messagesCursor = cursor }
    }

    private func merge(_ new: [Message]) {
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        // hidden ones are reaction events, already shown on their target message
        for message in new where message.isHidden != true { byID[message.id] = message }
        messages = byID.values.sorted { ($0.timestamp, $0.sortKey) < ($1.timestamp, $1.sortKey) }
    }

    /// Sends the text with any staged file, or saves it as the edit in progress.
    /// Returns false when that failed, so the composer keeps the text.
    func send(_ text: String) async -> Bool {
        guard let client, let chatID = selection, !isSending else { return false }
        isSending = true
        defer { isSending = false }
        var sent = false
        let (reply, edit, file) = (replyingTo, editing, pendingFile)
        await attempt {
            if let edit {
                try await client.edit(edit.id, in: chatID, text: text)
            } else {
                var uploadID: String?
                if let file { uploadID = try await client.upload(file) }
                try await client.send(text.isEmpty ? nil : text, to: chatID, replyTo: reply?.id, uploadID: uploadID)
            }
            sent = true
        }
        if sent, selection == chatID {
            (replyingTo, editing, pendingFile) = (nil, nil, nil)
            await refreshMessages()
        }
        return sent
    }

    func delete(_ message: Message) async {
        guard let client else { return }
        await attempt {
            try await client.delete(message.id, in: message.chatID)
            messages.removeAll { $0.id == message.id }
        }
    }

    func toggleReaction(_ key: String, on message: Message) async {
        guard let client else { return }
        let mine = message.reactions?.contains { $0.reactionKey == key && selfIDs.contains($0.participantID) } ?? false
        await attempt { try await client.setReaction(key, on: message.id, in: message.chatID, added: !mine) }
        await refreshMessages()
    }
}

/// Posts banners and routes a click on one back to its chat. Needs an app bundle, so `swift run` goes without.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let available = Bundle.main.bundleIdentifier != nil
    private let open: @MainActor @Sendable (String) -> Void

    init(open: @escaping @MainActor @Sendable (String) -> Void) {
        self.open = open
        super.init()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await open(response.notification.request.content.threadIdentifier)
    }
}

/// The token reads every chat, so it lives in the Keychain, not UserDefaults.
enum Keychain {
    private static var query: [CFString: Any] { [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "beeper-native",
        kSecAttrAccount: "desktop-api-token",
    ] }

    static var token: String? {
        get {
            var result: CFTypeRef?
            let q = query.merging([kSecReturnData: true]) { $1 }
            guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            SecItemDelete(query as CFDictionary)
            guard let newValue else { return }
            SecItemAdd(query.merging([kSecValueData: Data(newValue.utf8)]) { $1 } as CFDictionary, nil)
        }
    }
}
