import Foundation

/// 微博正文是 HTML 片段，图片/表情用 `<img>`，短链用 `<a data-url>`。
/// 这一层负责把 HTML 还原成可排版的纯文本，并保留表情占位与短链锚点。
enum HTMLText {

    // MARK: - 实体解码

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": " ", "ensp": " ", "emsp": " ", "thinsp": " ",
        "zwj": "\u{200D}", "zwnj": "\u{200C}", "ldquo": "“", "rdquo": "”",
        "lsquo": "‘", "rsquo": "’", "hellip": "…", "mdash": "—", "ndash": "–",
        "middot": "·", "bull": "•", "copy": "©", "reg": "®", "trade": "™",
        "deg": "°", "times": "×", "divide": "÷", "plusmn": "±",
    ]

    static func decodeEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var result = ""
        result.reserveCapacity(input.count)
        var index = input.startIndex
        while index < input.endIndex {
            guard input[index] == "&",
                  let semicolon = input[index...].firstIndex(of: ";"),
                  input.distance(from: index, to: semicolon) <= 10 else {
                result.append(input[index])
                index = input.index(after: index)
                continue
            }
            let body = String(input[input.index(after: index)..<semicolon])
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let scalarValue: UInt32?
                if digits.first == "x" || digits.first == "X" {
                    scalarValue = UInt32(digits.dropFirst(), radix: 16)
                } else {
                    scalarValue = UInt32(digits)
                }
                if let scalarValue, let scalar = Unicode.Scalar(scalarValue) {
                    result.append(Character(scalar))
                    index = input.index(after: semicolon)
                    continue
                }
            } else if let entity = namedEntities[body.lowercased()] {
                result.append(entity)
                index = input.index(after: semicolon)
                continue
            }
            result.append(input[index])
            index = input.index(after: index)
        }
        return result
    }

    // MARK: - HTML → 纯文本

    private static let emoticonImageRegex = try! NSRegularExpression(
        pattern: #"<img\b[^>]*\balt\s*=\s*(["'])(\[[^\[\]]+\])\1[^>]*/?>"#,
        options: [.caseInsensitive]
    )

    private static let brRegex = try! NSRegularExpression(pattern: #"<br\s*/?>"#, options: [.caseInsensitive])
    private static let tagRegex = try! NSRegularExpression(pattern: #"<[^>]+>"#)

    /// 表情在 HTML 里是 `<img alt="[微笑]">`；必须在剥标签前还原成 `[微笑]`。
    static func plainText(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        var text = html

        text = replace(brRegex, in: text, with: "\n")

        let emoticonMatches = emoticonImageRegex.matches(
            in: text, range: NSRange(text.startIndex..., in: text)
        )
        if !emoticonMatches.isEmpty {
            var rebuilt = ""
            var cursor = text.startIndex
            for match in emoticonMatches {
                guard let full = Range(match.range, in: text),
                      let alt = Range(match.range(at: 2), in: text) else { continue }
                rebuilt += text[cursor..<full.lowerBound]
                rebuilt += text[alt]
                cursor = full.upperBound
            }
            rebuilt += text[cursor...]
            text = rebuilt
        }

        text = replace(tagRegex, in: text, with: "")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = decodeEntities(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    // MARK: - 短链还原

    private static let anchorRegex = try! NSRegularExpression(
        pattern: #"<a\b([^>]*)>(.*?)</a>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let dataUrlRegex = try! NSRegularExpression(
        pattern: #"\bdata-url\s*=\s*["']([^"']+)["']"#,
        options: [.caseInsensitive]
    )
    private static let hrefRegex = try! NSRegularExpression(
        pattern: #"\bhref\s*=\s*["']([^"']+)["']"#,
        options: [.caseInsensitive]
    )

    /// 把 `<a>` 锚点还原成 t.cn 短链，这样正文才能把链接渲染成可点文字。
    /// 话题/昵称锚点保留可见文案，否则首页会露出 s.weibo.com 脏链。
    static func expandAnchorsToShortURLs(_ html: String) -> String {
        guard html.range(of: "<a", options: .caseInsensitive) != nil else { return html }
        let matches = anchorRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        guard !matches.isEmpty else { return html }

        var result = ""
        var cursor = html.startIndex
        for match in matches {
            guard let full = Range(match.range, in: html),
                  let attrsRange = Range(match.range(at: 1), in: html),
                  let innerRange = Range(match.range(at: 2), in: html) else { continue }
            result += html[cursor..<full.lowerBound]
            cursor = full.upperBound

            let attrs = String(html[attrsRange])
            let inner = String(html[innerRange])
            let dataURL = firstGroup(dataUrlRegex, in: attrs)
            let href = firstGroup(hrefRegex, in: attrs)
            let candidate = normalizeURL(dataURL ?? href)

            if let candidate, isExpandableStatusLink(candidate) {
                result += " \(candidate) "
            } else {
                result += inner
            }
        }
        result += html[cursor...]
        return result
    }

    private static func firstGroup(_ regex: NSRegularExpression, in text: String) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func isExpandableStatusLink(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains("t.cn/") || lower.hasPrefix("sinaweibo://")
    }

    // MARK: - 媒体链接剥离

    /// 已有图片/视频卡片时，正文里对应的 `查看图片`、`网页链接` 等文字要清掉，
    /// 否则会出现「文字 + 空链接」的重复观感。
    static func stripOrphanMediaLinks(_ text: String) -> String {
        var result = text
        let patterns = [
            #"O?\s*网页链接"#,
            #"查看图片"#,
            #"图片评论"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern, with: "", options: [.regularExpression]
            )
        }
        return tidy(result)
    }

    static func stripOrphanMediaLinks(_ text: String, keeping preserved: Set<String>) -> String {
        var result = text
        for entity in preserved where !entity.isEmpty {
            // 保留的短链用占位符临时替换，避免被清理规则误伤。
            result = result.replacingOccurrences(of: entity, with: "\u{0001}\(entity)\u{0001}")
        }
        result = stripOrphanMediaLinks(result)
        return result.replacingOccurrences(of: "\u{0001}", with: "")
    }

    static func stripEntityTokens(_ text: String, _ tokens: [String]) -> String {
        var result = text
        for token in tokens where !token.isEmpty {
            result = result.replacingOccurrences(of: token, with: "")
        }
        return tidy(result)
    }

    /// 合并多余空白但不破坏段落换行。
    static func tidy(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: [.regularExpression])
        result = result.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: [.regularExpression])
        result = result.replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: [.regularExpression])
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: [.regularExpression])
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 表情

    private static let emoticonAltRegex = try! NSRegularExpression(
        pattern: #"<img\b[^>]*\balt\s*=\s*(["'])(\[[^\[\]]+\])\1[^>]*/?>"#,
        options: [.caseInsensitive]
    )

    /// 提取正文里出现的表情短语，配合表情接口可换成图片渲染。
    static func emoticonPhrases(in html: String) -> [String] {
        guard html.contains("<img") else { return [] }
        let matches = emoticonAltRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var phrases: [String] = []
        for match in matches {
            guard let range = Range(match.range(at: 2), in: html) else { continue }
            let phrase = String(html[range])
            if !phrases.contains(phrase) { phrases.append(phrase) }
        }
        return phrases
    }

    // MARK: - URL 规范化

    static func normalizeURL(_ url: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        if url.hasPrefix("//") { return "https:" + url }
        if url.hasPrefix("http://") && url.contains("sinaimg.cn") {
            return url.replacingOccurrences(of: "http://", with: "https://")
        }
        return url
    }

    // MARK: - 计数格式化

    /// 与网页端一致：10000 以上折算成「1.2万」。
    static func formatCount(_ value: JSONValue) -> String {
        guard let count = value.int64 else { return "0" }
        if count >= 10_000 {
            let formatted = String(format: "%.1f", Double(count) / 10_000.0)
            return formatted.hasSuffix(".0")
                ? String(formatted.dropLast(2)) + "万"
                : formatted + "万"
        }
        return String(count)
    }

    /// 对已经格式化过的字符串做 ±1，用于点赞/评论数即时变化。
    static func bumpCount(_ value: String, delta: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("万") {
            guard let base = Double(trimmed.dropLast()) else { return value }
            let updated = max(0, base * 10_000 + Double(delta))
            return formatCount(JSONValue(Int64(updated)))
        }
        guard let base = Int(trimmed) else { return value }
        return formatCount(JSONValue(max(0, base + delta)))
    }

    // MARK: - 认证图标

    static func parseVerification(_ user: JSONValue?) -> UserVerification? {
        guard let user, user.exists else { return nil }
        if user["verified"].exists && !user["verified"].bool { return nil }
        let type = user["verified_type"].int ?? -1
        let ext = user["verified_type_ext"].int ?? 0
        if type == 0 {
            switch ext {
            case 1: return .gold
            case 2: return .orange
            default: return .yellow
            }
        }
        if (1...7).contains(type) {
            if ext == -1 { return .grey }
            if type == 3 && ext == 53 { return .red }
            return .blue
        }
        return nil
    }

    // MARK: - 时间

    private static let weiboDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT+0800")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return formatter
    }()

    /// 微博时间戳形如 `Sat Nov 01 12:34:56 +0800 2026`。
    static func date(fromWeibo raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = weiboDateFormatter.date(from: raw) { return date }
        // 个别接口给的是 ISO8601 或 `2026-11-01 12:34:56`。
        if let date = ISO8601DateFormatter().date(from: raw) { return date }
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fallback.date(from: raw)
    }

    /// 列表里显示成「刚刚 / 3分钟前 / 昨天 12:30 / 11-01」。
    static func relativeTime(_ raw: String?) -> String {
        guard let date = date(fromWeibo: raw) else { return raw ?? "" }
        let now = Date()
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60))分钟前" }
        let calendar = Calendar(identifier: .gregorian)
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "昨天 HH:mm"
            return formatter.string(from: date)
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd"
            return formatter.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

extension String {
    /// 微博短链常带中文标点结尾，取链接时需要裁掉。
    func trimmingLinkTrailingPunctuation() -> String {
        var result = self
        let punctuation = CharacterSet(charactersIn: "。，！？；）】、,.!?;)\"]}'")
        while let last = result.unicodeScalars.last, punctuation.contains(last) {
            result.removeLast()
        }
        return result
    }
}
