import Foundation

enum SearchParser {

    static func parseHotSearch(_ raw: String) throws -> [HotSearchItem] {
        let root = try JSONValue.parse(raw)
        let list = root["data"]["realtime"].array
        return list.compactMap { item in
            if item["is_ad"].int == 1 { return nil }
            guard let word = item["word"].nonEmptyString else { return nil }
            let label = item.firstString("labelName", "iconDesc", "small_icon_desc", "icon_desc") ?? ""
            return HotSearchItem(word: word, label: label, heat: item["num"].int64 ?? 0)
        }
    }

    static func parseSuggest(_ raw: String) throws -> SearchSuggestResult {
        let root = try JSONValue.parse(raw)
        guard let data = root["data"].object else { return SearchSuggestResult() }
        let hotQueries: [String] = data["hotquery"].array.compactMap { $0["suggestion"].nonEmptyString }
        var users: [SearchUserItem] = []
        for user in data["users"].array {
            guard let id = user.firstString("idstr", "id") else { continue }
            users.append(
                SearchUserItem(
                    id: id,
                    screenName: user.firstString("screen_name", "name") ?? "",
                    avatarURL: user.firstString("avatar_large", "profile_image_url"),
                    description: HTMLText.plainText(user["description"].string ?? ""),
                    followersCount: user.firstString("followers_count_str") ?? HTMLText.formatCount(user["followers_count"]),
                    verification: HTMLText.parseVerification(user)
                )
            )
        }
        if users.isEmpty, let single = data["user"].object, let id = single.firstString("idstr", "id") {
            users.append(
                SearchUserItem(
                    id: id,
                    screenName: single.firstString("screen_name", "name") ?? "",
                    avatarURL: single.firstString("avatar_large", "profile_image_url"),
                    description: HTMLText.plainText(single["description"].string ?? ""),
                    followersCount: single.firstString("followers_count_str") ?? HTMLText.formatCount(single["followers_count"]),
                    verification: HTMLText.parseVerification(single)
                )
            )
        }
        return SearchSuggestResult(hotQueries: hotQueries, users: users)
    }

    /// m.weibo.cn 的用户搜索结果同样是卡片结构，只是 mblog 换成 user。
    static func parseMweiboUsers(_ raw: String, page: Int) throws -> SearchUserPage {
        let root = try JSONValue.parse(raw)
        guard root["ok"].int != 0 || root["data"].exists else {
            throw WeiboError.api(root.firstString("msg", "message") ?? "用户搜索失败")
        }
        let cards = root["data"]["cards"].array
        var users: [SearchUserItem] = []
        var seen = Set<String>()

        func append(_ user: JSONValue) {
            guard let id = user.firstString("idstr", "id"), seen.insert(id).inserted else { return }
            users.append(
                SearchUserItem(
                    id: id,
                    screenName: user.firstString("screen_name", "name") ?? "微博用户",
                    avatarURL: user.firstString("avatar_hd", "avatar_large", "profile_image_url"),
                    description: HTMLText.plainText(user["description"].string ?? ""),
                    followersCount: user.firstString("followers_count_str") ?? HTMLText.formatCount(user["followers_count"]),
                    verification: HTMLText.parseVerification(user)
                )
            )
        }

        for card in cards {
            if let user = card["user"].object { append(user) }
            for group in card["card_group"].array {
                if let user = group["user"].object { append(user) }
                for sub in group["card_group"].array {
                    if let user = sub["user"].object { append(user) }
                }
            }
        }

        let info = root["data"]["cardlistInfo"]
        let total = info["total"].int ?? 0
        let currentPage = info["page"].int ?? page
        let nextCursor = total > currentPage * 10 ? String(currentPage + 1) : nil
        return SearchUserPage(items: users, nextCursor: nextCursor)
    }
}
