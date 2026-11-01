import SwiftUI
import WebKit
import SafariServices

// MARK: - 通用 WKWebView 包装

struct WebViewContainer: UIViewRepresentable {
    let url: URL
    var userAgent: String?
    var onNavigationFinished: ((URL?) -> Void)?
    var onProgress: ((Double) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        if let userAgent {
            webView.customUserAgent = userAgent
        }
        context.coordinator.observeProgress(webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let parent: WebViewContainer
        private var progressObservation: NSKeyValueObservation?

        init(_ parent: WebViewContainer) {
            self.parent = parent
        }

        func observeProgress(_ webView: WKWebView) {
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                let value = webView.estimatedProgress
                DispatchQueue.main.async { self?.parent.onProgress?(value) }
            }
        }

        func stopObserving() {
            progressObservation?.invalidate()
            progressObservation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onNavigationFinished?(webView.url)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(.allow)
        }

        /// 微博登录可能弹新窗口，直接在当前 WebView 打开。
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}

// MARK: - 登录页

struct LoginWebView: View {
    var onSuccess: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var progress: Double = 0
    @State private var didComplete = false

    private var loginURL: URL {
        URL(string: WeiboConstants.passportLogin) ?? URL(string: WeiboConstants.home)!
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                WebViewContainer(
                    url: loginURL,
                    userAgent: WeiboConstants.desktopUserAgent,
                    onNavigationFinished: { url in
                        checkLogin(currentURL: url)
                    },
                    onProgress: { progress = $0 }
                )
                .ignoresSafeArea(edges: .bottom)

                if progress < 1 {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }
            }
            .navigationTitle("登录微博")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("已完成") {
                        Task { await completeIfLoggedIn() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(false)
    }

    private func checkLogin(currentURL: URL?) {
        guard !didComplete else { return }
        guard let host = currentURL?.host, host.contains("weibo.com") else { return }
        guard !host.contains("passport") else { return }
        Task { await completeIfLoggedIn() }
    }

    private func completeIfLoggedIn() async {
        if await CookieJar.shared.hasLogin() {
            didComplete = true
            onSuccess()
            dismiss()
        }
    }
}

// MARK: - 应用内浏览器

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.preferredControlTintColor = UIColor.label
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

// MARK: - 消息标签页

/// 消息中心是 m.weibo.cn 的网页，未登录时先给一个原生引导，避免直接看到网页登录表单。
struct MessagesTabView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if app.isLoggedIn {
                WebPageView(path: "msg", title: "消息")
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "envelope.badge")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Theme.tertiaryText(scheme))
                    Text("登录后查看私信与通知")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.secondaryText(scheme))
                    Text("消息页面由微博网页版提供，登录凭据只保存在本机。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.tertiaryText(scheme))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button {
                        app.showLoginSheet = true
                    } label: {
                        Text("登录微博账号")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 26)
                            .padding(.vertical, 11)
                            .background(Capsule().fill(settings.themeColor.color))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    Spacer()
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.pageBackground(scheme).ignoresSafeArea())
                .navigationTitle("消息")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

// MARK: - 网页标签页（消息中心）

struct WebPageView: View {
    let path: String
    var title: String

    @Environment(\.colorScheme) private var scheme
    @State private var progress: Double = 0
    @State private var reloadToken = UUID()

    var body: some View {
        VStack(spacing: 0) {
            if progress < 1 {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            }
            WebViewContainer(
                url: URL(string: "https://m.weibo.cn/\(path)") ?? URL(string: WeiboConstants.home)!,
                userAgent: WeiboConstants.mweiboUserAgent,
                onProgress: { progress = $0 }
            )
            .id(reloadToken)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
