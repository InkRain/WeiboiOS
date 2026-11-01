import Foundation

enum ProfileParser {

    static func parseProfile(
        _ raw: String,
        fallbackUID: String? = nil,
        fallbackName: String? = nil,
        fallbackAvatar: String? = nil
    ) throws -> UserProfile {
        let root = try JSONValue.parse(raw)
        let data = root["data"].object ?? root
        let user = data["user"].object ?? data["userInfo"].object ?? data

        let uid = user.firstString("idstr", "id") ?? fallbackUID ?? ""
        let name = user.firstString("screen_name", "name") ?? fallbackName ?? "微博用户"

        return UserProfile(
            id: uid,
            screenName: name,
            avatarURL: user.firstString("avatar_hd", "avatar_large", "profile_image_url") ?? fallbackAvatar,
            description: user.nonEmptyString(withKey: "description"),
            location: user.nonEmptyString(withKey: "location"),
            ipLocation: normalizeIP(user.firstString("ip_location", "region_name")),
            verifiedReason: user.nonEmptyString(withKey: "verified_reason"),
            followingCount: HTMLText.formatCount(user["friends_count"].exists ? user["friends_count"] : user["follow_count"]),
            followersCount: HTMLText.formatCount(user["followers_count"]),
            statusesCount: HTMLText.formatCount(user["statuses_count"]),
            photosCount: user["photos_count"].exists ? HTMLText.formatCount(user["photos_count"]) : nil,
            coverURLs: coverURLs(user, data),
            following: user["following"].bool,
            followMe: user["follow_me"].bool,
            specialFollowing: user["special_follow"].bool,
            gender: user.nonEmptyString(withKey: "gender"),
            verification: HTMLText.parseVerification(user)
        )
    }

    /// 详情接口只额外提供 IP 属地，其余字段保持列表里的值。
    static func mergeDetail(_ profile: UserProfile, raw: String) -> UserProfile {
        guard let root = try? JSONValue.parse(raw), let data = root["data"].object else { return profile }
        var updated = profile
        if let ip = normalizeIP(data.nonEmptyString(withKey: "ip_location")), !ip.isEmpty {
            updated.ipLocation = ip
        }
        if updated.description == nil {
            updated.description = data.nonEmptyString(withKey: "description")
        }
        return updated
    }

