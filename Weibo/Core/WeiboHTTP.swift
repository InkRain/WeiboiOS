import Foundation
import WebKit

/// 微博的登录态完全落在网页 Cookie 上。这个类负责在「WKWebView 登录」和
/// 「原生接口请求」之间同步 Cookie，并把同一份登录态保存成可切换的账号快照。
final class CookieJar {

    static let shared = CookieJar()

    private let store = WKWebsiteDataStore.default().httpCookieStore

    /// 快照写盘用的队列，避免多账号切换时并发写坏文件。
    private let snapshotQueue = DispatchQueue(label: "com.example.myweibo.cookiesnapshot")

    // MARK: - 读取

    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    func weiboCookies() async -> [HTTPCookie] {
        await allCookies().filter { cookie in
            let domain = cookie.domain.lowercased()
            return domain.contains("weibo") || domain.contains("sina")
        }
    }

    /// 组装 Cookie 请求头。按 domain 过滤，避免把无关站点的 Cookie 发给微博。
    func cookieHeader() async -> String {
        let cookies = await weiboCookies().filter { !$0.isHTTPOnlyExpired }
        let sorted = cookies.sorted { $0.name < $1.name }
        var seen = Set<String>()
        var parts: [String] = []
        for cookie in sorted where seen.insert(cookie.name).inserted {
            parts.append("\(cookie.name)=\(cookie.value)")
        }
        return parts.joined(separator: "; ")
    }

    /// 有 SUB 才算真正登录。
    func hasLogin() async -> Bool {
        let cookies = await weiboCookies()
        return cookies.contains { $0.name == "SUB" && !$0.value.isEmpty }
    }

    func xsrfToken() async -> String? {
        let cookies = await weiboCookies()
        guard let raw = cookies.first(where: { $0.name == "XSRF-TOKEN" })?.value else { return nil }
        return raw.removingPercentEncoding ?? raw
    }

    // MARK: - 写入

    func setCookies(_ cookies: [HTTPCookie]) async {
        guard !cookies.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for cookie in cookies {
                group.enter()
                store.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .global()) { continuation.resume() }
        }
        await saveSnapshot()
    }

    /// 把响应里的 Set-Cookie 同步回 WebView，保证网页端与原生请求的登录态一致。
    func syncResponseCookies(_ response: HTTPURLResponse, url: URL) async {
        guard let fields = response.allHeaderFields as? [String: String] else { return }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !cookies.isEmpty else { return }
        await setCookies(cookies)
    }

    // MARK: - 账号快照

    private var snapshotURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WeiboCookies.json")
    }

    /// 供多账号使用：把当前 Cookie 序列化成可持久化的字典数组。
    func encodedCookies() async -> [[String: String]] {
        let cookies = await weiboCookies()
        return cookies.compactMap { cookie -> [String: String]? in
            guard let properties = cookie.properties else { return nil }
            var encoded: [String: String] = [:]
            for (key, value) in properties {
                guard let keyName = key as? HTTPCookiePropertyKey else { continue }
                encoded[keyName.rawValue] = String(describing: value)
            }
            return encoded
        }
    }

    func applyEncodedCookies(_ list: [[String: String]]) async {
        let cookies: [HTTPCookie] = list.compactMap { encoded in
            var properties: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in encoded {
                properties[HTTPCookiePropertyKey(key)] = value
            }
            return HTTPCookie(properties: properties)
        }
        await setCookies(cookies)
    }

    func saveSnapshot() async {
        let payload = await encodedCookies()
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try? FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        snapshotQueue.sync {
            try? data?.write(to: snapshotURL, options: [.atomic])
        }
    }

    /// 冷启动时把上次保存的 Cookie 重新灌回 WebView，避免「关掉应用就要重新登录」。
    func restoreSnapshot() async {
        guard FileManager.default.fileExists(atPath: snapshotURL.path),
              let data = try? Data(contentsOf: snapshotURL),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: String]],
              !list.isEmpty else {
            return
        }
        await applyEncodedCookies(list)
    }

    func clearAll() async {
        let cookies = await allCookies()
        for cookie in cookies where cookie.domain.contains("weibo") || cookie.domain.contains("sina") {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.delete(cookie) { continuation.resume() }
            }
        }
        let empty = Data("[]".utf8)
        snapshotQueue.sync {
            try? empty.write(to: snapshotURL, options: [.atomic])
        }
    }
}

private extension HTTPCookie {
    var isHTTPOnlyExpired: Bool {
        if let expires = expiresDate, expires < Date() { return true }
        return value.isEmpty
    }
}

// MARK: - 请求引擎

/// 复刻 Kotlin 版的请求头组合：桌面 UA + Referer + Origin + X-XSRF-TOKEN。
/// 微博对这几个头敏感，缺任何一个都可能直接返回 HTML 登录页。
final class WeiboHTTP {

