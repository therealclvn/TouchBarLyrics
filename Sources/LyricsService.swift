import Foundation
import CryptoKit

struct Lyrics: Codable {
    var source: String
    var synced: String?
    var plain: String?
    var instrumental: Bool = false
}

/// 依序查 LRCLIB、網易雲、QQ 音樂；含中日韓文字的歌優先查中國的兩個來源。
final class LyricsService {
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.httpAdditionalHeaders = ["User-Agent": "TouchBarLyrics/0.1 (personal macOS app)"]
        return URLSession(configuration: config)
    }()
    private let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TouchBarLyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func removeCache(for track: Track) {
        try? FileManager.default.removeItem(at: cacheFile(for: track))
    }

    func fetch(_ track: Track) async -> Lyrics? {
        let cacheFile = cacheFile(for: track)
        if let data = try? Data(contentsOf: cacheFile),
           let cached = try? JSONDecoder().decode(Lyrics.self, from: data) {
            return cached
        }

        let providers: [(Track) async -> Lyrics?] = containsCJK(track.title + track.artist)
            ? [netease, qqmusic, lrclib]
            : [lrclib, netease, qqmusic]

        var fallback: Lyrics?
        for provider in providers {
            guard let result = await provider(track) else { continue }
            if result.synced != nil || result.instrumental {
                save(result, to: cacheFile)
                return result
            }
            fallback = fallback ?? result // 只有純文字歌詞，先留著，繼續找同步版
        }
        if let fallback { save(fallback, to: cacheFile) }
        return fallback
    }

    // MARK: LRCLIB

    private struct LRCLibItem: Decodable {
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private func lrclib(_ track: Track) async -> Lyrics? {
        let seconds = track.durationMs / 1000
        var get = URLComponents(string: "https://lrclib.net/api/get")!
        get.queryItems = [
            .init(name: "track_name", value: track.title),
            .init(name: "artist_name", value: track.artist),
            .init(name: "album_name", value: track.album),
            .init(name: "duration", value: String(seconds)),
        ]
        if let item: LRCLibItem = await getJSON(get.url!), let lyrics = convert(item) {
            return lyrics
        }

        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [
            .init(name: "track_name", value: cleanTitle(track.title)),
            .init(name: "artist_name", value: track.artist),
        ]
        guard let items: [LRCLibItem] = await getJSON(search.url!) else { return nil }
        let close = items.filter { abs(($0.duration ?? 0) - Double(seconds)) < 5 }
        let best = close.first(where: { $0.syncedLyrics != nil }) ?? close.first
        return best.flatMap(convert)
    }

    private func convert(_ item: LRCLibItem) -> Lyrics? {
        if item.instrumental == true { return Lyrics(source: "LRCLIB", instrumental: true) }
        guard item.syncedLyrics != nil || item.plainLyrics != nil else { return nil }
        return Lyrics(source: "LRCLIB", synced: item.syncedLyrics, plain: item.plainLyrics)
    }

    // MARK: 網易雲音樂（非官方公開介面）

    private struct NESearch: Decodable {
        struct Result: Decodable { let songs: [Song]? }
        struct Song: Decodable {
            let id: Int
            let name: String
            let duration: Int?
            let artists: [Artist]?
        }
        struct Artist: Decodable { let name: String }
        let result: Result?
    }

    private struct NELyric: Decodable {
        struct Lrc: Decodable { let lyric: String? }
        let lrc: Lrc?
        let nolyric: Bool?
    }

    private func netease(_ track: Track) async -> Lyrics? {
        var search = URLComponents(string: "https://music.163.com/api/search/get")!
        search.queryItems = [
            .init(name: "s", value: "\(cleanTitle(track.title)) \(track.artist)"),
            .init(name: "type", value: "1"),
            .init(name: "limit", value: "10"),
        ]
        guard let result: NESearch = await getJSON(search.url!),
              let songs = result.result?.songs, !songs.isEmpty else { return nil }

        func score(_ s: NESearch.Song) -> Int {
            matchScore(track, s.name, (s.artists ?? []).map(\.name), s.duration ?? 0)
        }
        guard let best = songs.max(by: { score($0) < score($1) }), score(best) >= 4 else { return nil }

        var lyricURL = URLComponents(string: "https://music.163.com/api/song/lyric")!
        lyricURL.queryItems = [.init(name: "id", value: String(best.id)), .init(name: "lv", value: "1")]
        guard let lyric: NELyric = await getJSON(lyricURL.url!) else { return nil }
        if lyric.nolyric == true { return Lyrics(source: "網易雲", instrumental: true) }
        guard let text = lyric.lrc?.lyric, !text.isEmpty else { return nil }
        // 網易雲部分歌曲開頭會夾帶 JSON 格式的製作人員資訊，直接濾掉
        let cleaned = text.components(separatedBy: "\n").filter { !$0.hasPrefix("{") }.joined(separator: "\n")
        return Lyrics(source: "網易雲", synced: cleaned)
    }

    // MARK: QQ 音樂（非官方公開介面）

    private struct QQSmartbox: Decodable {
        struct DataBody: Decodable { let song: Songs? }
        struct Songs: Decodable { let itemlist: [Song]? }
        struct Song: Decodable {
            let mid: String
            let name: String
            let singer: String
        }
        let data: DataBody?
    }

    private struct QQLyric: Decodable { let lyric: String? }

    private func qqmusic(_ track: Track) async -> Lyrics? {
        // 完整搜尋介面（musicu.fcg）未登入時常被限流，改用輸入提示用的 smartbox，結果較少但穩定
        var search = URLComponents(string: "https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg")!
        search.queryItems = [.init(name: "key", value: "\(cleanTitle(track.title)) \(track.artist)"), .init(name: "format", value: "json")]
        guard let result: QQSmartbox = await getJSON(search.url!),
              let songs = result.data?.song?.itemlist, !songs.isEmpty else { return nil }

        func score(_ s: QQSmartbox.Song) -> Int { matchScore(track, s.name, [s.singer], nil) }
        // 沒有歌曲長度可比對，要求曲名與歌手都完全相符
        guard let best = songs.max(by: { score($0) < score($1) }), score(best) >= 6 else { return nil }

        var lyricURL = URLComponents(string: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg")!
        lyricURL.queryItems = [.init(name: "songmid", value: best.mid), .init(name: "format", value: "json"), .init(name: "nobase64", value: "1")]
        guard let lyric: QQLyric = await getJSON(lyricURL.url!), let text = lyric.lyric, text.contains("[") else { return nil }
        return Lyrics(source: "QQ 音樂", synced: decodeEntities(text))
    }

    /// QQ 音樂歌詞偶爾會用 &#58; 這類 HTML 實體表示標點
    private func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        let regex = try! NSRegularExpression(pattern: "&#(\\d+);")
        for m in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: out), let code = Int((s as NSString).substring(with: m.range(at: 1))),
                  let scalar = Unicode.Scalar(code) else { continue }
            out.replaceSubrange(r, with: String(Character(scalar)))
        }
        return out.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }

    // MARK: 工具

    /// 曲名完全相同 +3、部分相同 +1；歌手相符 +3；長度差 3 秒內 +2、10 秒內 +1。至少 4 分才採用，避免抓到翻唱版。
    private func matchScore(_ track: Track, _ name: String, _ artists: [String], _ durationMs: Int?) -> Int {
        let wantTitle = normalize(cleanTitle(track.title))
        let wantArtist = normalize(track.artist)
        var score = 0
        let got = normalize(name)
        if got == wantTitle { score += 3 } else if got.contains(wantTitle) || wantTitle.contains(got) { score += 1 }
        if artists.map(normalize).contains(where: { !$0.isEmpty && (wantArtist.contains($0) || $0.contains(wantArtist)) }) { score += 3 }
        guard let durationMs else { return score }
        let diff = abs(durationMs - track.durationMs)
        if diff < 3000 { score += 2 } else if diff < 10000 { score += 1 }
        return score
    }

    private func getJSON<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url)
        if url.host?.contains("163.com") == true {
            request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        } else if url.host?.contains("qq.com") == true {
            request.setValue("https://y.qq.com", forHTTPHeaderField: "Referer")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            NSLog("TouchBarLyrics: 請求失敗 \(url.host ?? "") \(error.localizedDescription)")
            return nil
        }
    }

    private func save(_ lyrics: Lyrics, to file: URL) {
        if let data = try? JSONEncoder().encode(lyrics) { try? data.write(to: file) }
    }

    private func cacheFile(for t: Track) -> URL {
        let raw = "\(t.title)|\(t.artist)|\(t.durationMs / 1000)"
        let key = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent(key + ".json")
    }

    /// 去掉 " - Remastered 2011"、"(feat. X)"、"[Live]" 這類尾綴，提高搜尋命中率。
    private func cleanTitle(_ title: String) -> String {
        var t = title
        if let r = t.range(of: " - ") { t = String(t[..<r.lowerBound]) }
        t = t.replacingOccurrences(of: #"\s*[\(\[（【][^\)\]）】]*[\)\]）】]"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces).isEmpty ? title : t.trimmingCharacters(in: .whitespaces)
    }

    /// 比對用：轉簡體、小寫、去標點空白。
    private func normalize(_ s: String) -> String {
        let simplified = s.applyingTransform(StringTransform("Hans-Hant"), reverse: true) ?? s
        return simplified.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    private func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value)
        }
    }
}
