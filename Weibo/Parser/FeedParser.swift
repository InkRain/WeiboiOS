import Foundation

/// 微博 `status` 结构解析。所有取值都做了兜底，因为同一个接口在不同账号、
/// 不同时段返回的字段集合并不一致。
enum FeedParser {

    // MARK: - 列表入口

    static func parseTimeline(_ raw: String) throws -> TimelinePage {
        let root = try JSONValue.parse(raw)
        let statuses = root["statuses"].array.isEmpty
            ? (root["data"]["statuses"].array.isEmpty
                ? (root["data"]["list"].array.isEmpty ? root["list"].array : root["data"]["list"].array)
                : root["data"]["statuses"].array)
            : root["statuses"].array

        var items: [FeedItem] = []
        for entry in statuses {
            let status = entry["mblog"].object ?? entry
            guard !isAdvertisement(status) else { continue }
            if let item = parseStatus(status, allowRetweeted: true) { items.append(item) }
        }
        let nextCursor = root.firstString("max_id")
            ?? root["data"].firstString("max_id", "next_cursor")
        return TimelinePage(items: items, nextCursor: nextCursor?.isEmpty == false ? nextCursor : nil)
    }

    /// 个人主页 / 收藏 / 点赞等「按页码翻页」的接口。
    static func parsePersonalFeed(_ raw: String, page: Int) throws -> TimelinePage {
        let root = try JSONValue.parse(raw)
        let data = root["data"]
        let statuses: [JSONValue] = {
            let candidates = [
                root["statuses"].array, data["statuses"].array, data["list"].array,
                data["favorites"].array, root["list"].array, root["data"].array,
            ]
            return candidates.first { !$0.isEmpty } ?? []
        }()

        var items: [FeedItem] = []
        for entry in statuses {
            let status = entry["mblog"].object ?? entry["status"].object ?? entry["weibo"].object ?? entry
            guard !isAdvertisement(status) else { continue }
            if let item = parseStatus(status, allowRetweeted: true) { items.append(item) }
        }
        let hasMore = data["has_more"].bool || !items.isEmpty
        return TimelinePage(
            items: items,
            nextCursor: hasMore && !items.isEmpty ? String(page + 1) : nil
        )
    }

    static func parseUserTimeline(_ raw: String, uid: String, page: Int) throws -> TimelinePage {
        var parsed = try parseTimeline(raw)
        parsed.items = parsed.items.filter { $0.authorID == uid }
        if parsed.nextCursor == nil, !parsed.items.isEmpty {
            parsed.nextCursor = String(page + 1)
        }
        return parsed
    }

    static func parseStatusDetail(_ raw: String) throws -> FeedItem? {
        let root = try JSONValue.parse(raw)
        guard let status = unwrapStatus(root), !isAdvertisement(status) else { return nil }
        return parseStatus(status, allowRetweeted: true)
    }

    /// m.weibo.cn 的卡片式容器（搜索、话题、超话都在用）。
    static func parseMweiboContainer(_ raw: String, page: Int) throws -> TimelinePage {
        let root = try JSONValue.parse(raw)
        guard root["ok"].int != 0 || root["data"].exists else {
            let message = root.firstString("msg", "message") ?? "搜索结果读取失败，请稍后重试"
            throw WeiboError.api(message)
        }
        let data = root["data"]
        var items: [FeedItem] = []
        for card in data["cards"].array {
            for mblog in collectMweiboStatuses(card) {
                if mblog["isAd"].int == 1 { continue }
                if let item = parseStatus(normalizeMweiboStatus(mblog), allowRetweeted: true) {
                    items.append(item)
                }
            }
        }
        let info = data["cardlistInfo"]
        let total = info["total"].int64 ?? 0
        let pageSize = info["page_size"].int64 ?? 10
        let currentPage = info["page"].int ?? page
        let hasMore = total > Int64(currentPage) * max(pageSize, 1)
        return TimelinePage(
            items: items,
            nextCursor: (hasMore || (items.count >= 10 && total == 0)) ? String(currentPage + 1) : nil
        )
    }

    // MARK: - status 主体

