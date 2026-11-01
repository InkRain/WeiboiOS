import Foundation

enum CommentParser {

    static func parseComments(_ raw: String) throws -> [CommentItem] {
        let root = try JSONValue.parse(raw)
        let list: [JSONValue] = {
            let top = root["data"].array
            if !top.isEmpty { return top }
            return root["data"]["comments"].array
        }()
        return list.compactMap { parseComment($0) }
    }

    static func parseTotalCount(_ raw: String) -> Int? {
        guard let root = try? JSONValue.parse(raw) else { return nil }
        let data = root["data"]
        let candidates = [
            data["total_number"].int, data["count"].int, data["total"].int,
            data["status"]["comments_count"].int, root["total_number"].int, root["comments_count"].int,
        ]
        return candidates.compactMap { $0 }.first { $0 > 0 }
    }

    static func nextCursor(_ raw: String) -> String? {
        guard let root = try? JSONValue.parse(raw) else { return nil }
        let cursor = root["data"]["max_id"].string ?? root["max_id"].string
        guard let cursor, !cursor.isEmpty, cursor != "0" else { return nil }
        return cursor
    }

    private static func parseComment(_ comment: JSONValue) -> CommentItem? {
        guard let id = comment.firstString("idstr", "id") else { return nil }
        let user = comment["user"].object
        let images = FeedParser.parseImages(comment)

        return CommentItem(
            id: id,
            authorID: user?.firstString("idstr", "id") ?? "",
            authorName: displayName(user),
            authorAvatarURL: user?.firstString("avatar_hd", "profile_image_url", "avatar_large"),
            text: parseText(comment, images: images),
            createdAt: comment.nonEmptyString(withKey: "created_at"),
            likesCount: HTMLText.formatCount(comment["like_counts"]),
            ipLocation: parseIPLocation(comment),
            images: images,
            comments: comment["comments"].array.compactMap { parseComment($0) },
            replyToAuthor: comment["reply_comment"]["user"].object.map { displayName($0) },
            replyToAuthorID: comment["reply_comment"]["user"].object?.firstString("idstr", "id"),
            urlEntities: parseURLEntities(comment),
            verification: HTMLText.parseVerification(user)
        )
    }

    private static func displayName(_ user: JSONValue?) -> String {
        guard let user else { return "微博用户" }
        if let name = user["screen_name"].nonEmptyString { return name }
        if let name = user["name"].nonEmptyString { return name }
        return "微博用户"
    }

    private static func parseText(_ comment: JSONValue, images: [FeedImage]) -> String {
        let raw = comment["text_raw"].nonEmptyString ?? comment["text"].string ?? ""
        var text = HTMLText.plainText(HTMLText.expandAnchorsToShortURLs(raw))
        // 图片评论的正文里常带图片短链，剥掉避免和图片卡重复。
        let tokens = comment["url_struct"].array.compactMap { entity -> String? in
            entity["pic_ids"].array.isEmpty ? nil : entity["short_url"].nonEmptyString
        }
        text = HTMLText.stripEntityTokens(text, tokens)
        if !images.isEmpty { text = HTMLText.stripOrphanMediaLinks(text) }
        return text
    }

    private static func parseURLEntities(_ comment: JSONValue) -> [FeedUrlEntity] {
        var entities: [FeedUrlEntity] = []
        for entity in comment["url_struct"].array {
            guard let shortURL = entity["short_url"].nonEmptyString,
                  let title = entity.firstString("url_title", "title") else { continue }
            guard entity["pic_ids"].array.isEmpty else { continue }
            let target = entity.firstString("h5_target_url", "long_url", "ori_url") ?? shortURL
            entities.append(FeedUrlEntity(shortURL: shortURL, title: title, url: target))
        }
        return entities
    }

