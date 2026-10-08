import SwiftUI

/// M2 模組入口。對殼只暴露模組契約:一個 View + setActive。
@MainActor
final class YouTubePlayerModule: PanelModule {

    private let store = PlayerStore.shared
    private let web: WebViewController

    init() {
        web = WebViewController(store: store)
    }

    var moduleView: AnyView {
        AnyView(YouTubePlayerView(store: store, controller: web))
    }

    /// 展開 → webview(若存活)保住;收合 → 交給 controller 判斷:
    /// 播放中保留、閒置倒數銷毀。模組自身沒有任何 timer。
    func setActive(_ active: Bool) {
        web.panelActive = active
    }
}