    static func parseStatus(_ status: JSONValue, allowRetweeted: Bool) -> FeedItem? {
        guard let id = status.firstString("idstr", "mid", "id") else { return nil }
        let user = status["user"].object
        let authorID = user?.firstString("idstr", "id") ?? ""

        let retweetedJson = allowRetweeted && !isAdvertisement(status["retweeted_status"])
            ? status["retweeted_status"].object
            : nil
        var retweeted: FeedItem?
        if let retweetedJson {
            retweeted = parseStatus(normalizeRetweeted(retweetedJson), allowRetweeted: false)
        }

        let medias = parseMedias(status)
        let htmlText = status["text"].string ?? ""
        let rawText = status.firstString("text_raw", "raw_text") ?? htmlText
        let displayText = buildDisplayText(rawText: rawText, htmlText: htmlText)

        var images = parseImages(status)
        if images.isEmpty == false, let retweetedImages = retweeted?.images, !retweetedImages.isEmpty {
            // 转发外层常把原博的图片再挂一遍，去重避免展示两套。
            let outerKeys = Set(images.map(\.largeURL))
            let innerKeys = Set(retweetedImages.map(\.largeURL))
            if !outerKeys.isEmpty && outerKeys == innerKeys {
                images = []
            }
        }

        var urlEntities = parseURLEntities(status, sourceText: displayText)
        if retweeted != nil {
            urlEntities = urlEntities.filterNotMediaLink()
        }

        var text = parseStatusText(
            status: status,
            sourceRaw: displayText,
            images: images,
            medias: medias,
            urlEntities: urlEntities
        )
        if retweeted != nil {
            text = stripWeiboHostedVideoTitles(text)
        }

        let editInfo = parseEditMetadata(status)
        let location = parseLocation(status, referenceText: retweeted != nil
            ? rawText.components(separatedBy: "//@").first ?? rawText
            : rawText)

        let item = FeedItem(
            id: id,
            statusID: status["mblogid"].nonEmptyString ?? id,
            authorID: authorID,
            authorName: user?.nonEmptyString(withKey: "screen_name") ?? "微博用户",
            authorAvatarURL: user?.firstString("avatar_hd", "profile_image_url", "avatar_large"),
            createdAt: status.nonEmptyString(withKey: "created_at"),
            source: HTMLText.plainText(status["source"].string ?? ""),
            ipLocation: parseIPLocation(status),
            locationName: location?.name,
            locationURL: location?.url,
            text: text,
            requiresLongTextFetch: hasLongTextFlag(status) || isTextTruncated(rawText: rawText, displayText: displayText),
            repostsCount: HTMLText.formatCount(status["reposts_count"]),
            commentsCount: HTMLText.formatCount(status["comments_count"]),
            likesCount: HTMLText.formatCount(status["attitudes_count"]),
            liked: status["attitudes_status"].int == 1,
            favorited: status["favorited"].bool || status["is_favorite"].bool,
            images: images,
            medias: medias,
            urlEntities: urlEntities,
            retweetedRef: retweeted.map(FeedItemRef.init),
            isEdited: editInfo.edited,
            editCount: editInfo.count,
            isPinned: isPinnedStatus(status),
            visibility: WeiboPostVisibility.from(
                apiValue: status["visible"]["type"].int ?? status["visible"].int ?? status["visible_type"].int
            ),
            poll: parsePoll(status, links: urlEntities),
            verification: HTMLText.parseVerification(user)
        )

        if let embedded = status["longText"].object, hasLongTextPayload(embedded) {
            return mergeLongText(into: item, data: embedded)
        }
        return item
    }

    // MARK: - 文本

    private static func buildDisplayText(rawText: String, htmlText: String) -> String {
        let fromHTML = HTMLText.plainText(HTMLText.expandAnchorsToShortURLs(htmlText))
        if fromHTML.isEmpty { return rawText }

        let htmlLinks = countShortLinks(fromHTML)
        let rawLinks = countShortLinks(rawText)
        let htmlTopics = countTopicMarkers(fromHTML)
        let rawTopics = countTopicMarkers(rawText)

        if rawLinks > htmlLinks { return rawText }
        if rawTopics > htmlTopics { return rawText }
        if htmlLinks > 0 { return fromHTML }
        if Double(fromHTML.count) >= Double(rawText.count) * 0.6 { return fromHTML }
        return rawText
    }

