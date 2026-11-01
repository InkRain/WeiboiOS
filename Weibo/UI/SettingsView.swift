import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @ObservedObject private var accountStore = AccountStore.shared
    @State private var showLogin = false
    @State private var confirmSignOut = false
    @State private var cacheCleared = false

    private var accent: Color { app.settings.themeColor.color }

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                appearanceSection
                readingSection
                playbackSection
                storageSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.pageBackground(scheme))
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showLogin) {
                LoginWebView {
                    Task { await app.completeLogin() }
                }
            }
            .confirmationDialog("退出登录会清除本地登录状态", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) {
                    Task { await app.signOut() }
                }
                Button("取消", role: .cancel) {}
            }
        }
        .tint(accent)
    }

    // MARK: - 账号

    private var accountSection: some View {
        Section {
            if accountStore.accounts.isEmpty {
                Button {
                    showLogin = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .foregroundStyle(accent)
                        Text("登录微博账号")
                            .foregroundStyle(.primary)
                    }
                }
            } else {
                ForEach(accountStore.accounts) { account in
                    Button {
                        Task { await app.switchAccount(account.uid) }
                    } label: {
                        HStack(spacing: 11) {
                            AvatarView(url: account.avatar, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name)
                                    .font(.system(size: 14.5, weight: .medium))
                                    .foregroundStyle(.primary)
                                Text("UID \(account.uid)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if account.uid == accountStore.currentUID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(accent)
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    let targets = offsets.map { accountStore.accounts[$0] }
                    Task {
                        for account in targets {
                            await accountStore.remove(uid: account.uid)
                        }
                    }
                }

                Button {
                    showLogin = true
                } label: {
                    Label("添加其他账号", systemImage: "plus.circle")
                        .foregroundStyle(accent)
                }

                Button(role: .destructive) {
                    confirmSignOut = true
                } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } header: {
            Text("账号")
        } footer: {
            Text("登录通过微博网页完成，应用只在本机保存登录凭据；删除本地账号不等于注销微博账号。")
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        Section("外观") {
            VStack(alignment: .leading, spacing: 10) {
                Text("主题颜色")
                    .font(.system(size: 13))
                HStack(spacing: 0) {
                    ForEach(ThemeColor.allCases) { option in
                        Button {
                            app.settings.themeColor = option
                        } label: {
                            Circle()
                                .fill(option.color)
                                .frame(width: 24, height: 24)
                                .overlay {
                                    if app.settings.themeColor == option {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 4)

            Picker("深色模式", selection: Binding(
                get: { app.settings.appearance },
                set: { app.settings.appearance = $0 }
            )) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - 阅读

    private var readingSection: some View {
        Section("阅读") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("正文字号")
                    Spacer()
                    Text(String(format: "%.0f%%", app.settings.fontScale * 100))
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12.5))
                }
                Slider(
                    value: Binding(
                        get: { app.settings.fontScale },
                        set: { app.settings.fontScale = $0 }
                    ),
                    in: 0.85...1.35,
                    step: 0.05
                )
                .tint(accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("正文行距")
                    Spacer()
                    Text(String(format: "%.0f", app.settings.lineSpacing))
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12.5))
                }
                Slider(
                    value: Binding(
                        get: { app.settings.lineSpacing },
                        set: { app.settings.lineSpacing = $0 }
                    ),
                    in: 0...12,
                    step: 1
                )
                .tint(accent)
            }

            Picker("图片清晰度", selection: Binding(
                get: { app.settings.imageQuality },
                set: { app.settings.imageQuality = $0 }
            )) {
                ForEach(ImageQuality.allCases) { quality in
                    Text(quality.label).tag(quality)
                }
            }

            Toggle("显示评论点赞数", isOn: Binding(
                get: { app.settings.showCommentLikes },
                set: { app.settings.showCommentLikes = $0 }
            ))
            .tint(accent)
        }
    }

    // MARK: - 播放

    private var playbackSection: some View {
        Section("播放") {
            Toggle("后台播放声音", isOn: Binding(
                get: { app.settings.backgroundAudio },
                set: { app.settings.backgroundAudio = $0 }
            ))
            .tint(accent)
        }
    }

    // MARK: - 存储

    private var storageSection: some View {
        Section("存储") {
            Button {
                ImageCache.shared.clear()
                cacheCleared = true
                app.showToast("图片缓存已清理")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { cacheCleared = false }
            } label: {
                HStack {
                    Text("清理图片缓存").foregroundStyle(.primary)
                    Spacer()
                    if cacheCleared {
                        Text("已清理").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            HStack {
                Text("版本")
                Spacer()
                Text(Self.versionText).foregroundStyle(.secondary)
            }
            Link(destination: URL(string: "https://github.com/gaoxipeng/Android_16_Weibo")!) {
                HStack {
                    Text("参考的 Android 项目").foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink("使用说明") {
                HelpView()
            }
        } header: {
            Text("关于")
        } footer: {
            Text("本项目为非官方客户端，仅供学习交流。接口由微博网页提供，接口变化或账号风控可能影响部分功能。请遵守微博用户协议及相关法律。")
        }
    }

    private static var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

// MARK: - 使用说明

struct HelpView: View {
    private let sections: [(String, [String])] = [
        ("开始使用", [
            "首次使用请到「我的 → 设置 → 账号」完成微博网页登录。",
            "可以在账号页添加、切换、删除已保存的账号。",
            "遇到登录失效提示时，重新登录后刷新即可。",
        ]),
        ("首页与频道", [
            "底部依次是信息流、消息、搜索、写微博、我的。",
            "点击左上角频道名称可切换：最新微博、好友圈、我的收藏、我的赞、热门、同城。",
            "下拉刷新，接近列表底部自动加载更多。",
        ]),
        ("微博卡片", [
            "点击卡片进入详情；点击被转发的灰色卡片进入原微博。",
            "点击彩色的 @昵称、#话题# 或链接会分别打开用户主页、话题搜索或对应网页。",
            "右上角菜单支持复制正文、收藏、分享与查看详情。",
        ]),
        ("评论、转发与点赞", [
            "详情页可切换「评论」和「转发」，评论可切换按热度或按时间排序。",
            "长按评论的「回复」可楼中楼回复；底部输入框可直接评论。",
            "点击赞会立即变色，失败会自动回滚。",
        ]),
        ("图片与视频", [
            "点击图片查看大图，支持双指缩放、双击放大、下拉关闭。",
            "大图右上角可保存到相册。",
            "点击视频封面进入播放页，支持系统播放控件的全屏与画中画。",
        ]),
        ("个人主页", [
            "「我的」和用户主页提供微博、相册、视频、赞过四个标签。",
            "相册按九宫格展示照片；视频标签展示已加载微博中的视频。",
        ]),
        ("隐私说明", [
            "登录通过微博网页完成，应用使用登录 Cookie 调用微博接口。",
            "请将本地账号数据视为敏感信息，不要在公开场合分享登录快照。",
        ]),
    ]

    var body: some View {
        List {
            ForEach(sections, id: \.0) { section in
                Section(section.0) {
                    ForEach(section.1, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("使用说明")
        .navigationBarTitleDisplayMode(.inline)
    }
}
