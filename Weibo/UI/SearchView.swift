import SwiftUI

enum SearchScope: String, CaseIterable, Identifiable {
    case statuses = "微博"
    case users = "用户"

    var id: String { rawValue }
}

@MainActor
final class SearchStore: ObservableObject {
    @Published var query = ""
    @Published var scope: SearchScope = .statuses
    @Published var realtime = false

    @Published private(set) var hot: [HotSearchItem] = []
    @Published private(set) var results: [FeedItem] = []
    @Published private(set) var users: [SearchUserItem] = []
    @Published private(set) var history: [String] = []

    @Published var isSearching = false
    @Published var isLoadingMore = false
    @Published var errorMessage: String?
    @Published var didSearch = false

    private var page = 1
    private var hasMore = true
    private let session = WeiboSession.shared

    private static let historyKey = "search.history"

    init() {
        history = UserDefaults.standard.stringArray(forKey: Self.historyKey) ?? []
    }

    func loadHot() async {
        guard hot.isEmpty else { return }
        if DemoMode.isEnabled {
            hot = DemoData.hotSearch()
            return
        }
        hot = (try? await session.loadHotSearch()) ?? []
    }

    func remember(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        history.removeAll { $0 == trimmed }
        history.insert(trimmed, at: 0)
        if history.count > 12 { history = Array(history.prefix(12)) }
        UserDefaults.standard.set(history, forKey: Self.historyKey)
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: Self.historyKey)
    }

    func search(_ keyword: String? = nil) async {
        let text = (keyword ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        query = text
        remember(text)
        isSearching = true
        errorMessage = nil
        didSearch = true
        page = 1
        results = []
        users = []
        hasMore = true
        do {
            switch scope {
            case .statuses:
                let result = try await session.searchStatuses(text, page: 1, realtime: realtime)
                results = result.items
                hasMore = result.nextCursor != nil
            case .users:
                let result = try await session.searchUsers(text, page: 1)
                users = result.items
                hasMore = result.nextCursor != nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isSearching = false
    }

    func loadMore() async {
        guard !isSearching, !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        let next = page + 1
        do {
            switch scope {
            case .statuses:
                let result = try await session.searchStatuses(query, page: next, realtime: realtime)
                let existing = Set(results.map(\.id))
                let added = result.items.filter { !existing.contains($0.id) }
                results.append(contentsOf: added)
                // m.weibo.cn 在 total 缺失时只能按「本页是否满 10 条」推测还有下一页，
                // 一旦服务端忽略 page 参数就会拿到整页重复内容，必须靠去重结果兜底。
                hasMore = result.nextCursor != nil && !added.isEmpty
            case .users:
                let result = try await session.searchUsers(query, page: next)
                let existing = Set(users.map(\.id))
                let added = result.items.filter { !existing.contains($0.id) }
                users.append(contentsOf: added)
                hasMore = result.nextCursor != nil && !added.isEmpty
            }
            page = next
        } catch {
            hasMore = false
        }
        isLoadingMore = false
    }

    func switchScope(_ newScope: SearchScope) async {
        guard scope != newScope else { return }
        scope = newScope
        if didSearch { await search(query) }
    }

    func apply(_ item: FeedItem) {
        if let index = results.firstIndex(where: { $0.id == item.id }) { results[index] = item }
    }

    func remove(id: String) {
        results.removeAll { $0.id == id }
    }
}

// MARK: - 搜索页

struct SearchView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var scheme

    @StateObject private var store = SearchStore()
    @FocusState private var focused: Bool

    private var accent: Color { settings.themeColor.color }

    var body: some View {
        NavigationStack(path: Binding(
            get: { app.searchPath },
            set: { app.searchPath = $0 }
        )) {
            ZStack {
                Theme.pageBackground(scheme).ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: Theme.cardSpacing) {
                        searchField
                        scopeBar
                        content
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 110)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Route.self) { RouteView(route: $0, tab: .search) }
            .task { await store.loadHot() }
            .onChange(of: app.feedUpdate) { _, update in
                guard let update else { return }
                if let item = update.item { store.apply(item) }
                if let id = update.deletedID { store.remove(id: id) }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.tertiaryText(scheme))
            TextField(store.scope == .statuses ? "搜索微博" : "搜索用户", text: $store.query)
                .font(.system(size: 15))
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { Task { await store.search() } }
            if !store.query.isEmpty {
                Button {
                    store.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            Button {
                Task { await store.search() }
            } label: {
                Text("搜索")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .cardSurface(scheme, radius: 14)
    }

    private var scopeBar: some View {
        HStack(spacing: 8) {
            ForEach(SearchScope.allCases) { scope in
                Button {
                    Task { await store.switchScope(scope) }
                } label: {
                    Text(scope.rawValue)
                        .font(.system(size: 13, weight: store.scope == scope ? .semibold : .regular))
                        .foregroundStyle(store.scope == scope ? .white : Theme.secondaryText(scheme))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(store.scope == scope ? accent : Theme.cardBackground(scheme))
                        )
                }
                .buttonStyle(.plain)
            }

            if store.scope == .statuses {
                Menu {
                    Button("综合排序") { Task { await setRealtime(false) } }
                    Button("实时排序") { Task { await setRealtime(true) } }
                } label: {
                    HStack(spacing: 3) {
                        Text(store.realtime ? "实时" : "综合")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(accent.opacity(0.1)))
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func setRealtime(_ value: Bool) async {
        store.realtime = value
        if store.didSearch { await store.search() }
    }

    @ViewBuilder
    private var content: some View {
        if store.isSearching {
            LoadingStateView(text: "正在搜索")
        } else if let error = store.errorMessage {
            ErrorStateView(message: error) { Task { await store.search() } }
        } else if store.didSearch {
            resultsContent
        } else {
            discoveryContent
        }
    }

    @ViewBuilder
    private var resultsContent: some View {
        switch store.scope {
        case .statuses:
            if store.results.isEmpty {
                EmptyStateView(symbol: "magnifyingglass", title: "没有找到相关微博", message: "换个关键词试试")
            } else {
                ForEach(store.results) { item in
                    FeedCard(item: item) { action in
                        app.handle(action, in: .search)
                    }
                    .onAppear {
                        if item.id == store.results.last?.id {
                            Task { await store.loadMore() }
                        }
                    }
                }
                if store.isLoadingMore { LoadMoreIndicator() }
            }
        case .users:
            if store.users.isEmpty {
                EmptyStateView(symbol: "person.slash", title: "没有找到相关用户")
            } else {
                VStack(spacing: 0) {
                    ForEach(store.users) { user in
                        UserRow(user: user) {
                            app.handle(.openUser(uid: user.id, name: user.screenName), in: .search)
                        }
                        Divider().overlay(Theme.separator(scheme)).padding(.leading, 62)
                    }
                }
                .cardSurface(scheme)
                if store.isLoadingMore { LoadMoreIndicator() }
            }
        }
    }

    @ViewBuilder
    private var discoveryContent: some View {
        if !store.history.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("搜索历史").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("清空") { store.clearHistory() }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                FlowLayout(spacing: 8) {
                    ForEach(store.history, id: \.self) { word in
                        chip(word)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(scheme)
        }

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(accent)
                Text("微博热搜").font(.system(size: 13.5, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if store.hot.isEmpty {
                LoadingStateView(text: "正在读取热搜").scaleEffect(0.9)
            } else {
                ForEach(Array(store.hot.enumerated()), id: \.element.id) { index, item in
                    Button {
                        Task { await store.search(item.word) }
                    } label: {
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(index < 3 ? accent : Theme.tertiaryText(scheme))
                                .frame(width: 18, alignment: .leading)
                            Text(item.word)
                                .font(.system(size: 14))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if !item.label.isEmpty {
                                Text(item.label)
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 3.5)
                                    .padding(.vertical, 1.5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(labelColor(item.label))
                                    )
                            }
                            Spacer(minLength: 0)
                            if item.heat > 0 {
                                Text(HTMLText.formatCount(JSONValue(item.heat)))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(scheme)
    }

    private func chip(_ word: String) -> some View {
        Button {
            Task { await store.search(word) }
        } label: {
            Text(word)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryText(scheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(Theme.quoteBackground(scheme))
                )
        }
        .buttonStyle(.plain)
    }

    private func labelColor(_ label: String) -> Color {
        switch label {
        case "爆": return Color(red: 0.75, green: 0.10, blue: 0.12)
        case "热": return Color(red: 0.93, green: 0.35, blue: 0.20)
        case "新": return Color(red: 0.20, green: 0.62, blue: 0.36)
        case "沸": return Color(red: 0.88, green: 0.24, blue: 0.30)
        default: return Color(red: 0.95, green: 0.55, blue: 0.22)
        }
    }
}

// MARK: - 用户行

struct UserRow: View {
    let user: SearchUserItem
    var onTap: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                AvatarView(url: user.avatarURL, size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(user.screenName)
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        VerificationBadge(verification: user.verification)
                        Spacer(minLength: 0)
                        if !user.followersCount.isEmpty {
                            Text("\(user.followersCount) 粉丝")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if !user.description.isEmpty {
                        Text(user.description)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.secondaryText(scheme))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 话题 / 搜索结果页

struct TopicView: View {
    let keyword: String

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var scheme

    @State private var items: [FeedItem] = []
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var page = 1
    @State private var hasMore = true

    var body: some View {
        ZStack {
            Theme.pageBackground(scheme).ignoresSafeArea()
            ScrollView {
                LazyVStack(spacing: Theme.cardSpacing) {
                    if isLoading && items.isEmpty {
                        LoadingStateView(text: "正在搜索话题").padding(.top, 60)
                    } else if let errorMessage, items.isEmpty {
                        ErrorStateView(message: errorMessage) { Task { await load() } }.padding(.top, 60)
                    } else if items.isEmpty {
                        EmptyStateView(symbol: "number", title: "没有找到相关微博").padding(.top, 60)
                    }
                    ForEach(items) { item in
                        FeedCard(item: item) { action in
                            app.handle(action, in: .timeline)
                        }
                        .onAppear {
                            if item.id == items.last?.id { Task { await loadMore() } }
                        }
                    }
                    if isLoadingMore { LoadMoreIndicator() }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("#\(keyword)#")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: app.feedUpdate) { _, update in
            guard let item = update?.item,
                  let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            items[index] = item
        }
    }

    private func load() async {
        guard !isLoading else { return }
        if DemoMode.isEnabled {
            items = DemoData.timeline()
            hasMore = false
            return
        }
        isLoading = true
        errorMessage = nil
        page = 1
        do {
            let result = try await WeiboSession.shared.searchTopic(keyword, page: 1)
            items = result.items
            hasMore = result.nextCursor != nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        do {
            let result = try await WeiboSession.shared.searchTopic(keyword, page: page + 1)
            let existing = Set(items.map(\.id))
            let added = result.items.filter { !existing.contains($0.id) }
            items.append(contentsOf: added)
            page += 1
            hasMore = result.nextCursor != nil && !added.isEmpty
        } catch {
            hasMore = false
        }
        isLoadingMore = false
    }
}

// MARK: - 简易流式布局

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var rows: [CGFloat] = [0]
        var rowWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                rows.append(size.height)
                rowWidth = size.width + spacing
            } else {
                rowWidth += size.width + spacing
            }
        }
        let height = rows.reduce(0, +) + CGFloat(max(rows.count - 1, 0)) * spacing
        return CGSize(width: maxWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += size.height + spacing
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
        }
    }
}
