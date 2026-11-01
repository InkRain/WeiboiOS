import Foundation

/// 一个已保存的微博账号。Cookie 快照是关键：切号时不重新登录，直接换 Cookie。
struct SavedAccount: Identifiable, Codable, Equatable {
    var uid: String
    var name: String
    var avatar: String?
    var cookies: [[String: String]]

    var id: String { uid }
}

@MainActor
final class AccountStore: ObservableObject {

    static let shared = AccountStore()

    private(set) var accounts: [SavedAccount] = []
    private(set) var currentUID: String?

    private let fileURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Accounts.json")

    init() {
        load()
    }

    var currentAccount: SavedAccount? {
        accounts.first { $0.uid == currentUID }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        accounts = payload.accounts
        currentUID = payload.currentUID
    }

    private func persist() {
        let payload = Payload(accounts: accounts, currentUID: currentUID)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: [.atomic])
    }

    private struct Payload: Codable {
        var accounts: [SavedAccount]
        var currentUID: String?
    }

    /// 登录成功后调用：抓取当前 Cookie 与身份信息落库。
    func saveCurrentSession(uid: String, name: String, avatar: String?) async {
        let cookies = await CookieJar.shared.encodedCookies()
        let account = SavedAccount(uid: uid, name: name, avatar: avatar, cookies: cookies)
        if let index = accounts.firstIndex(where: { $0.uid == uid }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        currentUID = uid
        persist()
    }

    /// 切号：清掉当前 Cookie，灌入目标账号的 Cookie，再重建身份缓存。
    func switchTo(uid: String) async throws {
        guard let account = accounts.first(where: { $0.uid == uid }) else {
            throw WeiboError.api("账号不存在")
        }
        await CookieJar.shared.clearAll()
        await CookieJar.shared.applyEncodedCookies(account.cookies)
        currentUID = uid
        persist()
        WeiboSession.shared.clearIdentityCache()
        guard await WeiboSession.shared.hasLogin() else {
            throw WeiboError.api("该账号的登录状态已失效，请重新登录")
        }
    }

    func remove(uid: String) async {
        accounts.removeAll { $0.uid == uid }
        if currentUID == uid {
            currentUID = accounts.first?.uid
            if let next = currentUID {
                try? await switchTo(uid: next)
            } else {
                await CookieJar.shared.clearAll()
                WeiboSession.shared.clearIdentityCache()
            }
        }
        persist()
    }

    /// 退出当前账号（只清本地登录态，不影响微博账号本身）。
    func signOut() async {
        await CookieJar.shared.clearAll()
        currentUID = nil
        accounts = []
        persist()
        WeiboSession.shared.clearIdentityCache()
    }

    func refreshCurrentAccountProfile(name: String, avatar: String?) async {
        guard let uid = currentUID, let index = accounts.firstIndex(where: { $0.uid == uid }) else { return }
        accounts[index].name = name
        accounts[index].avatar = avatar
        accounts[index].cookies = await CookieJar.shared.encodedCookies()
        persist()
    }
}