    private static func normalizeIP(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        var text = raw.trimmingCharacters(in: .whitespaces)
        for prefix in ["IP属地：", "IP属地:", "来自", "发布于"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func coverURLs(_ user: JSONValue, _ data: JSONValue) -> [String] {
        var urls: [String] = []
        if let phone = user.nonEmptyString(withKey: "cover_image_phone") {
            urls = phone
                .split(whereSeparator: { $0 == "," || $0 == " " })
                .compactMap { HTMLText.normalizeURL(String($0)) }
        }
        for key in ["cover_image", "cover"] {
            if let url = HTMLText.normalizeURL(user.nonEmptyString(withKey: key) ?? data.nonEmptyString(withKey: key)) {
                urls.append(url)
            }
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0).inserted }
    }

    // MARK: - 相册

    /// 相册接口一行里可能混着「图片 / 视频封面 / live photo」，
    /// 统一转成带尺寸的 FeedImage，交给九宫格直接渲染。
    static func parseImageWall(_ raw: String, uid: String) throws -> AlbumPage {
        let root = try JSONValue.parse(raw)
        let ok = root["ok"].int ?? 0
        if ok == -100 { throw WeiboError.api("相册需要登录后查看") }
        if ok != 1 {
            let hint = root.firstString("msg", "url") ?? "ok=\(ok)"
            throw WeiboError.api("相册接口返回异常：\(hint)")
        }
        let data = root["data"]
        let lists = data["list"].array + data["photo_wall"].array
        var images: [FeedImage] = []
        for item in lists {
            if let image = albumImage(from: item, uid: uid) { images.append(image) }
        }
        var seen = Set<String>()
        let unique = images.filter { seen.insert($0.id + $0.largeURL).inserted }

        // 视频墙返回 cursor，照片墙返回 since_id，两者不能混用。
        if let nextCursor = data.firstString("cursor", "next_cursor"),
           !nextCursor.isEmpty, nextCursor != "0" {
            return AlbumPage(images: unique, nextCursor: WeiboSession.albumCursorPrefix + nextCursor)
        }
        let nextSince = data["since_id"].string.flatMap { $0 == "0" ? nil : $0 }
            ?? data["next_since_id"].string.flatMap { $0 == "0" ? nil : $0 }
        return AlbumPage(images: unique, nextCursor: nextSince)
    }

    private static func albumImage(from item: JSONValue, uid: String) -> FeedImage? {
        let payload = item["pic_detail_vo"].object
            ?? item["photo_detail_vo"].object
            ?? item["video_detail_vo"].object
            ?? item

        guard let large = largeImageURL(payload) else { return nil }
        let thumbnail = HTMLText.normalizeURL(
            payload.firstString("thumbnail_pic", "pic", "small", "cover")
        ) ?? large

        let mid = payload.firstString("mid", "id")
        return FeedImage(
            id: mid ?? large,
            thumbnailURL: thumbnail,
            largeURL: large,
            downloadURLs: [large],
            livePhotoVideoURL: nil,
            videoStreamURL: nil,
            createdAt: payload.nonEmptyString(withKey: "created_at") ?? (mid.flatMap(dateFromMid)),
            statusID: payload.firstString("mblogid", "blog_id", "status_id") ?? mid,
            width: payload.firstInt("width", "pic_width"),
            height: payload.firstInt("height", "pic_height"),
            type: payload.firstString("type", "pic_type")
        )
    }

    private static func largeImageURL(_ payload: JSONValue) -> String? {
        for key in ["large", "large_pic", "pic", "url", "pic_url", "original_pic"] {
            if let url = HTMLText.normalizeURL(payload.nonEmptyString(withKey: key)),
               url.contains("sinaimg") || url.contains(".jpg") || url.contains(".png") || url.contains(".gif") {
                return url
            }
        }
        // 只有 pid 时按 sinaimg 规则拼出大图地址。
        if let pid = payload.firstString("pid", "pic_id") {
            return largeURL(fromPid: pid)
        }
        if let infos = payload["pic_infos"].object, let first = infos.dictionaryKeys.first {
            return largeURL(fromPid: first)
        }
        return nil
    }

    private static func largeURL(fromPid pid: String) -> String {
        let clean = pid.components(separatedBy: ".").first ?? pid
        let ext = pid.lowercased().contains(".gif") ? "gif" : "jpg"
        let host: String
        if clean.hasPrefix("006") || clean.hasPrefix("007") {
            host = "wx2"
        } else if clean.hasPrefix("008") || clean.hasPrefix("009") {
            host = "wx3"
        } else {
            host = "wx\(abs(clean.hashValue) % 4 + 1)"
        }
        return "https://\(host).sinaimg.cn/large/\(clean).\(ext)"
    }

    /// 微博 mid 高 32 位是秒级时间戳（偏移 515483463），可还原发布日期。
    private static func dateFromMid(_ mid: String) -> String? {
        guard let value = Int64(mid) else { return nil }
        let seconds = (value >> 22) + 515_483_463
        guard seconds > 1_000_000_000, seconds < 4_102_444_800 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    // MARK: - 关注 / 粉丝列表

    static func parseRelationUsers(_ raw: String) throws -> [SearchUserItem] {
        let root = try JSONValue.parse(raw)
        let data = root["data"].object ?? root
        let list = data["users"].array.isEmpty ? data["list"].array : data["users"].array
        return list.compactMap { entry in
            let user = entry["user"].object ?? entry
            guard let id = user.firstString("idstr", "id") else { return nil }
            return SearchUserItem(
                id: id,
                screenName: user.firstString("screen_name", "name") ?? "微博用户",
                avatarURL: user.firstString("avatar_hd", "avatar_large", "profile_image_url"),
                description: HTMLText.plainText(user["description"].string ?? ""),
                followersCount: user.firstString("followers_count_str") ?? HTMLText.formatCount(user["followers_count"]),
                verification: HTMLText.parseVerification(user)
            )
        }
    }
}
