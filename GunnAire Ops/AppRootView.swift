import SwiftUI
import AVKit
import AVFoundation

struct AppRootView: View {
    @AppStorage("hasAuthenticatedUser") private var hasAuthenticatedUser = false
    @AppStorage("enableSplashVideo") private var enableSplashVideo = true
    @State private var showingSplash = false

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
        .onAppear {
            if enableSplashVideo && SplashVideoLocator.resolveURL() != nil {
                showingSplash = true
            } else {
                showingSplash = false
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
    @AppStorage("maximumSplashDurationSeconds") private var maximumSplashDurationSeconds = 6.0
    @AppStorage("allowSplashTapToSkip") private var allowSplashTapToSkip = true

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

            if allowSplashTapToSkip {
                VStack {
                    HStack {
                        Spacer()
                        Text("Tap to skip")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding()
                    Spacer()
                }
                .foregroundStyle(.white)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard allowSplashTapToSkip else { return }
            finishImmediately()
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

        // Load and play the first available splash video once (muted).
        // This supports either a bundled asset or a Loading.mp4 dropped into
        // the app's Application Support / Documents directories.
        if let url = SplashVideoLocator.resolveURL() {
            let work = DispatchWorkItem {
                finishOnce()
            }
            timeoutWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + SplashVideoLocator.preferredFinishDelay(
                    for: url,
                    maximumDuration: maximumSplashDurationSeconds
                ),
                execute: work
            )

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
            // Ensure we transition even if no video exists to load.
            let work = DispatchWorkItem {
                finishOnce()
            }
            timeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
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

    private func finishImmediately() {
        guard !didFinish else { return }
        didFinish = true
        cleanup()
        onFinished()
    }
}

enum SplashVideoLocator {
    enum Source {
        case custom
        case bundled
        case fallback

        var description: String {
            switch self {
            case .custom:
                return "Custom Loading.mp4"
            case .bundled:
                return "Bundled Loading.mp4"
            case .fallback:
                return "Logo Fallback"
            }
        }
    }

    struct VideoDetails {
        let filename: String
        let fileSizeDescription: String
        let modifiedDescription: String
        let durationDescription: String?
        let resolutionDescription: String?
        let advisoryMessage: String?
    }

    enum ValidationError: LocalizedError {
        case unsupportedFormat
        case unreadableVideo

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "Only MP4 loading videos are supported."
            case .unreadableVideo:
                return "The selected video could not be read as a playable splash clip."
            }
        }
    }

    static func resolveURL(fileManager: FileManager = .default) -> URL? {
        let bundledURL = Bundle.main.url(forResource: "Loading", withExtension: "mp4")
        let storedCandidates = storedCandidateURLs(fileManager: fileManager)
        return preferredURL(bundledURL: bundledURL, storedCandidates: storedCandidates, fileManager: fileManager)
    }

    static func currentSource(fileManager: FileManager = .default) -> Source {
        if let storedURL = storedCandidateURLs(fileManager: fileManager).first,
           fileManager.fileExists(atPath: storedURL.path) {
            return .custom
        }
        if Bundle.main.url(forResource: "Loading", withExtension: "mp4") != nil {
            return .bundled
        }
        return .fallback
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

    static func installVideo(from sourceURL: URL, fileManager: FileManager = .default) throws -> VideoDetails {
        _ = try inspectVideo(at: sourceURL, fileManager: fileManager)
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
        return try inspectVideo(at: destinationURL, fileManager: fileManager)
    }

    static func removeStoredVideo(fileManager: FileManager = .default) throws {
        guard let storedURL = storedCandidateURLs(fileManager: fileManager).first else { return }
        guard fileManager.fileExists(atPath: storedURL.path) else { return }
        try fileManager.removeItem(at: storedURL)
    }

    static func currentSourceDescription(fileManager: FileManager = .default) -> String {
        currentSource(fileManager: fileManager).description
    }

    static func currentStoredVideoDetails(fileManager: FileManager = .default) -> VideoDetails? {
        guard currentSource(fileManager: fileManager) == .custom else { return nil }
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
        let videoMetrics = inspectVideoMetrics(at: storedURL)

        return VideoDetails(
            filename: storedURL.lastPathComponent,
            fileSizeDescription: formatter.string(fromByteCount: byteCount?.int64Value ?? 0),
            modifiedDescription: modifiedDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown",
            durationDescription: describe(duration: videoMetrics?.durationSeconds),
            resolutionDescription: describe(size: videoMetrics?.pixelSize),
            advisoryMessage: advisoryMessage(forDuration: videoMetrics?.durationSeconds)
        )
    }

    static func currentResolvedVideoDetails(fileManager: FileManager = .default) -> VideoDetails? {
        guard let resolvedURL = resolveURL(fileManager: fileManager) else { return nil }
        return try? inspectVideo(at: resolvedURL, fileManager: fileManager)
    }

    static func preferredFinishDelay(for url: URL, maximumDuration: TimeInterval = 6.0) -> TimeInterval {
        let durationSeconds = inspectVideoMetrics(at: url)?.durationSeconds ?? 0
        return preferredFinishDelay(durationSeconds: durationSeconds, maximumDuration: maximumDuration)
    }

    static func preferredFinishDelay(durationSeconds: TimeInterval, maximumDuration: TimeInterval = 6.0) -> TimeInterval {
        let fallbackDelay: TimeInterval = 3.0
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            return fallbackDelay
        }

        let paddedDuration = durationSeconds + 0.2
        return min(max(paddedDuration, 1.2), max(maximumDuration, 1.2))
    }

    private static func inspectVideo(at url: URL, fileManager: FileManager) throws -> VideoDetails {
        guard url.pathExtension.lowercased() == "mp4" else {
            throw ValidationError.unsupportedFormat
        }

        guard fileManager.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            throw ValidationError.unreadableVideo
        }

        guard let videoMetrics = inspectVideoMetrics(at: url) else {
            throw ValidationError.unreadableVideo
        }

        let byteCount = attributes[.size] as? NSNumber
        let modifiedDate = attributes[.modificationDate] as? Date
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file

        return VideoDetails(
            filename: url.lastPathComponent,
            fileSizeDescription: formatter.string(fromByteCount: byteCount?.int64Value ?? 0),
            modifiedDescription: modifiedDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown",
            durationDescription: describe(duration: videoMetrics.durationSeconds),
            resolutionDescription: describe(size: videoMetrics.pixelSize),
            advisoryMessage: advisoryMessage(forDuration: videoMetrics.durationSeconds)
        )
    }

    private static func inspectVideoMetrics(at url: URL) -> (durationSeconds: TimeInterval, pixelSize: CGSize?)? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: (durationSeconds: TimeInterval, pixelSize: CGSize?)?

        Task {
            defer { semaphore.signal() }

            let asset = AVURLAsset(url: url)

            do {
                let duration = try await asset.load(.duration)
                let isPlayable = try await asset.load(.isPlayable)
                let tracks = try await asset.loadTracks(withMediaType: .video)

                guard isPlayable || !tracks.isEmpty else { return }

                let pixelSize: CGSize?
                if let track = tracks.first {
                    let naturalSize = try await track.load(.naturalSize)
                    let preferredTransform = try await track.load(.preferredTransform)
                    let transformedSize = naturalSize.applying(preferredTransform)
                    pixelSize = CGSize(
                        width: abs(transformedSize.width),
                        height: abs(transformedSize.height)
                    )
                } else {
                    pixelSize = nil
                }

                let durationSeconds = CMTimeGetSeconds(duration)
                result = (durationSeconds, pixelSize)
            } catch {
                result = nil
            }
        }

        semaphore.wait()
        return result
    }

    private static func describe(duration: TimeInterval?) -> String? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        if duration < 10 {
            return String(format: "%.1f seconds", duration)
        }
        return String(format: "%.0f seconds", duration.rounded())
    }

    private static func describe(size: CGSize?) -> String? {
        guard let size, size.width > 0, size.height > 0 else { return nil }
        return "\(Int(size.width.rounded())) x \(Int(size.height.rounded()))"
    }

    private static func advisoryMessage(forDuration duration: TimeInterval?) -> String? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        if duration > 6 {
            return "Long splash videos are trimmed to roughly the first 6 seconds during app launch."
        }
        if duration < 1 {
            return "Very short splash videos may finish before the app is fully visible."
        }
        return nil
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
