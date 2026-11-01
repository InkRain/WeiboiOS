import SwiftUI

@MainActor
final class TimelineStore: ObservableObject {
    @Published private(set) var items: [FeedItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?
    @Published var lastRefreshCount: Int?

    private var cursor: String?
    private var hasMore = true
    private var loadedGeneration: Int?

    var kind: TimelineKind
    private let session = WeiboSession.shared

    init(kind: TimelineKind) {
        self.kind = kind
    }

    /// 切换频道：更新 kind 并重新拉取对应接口（或 demo 数据）。
    /// store 由 @StateObject 持有，kind 不能靠重建触发，必须显式切换。
    func setKind(_ newKind: TimelineKind) async {
        guard newKind != kind else { return }
        kind = newKind
        loadedGeneration = nil
        items = []
        cursor = nil
        hasMore = true
        errorMessage = nil
        // 先秒开该频道的缓存（如果有），再后台刷新，避免切频道又从头转圈。
        if let cached = FeedCache.shared.cachedItems(kind: newKind), !cached.items.isEmpty {
            items = cached.items
            cursor = cached.cursor
            hasMore = cached.cursor != nil
            Task { await refresh(announce: false) }
        } else {
            await refresh(announce: false)
        }
    }

    var isEmpty: Bool { items.isEmpty && !isLoading }

    func loadIfNeeded(generation: Int) async {
        guard loadedGeneration != generation else { return }
        loadedGeneration = generation
        cursor = nil
        hasMore = true
        // 有缓存就先秒开旧内容，后台静默刷新；没有才显示转圈拉取。
        if let cached = FeedCache.shared.cachedItems(kind: kind), !cached.items.isEmpty {
            items = cached.items
            cursor = cached.cursor
            hasMore = cached.cursor != nil
            errorMessage = nil
            Task { await refresh(announce: false) }
        } else {
            items = []
            await refresh(announce: false)
        }
    }

    func refresh(announce: Bool = true) async {
        guard !isLoading else { return }
        if DemoMode.isEnabled {
            items = DemoData.timeline(kind: kind)
            lastRefreshCount = items.count
            cursor = nil
            hasMore = false
            errorMessage = nil
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let page = try await session.loadTimeline(kind: kind, cursor: nil)
            let fetched = dedupe(page.items)
            // 增量刷新：保留列表里已有的微博，只把「列表中还没有的」新微博插到最前。
            // 这样下拉刷新不会清空/重置时间线，已读的内容也不会丢；没有新微博时原样保留。
            let existingIds = Set(items.map(\.id))
            let newlyAdded = fetched.filter { !existingIds.contains($0.id) }
            if items.isEmpty {
                // 冷启动（无缓存）时直接整列赋值。
                items = fetched
            } else {
                items.insert(contentsOf: newlyAdded, at: 0)
            }
            lastRefreshCount = newlyAdded.count
            cursor = page.nextCursor
            hasMore = page.nextCursor != nil
        } catch {
            // 不论是否已有内容都记录错误，供 UI 提示（之前有内容时会被静默吞掉，
            // 导致「下拉刷新看起来没反应」）。已有微博一律保留，不被清空。
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func loadMore() async {
        guard !isLoading, !isLoadingMore, hasMore, let cursor else { return }
        isLoadingMore = true
        do {
            let page = try await session.loadTimeline(kind: kind, cursor: cursor)
            let existing = Set(items.map(\.id))
            let added = page.items.filter { !existing.contains($0.id) }
            items.append(contentsOf: added)
            // 微博的 max_id 偶尔会原地不动或返回整页重复内容，不拦住就会无限请求。
            if added.isEmpty || page.nextCursor == cursor {
                hasMore = false
            } else {
                self.cursor = page.nextCursor
                hasMore = page.nextCursor != nil
            }
        } catch {
            hasMore = false
            errorMessage = error.localizedDescription
        }
        isLoadingMore = false
    }

    func apply(_ updated: FeedItem) {
        guard let index = items.firstIndex(where: { $0.id == updated.id }) else { return }
        items[index] = updated
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
    }

    private func dedupe(_ list: [FeedItem]) -> [FeedItem] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }
    }
}

// MARK: - 首页

struct TimelineView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var scheme

