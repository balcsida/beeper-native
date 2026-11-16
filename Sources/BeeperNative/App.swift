import AppKit
import BeeperKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct BeeperNativeApp: App {
    @State private var model = AppModel()

    init() {
        // A bare SwiftPM executable is not a bundle: without this it gets no Dock icon or key window.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup("Beeper") {
            Group {
                if model.client == nil { SignInView() } else { MainView() }
            }
            .environment(model)
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Sign Out") { model.signOut() }.disabled(model.client == nil)
            }
        }
    }
}

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""

    var body: some View {
        Form {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            Text("In Beeper Desktop, open Settings → Integrations, enable the Desktop API, and add an approved connection to get an access token.")
                .foregroundStyle(.secondary)
            SecureField("Access token", text: $token)
                .onSubmit(signIn)
            Button("Connect", action: signIn)
                .keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
        .padding()
    }

    private func signIn() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { model.signIn(token: trimmed) }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.visibleChats) { chat in
                    ChatRow(chat: chat)
                        .contextMenu {
                            Button(chat.isArchived == true ? "Unarchive" : "Archive") {
                                Task { await model.setArchived(chat.isArchived != true, chat: chat) }
                            }
                            Button("Mark as Unread") { Task { await model.markUnread(chat) } }
                        }
                }
                if model.searchResults == nil ? model.chatsCursor != nil : model.searchCursor != nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task { await model.searchResults == nil ? model.loadMoreChats() : model.loadMoreSearchResults() }
                }
                if !model.messageHits.isEmpty {
                    Section("Messages") {
                        ForEach(model.messageHits) { hit in
                            // a button, not a tag: several hits share one chat ID and would all highlight
                            Button { model.selection = hit.chatID } label: {
                                MessageHitRow(hit: hit, chat: model.hitChats[hit.chatID])
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                        if model.hitsCursor != nil {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .task { await model.loadMoreMessageHits() }
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search chats and messages")
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Inbox", selection: $model.inbox) {
                    Text("Inbox").tag(BeeperClient.Inbox.primary)
                    Text("Low Priority").tag(BeeperClient.Inbox.lowPriority)
                    Text("Archive").tag(BeeperClient.Inbox.archive)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
            }
            .task(id: "\(model.inbox.rawValue)|\(search)") {
                try? await Task.sleep(for: .milliseconds(250))  // wait out fast typing
                if !Task.isCancelled { await model.search(search) }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            if let chat = model.selectedChat {
                ChatView(chat: chat)
            } else {
                ContentUnavailableView("No Chat Selected", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let error = model.error {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                    Button("Dismiss", systemImage: "xmark") { model.error = nil }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                }
                .font(.callout)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.yellow.opacity(0.25))
            }
        }
        .frame(minWidth: 700, minHeight: 420)
        // a message that arrived in the open chat while the app was in the background is seen now
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.markSelectedRead() }
        }
    }
}

struct ChatRow: View {
    let chat: Chat