    private static func countShortLinks(_ text: String) -> Int {
        text.ranges(of: #"https?://t\.cn/[A-Za-z0-9]+"#).count
    }

    private static func countTopicMarkers(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.ranges(of: #"#[^#\n]+#"#).count
    }

    private static func parseStatusText(
        status: JSONValue,
        sourceRaw: String,
        images: [FeedImage],
        medias: [FeedMedia],
        urlEntities: [FeedUrlEntity]
    ) -> String {
        let preserved = Set(urlEntities.map(\.shortURL))
        var text = HTMLText.plainText(sourceRaw)

        // url_struct 里带 pic_ids 的条目是图片短链，正文里不该再显示。
        let imageTokens = imageURLTokens(status["url_struct"], sourceRaw: sourceRaw)
            .filter { !preserved.contains($0) }
        text = HTMLText.stripEntityTokens(text, imageTokens)

        if !medias.isEmpty {
            text = HTMLText.stripEntityTokens(text, mediaURLTokens(status, sourceRaw: sourceRaw))
        }

        if (!images.isEmpty || !medias.isEmpty) && urlEntities.isEmpty {
            text = HTMLText.stripOrphanMediaLinks(text)
        } else if !urlEntities.isEmpty {
            text = HTMLText.stripOrphanMediaLinks(text, keeping: preserved)
        }
        return text
    }

    private static func stripWeiboHostedVideoTitles(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for pattern in [#"L?\S{1,40}的微博视频"#, #"L?\S{1,40}的微博直播"#, #"L?\S{1,40}的微博故事"#] {
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression])
        }
        return HTMLText.tidy(result)
    }

    // MARK: - 链接实体

    private static func parseURLEntities(_ status: JSONValue, sourceText: String) -> [FeedUrlEntity] {
        let structs = status["url_struct"].array
        guard !structs.isEmpty else { return [] }
        var entities: [FeedUrlEntity] = []
        for entity in structs {
            guard let shortURL = entity["short_url"].nonEmptyString else { continue }
            guard sourceText.contains(shortURL) else { continue }
            let picIDs = entity["pic_ids"].array
            if !picIDs.isEmpty && entity["pic_infos"].object != nil { continue }
            if entity["url_type"].exists && (entity["url_type"].int ?? 1) == 1 { continue }
            guard let title = entity.firstString("url_title", "title") else { continue }
            let target = entity.firstString("h5_target_url", "long_url", "ori_url") ?? shortURL
            entities.append(
                FeedUrlEntity(
                    shortURL: shortURL,
                    title: title,
                    url: target,
                    isMediaLink: isMediaEntity(entity, title: title)
                )
            )
        }
        // 同一「xxx的微博视频」常对应多条短链，只保留一条。
        var seenVideoTitles = Set<String>()
        return entities.filter { entity in
            guard entity.isMediaLink else { return true }
            return seenVideoTitles.insert(entity.title).inserted
        }
    }

    private static func isMediaEntity(_ entity: JSONValue, title: String) -> Bool {
        if title.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil {
            return false
        }
        let objectType = entity["object_type"].string?.lowercased() ?? ""
        if ["video", "live", "story", "movie", "audio", "gif"].contains(objectType) { return true }
        if title.contains("微博视频") || title.contains("微博直播")
            || title.contains("微博故事") || title.contains("的视频") {
            return true
        }
        let candidates = [
            entity["h5_target_url"].string, entity["long_url"].string,
            entity["ori_url"].string, entity["short_url"].string,
        ].compactMap { $0?.lowercased() }
        return candidates.contains { url in
            url.contains("video.weibo.com") || url.contains("weibo.com/tv")
                || url.contains("media.weibo.cn") || url.contains("/tv/show/")
                || url.contains("livestream")
        }
    }

    private static func imageURLTokens(_ urlStruct: JSONValue, sourceRaw: String) -> [String] {
        var tokens: [String] = []
        for entity in urlStruct.array {
            let picIDs = entity["pic_ids"].array
            guard !picIDs.isEmpty else { continue }
            if let short = entity["short_url"].nonEmptyString, sourceRaw.contains(short) {
                tokens.append(short)
            }
            if let title = entity.firstString("url_title", "title"), sourceRaw.contains(title) {
                tokens.append(title)
            }
        }
        return tokens
    }

