import Foundation

/// 启动参数带 `-demo` 时使用本地示例数据。
/// 用途是在未登录 / 无网络的环境下预览信息流、卡片、图片与评论的排版。
enum DemoMode {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-demo")
}

enum DemoData {

    /// 默认返回「最新微博」示例；传入其他 kind 时做轻量区分，便于在 -demo 模式下验证频道切换生效。
    static func timeline(kind: TimelineKind = .following) -> [FeedItem] {
        var items: [FeedItem] = [
            item(
                id: "demo-1",
                name: "微博科技",
                avatar: "https://picsum.photos/seed/avatar1/120",
                text: "全新一代折叠屏上手：展开厚度只有 4.9mm，折痕几乎不可见。#数码评测# 长文里还聊了续航和影像的实际表现，欢迎在评论区告诉我你最关心的点。 https://t.cn/A6demo1",
                images: images(seed: "fold", count: 3),
                reposts: "1.2万", comments: "3421", likes: "5.6万",
                verified: .blue,
                source: "来自 iPhone 18 Pro",
                ip: "北京",
                hoursAgo: 0.2
            ),
            item(
                id: "demo-2",
                name: "山野与海",
                avatar: "https://picsum.photos/seed/avatar2/120",
                text: "清晨五点半的海边，风很大，但值得。@旅行的阿树 下次一起来。",
                images: images(seed: "sea", count: 1),
                reposts: "238", comments: "96", likes: "1.8万",
                verified: nil,
                source: "来自 iPhone",
                ip: "山东",
                hoursAgo: 3,
                retweet: FeedItem.demoQuote
            ),
            item(
                id: "demo-3",
                name: "城市观察局",
                avatar: "https://picsum.photos/seed/avatar3/120",
                text: "关于地铁末班车时间调整的通知：自下月起，1 号线末班车延后至 23:40 发车，其他线路保持原时刻不变。转发周知。#北京生活#",
                images: [],
                reposts: "8742", comments: "1203", likes: "2.1万",
                verified: .yellow,
                source: "来自 微博网页版",
                ip: "北京",
                hoursAgo: 6,
                poll: FeedPoll(
                    id: "poll-1",
                    title: "你平时会赶末班车吗？",
                    options: [
                        FeedPollOption(id: "a", text: "经常，加班到很晚", count: 12480, countText: "1.2万", selected: true),
                        FeedPollOption(id: "b", text: "偶尔，看情况", count: 8600, countText: "8600", selected: false),
                        FeedPollOption(id: "c", text: "基本不坐地铁", count: 3120, countText: "3120", selected: false),
                    ],
                    participantCount: 24200,
                    endTime: "11-08 23:59",
                    isEnded: false,
                    hasVoted: true
                )
            ),
            item(
                id: "demo-4",
                name: "一日一画",
                avatar: "https://picsum.photos/seed/avatar4/120",
                text: "今天的速写练习，九宫格凑齐了。#每日一画#",
                images: images(seed: "sketch", count: 9),
                reposts: "56", comments: "18", likes: "742",
                verified: nil,
                source: "来自 iPad",
                ip: "上海",
                hoursAgo: 9
            ),
            item(
                id: "demo-5",
                name: "光影记录",
                avatar: "https://picsum.photos/seed/avatar6/120",
                text: "一段城市夜景延时，时长 43 秒。#城市夜景#",
                images: [],
                reposts: "412", comments: "67", likes: "3921",
                verified: .blue,
                source: "来自 iPhone 18 Pro",
                ip: "广东",
                hoursAgo: 12,
                media: FeedMedia(
                    kind: .video,
                    title: "城市夜景延时",
                    coverURL: "https://picsum.photos/seed/nightvideo/1200/675",
                    streamURL: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4",
                    downloadURL: nil,
                    durationSeconds: 43,
                    liveStatus: nil,
                    replayURL: nil,
                    videoOrientation: nil,
                    coverWidth: 1200,
                    coverHeight: 675
                )
            ),
        ]
        // 个人频道在 demo 下返回较少条目，便于区分。
        switch kind {
        case .favorites: items = Array(items.prefix(2))
        case .liked: items = Array(items.prefix(3))
        default: break
        }
        // 给首条加上频道标签，确认切换已生效。
        if kind != .following, let first = items.first {
            var head = first
            head.text = "【\(kind.label)】" + head.text
            items[0] = head
        }
        // 启动参数 `-demoReverse` 让卡片类型靠后的内容（投票 / 九宫格 / 视频）出现在首屏，方便核对排版。
        return ProcessInfo.processInfo.arguments.contains("-demoReverse") ? items.reversed() : items
    }

