import SwiftUI
import AVKit
import AVFoundation

struct SplashView: View {
    @AppStorage("hasAuthenticatedUser") private var hasAuthenticatedUser: Bool = false
    @State private var player: AVPlayer? = nil
    @State private var videoEnded: Bool = false
    @State private var showNextView: Bool = false
    @State private var opacity: Double = 1.0

    private let timeout: TimeInterval = 3.0

    var body: some View {
        Group {
            if showNextView {
                if hasAuthenticatedUser {
                    ContentView()
                        .transition(.opacity)
                } else {
                    LoginView()
                        .transition(.opacity)
                }
            } else {
                ZStack {
                    if let player = player {
                        VideoPlayer(player: player)
                            .onAppear {
                                player.play()
                                addObservers(to: player)
                            }
                            .onDisappear {
                                removeObservers()
                            }
                            .accessibilityLabel("Loading")
                            .ignoresSafeArea()
                            .opacity(opacity)
                    } else {
                        Image("AppLogo")
                            .resizable()
                            .scaledToFill()
                            .ignoresSafeArea()
                            .accessibilityLabel("Loading")
                            .opacity(opacity)
                    }
                }
            }
        }
    }

    // MARK: - Observers

    private func addObservers(to player: AVPlayer) {
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            videoEnded = true
            fadeOutAndTransition()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if !videoEnded {
                fadeOutAndTransition()
            }
        }
    }

    private func removeObservers() {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Transition

    private func fadeOutAndTransition() {
        withAnimation(.easeOut(duration: 0.6)) {
            opacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            showNextView = true
        }
    }

    // MARK: - Init

    init() {
        if let url = Bundle.main.url(forResource: "Loading", withExtension: "mp4") {
            let playerItem = AVPlayerItem(url: url)
            let avPlayer = AVPlayer(playerItem: playerItem)
            avPlayer.isMuted = true
            avPlayer.actionAtItemEnd = .pause
            self._player = State(initialValue: avPlayer)
        } else {
            self._player = State(initialValue: nil)
        }
    }
}


// Dummy placeholders for LoginView and ContentView to make this file self-contained.
struct LoginView: View {
    var body: some View {
        Text("Login View")
            .font(.largeTitle)
    }
}

struct ContentView: View {
    var body: some View {
        Text("Content View")
            .font(.largeTitle)
    }
}

struct SplashView_Previews: PreviewProvider {
    static var previews: some View {
        SplashView()
    }
}