    static let shared = WeiboHTTP()

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["Accept-Encoding": "gzip, deflate"]
        session = URLSession(configuration: configuration)
    }

    func get(
        path: String,
        params: [String: String] = [:],
        referer: String = WeiboConstants.home
    ) async throws -> String {
        let url = try buildURL(base: "https://weibo.com", path: path, params: params)
        return try await send(url: url, method: "GET", body: nil, referer: referer, origin: "https://weibo.com", userAgent: WeiboConstants.desktopUserAgent)
    }

    func getAbsolute(
        _ urlString: String,
        params: [String: String] = [:],
        referer: String,
        origin: String,
        userAgent: String = WeiboConstants.desktopUserAgent
    ) async throws -> String {
        guard let base = URL(string: urlString) else { throw WeiboError.invalidResponse("无效的请求地址") }
        let url = try buildURL(base: base.absoluteString, path: "", params: params)
        return try await send(url: url, method: "GET", body: nil, referer: referer, origin: origin, userAgent: userAgent)
    }

    func postForm(
        path: String,
        params: [String: String],
        referer: String = WeiboConstants.home,
        base: String = "https://weibo.com",
        origin: String = "https://weibo.com",
        userAgent: String = WeiboConstants.desktopUserAgent
    ) async throws -> String {
        let url = try buildURL(base: base, path: path, params: [:])
        let body = params
            .map { "\($0.key.urlEncoded())=\($0.value.urlEncoded())" }
            .joined(separator: "&")
            .data(using: .utf8)
        return try await send(
            url: url, method: "POST", body: body, referer: referer, origin: origin,
            userAgent: userAgent, contentType: "application/x-www-form-urlencoded; charset=UTF-8"
        )
    }

    func postJSON(
        path: String,
        json: [String: Any],
        referer: String = WeiboConstants.home
    ) async throws -> String {
        let url = try buildURL(base: "https://weibo.com", path: path, params: [:])
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await send(
            url: url, method: "POST", body: body, referer: referer, origin: "https://weibo.com",
            userAgent: WeiboConstants.desktopUserAgent, contentType: "application/json; charset=UTF-8"
        )
    }

    // MARK: - 内部

    private func buildURL(base: String, path: String, params: [String: String]) throws -> URL {
        let combined = base.hasSuffix("/") && path.hasPrefix("/")
            ? base + String(path.dropFirst())
            : base + path
        guard var components = URLComponents(string: combined) else {
            throw WeiboError.invalidResponse("无效的请求地址")
        }
        if !params.isEmpty {
            components.queryItems = params
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw WeiboError.invalidResponse("无效的请求地址") }
        return url
    }

    private func send(
        url: URL,
        method: String,
        body: Data?,
        referer: String,
        origin: String,
        userAgent: String,
        contentType: String? = nil
    ) async throws -> String {
        let cookieHeader = await CookieJar.shared.cookieHeader()
        guard cookieHeader.contains("SUB=") else { throw WeiboError.notLoggedIn }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let xsrf = await CookieJar.shared.xsrfToken() {
            request.setValue(xsrf, forHTTPHeaderField: "X-XSRF-TOKEN")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WeiboError.invalidResponse("未收到有效响应")
        }
        await CookieJar.shared.syncResponseCookies(http, url: url)

        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if http.statusCode == 401 || http.statusCode == 302 {
                throw WeiboError.notLoggedIn
            }
            throw WeiboError.http(http.statusCode, String(snippet.prefix(120)))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw WeiboError.invalidResponse("响应编码无法识别")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") {
            throw WeiboError.htmlResponse
        }
        return text
    }
    // MARK: - 图片上传

    /// 微博图床上传是把图片原始字节直接作为请求体，pid 从返回 JSON 里取。
    func uploadBinary(
        urlString: String,
        data: Data,
        contentType: String,
        referer: String
    ) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw WeiboError.invalidResponse("无效的上传地址")
        }
        let cookieHeader = await CookieJar.shared.cookieHeader()
        guard cookieHeader.contains("SUB=") else { throw WeiboError.notLoggedIn }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue(WeiboConstants.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("https://weibo.com", forHTTPHeaderField: "Origin")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        if let xsrf = await CookieJar.shared.xsrfToken() {
            request.setValue(xsrf, forHTTPHeaderField: "X-XSRF-TOKEN")
        }

        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WeiboError.invalidResponse("上传未收到有效响应")
        }
        await CookieJar.shared.syncResponseCookies(http, url: url)
        guard (200...299).contains(http.statusCode) else {
            throw WeiboError.http(http.statusCode, String(data: responseData, encoding: .utf8)?.prefix(120).description ?? "")
        }
        guard let text = String(data: responseData, encoding: .utf8) else {
            throw WeiboError.invalidResponse("上传响应编码无法识别")
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
            throw WeiboError.htmlResponse
        }
        return text
    }
}

extension String {
    func urlEncoded() -> String {
        addingPercentEncoding(withAllowedCharacters: .weiboQueryAllowed) ?? self
    }
}

extension CharacterSet {
    /// 微博接口要求空格编码成 %20，不能是 "+"。
    static let weiboQueryAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=%#?")
        return allowed
    }()
}
