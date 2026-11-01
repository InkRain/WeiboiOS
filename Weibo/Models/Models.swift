import Foundation

// MARK: - 认证图标

/// 对应微博网页当前使用的六类认证图标。
enum UserVerification: String, Codable {
    case red, orange, blue, yellow, gold, grey

    var label: String {
        switch self {
        case .red: return "红 V"
        case .orange: return "橙 V"
        case .blue: return "蓝 V"
        case .yellow: return "黄 V"
        case .gold: return "金 V"
        case .grey: return "灰色认证"
        }
    }

    var symbols: String {
        switch self {
        case .red, .orange, .blue, .grey: return "checkmark.seal.fill"
        case .yellow, .gold: return "star.circle.fill"
        }
    }
}

// MARK: - 可见范围

enum WeiboPostVisibility: Int, CaseIterable, Identifiable {
    case `public` = 0
    case friends = 1
    case privateOnly = 3
    case followers = 10

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .public: return "公开可见"
        case .friends: return "好友圈"
        case .privateOnly: return "仅自己可见"
        case .followers: return "仅粉丝可见"
        }
    }

    /// 卡片上的短提示，对应原版「受限可见」圆角提示框。
    var shortBadge: String? {
        switch self {
        case .public: return nil
        case .friends: return "好友圈"
        case .privateOnly: return "仅自己可见"
        case .followers: return "仅粉丝可见"
        }
    }

    var apiValue: Int { rawValue }

    static func from(apiValue: Int?) -> WeiboPostVisibility? {
        guard let apiValue else { return nil }
        return WeiboPostVisibility(rawValue: apiValue)
    }
}

// MARK: - 图片

struct FeedImage: Identifiable, Hashable {
    let id: String
    let thumbnailURL: String
    let largeURL: String
    var downloadURLs: [String] = []
    var livePhotoVideoURL: String?
    var videoStreamURL: String?
    var createdAt: String?
    var statusID: String?
    var width: Int?
    var height: Int?
    var type: String?

    var isGIF: Bool { type?.lowercased() == "gif" }
    var isLivePhoto: Bool { livePhotoVideoURL?.isEmpty == false && !isGIF }
    var isAlbumVideo: Bool { type?.lowercased() == "video" && videoStreamURL?.isEmpty == false }

    /// 按屏幕需求取合适尺寸：九宫格用小图，大图用 large。
    func displayURL(preferLarge: Bool) -> URL? {
        let candidate = preferLarge ? largeURL : (thumbnailURL.isEmpty ? largeURL : thumbnailURL)
        return URL(string: candidate)
    }
}

// MARK: - 视频 / 媒体

enum MediaKind: String {
    case video, live, audio
}

struct FeedMedia: Hashable, Identifiable {
    var kind: MediaKind
    var title: String
    var coverURL: String?
    var streamURL: String
    var downloadURL: String?
    var durationSeconds: Int?
    var liveStatus: Int?
    var replayURL: String?
    var videoOrientation: String?
    var coverWidth: Int?
    var coverHeight: Int?

    var id: String { streamURL + "|" + title }

    var isPortrait: Bool { videoOrientation?.lowercased() == "vertical" }

    var aspectRatio: CGFloat {
        guard let w = coverWidth, let h = coverHeight, w > 0, h > 0 else {
            return isPortrait ? 3.0 / 4.0 : 16.0 / 9.0
        }
        return CGFloat(w) / CGFloat(h)
    }

    func resolvedPlaybackURL() -> String? {
        switch kind {
        case .video:
            return streamURL.isEmpty ? nil : streamURL
        case .live:
            if liveStatus == 3 { return replayURL?.isEmpty == false ? replayURL : (streamURL.isEmpty ? nil : streamURL) }
            if liveStatus == 1 { return streamURL.isEmpty ? nil : streamURL }
            if liveStatus == nil { return replayURL?.isEmpty == false ? replayURL : (streamURL.isEmpty ? nil : streamURL) }
            return nil
        case .audio:
            return streamURL.isEmpty ? nil : streamURL
        }
    }

    var liveBadge: String? {
        guard kind == .live else { return nil }
        if liveStatus == 1 { return "直播" }
        if liveStatus == 3 { return "回放" }
        return "未开播"
    }
}

// MARK: - 投票

struct FeedPollOption: Identifiable, Hashable {
    var id: String
    var text: String
    var count: Int64?
    var countText: String?
    var selected: Bool = false
}

struct FeedPoll: Hashable {
    var id: String?
    var title: String
    var options: [FeedPollOption] = []
    var participantCount: Int64?
    var endTime: String?
    var isEnded: Bool = false
    var hasVoted: Bool = false
    var maximum: Int = 1
    var minimum: Int = 1
}

// MARK: - 正文链接实体

struct FeedUrlEntity: Identifiable, Hashable {
    var id: String { shortURL }
    var shortURL: String
    var title: String
    var url: String
    var isMediaLink: Bool = false
}

/// 转发关系会让 `FeedItem` 递归包含自身，值类型不能直接持有自己，
/// 这里用一个盒子做间接层，对外仍暴露 `retweetedStatus: FeedItem?`。
final class FeedItemRef {
    let value: FeedItem
    init(_ value: FeedItem) { self.value = value }
}

// MARK: - 微博条目

struct FeedItem: Identifiable, Equatable {
    var id: String
    var statusID: String
    var authorID: String
    var authorName: String
    var authorAvatarURL: String?
    var createdAt: String?
    var source: String?
    var ipLocation: String?
    var locationName: String?
    var locationURL: String?
    var text: String
    var requiresLongTextFetch: Bool = false
    var repostsCount: String
    var commentsCount: String
    var likesCount: String
    var liked: Bool = false
    var favorited: Bool = false
    var images: [FeedImage] = []
    var medias: [FeedMedia] = []
    var urlEntities: [FeedUrlEntity] = []
    var retweetedRef: FeedItemRef?
    var isEdited: Bool = false
    var editCount: Int = 0
    var isPinned: Bool = false
    var visibility: WeiboPostVisibility?
    var poll: FeedPoll?
    var verification: UserVerification?

