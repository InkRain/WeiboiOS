import SwiftUI

/// 不依赖 `.refreshable` 的自定义下拉刷新容器。
/// 在「ZStack + 顶部 safeAreaInset」这类结构里，系统 `.refreshable` 经常无法触发，
/// 这里改用滚动手势 + 滚动偏移检测，行为完全可控。
struct RefreshableScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content
    let onRefresh: () async -> Void

    @State private var isRefreshing = false
    @State private var pullDistance: CGFloat = 0
    @State private var scrollMinY: CGFloat = 0
    @State private var topBaseline: CGFloat?

    private let threshold: CGFloat = 70
    private let maxPull: CGFloat = 90

    /// 是否处于列表最顶端（含顶部下拉的过冲位置）。
    private var atTop: Bool {
        guard let base = topBaseline else { return scrollMinY > -4 }
        return scrollMinY >= base - 4
    }

    var body: some View {
        ScrollView {
            ZStack(alignment: .top) {
                GeometryReader { proxy in
                    let y = proxy.frame(in: .named("rtScroll")).minY
                    Color.clear.preference(key: ScrollOffsetKey.self, value: y)
                }
                .frame(height: 0)
                content()
            }
        }
        .coordinateSpace(name: "rtScroll")
        .scrollIndicators(.hidden)
        .overlay(alignment: .top) { indicator }
        .simultaneousGesture(drag)
        .onPreferenceChange(ScrollOffsetKey.self) { y in
            scrollMinY = y
            if topBaseline == nil || y > topBaseline! { topBaseline = y }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                guard atTop, !isRefreshing else { return }
                let d = v.translation.height
                pullDistance = d > 0 ? min(d * 0.55, maxPull) : 0
            }
            .onEnded { v in
                guard atTop, !isRefreshing else { return }
                let d = v.translation.height
                if d > threshold {
                    trigger()
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { pullDistance = 0 }
                }
            }
    }

    private func trigger() {
        isRefreshing = true
        pullDistance = 44
        Task {
            await onRefresh()
            withAnimation(.easeOut(duration: 0.25)) {
                isRefreshing = false
                pullDistance = 0
            }
        }
    }

    @ViewBuilder
    private var indicator: some View {
        if pullDistance > 0.5 || isRefreshing {
            ProgressView()
                .tint(.secondary)
                .scaleEffect(isRefreshing ? 1 : max(0.5, pullDistance / threshold))
                .opacity(isRefreshing ? 1 : pullDistance / threshold)
                .padding(.top, 6 + pullDistance)
        }
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
