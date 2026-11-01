import SwiftUI

/// 卡片向外抛出的交互，集中在一个枚举里，避免层层传十几个闭包。
enum FeedAction {
    case openDetail(FeedItem)
    case openUser(uid: String, name: String)
    case openImages([FeedImage], Int)
    case playVideo(FeedMedia)
    case openTopic(String)
    case openLink(String)
    case like(FeedItem)
    case favorite(FeedItem)
    case comment(FeedItem)
    case repost(FeedItem)
    case more(FeedItem)
    case openOriginalStatus(FeedItem)
}

struct FeedCard: View {
    let item: FeedItem
    var onAction: (FeedAction) -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    /// 列表里正文最多显示 8 行，点进详情看全文。
    var collapseText = true
    /// 详情页复用它时关掉整卡点击，避免重复入栈。
    var allowsNavigation = true

    private var accent: Color { settings.themeColor.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            if let retweeted = item.retweetedStatus {
                quotedCard(retweeted)
            }
            footer
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.vertical, 13)
        .cardSurface(scheme)
        .environment(\.openURL, OpenURLAction { url in
            handle(url)
            return .handled
        })
        .contentShape(Rectangle())
        .onTapGesture {
            guard allowsNavigation else { return }
            onAction(.openDetail(item))
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                onAction(.openUser(uid: item.authorID, name: item.authorName))
            } label: {
                AvatarView(url: item.authorAvatarURL, size: 40)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                if let badge = item.visibility?.shortBadge {
                    visibilityBadge(badge)
                }
                HStack(spacing: 4) {
                    Text(item.authorName)
                        .font(.system(size: settings.nameFontSize, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    VerificationBadge(verification: item.verification)
                    if item.isPinned {
                        Text("置顶")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(accent.opacity(0.12))
                            )
                            .foregroundStyle(accent)
                    }
                }
                HStack(spacing: 6) {
                    Text(HTMLText.relativeTime(item.createdAt))
                    if let source = item.source, !source.isEmpty {
                        Text(source).lineLimit(1)
                    }
                    if let ip = item.ipLocation, !ip.isEmpty {
                        Text("IP属地：\(ip)")
                    }
                    if item.isEdited {
                        Label("已编辑", systemImage: "pencil")
                            .labelStyle(.titleOnly)
                    }
                }
                .font(.system(size: settings.captionFontSize - 0.5))
                .foregroundStyle(Theme.tertiaryText(scheme))
                .lineLimit(1)
            }

            Spacer(minLength: 0)

            Menu {
                moreMenu
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText(scheme))
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
        }
    }

    private func visibilityBadge(_ text: String) -> some View {
        HStack(spacing: 3) {
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.separator(scheme).opacity(0.6))
        )
    }

    @ViewBuilder
    private var moreMenu: some View {
        Button {
            UIPasteboard.general.string = item.text
            Haptics.tap()
        } label: {
            Label("复制正文", systemImage: "doc.on.doc")
        }
        Button {
            onAction(.favorite(item))
        } label: {
            Label(item.favorited ? "取消收藏" : "收藏", systemImage: item.favorited ? "star.slash" : "star")
        }
        ShareLink(item: "https://m.weibo.cn/detail/\(item.detailKey)") {
            Label("分享链接", systemImage: "square.and.arrow.up")
        }
        Button {
            onAction(.openDetail(item))
        } label: {
            Label("查看详情", systemImage: "doc.text.magnifyingglass")
        }
    }

    // MARK: - 正文与媒体

    private var content: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !item.text.isEmpty {
                RichTextView(
                    text: item.text,
                    entities: item.urlEntities,
                    fontSize: settings.bodyFontSize,
                    lineSpacing: settings.lineSpacing,
                    linkColor: accent,
                    lineLimit: nil
                )
            }

            if let location = item.locationName, !location.isEmpty {
                Button {
                    if let url = item.locationURL { onAction(.openLink(url)) }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "mappin.circle.fill").font(.system(size: 11))
                        Text(location).font(.system(size: 12))
                    }
                    .foregroundStyle(Theme.secondaryText(scheme))
                }
                .buttonStyle(.plain)
            }

            if let poll = item.poll {
                PollCard(poll: poll, accent: accent)
            }

            if !item.images.isEmpty {
                ImageGridView(images: item.images, accent: accent) { index in
                    onAction(.openImages(item.images, index))
                }
            }

            if let media = item.media {
                InlineVideoCard(media: media) {
                    onAction(.playVideo(media))
                }
            }
        }
    }

    // MARK: - 转发引用

    private func quotedCard(_ original: FeedItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                AvatarView(url: original.authorAvatarURL, size: 20)
                Text(original.authorName)
                    .font(.system(size: settings.nameFontSize - 1.5, weight: .medium))
                    .foregroundStyle(Theme.secondaryText(scheme))
                    .lineLimit(1)
                VerificationBadge(verification: original.verification)
                Spacer(minLength: 0)
            }
            if !original.text.isEmpty {
                RichTextView(
                    text: original.text,
                    entities: original.urlEntities,
                    fontSize: settings.bodyFontSize - 1,
                    lineSpacing: settings.lineSpacing - 1,
                    textColor: Theme.secondaryText(scheme),
                    linkColor: accent,
                    lineLimit: 6
                )
            }
            if !original.images.isEmpty {
                ImageGridView(
                    images: Array(original.images.prefix(3)),
                    accent: accent,
                    compact: true
                ) { _ in
                    onAction(.openOriginalStatus(original))
                }
            }
            if let media = original.media {
                Button {
                    onAction(.openOriginalStatus(original))
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.circle.fill")
                        Text(media.title).lineLimit(1)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.quoteBackground(scheme))
        )
        .contentShape(Rectangle())
        .onTapGesture { onAction(.openOriginalStatus(original)) }
    }

    // MARK: - 操作栏

    private var footer: some View {
        HStack(spacing: 0) {
            actionButton(
                symbol: item.liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                count: item.likesCount,
                tint: item.liked ? accent : Theme.secondaryText(scheme)
            ) { onAction(.like(item)) }

            actionButton(
                symbol: "bubble.right",
                count: item.commentsCount,
                tint: Theme.secondaryText(scheme)
            ) { onAction(.comment(item)) }

            actionButton(
                symbol: "arrow.2.squarepath",
                count: item.repostsCount,
                tint: Theme.secondaryText(scheme)
            ) { onAction(.repost(item)) }

            Spacer(minLength: 0)

            Button {
                onAction(.favorite(item))
            } label: {
                Image(systemName: item.favorited ? "star.fill" : "star")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(item.favorited ? accent : Theme.secondaryText(scheme))
                    .frame(width: 34, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    private func actionButton(
        symbol: String,
        count: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                if count != "0" {
                    Text(count).font(.system(size: 12.5))
                }
            }
            .foregroundStyle(tint)
            .padding(.trailing, 26)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 链接分发

    private func handle(_ url: URL) {
        guard let parsed = TextLink.parse(url) else {
            if url.scheme == "http" || url.scheme == "https" {
                onAction(.openLink(url.absoluteString))
            }
            return
        }
        switch parsed.kind {
        case "user":
            let name = parsed.value.replacingOccurrences(of: "@", with: "")
            onAction(.openUser(uid: "", name: name))
        case "topic":
            onAction(.openTopic(parsed.value))
        case "link":
            onAction(.openLink(parsed.value))
        default:
            break
        }
    }
}

// MARK: - 图片九宫格

struct ImageGridView: View {
    let images: [FeedImage]
    var accent: Color = .accentColor
    var compact = false
    var onTap: (Int) -> Void

    private var columns: Int {
        switch images.count {
        case 1: return 1
        case 2, 4: return 2
        default: return 3
        }
    }

    private var totalWidth: CGFloat {
        UIScreen.main.bounds.width - 2 * 16 - 2 * Theme.horizontalPadding - (compact ? 20 : 0)
    }

    private var cellSize: CGFloat {
        let spacing: CGFloat = 5
        return (totalWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
    }

    var body: some View {
        if images.count == 1, let image = images.first {
            singleImage(image)
        } else {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(cellSize), spacing: 5), count: columns),
                spacing: 5
            ) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    Button {
                        onTap(index)
                    } label: {
                        RemoteImage(url: image.displayURL(preferLarge: false), maxPixelSize: cellSize * 3)
                            .frame(width: cellSize, height: cellSize)
                            .clipped()
                            .overlay(alignment: .bottomTrailing) {
                                if image.isGIF {
                                    Text("GIF")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 3)
                                        .padding(.vertical, 1)
                                        .background(Color.black.opacity(0.5))
                                        .padding(4)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: totalWidth, alignment: .leading)
        }
    }

    private func singleImage(_ image: FeedImage) -> some View {
        let maxHeight: CGFloat = compact ? 150 : 340
        let ratio: CGFloat = {
            guard let w = image.width, let h = image.height, w > 0, h > 0 else { return 4.0 / 3.0 }
            return CGFloat(w) / CGFloat(h)
        }()
        let width = compact ? min(totalWidth * 0.6, maxHeight * ratio) : min(totalWidth * 0.72, maxHeight * ratio)
        let height = min(width / ratio, maxHeight)

        return Button {
            onTap(0)
        } label: {
            RemoteImage(url: image.displayURL(preferLarge: false), maxPixelSize: max(width, height) * 2.5)
                .frame(width: width, height: height)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 视频卡片

struct InlineVideoCard: View {
    let media: FeedMedia
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RemoteImage(url: URL(string: media.coverURL ?? ""), maxPixelSize: 900)
                    .frame(height: coverHeight)
                    .frame(maxWidth: .infinity)
                    .clipped()

                LinearGradient(
                    colors: [.black.opacity(0.05), .black.opacity(0.38)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.3), radius: 8)

                VStack {
                    HStack {
                        if let badge = media.liveBadge {
                            Text(badge)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2.5)
                                .background(Capsule().fill(Color.red.opacity(0.85)))
                        }
                        Spacer()
                        if let duration = media.durationSeconds {
                            Text(Self.durationText(duration))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.black.opacity(0.45)))
                        }
                    }
                    Spacer()
                }
                .padding(9)
            }
            .frame(height: coverHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var coverHeight: CGFloat {
        let ratio = media.aspectRatio
        let width = UIScreen.main.bounds.width - 2 * 16 - 2 * Theme.horizontalPadding
        let height = width / max(ratio, 0.6)
        return min(max(height, 150), 420)
    }

    static func durationText(_ seconds: Int) -> String {
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - 投票

struct PollCard: View {
    let poll: FeedPoll
    var accent: Color

    @Environment(\.colorScheme) private var scheme

    private var totalVotes: Int64 {
        poll.options.compactMap { $0.count }.reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                Text(poll.isEnded ? "投票已结束" : "微博投票")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(accent)

            Text(poll.title)
                .font(.system(size: 14, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)

            ForEach(poll.options) { option in
                optionRow(option)
            }

            HStack(spacing: 6) {
                if let participants = poll.participantCount ?? (totalVotes > 0 ? totalVotes : nil) {
                    Text("\(HTMLText.formatCount(JSONValue(participants))) 人参与")
                }
                if poll.hasVoted {
                    Text("· 已投票")
                }
                Spacer(minLength: 0)
                if let end = poll.endTime, !end.isEmpty {
                    Text(end).lineLimit(1)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiaryText(scheme))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accent.opacity(0.05))
        )
    }

    private func optionRow(_ option: FeedPollOption) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(accent.opacity(option.selected ? 0.10 : 0.05))
                if let ratio = ratio(for: option) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(accent.opacity(option.selected ? 0.30 : 0.18))
                        .frame(width: max(proxy.size.width * ratio, 6))
                }
                HStack(spacing: 6) {
                    if option.selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(accent)
                    }
                    Text(option.text)
                        .font(.system(size: 13, weight: option.selected ? .medium : .regular))
                        .foregroundStyle(option.selected ? accent : Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let text = option.countText ?? option.count.map({ HTMLText.formatCount(JSONValue($0)) }) {
                        Text(text)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 9)
            }
        }
        .frame(height: 32)
    }

    private func ratio(for option: FeedPollOption) -> Double? {
        guard let count = option.count, totalVotes > 0 else { return nil }
        return Double(count) / Double(totalVotes)
    }
}

// MARK: - 轻触反馈

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