    var retweetedStatus: FeedItem? {
        get { retweetedRef?.value }
        set { retweetedRef = newValue.map(FeedItemRef.init) }
    }

    static func == (lhs: FeedItem, rhs: FeedItem) -> Bool {
        lhs.id == rhs.id
            && lhs.liked == rhs.liked
            && lhs.favorited == rhs.favorited
            && lhs.text == rhs.text
            && lhs.likesCount == rhs.likesCount
            && lhs.commentsCount == rhs.commentsCount
            && lhs.repostsCount == rhs.repostsCount
            && lhs.images.count == rhs.images.count
            && lhs.medias.count == rhs.medias.count
    }

    var media: FeedMedia? { medias.first }

    /// 详情与列表页的统一跳转标识：优先用 mblogid（短链里的 id）。
    var detailKey: String { statusID.isEmpty ? id : statusID }

    var hasReposts: Bool {
        let value = repostsCount.trimmingCharacters(in: .whitespaces)
        return !(value == "0" || value == "--" || value.isEmpty || value.lowercased() == "null")
    }
}

// MARK: - 评论

struct CommentItem: Identifiable, Hashable {
    var id: String
    var authorID: String = ""
    var authorName: String
    var authorAvatarURL: String?
    var text: String
    var createdAt: String?
    var likesCount: String
    var ipLocation: String?
    var images: [FeedImage] = []
    var comments: [CommentItem] = []
    var replyToAuthor: String?
    var replyToAuthorID: String?
    var urlEntities: [FeedUrlEntity] = []
    var verification: UserVerification?

    var hasLikes: Bool {
        let v = likesCount.trimmingCharacters(in: .whitespaces)
        return !(v.isEmpty || v == "0" || v == "赞")
    }
}

// MARK: - 用户

struct UserProfile: Identifiable, Hashable {
    var id: String
    var screenName: String
    var avatarURL: String?
    var description: String?
    var location: String?
    var ipLocation: String?
    var verifiedReason: String?
    var followingCount: String
    var followersCount: String
    var statusesCount: String
    var photosCount: String?
    var coverURLs: [String] = []
    var following: Bool = false
    var followMe: Bool = false
    var specialFollowing: Bool = false
    var gender: String?
    var verification: UserVerification?

    var coverURL: String? { coverURLs.first }

    var postSearchPlaceholder: String {
        switch gender?.lowercased() {
        case "f": return "搜索她的微博"
        case "m": return "搜索他的微博"
        default: return "搜索TA的微博"
        }
    }
}

// MARK: - 分页

struct TimelinePage {
    var items: [FeedItem]
    var nextCursor: String?
}

struct CommentsPage {
    var items: [CommentItem]
    var nextCursor: String?
    var totalCount: Int?
}

struct RepostsPage {
    var items: [CommentItem]
    var nextPage: Int?
    var totalCount: Int?
}

struct LikeUsersPage {
    var users: [MentionCandidate]
    var nextPage: Int?
    var totalCount: Int?
}

struct AlbumPage {
    var images: [FeedImage]
    var nextCursor: String?
}

struct MentionCandidate: Identifiable, Hashable {
    var id: String
    var name: String
    var avatarURL: String?
    var verification: UserVerification?
}

// MARK: - 搜索

struct HotSearchItem: Identifiable, Hashable {
    var word: String
    var label: String = ""
    var heat: Int64 = 0

    var id: String { word }
}

struct SearchUserItem: Identifiable, Hashable {
    var id: String
    var screenName: String
    var avatarURL: String?
    var description: String
    var followersCount: String
    var verification: UserVerification?
}

struct SearchUserPage {
    var items: [SearchUserItem]
    var nextCursor: String?
}

struct SearchSuggestResult {
    var hotQueries: [String] = []
    var users: [SearchUserItem] = []
}

// MARK: - 首页频道

enum TimelineKind: String, CaseIterable, Identifiable, Codable {
    case following
    case friendsCircle
    case favorites
    case liked
    case hot
    case nearby

    var id: String { rawValue }

    /// 长按小房子切换顺序，与原版一致。
    var label: String {
        switch self {
        case .following: return "最新微博"
        case .friendsCircle: return "好友圈"
        case .favorites: return "我的收藏"
        case .liked: return "我的赞"
        case .hot: return "热门"
        case .nearby: return "同城"
        }
    }

    var symbol: String {
        switch self {
        case .following: return "house.fill"
        case .friendsCircle: return "person.2.fill"
        case .favorites: return "star.fill"
        case .liked: return "hand.thumbsup.fill"
        case .hot: return "flame.fill"
        case .nearby: return "location.fill"
        }
    }

    static func from(storage: String?) -> TimelineKind {
        guard let storage, let kind = TimelineKind(rawValue: storage) else { return .following }
        return kind
    }
}

// MARK: - 评论排序

enum CommentSort: String, CaseIterable, Identifiable {
    case hot, time

    var id: String { rawValue }

    /// 接口 flow 参数：0 表示按热度，1 表示按时间。
    var flow: String {
        switch self {
        case .hot: return "0"
        case .time: return "1"
        }
    }

    var label: String {
        switch self {
        case .hot: return "按热度"
        case .time: return "按时间"
        }
    }

    static func from(flow: String?) -> CommentSort {
        flow == "0" ? .hot : .time
    }
}
