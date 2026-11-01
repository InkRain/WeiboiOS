import SwiftUI

// MARK: - 路由分发

struct RouteView: View {
    let route: Route
    let tab: AppTab

    var body: some View {
        switch route {
        case let .detail(id, _):
            DetailView(statusID: id)
        case let .user(uid, name):
            ProfileView(uid: uid, name: name)
        case let .topic(keyword):
            TopicView(keyword: keyword)
        case let .searchResults(query, isUser):
            TopicView(keyword: query)
                .onAppear { _ = isUser }
        }
    }
}

// MARK: - 根视图

struct RootView: View {
    @StateObject private var app = AppModel()
    @State private var tab: RootTab = .timeline
    @State private var debugSheet: DebugSheet?

    private enum RootTab: Hashable {
        case timeline, message, search, profile
    }

    /// 仅调试截图用：`-screen settings|channels|images` 直接弹出对应面板。
    private enum DebugSheet: String, Identifiable {
        case settings, channels, images
        var id: String { rawValue }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.pageBackground(.light).ignoresSafeArea()

            TabView(selection: $tab) {
                NavigationStack(path: Binding(
                    get: { app.timelinePath },
                    set: { app.timelinePath = $0 }
                )) {
                    TimelineView(kind: app.settings.timelineChannel)
                        .navigationDestination(for: Route.self) { RouteView(route: $0, tab: .timeline) }
                        .toolbar(.hidden, for: .tabBar)
                }
                .tag(RootTab.timeline)

                NavigationStack {
                    MessagesTabView()
                        .toolbar(.hidden, for: .tabBar)
                }
                .tag(RootTab.message)

                SearchView()
                    .toolbar(.hidden, for: .tabBar)
                    .tag(RootTab.search)

                MyProfileView()
                    .toolbar(.hidden, for: .tabBar)
                    .tag(RootTab.profile)
            }
            .tint(app.settings.themeColor.color)

