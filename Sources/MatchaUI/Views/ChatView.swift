import MatchaCore
import SwiftUI

/// The conversation pane: transcript above, composer below.
struct ChatView: View {
    let environment: AppEnvironment
    @State private var drafts: [ComposerDraftKey: ComposerDraft] = [:]
    @State private var showingGroupMembers = false
    @State private var pendingHistoryClear: PendingHistoryClear?
    @State private var historyClearError: String?

    var body: some View {
        if let chat = environment.selectedChat {
            let draftKey = ComposerDraftKey(chat: chat, senderID: environment.activeUserID)
            transcript(for: chat)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Composer(
                        environment: environment,
                        chat: chat,
                        senderID: draftKey.senderID,
                        draft: draftBinding(for: draftKey)
                    )
                        .id(draftKey)
                        .frame(maxWidth: 900)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 14)
            }
            .navigationTitle(title(for: chat))
            .navigationSubtitle(subtitle(for: chat))
            .toolbar {
                if chat.scene == .group {
                    ToolbarItem {
                        Button {
                            showingGroupMembers = true
                        } label: {
                            Label("Group Members", systemImage: "person.3")
                        }
                        .help("Manage group members")
                    }
                }
            }
            .sheet(isPresented: $showingGroupMembers) {
                GroupMembersSheet(environment: environment, groupID: chat.peerID)
            }
            .confirmationDialog(
                pendingHistoryClear.map { "Clear all messages in \($0.title)?" }
                    ?? "Clear Chat History?",
                isPresented: historyClearConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Clear Chat History", role: .destructive) {
                    guard let request = pendingHistoryClear else { return }
                    pendingHistoryClear = nil
                    Task { await clearHistory(request.chat) }
                }
                Button("Cancel", role: .cancel) {
                    pendingHistoryClear = nil
                }
            } message: {
                Text(
                    "This permanently deletes every message saved in this conversation. "
                        + "The friend or group chat will not be deleted."
                )
            }
            .alert("Unable to Clear Chat History", isPresented: historyClearErrorPresented) {
                Button("OK") { historyClearError = nil }
            } message: {
                Text(historyClearError ?? "Unknown error")
            }
        } else {
            ContentUnavailableView(
                "No Conversation Selected",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Select a conversation in the sidebar, or create a persona to start simulating a chat.")
            )
        }
    }

    private func transcript(for chat: Chat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(environment.messages) { message in
                        MessageRow(message: message, chat: chat, environment: environment)
                        .id(message.id)
                    }
                }
                .frame(maxWidth: 920)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .contextMenu {
                Button("Clear Chat History…", systemImage: "trash", role: .destructive) {
                    pendingHistoryClear = PendingHistoryClear(
                        chat: chat,
                        title: environment.conversationTitle(for: chat)
                    )
                }
            }
            // Keep the newest message in view as traffic arrives.
            .onChange(of: environment.messages.last?.id) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(newValue, anchor: .bottom)
                }
            }
        }
    }

    /// Drafts are window-local and keyed by the stable conversation identity, so
    /// switching chats never moves unfinished text into another recipient.
    private func draftBinding(for key: ComposerDraftKey) -> Binding<ComposerDraft> {
        Binding(
            get: { drafts[key] ?? ComposerDraft() },
            set: { value in
                if value.isEmpty {
                    drafts.removeValue(forKey: key)
                } else {
                    drafts[key] = value
                }
            }
        )
    }

    private var historyClearConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingHistoryClear != nil },
            set: { if !$0 { pendingHistoryClear = nil } }
        )
    }

    private var historyClearErrorPresented: Binding<Bool> {
        Binding(
            get: { historyClearError != nil },
            set: { if !$0 { historyClearError = nil } }
        )
    }

    private func clearHistory(_ chat: Chat) async {
        do {
            try await environment.clearMessageHistory(in: chat)
            historyClearError = nil
        } catch {
            historyClearError = error.localizedDescription
        }
    }

    private func title(for chat: Chat) -> String {
        environment.conversationTitle(for: chat)
    }

    private func subtitle(for chat: Chat) -> String {
        switch chat.scene {
        case .group: return "Group \(chat.peerID)"
        case .friend:
            let peerID = environment.displayedPeerID(for: chat) ?? chat.peerID
            return environment.isFriend(chat.peerID)
                ? "Friend \(peerID)"
                : "Not a Friend \(peerID)"
        case .temp:
            return "Temporary Chat \(environment.displayedPeerID(for: chat) ?? chat.peerID)"
        }
    }
}

private struct PendingHistoryClear {
    let chat: Chat
    let title: String
}

struct ComposerDraftKey: Hashable {
    let chat: Chat
    let senderID: User.ID?
}

/// One message bubble.
///
/// The transcript is rendered from the selected speaking identity's perspective:
/// its messages stay on the right and every other participant stays on the left.
/// `Message.direction` remains protocol-origin metadata and is deliberately not a
/// layout flag.
struct MessageRow: View {
    let message: Message
    let chat: Chat
    let environment: AppEnvironment

    private var isFromActiveUser: Bool {
        guard let activeUserID = environment.activeUserID else { return false }
        return message.senderID == activeUserID
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isFromActiveUser { Spacer(minLength: 60) }

            if !isFromActiveUser {
                AvatarView(name: senderName, path: senderAvatar, size: 32)
            }

            VStack(alignment: isFromActiveUser ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(senderName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(message.time, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let badge = roleBadge {
                        Text(badge)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.15), in: .rect(cornerRadius: 3))
                    }
                }

                bubble
            }
            .frame(maxWidth: 640, alignment: isFromActiveUser ? .trailing : .leading)