    static func comments() -> [CommentItem] {
        [
            CommentItem(
                id: "c1",
                authorID: "u1",
                authorName: "折叠屏爱好者",
                authorAvatarURL: "https://picsum.photos/seed/c1/80",
                text: "折痕控制确实进步很大，就是重量还是有点压手。",
                createdAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3200)),
                likesCount: "326",
                ipLocation: "广东",
                comments: [
                    CommentItem(
                        id: "c1-1",
                        authorID: "u2",
                        authorName: "微博科技",
                        authorAvatarURL: "https://picsum.photos/seed/avatar1/80",
                        text: "205g，比上代轻了 12g，握持感好不少。",
                        createdAt: nil,
                        likesCount: "",
                        verification: .blue
                    )
                ],
                replyToAuthor: nil,
                verification: nil
            ),
            CommentItem(
                id: "c2",
                authorID: "u3",
                authorName: "摄影笔记",
                authorAvatarURL: "https://picsum.photos/seed/c2/80",
                text: "影像部分希望多讲讲夜景，尤其是长焦的可用度。",
                createdAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7200)),
                likesCount: "128",
                ipLocation: "浙江",
                comments: [],
                verification: .yellow
            ),
        ]
    }

    static func profile() -> UserProfile {
        UserProfile(
            id: "demo-uid",
            screenName: "微博科技",
            avatarURL: "https://picsum.photos/seed/avatar1/200",
            description: "关注科技与生活方式的交叉点｜投稿请私信",
            location: "北京 朝阳区",
            ipLocation: "北京",
            verifiedReason: "科技数码博主",
            followingCount: "286",
            followersCount: "128.4万",
            statusesCount: "1.2万",
            photosCount: "860",
            coverURLs: ["https://picsum.photos/seed/cover/1200/400"],
            following: false,
            followMe: true,
            gender: "m",
            verification: .blue
        )
    }

    static func hotSearch() -> [HotSearchItem] {
        [
            HotSearchItem(word: "折叠屏厚度新纪录", label: "爆", heat: 3_240_000),
            HotSearchItem(word: "地铁末班车延后", label: "热", heat: 1_820_000),
            HotSearchItem(word: "秋天的第一杯奶茶", label: "新", heat: 1_120_000),
            HotSearchItem(word: "国产大模型开源", label: "", heat: 986_000),
            HotSearchItem(word: "立冬吃什么", label: "", heat: 745_000),
            HotSearchItem(word: "马拉松完赛奖牌", label: "", heat: 512_000),
        ]
    }

    // MARK: - 构造辅助

    private static func images(seed: String, count: Int) -> [FeedImage] {
        (0..<count).map { index in
            let url = "https://picsum.photos/seed/\(seed)\(index)/900/900"
            return FeedImage(
                id: "\(seed)-\(index)",
                thumbnailURL: "https://picsum.photos/seed/\(seed)\(index)/400/400",
                largeURL: url,
                downloadURLs: [url],
                width: 900,
                height: 900,
                type: "jpg"
            )
        }
    }

    private static func item(
        id: String,
        name: String,
        avatar: String,
        text: String,
        images: [FeedImage],
        reposts: String,
        comments: String,
        likes: String,
        verified: UserVerification?,
        source: String,
        ip: String,
        hoursAgo: Double,
        retweet: FeedItem? = nil,
        poll: FeedPoll? = nil,
        media: FeedMedia? = nil
    ) -> FeedItem {
        var item = FeedItem(
            id: id,
            statusID: id,
            authorID: "uid-\(id)",
            authorName: name,
            authorAvatarURL: avatar,
            createdAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-hoursAgo * 3600)),
            source: source,
            ipLocation: ip,
            text: text,
            repostsCount: reposts,
            commentsCount: comments,
            likesCount: likes,
            images: images,
            urlEntities: [],
            verification: verified
        )
        item.poll = poll
        item.retweetedStatus = retweet
        if let media { item.medias = [media] }
        return item
    }
}

extension FeedItem {
    static var demoQuote: FeedItem {
        FeedItem(
            id: "demo-original",
            statusID: "demo-original",
            authorID: "uid-阿树",
            authorName: "旅行的阿树",
            authorAvatarURL: "https://picsum.photos/seed/avatar5/120",
            createdAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-46_800)),
            source: "来自 iPhone",
            ipLocation: "福建",
            text: "把上周在海边拍的延时整理了一下，日落那一段最喜欢。",
            repostsCount: "128",
            commentsCount: "42",
            likesCount: "3120",
            images: DemoData.demoSunsetImages,
            verification: .yellow
        )
    }
}

extension DemoData {
    static var demoSunsetImages: [FeedImage] {
        (0..<2).map { index in
            let url = "https://picsum.photos/seed/sunset\(index)/900/900"
            return FeedImage(
                id: "sunset-\(index)",
                thumbnailURL: "https://picsum.photos/seed/sunset\(index)/400/400",
                largeURL: url,
                downloadURLs: [url],
                width: 900,
                height: 900,
                type: "jpg"
            )
        }
    }
}