    private static func mediaURLTokens(_ status: JSONValue, sourceRaw: String) -> [String] {
        var tokens: [String] = []
        for entity in status["url_struct"].array where isMediaEntity(entity, title: entity["url_title"].string ?? "") {
            for key in ["short_url", "long_url", "ori_url", "h5_target_url", "url_title", "title"] {
                if let value = entity[key].nonEmptyString, sourceRaw.contains(value) {
                    tokens.append(value)
                }
            }
        }
        if let pageInfo = status["page_info"].object {
            let title = pageInfo.firstString("page_title", "title") ?? ""
            let looksVideo = ["video", "live", "story"].contains(pageInfo["type"].string?.lowercased() ?? "")
                || ["video", "live", "story"].contains(pageInfo["object_type"].string?.lowercased() ?? "")
                || title.contains("微博视频") || title.contains("微博直播")
            if looksVideo {
                for key in ["page_url", "url_ori"] {
                    if let value = pageInfo[key].nonEmptyString, sourceRaw.contains(value) {
                        tokens.append(value)
                    }
                }
                if let h5 = pageInfo["media_info"]["h5_url"].nonEmptyString, sourceRaw.contains(h5) {
                    tokens.append(h5)
                }
                if !title.isEmpty && sourceRaw.contains(title) { tokens.append(title) }
            }
        }
        return tokens
    }

    // MARK: - 图片

    static func parseImages(_ status: JSONValue) -> [FeedImage] {
        let picIDs = status["pic_ids"].array
        let picInfos = status["pic_infos"].object
        var images: [FeedImage] = []

        if picInfos != nil {
            for picID in picIDs {
                guard let key = picID.string, let info = picInfos?[key].object else { continue }
                if let image = imageFromPicInfo(key: key, info: info) {
                    images.append(withTimestamp(image, status))
                }
            }
        }
        if images.isEmpty {
            // mix_media_info 是新版「图文混合」结构，图片和视频混排。
            for item in status["mix_media_info"]["items"].array {
                guard item["type"].string == "pic" else { continue }
                let data = item["data"]
                let key = data.firstString("pic_id", "object_id", "id") ?? ""
                if let image = imageFromPicInfo(key: key, info: data) {
                    images.append(withTimestamp(image, status))
                }
            }
        }
        return images
    }

    private static func withTimestamp(_ image: FeedImage, _ status: JSONValue) -> FeedImage {
        var copy = image
        if copy.createdAt == nil { copy.createdAt = status.nonEmptyString(withKey: "created_at") }
        return copy
    }

    private static func imageFromPicInfo(key: String, info: JSONValue) -> FeedImage? {
        let large = info["largest"]["url"].nonEmptyString
            ?? info["large"]["url"].nonEmptyString
            ?? info["bmiddle"]["url"].nonEmptyString
            ?? info["thumbnail"]["url"].nonEmptyString
        guard let large = HTMLText.normalizeURL(large) else { return nil }
        let thumb = HTMLText.normalizeURL(
            info["thumbnail"]["url"].nonEmptyString
                ?? info["bmiddle"]["url"].nonEmptyString
                ?? large
        ) ?? large

        var downloads: [String] = [large]
        for k in ["largest", "large", "bmiddle"] {
            if let url = HTMLText.normalizeURL(info[k]["url"].nonEmptyString), !downloads.contains(url) {
                downloads.append(url)
            }
        }

        let liveURL = HTMLText.normalizeURL(
            info["video"].nonEmptyString(withKey: "url")
                ?? info["live_photo"].nonEmptyString(withKey: "video_url")
        )
        let type = info["type"].string?.lowercased()

        return FeedImage(
            id: key.isEmpty ? large : key,
            thumbnailURL: thumb,
            largeURL: large,
            downloadURLs: downloads,
            livePhotoVideoURL: liveURL,
            videoStreamURL: nil,
            createdAt: nil,
            statusID: nil,
            width: info["largest"]["width"].int ?? info["large"]["width"].int,
            height: info["largest"]["height"].int ?? info["large"]["height"].int,
            type: type
        )
    }

    // MARK: - 视频

