import SwiftUI

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profile: UserProfile?
    @Published private(set) var posts: [FeedItem] = []
    @Published private(set) var likedPosts: [FeedItem] = []
    @Published private(set) var albumImages: [FeedImage] = []

    @Published var isLoading = false
    @Published var isLoadingPosts = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?
    @Published var isFollowing = false
    @Published var isUpdatingFollow = false

    private var postPage = 1
    private var hasMorePosts = true
    private var likedPage = 1
    private var hasMoreLiked = true
    private var likedLoaded = false
    private var albumCursor: String?
    private var albumLoaded = false
    private var hasMoreAlbum = true

    private let session = WeiboSession.shared
    private var resolvedUID: String

    init(uid: String, name: String) {
        resolvedUID = uid
        pendingName = name
    }

    private var pendingName: String = ""

    var uid: String { resolvedUID }

    func load() async {
        guard !isLoading else { return }
        if DemoMode.isEnabled {
            profile = DemoData.profile()
            posts = DemoData.timeline()
            albumImages = DemoData.timeline().flatMap(\.images)
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            if resolvedUID.isEmpty {
                try await resolveUID()
            }
            let loaded = try await session.loadProfile(uid: resolvedUID)
            profile = loaded
            isFollowing = loaded.following
            isLoading = false
            await loadPosts()
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// 从 `@昵称` 进入时只有名字，需要先换成 UID。
    private func resolveUID() async throws {
        guard !pendingName.isEmpty else { throw WeiboError.api("缺少用户标识") }
        _ = try? await session.loadSearchSuggest(pendingName)
        let page = try await session.searchUsers(pendingName, page: 1)
        if let matched = page.items.first(where: { $0.screenName == pendingName }) ?? page.items.first {
            resolvedUID = matched.id
        } else {
            throw WeiboError.api("没有找到用户「\(pendingName)」")
        }
    }

    func loadPosts() async {
        guard !resolvedUID.isEmpty else { return }
        isLoadingPosts = true
        do {
            let page = try await session.loadUserTimeline(uid: resolvedUID, page: 1)
            posts = page.items
            postPage = 2
            hasMorePosts = page.nextCursor != nil
        } catch {
            if posts.isEmpty { errorMessage = error.localizedDescription }
        }
        isLoadingPosts = false
    }

    func loadMorePosts() async {
        guard !isLoadingMore, hasMorePosts, !resolvedUID.isEmpty else { return }
        isLoadingMore = true
        do {
            let page = try await session.loadUserTimeline(uid: resolvedUID, page: postPage)
            let existing = Set(posts.map(\.id))
            let fresh = page.items.filter { !existing.contains($0.id) }
            posts.append(contentsOf: fresh)
            if page.nextCursor == nil || fresh.isEmpty { hasMorePosts = false }
            postPage += 1
        } catch {
            hasMorePosts = false
        }
        isLoadingMore = false
    }

    func loadLikedIfNeeded() async {
        guard !likedLoaded, !resolvedUID.isEmpty else { return }
        likedLoaded = true
        await loadMoreLiked(reset: true)
    }

    func loadMoreLiked(reset: Bool = false) async {
        if reset {
            likedPage = 1
            hasMoreLiked = true
            likedPosts = []
        }
        guard hasMoreLiked, !isLoadingMore else { return }
        isLoadingMore = true
        do {
            let page = try await session.searchUserLiked(uid: resolvedUID, page: likedPage)
            let existing = Set(likedPosts.map(\.id))
            let added = page.items.filter { !existing.contains($0.id) }
            likedPosts.append(contentsOf: added)
            if added.isEmpty { hasMoreLiked = false }
            likedPage += 1
        } catch {
            hasMoreLiked = false
        }
        isLoadingMore = false
    }

    func loadAlbumIfNeeded() async {
        guard !albumLoaded, !resolvedUID.isEmpty else { return }
        albumLoaded = true
        await loadMoreAlbum()
    }

    func loadMoreAlbum() async {
        guard hasMoreAlbum, !isLoadingMore, !resolvedUID.isEmpty else { return }
        isLoadingMore = true
        let previous = albumCursor
        do {
            let page = try await session.loadAlbum(uid: resolvedUID, cursor: albumCursor)
            let existing = Set(albumImages.map(\.id))
            let added = page.images.filter { !existing.contains($0.id) }
            albumImages.append(contentsOf: added)
            // 游标不前进或整页重复时收尾，否则相册会无限请求同一页。
            if added.isEmpty || page.nextCursor == previous || page.nextCursor == nil {
                hasMoreAlbum = false
            }
            albumCursor = page.nextCursor
        } catch {
            hasMoreAlbum = false
        }
        isLoadingMore = false
    }

    func toggleFollow() async throws {
        guard var updated = profile else { return }
        isUpdatingFollow = true
        defer { isUpdatingFollow = false }
        try await session.setFollowing(uid: resolvedUID, follow: !isFollowing)
        isFollowing.toggle()
        updated.following = isFollowing
        profile = updated
    }

    func apply(_ item: FeedItem) {
        if let index = posts.firstIndex(where: { $0.id == item.id }) { posts[index] = item }
        if let index = likedPosts.firstIndex(where: { $0.id == item.id }) { likedPosts[index] = item }
    }

    func remove(id: String) {
        posts.removeAll { $0.id == id }
        likedPosts.removeAll { $0.id == id }
    }

    /// 「视频」页用已加载微博里的视频条目，避免额外的瀑布流接口。
    var videoPosts: [FeedItem] {
        posts.filter { !$0.medias.isEmpty }
    }
}

// MARK: - 个人主页

struct ProfileView: View {
    let uid: String
    let name: String

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var scheme

    @StateObject private var store: ProfileStore
    @State private var tab: ProfileTab = .posts
    @State private var isHeaderExpanded = false

    init(uid: String, name: String) {
        self.uid = uid
        self.name = name
        _store = StateObject(wrappedValue: ProfileStore(uid: uid, name: name))
    }

    private enum ProfileTab: String, CaseIterable, Identifiable {
        case posts = "微博"
        case album = "相册"
        case video = "视频"
        case liked = "赞过"

        var id: String { rawValue }
    }

    private var accent: Color { settings.themeColor.color }
    private var isSelf: Bool { app.currentUser?.id == store.uid && !store.uid.isEmpty }

    var body: some View {
        ZStack {
            Theme.pageBackground(scheme).ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: Theme.cardSpacing, pinnedViews: [.sectionHeaders]) {
                    header

                    Section {
                        tabContent
                    } header: {
                        tabBar
                    }
                }
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .refreshable { await store.load() }

            if store.isLoading && store.profile == nil {
                LoadingStateView(text: "正在读取主页").padding(.top, 80)
            } else if let error = store.errorMessage, store.profile == nil {
                ErrorStateView(message: error) { Task { await store.load() } }
                    .padding(.top, 80)
            }
        }
        .navigationTitle(store.profile?.screenName ?? name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .onChange(of: app.feedUpdate) { _, update in
            guard let update else { return }
            if let item = update.item { store.apply(item) }
            if let id = update.deletedID { store.remove(id: id) }
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: URL(string: store.profile?.coverURL ?? ""), maxPixelSize: 1200)
                    .frame(height: 128)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.35)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                    }

                AvatarView(url: store.profile?.avatarURL, size: 76)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                    .offset(x: 16, y: 34)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(store.profile?.screenName ?? name)
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(isHeaderExpanded ? 3 : 1)
                    VerificationBadge(verification: store.profile?.verification)
                    Spacer(minLength: 0)
                    followButton
                }
                .padding(.top, 42)

                if let reason = store.profile?.verifiedReason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let description = store.profile?.description, !description.isEmpty {
                    RichTextView(
                        text: description,
                        fontSize: settings.bodyFontSize - 2,
                        lineSpacing: 2,
                        textColor: Theme.secondaryText(scheme),
                        linkColor: accent,
                        lineLimit: isHeaderExpanded ? nil : 3
                    )
                    .onTapGesture { isHeaderExpanded.toggle() }
                }

                if let profile = store.profile {
                    HStack(spacing: 6) {
                        if let location = profile.location, !location.isEmpty {
                            Label(location, systemImage: "mappin")
                        }
                        if let ip = profile.ipLocation, !ip.isEmpty {
                            Text("IP属地：\(ip)")
                        }
                        if let gender = profile.gender, !gender.isEmpty {
                            Image(systemName: gender.lowercased() == "f" ? "figure.dress.line.vertical.figure" : "figure.stand")
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .labelStyle(.titleAndIcon)

                    HStack(spacing: 18) {
                        countItem(profile.statusesCount, "微博")
                        countItem(profile.followingCount, "关注")
                        countItem(profile.followersCount, "粉丝")
                        if let photos = profile.photosCount {
                            countItem(photos, "照片")
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .cardSurface(scheme, radius: 0)
    }

    private func countItem(_ value: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(value).font(.system(size: 14, weight: .semibold))
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var followButton: some View {
        if isSelf {
            Button {
                Task { await app.refreshProfile() }
            } label: {
                Text("刷新资料")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.secondaryText(scheme))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().strokeBorder(Theme.separator(scheme), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        } else if store.profile != nil {
            Button {
                guard app.requireLogin() else { return }
                Task {
                    do {
                        try await store.toggleFollow()
                        Haptics.success()
                        app.showToast(store.isFollowing ? "已关注" : "已取消关注")
                    } catch {
                        app.showError(error)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    if store.isUpdatingFollow {
                        ProgressView().controlSize(.mini).tint(.white)
                    }
                    Text(store.isFollowing ? "已关注" : "关注")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(store.isFollowing ? Theme.secondaryText(scheme) : .white)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background {
                    if store.isFollowing {
                        Capsule().strokeBorder(Theme.separator(scheme), lineWidth: 1)
                    } else {
                        Capsule().fill(accent)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 标签栏

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(ProfileTab.allCases) { item in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { tab = item }
                    switch item {
                    case .album: Task { await store.loadAlbumIfNeeded() }
                    case .liked: Task { await store.loadLikedIfNeeded() }
                    default: break
                    }
                } label: {
                    VStack(spacing: 5) {
                        Text(item.rawValue)
                            .font(.system(size: 13.5, weight: tab == item ? .semibold : .regular))
                            .foregroundStyle(tab == item ? .primary : Theme.secondaryText(scheme))
                        Capsule()
                            .fill(tab == item ? accent : .clear)
                            .frame(width: 18, height: 2.5)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background {
            Theme.cardBackground(scheme)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Theme.separator(scheme))
                        .frame(height: 0.5)
                }
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .posts:
            feedList(store.posts, isLoading: store.isLoadingPosts) {
                if store.posts.last?.id == $0.id { Task { await store.loadMorePosts() } }
            }
        case .liked:
            feedList(store.likedPosts, isLoading: store.isLoadingMore) {
                if store.likedPosts.last?.id == $0.id { Task { await store.loadMoreLiked() } }
            }
        case .album:
            albumGrid
        case .video:
            videoGrid
        }
    }

    @ViewBuilder
    private func feedList(
        _ items: [FeedItem],
        isLoading: Bool,
        onAppearLast: @escaping (FeedItem) -> Void
    ) -> some View {
        if items.isEmpty && isLoading {
            LoadingStateView()
        } else if items.isEmpty {
            EmptyStateView(symbol: "text.bubble", title: "暂无内容", message: "可能受隐私设置限制")
        } else {
            ForEach(items) { item in
                FeedCard(item: item) { action in
                    app.handle(action, in: .profile)
                }
                .padding(.horizontal, 16)
                .onAppear { onAppearLast(item) }
            }
            if store.isLoadingMore {
                LoadMoreIndicator()
            }
        }
    }

    private var albumGrid: some View {
        Group {
            if store.albumImages.isEmpty && store.isLoadingMore {
                LoadingStateView()
            } else if store.albumImages.isEmpty {
                EmptyStateView(symbol: "photo.on.rectangle", title: "还没有照片")
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3),
                    spacing: 3
                ) {
                    ForEach(Array(store.albumImages.enumerated()), id: \.offset) { index, image in
                        Button {
                            app.imageBrowser = ImageBrowserState(
                                images: store.albumImages,
                                index: index,
                                statusID: image.statusID
                            )
                        } label: {
                            RemoteImage(url: image.displayURL(preferLarge: false), maxPixelSize: 400)
                                .aspectRatio(1, contentMode: .fill)
                                .clipped()
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if index == store.albumImages.count - 1 {
                                Task { await store.loadMoreAlbum() }
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var videoGrid: some View {
        Group {
            if store.videoPosts.isEmpty {
                EmptyStateView(symbol: "play.rectangle", title: "还没有视频", message: "这里展示已加载微博中的视频")
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 2),
                    spacing: 4
                ) {
                    ForEach(store.videoPosts) { item in
                        if let media = item.media {
                            Button {
                                app.videoToPlay = media
                            } label: {
                                ZStack {
                                    RemoteImage(url: URL(string: media.coverURL ?? ""), maxPixelSize: 500)
                                        .aspectRatio(4.0 / 3.0, contentMode: .fill)
                                        .clipped()
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 30, weight: .light))
                                        .foregroundStyle(.white.opacity(0.9))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }
}

// MARK: - 「我的」页

struct MyProfileView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var scheme

    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: Binding(
            get: { app.profilePath },
            set: { app.profilePath = $0 }
        )) {
            Group {
                if let uid = app.currentUser?.id, !uid.isEmpty {
                    ProfileView(uid: uid, name: app.currentUser?.screenName ?? "")
                        .navigationBarTitleDisplayMode(.inline)
                } else {
                    notLoggedInView
                }
            }
            .navigationDestination(for: Route.self) { RouteView(route: $0, tab: .profile) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    private var notLoggedInView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有登录微博")
                .font(.headline)
            Text("登录后即可查看信息流、发表微博和管理账号")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                app.showLoginSheet = true
            } label: {
                Text("登录微博")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 34)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(settings.themeColor.color))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.pageBackground(scheme).ignoresSafeArea())
    }
}
