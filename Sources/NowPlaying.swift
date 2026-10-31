import AppKit

enum Player: String, CaseIterable {
    case spotify = "Spotify"
    case music = "Apple Music"

    var bundleID: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .music: return "com.apple.Music"
        }
    }

    /// 回傳以 linefeed 分隔的：狀態、曲名、歌手、專輯、長度(ms)、位置(ms)。
    /// 位置一律轉成整數毫秒，避免不同地區小數點符號造成解析錯誤。
    var scriptSource: String {
        let duration: String
        switch self {
        case .spotify: duration = "((duration of t) as integer)" // Spotify 本身就是 ms
        case .music: duration = "(((duration of t) * 1000) as integer)"
        }
        return """
        tell application id "\(bundleID)"
            set pState to player state as string
            if pState is "stopped" then return "stopped"
            set t to current track
            return pState & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & \(duration) & linefeed & (((player position) * 1000) as integer)
        end tell
        """
    }
}

struct Track: Equatable {
    let player: Player
    let title: String
    let artist: String
    let album: String
    let durationMs: Int
}

struct PlaybackSnapshot {
    let track: Track
    let positionMs: Int
    let isPlaying: Bool
    let fetchedAt: Date

    /// 以上次讀取的位置加上經過時間推算目前秒數，讓顯示比輪詢更順。
    var currentPosition: Double {
        let base = Double(positionMs) / 1000
        return isPlaying ? base + Date().timeIntervalSince(fetchedAt) : base
    }
}

/// 透過 AppleScript 讀取 Spotify / Apple Music 的播放狀態。
final class NowPlayingMonitor: NSObject {
    var onUpdate: ((PlaybackSnapshot?) -> Void)?
    private(set) var snapshot: PlaybackSnapshot?
    private var scripts: [Player: NSAppleScript] = [:]
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        let center = DistributedNotificationCenter.default()
        for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo"] {
            center.addObserver(self, selector: #selector(playerChanged), name: .init(name), object: nil)
        }
        poll()
    }

    @objc private func playerChanged(_ note: Notification) {
        // 通知可能比 AppleScript 狀態更新早一點，稍等再讀。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.poll() }
    }

    func poll() {
        var results: [PlaybackSnapshot] = []
        for player in Player.allCases where isRunning(player) {
            if let s = query(player) { results.append(s) }
        }
        let chosen = results.first(where: \.isPlaying)
            ?? results.first(where: { $0.track.player == snapshot?.track.player })
            ?? results.first
        snapshot = chosen
        onUpdate?(chosen)
    }

    private func isRunning(_ player: Player) -> Bool {
        // 一定要先確認，否則 tell application 會把沒開的 App 叫起來。
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty
    }

    private func query(_ player: Player) -> PlaybackSnapshot? {
        let script: NSAppleScript
        if let cached = scripts[player] {
            script = cached
        } else {
            guard let s = NSAppleScript(source: player.scriptSource) else { return nil }
            var err: NSDictionary?
            guard s.compileAndReturnError(&err) else {
                NSLog("TouchBarLyrics: \(player.rawValue) AppleScript 編譯失敗 \(err ?? [:])")
                return nil
            }
            scripts[player] = s
            script = s
        }

        var err: NSDictionary?
        let output = script.executeAndReturnError(&err)
        if let err {
            NSLog("TouchBarLyrics: \(player.rawValue) AppleScript 錯誤 \(err)")
            return nil
        }
        guard let text = output.stringValue else { return nil }
        let parts = text.components(separatedBy: "\n")
        guard parts.count >= 6, parts[0] != "stopped" else { return nil }

        let track = Track(player: player,
                          title: parts[1],
                          artist: parts[2],
                          album: parts[3],
                          durationMs: Int(parts[4]) ?? 0)
        guard !track.title.isEmpty else { return nil }
        return PlaybackSnapshot(track: track,
                                positionMs: Int(parts[5]) ?? 0,
                                isPlaying: parts[0] == "playing",
                                fetchedAt: Date())
    }
}
