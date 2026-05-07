import SwiftUI
import AVKit
import AVFoundation

struct AppRootView: View {
    @AppStorage("hasAuthenticatedUser") private var hasAuthenticatedUser = false
    @State private var showingSplash = true

    var body: some View {
        ZStack {
            if showingSplash {
                VideoSplashView {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        showingSplash = false
                    }
                }
                .transition(.opacity)
            } else {
                if hasAuthenticatedUser {
                    ContentView()
                        .transition(.opacity)
                } else {
                    LoginView(hasAuthenticatedUser: $hasAuthenticatedUser)
                        .transition(.opacity)
                }
            }
        }
    }
}

private struct VideoSplashView: View {
    let onFinished: () -> Void

    @State private var player: AVPlayer?
    @State private var didFinish = false
    @State private var timeoutWork: DispatchWorkItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                PlayerLayerView(player: player)
                    .ignoresSafeArea()
                    .accessibilityLabel("Loading")
            } else {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240)
                    .opacity(0.9)
                    .accessibilityHidden(true)
            }
        }
        .onAppear(perform: start)
        .onDisappear(perform: cleanup)
    }

    private func start() {
        let finishOnce: () -> Void = {
            if !didFinish {
                didFinish = true
                onFinished()
            }
        }

        // Ensure we transition even if the video fails to load
        let work = DispatchWorkItem {
            finishOnce()
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)

        // Load and play the bundled splash video once (muted)
        if let url = Bundle.main.url(forResource: "Loading", withExtension: "mp4") {
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.actionAtItemEnd = .pause
            self.player = player

            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
                finishOnce()
            }

            player.play()
        } else {
            // No video found; briefly show the logo then proceed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                finishOnce()
            }
        }
    }

    private func cleanup() {
        timeoutWork?.cancel()
        timeoutWork = nil
        player?.pause()
        NotificationCenter.default.removeObserver(self)
    }
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
