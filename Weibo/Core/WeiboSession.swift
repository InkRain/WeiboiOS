import Foundation

/// 微博接口门面。所有解析都在 Parser 层，这里只负责拼参数、发请求、装配结果。
final class WeiboSession {

    static let shared = WeiboSession()

    private let http = WeiboHTTP.shared
    private let jar = CookieJar.shared

    /// 当前登录用户的 UID 缓存，避免每个请求都去问 /ajax/config。
    private var cachedUID: String?
    private var cachedScreenName: String?
    private var cachedAvatar: String?

    // MARK: - 登录态

    func hasLogin() async -> Bool {
        await jar.hasLogin()
    }

    func currentUserIdentity() async -> (uid: String, name: String, avatar: String?)? {
        if let uid = cachedUID, !uid.isEmpty {
            return (uid, cachedScreenName ?? "", cachedAvatar)
        }
        return await refreshIdentity()
    }

    @discardableResult
    func refreshIdentity() async -> (uid: String, name: String, avatar: String?)? {
        if let identity = try? await fetchIdentityFromConfig() {
            cachedUID = identity.uid
            cachedScreenName = identity.name
            cachedAvatar = identity.avatar
            return identity
        }
        if let identity = try? await fetchIdentityFromMweibo() {
            cachedUID = identity.uid
            cachedScreenName = identity.name
            cachedAvatar = identity.avatar
            return identity
        }
        return nil
    }

    func clearIdentityCache() {
        cachedUID = nil
        cachedScreenName = nil
        cachedAvatar = nil
    }

    private func fetchIdentityFromConfig() async throws -> (uid: String, name: String, avatar: String?) {
        let raw = try await http.get(path: WeiboEndpoints.config)
        let root = try JSONValue.parse(raw)
        let data = root["data"].exists ? root["data"] : root
        let user = data["user"].object ?? data["login_user"].object ?? data["userInfo"].object ?? data
        let uid = data.firstString("uid", "id", "idstr")
            ?? user.firstString("idstr", "id")
            ?? ""
        guard !uid.isEmpty, uid != "0" else { throw WeiboError.api("未读到当前登录用户 UID") }
        let name = data.firstString("screen_name", "nick", "name")
            ?? user.firstString("screen_name", "name")
            ?? ""
        let avatar = data.firstString("avatar", "profile_image_url")
            ?? user.firstString("avatar_hd", "avatar_large", "profile_image_url")
        return (uid, name, avatar)
    }

    private func fetchIdentityFromMweibo() async throws -> (uid: String, name: String, avatar: String?) {
        let raw = try await http.getAbsolute(
            "https://m.weibo.cn/api/config",
            referer: "https://m.weibo.cn/",
            origin: "https://m.weibo.cn",
            userAgent: WeiboConstants.mweiboUserAgent
        )
        let root = try JSONValue.parse(raw)
        let data = root["data"]
        guard let uid = data.firstString("uid", "id", "idstr"), uid != "0" else {
            throw WeiboError.api("未读到当前登录用户 UID")
        }
        return (uid, data.firstString("screen_name", "nick") ?? "", data.nonEmptyString(withKey: "avatar"))
    }

    // MARK: - 首页信息流

    func loadTimeline(kind: TimelineKind, cursor: String?) async throws -> TimelinePage {
        if kind == .favorites || kind == .liked {
            return try await loadPersonalFeed(kind: kind, page: Int(cursor ?? "1") ?? 1)
        }
        let raw = try await loadTimelineRaw(kind: kind, cursor: cursor)
        let page = try FeedParser.parseTimeline(raw)
        // 只缓存首屏（cursor 为空的那次），翻页结果不覆盖首屏缓存。
        if cursor == nil {
            FeedCache.shared.store(kind: kind, raw: raw, items: page.items, cursor: page.nextCursor)
        }
        return page
    }

    private func loadPersonalFeed(kind: TimelineKind, page: Int) async throws -> TimelinePage {
        guard let identity = await currentUserIdentity() else {
            throw WeiboError.api("未读到当前登录用户 UID")
        }
        let path = kind == .favorites ? WeiboEndpoints.favorites : WeiboEndpoints.likedStatuses
        var params = ["uid": identity.uid, "page": String(page)]
        if kind == .liked { params["relate"] = "fans" }
        let referer = kind == .favorites ? "https://weibo.com/fav" : WeiboConstants.home
        let raw = try await http.get(path: path, params: params, referer: referer)
        return try FeedParser.parsePersonalFeed(raw, page: page)
    }