    private static func parseMedias(_ status: JSONValue) -> [FeedMedia] {
        var medias: [FeedMedia] = []

        for item in status["mix_media_info"]["items"].array {
            guard item["type"].string == "video" else { continue }
            let data = item["data"]
            let mediaInfo = data["media_info"]
            guard let stream = progressiveVideoURL(mediaInfo) else { continue }
            let cover = HTMLText.normalizeURL(
                data.nonEmptyString(withKey: "page_pic")
                    ?? mediaInfo["big_pic_info"]["pic_big"].nonEmptyString(withKey: "url")
            )
            medias.append(
                FeedMedia(
                    kind: .video,
                    title: mediaInfo.nonEmptyString(withKey: "video_title")
                        ?? data.nonEmptyString(withKey: "content1") ?? "微博视频",
                    coverURL: cover,
                    streamURL: stream,
                    downloadURL: downloadVideoURL(mediaInfo),
                    durationSeconds: mediaDuration(mediaInfo, data),
                    videoOrientation: mediaInfo.nonEmptyString(withKey: "video_orientation"),
                    coverWidth: coverWidth(mediaInfo),
                    coverHeight: coverHeight(mediaInfo)
                )
            )
        }
        if !medias.isEmpty { return medias }

        guard let pageInfo = status["page_info"].object,
              let mediaInfo = pageInfo["media_info"].object else { return [] }
        let objectType = pageInfo["object_type"].string ?? ""
        if objectType == "live" {
            let liveStatus = mediaInfo["live_status"].int
            let stream = HTMLText.normalizeURL(
                mediaInfo.nonEmptyString(withKey: "live_ld") ?? mediaInfo.nonEmptyString(withKey: "stream_url")
            ) ?? ""
            let replay = HTMLText.normalizeURL(mediaInfo.nonEmptyString(withKey: "replay_hd"))
            if stream.isEmpty && (replay?.isEmpty ?? true) { return [] }
            let cover = HTMLText.normalizeURL(
                pageInfo.nonEmptyString(withKey: "page_pic")
                    ?? mediaInfo["big_pic_info"]["pic_big"].nonEmptyString(withKey: "url")
            )
            return [
                FeedMedia(
                    kind: .live,
                    title: mediaInfo.nonEmptyString(withKey: "video_title")
                        ?? pageInfo.nonEmptyString(withKey: "page_title") ?? "微博直播",
                    coverURL: cover,
                    streamURL: stream,
                    downloadURL: nil,
                    durationSeconds: nil,
                    liveStatus: liveStatus,
                    replayURL: replay,
                    videoOrientation: mediaInfo.nonEmptyString(withKey: "video_orientation"),
                    coverWidth: coverWidth(mediaInfo),
                    coverHeight: coverHeight(mediaInfo)
                )
            ]
        }

        guard let stream = progressiveVideoURL(mediaInfo) else { return [] }
        let cover = HTMLText.normalizeURL(
            pageInfo.nonEmptyString(withKey: "page_pic")
                ?? mediaInfo["big_pic_info"]["pic_big"].nonEmptyString(withKey: "url")
        )
        let kind: MediaKind = objectType == "audio" ? .audio : .video
        return [
            FeedMedia(
                kind: kind,
                title: mediaInfo.nonEmptyString(withKey: "video_title")
                    ?? pageInfo.nonEmptyString(withKey: "page_title")
                    ?? (kind == .audio ? "微博音频" : "微博视频"),
                coverURL: cover,
                streamURL: stream,
                downloadURL: downloadVideoURL(mediaInfo),
                durationSeconds: mediaDuration(mediaInfo, pageInfo),
                videoOrientation: mediaInfo.nonEmptyString(withKey: "video_orientation"),
                coverWidth: coverWidth(mediaInfo),
                coverHeight: coverHeight(mediaInfo)
            )
        ]
    }

    private static func coverWidth(_ mediaInfo: JSONValue) -> Int? {
        mediaInfo["big_pic_info"]["pic_big"]["width"].int
    }

    private static func coverHeight(_ mediaInfo: JSONValue) -> Int? {
        mediaInfo["big_pic_info"]["pic_big"]["height"].int
    }