    @StateObject private var store: TimelineStore
    @State private var showChannelPicker = false

    init(kind: TimelineKind) {
        _store = StateObject(wrappedValue: TimelineStore(kind: kind))
    }

    private var accent: Color { settings.themeColor.color }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.pageBackground(scheme).ignoresSafeArea()

            RefreshableScrollView {
                LazyVStack(spacing: Theme.cardSpacing) {
                    if store.items.isEmpty && store.isLoading {
                        LoadingStateView(text: "正在加载微博")
                            .padding(.top, 90)
                    } else if let message = store.errorMessage, store.items.isEmpty {
                        ErrorStateView(message: message) {
                            Task { await store.refresh() }
                        }
                        .padding(.top, 60)
                    } else if store.isEmpty {
                        EmptyStateView(
                            symbol: store.kind.symbol,
                            title: "还没有内容",
                            message: "下拉刷新，或换个频道看看"
                        )
                        .padding(.top, 60)
                    }

                    ForEach(store.items) { item in
                        FeedCard(item: item) { action in
                            app.handle(action, in: .timeline)
                        }
                        .onAppear {
                            if item.id == store.items.last?.id {
                                Task { await store.loadMore() }
                            }
                        }
                    }

                    if store.isLoadingMore {
                        LoadMoreIndicator()
                    } else if !store.items.isEmpty && store.items.count > 3 {
                        Text("已经到底啦")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 20)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 110)
            } onRefresh: {
                await doRefresh()
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                channelBar
            }
        }
        .navigationDestination(for: Route.self) { RouteView(route: $0, tab: .timeline) }
        .task(id: app.sessionGeneration) {
            await store.loadIfNeeded(generation: app.sessionGeneration)
        }
        .onChange(of: app.feedUpdate) { _, update in
            guard let update else { return }
            if let item = update.item { store.apply(item) }
            if let id = update.deletedID { store.remove(id: id) }
        }
        .onChange(of: settings.timelineChannel) { _, newKind in
            // 频道变化后让 store 重新拉取对应接口（顶部频道名已直接读 settings，即时更新）。
            Task { await store.setKind(newKind) }
        }
        .sheet(isPresented: $showChannelPicker) {
            ChannelPickerSheet(selected: settings.timelineChannel) { kind in
                settings.timelineChannel = kind
                app.timelinePath = []
                showChannelPicker = false
            }
            .presentationDetents([.height(400)])
        }
    }

    private func doRefresh() async {
        await store.refresh()
        if let err = store.errorMessage, !store.items.isEmpty {
            app.showToast("刷新失败：\(err)", symbol: "exclamationmark.triangle")
        } else if let count = store.lastRefreshCount {
            app.showToast(count > 0 ? "更新了 \(count) 条微博" : "已是最新内容", symbol: "arrow.clockwise")
        }
    }

    private var channelBar: some View {
        HStack(spacing: 8) {
            Button {
                showChannelPicker = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: settings.timelineChannel.symbol)
                        .font(.system(size: 12, weight: .semibold))
                    Text(settings.timelineChannel.label)
                        .font(.system(size: 14, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassBar(cornerRadius: 18)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                Task { await doRefresh() }
            } label: {
                Group {
                    if store.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .glassBar(cornerRadius: 19)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
}

// MARK: - 频道选择

struct ChannelPickerSheet: View {
    let selected: TimelineKind
    var onSelect: (TimelineKind) -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(TimelineKind.allCases) { kind in
                    Button {
                        onSelect(kind)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: kind.symbol)
                                .font(.system(size: 15))
                                .foregroundStyle(settings.themeColor.color)
                                .frame(width: 24)
                            Text(kind.label)
                                .foregroundStyle(.primary)
                            Spacer()
                            if kind == selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(settings.themeColor.color)
                            }
                        }
                    }
                    .listRowBackground(Theme.cardBackground(scheme))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.pageBackground(scheme))
            .navigationTitle("选择频道")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationBackground(Theme.pageBackground(scheme))
        .presentationDragIndicator(.visible)
    }
}
