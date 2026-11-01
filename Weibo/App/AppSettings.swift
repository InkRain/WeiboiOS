import SwiftUI

// MARK: - 主题配色

/// 对应原版的九种主题色，作用于导航、按钮和强调文字。
enum ThemeColor: String, CaseIterable, Identifiable {
    case weibo
    case orange
    case amber
    case green
    case teal
    case blue
    case indigo
    case purple
    case pink

    var id: String { rawValue }

    var label: String {
        switch self {
        case .weibo: return "微博红"
        case .orange: return "橙色"
        case .amber: return "琥珀"
        case .green: return "绿色"
        case .teal: return "青色"
        case .blue: return "蓝色"
        case .indigo: return "靛蓝"
        case .purple: return "紫色"
        case .pink: return "粉色"
        }
    }

    var color: Color {
        switch self {
        case .weibo: return Color(red: 0.95, green: 0.32, blue: 0.29)
        case .orange: return Color(red: 0.98, green: 0.51, blue: 0.19)
        case .amber: return Color(red: 0.95, green: 0.68, blue: 0.16)
        case .green: return Color(red: 0.24, green: 0.72, blue: 0.42)
        case .teal: return Color(red: 0.18, green: 0.70, blue: 0.68)
        case .blue: return Color(red: 0.24, green: 0.56, blue: 0.96)
        case .indigo: return Color(red: 0.36, green: 0.42, blue: 0.92)
        case .purple: return Color(red: 0.58, green: 0.40, blue: 0.93)
        case .pink: return Color(red: 0.95, green: 0.42, blue: 0.62)
        }
    }
}

// MARK: - 外观模式

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - 图片清晰度

enum ImageQuality: String, CaseIterable, Identifiable {
    case saver, standard, high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .saver: return "省流"
        case .standard: return "标准"
        case .high: return "高清"
        }
    }
}

// MARK: - 设置存储

/// 用 AppStorage 直连，改动立即生效，不需要额外的保存逻辑。
final class AppSettings: ObservableObject {
    @Published var themeColor: ThemeColor {
        didSet { UserDefaults.standard.set(themeColor.rawValue, forKey: Keys.themeColor) }
    }
    @Published var appearance: AppearanceMode {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    @Published var imageQuality: ImageQuality {
        didSet { UserDefaults.standard.set(imageQuality.rawValue, forKey: Keys.imageQuality) }
    }
    @Published var fontScale: Double {
        didSet { UserDefaults.standard.set(fontScale, forKey: Keys.fontScale) }
    }
    @Published var lineSpacing: Double {
        didSet { UserDefaults.standard.set(lineSpacing, forKey: Keys.lineSpacing) }
    }
    @Published var showCommentLikes: Bool {
        didSet { UserDefaults.standard.set(showCommentLikes, forKey: Keys.showCommentLikes) }
    }
    @Published var autoHideTabBar: Bool {
        didSet { UserDefaults.standard.set(autoHideTabBar, forKey: Keys.autoHideTabBar) }
    }
    @Published var backgroundAudio: Bool {
        didSet { UserDefaults.standard.set(backgroundAudio, forKey: Keys.backgroundAudio) }
    }
    @Published var timelineChannel: TimelineKind {
        didSet { UserDefaults.standard.set(timelineChannel.rawValue, forKey: Keys.timelineChannel) }
    }

    private enum Keys {
        static let themeColor = "settings.themeColor"
        static let appearance = "settings.appearance"
        static let imageQuality = "settings.imageQuality"
        static let fontScale = "settings.fontScale"
        static let lineSpacing = "settings.lineSpacing"
        static let showCommentLikes = "settings.showCommentLikes"
        static let autoHideTabBar = "settings.autoHideTabBar"
        static let backgroundAudio = "settings.backgroundAudio"
        static let timelineChannel = "settings.timelineChannel"
    }

    init() {
        let defaults = UserDefaults.standard
        themeColor = ThemeColor(rawValue: defaults.string(forKey: Keys.themeColor) ?? "") ?? .weibo
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        imageQuality = ImageQuality(rawValue: defaults.string(forKey: Keys.imageQuality) ?? "") ?? .standard
        fontScale = defaults.object(forKey: Keys.fontScale) as? Double ?? 1.0
        lineSpacing = defaults.object(forKey: Keys.lineSpacing) as? Double ?? 4
        showCommentLikes = defaults.object(forKey: Keys.showCommentLikes) as? Bool ?? true
        autoHideTabBar = defaults.object(forKey: Keys.autoHideTabBar) as? Bool ?? true
        backgroundAudio = defaults.object(forKey: Keys.backgroundAudio) as? Bool ?? false
        timelineChannel = TimelineKind.from(storage: defaults.string(forKey: Keys.timelineChannel))
    }

    /// 正文基础字号，配合 fontScale 使用。
    var bodyFontSize: CGFloat { 16 * fontScale }
    var nameFontSize: CGFloat { 15.5 * fontScale }
    var captionFontSize: CGFloat { 12.5 * fontScale }
}
