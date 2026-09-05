import Foundation
import SwiftData

/// Persistent store for the simulated platform.
///
/// `ReiStore` is a Sendable value-facing facade. Its SwiftData container,
/// contexts, and reference-model instances remain confined to `StoreExecutor`.
public final class ReiStore: Sendable {
    let executor: StoreExecutor

    /// Opens a SwiftData store at `path`, creating and migrating it as needed.
    public init(path: String) throws {
        executor = StoreExecutor(modelContainer: try ReiContainerFactory.persistent(path: path))
    }

    /// An isolated in-memory store, for tests and previews.
    public init() throws {
        executor = StoreExecutor(modelContainer: try ReiContainerFactory.inMemory())
    }

    /// The store in the user's Application Support directory.
    ///
    /// The name intentionally differs from the former GRDB `rei.sqlite`: a raw
    /// SQLite schema is not a SwiftData/Core Data store, so the legacy file remains
    /// untouched instead of being opened or overwritten accidentally.
    public static func defaultLocation() throws -> ReiStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Rei", isDirectory: true)

        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return try ReiStore(path: base.appendingPathComponent("rei.store").path)
    }

    // MARK: - Users

    public func save(_ user: User) async throws {
        try await executor.save(user)
    }

    public func user(id: String) async throws -> User? {
        try await executor.user(id: id)
    }

    public func allUsers() async throws -> [User] {
        try await executor.allUsers()
    }

    public func deleteUser(id: String) async throws {
        try await executor.deleteUser(id: id)
    }

    // MARK: - Groups

    public func save(_ group: Group) async throws {
        try await executor.save(group)
    }

    public func group(id: String) async throws -> Group? {
        try await executor.group(id: id)
    }

    public func allGroups() async throws -> [Group] {
        try await executor.allGroups()
    }

    public func deleteGroup(id: String) async throws {
        try await executor.deleteGroup(id: id)
    }

    // MARK: - Members

    public func save(_ member: GroupMember) async throws {
        try await executor.save(member)
    }

    public func member(groupID: String, userID: String) async throws -> GroupMember? {
        try await executor.member(groupID: groupID, userID: userID)
    }

    public func members(groupID: String) async throws -> [GroupMember] {
        try await executor.members(groupID: groupID)
    }

    public func groups(containing userID: String) async throws -> [Group] {
        try await executor.groups(containing: userID)
    }

    public func removeMember(groupID: String, userID: String) async throws {
        try await executor.removeMember(groupID: groupID, userID: userID)
    }

    public func memberCount(groupID: String) async throws -> Int {
        try await executor.memberCount(groupID: groupID)
    }

    // MARK: - Friendships

    public func save(_ friendship: Friendship) async throws {
        try await executor.save(friendship)
    }

    public func friendship(userID: String, friendID: String) async throws -> Friendship? {
        try await executor.friendship(userID: userID, friendID: friendID)
    }

    public func friendships(userID: String) async throws -> [Friendship] {
        try await executor.friendships(userID: userID)
    }

    public func friends(of userID: String) async throws -> [(friendship: Friendship, user: User)] {
        try await executor.friends(of: userID)
    }

    public func removeFriendship(userID: String, friendID: String) async throws {
        try await executor.removeFriendship(userID: userID, friendID: friendID)
    }
}

enum ReiContainerFactory {
    private static var schema: Schema { Schema(versionedSchema: ReiSchemaV1.self) }

    static func persistent(path: String) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "Rei",
            schema: schema,
            url: URL(fileURLWithPath: path),
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: ReiMigrationPlan.self,
            configurations: [configuration]
        )
    }

    static func inMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "ReiInMemory",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: ReiMigrationPlan.self,
            configurations: [configuration]
        )
    }
}

struct StoreChange: OptionSet, Sendable {
    let rawValue: UInt16

    static let users = StoreChange(rawValue: 1 << 0)
    static let groups = StoreChange(rawValue: 1 << 1)
    static let members = StoreChange(rawValue: 1 << 2)
    static let messages = StoreChange(rawValue: 1 << 3)
    static let requests = StoreChange(rawValue: 1 << 4)
    static let conversations = StoreChange(rawValue: 1 << 5)
    static let assets = StoreChange(rawValue: 1 << 6)
    static let friendships = StoreChange(rawValue: 1 << 7)
    static let all: StoreChange = [
        .users, .groups, .members, .messages, .requests, .conversations, .assets, .friendships,
    ]
}