    private func loadTimelineRaw(kind: TimelineKind, cursor: String?) async throws -> String {
        switch kind {
        case .following:
            var params = [
                "list_id": WeiboConstants.followingFID,
                "refresh": "4",
                "count": "20",
                "fid": WeiboConstants.followingFID,
            ]
            params[cursor == nil ? "since_id" : "max_id"] = cursor ?? "0"
            return try await http.get(path: WeiboEndpoints.following, params: params)

        case .friendsCircle:
            var params = [
                "list_id": WeiboConstants.friendsCircleGID,
                "refresh": "4",
                "fast_refresh": "1",
                "count": "25",
            ]
            if let cursor { params["max_id"] = cursor }
            return try await http.get(
                path: WeiboEndpoints.groupTimeline,
                params: params,
                referer: "https://weibo.com/mygroups?gid=\(WeiboConstants.friendsCircleGID)"
            )

        case .hot, .nearby:
            let channel = kind == .hot
                ? (groupId: "102803", containerId: "102803")
                : try await nearbyChannel()
            let params = [
                "group_id": channel.groupId,
                "containerid": channel.containerId,
                "extparam": "discover|new_feed",
                "refresh": "0",
                "count": "20",
                "max_id": cursor ?? "0",
            ]
            return try await http.get(
                path: WeiboEndpoints.hotTimeline,
                params: params,
                referer: "https://weibo.com/hot/weibo/\(channel.groupId)"
            )

        case .favorites, .liked:
            throw WeiboError.api("该频道使用个人流接口")
        }
    }

    /// 同城频道必须用账号自己的频道，不能猜城市。
    private func nearbyChannel() async throws -> (groupId: String, containerId: String) {
        let raw = try await http.get(path: WeiboEndpoints.allGroups)
        if let channel = findChannel(in: try? JSONValue.parse(raw), label: "同城") {
            return channel
        }
        throw WeiboError.api("微博未提供当前账号的同城频道")
    }

    private func findChannel(in value: JSONValue?, label: String) -> (groupId: String, containerId: String)? {
        guard let value else { return nil }
        if let dict = value.value as? [String: Any] {
            let node = JSONValue(dict)
            let titles = [node["title"].string, node["name"].string, node["name_cn"].string]
            if titles.contains(where: { $0?.trimmingCharacters(in: .whitespaces) == label }) {
                let group = [node["gid"].string, node["group_id"].string, node["id"].string]
                    .compactMap { $0 }
                    .first { !$0.isEmpty && $0 != "null" && $0 != "0" }
                if let group {
                    let container = node["containerid"].nonEmptyString ?? group
                    return (group, container)
                }
            }
            for key in dict.keys {
                if let found = findChannel(in: node[key], label: label) { return found }
            }
        }
        if let list = value.value as? [Any] {
            for item in list {
                if let found = findChannel(in: JSONValue(item), label: label) { return found }
            }
        }
        return nil
    }

    // MARK: - 微博详情

    func loadStatusDetail(id: String) async throws -> FeedItem? {
        let key = id.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        let raw = try await http.get(
            path: WeiboEndpoints.statusDetail,
            params: ["id": key, "isGetLongText": "1"]
        )
        return try FeedParser.parseStatusDetail(raw)
    }

    /// 长文展开：先走 longtext，再退回详情接口。返回 nil 表示拿不到更长的正文。
    func expandLongText(_ item: FeedItem) async -> FeedItem? {
        for candidate in [item.statusID, item.id] where !candidate.isEmpty {
            guard let raw = try? await http.get(
                path: WeiboEndpoints.statusLongText,
                params: ["id": candidate]
            ), let root = try? JSONValue.parse(raw),
               let data = root["data"].object,
               FeedParser.hasLongTextPayload(data) else { continue }
            let merged = FeedParser.mergeLongText(into: item, data: data)
            if merged.text.count > item.text.count { return merged }
        }
        if let detail = try? await loadStatusDetail(id: item.detailKey),
           detail.text.count > item.text.count {
            var merged = detail
            merged.id = item.id
            return merged
        }
        return nil
    }

    // MARK: - 评论 / 转发 / 点赞

    private func commentParams(_ item: FeedItem, sort: CommentSort) -> [String: String] {
        [
            "id": item.id,
            "uid": item.authorID,
            "flow": sort.flow,
            "is_reload": "1",
            "is_show_bulletin": "2",
            "is_mix": "0",
            "count": "20",
            "fetch_level": "0",
            "locale": "zh",
        ]
    }