            if isFromActiveUser {
                AvatarView(name: senderName, path: senderAvatar, size: 32)
            }
            if !isFromActiveUser { Spacer(minLength: 60) }
        }
        .contextMenu {
            if canAddSenderAsFriend {
                Button("Add Friend", systemImage: "person.badge.plus") {
                    addSenderAsFriend()
                }
            }

            if privateConversation != nil {
                Button("Start Conversation", systemImage: "bubble.left") {
                    startConversationWithSender()
                }
            }

            if canAddSenderAsFriend || privateConversation != nil {
                Divider()
            }

            Button("Recall") {
                Task { await environment.recall(message) }
            }
            .disabled(message.isRecalled)

            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content.plainText, forType: .string)
            }

            Button("Copy Message ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.id, forType: .string)
            }
        }
    }

    private var senderActionsAvailable: Bool {
        guard chat.scene == .group,
              environment.botUserID == chat.selfID
        else {
            return false
        }
        return environment.users.contains { $0.id == message.senderID }
    }

    private var privateConversation: Chat? {
        guard senderActionsAvailable else { return nil }
        return environment.privateChat(with: message.senderID)
    }

    private var canAddSenderAsFriend: Bool {
        guard let privateConversation else { return false }
        return !environment.isFriend(privateConversation.peerID)
    }

    private func addSenderAsFriend() {
        guard canAddSenderAsFriend else { return }
        Task {
            do {
                try await environment.addFriend(with: message.senderID)
            } catch {
                environment.lastError = error.localizedDescription
            }
        }
    }

    private func startConversationWithSender() {
        guard privateConversation != nil else { return }
        environment.openPrivateChat(with: message.senderID)
    }

    @ViewBuilder
    private var bubble: some View {
        if message.isRecalled {
            Text("Recalled")
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: .rect(cornerRadius: 10))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(message.content.enumerated()), id: \.offset) { _, segment in
                    SegmentView(segment: segment, environment: environment, chat: chat)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isFromActiveUser
                    ? AnyShapeStyle(.tint.opacity(0.18))
                    : AnyShapeStyle(.quaternary),
                in: .rect(cornerRadius: 10)
            )
            .textSelection(.enabled)
        }
    }

    private var senderName: String {
        environment.displayName(for: message.senderID, in: chat)
    }

    private var senderAvatar: String? {
        environment.users.first { $0.id == message.senderID }?.avatar
    }

    /// Owner and admin labels, from the roster loaded when the chat opened.
    private var roleBadge: String? {
        guard message.scene == .group else { return nil }
        switch environment.role(of: message.senderID, in: message.peerID) {
        case .owner: return "Owner"
        case .admin: return "Admin"
        case .member, nil: return nil
        }
    }
}

/// Renders one message segment.
struct SegmentView: View {
    let segment: MessageSegment
    let environment: AppEnvironment
    let chat: Chat

    var body: some View {
        switch segment {
        case let .text(text):
            Text(text)

        case let .mention(userID):
            Text(userID == nil ? "@everyone" : "@\(environment.displayName(for: userID!, in: chat))")
                .foregroundStyle(.tint)

        case let .face(_, name):
            Text(name.map { "[\($0)]" } ?? "[Emoji]")
                .foregroundStyle(.secondary)

        case let .image(asset):
            ImageSegmentView(asset: asset)

        case let .record(asset, duration):
            attachment(icon: "waveform", label: durationLabel(asset: asset, duration: duration))

        case let .video(asset):
            attachment(icon: "film", label: asset.name)

        case let .file(asset):
            attachment(icon: "doc", label: "\(asset.name) · \(byteLabel(asset.byteCount))")

        case let .reply(messageID):
            QuotedMessageView(messageID: messageID, environment: environment, chat: chat)

        case .poke:
            attachment(icon: "hand.point.right", label: "Poke")

        case let .forward(_, nodes):
            ForwardSegmentView(nodes: nodes, environment: environment, chat: chat)

        case let .unsupported(type, _):
            attachment(icon: "questionmark.square.dashed", label: "Unsupported message segment: \(type)")
        }
    }

    private func attachment(icon: String, label: String) -> some View {
        Label(label, systemImage: icon)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func durationLabel(asset: Asset, duration: TimeInterval?) -> String {
        guard let duration, duration > 0 else { return "Voice" }
        return "Voice \(Int(duration.rounded()))s"
    }

    private func byteLabel(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

/// An inline image, capped so a large attachment does not dominate the transcript.
struct ImageSegmentView: View {
    let asset: Asset

    var body: some View {
        if let image = loadedImage {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240, maxHeight: 240)
                .clipShape(.rect(cornerRadius: 6))
        } else {
            Label("[Image] \(asset.name)", systemImage: "photo")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var loadedImage: NSImage? {
        if case let .local(path) = asset.source {
            return NSImage(contentsOfFile: path)
        }
        return nil
    }
}

/// The message a reply quotes.
struct QuotedMessageView: View {
    let messageID: String
    let environment: AppEnvironment
    let chat: Chat
    @State private var quoted: Message?

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(.tint).frame(width: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(quoted.map { environment.displayName(for: $0.senderID, in: chat) } ?? "Quoted Message")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(quoted?.content.textPreview ?? messageID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .task(id: messageID) {
            quoted = await environment.quotedMessage(id: messageID)
        }
    }
}

/// A merged-forward bundle, collapsed to its preview lines.
struct ForwardSegmentView: View {
    let nodes: [MessageSegment.ForwardNode]
    let environment: AppEnvironment
    let chat: Chat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Forwarded Messages", systemImage: "rectangle.stack")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(nodes.prefix(3)) { node in
                Text("\(node.senderName): \(node.content.textPreview)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if nodes.count > 3 {
                Text("\(nodes.count) messages")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(6)
        .background(.quinary, in: .rect(cornerRadius: 6))
    }
}
