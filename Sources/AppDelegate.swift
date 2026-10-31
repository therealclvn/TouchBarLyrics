import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = NowPlayingMonitor()
    private let service = LyricsService()
    private let bar = LyricsTouchBar()
    private var statusItem: NSStatusItem!
    private var displayTimer: Timer?

    private var track: Track?
    private var lyrics: Lyrics?
    private var lines: [LyricLine] = []
    private var isLoading = false

    private let defaults = UserDefaults.standard
    private var offset: Double {
        get { defaults.double(forKey: "offset") }
        set { defaults.set(newValue, forKey: "offset") }
    }
    private var autoPresent: Bool { defaults.bool(forKey: "autoPresent") }
    private var traditional: Bool { defaults.bool(forKey: "traditional") }
    private var showInMenuBar: Bool { defaults.bool(forKey: "showInMenuBar") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["autoPresent": true, "traditional": true, "showInMenuBar": false])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: "Touch Bar 歌詞")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        bar.onTrayTap = { [weak self] in self?.bar.present() }
        bar.install()
        bar.setText("♪ 等待播放中的音樂…")

        monitor.onUpdate = { [weak self] snapshot in self?.handle(snapshot) }
        monitor.start()

        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.refreshDisplay() }
    }

    // MARK: 播放狀態

    private func handle(_ snapshot: PlaybackSnapshot?) {
        guard let snapshot else {
            if track != nil { track = nil; lyrics = nil; lines = [] }
            return
        }
        guard snapshot.track != track else { return }

        track = snapshot.track
        lyrics = nil
        lines = []
        isLoading = true
        if autoPresent && snapshot.isPlaying { bar.present() }

        let wanted = snapshot.track
        Task { @MainActor in
            let result = await service.fetch(wanted)
            guard self.track == wanted else { return } // 抓完時已經換歌
            self.isLoading = false
            self.lyrics = result
            self.reparse()
        }
    }

    private func reparse() {
        guard let synced = lyrics?.synced else { lines = []; return }
        let text = traditional ? (synced.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? synced) : synced
        lines = LRCParser.parse(text)
    }

    // MARK: 顯示

    private func currentText() -> String {
        guard let track, let snapshot = monitor.snapshot else { return "♪ 沒有播放中的音樂" }
        let header = "\(track.title) — \(track.artist)"
        if isLoading { return "\(header)　搜尋歌詞中…" }
        guard let lyrics else { return "\(header)　找不到歌詞" }
        if lyrics.instrumental { return "♪ \(header)（純音樂）" }
        guard !lines.isEmpty else { return "\(header)　只有未同步歌詞" }

        guard let i = LRCParser.index(in: lines, at: snapshot.currentPosition + offset) else { return header }
        let text = lines[i].text
        return text.isEmpty ? "♪" : text
    }

    private func refreshDisplay() {
        let text = currentText()
        bar.setText(text)
        if showInMenuBar, track != nil {
            let short = text.count > 40 ? String(text.prefix(40)) + "…" : text
            if statusItem.button?.title != short { statusItem.button?.title = " " + short }
        } else if statusItem.button?.title.isEmpty == false {
            statusItem.button?.title = ""
        }
    }

    // MARK: 選單

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let track {
            menu.addItem(disabled("\(track.title) — \(track.artist)"))
            let source = isLoading ? "搜尋中…" : (lyrics.map { "來源：\($0.source)\($0.synced == nil ? "（無同步）" : "")" } ?? "找不到歌詞")
            menu.addItem(disabled("\(track.player.rawValue)・\(source)"))
        } else {
            menu.addItem(disabled("沒有播放中的音樂"))
        }
        menu.addItem(.separator())

        menu.addItem(item("在 Touch Bar 顯示歌詞", #selector(showBar), key: "l"))
        menu.addItem(item("收起 Touch Bar 歌詞", #selector(hideBar)))
        menu.addItem(.separator())

        menu.addItem(disabled(String(format: "歌詞時間偏移：%+.1f 秒", offset)))
        menu.addItem(item("歌詞提早 0.5 秒", #selector(offsetEarlier), key: "]"))
        menu.addItem(item("歌詞延後 0.5 秒", #selector(offsetLater), key: "["))
        menu.addItem(item("重設偏移", #selector(offsetReset)))
        menu.addItem(.separator())

        menu.addItem(toggle("換歌時自動彈出", "autoPresent"))
        menu.addItem(toggle("簡體轉繁體", "traditional"))
        menu.addItem(toggle("同時在選單列顯示歌詞", "showInMenuBar"))
        menu.addItem(item("重新抓取這首歌詞", #selector(refetch)))
        menu.addItem(.separator())
        menu.addItem(item("結束", #selector(quit), key: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func toggle(_ title: String, _ key: String) -> NSMenuItem {
        let i = item(title, #selector(toggleSetting(_:)))
        i.representedObject = key
        i.state = defaults.bool(forKey: key) ? .on : .off
        return i
    }

    @objc private func showBar() { bar.present() }
    @objc private func hideBar() { bar.minimize() }
    @objc private func offsetEarlier() { offset += 0.5 }
    @objc private func offsetLater() { offset -= 0.5 }
    @objc private func offsetReset() { offset = 0 }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleSetting(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        defaults.set(!defaults.bool(forKey: key), forKey: key)
        if key == "traditional" { reparse() }
    }

    @objc private func refetch() {
        guard let track else { return }
        service.removeCache(for: track)
        self.track = nil // 讓下一次輪詢視為換歌，重新抓取
        monitor.poll()
    }
}
