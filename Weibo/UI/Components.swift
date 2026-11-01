import SwiftUI
import UIKit
import ImageIO

// MARK: - 图片缓存

/// 微博图片体积大、列表滚动快，用内存缓存 + 解码时降采样控制内存。
final class ImageCache {
    static let shared = ImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()

    init() {
        memory.countLimit = 220
        memory.totalCostLimit = 120 * 1024 * 1024
    }

    func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url.absoluteString as NSString)
    }

    func load(_ url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        let key = url.absoluteString
        if let cached = memory.object(forKey: key as NSString) { return cached }

        let task: Task<UIImage?, Never> = lock.withLock {
            if let existing = inFlight[key] { return existing }
            let newTask = Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let data = try? await URLSession.shared.data(from: url).0 else { return nil }
                return Self.downsample(data: data, maxPixelSize: maxPixelSize)
            }
            inFlight[key] = newTask
            return newTask
        }

        let image = await task.value
        lock.withLock { inFlight[key] = nil }
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * 4)
            memory.setObject(image, forKey: key as NSString, cost: cost)
        }
        return image
    }

    nonisolated static func downsample(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    func clear() {
        memory.removeAllObjects()
    }
}

// MARK: - 网络图片

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var maxPixelSize: CGFloat = 1000
    var placeholderSymbol: String = "photo"

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                Rectangle()
                    .fill(.quaternary.opacity(0.35))
                    .overlay {
                        if failed {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.system(size: 18))
                                .foregroundStyle(.tertiary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard let url else { return }
        if let cached = ImageCache.shared.cached(url) {
            image = cached
            return
        }
        image = nil
        failed = false
        let loaded = await ImageCache.shared.load(url, maxPixelSize: maxPixelSize)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            image = loaded
            failed = loaded == nil
        }
    }
}

// MARK: - 头像

struct AvatarView: View {
    let url: String?
    var size: CGFloat = 40
    var ringColor: Color = .clear

    var body: some View {
        RemoteImage(url: URL(string: url ?? ""), maxPixelSize: size * 3)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(ringColor, lineWidth: ringColor == .clear ? 0 : 1.6)
            }
            .overlay {
                Circle().strokeBorder(.black.opacity(0.06), lineWidth: 0.5)
            }
    }
}

// MARK: - 认证标识

struct VerificationBadge: View {
    let verification: UserVerification?

    var body: some View {
        if let verification {
            Image(systemName: verification.symbols)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color(verification))
                .accessibilityLabel(verification.label)
        }
    }

    private func color(_ value: UserVerification) -> Color {
        switch value {
        case .red: return Color(red: 0.92, green: 0.26, blue: 0.24)
        case .orange: return Color(red: 0.98, green: 0.55, blue: 0.20)
        case .blue: return Color(red: 0.26, green: 0.55, blue: 0.94)
        case .yellow: return Color(red: 0.95, green: 0.72, blue: 0.16)
        case .gold: return Color(red: 0.85, green: 0.63, blue: 0.18)
        case .grey: return Color(white: 0.55)
        }
    }
}

// MARK: - 状态视图

struct LoadingStateView: View {
    var text: String = "正在加载"

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

struct EmptyStateView: View {
    var symbol: String = "tray"
    var title: String
    var message: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}

struct ErrorStateView: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            if let retry {
                Button("重新加载", action: retry)
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// 底部「加载更多」的轻量指示。
struct LoadMoreIndicator: View {
    var text: String = "加载中…"

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

// MARK: - 顶部胶囊提示

struct ToastOverlay: View {
    let toast: ToastMessage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol)
                .font(.system(size: 14, weight: .semibold))
            Text(toast.text)
                .font(.subheadline.weight(.medium))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(toast.isError ? Color.white : Color.primary)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background {
            if toast.isError {
                Capsule().fill(Color(red: 0.85, green: 0.25, blue: 0.22))
            } else {
                Capsule().fill(.ultraThinMaterial)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.6))
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .padding(.horizontal, 24)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - 分组标题

struct SectionHeader: View {
    let title: String
    var trailing: AnyView?

    var body: some View {
        HStack {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, Theme.horizontalPadding)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }
}
