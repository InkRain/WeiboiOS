import Foundation

/// 首页各频道信息流缓存：内存一份（切回页面秒开），磁盘存原始 JSON（冷启动也能秒开）。
///
/// 之所以存「原始 JSON」而不是把 FeedItem 序列化，是因为 FeedItem 不是 Codable，
/// 而解析本来就由 FeedParser 负责——复用它即可，省去一套易碎的编解码。
final class FeedCache {

    static let shared = FeedCache()

    /// 缓存有效期：超过这个时间后，进入页面仍先秒开旧数据，但会强制后台刷新一次。
    private let maxAge: TimeInterval = 30 * 60

    private let queue = DispatchQueue(label: "com.example.myweibo.feedcache")
    private var memoryItems: [TimelineKind: [FeedItem]] = [:]
    private var memoryCursor: [TimelineKind: String?] = [:]
    private var memoryDate: [TimelineKind: Date] = [:]

    private let fileManager = FileManager.default
    private var directory: URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FeedCache", isDirectory: true)
    }

    // MARK: - 读取

    /// 返回缓存的首屏内容（内存优先，回落磁盘）。没有或已空返回 nil。
    /// 命中磁盘时会补回内存，避免下次再读盘。
    func cachedItems(kind: TimelineKind) -> (items: [FeedItem], cursor: String?)? {
        if let items = memoryItems[kind], let cursor = memoryCursor[kind], !items.isEmpty {
            return (items, cursor)
        }
        guard let raw = try? String(contentsOf: fileURL(kind: kind), encoding: .utf8),
              !raw.isEmpty,
              let page = try? FeedParser.parseTimeline(raw) else {
            return nil
        }
        queue.sync {
            memoryItems[kind] = page.items
            memoryCursor[kind] = page.nextCursor
            memoryDate[kind] = Date()
        }
        return (page.items, page.nextCursor)
    }

    // MARK: - 写入

    /// 只缓存首屏（cursor 为 nil 的那次），翻页结果不覆盖首屏缓存。
    func store(kind: TimelineKind, raw: String, items: [FeedItem], cursor: String?) {
        queue.sync {
            memoryItems[kind] = items
            memoryCursor[kind] = cursor
            memoryDate[kind] = Date()
        }
        // 磁盘写入放到后台，避免主线程被 JSON 落盘卡住。
        queue.async { [weak self] in
            guard let self else { return }
            try? self.fileManager.createDirectory(at: self.directory ?? URL(fileURLWithPath: "/dev/null"), withIntermediateDirectories: true)
            let url = self.fileURL(kind: kind)
            try? raw.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// 清空缓存。不传 kind 表示清空全部（退出登录 / 切换账号时用，避免串号）。
    func clear(kind: TimelineKind? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            if let kind {
                self.memoryItems[kind] = nil
                self.memoryCursor[kind] = nil
                self.memoryDate[kind] = nil
                if let dir = self.directory { try? self.fileManager.removeItem(at: self.fileURL(kind: kind)) }
            } else {
                self.memoryItems.removeAll()
                self.memoryCursor.removeAll()
                self.memoryDate.removeAll()
                if let dir = self.directory { try? self.fileManager.removeItem(at: dir) }
            }
        }
    }

    private func fileURL(kind: TimelineKind) -> URL {
        directory?.appendingPathComponent("timeline_\(kind.rawValue).json")
            ?? URL(fileURLWithPath: "/dev/null")
    }
}
