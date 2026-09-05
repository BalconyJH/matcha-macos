import Foundation
import SwiftData

extension ReiStore {
    // MARK: - Messages

    /// Persists a message, assigning the next sequence number in its chat.
    /// Allocation and insertion run on the same model actor and transaction.
    public func append(_ message: Message) async throws -> Message {
        try await executor.append(message)
    }

    public func save(_ message: Message) async throws {
        try await executor.save(message)
    }

    public func message(id: String) async throws -> Message? {
        try await executor.message(id: id)
    }

    public func message(scene: ChatScene, peerID: String, seq: Int64, selfID: String) async throws -> Message? {
        try await executor.message(scene: scene, peerID: peerID, seq: seq, selfID: selfID)
    }

    public func messages(in chat: Chat, limit: Int = 200) async throws -> [Message] {
        try await executor.messages(in: chat, limit: limit)
    }

    /// Finds the nodes owned by a persisted merged-forward segment.
    ///
    /// Forward bundles are stored inline with message content, so this queries that
    /// source of truth instead of maintaining a second ID-to-nodes cache that could
    /// outlive a deleted message or become stale after an edit.
    public func forwardNodes(id: String, selfID: String) async throws -> [MessageSegment.ForwardNode]? {
        try await executor.forwardNodes(id: id, selfID: selfID)
    }

    public func history(
        scene: ChatScene,
        peerID: String,
        selfID: String,
        startSeq: Int64? = nil,
        limit: Int = 20
    ) async throws -> [Message] {
        try await executor.history(
            scene: scene,
            peerID: peerID,
            selfID: selfID,
            startSeq: startSeq,
            limit: limit
        )
    }

    public func recallMessage(id: String, by operatorID: String) async throws -> Message? {
        try await executor.recallMessage(id: id, by: operatorID)
    }

    public func activeChats(selfID: String) async throws -> [(chat: Chat, lastMessage: Message)] {
        try await executor.activeChats(selfID: selfID)
    }

    public func deleteMessages(in chat: Chat) async throws {
        try await executor.deleteMessages(in: chat)
    }

    // MARK: - Requests

    public func save(_ request: PendingRequest) async throws {
        try await executor.save(request)
    }

    public func request(id: String) async throws -> PendingRequest? {
        try await executor.request(id: id)
    }

    public func request(flag: String) async throws -> PendingRequest? {
        try await executor.request(flag: flag)
    }

    public func pendingRequests(selfID: String, kind: PendingRequest.Kind? = nil) async throws -> [PendingRequest] {
        try await executor.pendingRequests(selfID: selfID, kind: kind)
    }

    public func resolve(
        requestID: String,
        as resolution: PendingRequest.Resolution
    ) async throws -> PendingRequest? {
        try await executor.resolve(requestID: requestID, as: resolution)
    }

    // MARK: - Assets

    public func save(_ asset: Asset) async throws {
        try await executor.save(asset)
    }

    public func asset(id: String) async throws -> Asset? {
        try await executor.asset(id: id)
    }
}

extension StoreExecutor {
    // MARK: Record lookup

