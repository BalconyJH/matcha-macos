import MatchaCore
import SwiftUI
import UniformTypeIdentifiers

struct MentionTarget: Identifiable, Hashable {
    let userID: User.ID?

    var id: String {
        userID.map { "user:\($0)" } ?? "everyone"
    }

    var isEveryone: Bool { userID == nil }
}

struct ComposerDraft: Equatable {
    var text = ""
    var mentions: [MentionTarget] = []
    var attachments: [Asset] = []
    var attachmentImportCount = 0
    var isSending = false

    var isEmpty: Bool {
        text.isEmpty && mentions.isEmpty && attachments.isEmpty
            && attachmentImportCount == 0 && !isSending
    }

    func messageContent(
        allowedMentionUserIDs: Set<User.ID>? = nil
    ) -> [MessageSegment] {
        var content = mentions.compactMap { target -> MessageSegment? in
            if let userID = target.userID,
                allowedMentionUserIDs.map({ !$0.contains(userID) }) == true
            {
                return nil
            }
            return .mention(userID: target.userID)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            content.append(.text(trimmed))
        }
        content.append(contentsOf: attachments.map(Self.segment(for:)))
        return content
    }

    @discardableResult
    mutating func addMention(userID: User.ID?) -> Bool {
        let target = MentionTarget(userID: userID)
        guard !mentions.contains(target) else { return false }
        if target.isEveryone {
            mentions = [target]
        } else {
            mentions.removeAll(where: \.isEveryone)
            mentions.append(target)
        }
        return true
    }

    mutating func removeInvalidMentions(validUserIDs: Set<User.ID>) {
        mentions.removeAll { target in
            target.userID.map({ !validUserIDs.contains($0) }) ?? false
        }
    }

    private static func segment(for asset: Asset) -> MessageSegment {
        guard let mime = asset.mimeType else { return .file(asset) }
        if mime.hasPrefix("image/") { return .image(asset) }
        if mime.hasPrefix("audio/") { return .record(asset, duration: nil) }
        if mime.hasPrefix("video/") { return .video(asset) }
        return .file(asset)
    }
}

/// Floating desktop composer. SwiftUI owns the draft and attachment state; AppKit
/// owns only the text-system edge needed for IME-safe Return handling.
@MainActor
struct Composer: View {
    let environment: AppEnvironment
    let chat: Chat
    let senderID: User.ID?
    @Binding var draft: ComposerDraft

    @State private var isTargetedForDrop = false
    @State private var isPickingFiles = false

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                if !draft.mentions.isEmpty || !draft.attachments.isEmpty {
                    segmentStrip
                }