    func loadComments(item: FeedItem, sort: CommentSort, cursor: String? = nil) async throws -> CommentsPage {
        var params = commentParams(item, sort: sort)
        if let cursor { params["max_id"] = cursor }
        let raw = try await http.get(path: WeiboEndpoints.statusComments, params: params)
        return CommentsPage(
            items: try CommentParser.parseComments(raw),
            nextCursor: CommentParser.nextCursor(raw),
            totalCount: CommentParser.parseTotalCount(raw)
        )
    }

    func loadNestedComments(commentID: String, statusAuthorUID: String, cursor: String? = nil) async throws -> CommentsPage {
        let params: [String: String] = [
            "flow": "1",
            "id": commentID,
            "uid": statusAuthorUID,
            "is_reload": cursor == nil ? "1" : "0",
            "is_show_bulletin": "2",
            "is_mix": "1",
            "fetch_level": "1",
            "count": "20",
            "max_id": cursor ?? "0",
            "locale": "zh",
        ]
        let raw = try await http.get(path: WeiboEndpoints.statusComments, params: params)
        return CommentsPage(
            items: try CommentParser.parseComments(raw),
            nextCursor: CommentParser.nextCursor(raw)
        )
    }

    func loadReposts(item: FeedItem, page: Int) async throws -> RepostsPage {
        if page <= 1 && !item.hasReposts {
            return RepostsPage(items: [], nextPage: nil)
        }
        let candidates = [item.statusID, item.id].filter { !$0.isEmpty }
        let parameterSets: [[String: String]] = [
            ["id": item.statusID, "page": String(page), "moduleID": "feed", "count": "20"],
            ["id": item.statusID, "page": String(page), "is_reload": page <= 1 ? "1" : "0", "count": "20"],
            ["id": item.statusID, "page": String(page)],
        ]
        var lastError: Error?
        for statusID in candidates {
            for params in parameterSets {
                var resolved = params
                resolved["id"] = statusID
                do {
                    let raw = try await http.get(
                        path: WeiboEndpoints.statusRepostTimeline,
                        params: resolved,
                        referer: "https://weibo.com/\(item.authorID)/\(item.detailKey)"
                    )
                    return try CommentParser.parseReposts(raw, page: page)
                } catch {
                    lastError = error
                }
            }
        }
        throw lastError ?? WeiboError.api("转发列表加载失败")
    }

    func loadLikeUsers(statusID: String, page: Int) async throws -> LikeUsersPage {
        let raw = try await http.getAbsolute(
            "https://m.weibo.cn/api/attitudes/show",
            params: ["id": statusID, "page": String(page)],
            referer: "https://m.weibo.cn/detail/\(statusID)",
            origin: "https://m.weibo.cn",
            userAgent: WeiboConstants.mweiboUserAgent
        )
        return try CommentParser.parseLikeUsers(raw, page: page)
    }

    // MARK: - 用户

    func loadProfile(uid: String) async throws -> UserProfile {
        let raw = try await http.get(path: WeiboEndpoints.profileInfo, params: ["uid": uid])
        let profile = try ProfileParser.parseProfile(raw, fallbackUID: uid)
        return await enrich(profile)
    }

    func loadCurrentProfile() async throws -> UserProfile {
        guard let identity = await currentUserIdentity() else {
            throw WeiboError.api("未读到当前登录用户 UID，请先完成微博登录")
        }
        do {
            let raw = try await http.get(path: WeiboEndpoints.profileInfo, params: ["uid": identity.uid])
            let profile = try ProfileParser.parseProfile(
                raw,
                fallbackUID: identity.uid,
                fallbackName: identity.name,
                fallbackAvatar: identity.avatar
            )
            return await enrich(profile)
        } catch {
            // 兜底走 m.weibo.cn 的容器接口，桌面接口偶尔对新账号不可用。
            let raw = try await http.getAbsolute(
                "https://m.weibo.cn/api/container/getIndex",
                params: ["type": "uid", "value": identity.uid],
                referer: "https://m.weibo.cn/u/\(identity.uid)",
                origin: "https://m.weibo.cn",
                userAgent: WeiboConstants.mweiboUserAgent
            )
            return try ProfileParser.parseProfile(
                raw,
                fallbackUID: identity.uid,
                fallbackName: identity.name,
                fallbackAvatar: identity.avatar
            )
        }
    }