    func messageRecord(id: String) throws -> MessageRecord? {
        let requestedID = id
        let descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.id == requestedID }
        )
        return try modelContext.fetch(descriptor).first
    }

    func requestRecord(id: String) throws -> PendingRequestRecord? {
        let requestedID = id
        let descriptor = FetchDescriptor<PendingRequestRecord>(
            predicate: #Predicate { $0.id == requestedID }
        )
        return try modelContext.fetch(descriptor).first
    }

    func assetRecord(id: String) throws -> AssetRecord? {
        let requestedID = id
        let descriptor = FetchDescriptor<AssetRecord>(
            predicate: #Predicate { $0.id == requestedID }
        )
        return try modelContext.fetch(descriptor).first
    }

    // MARK: Messages

    func append(_ message: Message) throws -> Message {
        var stored = message
        try modelContext.transaction {
            if stored.seq == 0 {
                stored.seq = try nextSequence(in: stored.chat)
            }
            try upsert(stored)
            try modelContext.save()
        }
        publish([.messages, .conversations])
        return stored
    }

    func save(_ message: Message) throws {
        try upsert(message)
        try modelContext.save()
        publish([.messages, .conversations])
    }

    func message(id: String) throws -> Message? {
        try messageRecord(id: id)?.domainValue()
    }

    func message(scene: ChatScene, peerID: String, seq: Int64, selfID: String) throws -> Message? {
        let requestedScene = scene.rawValue
        let requestedPeerID = peerID
        let requestedSequence = seq
        let requestedSelfID = selfID
        let descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate {
                $0.scene == requestedScene
                    && $0.peerID == requestedPeerID
                    && $0.seq == requestedSequence
                    && $0.selfID == requestedSelfID
            }
        )
        return try modelContext.fetch(descriptor).first?.domainValue()
    }

    func messages(in chat: Chat, limit: Int = 200) throws -> [Message] {
        guard limit > 0 else { return [] }
        let scene = chat.scene.rawValue
        let peerID = chat.peerID
        let selfID = chat.selfID
        var descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate {
                $0.scene == scene && $0.peerID == peerID && $0.selfID == selfID
            },
            sortBy: [SortDescriptor(\MessageRecord.seq, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let newestFirst = try modelContext.fetch(descriptor).map { try $0.domainValue() }
        return Array(newestFirst.reversed())
    }

    func forwardNodes(id: String, selfID: String) throws -> [MessageSegment.ForwardNode]? {
        let requestedSelfID = selfID
        let descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.selfID == requestedSelfID }
        )
        for record in try modelContext.fetch(descriptor) {
            let message = try record.domainValue()
            if let nodes = Self.forwardNodes(id: id, in: message.content) {
                return nodes
            }
        }
        return nil
    }

    private static func forwardNodes(
        id: String,
        in content: [MessageSegment]
    ) -> [MessageSegment.ForwardNode]? {
        for segment in content {
            guard case .forward(let forwardID, let nodes) = segment else { continue }
            if forwardID == id { return nodes }
            for node in nodes {
                if let nested = forwardNodes(id: id, in: node.content) {
                    return nested
                }
            }
        }
        return nil
    }

    func history(
        scene: ChatScene,
        peerID: String,
        selfID: String,
        startSeq: Int64? = nil,
        limit: Int = 20
    ) throws -> [Message] {
        let bounded = min(max(limit, 1), 100)
        let requestedScene = scene.rawValue
        let requestedPeerID = peerID
        let requestedSelfID = selfID
        let upperBound = startSeq ?? Int64.max
        var descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate {
                $0.scene == requestedScene
                    && $0.peerID == requestedPeerID
                    && $0.selfID == requestedSelfID
                    && $0.seq <= upperBound
            },
            sortBy: [SortDescriptor(\MessageRecord.seq, order: .reverse)]
        )
        descriptor.fetchLimit = bounded
        let newestFirst = try modelContext.fetch(descriptor).map { try $0.domainValue() }
        return Array(newestFirst.reversed())
    }

    func recallMessage(id: String, by operatorID: String) throws -> Message? {
        guard let record = try messageRecord(id: id) else { return nil }
        record.recalledAt = .now
        record.recalledBy = operatorID
        try modelContext.save()
        publish([.messages, .conversations])
        return try record.domainValue()
    }

    func activeChats(selfID: String) throws -> [(chat: Chat, lastMessage: Message)] {
        let requestedSelfID = selfID
        let descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.selfID == requestedSelfID }
        )

        // Sequence, rather than wall-clock time, defines the last message in a chat.
        // Callers can supply historical timestamps, so selecting the newest date can
        // otherwise resurrect an older sequence as the conversation preview.
        var latestByChat: [Chat: Message] = [:]
        for record in try modelContext.fetch(descriptor) {
            let message = try record.domainValue()
            if latestByChat[message.chat].map({ $0.seq < message.seq }) ?? true {
                latestByChat[message.chat] = message
            }
        }
        return
            latestByChat
            .map { (chat: $0.key, lastMessage: $0.value) }
            .sorted {
                if $0.lastMessage.time != $1.lastMessage.time {
                    return $0.lastMessage.time > $1.lastMessage.time
                }
                return $0.chat.id < $1.chat.id
            }
    }

    func deleteMessages(in chat: Chat) throws {
        let scene = chat.scene.rawValue
        let peerID = chat.peerID
        let selfID = chat.selfID
        let descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate {
                $0.scene == scene && $0.peerID == peerID && $0.selfID == selfID
            }
        )
        let records = try modelContext.fetch(descriptor)
        guard !records.isEmpty else { return }
        for record in records { modelContext.delete(record) }
        try modelContext.save()
        publish([.messages, .conversations])
    }

    private func nextSequence(in chat: Chat) throws -> Int64 {
        let scene = chat.scene.rawValue
        let peerID = chat.peerID
        let selfID = chat.selfID
        var descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate {
                $0.scene == scene && $0.peerID == peerID && $0.selfID == selfID
            },
            sortBy: [SortDescriptor(\MessageRecord.seq, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try modelContext.fetch(descriptor).first?.seq ?? 0) + 1
    }

    private func upsert(_ message: Message) throws {
        if let record = try messageRecord(id: message.id) {
            try record.update(from: message)
        } else {
            modelContext.insert(try MessageRecord.make(from: message))
        }
    }

    // MARK: Requests

    func save(_ request: PendingRequest) throws {
        if let record = try requestRecord(id: request.id) {
            try record.update(from: request)
        } else {
            modelContext.insert(try PendingRequestRecord.make(from: request))
        }
        try modelContext.save()
        publish(.requests)
    }

    func request(id: String) throws -> PendingRequest? {
        try requestRecord(id: id)?.domainValue()
    }

    func request(flag: String) throws -> PendingRequest? {
        let requestedFlag = flag
        let descriptor = FetchDescriptor<PendingRequestRecord>(
            predicate: #Predicate { $0.flag == requestedFlag }
        )
        return try modelContext.fetch(descriptor).first?.domainValue()
    }

    func pendingRequests(selfID: String, kind: PendingRequest.Kind? = nil) throws -> [PendingRequest] {
        let requestedSelfID = selfID
        let descriptor: FetchDescriptor<PendingRequestRecord>
        if let kind {
            let requestedKind = kind.rawValue
            descriptor = FetchDescriptor<PendingRequestRecord>(
                predicate: #Predicate {
                    $0.selfID == requestedSelfID
                        && $0.resolution == nil
                        && $0.kind == requestedKind
                },
                sortBy: [SortDescriptor(\PendingRequestRecord.time, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<PendingRequestRecord>(
                predicate: #Predicate {
                    $0.selfID == requestedSelfID && $0.resolution == nil
                },
                sortBy: [SortDescriptor(\PendingRequestRecord.time, order: .reverse)]
            )
        }
        return try modelContext.fetch(descriptor).map { try $0.domainValue() }
    }

    func resolve(
        requestID: String,
        as resolution: PendingRequest.Resolution
    ) throws -> PendingRequest? {
        guard let record = try requestRecord(id: requestID) else { return nil }
        record.resolution = try PersistenceCodec.encode(resolution)
        try modelContext.save()
        publish(.requests)
        return try record.domainValue()
    }

    // MARK: Assets

    func save(_ asset: Asset) throws {
        if let record = try assetRecord(id: asset.id) {
            try record.update(from: asset)
        } else {
            modelContext.insert(try AssetRecord.make(from: asset))
        }
        try modelContext.save()
        publish(.assets)
    }

    func asset(id: String) throws -> Asset? {
        try assetRecord(id: id)?.domainValue()
    }
}