@ModelActor
actor StoreExecutor {
    private struct Observer {
        var interests: StoreChange
        var continuation: AsyncStream<Void>.Continuation
    }

    private var observers: [UUID: Observer] = [:]

    /// Emits only when a requested category changes. Filtering happens before the
    /// newest-one buffer, so an unrelated write can never overwrite a pending refresh.
    func changes(matching interests: StoreChange) -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = Observer(interests: interests, continuation: continuation)
            continuation.yield(())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    func publish(_ change: StoreChange) {
        for observer in observers.values where !observer.interests.intersection(change).isEmpty {
            observer.continuation.yield(())
        }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    // MARK: Record lookup

    func userRecord(id: String) throws -> UserRecord? {
        let requestedID = id
        let descriptor = FetchDescriptor<UserRecord>(
            predicate: #Predicate { $0.id == requestedID }
        )
        return try modelContext.fetch(descriptor).first
    }

    func groupRecord(id: String) throws -> GroupRecord? {
        let requestedID = id
        let descriptor = FetchDescriptor<GroupRecord>(
            predicate: #Predicate { $0.id == requestedID }
        )
        return try modelContext.fetch(descriptor).first
    }

    func memberRecord(groupID: String, userID: String) throws -> GroupMemberRecord? {
        let id = StorageIdentity.groupMember(groupID: groupID, userID: userID)
        let descriptor = FetchDescriptor<GroupMemberRecord>(
            predicate: #Predicate { $0.id == id }
        )
        return try modelContext.fetch(descriptor).first
    }

    func friendshipRecord(userID: String, friendID: String) throws -> FriendshipRecord? {
        let id = StorageIdentity.friendship(userID: userID, friendID: friendID)
        let descriptor = FetchDescriptor<FriendshipRecord>(
            predicate: #Predicate { $0.id == id }
        )
        return try modelContext.fetch(descriptor).first
    }

    // MARK: Users

    func save(_ user: User) throws {
        if let record = try userRecord(id: user.id) {
            record.update(from: user)
        } else {
            modelContext.insert(UserRecord.make(from: user))
        }
        try modelContext.save()
        publish([.users, .members, .conversations])
    }

    func user(id: String) throws -> User? {
        try userRecord(id: id)?.domainValue()
    }

    func allUsers() throws -> [User] {
        let descriptor = FetchDescriptor<UserRecord>(
            sortBy: [SortDescriptor(\UserRecord.createdAt)]
        )
        return try modelContext.fetch(descriptor).map { try $0.domainValue() }
    }

    func deleteUser(id: String) throws {
        let userID = id
        try modelContext.transaction {
            if let record = try userRecord(id: userID) {
                modelContext.delete(record)
            }

            let memberships = try modelContext.fetch(
                FetchDescriptor<GroupMemberRecord>(predicate: #Predicate { $0.userID == userID })
            )
            for membership in memberships { modelContext.delete(membership) }

            let friendships = try modelContext.fetch(
                FetchDescriptor<FriendshipRecord>(
                    predicate: #Predicate { $0.userID == userID || $0.friendID == userID }
                )
            )
            for friendship in friendships { modelContext.delete(friendship) }
            try modelContext.save()
        }
        publish([.users, .members, .friendships, .conversations])
    }

    // MARK: Groups

    func save(_ group: Group) throws {
        if let record = try groupRecord(id: group.id) {
            record.update(from: group)
        } else {
            modelContext.insert(GroupRecord.make(from: group))
        }
        try modelContext.save()
        publish(.friendships)
        publish([.groups, .conversations])
    }

    func group(id: String) throws -> Group? {
        try groupRecord(id: id)?.domainValue()
    }

    func allGroups() throws -> [Group] {
        let descriptor = FetchDescriptor<GroupRecord>(
            sortBy: [SortDescriptor(\GroupRecord.createdAt)]
        )
        return try modelContext.fetch(descriptor).map { $0.domainValue() }
    }

    func deleteGroup(id: String) throws {
        let groupID = id
        let groupScene = ChatScene.group.rawValue
        try modelContext.transaction {
            if let record = try groupRecord(id: groupID) {
                modelContext.delete(record)
            }
            let memberships = try modelContext.fetch(
                FetchDescriptor<GroupMemberRecord>(predicate: #Predicate { $0.groupID == groupID })
            )
            for membership in memberships { modelContext.delete(membership) }

            let messages = try modelContext.fetch(
                FetchDescriptor<MessageRecord>(
                    predicate: #Predicate {
                        $0.scene == groupScene && $0.peerID == groupID
                    }
                )
            )
            for message in messages { modelContext.delete(message) }

            let requests = try modelContext.fetch(
                FetchDescriptor<PendingRequestRecord>(
                    predicate: #Predicate { $0.groupID == groupID }
                )
            )
            for request in requests { modelContext.delete(request) }
            try modelContext.save()
        }
        publish([.groups, .members, .messages, .requests, .conversations])
    }

    // MARK: Members

    func save(_ member: GroupMember) throws {
        guard try groupRecord(id: member.groupID) != nil else {
            throw StorePersistenceError.missingGroup(member.groupID)
        }
        guard try userRecord(id: member.userID) != nil else {
            throw StorePersistenceError.missingUser(member.userID)
        }
        if let record = try memberRecord(groupID: member.groupID, userID: member.userID) {
            record.update(from: member)
        } else {
            modelContext.insert(GroupMemberRecord.make(from: member))
        }
        try modelContext.save()
        publish(.members)
    }

    func member(groupID: String, userID: String) throws -> GroupMember? {
        try memberRecord(groupID: groupID, userID: userID)?.domainValue()
    }

    func members(groupID: String) throws -> [GroupMember] {
        let requestedGroupID = groupID
        let descriptor = FetchDescriptor<GroupMemberRecord>(
            predicate: #Predicate { $0.groupID == requestedGroupID },
            sortBy: [SortDescriptor(\GroupMemberRecord.joinedAt)]
        )
        return try modelContext.fetch(descriptor).map { try $0.domainValue() }
    }

    func groups(containing userID: String) throws -> [Group] {
        let requestedUserID = userID
        let memberships = try modelContext.fetch(
            FetchDescriptor<GroupMemberRecord>(predicate: #Predicate { $0.userID == requestedUserID })
        )
        let groupIDs = Set(memberships.map(\.groupID))
        let descriptor = FetchDescriptor<GroupRecord>(
            sortBy: [SortDescriptor(\GroupRecord.createdAt)]
        )
        return try modelContext.fetch(descriptor)
            .filter { groupIDs.contains($0.id) }
            .map { $0.domainValue() }
    }

    func removeMember(groupID: String, userID: String) throws {
        if let record = try memberRecord(groupID: groupID, userID: userID) {
            modelContext.delete(record)
            try modelContext.save()
            publish(.members)
        }
    }

    func memberCount(groupID: String) throws -> Int {
        let requestedGroupID = groupID
        let descriptor = FetchDescriptor<GroupMemberRecord>(
            predicate: #Predicate { $0.groupID == requestedGroupID }
        )
        return try modelContext.fetchCount(descriptor)
    }

    // MARK: Friendships

    func save(_ friendship: Friendship) throws {
        guard try userRecord(id: friendship.userID) != nil else {
            throw StorePersistenceError.missingUser(friendship.userID)
        }
        guard try userRecord(id: friendship.friendID) != nil else {
            throw StorePersistenceError.missingUser(friendship.friendID)
        }
        if let record = try friendshipRecord(userID: friendship.userID, friendID: friendship.friendID) {
            record.update(from: friendship)
        } else {
            modelContext.insert(FriendshipRecord.make(from: friendship))
        }
        try modelContext.save()
        publish(.friendships)
    }

    func friendship(userID: String, friendID: String) throws -> Friendship? {
        try friendshipRecord(userID: userID, friendID: friendID)?.domainValue()
    }

    func friendships(userID: String) throws -> [Friendship] {
        let requestedUserID = userID
        let descriptor = FetchDescriptor<FriendshipRecord>(
            predicate: #Predicate { $0.userID == requestedUserID },
            sortBy: [SortDescriptor(\FriendshipRecord.createdAt)]
        )
        return try modelContext.fetch(descriptor).map { $0.domainValue() }
    }

    func friends(of userID: String) throws -> [(friendship: Friendship, user: User)] {
        let records = try friendships(userID: userID)
        return try records.compactMap { friendship in
            guard let record = try userRecord(id: friendship.friendID) else { return nil }
            return (friendship, try record.domainValue())
        }
    }

    func removeFriendship(userID: String, friendID: String) throws {
        let firstUserID = userID
        let secondUserID = friendID
        let descriptor = FetchDescriptor<FriendshipRecord>(
            predicate: #Predicate {
                ($0.userID == firstUserID && $0.friendID == secondUserID)
                    || ($0.userID == secondUserID && $0.friendID == firstUserID)
            }
        )
        let records = try modelContext.fetch(descriptor)
        guard !records.isEmpty else { return }
        for record in records { modelContext.delete(record) }
        try modelContext.save()
        publish(.friendships)
    }
}