    private func enrich(_ profile: UserProfile) async -> UserProfile {
        guard !profile.id.isEmpty, profile.ipLocation == nil else { return profile }
        guard let raw = try? await http.get(
            path: WeiboEndpoints.profileDetail,
            params: ["uid": profile.id]
        ) else { return profile }
        return ProfileParser.mergeDetail(profile, raw: raw)
    }

    func loadUserTimeline(uid: String, page: Int) async throws -> TimelinePage {
        let raw = try await http.get(
            path: WeiboEndpoints.userTimeline,
            params: ["uid": uid, "page": String(page), "feature": "0"]
        )
        var parsed = try FeedParser.parseUserTimeline(raw, uid: uid, page: page)
        // 主页长文同样需要展开，否则会看到截断的「...」。
        if parsed.items.contains(where: { $0.requiresLongTextFetch }) {
            var expanded: [FeedItem] = []
            for item in parsed.items {
                if item.requiresLongTextFetch, let merged = await expandLongText(item) {
                    expanded.append(merged)
                } else {
                    expanded.append(item)
                }
            }
            parsed.items = expanded
        }
        return parsed
    }

    func searchUserStatuses(uid: String, query: String, page: Int) async throws -> TimelinePage {        let raw = try await http.get(
            path: WeiboEndpoints.userSearchBlog,
            params: ["uid": uid, "page": String(page), "feature": "0", "q": query],
            referer: "https://weibo.com/u/\(uid)"
        )
        let root = try JSONValue.parse(raw)
        let entries: [JSONValue] = {
            for key in ["list", "statuses"] {
                let arr = root["data"][key].array
                if !arr.isEmpty { return arr }
            }
            return root["data"].array.isEmpty ? root["list"].array : root["data"].array
        }()
        var items: [FeedItem] = []
        for entry in entries {
            var status = entry["mblog"].object ?? entry["status"].object ?? entry
            if status["user"].object == nil, var dict = status.value as? [String: Any] {
                dict["user"] = ["idstr": uid]
                status = JSONValue(dict)
            }
            if let item = FeedParser.parseStatus(status, allowRetweeted: true) { items.append(item) }
        }
        return TimelinePage(
            items: items,
            nextCursor: items.isEmpty ? nil : String(page + 1)
        )
    }

    /// 查看某个用户公开可见的「赞过」。
    func searchUserLiked(uid: String, page: Int) async throws -> TimelinePage {
        let raw = try await http.get(
            path: WeiboEndpoints.likedStatuses,
            params: ["uid": uid, "relate": "fans", "page": String(page)],
            referer: "https://weibo.com/u/\(uid)"
        )
        return try FeedParser.parsePersonalFeed(raw, page: page)
    }

    func loadAlbum(uid: String, cursor: String?) async throws -> AlbumPage {
        var params = ["uid": uid]
        // getImageWall 有两套翻页参数：照片墙用 sinceid，视频墙用 cursor。
        // 解析层用前缀区分，这里按前缀回填到对应的参数名，不能一律当 cursor 发。
        if let cursor, cursor.hasPrefix(Self.albumCursorPrefix) {
            params["cursor"] = String(cursor.dropFirst(Self.albumCursorPrefix.count))
        } else if let cursor {
            params["sinceid"] = cursor
        } else {
            params["sinceid"] = "0"
            params["has_album"] = "true"
        }
        let raw = try await http.get(
            path: WeiboEndpoints.profileImageWall,
            params: params,
            referer: "https://weibo.com/u/\(uid)?tabtype=album"
        )
        return try ProfileParser.parseImageWall(raw, uid: uid)
    }

    /// 相册 cursor 前缀：区分「cursor 翻页」与「sinceid 翻页」。
    static let albumCursorPrefix = "cursor:"

    // MARK: - 搜索

    func loadHotSearch() async throws -> [HotSearchItem] {
        let raw = try await http.get(path: WeiboEndpoints.searchBand, params: ["last_tab": "hot"])
        return try SearchParser.parseHotSearch(raw)
    }

    func loadSearchSuggest(_ query: String) async throws -> SearchSuggestResult {
        let raw = try await http.get(path: WeiboEndpoints.searchSide, params: ["q": query])
        return try SearchParser.parseSuggest(raw)
    }

