# YouTubePlayer

macOS 的 YouTube 播放器模組,可以把影片當成桌布:正在播的影片直接搬到桌面層(在桌面圖示底下),從原本的秒數接著播,不重新載入;再按一次搬回視窗。多螢幕和影片全螢幕都有處理,看不到又沒在播時會釋放網頁,不佔記憶體。

用的是 `WKWebView` 開 YouTube 網頁,登入和播放都由 YouTube 自己處理,不下載影片。**非 YouTube 官方專案,與 Google 無關,請自行遵守 YouTube 服務條款。**

## 需求

macOS 26 以上、Swift 6.2。

## 使用

```bash
swift run YouTubePlayerApp
```

也可以當函式庫用,把畫面放進你自己的視窗或面板:

```swift
import YouTubePlayer

let player = YouTubePlayerModule()
YouTubePlayerModule.onDesktopModeChange = { on in /* 藏起你的桌面小工具 */ }
window.contentView = NSHostingView(rootView: player.moduleView)
player.setActive(true)      // 看不到時傳 false
player.toggleDesktopMode()
```

原本是 LiriOS 側面板的一部分,程式裡的「面板」指的是放播放器的視窗。