    /// 优先选兼容性最好的 mp4，其次 m3u8。
    private static func progressiveVideoURL(_ mediaInfo: JSONValue) -> String? {
        let keys = [
            "mp4_1080p_mp4", "mp4_720p_mp4", "mp4_hd_url", "mp4_sd_url",
            "mp4_ld_url", "stream_url_hd", "stream_url",
        ]
        for key in keys {
            if let url = HTMLText.normalizeURL(mediaInfo.nonEmptyString(withKey: key)) {
                let lower = url.lowercased()
                if lower.contains(".mp4") || lower.contains("mp4") || lower.contains("m3u8") {
                    return url
                }
            }
        }
        if let url = bestProgressiveFromPlaybackList(mediaInfo) { return url }
        for key in keys {
            if let url = HTMLText.normalizeURL(mediaInfo.nonEmptyString(withKey: key)) { return url }
        }
        for key in ["h265_mp4_hd", "h265_mp4_ld", "hevc_mp4_720p", "hevc_mp4_hd"] {
            if let url = HTMLText.normalizeURL(mediaInfo.nonEmptyString(withKey: key)) { return url }
        }
        return nil
    }

    private static func bestProgressiveFromPlaybackList(_ mediaInfo: JSONValue) -> String? {
        let list = mediaInfo["playback_list"]["play_info"].array.isEmpty
            ? mediaInfo["playback_list"].array
            : mediaInfo["playback_list"]["play_info"].array
        var best: (score: Int, quality: Int, url: String)?
        for item in list {
            let meta = item["meta"]
            if meta["is_hidden"].bool { continue }
            if (meta["type"].int ?? -1) == 2 { continue }
            let playInfo = item["play_info"].object ?? item
            let proto = (playInfo["protocol"].string ?? item["protocol"].string ?? "").lowercased()
            if proto == "dash" { continue }
            guard let url = playInfo["url"].nonEmptyString else { continue }
            let quality = meta["quality_index"].int ?? playInfo["quality_index"].int ?? 0
            let lower = url.lowercased()
            let score: Int
            if lower.contains("h265") || lower.contains("hevc") {
                score = 1
            } else if lower.contains("m3u8") {
                score = 2
            } else if lower.contains("mp4") {
                score = 3
            } else {
                score = 1
            }
            if best == nil || score > best!.score || (score == best!.score && quality > best!.quality) {
                best = (score, quality, url)
            }
        }
        return best?.url
    }

    private static func downloadVideoURL(_ mediaInfo: JSONValue) -> String? {
        for key in ["mp4_1080p_mp4", "mp4_720p_mp4", "mp4_hd_url", "mp4_sd_url",
                    "mp4_ld_url", "stream_url_hd", "stream_url"] {
            if let url = HTMLText.normalizeURL(mediaInfo.nonEmptyString(withKey: key)) { return url }
        }
        return nil
    }

    private static func mediaDuration(_ sources: JSONValue...) -> Int? {
        for source in sources {
            for key in ["duration", "video_duration"] {
                if let raw = source[key].int, raw > 0 {
                    return raw > 10_000 ? raw / 1000 : raw
                }
            }
            for key in ["duration_time", "duration_label", "video_duration"] {
                if let text = source[key].string, let seconds = parseDurationText(text) {
                    return seconds
                }
            }
        }
        return nil
    }

    private static func parseDurationText(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let value = Int(trimmed) { return value > 0 ? (value > 10_000 ? value / 1000 : value) : nil }
        let parts = trimmed.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }

    // MARK: - 投票