    /// 微博搜索走 m.weibo.cn 的卡片容器，返回结构和话题搜索一致。
    func searchStatuses(_ query: String, page: Int, realtime: Bool = false) async throws -> TimelinePage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return TimelinePage(items: [], nextCursor: nil) }
        let container = realtime ? "100103type=61&q=\(trimmed)" : "100103type=1&q=\(trimmed)"
        let raw = try await http.getAbsolute(
            "https://m.weibo.cn/api/container/getIndex",
            params: ["containerid": container, "page_type": "searchall", "page": String(page)],
            referer: "https://m.weibo.cn/search?containerid=\(container)",
            origin: "https://m.weibo.cn",
            userAgent: WeiboConstants.mweiboUserAgent
        )
        return try FeedParser.parseMweiboContainer(raw, page: page)
    }

    func searchTopic(_ topic: String, page: Int) async throws -> TimelinePage {
        let normalized = topic
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return TimelinePage(items: [], nextCursor: nil) }
        let container = "231522type=1&q=#\(normalized)#"
        let raw = try await http.getAbsolute(
            "https://m.weibo.cn/api/container/getIndex",
            params: ["containerid": container, "page_type": "searchall", "v_p": "42", "page": String(page)],
            referer: "https://m.weibo.cn/search?containerid=\(container)",
            origin: "https://m.weibo.cn",
            userAgent: WeiboConstants.mweiboUserAgent
        )
        return try FeedParser.parseMweiboContainer(raw, page: page)
    }

    func searchUsers(_ query: String, page: Int) async throws -> SearchUserPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SearchUserPage(items: [], nextCursor: nil) }
        let container = "100103type=3&q=\(trimmed)"
        let raw = try await http.getAbsolute(
            "https://m.weibo.cn/api/container/getIndex",
            params: ["containerid": container, "page_type": "searchall", "page": String(page)],
            referer: "https://m.weibo.cn/search?containerid=\(container)",
            origin: "https://m.weibo.cn",
            userAgent: WeiboConstants.mweiboUserAgent
        )
        return try SearchParser.parseMweiboUsers(raw, page: page)
    }

    // MARK: - 互动操作

    private func assertSuccess(_ raw: String, defaultMessage: String) throws {
        let root = try JSONValue.parse(raw)
        if root["ok"].int == 1 || root["result"].bool { return }
        if root["code"].string == "100000" { return }
        let message = root.firstString("msg", "message", "error_description", "error")
            ?? root["data"].firstString("msg", "message")
            ?? defaultMessage
        throw WeiboError.api(message)
    }

    func setLike(_ item: FeedItem, like: Bool) async throws -> FeedItem {
        let id = item.id
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else {
            throw WeiboError.api("无效的微博 ID，无法点赞")
        }
        let raw = try await http.postForm(
            path: like ? WeiboEndpoints.setLike : WeiboEndpoints.cancelLike,
            params: ["id": id],
            referer: "https://weibo.com/detail/\(item.detailKey)"
        )
        try assertSuccess(raw, defaultMessage: like ? "点赞失败" : "取消点赞失败")
        var updated = item
        updated.liked = like
        updated.likesCount = HTMLText.bumpCount(item.likesCount, delta: like ? 1 : -1)
        return updated
    }

    func setFavorite(_ item: FeedItem, favorite: Bool) async throws -> FeedItem {
        let id = item.statusID.isEmpty ? item.id : item.statusID
        let raw = try await http.postJSON(
            path: favorite ? WeiboEndpoints.statusFavoriteCreate : WeiboEndpoints.statusFavoriteDestroy,
            json: ["id": id],
            referer: "https://weibo.com/fav"
        )
        try assertSuccess(raw, defaultMessage: favorite ? "收藏失败" : "取消收藏失败")
        var updated = item
        updated.favorited = favorite
        return updated
    }

    func deleteStatus(_ item: FeedItem) async throws {
        let raw = try await http.postForm(
            path: WeiboEndpoints.statusDestroy,
            params: ["id": item.id],
            referer: "https://weibo.com/detail/\(item.detailKey)"
        )
        try assertSuccess(raw, defaultMessage: "删除微博失败")
    }

    func setFollowing(uid: String, follow: Bool) async throws {
        let path = follow ? WeiboEndpoints.followCreate : WeiboEndpoints.followDestroy
        let params = follow
            ? ["friend_uid": uid, "page": "profile", "lpage": "profile"]
            : ["uid": uid]
        let raw = try await http.postForm(path: path, params: params, referer: "https://weibo.com/u/\(uid)")
        try assertSuccess(raw, defaultMessage: follow ? "关注失败" : "取消关注失败")
    }

    func postComment(to item: FeedItem, text: String, replyToCommentID: String? = nil) async throws {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw WeiboError.api("评论内容不能为空") }
        var params = [
            "id": item.id,
            "comment": content,
            "pic_id": "",
            "is_repost": "0",
            "comment_ori": "0",
            "is_comment": "0",
            "fp": "",
        ]
        let path: String
        if let replyToCommentID, !replyToCommentID.isEmpty {
            params["cid"] = replyToCommentID
            path = WeiboEndpoints.commentReply
        } else {
            path = WeiboEndpoints.commentCreate
        }
        let raw = try await http.postForm(
            path: path,
            params: params,
            referer: "https://weibo.com/detail/\(item.detailKey)"
        )
        try assertSuccess(raw, defaultMessage: "评论发布失败")
    }

    func repost(_ item: FeedItem, text: String, alsoComment: Bool) async throws {
        let raw = try await http.postForm(
            path: WeiboEndpoints.statusRepost,
            params: [
                "id": item.id,
                "comment": text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "转发微博" : text,
                "is_comment": alsoComment ? "1" : "0",
                "pic_id": "",
            ],
            referer: "https://weibo.com/detail/\(item.detailKey)"
        )
        try assertSuccess(raw, defaultMessage: "转发失败")
    }

    // MARK: - 发布

    func loadComposeToken() async throws -> String {
        let raw = try await http.getAbsolute(
            "https://m.weibo.cn/api/config",
            referer: "https://m.weibo.cn/",
            origin: "https://m.weibo.cn",
            userAgent: WeiboConstants.mweiboUserAgent
        )
        let root = try JSONValue.parse(raw)
        if let token = root["data"]["st"].nonEmptyString { return token }
        if let xsrf = await jar.xsrfToken(), !xsrf.isEmpty { return xsrf }
        throw WeiboError.api("无法获取发布令牌，请稍后重试")
    }

    func uploadImage(_ data: Data, mimeType: String) async throws -> String {
        let identity = await currentUserIdentity()
        let uid = identity?.uid ?? ""
        var screenName = identity?.name ?? ""
        if !screenName.isEmpty && !screenName.hasPrefix("@") { screenName = "@" + screenName }
        let query = [
            "data": "1", "p": "1", "url": "weibo.com/u/\(uid)", "markpos": "1",
            "nick": screenName, "marks": "0", "app": "miniblog", "s": "json",
            "pri": "null", "file_source": "1",
        ]
        let queryString = query
            .sorted { $0.key < $1.key }
            .map { "\($0.key.urlEncoded())=\($0.value.urlEncoded())" }
            .joined(separator: "&")
        let raw = try await http.uploadBinary(
            urlString: "https://picupload.weibo.com/interface/pic_upload.php?\(queryString)",
            data: data,
            contentType: mimeType,
            referer: WeiboConstants.home
        )
        if let pid = Self.extractPID(from: raw) { return pid }
        throw WeiboError.api("图片上传失败：未拿到图片 ID")
    }

    static func extractPID(from raw: String) -> String? {
        if let root = try? JSONValue.parse(raw) {
            let pics = root["data"]["pics"].object
            if let key = pics?.dictionaryKeys.first,
               let pid = pics?[key].nonEmptyString(withKey: "pid") {
                return pid
            }
            if let pid = root["data"]["pid"].nonEmptyString { return pid }
        }
        if let regex = try? NSRegularExpression(pattern: #""pid"\s*:\s*"([^"]+)""#),
           let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
           let range = Range(match.range(at: 1), in: raw) {
            return String(raw[range])
        }
        return nil
    }

    func postStatus(content: String, visibility: WeiboPostVisibility, imagePIDs: [String]) async throws {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !imagePIDs.isEmpty else { throw WeiboError.api("微博内容不能为空") }
        let token = try await loadComposeToken()
        var params = [
            "content": text,
            "visible": String(visibility.apiValue),
            "st": token,
            "_spr": "screen:390x844",
        ]
        if !imagePIDs.isEmpty {
            params["picId"] = imagePIDs.joined(separator: ",")
        }
        let raw = try await http.postForm(
            path: "/api/statuses/update",
            params: params,
            referer: "https://m.weibo.cn/compose/",
            base: "https://m.weibo.cn",
            origin: "https://m.weibo.cn",
            userAgent: WeiboConstants.mweiboUserAgent
        )
        let root = try JSONValue.parse(raw)
        if root["ok"].int == 1 { return }
        throw WeiboError.api(root.firstString("msg", "message") ?? "微博发布失败")
    }
}
