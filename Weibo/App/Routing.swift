import SwiftUI

// MARK: - 路由

enum Route: Hashable {
    case detail(id: String, title: String?)
    case user(uid: String, name: String)
    case topic(String)
    case searchResults(query: String, isUser: Bool)
}

// MARK: - 弹出层状态

struct ImageBrowserState: Identifiable {
    let id = UUID()
    var images: [FeedImage]
    var index: Int
    var statusID: String?
}

enum ComposeMode {
    case newStatus
    case comment(FeedItem, replyTo: CommentItem?)
    case repost(FeedItem)
}

struct ComposeState: Identifiable {
    let id = UUID()
    var mode: ComposeMode
}

/// 微博被点赞/收藏/删除后广播出去，所有正在展示它的列表同步刷新。
struct FeedUpdate: Equatable {
    let id = UUID()
    var item: FeedItem?
    var deletedID: String?
}

// MARK: - 交互路由

@MainActor
extension AppModel {

    func push(_ route: Route, in tab: AppTab) {
        switch tab {
        case .timeline, .message, .compose: timelinePath.append(route)
        case .search: searchPath.append(route)
        case .profile: profilePath.append(route)
        }
    }

    /// 卡片上的所有交互在这里落地，页面只负责渲染。
    func handle(_ action: FeedAction, in tab: AppTab) {
        switch action {
        case let .openDetail(item):
            push(.detail(id: item.detailKey, title: nil), in: tab)

        case let .openUser(uid, name):
            push(.user(uid: uid, name: name), in: tab)

        case let .openImages(images, index):
            imageBrowser = ImageBrowserState(images: images, index: index, statusID: nil)

        case let .openOriginalStatus(original):
            push(.detail(id: original.detailKey, title: nil), in: tab)

        case let .playVideo(media):
            videoToPlay = media

        case let .openTopic(keyword):
            push(.topic(keyword), in: tab)

        case let .openLink(url):
            externalLink = url

        case let .like(item):
            guard requireLogin() else { return }
            applyLike(item)

        case let .favorite(item):
            guard requireLogin() else { return }
            applyFavorite(item)

        case let .comment(item):
            guard requireLogin() else { return }
            compose = ComposeState(mode: .comment(item, replyTo: nil))

        case let .repost(item):
            guard requireLogin() else { return }
            compose = ComposeState(mode: .repost(item))

        case let .more(item):
            pendingMoreItem = item
        }
    }

    // MARK: - 点赞 / 收藏

    private func applyLike(_ item: FeedItem) {
        // 先本地翻转再发请求，失败回滚，避免等网络才有反馈。
        var optimistic = item
        optimistic.liked.toggle()
        optimistic.likesCount = HTMLText.bumpCount(item.likesCount, delta: optimistic.liked ? 1 : -1)
        broadcast(optimistic)

        Task {
            do {
                let updated = try await session.setLike(item, like: optimistic.liked)
                broadcast(updated)
                Haptics.tap()
            } catch {
                broadcast(item)
                showError(error)
            }
        }
    }

    private func applyFavorite(_ item: FeedItem) {
        var optimistic = item
        optimistic.favorited.toggle()
        broadcast(optimistic)

        Task {
            do {
                let updated = try await session.setFavorite(item, favorite: optimistic.favorited)
                broadcast(updated)
                showToast(optimistic.favorited ? "已收藏" : "已取消收藏", symbol: "star.fill")
            } catch {
                broadcast(item)
                showError(error)
            }
        }
    }

    func deleteStatus(_ item: FeedItem) async -> Bool {
        do {
            try await session.deleteStatus(item)
            feedUpdate = FeedUpdate(item: nil, deletedID: item.id)
            showToast("已删除")
            return true
        } catch {
            showError(error)
            return false
        }
    }

    func broadcast(_ item: FeedItem) {
        feedUpdate = FeedUpdate(item: item, deletedID: nil)
    }
}
