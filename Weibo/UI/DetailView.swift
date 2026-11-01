import SwiftUI

@MainActor
final class DetailStore: ObservableObject {
    @Published private(set) var status: FeedItem?
    private(set) var comments: [CommentItem] = []
    @Published private(set) var reposts: [CommentItem] = []
    @Published private(set) var likeUsers: [MentionCandidate] = []

    @Published var isLoading = false
    @Published var isLoadingComments = false
    @Published var isLoadingMore = false
    @Published var isLoadingReposts = false
    @Published var errorMessage: String?
    @Published var commentsError: String?
    @Published var sort: CommentSort = .hot
    @Published var totalComments: Int?

    private var commentCursor: String?
    private var hasMoreComments = true
    private var repostPage = 1
    private var hasMoreReposts = true
    private var hasLoadedReposts = false

    private let session = WeiboSession.shared
    private let statusID: String

    init(statusID: String) {
        self.statusID = statusID
    }

    func load() async {
        guard !isLoading else { return }
        if DemoMode.isEnabled {
            let items = DemoData.timeline()
            status = items.first { $0.statusID == statusID || $0.id == statusID } ?? items.first
            comments = DemoData.comments()
            totalComments = comments.count
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            var item = try await session.loadStatusDetail(id: statusID)
            if let loaded = item, loaded.requiresLongTextFetch,
               let merged = await session.expandLongText(loaded) {
                item = merged
            }
            guard let resolved = item else {
                throw WeiboError.api("这条微博可能已被删除")
            }
            status = resolved
            isLoading = false
            await reloadComments()
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func reloadComments() async {
        guard let status else { return }
        isLoadingComments = true
        commentsError = nil
        do {
            let page = try await session.loadComments(item: status, sort: sort)
            comments = page.items
            commentCursor = page.nextCursor
            hasMoreComments = page.nextCursor != nil
            totalComments = page.totalCount
            if let total = page.totalCount {
                self.status?.commentsCount = HTMLText.formatCount(JSONValue(Int64(total)))
            }
        } catch {
            commentsError = error.localizedDescription
        }
        isLoadingComments = false
    }

    func loadMoreComments() async {
        guard let status, !isLoadingMore, hasMoreComments else { return }
        isLoadingMore = true
        do {
            if let cursor = commentCursor {
                let page = try await session.loadComments(item: status, sort: sort, cursor: cursor)
                let existing = Set(comments.map(\.id))
                let added = page.items.filter { !existing.contains($0.id) }
                comments.append(contentsOf: added)
                // 游标没前进或整页都是重复内容时直接收尾，避免反复请求同一页。
                if added.isEmpty || page.nextCursor == cursor {
                    hasMoreComments = false
                } else {
                    commentCursor = page.nextCursor
                    hasMoreComments = page.nextCursor != nil
                }
            } else {
                hasMoreComments = false
            }
        } catch {
            hasMoreComments = false
        }
        isLoadingMore = false
    }

    func switchSort(_ newSort: CommentSort) async {
        guard sort != newSort else { return }
        sort = newSort
        comments = []
        commentCursor = nil
        hasMoreComments = true
        await reloadComments()
    }

    func loadRepostsIfNeeded() async {
        guard !hasLoadedReposts, let status else { return }
        hasLoadedReposts = true
        await loadMoreReposts(status: status)
    }

    private func loadMoreReposts(status: FeedItem) async {
        guard !isLoadingReposts, hasMoreReposts else { return }
        isLoadingReposts = true
        do {
            let page = try await session.loadReposts(item: status, page: repostPage)
            let existing = Set(reposts.map(\.id))
            reposts.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            if let next = page.nextPage {
                repostPage = next
                hasMoreReposts = true
            } else {
                hasMoreReposts = false
            }
        } catch {
            hasMoreReposts = false
        }
        isLoadingReposts = false
    }

    func apply(_ updated: FeedItem) {
        guard updated.id == status?.id else { return }
        status = updated
    }

    func appendComment(_ comment: CommentItem) {
        comments.insert(comment, at: 0)
        if let count = status?.commentsCount {
            status?.commentsCount = HTMLText.bumpCount(count, delta: 1)
        }
    }
}

// MARK: - 详情页

struct DetailView: View {
    let statusID: String

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var scheme

    @StateObject private var store: DetailStore
    @State private var tab: DetailTab = .comments
    @State private var commentDraft = ""
    @State private var isSending = false
    @FocusState private var inputFocused: Bool

    init(statusID: String) {
        self.statusID = statusID
        _store = StateObject(wrappedValue: DetailStore(statusID: statusID))
    }

    private enum DetailTab: Hashable {
        case comments, reposts
    }

    private var accent: Color { settings.themeColor.color }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.pageBackground(scheme).ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: Theme.cardSpacing) {
                    if let status = store.status {
                        FeedCard(item: status, onAction: { action in
                            app.handle(action, in: .timeline)
                        }, allowsNavigation: false)
                            .onTapGesture { inputFocused = false }

                        tabBar
                        content(for: status)
                    } else if let error = store.errorMessage {
                        ErrorStateView(message: error) {
                            Task { await store.load() }
                        }
                        .padding(.top, 80)
                    } else {
                        LoadingStateView(text: "正在读取微博")
                            .padding(.top, 80)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 96)
            }
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await store.load() }

