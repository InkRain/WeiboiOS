import Foundation

/// 与 Kotlin 版 `WeiboEndpoints` 一一对应的接口路径表。
enum WeiboEndpoints {
    static let config = "/ajax/config"
    static let following = "/ajax/feed/friendstimeline"
    static let groupTimeline = "/ajax/feed/groupstimeline"
    static let hotTimeline = "/ajax/feed/hottimeline"
    static let allGroups = "/ajax/feed/allGroups"
    static let favorites = "/ajax/favorites/all_fav"
    static let likedStatuses = "/ajax/statuses/likelist"

    static let statusComments = "/ajax/statuses/buildComments"
    static let commentCreate = "/ajax/comments/create"
    static let commentReply = "/ajax/comments/reply"
    static let statusLongText = "/ajax/statuses/longtext"
    static let statusDetail = "/ajax/statuses/show"
    static let statusRepostTimeline = "/ajax/statuses/repostTimeline"
    static let statusRepost = "/ajax/statuses/repost"
    static let statusDestroy = "/ajax/statuses/destroy"

    static let profileInfo = "/ajax/profile/info"
    static let profileDetail = "/ajax/profile/detail"
    static let userTimeline = "/ajax/statuses/mymblog"
    static let userSearchBlog = "/ajax/profile/searchblog"
    static let profileImageWall = "/ajax/profile/getImageWall"

    static let followCreate = "/ajax/friendships/create"
    static let followDestroy = "/ajax/friendships/destory"
    static let friends = "/ajax/friendships/friends"
    static let setLike = "/ajax/statuses/setLike"
    static let cancelLike = "/ajax/statuses/cancelLike"

    static let statusFavoriteCreate = "/ajax/statuses/createFavorites"
    static let statusFavoriteDestroy = "/ajax/statuses/destoryFavorites"

    static let searchBand = "/ajax/side/searchBand"
    static let searchSide = "/ajax/side/search"

    static func timelinePath(_ kind: TimelineKind) -> String {
        switch kind {
        case .following: return following
        case .friendsCircle: return groupTimeline
        case .favorites: return favorites
        case .liked: return likedStatuses
        case .hot, .nearby: return hotTimeline
        }
    }
}

enum WeiboConstants {
    static let home = "https://weibo.com/"
    static let passportLogin = "https://passport.weibo.cn/signin/login"
    static let passportOrigin = "https://passport.weibo.cn/"

    /// 好友圈固定分组。
    static let friendsCircleGID = "100097312739005"
    /// 「最新微博」分组固定 fid。
    static let followingFID = "110001768015440"

    static let desktopUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    static let mweiboUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Weibo (iPhone14,2__weibo__14.9.0__iphone__os17.0)"

    static let cookieOrigins = [
        "https://weibo.com/",
        "https://www.weibo.com/",
        "https://s.weibo.com/",
        "https://passport.weibo.cn/",
        "https://m.weibo.cn/",
        "https://card.weibo.com/",
    ]
}