                HStack(alignment: .bottom, spacing: 8) {
                    editor
                    actionRow
                }
            }
            .padding(10)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(
                        isTargetedForDrop ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                        lineWidth: 2
                    )
            }
        }
        .fileImporter(
            isPresented: $isPickingFiles,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                environment.reportAttachmentSelectionCompleted()
                beginAttaching(urls: urls)
            case .failure(let error):
                environment.reportAttachmentSelectionFailure(error)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, !draft.isSending else { return false }
            beginAttaching(urls: urls)
            return true
        } isTargeted: {
            isTargetedForDrop = $0
        }
        .onChange(of: mentionableUsers.map(\.id), initial: true) { _, userIDs in
            draft.removeInvalidMentions(validUserIDs: Set(userIDs))
        }
        .disabled(draft.isSending)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            AppKitComposerEditor(
                text: $draft.text,
                isEditable: !draft.isSending,
                onSubmit: submit
            )
            .frame(minHeight: 40, idealHeight: 56, maxHeight: 112)

            if draft.text.isEmpty {
                Text("Message…")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, AppKitComposerEditor.horizontalTextInset)
                    .padding(.vertical, 7)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Message")
    }

    /// The editor and the actions stay bottom-anchored as the draft grows, while
    /// controls with different intrinsic heights share one visual center line.
    private var actionRow: some View {
        HStack(spacing: 8) {
            if chat.scene == .group {
                mentionMenu(chat: chat)
            }

            Button {
                isPickingFiles = true
            } label: {
                Label("Attach Files", systemImage: "paperclip")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Attach files")
            .disabled(isIngestingFiles)

            if isIngestingFiles {
                ProgressView()
                    .controlSize(.small)
                    .help("Importing attachments")
            }

            Button("Send", systemImage: "arrow.up", action: submit)
                .buttonStyle(.glassProminent)
                .disabled(!canSend)
                .help("Send with Return; insert a line break with Shift-Return")
        }
        .fixedSize()
    }

    private func mentionMenu(chat: Chat) -> some View {
        Menu {
            ForEach(mentionableUsers) { user in
                Button(
                    "@\(environment.displayName(for: user.id, in: chat)) · \(user.id)"
                ) {
                    draft.addMention(userID: user.id)
                }
                .disabled(draft.mentions.contains(MentionTarget(userID: user.id)))
            }

            if !mentionableUsers.isEmpty {
                Divider()
            }

            Button("@everyone") {
                draft.addMention(userID: nil)
            }
            .disabled(draft.mentions.contains(MentionTarget(userID: nil)))
        } label: {
            Label("Mention Group Member", systemImage: "at")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Mention a group member")
    }

    private var segmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(draft.mentions) { target in
                    HStack(spacing: 5) {
                        Text(mentionLabel(target))
                            .lineLimit(1)
                        Button {
                            draft.mentions.removeAll { $0 == target }
                        } label: {
                            Label("Remove \(mentionLabel(target))", systemImage: "xmark.circle.fill")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove \(mentionLabel(target))")
                    }
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.tint.opacity(0.12), in: .capsule)
                }

                ForEach(draft.attachments) { asset in
                    HStack(spacing: 5) {
                        Image(systemName: icon(for: asset))
                        Text(asset.name)
                            .lineLimit(1)
                        Button {
                            draft.attachments.removeAll { $0.id == asset.id }
                        } label: {
                            Label("Remove \(asset.name)", systemImage: "xmark.circle.fill")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove \(asset.name)")
                    }
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: .capsule)
                }
            }
        }
        .scrollIndicators(.never)
        .frame(height: 26)
    }

    private var canSend: Bool {
        senderID != nil
            && !draft.messageContent(allowedMentionUserIDs: mentionableUserIDs).isEmpty
            && environment.canSubmitMessages
            && !isIngestingFiles
            && !draft.isSending
    }

    private func submit() {
        guard canSend else { return }

        guard let senderID else { return }
        let content = draft.messageContent(
            allowedMentionUserIDs: mentionableUserIDs
        )
        draft.isSending = true

        Task {
            let didSend = await environment.send(content: content, in: chat, as: senderID)
            if didSend {
                draft = ComposerDraft()
            } else {
                draft.isSending = false
            }
        }
    }

    private var mentionableUsers: [User] {
        environment.mentionableUsers(in: chat)
    }

    private var mentionableUserIDs: Set<User.ID> {
        Set(mentionableUsers.map(\.id))
    }

    private var isIngestingFiles: Bool { draft.attachmentImportCount > 0 }

    private func mentionLabel(_ target: MentionTarget) -> String {
        guard let userID = target.userID else { return "@everyone" }
        return "@\(environment.displayName(for: userID, in: chat))"
    }

    private func icon(for asset: Asset) -> String {
        guard let mime = asset.mimeType else { return "doc" }
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime.hasPrefix("video/") { return "film" }
        return "doc"
    }

    private func beginAttaching(urls: [URL]) {
        guard !urls.isEmpty, !draft.isSending else { return }
        draft.attachmentImportCount += 1
        Task {
            await attach(urls: urls)
            draft.attachmentImportCount -= 1
        }
    }

    private func attach(urls: [URL]) async {
        for url in urls {
            let isSecurityScoped = url.startAccessingSecurityScopedResource()
            defer {
                if isSecurityScoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            if let asset = await environment.ingestAttachment(at: url),
                !draft.attachments.contains(where: { $0.id == asset.id })
            {
                draft.attachments.append(asset)
            }
        }
    }
}
