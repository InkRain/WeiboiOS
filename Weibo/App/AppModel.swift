import SwiftUI

enum AppTab: Hashable {
    case timeline, message, search, compose, profile
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var symbol: String = "checkmark.circle.fill"
    var isError: Bool = false
}

@MainActor
final class AppModel: ObservableObject {

    let settings = AppSettings()
    let accounts = AccountStore.shared
    let session = WeiboSession.shared

    var tab: AppTab = .timeline
    @Published var isLoggedIn = false
    @Published var isBootstrapping = true
    @Published var currentUser: UserProfile?
    @Published var toast: ToastMessage?
    @Published var showLoginSheet = false

    /// 切号 / 重新登录后自增，用来让各页面丢弃旧数据重新加载。
    @Published var sessionGeneration = 0

    // MARK: - 导航与弹出层

    @Published var timelinePath: [Route] = []
    @Published var searchPath: [Route] = []
    @Published var profilePath: [Route] = []

    @Published var imageBrowser: ImageBrowserState?
    @Published var videoToPlay: FeedMedia?
    @Published var externalLink: String?
    @Published var compose: ComposeState?
    @Published var pendingMoreItem: FeedItem?
    @Published var pendingTopic: String?
    @Published var feedUpdate: FeedUpdate?

    private var toastTask: Task<Void, Never>?

    // MARK: - 启动

    func bootstrap() async {
        defer { isBootstrapping = false }
        await CookieJar.shared.restoreSnapshot()

        if await session.hasLogin() {
            isLoggedIn = true
            _ = await session.refreshIdentity()
            // 资料接口要两次串行请求，比较慢；放到后台去拉，先让首页用缓存/骨架出来，
            // 否则每次冷启动都要盯着启动转圈好几秒。
            Task.detached { [weak self] in
                guard let session = await self?.session else { return }
                if let user = try? await session.loadCurrentProfile() {
                    await self?.applyProfile(user)
                }
            }
        } else {
            isLoggedIn = false
            currentUser = nil
        }
    }

    /// 后台拉到资料后回到主线程更新并落盘，避免阻塞启动。
    private func applyProfile(_ user: UserProfile) {
        currentUser = user
        Task {
            await accounts.saveCurrentSession(
                uid: user.id,
                name: user.screenName,
                avatar: user.avatarURL
            )
        }
    }

    /// 网页登录完成后调用。
    func completeLogin() async {
        await CookieJar.shared.saveSnapshot()
        _ = await session.refreshIdentity()
        guard let identity = await session.currentUserIdentity() else {
            isLoggedIn = false
            showToast("登录状态读取失败，请重试", symbol: "exclamationmark.triangle.fill", isError: true)
            return
        }
        isLoggedIn = true
        currentUser = try? await session.loadCurrentProfile()
        await accounts.saveCurrentSession(
            uid: identity.uid,
            name: currentUser?.screenName ?? identity.name,
            avatar: currentUser?.avatarURL ?? identity.avatar
        )
        sessionGeneration += 1
        showToast("已登录：\(currentUser?.screenName ?? identity.name)")
    }

    func switchAccount(_ uid: String) async {
        do {
            try await accounts.switchTo(uid: uid)
            _ = await session.refreshIdentity()
            isLoggedIn = true
            currentUser = try? await session.loadCurrentProfile()
            // 换号后清掉旧号的信息流缓存，避免串号闪现上一个账号的内容。
            FeedCache.shared.clear()
            sessionGeneration += 1
            showToast("已切换账号")
        } catch {
            showToast(error.localizedDescription, symbol: "exclamationmark.triangle.fill", isError: true)
        }
    }

    func signOut() async {
        await accounts.signOut()
        session.clearIdentityCache()
        isLoggedIn = false
        currentUser = nil
        // 退出登录清空所有信息流缓存，下次进入是干净状态。
        FeedCache.shared.clear()
        sessionGeneration += 1
        showToast("已退出登录")
    }

    func refreshProfile() async {
        currentUser = try? await session.loadCurrentProfile()
        if let user = currentUser {
            await accounts.refreshCurrentAccountProfile(name: user.screenName, avatar: user.avatarURL)
        }
        showToast("资料已更新", symbol: "arrow.clockwise")
    }

    // MARK: - 提示

    func showToast(_ text: String, symbol: String = "checkmark.circle.fill", isError: Bool = false) {
        toastTask?.cancel()
        withAnimation(.snappy(duration: 0.22)) {
            toast = ToastMessage(text: text, symbol: symbol, isError: isError)
        }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.snappy(duration: 0.22)) { self?.toast = nil }
            }
        }
    }

    func showError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        showToast(message, symbol: "exclamationmark.triangle.fill", isError: true)
    }

    /// 未登录时统一拦在入口，避免每个页面各写一遍。
    func requireLogin() -> Bool {
        if isLoggedIn { return true }
        showLoginSheet = true
        showToast("请先登录微博账号", symbol: "person.crop.circle.badge.exclamationmark", isError: true)
        return false
    }
}