    var body: some View {
        HStack(spacing: 10) {
            Avatar(url: chat.imgURL ?? chat.participants?.items.first { $0.isSelf != true }?.imgURL, name: chat.title)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(chat.title).fontWeight(chat.unreadCount > 0 || chat.isMarkedUnread == true ? .semibold : .regular).lineLimit(1)
                    Spacer()
                    if let date = chat.lastActivity {
                        Text(date, format: Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.day().month())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(chat.preview?.text ?? chat.network).lineLimit(1).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if chat.unreadCount > 0 || chat.isMarkedUnread == true {
                        Text(chat.unreadCount > 0 ? "\(chat.unreadCount)" : " ")
                            .font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(chat.isMuted == true ? Color.secondary : Color.accentColor, in: .capsule)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct MessageHitRow: View {
    let hit: Message
    let chat: Chat?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(chat?.title ?? "Chat").lineLimit(1)
                Spacer()
                Text(hit.timestamp, format: .dateTime.day().month().year(.twoDigits))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(hit.isSender == true ? "You" : hit.senderName ?? ""): \(hit.text ?? "Attachment")")
                .lineLimit(2).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct ChatView: View {
    @Environment(AppModel.self) private var model
    let chat: Chat
    @State private var draft = ""
    @State private var pickingFile = false
    @State private var deleting: Message?
    @FocusState private var composerFocused: Bool

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                if model.messagesCursor != nil {
                    Button("Load Earlier Messages") { Task { await model.loadOlderMessages() } }
                        .buttonStyle(.link)
                }
                ForEach(model.messages) { message in
                    MessageRow(
                        message: message, showSender: chat.type == "group",
                        quoted: message.linkedMessageID.flatMap { id in model.messages.first { $0.id == id } }
                    )
                    .contextMenu { menu(for: message) }
                }
            }
            .padding()
        }
        .defaultScrollAnchor(.bottom)
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle(chat.title)
        .navigationSubtitle(chat.network)
        .onChange(of: chat.id, initial: true) {
            draft = ""
            composerFocused = true
        }
        .onChange(of: composerFocused, initial: true) { model.composerFocused = composerFocused }
        .onDisappear { model.composerFocused = false }
        // files are staged, never sent on drop: a stray drag must not post into a chat
        .dropDestination(for: URL.self) { files, _ in
            guard let file = files.first(where: \.isFileURL) else { return false }
            model.pendingFile = file
            return true
        }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.item]) { result in
            if case .success(let file) = result { model.pendingFile = file }
        }
        .confirmationDialog(
            "Delete this message?", isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting
        ) { message in
            Button("Delete", role: .destructive) { Task { await model.delete(message) } }
        } message: { _ in
            Text("It is removed for everyone where the network allows that.")
        }
    }

    @ViewBuilder private func menu(for message: Message) -> some View {
        if message.isDeleted != true {
            Button("Reply") {
                model.replyingTo = message
                composerFocused = true
            }
            if let text = message.text, !text.isEmpty {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            Menu("React") {
                ForEach(["👍", "❤️", "😂", "😮", "😢", "🙏"], id: \.self) { emoji in
                    Button(emoji) { Task { await model.toggleReaction(emoji, on: message) } }
                }
            }
            if message.isSender == true {
                Divider()
                if let text = message.text, !text.isEmpty {
                    Button("Edit") {
                        model.editing = message
                        draft = text
                        composerFocused = true
                    }
                }
                Button("Delete…", role: .destructive) { deleting = message }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.editing != nil {
                banner("Editing message", cancel: "Cancel Edit") {
                    model.editing = nil
                    draft = ""
                }
            } else if let reply = model.replyingTo {
                banner("Replying to \(reply.senderName ?? "message"): \(reply.text ?? "Attachment")", cancel: "Cancel Reply") {
                    model.replyingTo = nil
                }
            }
            if let file = model.pendingFile, model.editing == nil {
                banner("📎 \(file.lastPathComponent)", cancel: "Remove Attachment") { model.pendingFile = nil }
            }
            HStack(alignment: .bottom) {
                Button("Attach File", systemImage: "paperclip") { pickingFile = true }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .onSubmit(send)
                if model.isSending { ProgressView().controlSize(.small) }
            }
        }
        .padding(10)
        .background(.bar)
    }

    private func banner(_ text: String, cancel: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(text).lineLimit(1).truncationMode(.middle).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button(cancel, systemImage: "xmark.circle.fill", action: action)
                .labelStyle(.iconOnly).buttonStyle(.plain)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // an edit needs text; a new message needs text or a staged file
        guard !text.isEmpty || (model.pendingFile != nil && model.editing == nil) else { return }
        draft = ""
        Task {
            // put the text back rather than lose it if the send fails
            if await !model.send(text), draft.isEmpty { draft = text }
        }
    }
}

struct MessageRow: View {
    let message: Message
    let showSender: Bool
    let quoted: Message?

    private var mine: Bool { message.isSender == true }

    private var images: [String] {
        message.isDeleted == true ? [] : (message.attachments ?? []).filter { $0.type == "img" }.compactMap(\.srcURL)
    }

    private var content: String {
        if message.isDeleted == true { return "Message deleted" }
        let files = (message.attachments ?? []).filter { $0.type != "img" }.map { "📎 " + ($0.fileName ?? $0.type) }
        return ([message.text].compactMap { $0 }.filter { !$0.isEmpty } + files).joined(separator: "\n")
    }

    /// "👍 2 ❤️" from one entry per person.
    private var reactions: String {
        let counts = Dictionary((message.reactions ?? []).map { ($0.reactionKey, 1) }, uniquingKeysWith: +)
        return counts.sorted { $0.key < $1.key }.map { $1 > 1 ? "\($0) \($1)" : $0 }.joined(separator: "  ")
    }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            if showSender, !mine, let name = message.senderName {
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
            if let quoted {
                Text("↩ \(quoted.senderName ?? ""): \(quoted.text ?? "Attachment")")
                    .lineLimit(2).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(images, id: \.self) { url in
                RemoteImage(url: url) { Color.secondary.opacity(0.2) }
                    .frame(maxWidth: 280, maxHeight: 280)
                    .clipShape(.rect(cornerRadius: 14))
                    .accessibilityLabel("Image")
            }
            if !content.isEmpty || images.isEmpty {
                Text(content.isEmpty ? "Unsupported message" : content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .foregroundStyle(mine ? .white : .primary)
                    .background(mine ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: .rect(cornerRadius: 14))
            }
            if !reactions.isEmpty {
                Text(reactions).font(.caption)
            }
        }
        .frame(maxWidth: 520, alignment: mine ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .help(message.timestamp.formatted(date: .abbreviated, time: .shortened))
    }
}

struct Avatar: View {
    let url: String?
    let name: String

    var body: some View {
        RemoteImage(url: url) {
            ZStack {
                Color.secondary.opacity(0.3)
                Text(name.prefix(1).uppercased()).font(.headline).foregroundStyle(.secondary)
            }
        }
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}

/// An avatar or attachment fetched through Beeper, which holds the keys to decrypt it.
struct RemoteImage<Placeholder: View>: View {
    @Environment(AppModel.self) private var model
    let url: String?
    @ViewBuilder var placeholder: Placeholder
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                placeholder
            }
        }
        .task(id: url) {
            image = nil
            guard let url, let client = model.client else { return }
            if let cached = ImageCache.shared.object(forKey: url as NSString) {
                image = cached
            } else if let data = try? await client.asset(url), let loaded = NSImage(data: data) {
                ImageCache.shared.setObject(loaded, forKey: url as NSString)
                image = loaded
            }
        }
    }
}

@MainActor enum ImageCache {
    static let shared = NSCache<NSString, NSImage>()
}