    private static func parseIPLocation(_ comment: JSONValue) -> String? {
        if let source = comment["source"].string.map(HTMLText.plainText) {
            if let range = source.range(of: "来自") {
                let text = String(source[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty && text.count <= 12 { return text }
            }
        }
        for key in ["region_name", "ip_location"] {
            if let text = comment[key].nonEmptyString { return text }
        }
        return nil
    }

    // MARK: - 转发列表

    static func parseReposts(_ raw: String, page: Int) throws -> RepostsPage {
        let root = try JSONValue.parse(raw)
        if root["ok"].exists && root["ok"].int != 1 {
            let message = root.firstString("msg", "message", "error") ?? ""
            if message.isEmpty || message.contains("暂无") || message.contains("没有") || message.contains("为空") {
                return RepostsPage(items: [], nextPage: nil)
            }
            throw WeiboError.api(message)
        }
        let data = root["data"]
        let list: [JSONValue] = {
            for key in ["data", "list", "statuses", "reposts"] {
                let arr = data[key].array
                if !arr.isEmpty { return arr }
            }
            for key in ["data", "list", "statuses", "reposts"] {
                let arr = root[key].array
                if !arr.isEmpty { return arr }
            }
            return []
        }()

        let items = list.compactMap { parseRepost($0) }
        let cursor = data["max_id"].string ?? data["next_cursor"].string
            ?? root["max_id"].string ?? root["next_cursor"].string
        let total = data["total_number"].int64 ?? root["total_number"].int64 ?? 0
        let hasMore = !(cursor == nil || cursor == "0")
        let nextPage: Int?
        if items.isEmpty {
            nextPage = nil
        } else if hasMore {
            nextPage = page + 1
        } else if total > 0 && Int64(page * 20) < total {
            nextPage = page + 1
        } else if items.count >= 20 {
            nextPage = page + 1
        } else {
            nextPage = nil
        }
        return RepostsPage(items: items, nextPage: nextPage, totalCount: total > 0 ? Int(total) : nil)
    }

    private static func parseRepost(_ repost: JSONValue) -> CommentItem? {
        guard let id = repost.firstString("idstr", "id") else { return nil }
        let user = repost["user"].object
        let images = FeedParser.parseImages(repost)
        var text = repost["raw_text"].nonEmptyString ?? HTMLText.plainText(repost["text"].string ?? "")
        if !images.isEmpty { text = HTMLText.stripOrphanMediaLinks(text) }
        if text.isEmpty { text = "转发微博" }

        return CommentItem(
            id: id,
            authorID: user?.firstString("idstr", "id") ?? "",
            authorName: displayName(user),
            authorAvatarURL: user?.firstString("avatar_hd", "profile_image_url"),
            text: HTMLText.tidy(text),
            createdAt: repost.nonEmptyString(withKey: "created_at"),
            likesCount: HTMLText.formatCount(repost["like_counts"]),
            ipLocation: parseIPLocation(repost),
            images: images,
            verification: HTMLText.parseVerification(user)
        )
    }

    // MARK: - 点赞用户

    static func parseLikeUsers(_ raw: String, page: Int) throws -> LikeUsersPage {
        let root = try JSONValue.parse(raw)
        if root["ok"].exists && (root["ok"].int ?? 1) <= 0 {
            let message = root.firstString("msg", "message") ?? "加载点赞列表失败"
            throw WeiboError.api(message)
        }
        let data = root["data"]
        let list = data["data"].array.isEmpty ? data["users"].array : data["data"].array
        let users: [MentionCandidate] = list.compactMap { entry in
            let user = entry["user"].object ?? entry
            guard let id = user.firstString("idstr", "id", "uid") else { return nil }
            return MentionCandidate(
                id: id,
                name: user.firstString("screen_name", "name") ?? "微博用户",
                avatarURL: user.firstString("avatar_hd", "avatar_large", "profile_image_url"),
                verification: HTMLText.parseVerification(user)
            )
        }
        let total = data["total_number"].int ?? data["total"].int
        let nextPage: Int? = users.count >= 20 ? page + 1 : nil
        return LikeUsersPage(users: users, nextPage: nextPage, totalCount: total)
    }
}
