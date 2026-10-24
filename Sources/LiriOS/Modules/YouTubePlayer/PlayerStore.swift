import Foundation
import Observation

/// M2 播放狀態。只存「殼需要知道的最小集合」——
/// 完整的播放 UI 是 YouTube Music 網頁自己的,這裡的狀態主要供生命週期決策與(未來的)緊湊卡片用。
@Observable
@MainActor
final class PlayerStore {

    static let shared = PlayerStore()
    var isPlaying = false
    var title = ""
    var artist = ""
    var artworkURL = ""
    var position: Double = 0
    var duration: Double = 0
    /// 影片是否處於 HTML5 全螢幕(面板在此期間不可自動收合)
    var isFullscreen = false
    /// webview 目前是否存活(供 View 決定顯示播放器還是「載入」佔位)
    var webViewAlive = false
    /// 「影片當桌布」模式:webview 目前在桌面層視窗裡,不在面板
    var isDesktopMode = false

    func reset() {
        isPlaying = false
        title = ""
        artist = ""
        artworkURL = ""
        position = 0
        duration = 0
        isFullscreen = false
        webViewAlive = false
        isDesktopMode = false
    }
}
