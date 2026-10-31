import AppKit

/// Touch Bar 私有 API 的包裝。一般 App 只有在前景時才能顯示 Touch Bar，
/// 要在 Spotify / Music 在前景時也顯示，只能用系統層級（system modal）的 Touch Bar。
/// 這些 API 未公開，不能上架 App Store，未來 macOS 版本也可能失效。
enum PrivateTouchBar {
    private static let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY)

    static func addSystemTrayItem(_ item: NSTouchBarItem) {
        call(on: NSTouchBarItem.self, ["addSystemTrayItem:"], item)
    }

    static func setControlStripPresence(_ id: NSTouchBarItem.Identifier, _ visible: Bool) {
        guard let dfr, let sym = dlsym(dfr, "DFRElementSetControlStripPresenceForIdentifier") else { return }
        typealias Fn = @convention(c) (CFString, Bool) -> Void
        unsafeBitCast(sym, to: Fn.self)(id.rawValue as CFString, visible)
    }

    static func showsCloseBoxWhenFrontMost(_ show: Bool) {
        guard let dfr, let sym = dlsym(dfr, "DFRSystemModalShowsCloseBoxWhenFrontMost") else { return }
        typealias Fn = @convention(c) (Bool) -> Void
        unsafeBitCast(sym, to: Fn.self)(show)
    }

    static func present(_ touchBar: NSTouchBar, trayID: NSTouchBarItem.Identifier) {
        call(on: NSTouchBar.self,
             ["presentSystemModalFunctionBar:systemTrayItemIdentifier:", "presentSystemModalTouchBar:systemTrayItemIdentifier:"],
             touchBar, trayID.rawValue as NSString)
    }

    static func minimize(_ touchBar: NSTouchBar) {
        call(on: NSTouchBar.self, ["minimizeSystemModalFunctionBar:", "minimizeSystemModalTouchBar:"], touchBar)
    }

    /// 不同 macOS 版本的方法名稱不同（FunctionBar / TouchBar），依序嘗試；macOS 15.5 實測為 TouchBar 版本。
    private static func call(on cls: NSObject.Type, _ selectors: [String], _ a: Any, _ b: Any? = nil) {
        for name in selectors {
            let sel = NSSelectorFromString(name)
            guard cls.responds(to: sel) else { continue }
            if let b { _ = cls.perform(sel, with: a, with: b) } else { _ = cls.perform(sel, with: a) }
            return
        }
        NSLog("TouchBarLyrics: 找不到私有 API \(selectors.first ?? "")")
    }
}

final class LyricsTouchBar: NSObject, NSTouchBarDelegate {
    static let trayID = NSTouchBarItem.Identifier("tw.calvin.TouchBarLyrics.tray")
    static let lyricID = NSTouchBarItem.Identifier("tw.calvin.TouchBarLyrics.lyric")

    /// 13 吋 Touch Bar 扣掉 Esc 與關閉鈕後大約可用的寬度（pt）
    private let maxWidth: CGFloat = 880
    private let maxFontSize: CGFloat = 16
    private let minFontSize: CGFloat = 11

    let touchBar = NSTouchBar()
    var onTrayTap: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var trayItem: NSCustomTouchBarItem?

    override init() {
        super.init()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [Self.lyricID]
        touchBar.principalItemIdentifier = Self.lyricID

        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .white
        label.font = .systemFont(ofSize: maxFontSize, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
    }

    /// 在 Control Strip 放一個 ♪ 按鈕，點了會叫出歌詞列。
    func install() {
        let item = NSCustomTouchBarItem(identifier: Self.trayID)
        let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "歌詞")!
        item.view = NSButton(image: image, target: self, action: #selector(trayTapped))
        trayItem = item
        PrivateTouchBar.addSystemTrayItem(item)
        PrivateTouchBar.setControlStripPresence(Self.trayID, true)
        PrivateTouchBar.showsCloseBoxWhenFrontMost(true)
    }

    func present() { PrivateTouchBar.present(touchBar, trayID: Self.trayID) }
    func minimize() { PrivateTouchBar.minimize(touchBar) }

    func setText(_ text: String) {
        guard label.stringValue != text else { return }
        label.font = fittingFont(for: text)
        label.stringValue = text
    }

    /// 長句先縮小字級，縮到最小還放不下才截斷。
    private func fittingFont(for text: String) -> NSFont {
        var size = maxFontSize
        while size > minFontSize {
            let font = NSFont.systemFont(ofSize: size, weight: .medium)
            if (text as NSString).size(withAttributes: [.font: font]).width <= maxWidth - 8 { return font }
            size -= 1
        }
        return .systemFont(ofSize: minFontSize, weight: .medium)
    }

    @objc private func trayTapped() { onTrayTap?() }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == Self.lyricID else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = label
        return item
    }
}
