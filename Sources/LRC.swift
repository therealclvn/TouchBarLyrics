import Foundation

struct LyricLine {
    let time: Double
    let text: String
}

enum LRCParser {
    private static let stamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)
    private static let offsetTag = try! NSRegularExpression(pattern: #"^\[offset:\s*([+-]?\d+)\]"#, options: .caseInsensitive)

    /// 解析 LRC，支援一行多個時間標籤與 [offset:]。
    static func parse(_ source: String) -> [LyricLine] {
        var offset = 0.0
        var lines: [LyricLine] = []

        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)

            if let m = offsetTag.firstMatch(in: line, range: full) {
                offset = (Double(ns.substring(with: m.range(at: 1))) ?? 0) / 1000
                continue
            }

            var times: [Double] = []
            var cursor = 0
            while let m = stamp.firstMatch(in: line, range: NSRange(location: cursor, length: ns.length - cursor)),
                  m.range.location == cursor {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                times.append(min * 60 + sec)
                cursor = m.range.location + m.range.length
            }
            guard !times.isEmpty else { continue }

            let text = ns.substring(from: cursor).trimmingCharacters(in: .whitespaces)
            for t in times {
                // LRC 的 offset 正值代表歌詞提前出現
                lines.append(LyricLine(time: max(0, t - offset), text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// 回傳 position 秒時應該顯示的那一行索引。
    static func index(in lines: [LyricLine], at position: Double) -> Int? {
        var lo = 0, hi = lines.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= position { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }
}
