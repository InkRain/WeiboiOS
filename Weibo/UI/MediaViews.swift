import SwiftUI
import AVKit
import Photos

// MARK: - 大图浏览

struct ImageBrowserView: View {
    let state: ImageBrowserState

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var index: Int
    @State private var showChrome = true
    @State private var isSaving = false
    @State private var dragOffset: CGFloat = 0

    init(state: ImageBrowserState) {
        self.state = state
        _index = State(initialValue: state.index)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(state.images.enumerated()), id: \.offset) { offset, image in
                    ZoomableImage(
                        url: image.displayURL(preferLarge: true),
                        onSingleTap: { withAnimation(.easeInOut(duration: 0.2)) { showChrome.toggle() } },
                        onDragDown: { translation in dragOffset = translation }
                    )
                    .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: dragOffset)
            .scaleEffect(dragOffset == 0 ? 1 : max(0.85, 1 - abs(dragOffset) / 1200))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if value.translation.height > 0, abs(value.translation.width) < 60 {
                            dragOffset = value.translation.height
                        }
                    }
                    .onEnded { value in
                        if value.translation.height > 120 {
                            dismiss()
                        } else {
                            withAnimation(.spring(response: 0.3)) { dragOffset = 0 }
                        }
                    }
            )

            if showChrome {
                chrome
            }
        }
        .statusBarHidden(!showChrome)
    }

    private var chrome: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.black.opacity(0.35)))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("\(index + 1) / \(state.images.count)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.black.opacity(0.35)))

                Spacer()

                Button {
                    Task { await saveCurrent() }
                } label: {
                    Group {
                        if isSaving {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.black.opacity(0.35)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            if state.images.count > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<state.images.count, id: \.self) { offset in
                        Circle()
                            .fill(offset == index ? Color.white : Color.white.opacity(0.35))
                            .frame(width: offset == index ? 7 : 5, height: offset == index ? 7 : 5)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(.black.opacity(0.3)))
                .padding(.bottom, 30)
            }
        }
        .transition(.opacity)
    }

    private func saveCurrent() async {
        guard index < state.images.count else { return }
        let image = state.images[index]
        isSaving = true
        defer { isSaving = false }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            ToastCenter.shared.show("没有相册写入权限，请到系统设置中开启", isError: true)
            return
        }
        guard let url = URL(string: image.largeURL) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }
            ToastCenter.shared.show("已保存到相册")
        } catch {
            ToastCenter.shared.show("保存失败：\(error.localizedDescription)", isError: true)
        }
    }
}

/// 单张图片：双指缩放、双击放大、拖动平移。
private struct ZoomableImage: View {
    let url: URL?
    var onSingleTap: () -> Void
    var onDragDown: (CGFloat) -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            RemoteImage(url: url, contentMode: .fit, maxPixelSize: 2400)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = min(max(lastScale * value, 1), 4)
                        }
                        .onEnded { _ in
                            lastScale = scale
                            if scale <= 1.02 {
                                withAnimation(.spring(response: 0.3)) {
                                    scale = 1
                                    lastScale = 1
                                    offset = .zero
                                    lastOffset = .zero
                                }
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            if scale > 1 {
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            } else {
                                onDragDown(value.translation.height)
                            }
                        }
                        .onEnded { _ in
                            if scale > 1 { lastOffset = offset }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.32)) {
                        if scale > 1 {
                            scale = 1
                            lastScale = 1
                            offset = .zero
                            lastOffset = .zero
                        } else {
                            scale = 2.2
                            lastScale = 2.2
                        }
                    }
                }
                .onTapGesture { onSingleTap() }
        }
    }
}

// MARK: - 视频播放

struct VideoPlayerView: View {
    let media: FeedMedia

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                        .onAppear { player.play() }
                } else {
                    VStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("正在准备播放…").font(.footnote).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .navigationTitle(media.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        player?.pause()
                        dismiss()
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .onAppear(perform: prepare)
        .onDisappear { player?.pause() }
    }

    private func prepare() {
        guard let urlString = media.resolvedPlaybackURL(), let url = URL(string: urlString) else {
            ToastCenter.shared.show("该视频暂时无法播放", isError: true)
            return
        }
        configureAudioSession()
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = false
        player = newPlayer
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            // 播放不因此中断，仅失去后台出声能力。
        }
    }
}

// MARK: - 轻量全局提示（无 AppModel 环境时使用）

@MainActor
final class ToastCenter {
    static let shared = ToastCenter()

    private(set) var message: String?
    private(set) var isError = false
    private var task: Task<Void, Never>?

    func show(_ text: String, isError: Bool = false) {
        message = text
        self.isError = isError
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}
