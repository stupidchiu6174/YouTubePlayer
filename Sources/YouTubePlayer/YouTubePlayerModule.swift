import SwiftUI

/// 對外的入口:一個 View + setActive。主程式把 moduleView 放進自己的視窗或面板。
@MainActor
public final class YouTubePlayerModule {

    /// HTML5 全螢幕開關時呼叫(主程式可以趁機暫停自己的自動收合)
    public static var onFullscreenChange: (Bool) -> Void = { _ in }
    /// 影片當桌布開關時呼叫(主程式可以趁機藏起自己的桌面小工具)
    public static var onDesktopModeChange: (Bool) -> Void = { _ in }

    private let store = PlayerStore.shared
    private let web: WebViewController

    public init() {
        web = WebViewController(store: store)
    }

    public var moduleView: AnyView {
        AnyView(YouTubePlayerView(store: store, controller: web))
    }

    /// 看得到 → webview(若存活)保住;看不到 → 交給 controller 判斷:
    /// 播放中保留、閒置倒數銷毀。模組自身沒有任何 timer。
    public func setActive(_ active: Bool) {
        web.panelActive = active
    }

    /// 影片當桌布:把正在播的影片搬到桌面層,從原本的秒數接著播;再呼叫一次搬回來
    public func toggleDesktopMode() {
        web.toggleDesktopMode()
    }
}
