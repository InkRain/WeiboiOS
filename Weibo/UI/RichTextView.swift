import SwiftUI

/// 正文富文本：把 @昵称、#话题#、http 链接渲染成可点文字。
/// 点击不直接打开网页，而是转成自定义 scheme 交给页面决定后续跳转。
enum TextLink {
    static let scheme = "weibox"

    static func user(_ name: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "user"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }

    static func topic(_ keyword: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "topic"
        components.queryItems = [URLQueryItem(name: "q", value: keyword)]
        return components.url
    }

    static func link(_ url: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "link"
        components.queryItems = [URLQueryItem(name: "u", value: url)]
        return components.url
    }

    static func parse(_ url: URL) -> (kind: String, value: String)? {
        guard url.scheme == scheme, let host = url.host else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let value = components?.queryItems?.first?.value ?? ""
        return value.isEmpty ? nil : (host, value)
    }
}

struct RichTextView: View {
    let text: String
    var entities: [FeedUrlEntity] = []
    var fontSize: CGFloat = 16
    var lineSpacing: CGFloat = 4
    var textColor: Color = .primary
    var linkColor: Color = .accentColor
    /// 超过这个行数时折叠（列表页正文限行，详情页不限）。
    var lineLimit: Int?

    @State private var expanded = false

    private var attributed: AttributedString {
        Self.build(text: text, linkColor: linkColor)
    }

    private var visibleEntities: [FeedUrlEntity] {
        entities.filter { !text.contains($0.shortURL) && !$0.title.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(attributed)
                .font(.system(size: fontSize))
                .lineSpacing(lineSpacing)
                .foregroundStyle(textColor)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)

            if !visibleEntities.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(visibleEntities) { entity in
                        Link(destination: TextLink.link(entity.url) ?? URL(string: "https://weibo.com")!) {
                            HStack(spacing: 5) {
                                Image(systemName: entity.isMediaLink ? "play.rectangle.fill" : "link")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(entity.title)
                                    .font(.system(size: fontSize - 2))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(linkColor)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(linkColor.opacity(0.08))
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - 富文本构建

    private struct Match {
        var range: Range<String.Index>
        var url: URL
    }

    private static let userRegex = try! NSRegularExpression(pattern: #"@[\w\u4e00-\u9fa5\-]{1,30}"#)
    private static let topicRegex = try! NSRegularExpression(pattern: #"#[^#\n]{1,40}#"#)
    private static let urlRegex = try! NSRegularExpression(pattern: #"https?://[^\s<>"'\[\]\u4e00-\u9fa5，。！？；（）【】]+"#)

    static func build(text: String, linkColor: Color) -> AttributedString {
        guard !text.isEmpty else { return AttributedString() }
        let nsText = text as NSString
        var matches: [Match] = []

        func collect(_ regex: NSRegularExpression, makeURL: (String) -> URL?) {
            for result in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                guard let range = Range(result.range, in: text) else { continue }
                let token = String(text[range])
                guard let url = makeURL(token) else { continue }
                // 已被更早的规则占用（例如链接里的 @）就跳过。
                if matches.contains(where: { $0.range.overlaps(range) }) { continue }
                matches.append(Match(range: range, url: url))
            }
        }

        collect(urlRegex) { token in
            TextLink.link(token.trimmingLinkTrailingPunctuation())
        }
        collect(userRegex) { TextLink.user($0) }
        collect(topicRegex) { TextLink.topic($0) }

        guard !matches.isEmpty else { return AttributedString(text) }

        matches.sort { $0.range.lowerBound < $1.range.lowerBound }
        var result = AttributedString()
        var cursor = text.startIndex
        for match in matches {
            guard match.range.lowerBound >= cursor else { continue }
            result += AttributedString(String(text[cursor..<match.range.lowerBound]))
            var piece = AttributedString(String(text[match.range]))
            piece.link = match.url
            piece.foregroundColor = linkColor
            result += piece
            cursor = match.range.upperBound
        }
        result += AttributedString(String(text[cursor...]))
        return result
    }
}