            inputBar
        }
        .navigationTitle("微博详情")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .onChange(of: app.feedUpdate) { _, update in
            guard let item = update?.item else { return }
            store.apply(item)
        }
    }

    // MARK: - 评论 / 转发切换

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(title: "评论", count: store.totalComments.map { "\($0)" } ?? store.status?.commentsCount, tab: .comments)
            tabButton(title: "转发", count: store.status?.repostsCount, tab: .reposts)
            Spacer(minLength: 0)
            if tab == .comments {
                Menu {
                    ForEach(CommentSort.allCases) { option in
                        Button {
                            Task { await store.switchSort(option) }
                        } label: {
                            if option == store.sort {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(store.sort.label)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(accent)
                }
            }
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.vertical, 12)
        .cardSurface(scheme)
    }

    private func tabButton(title: String, count: String?, tab target: DetailTab) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { tab = target }
            if target == .reposts {
                Task { await store.loadRepostsIfNeeded() }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: tab == target ? .semibold : .regular))
                if let count, count != "0" {
                    Text(count).font(.system(size: 12))
                }
            }
            .foregroundStyle(tab == target ? accent : Theme.secondaryText(scheme))
            .padding(.trailing, 22)
            .overlay(alignment: .bottom) {
                if tab == target {
                    Capsule()
                        .fill(accent)
                        .frame(height: 2.5)
                        .offset(y: 9)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 内容

    @ViewBuilder
    private func content(for status: FeedItem) -> some View {
        if tab == .comments {
            if store.isLoadingComments && store.comments.isEmpty {
                LoadMoreIndicator(text: "正在加载评论")
                    .cardSurface(scheme)
            } else if let error = store.commentsError, store.comments.isEmpty {
                ErrorStateView(message: error) {
                    Task { await store.reloadComments() }
                }
                .cardSurface(scheme)
            } else if store.comments.isEmpty {
                EmptyStateView(symbol: "bubble.right", title: "还没有评论", message: "来说点什么吧")
                    .cardSurface(scheme)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.comments) { comment in
                        CommentRow(
                            comment: comment,
                            isAuthor: comment.authorID == status.authorID,
                            onLike: { Task { await like(comment) } },
                            onReply: {
                                guard app.requireLogin() else { return }
                                app.compose = ComposeState(mode: .comment(status, replyTo: comment))
                            },
                            onUserTap: {
                                app.handle(.openUser(uid: comment.authorID, name: comment.authorName), in: .timeline)
                            }
                        )
                        .onAppear {
                            if comment.id == store.comments.last?.id {
                                Task { await store.loadMoreComments() }
                            }
                        }
                        Divider()
                            .overlay(Theme.separator(scheme))
                            .padding(.leading, Theme.horizontalPadding + 44)
                    }
                    if store.isLoadingMore {
                        LoadMoreIndicator()
                    }
                }
                .cardSurface(scheme)
            }
        } else {
            if store.isLoadingReposts && store.reposts.isEmpty {
                LoadMoreIndicator(text: "正在加载转发")
                    .cardSurface(scheme)
            } else if store.reposts.isEmpty {
                EmptyStateView(symbol: "arrow.2.squarepath", title: "还没有转发")
                    .cardSurface(scheme)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.reposts) { repost in
                        CommentRow(
                            comment: repost,
                            isAuthor: repost.authorID == status.authorID,
                            showLike: false,
                            onLike: {},
                            onReply: nil,
                            onUserTap: {
                                app.handle(.openUser(uid: repost.authorID, name: repost.authorName), in: .timeline)
                            }
                        )
                        Divider()
                            .overlay(Theme.separator(scheme))
                            .padding(.leading, Theme.horizontalPadding + 44)
                    }
                }
                .cardSurface(scheme)
            }
        }
    }

    // MARK: - 底部输入

    private var inputBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.tertiaryText(scheme))
                TextField("写评论…", text: $commentDraft, axis: .vertical)
                    .font(.system(size: 14))
                    .focused($inputFocused)
                    .lineLimit(1...4)
                    .submitLabel(.send)
                    .onSubmit { Task { await sendComment() } }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(Theme.quoteBackground(scheme))
                    .overlay(Capsule().strokeBorder(Theme.separator(scheme), lineWidth: 0.8))
            )

            if !commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    Task { await sendComment() }
                } label: {
                    Group {
                        if isSending {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 13, weight: .bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(accent))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
        .animation(.snappy(duration: 0.2), value: commentDraft.isEmpty)
    }

    private func sendComment() async {
        guard let status = store.status else { return }
        let text = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, app.requireLogin() else { return }
        isSending = true
        do {
            try await WeiboSession.shared.postComment(to: status, text: text)
            commentDraft = ""
            inputFocused = false
            Haptics.success()
            app.showToast("评论已发布")
            await store.reloadComments()
        } catch {
            app.showError(error)
        }
        isSending = false
    }

    private func like(_ comment: CommentItem) async {
        // 评论点赞接口与微博不同，这里只做本地计数反馈并提示。
        app.showToast("评论点赞暂未开放", symbol: "info.circle")
    }
}

