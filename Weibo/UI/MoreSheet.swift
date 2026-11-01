import SwiftUI

/// 卡片右上角「…」的操作面板：复制、收藏、在浏览器打开、删除自己的微博。
struct MoreSheet: View {
    let item: FeedItem

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingDelete = false

    private var accent: Color { settings.themeColor.color }

    /// 只有自己的微博才给删除入口。
    private var isMine: Bool {
        guard let uid = app.currentUser?.id, !uid.isEmpty else { return false }
        return uid == item.authorID
    }

    private var webURL: String {
        let author = item.authorID.isEmpty ? "u" : item.authorID
        return "https://weibo.com/\(author)/\(item.detailKey)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 0) {
                row(title: "复制正文", symbol: "doc.on.doc") {
                    UIPasteboard.general.string = item.text
                    app.showToast("已复制正文", symbol: "doc.on.doc")
                    dismiss()
                }
                divider
                row(title: "复制链接", symbol: "link") {
                    UIPasteboard.general.string = webURL
                    app.showToast("已复制链接", symbol: "link")
                    dismiss()
                }
                divider
                row(title: "在浏览器打开", symbol: "safari") {
                    app.externalLink = webURL
                    dismiss()
                }
                divider
                row(
                    title: item.favorited ? "取消收藏" : "收藏这条微博",
                    symbol: item.favorited ? "star.slash" : "star"
                ) {
                    dismiss()
                    app.handle(.favorite(item), in: .timeline)
                }

                if isMine {
                    divider
                    row(title: "删除微博", symbol: "trash", tint: .red) {
                        confirmingDelete = true
                    }
                }
            }
            .background(Theme.cardBackground(scheme))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Button {
                dismiss()
            } label: {
                Text("取消")
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Theme.cardBackground(scheme))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.pageBackground(scheme).ignoresSafeArea())
        .presentationDetents([.height(isMine ? 420 : 366)])
        .presentationDragIndicator(.visible)
        .alert("删除这条微博？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) {
                dismiss()
                Task { _ = await app.deleteStatus(item) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复。")
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(item.authorName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(item.text)
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 14)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.separator(scheme))
            .frame(height: 0.5)
            .padding(.leading, 48)
    }

    private func row(
        title: String,
        symbol: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(tint ?? accent)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(tint ?? .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
