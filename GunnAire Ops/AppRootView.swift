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
    @State private var playbackEndObserver: NSObjectProtocol?
    @State private var playbackFailureObserver: NSObjectProtocol?

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

        // Load and play the first available splash video once (muted).
        // This supports either a bundled asset or a Loading.mp4 dropped into
        // the app's Application Support / Documents directories.
        if let url = SplashVideoLocator.resolveURL() {
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.actionAtItemEnd = .pause
            self.player = player

            playbackEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in
                finishOnce()
            }

            playbackFailureObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in
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
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
            self.playbackEndObserver = nil
        }
        if let playbackFailureObserver {
            NotificationCenter.default.removeObserver(playbackFailureObserver)
            self.playbackFailureObserver = nil
        }
    }
}

enum SplashVideoLocator {
    struct VideoDetails {
        let filename: String
        let fileSizeDescription: String
        let modifiedDescription: String
    }

    static func resolveURL(fileManager: FileManager = .default) -> URL? {
        let bundledURL = Bundle.main.url(forResource: "Loading", withExtension: "mp4")
        let storedCandidates = storedCandidateURLs(fileManager: fileManager)
        return preferredURL(bundledURL: bundledURL, storedCandidates: storedCandidates, fileManager: fileManager)
    }

    static func preferredURL(
        bundledURL: URL?,
        storedCandidates: [URL],
        fileManager: FileManager = .default
    ) -> URL? {
        for candidate in storedCandidates where fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }
        return bundledURL
    }

    static func storedCandidateURLs(fileManager: FileManager = .default) -> [URL] {
        var urls: [URL] = []
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            urls.append(appSupport.appendingPathComponent("Loading.mp4"))
        }
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            urls.append(documents.appendingPathComponent("Loading.mp4"))
        }
        return urls
    }

    static func installVideo(from sourceURL: URL, fileManager: FileManager = .default) throws {
        let destinationURL = try ensureStorageURL(fileManager: fileManager)
        let shouldStopAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if shouldStopAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    static func removeStoredVideo(fileManager: FileManager = .default) throws {
        guard let storedURL = storedCandidateURLs(fileManager: fileManager).first else { return }
        guard fileManager.fileExists(atPath: storedURL.path) else { return }
        try fileManager.removeItem(at: storedURL)
    }

    static func currentSourceDescription(fileManager: FileManager = .default) -> String {
        if let storedURL = storedCandidateURLs(fileManager: fileManager).first,
           fileManager.fileExists(atPath: storedURL.path) {
            return "Custom Loading.mp4"
        }
        if Bundle.main.url(forResource: "Loading", withExtension: "mp4") != nil {
            return "Bundled Loading.mp4"
        }
        return "Logo Fallback"
    }

    static func currentStoredVideoDetails(fileManager: FileManager = .default) -> VideoDetails? {
        guard let storedURL = storedCandidateURLs(fileManager: fileManager).first,
              fileManager.fileExists(atPath: storedURL.path),
              let attributes = try? fileManager.attributesOfItem(atPath: storedURL.path) else {
            return nil
        }

        let byteCount = attributes[.size] as? NSNumber
        let modifiedDate = attributes[.modificationDate] as? Date
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file

        return VideoDetails(
            filename: storedURL.lastPathComponent,
            fileSizeDescription: formatter.string(fromByteCount: byteCount?.int64Value ?? 0),
            modifiedDescription: modifiedDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown"
        )
    }

    private static func ensureStorageURL(fileManager: FileManager) throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("Loading.mp4")
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