// MARK: - 评论行

struct CommentRow: View {
    let comment: CommentItem
    var isAuthor: Bool
    var showLike = true
    var onLike: () -> Void
    var onReply: (() -> Void)?
    var onUserTap: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    private var accent: Color { settings.themeColor.color }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onUserTap) {
                AvatarView(url: comment.authorAvatarURL, size: 32)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(comment.authorName)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.secondaryText(scheme))
                        .lineLimit(1)
                    VerificationBadge(verification: comment.verification)
                    if isAuthor {
                        Text("博主")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(accent.opacity(0.12))
                            )
                    }
                    Spacer(minLength: 0)
                    if showLike && settings.showCommentLikes && comment.hasLikes {
                        Button(action: onLike) {
                            HStack(spacing: 3) {
                                Image(systemName: "hand.thumbsup")
                                    .font(.system(size: 11))
                                Text(comment.likesCount).font(.system(size: 11))
                            }
                            .foregroundStyle(Theme.tertiaryText(scheme))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let replyTo = comment.replyToAuthor, !replyTo.isEmpty {
                    Text("回复 @\(replyTo)：")
                        .font(.system(size: 13))
                        .foregroundStyle(accent.opacity(0.9))
                }

                RichTextView(
                    text: comment.text,
                    entities: comment.urlEntities,
                    fontSize: settings.bodyFontSize - 1.5,
                    lineSpacing: max(settings.lineSpacing - 1, 2),
                    linkColor: accent
                )

                if !comment.images.isEmpty {
                    ImageGridView(images: comment.images, accent: accent, compact: true) { _ in }
                        .frame(maxWidth: 200, alignment: .leading)
                }

                HStack(spacing: 10) {
                    Text(HTMLText.relativeTime(comment.createdAt))
                    if let ip = comment.ipLocation, !ip.isEmpty {
                        Text(ip)
                    }
                    if let onReply {
                        Button("回复", action: onReply)
                            .foregroundStyle(accent.opacity(0.9))
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)

                if !comment.comments.isEmpty {
                    nestedComments
                }
            }
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.vertical, 12)
        .environment(\.openURL, OpenURLAction { url in
            if let parsed = TextLink.parse(url) {
                switch parsed.kind {
                case "user":
                    onUserTap()
                case "topic":
                    // 话题在评论里点击时交给外层导航处理。
                    NotificationCenter.default.post(name: .weiboOpenTopic, object: parsed.value)
                case "link":
                    NotificationCenter.default.post(name: .weiboOpenLink, object: parsed.value)
                default:
                    break
                }
                return .handled
            }
            return .systemAction
        })
    }

    private var nestedComments: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(comment.comments.prefix(3)) { reply in
                HStack(alignment: .top, spacing: 5) {
                    Text(reply.authorName + "：")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.secondaryText(scheme))
                    RichTextView(
                        text: reply.text,
                        fontSize: settings.bodyFontSize - 3,
                        lineSpacing: 2,
                        linkColor: accent
                    )
                }
            }
            if comment.comments.count > 3 {
                Text("共 \(comment.comments.count) 条回复")
                    .font(.system(size: 11.5))
                    .foregroundStyle(accent)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.quoteBackground(scheme))
        )
    }
}

extension Notification.Name {
    static let weiboOpenTopic = Notification.Name("weibo.openTopic")
    static let weiboOpenLink = Notification.Name("weibo.openLink")
}