    private static func parsePoll(_ status: JSONValue, links: [FeedUrlEntity]) -> FeedPoll? {
        let page = status["page_info"]
        let explicit = page["card_info"]["vote_object"].object
            ?? status["vote_info"].object
            ?? status["vote"].object
            ?? page["vote_info"].object
            ?? page["vote"].object
            ?? page["vote_object"].object
        let link = links.first {
            $0.title.trimmingCharacters(in: .whitespaces) == "微博投票"
                || $0.url.range(of: #"https?://vote\.weibo\.(com|cn)(/|$)"#, options: .regularExpression) != nil
        }
        let isVotePage = ["object_type", "type", "page_type"].contains { key in
            ["vote", "poll", "hudongvote"].contains(page[key].string?.lowercased() ?? "")
        }
        guard explicit != nil || link != nil || isVotePage else { return nil }
        let data = explicit ?? (page.exists ? page["card_info"].object ?? page : .null)

        func label(_ source: JSONValue, _ names: [String]) -> String? {
            for name in names {
                if let text = source[name].string?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                    return text
                }
            }
            return nil
        }
        func count(_ source: JSONValue, _ names: [String]) -> Int64? {
            for name in names {
                if let value = source[name].int64, value >= 0 { return value }
            }
            return nil
        }

        let optionsArray = data["options"].array.isEmpty
            ? (data["option_list"].array.isEmpty
                ? (data["vote_items"].array.isEmpty ? data["vote_list"].array : data["vote_items"].array)
                : data["option_list"].array)
            : data["options"].array

        var options: [FeedPollOption] = []
        for (index, option) in optionsArray.enumerated() {
            let text = label(option, ["text", "title", "content", "option", "name"])
                ?? option.nonEmptyString
            guard let text, !text.isEmpty else { continue }
            options.append(
                FeedPollOption(
                    id: label(option, ["id", "option_id"]) ?? "\(index)",
                    text: text.replacingOccurrences(of: "<[^>]+>", with: "", options: [.regularExpression]),
                    count: count(option, ["part_num", "vote_count", "count", "num"]),
                    countText: label(option, ["part_num", "vote_count", "count", "num"]),
                    selected: option["selected"].bool || option["is_voted"].int == 1
                )
            )
        }

        var title = label(data, ["title", "vote_title", "question", "page_title", "content"])
            ?? label(page, ["page_title", "title"])
            ?? link?.title
            ?? "微博投票"
        title = title.replacingOccurrences(of: "<[^>]+>", with: "", options: [.regularExpression])

        return FeedPoll(
            id: label(data, ["id", "vote_id"]),
            title: title,
            options: options,
            participantCount: count(data, ["participant_count", "total_count", "total", "join_num", "part_num"]),
            endTime: label(data, ["end_time", "expire_time", "endtime", "expire_date", "end_time_str"]),
            isEnded: data["status"].int == 0 || data["state"].int == 0,
            hasVoted: data["parted"].int == 1 || options.contains { $0.selected },
            maximum: max(data["maximum"].int ?? 1, 1),
            minimum: max(data["minimum"].int ?? 1, 1)
        )
    }

    // MARK: - 元信息

