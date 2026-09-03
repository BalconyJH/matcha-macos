import Foundation
import SwiftData

/// The first SwiftData schema used by Matcha.
///
/// Persistence models deliberately remain internal record mirrors. Public domain
/// values cross actor and module boundaries, while these reference types never
/// leave the storage executor that owns their `ModelContext`.
enum MatchaSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            UserRecord.self,
            GroupRecord.self,
            GroupMemberRecord.self,
            FriendshipRecord.self,
            MessageRecord.self,
            PendingRequestRecord.self,
            AssetRecord.self,
        ]
    }

    @Model
    final class UserRecord {
        #Index<UserRecord>([\.createdAt])

        @Attribute(.unique) var id: String
        var name: String
        var nickname: String
        var avatar: String?
        var sex: String
        var age: Int?
        var sign: String
        var createdAt: Date

        init(
            id: String,
            name: String,
            nickname: String,
            avatar: String?,
            sex: String,
            age: Int?,
            sign: String,
            createdAt: Date
        ) {
            self.id = id
            self.name = name
            self.nickname = nickname
            self.avatar = avatar
            self.sex = sex
            self.age = age
            self.sign = sign
            self.createdAt = createdAt
        }
    }

    @Model
    final class GroupRecord {
        #Index<GroupRecord>([\.createdAt])

        @Attribute(.unique) var id: String
        var name: String
        var avatar: String?
        var intro: String
        var level: Int
        var maxMemberCount: Int
        var wholeMuted: Bool
        var createdAt: Date

        init(
            id: String,
            name: String,
            avatar: String?,
            intro: String,
            level: Int,
            maxMemberCount: Int,
            wholeMuted: Bool,
            createdAt: Date
        ) {
            self.id = id
            self.name = name
            self.avatar = avatar
            self.intro = intro
            self.level = level
            self.maxMemberCount = maxMemberCount
            self.wholeMuted = wholeMuted
            self.createdAt = createdAt
        }
    }

    @Model
    final class GroupMemberRecord {
        #Unique<GroupMemberRecord>([\.groupID, \.userID])
        #Index<GroupMemberRecord>([\.groupID, \.joinedAt], [\.userID])

        /// Stable storage identity for the domain's composite key.
        @Attribute(.unique) var id: String
        var groupID: String
        var userID: String
        var card: String
        var role: String
        var title: String
        var joinedAt: Date
        var lastSentAt: Date?
        var mutedUntil: Date?

        init(
            id: String,
            groupID: String,
            userID: String,
            card: String,
            role: String,
            title: String,
            joinedAt: Date,
            lastSentAt: Date?,
            mutedUntil: Date?
        ) {
            self.id = id
            self.groupID = groupID
            self.userID = userID
            self.card = card
            self.role = role
            self.title = title
            self.joinedAt = joinedAt
            self.lastSentAt = lastSentAt
            self.mutedUntil = mutedUntil
        }
    }

    @Model
    final class FriendshipRecord {
        #Unique<FriendshipRecord>([\.userID, \.friendID])
        #Index<FriendshipRecord>([\.userID, \.createdAt], [\.friendID])

        /// Stable storage identity for the directional composite key.
        @Attribute(.unique) var id: String
        var userID: String
        var friendID: String
        var remark: String
        var createdAt: Date

        init(id: String, userID: String, friendID: String, remark: String, createdAt: Date) {
            self.id = id
            self.userID = userID
            self.friendID = friendID
            self.remark = remark
            self.createdAt = createdAt
        }
    }

    @Model
    final class MessageRecord {
        #Index<MessageRecord>(
            [\.scene, \.peerID, \.selfID, \.seq],
            [\.selfID, \.time],
            [\.time]
        )

        @Attribute(.unique) var id: String
        var seq: Int64
        var scene: String
        var peerID: String
        var senderID: String
        var selfID: String
        /// Explicit JSON bytes keep the segment persistence format under our control.
        var content: Data
        var time: Date
        var direction: String
        var recalledAt: Date?
        var recalledBy: String?

        init(
            id: String,
            seq: Int64,
            scene: String,
            peerID: String,
            senderID: String,
            selfID: String,
            content: Data,
            time: Date,
            direction: String,
            recalledAt: Date?,
            recalledBy: String?
        ) {
            self.id = id
            self.seq = seq
            self.scene = scene
            self.peerID = peerID
            self.senderID = senderID
            self.selfID = selfID
            self.content = content
            self.time = time
            self.direction = direction
            self.recalledAt = recalledAt
            self.recalledBy = recalledBy
        }
    }

    @Model
    final class PendingRequestRecord {
        #Index<PendingRequestRecord>([\.flag], [\.selfID, \.time])

        @Attribute(.unique) var id: String
        var flag: String
        var kind: String
        var requesterID: String
        var groupID: String?
        var selfID: String
        var comment: String
        var time: Date
        /// `nil` means unresolved; non-nil JSON records the complete resolution.
        var resolution: Data?

        init(
            id: String,
            flag: String,
            kind: String,
            requesterID: String,
            groupID: String?,
            selfID: String,
            comment: String,
            time: Date,
            resolution: Data?
        ) {
            self.id = id
            self.flag = flag
            self.kind = kind
            self.requesterID = requesterID
            self.groupID = groupID
            self.selfID = selfID
            self.comment = comment
            self.time = time
            self.resolution = resolution
        }
    }

    @Model
    final class AssetRecord {
        @Attribute(.unique) var id: String
        var name: String
        var mimeType: String?
        var byteCount: Int
        /// Explicit JSON bytes avoid relying on SwiftData's transformable inference.
        var source: Data

        init(id: String, name: String, mimeType: String?, byteCount: Int, source: Data) {
            self.id = id
            self.name = name
            self.mimeType = mimeType
            self.byteCount = byteCount
            self.source = source
        }
    }
}

enum MatchaMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [MatchaSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

typealias UserRecord = MatchaSchemaV1.UserRecord
typealias GroupRecord = MatchaSchemaV1.GroupRecord
typealias GroupMemberRecord = MatchaSchemaV1.GroupMemberRecord
typealias FriendshipRecord = MatchaSchemaV1.FriendshipRecord
typealias MessageRecord = MatchaSchemaV1.MessageRecord
typealias PendingRequestRecord = MatchaSchemaV1.PendingRequestRecord
typealias AssetRecord = MatchaSchemaV1.AssetRecord