            if isTabBarVisible {
                bottomBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let toast = app.toast {
                ToastOverlay(toast: toast)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
                    .zIndex(10)
            }

            if app.isBootstrapping {
                ZStack {
                    Theme.pageBackground(.light).ignoresSafeArea()
                    VStack(spacing: 14) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 38))
                            .foregroundStyle(app.settings.themeColor.color)
                        ProgressView()
                    }
                }
                .transition(.opacity)
            }
        }
        .environmentObject(app)
        .environmentObject(app.settings)
        .preferredColorScheme(app.settings.appearance.colorScheme)
        .task {
            await app.bootstrap()
            openDebugScreenIfNeeded()
        }
        .onChange(of: app.settings.timelineChannel) { _, _ in
            // 频道变化后让首页重建。
            app.timelinePath = []
        }
        .onReceive(NotificationCenter.default.publisher(for: .weiboOpenTopic)) { note in
            guard let keyword = note.object as? String else { return }
            app.handle(.openTopic(keyword), in: .timeline)
        }
        .onReceive(NotificationCenter.default.publisher(for: .weiboOpenLink)) { note in
            guard let url = note.object as? String else { return }
            app.handle(.openLink(url), in: .timeline)
        }
        // 大图
        .sheet(item: Binding(
            get: { app.imageBrowser },
            set: { app.imageBrowser = $0 }
        )) { state in
            ImageBrowserView(state: state)
                .environmentObject(app.settings)
        }
        // 视频
        .sheet(item: Binding(
            get: { app.videoToPlay },
            set: { app.videoToPlay = $0 }
        )) { media in
            VideoPlayerView(media: media)
                .environmentObject(app.settings)
        }
        // 发布
        .sheet(item: Binding(
            get: { app.compose },
            set: { app.compose = $0 }
        )) { state in
            ComposeView(mode: state.mode)
                .environmentObject(app)
                .environmentObject(app.settings)
        }
        // 网页登录
        .sheet(isPresented: Binding(
            get: { app.showLoginSheet },
            set: { app.showLoginSheet = $0 }
        )) {
            LoginWebView {
                Task { await app.completeLogin() }
            }
            .environmentObject(app)
        }
        // 站内打开外部链接
        .sheet(isPresented: Binding(
            get: { app.externalLink != nil },
            set: { if !$0 { app.externalLink = nil } }
        )) {
            if let link = app.externalLink, let url = URL(string: link) {
                SafariView(url: url)
                    .ignoresSafeArea()
            }
        }
        .sheet(item: $debugSheet) { sheet in
            switch sheet {
            case .settings:
                SettingsView()
                    .environmentObject(app)
                    .environmentObject(app.settings)
            case .channels:
                ChannelPickerSheet(selected: app.settings.timelineChannel) { kind in
                    app.settings.timelineChannel = kind
                    debugSheet = nil
                }
                .environmentObject(app.settings)
                .presentationDetents([.height(400)])
            case .images:
                ImageBrowserView(state: ImageBrowserState(
                    images: DemoData.demoSunsetImages,
                    index: 0,
                    statusID: nil
                ))
                .environmentObject(app.settings)
            }
        }
        // 卡片右上角「…」更多操作
        .sheet(item: Binding(
            get: { app.pendingMoreItem },
            set: { app.pendingMoreItem = $0 }
        )) { item in
            MoreSheet(item: item)
                .environmentObject(app)
                .environmentObject(app.settings)
        }
    }

    /// 启动参数 `-screen detail|search|profile|topic` 可直接进入对应页面，方便逐页检查。
    private func openDebugScreenIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-screen"), index + 1 < arguments.count else { return }
        switch arguments[index + 1] {
        case "detail":
            app.timelinePath = [.detail(id: "demo-1", title: nil)]
        case "profile":
            tab = .profile
            app.profilePath = [.user(uid: "demo-uid", name: "微博科技")]
        case "me":
            tab = .profile
        case "search":
            tab = .search
        case "topic":
            app.timelinePath = [.topic("数码评测")]
        case "poll":
            app.timelinePath = [.detail(id: "demo-3", title: nil)]
        case "compose":
            app.compose = ComposeState(mode: .newStatus)
        case "message":
            tab = .message
        case "settings":
            tab = .profile
            debugSheet = .settings
        case "channels":
            debugSheet = .channels
        case "images":
            debugSheet = .images
        default:
            break
        }
    }

    /// 进入详情 / 主页等二级页面时收起底栏，把空间让给内容。
    private var isTabBarVisible: Bool {
        switch tab {
        case .timeline: return app.timelinePath.isEmpty
        case .search: return app.searchPath.isEmpty
        case .profile: return app.profilePath.isEmpty
        case .message: return true
        }
    }

    // MARK: - 底部导航

    private var bottomBar: some View {
        HStack(spacing: 0) {
            tabButton(.timeline, symbol: "house.fill", title: "首页")
            tabButton(.message, symbol: "envelope.fill", title: "消息")
            tabButton(.search, symbol: "magnifyingglass", title: "搜索")

            Button {
                guard app.requireLogin() else { return }
                app.compose = ComposeState(mode: .newStatus)
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(app.settings.themeColor.color))
                    .shadow(color: app.settings.themeColor.color.opacity(0.35), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            tabButton(.profile, symbol: "person.fill", title: "我的")
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(.white.opacity(0.16))
                        .frame(height: 0.6)
                }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func tabButton(_ target: RootTab, symbol: String, title: String) -> some View {
        Button {
            if tab == target {
                // 再次点击当前标签回到顶部（清空堆栈）。
                switch target {
                case .timeline: app.timelinePath = []
                case .search: app.searchPath = []
                case .profile: app.profilePath = []
                case .message: break
                }
            } else {
                tab = target
            }
            Haptics.tap()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: tab == target ? .semibold : .regular))
                Text(title)
                    .font(.system(size: 10, weight: tab == target ? .semibold : .regular))
            }
            .foregroundStyle(tab == target ? app.settings.themeColor.color : Color.secondary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
