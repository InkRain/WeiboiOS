import SwiftUI
import PhotosUI

struct ComposeView: View {
    let mode: ComposeMode

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var visibility: WeiboPostVisibility = .public
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var imageData: [Data] = []
    @State private var isSending = false
    @State private var alsoComment = false
    @FocusState private var focused: Bool

    private var accent: Color { settings.themeColor.color }

    private var title: String {
        switch mode {
        case .newStatus: return "写微博"
        case .comment: return "写评论"
        case .repost: return "转发微博"
        }
    }

    private var allowsImages: Bool {
        if case .newStatus = mode { return true }
        return false
    }

    private var allowsVisibility: Bool {
        if case .newStatus = mode { return true }
        return false
    }

    private var maxLength: Int { 2000 }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.pageBackground(scheme).ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        contextCard

                        editor

                        if !imageData.isEmpty {
                            selectedImages
                        }

                        if case let .repost(item) = mode {
                            Toggle("同时评论原微博", isOn: $alsoComment)
                                .font(.system(size: 14))
                                .padding(14)
                                .cardSurface(scheme)
                            if item.retweetedStatus != nil {
                                Text("将转发该微博的转发内容")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        if allowsVisibility {
                            visibilityPicker
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                editorBar
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await send() }
                    } label: {
                        Group {
                            if isSending {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("发送").font(.system(size: 15, weight: .semibold))
                            }
                        }
                        .foregroundStyle(canSend ? accent : Theme.tertiaryText(scheme))
                    }
                    .disabled(!canSend || isSending)
                }
            }
            .onAppear {
                if case let .comment(_, replyTo) = mode, let replyTo {
                    text = "回复 @" + replyTo.authorName + "："
                }
            }
        }
    }

    private var canSend: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .repost = mode { return true }
        return !trimmed.isEmpty || !imageData.isEmpty
    }

    // MARK: - 引用上下文

    @ViewBuilder
    private var contextCard: some View {
        switch mode {
        case .newStatus:
            EmptyView()
        case let .comment(item, _), let .repost(item):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    AvatarView(url: item.authorAvatarURL, size: 22)
                    Text(item.authorName)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(item.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.quoteBackground(scheme))
            )
        }
    }

    // MARK: - 输入区

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: settings.bodyFontSize))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                }
                TextEditor(text: $text)
                    .font(.system(size: settings.bodyFontSize))
                    .lineSpacing(settings.lineSpacing)
                    .focused($focused)
                    .frame(minHeight: 150)
                    .scrollContentBackground(.hidden)
                    .background(.clear)
            }
        }
        .padding(12)
        .cardSurface(scheme)
    }

    private var placeholder: String {
        switch mode {
        case .newStatus: return "分享新鲜事…"
        case .comment: return "写评论…"
        case .repost: return "说点什么（留空则自动为「转发微博」）"
        }
    }

    private var imagePickerButton: some View {
        PhotosPicker(
            selection: $pickerItems,
            maxSelectionCount: max(0, 9 - imageData.count),
            matching: .images
        ) {
            HStack(spacing: 6) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 16))
                Text(imageData.isEmpty ? "图片" : "\(imageData.count)/9")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(imageData.count >= 9 ? Theme.tertiaryText(scheme) : accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(accent.opacity(0.1)))
        }
        .disabled(imageData.count >= 9)
        .onChange(of: pickerItems) { _, items in
            Task { await loadImages(items) }
        }
    }

    /// 底部编辑工具条：图片、话题、@、字数。
    private var editorBar: some View {
        HStack(spacing: 10) {
            if allowsImages {
                imagePickerButton
            }

            Button {
                text += "#话题#"
            } label: {
                barIcon("number")
            }
            .buttonStyle(.plain)

            Button {
                text += "@"
            } label: {
                barIcon("at")
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Text("\(text.count)/\(maxLength)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(text.count > maxLength ? Color.red : Theme.tertiaryText(scheme))
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background {
            Rectangle()
                .fill(Theme.cardBackground(scheme))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Theme.separator(scheme))
                        .frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func barIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16))
            .foregroundStyle(Theme.secondaryText(scheme))
            .frame(width: 34, height: 32)
    }

    private var selectedImages: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(imageData.enumerated()), id: \.offset) { index, data in
                    ZStack(alignment: .topTrailing) {
                        if let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 92, height: 92)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        Button {
                            imageData.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(.white, .black.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var visibilityPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("谁可以看")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
            Picker("可见范围", selection: $visibility) {
                ForEach(WeiboPostVisibility.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(14)
        .cardSurface(scheme)
    }

    // MARK: - 动作

    private func loadImages(_ items: [PhotosPickerItem]) async {
        var loaded: [Data] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                loaded.append(data)
            }
        }
        await MainActor.run {
            imageData.append(contentsOf: loaded)
            pickerItems = []
        }
    }

    private func send() async {
        guard app.requireLogin() else { return }
        isSending = true
        defer { isSending = false }

        do {
            switch mode {
            case .newStatus:
                var pids: [String] = []
                for (index, data) in imageData.enumerated() {
                    app.showToast("正在上传第 \(index + 1)/\(imageData.count) 张图片", symbol: "arrow.up.circle")
                    let mime = Self.mimeType(for: data)
                    let pid = try await WeiboSession.shared.uploadImage(data, mimeType: mime)
                    pids.append(pid)
                }
                try await WeiboSession.shared.postStatus(
                    content: text,
                    visibility: visibility,
                    imagePIDs: pids
                )
                app.showToast("微博已发布")
                app.timelinePath = []

            case let .comment(item, replyTo):
                try await WeiboSession.shared.postComment(
                    to: item,
                    text: text,
                    replyToCommentID: replyTo?.id
                )
                app.showToast("评论已发布")

            case let .repost(item):
                try await WeiboSession.shared.repost(item, text: text, alsoComment: alsoComment)
                app.showToast("已转发")
            }
            Haptics.success()
            dismiss()
        } catch {
            Haptics.error()
            app.showError(error)
        }
    }

    private static func mimeType(for data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8]) { return "image/jpeg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        let header = data.prefix(12)
        if header.count >= 12, header[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50]) {
            return "image/webp"
        }
        return "image/jpeg"
    }
}