    private static func parseIPLocation(_ status: JSONValue) -> String? {
        let candidates = [
            status["region_name"].nonEmptyString,
            status["ip_location"].nonEmptyString,
            status["status_region_name"].nonEmptyString,
        ]
        for candidate in candidates {
            guard var text = candidate else { continue }
            for prefix in ["IP属地：", "IP属地:", "来自", "发布于"] where text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
            }
            text = text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        // 老接口把属地塞在 source 里，形如「来自 北京」。
        if let source = status["source"].string.map(HTMLText.plainText) {
            if let range = source.range(of: "来自") {
                let text = String(source[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty && text.count <= 12 { return text }
            }
        }
        return nil
    }

    private static func parseLocation(_ status: JSONValue, referenceText: String) -> (name: String, url: String?)? {
        guard let pageInfo = status["page_info"].object,
              pageInfo["object_type"].string == "place" || pageInfo["type"].string == "place" else {
            // 部分接口把 POI 放在 status 的 poi 字段。
            if let poi = status["poi"].object, let name = poi.nonEmptyString(withKey: "name") {
                return (name, poi.nonEmptyString(withKey: "url") ?? poi.nonEmptyString(withKey: "h5_url"))
            }
            return nil
        }
        guard let name = pageInfo.firstString("content1", "page_title", "title") else { return nil }
        guard referenceText.contains(name) || name.count > 1 else { return nil }
        let url = pageInfo.firstString("page_url", "url_ori", "h5_url")
        return (name, url)
    }

    private static func parseEditMetadata(_ status: JSONValue) -> (edited: Bool, count: Int) {
        let count = status["edit_count"].int ?? 0
        let edited = count > 1
            || status["edited"].bool
            || status["is_edit"].int == 1
            || status["edit_at"].exists
        return (edited, count)
    }

    private static func isPinnedStatus(_ status: JSONValue) -> Bool {
        if status["isTop"].int == 1 || status["is_top"].int == 1 { return true }
        return status["title"]["text"].string?.contains("置顶") == true
    }

    private static func hasLongTextFlag(_ status: JSONValue) -> Bool {
        status["isLongText"].bool || status["is_long_text"].bool || status["longText"].object != nil
    }

    private static func isTextTruncated(rawText: String, displayText: String) -> Bool {
        if rawText.hasSuffix("...") || rawText.hasSuffix("…") { return true }
        return rawText.range(of: #"(全文|展开)$"#, options: .regularExpression) != nil
    }

    static func hasLongTextPayload(_ data: JSONValue) -> Bool {
        if let longText = data["longTextContent"].nonEmptyString ?? data["longText"].nonEmptyString {
            return !longText.isEmpty
        }
        return data["longText"].object != nil
    }

    /// 长文接口返回的是完整 HTML，合并时替换正文但保留原有媒体与计数。
    static func mergeLongText(into item: FeedItem, data: JSONValue) -> FeedItem {
        let html = data["longTextContent"].nonEmptyString
            ?? data["longText"].string
            ?? data["longText"]["longTextContent"].nonEmptyString
        guard let html, !html.isEmpty else { return item }
        var text = HTMLText.plainText(HTMLText.expandAnchorsToShortURLs(html))
        text = text.replacingOccurrences(of: #"(?<=\S)\s*(?:全文|展开)$"#, with: "", options: [.regularExpression])
        guard text.count > item.text.count else { return item }
        var updated = item
        updated.text = text
        updated.requiresLongTextFetch = false
        return updated
    }

    // MARK: - 辅助

    private static func unwrapStatus(_ root: JSONValue) -> JSONValue? {
        let data = root["data"]
        if isStatusLike(data) { return data }
        for container in [data["mblog"], data["status"], root["mblog"], root["status"]] {
            if isStatusLike(container) { return container }
        }
        return isStatusLike(root) ? root : nil
    }

    private static func isStatusLike(_ value: JSONValue) -> Bool {
        guard value.exists else { return false }
        return value["user"].object != nil
            || value.firstString("idstr", "mid", "id") != nil
            || value["retweeted_status"].object != nil
    }

    private static func isAdvertisement(_ status: JSONValue) -> Bool {
        if status["is_ad"].int == 1 || status["isAd"].int == 1 { return true }
        if status["ad_state"].int == 1 || status["adState"].int == 1 { return true }
        if status["promotion"].object != nil { return true }
        return status["mblogtypename"].string?.contains("广告") == true
    }

    /// m.weibo.cn 的 mblog 缺 mblogid、图片字段也不同，先归一化再用同一套解析。
    private static func normalizeMweiboStatus(_ mblog: JSONValue) -> JSONValue {
        guard var dict = mblog.value as? [String: Any] else { return mblog }
        if dict["mblogid"] == nil, let bid = dict["bid"] as? String {
            dict["mblogid"] = bid
        }
        if dict["text_raw"] == nil, let text = dict["text"] as? String {
            dict["text_raw"] = HTMLText.plainText(text)
        }
        return JSONValue(dict)
    }

    private static func normalizeRetweeted(_ json: JSONValue) -> JSONValue {
        guard var dict = json.value as? [String: Any] else { return json }
        if dict["retweeted_status"] != nil { dict.removeValue(forKey: "retweeted_status") }
        return JSONValue(dict)
    }

    private static func collectMweiboStatuses(_ card: JSONValue) -> [JSONValue] {
        var result: [JSONValue] = []
        if let mblog = card["mblog"].object { result.append(mblog) }
        for group in card["card_group"].array {
            if let mblog = group["mblog"].object { result.append(mblog) }
            for sub in group["card_group"].array {
                if let mblog = sub["mblog"].object { result.append(mblog) }
            }
        }
        return result
    }
}

// MARK: - 小工具

private extension Array where Element == FeedUrlEntity {
    func filterNotMediaLink() -> [FeedUrlEntity] {
        filter { !$0.isMediaLink }
    }
}

extension JSONValue {
    func nonEmptyString(withKey key: String) -> String? {
        self[key].nonEmptyString
    }
}

extension String {
    func ranges(of pattern: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: self, range: NSRange(startIndex..., in: self))
        return matches.compactMap { Range($0.range, in: self) }
    }
}
