import AppKit
import MatchaCore
import SwiftUI

/// A native source list for conversations and pending platform requests.
@MainActor
struct SidebarView: View {
    let environment: AppEnvironment
    @Binding var selectedSettingsTab: MatchaSettingsTab

    @State private var query = ""
    @State private var pendingDestructiveAction: SidebarDestructiveAction?
    @State private var deletionError: String?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selectionBinding) {
                if !matchingRequests.isEmpty {
                    Section("Pending Requests") {
                        ForEach(matchingRequests) { request in
                            RequestRow(request: request, environment: environment)
                        }
                    }
                }

                Section {
                    ForEach(matchingConversations) { summary in
                        ConversationRow(summary: summary, environment: environment)
                            .tag(summary.chat)
                            .contextMenu {
                                conversationActions(for: summary)
                            }
                    }

                    ForEach(matchingUnstartedGroups) { group in
                        if let chat = chat(scene: .group, peerID: group.id) {
                            SidebarPeerRow(
                                title: group.name,
                                detail: "No Messages Yet",
                                systemImage: "person.3"
                            )
                            .tag(chat)
                            .contextMenu {
                                Button("Start Conversation") { environment.selectChat(chat) }
                                Button("Copy Group ID") { copy(group.id) }
                                Divider()
                                Button("Delete Group Chat…", systemImage: "trash", role: .destructive) {
                                    pendingDestructiveAction = .deleteGroup(
                                        id: group.id,
                                        name: group.name
                                    )
                                }
                            }
                        }
                    }

                    ForEach(matchingUnstartedPrivateChats) { candidate in
                        SidebarPeerRow(
                            title: candidate.user.displayName,
                            detail: candidate.isFriend ? "No Messages Yet" : "Not a Friend",
                            systemImage: "person"
                        )
                        .tag(candidate.chat)
                        .contextMenu {
                            Button(candidate.isFriend ? "Start Conversation" : "Start Temporary Chat") {
                                environment.selectChat(candidate.chat)
                            }
                            Button("Copy Account ID") { copy(candidate.user.id) }

                            if candidate.isFriend {
                                Divider()
                                Button("Remove Friend…", systemImage: "person.badge.minus", role: .destructive) {
                                    pendingDestructiveAction = .removeFriend(
                                        id: candidate.chat.peerID,
                                        name: candidate.user.displayName
                                    )
                                }
                            }
                        }
                    }

                    if hasNoMatches {
                        Text(query.isEmpty ? "No Conversations Yet" : "No Matching Conversations")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Conversations")
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $query, placement: .sidebar, prompt: "Search Conversations")

            if !environment.users.isEmpty {
                Divider()
                PersonaBar(
                    environment: environment,
                    selectedSettingsTab: $selectedSettingsTab
                )
            }
        }
        .confirmationDialog(
            pendingDestructiveAction?.title ?? "Confirm Deletion?",
            isPresented: destructiveActionPresented,
            titleVisibility: .visible
        ) {
            if let action = pendingDestructiveAction {
                Button(action.buttonTitle, role: .destructive) {
                    pendingDestructiveAction = nil
                    Task { await perform(action) }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDestructiveAction = nil
            }
        } message: {
            Text(pendingDestructiveAction?.message ?? "")
        }
        .alert("Unable to Complete Action", isPresented: deletionErrorPresented) {
            Button("OK") { deletionError = nil }
        } message: {
            Text(deletionError ?? "Unknown error")
        }
    }

    private var selectionBinding: Binding<Chat?> {
        Binding(
            get: { environment.selectedChat },
            set: { environment.selectChat($0) }
        )
    }

    private var destructiveActionPresented: Binding<Bool> {
        Binding(
            get: { pendingDestructiveAction != nil },
            set: { if !$0 { pendingDestructiveAction = nil } }
        )
    }

    private var deletionErrorPresented: Binding<Bool> {
        Binding(
            get: { deletionError != nil },
            set: { if !$0 { deletionError = nil } }
        )
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
    }

    private var matchingConversations: [ConversationSummary] {
        let visible = environment.conversations.filter { summary in
            summary.chat.scene == .group
                || environment.displayedPeerID(for: summary.chat) != nil
        }
        guard !normalizedQuery.isEmpty else { return visible }
        return visible.filter { summary in
            environment.conversationTitle(for: summary.chat)
                .localizedCaseInsensitiveContains(normalizedQuery)
                || environment.conversationPreview(for: summary)
                    .localizedCaseInsensitiveContains(normalizedQuery)
                || displayedID(for: summary.chat)
                    .localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    private var matchingRequests: [PendingRequest] {
        guard !normalizedQuery.isEmpty else { return environment.pendingRequests }
        return environment.pendingRequests.filter { request in
            request.comment.localizedCaseInsensitiveContains(normalizedQuery)
                || environment.displayName(for: request.requesterID, in: nil)
                    .localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    private var matchingUnstartedGroups: [MatchaCore.Group] {
        let active = Set(
            environment.conversations
                .filter { $0.chat.scene == .group }
                .map(\.chat.peerID)
        )
        let available = environment.groups.filter { !active.contains($0.id) }
        guard !normalizedQuery.isEmpty else { return available }
        return available.filter {
            $0.name.localizedCaseInsensitiveContains(normalizedQuery)
                || $0.id.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    private var matchingUnstartedPrivateChats: [SidebarPrivateChatCandidate] {
        let activePeerIDs = Set(
            environment.conversations
                .filter { $0.chat.scene != .group }
                .map(\.chat.peerID)
        )
        let available = environment.users.compactMap { user -> SidebarPrivateChatCandidate? in
            guard let chat = environment.privateChat(with: user.id),
                  !activePeerIDs.contains(chat.peerID)
            else {
                return nil
            }
            return SidebarPrivateChatCandidate(
                chat: chat,
                user: user,
                isFriend: environment.isFriend(chat.peerID)
            )
        }
        guard !normalizedQuery.isEmpty else { return available }
        return available.filter { candidate in
            candidate.user.displayName.localizedCaseInsensitiveContains(normalizedQuery)
                || candidate.user.id.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    private var hasNoMatches: Bool {
        matchingConversations.isEmpty
            && matchingUnstartedGroups.isEmpty
            && matchingUnstartedPrivateChats.isEmpty
    }

    private func chat(scene: ChatScene, peerID: String) -> Chat? {
        guard let selfID = environment.botUserID else { return nil }
        return Chat(scene: scene, peerID: peerID, selfID: selfID)
    }

    private func displayedID(for chat: Chat) -> String {
        if chat.scene == .group { return chat.peerID }
        return environment.displayedPeerID(for: chat) ?? chat.peerID
    }

    @ViewBuilder
    private func conversationActions(for summary: ConversationSummary) -> some View {
        Button("Open Conversation") {
            environment.selectChat(summary.chat)
        }
        Button(summary.chat.scene == .group ? "Copy Group ID" : "Copy Account ID") {
            copy(displayedID(for: summary.chat))
        }

        Divider()

        Button("Clear Chat History…", systemImage: "trash", role: .destructive) {
            pendingDestructiveAction = .clearMessageHistory(
                chat: summary.chat,
                title: environment.conversationTitle(for: summary.chat)
            )
        }

        if summary.chat.scene == .group {
            if let group = environment.groups.first(where: { $0.id == summary.chat.peerID }) {
                Button("Delete Group Chat…", systemImage: "trash", role: .destructive) {
                    pendingDestructiveAction = .deleteGroup(id: group.id, name: group.name)
                }
            }
        } else if environment.isFriend(summary.chat.peerID) {
            Button("Remove Friend…", systemImage: "person.badge.minus", role: .destructive) {
                pendingDestructiveAction = .removeFriend(
                    id: summary.chat.peerID,
                    name: environment.conversationTitle(for: summary.chat)
                )
            }
        }
    }

    private func perform(_ action: SidebarDestructiveAction) async {
        do {
            switch action {
            case let .clearMessageHistory(chat, _):
                try await environment.clearMessageHistory(in: chat)
            case let .deleteGroup(id, _):
                try await environment.deleteGroup(id)
            case let .removeFriend(id, _):
                try await environment.removeFriend(id)
            }
            deletionError = nil
        } catch {
            deletionError = error.localizedDescription
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private enum SidebarDestructiveAction: Identifiable {
    case clearMessageHistory(chat: Chat, title: String)
    case deleteGroup(id: MatchaCore.Group.ID, name: String)
    case removeFriend(id: User.ID, name: String)

    var id: String {
        switch self {
        case let .clearMessageHistory(chat, _): return "history:\(chat.id)"
        case let .deleteGroup(id, _): return "group:\(id)"
        case let .removeFriend(id, _): return "friend:\(id)"
        }
    }

    var title: String {
        switch self {
        case let .clearMessageHistory(_, title): return "Clear chat history with “\(title)”?"
        case let .deleteGroup(_, name): return "Permanently delete group chat “\(name)”?"
        case let .removeFriend(_, name): return "Remove “\(name)” as a friend?"
        }
    }

    var message: String {
        switch self {
        case .clearMessageHistory:
            return "This permanently deletes the conversation history saved for the current bot account. The friend or group chat will not be deleted."
        case .deleteGroup:
            return "The group, its members, related requests, and all chat history will be permanently deleted. This cannot be undone."
        case .removeFriend:
            return "The accounts will no longer be friends. Chat history will be kept, and the friend can be added again later."
        }
    }

    var buttonTitle: String {
        switch self {
        case .clearMessageHistory: return "Clear Chat History"
        case .deleteGroup: return "Delete Group Chat"
        case .removeFriend: return "Remove Friend"
        }
    }
}

/// One conversation row: avatar, primary title, and a single preview line.
private struct ConversationRow: View {
    let summary: ConversationSummary
    let environment: AppEnvironment

    var body: some View {
        HStack(spacing: 9) {
            AvatarView(
                name: title,
                path: environment.conversationAvatar(for: summary.chat),
                isGroup: summary.chat.scene == .group
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text(environment.conversationPreview(for: summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(summary.lastMessage.time, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        environment.conversationTitle(for: summary.chat)
    }
}

private struct SidebarPrivateChatCandidate: Identifiable {
    let chat: Chat
    let user: User
    let isFriend: Bool

    var id: Chat.ID { chat.id }
}

private struct SidebarPeerRow: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A request stays visually flat; its actions are available from the trailing menu
/// and the row's contextual menu for pointer-first use.
private struct RequestRow: View {
    let request: PendingRequest
    let environment: AppEnvironment

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                if !request.comment.isEmpty {
                    Text(request.comment)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 2)

            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Manage request")
        }
        .padding(.vertical, 2)
        .contextMenu { actions }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Accept", systemImage: "checkmark") {
            Task { await environment.resolveRequest(request, approve: true) }
        }
        Button("Decline", systemImage: "xmark", role: .destructive) {
            Task { await environment.resolveRequest(request, approve: false) }
        }
    }

    private var title: String {
        let who = environment.displayName(for: request.requesterID, in: nil)
        switch request.kind {
        case .friend: return "\(who) sent a friend request"
        case .groupJoin: return "\(who) requested to join the group"
        case .groupInvite: return "\(who) sent a group invitation"
        }
    }
}

/// A compact source-list footer for the current speaking identity.
private struct PersonaBar: View {
    let environment: AppEnvironment
    @Binding var selectedSettingsTab: MatchaSettingsTab
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            selectedSettingsTab = .roles
            openSettings()
        } label: {
            profileLabel
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 64)
        .contentShape(.rect)
        .help("Open persona settings and change the sending identity")
        .accessibilityLabel("Current user: \(activeName). Open sending identity settings")
    }

    private var profileLabel: some View {
        HStack(spacing: 12) {
            AvatarView(name: activeName, path: activeAvatar, size: 38)
                .overlay {
                    Circle()
                        .stroke(.separator.opacity(0.45), lineWidth: 0.5)
                }

            Text(activeName)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 64)
    }

    private var activeUser: User? {
        environment.users.first { $0.id == activeUserID }
    }

    private var activeUserID: User.ID? {
        environment.activeUserID ?? environment.users.first?.id
    }

    private var activeName: String {
        activeUser?.displayName ?? "Select Identity"
    }

    private var activeAvatar: String? {
        activeUser?.avatar
    }
}

/// A circular avatar, falling back to a semantic system glyph.
struct AvatarView: View {
    let name: String
    let path: String?
    var isGroup = false
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let path, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(.quaternary)
                    Image(systemName: isGroup ? "person.3.fill" : "person.fill")
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityLabel(name)
    }
}
