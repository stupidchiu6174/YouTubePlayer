import AppKit
import WebKit

/// M2 的核心:WKWebView 生命週期管理(SPEC 4.2 路線 B,Q5 定案為完整播放器)。
///
/// 效能契約(效能預算 2.5 的唯一例外,已與使用者確認):
/// - 「播放中」收合面板 → webview 保留,音樂續播(記憶體 100–200MB,只在播放時)
/// - 「未播放」且面板收合 → 倒數 teardownDelay 後銷毀 webview,記憶體歸零、CPU 回到 0.0%
/// - 面板展開中永不銷毀
@MainActor
final class WebViewController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    /// 桌面媒體卡的控制入口(單一 webview,弱參照)
    static weak var current: WebViewController?

    private let store: PlayerStore
    private(set) var webView: WKWebView?
    private weak var container: NSView?
    private var teardownTimer: Timer?
    /// 「影片當桌布」模式的桌面層視窗與螢幕變更監聽(見 DesktopVideoMode.swift)
    var desktopWindow: DesktopVideoWindow?
    var desktopScreenObserver: NSObjectProtocol?

    /// 暫停後多久銷毀 webview(秒)
    /// 桌面版 YouTube 的頁面比手機版重得多(完整 polymer app + 首頁無限捲動的縮圖),
    /// 收合後留著它純粹是浪費記憶體與背景 timer → 從 5 分鐘縮短到 90 秒。
    var teardownDelay: TimeInterval = 90

    /// 面板展開/收合狀態,由模組的 setActive 餵進來
    var panelActive = false {
        didSet { evaluateTeardown() }
    }

    private static let homeURL = URL(string: "https://www.youtube.com")!
    /// 面板內的版面縮放(全螢幕時恢復 1.0,否則播放器控制列在大螢幕上會偏小)
    static let panelZoom: CGFloat = 0.8
    private static let lastWatchKey = "yt.lastWatch"

    init(store: PlayerStore) {
        self.store = store
        super.init()
        WebViewController.current = self
    }

    // MARK: - 建立 / 銷毀

    @discardableResult
    func ensureWebView() -> WKWebView {
        if let webView { return webView }

        let config = WKWebViewConfiguration()
        // 登入狀態(Premium 帳號)跨啟動保留
        config.websiteDataStore = .default()
        // 允許無使用者手勢的自動播放(切歌、佇列連播)
        config.mediaTypesRequiringUserActionForPlayback = []
        // HTML5 全螢幕在 macOS 的 WKWebView 預設關閉——不開這個,
        // YouTube 播放器右下角的全螢幕鍵按下去完全沒反應
        config.preferences.isElementFullscreenEnabled = true
        config.userContentController.add(self, name: "media")
        // YT 把音量/靜音狀態存在 localStorage 的 yt-player-volume,播放器初始化時讀取;
        // 在頁面任何 script 跑之前把它種成「不靜音、音量 100」,從源頭杜絕靜音起播。
        config.userContentController.addUserScript(WKUserScript(
            source: Self.volumeSeedJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        config.userContentController.addUserScript(WKUserScript(
            source: Self.mediaBridgeJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))

        let wv = FirstMouseWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        // 圓角直接做在 layer 上(取代 SwiftUI clipShape 的 mask layer,見 YouTubePlayerView)
        wv.wantsLayer = true
        wv.layer?.cornerRadius = 17
        wv.layer?.cornerCurve = .continuous
        wv.layer?.masksToBounds = true
        // 桌面版 Safari UA:改用桌面版播放器。手機版播放器是為觸控設計的——
        // 進度條又細又要先點一下才出現、沒有 hover 拖曳、全螢幕控制列的邏輯也是觸控那套,
        // 用滑鼠操作處處卡手。桌面版是滑鼠原生:hover 進度條可直接拖、控制列 3 秒自動隱藏、
        // 游標自動隱藏、空白鍵/方向鍵/f 等快捷鍵全部可用。
        // 版面用 pageZoom 縮到 0.8,440pt 的面板等於 550 CSS px,桌面版在這個寬度會切成單欄。
        // (想換回手機版:UA 改回 iPhone 字串、pageZoom 設 1 即可)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        wv.pageZoom = Self.panelZoom
        wv.load(URLRequest(url: Self.homeURL))

        webView = wv
        store.webViewAlive = true
        attachIfPossible()
        return wv
    }

    func destroyWebView() {
        cancelTeardown()
        exitDesktopMode()
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "media")
        webView?.removeFromSuperview()
        webView = nil
        store.reset()
    }

    /// 手動重整 / 回首頁(面板工具列用)
    func reload() { webView?.reload() }
    func goHome() { webView?.load(URLRequest(url: Self.homeURL)) }

    /// 網頁內容行程被系統回收(記憶體壓力)時 webview 會變成空殼——自動復活。
    /// 這就是「突然無法播放、頁面剩框架」的典型原因。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        store.isPlaying = false
        if store.isFullscreen {
            // 全螢幕中途死掉:旗標不清就會永遠禁止面板收合
            store.isFullscreen = false
            PanelController.shared.setFullscreenMode(false)
        }
        webView.reload()
    }

    /// 桌布模式中頁面重新載入(行程被回收、手動重整)會丟掉注入的版面,載完再套一次
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyDesktopLayout()
    }

    // MARK: - 播放控制(桌面媒體卡用)

    func togglePlayPause() {
        webView?.evaluateJavaScript(
            "(function(){const v=document.querySelector('video');if(!v)return;if(v.paused){v.play();if(window.__spUnmute){window.__spUnmute();setTimeout(window.__spUnmute,400);}}else{v.pause();}})()"
        )
    }

    func nextTrack() {
        webView?.evaluateJavaScript(
            """
            (function(){
              const b = document.querySelector('.ytp-next-button')
                     || document.querySelector('ytmusic-player-bar .next-button')
                     || document.querySelector('.next-button');
              if (b) { b.click(); return; }
              const v = document.querySelector('video');
              if (v && isFinite(v.duration)) { v.currentTime = v.duration - 0.1; }
            })()
            """
        )
    }

    /// 有記住上次看的影片嗎?(桌面卡用來決定要不要順便開側面板選片)
    var hasResumeTarget: Bool {
        UserDefaults.standard.string(forKey: Self.lastWatchKey) != nil
    }

    /// 桌面媒體卡「直連 YT」:webview 沒活著就建起來,載入完成後自動接續上次的播放清單。
    func resumePlayback() {
        if let wv = webView {
            tryResume(wv, attemptsLeft: 2)
            return
        }
        let wv = ensureWebView()
        // 記得上次看的影片就直接載它,YouTube 首頁沒有「接續」入口
        if let last = UserDefaults.standard.string(forKey: Self.lastWatchKey),
           let url = URL(string: last) {
            wv.load(URLRequest(url: url))
        }
        tryResume(wv, attemptsLeft: 12)
    }

    private func tryResume(_ wv: WKWebView, attemptsLeft: Int) {
        wv.evaluateJavaScript(
            """
            (function(){
              const v = document.querySelector('video');
              if (v) {
                if (v.paused) v.play();
                if (window.__spUnmute) { window.__spUnmute(); setTimeout(window.__spUnmute, 400); }
                return true;
              }
              const b = document.querySelector('#play-pause-button')
                     || document.querySelector('ytmusic-player-bar .play-pause-button');
              if (b) { b.click(); return true; }
              return false;
            })()
            """
        ) { [weak self] result, _ in
            let ok = (result as? Bool) ?? false
            guard !ok, attemptsLeft > 1 else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, let wv = self.webView else { return }
                self.tryResume(wv, attemptsLeft: attemptsLeft - 1)
            }
        }
    }

    func previousTrack() {
        webView?.evaluateJavaScript(
            """
            (function(){
              const b = document.querySelector('.ytp-prev-button')
                     || document.querySelector('ytmusic-player-bar .previous-button')
                     || document.querySelector('.previous-button');
              if (b) { b.click(); return; }
              const v = document.querySelector('video');
              if (v) { v.currentTime = 0; }
            })()
            """
        )
    }

    // MARK: - View 掛載(WebViewContainer 呼叫)

    func attach(to view: NSView) {
        container = view
        attachIfPossible()
    }

    /// 桌布模式結束後,把 webview 掛回面板容器
    func reattachToPanel() { attachIfPossible() }

    private func attachIfPossible(retry: Int = 0) {
        // 桌布模式中 webview 屬於桌面視窗,面板容器 update 時不可搶回來
        guard !store.isDesktopMode,
              let webView, let container, webView.superview !== container else { return }
        // WebKit 退出全螢幕的動畫還沒跑完時 webview 仍在它的全螢幕視窗裡;
        // 這時硬把它搬回來,WebKit 的搬回流程會失敗,全螢幕視窗可能就殘留在畫面上
        // (看不見但吃掉所有點擊)——這是「退出全螢幕後面板打不開」的元凶之一。
        if let window = webView.window, window.styleMask.contains(.fullScreen), retry < 20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated { self.attachIfPossible(retry: retry + 1) }
            }
            return
        }
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }

    // MARK: - 生命週期決策

    private func evaluateTeardown() {
        if panelActive || store.isPlaying || store.isDesktopMode {
            cancelTeardown()
        } else if webView != nil {
            scheduleTeardown()
        }
    }

    private func scheduleTeardown() {
        guard teardownTimer == nil else { return }
        teardownTimer = Timer.scheduledTimer(withTimeInterval: teardownDelay,
                                             repeats: false) { [weak self] _ in
            // Timer 掛在主 runloop,回呼必在主執行緒
            MainActor.assumeIsolated { self?.teardownIfIdle() }
        }
    }

    /// 倒數到了不直接拆,先問頁面一次「真的沒有在播嗎」。
    /// 事件有可能漏(頁面導航、行程回收後重載),最後一道防線以實況為準。
    private func teardownIfIdle() {
        teardownTimer = nil
        guard let webView, !panelActive else { return }
        webView.evaluateJavaScript("!!(window.__spAnyPlaying && window.__spAnyPlaying())") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if (result as? Bool) == true {
                    self.store.isPlaying = true
                    self.evaluateTeardown()
                } else {
                    self.destroyWebView()
                }
            }
        }
    }

    private func cancelTeardown() {
        teardownTimer?.invalidate()
        teardownTimer = nil
    }

    nonisolated static let volumeSeedJS = """
    (function () {
      try {
        const now = Date.now();
        const inner = JSON.stringify({ volume: 100, muted: false });
        localStorage.setItem("yt-player-volume", JSON.stringify({
          data: inner, expiration: now + 2592000000, creation: now
        }));
      } catch (e) {}
      // 全螢幕「之前」先通知原生端把 App 啟用、視窗變成 key window。
      // fullscreenchange 事件來得太晚:WebKit 的全螢幕視窗已經在一個未啟用的 App 裡建好了,
      // 滑鼠移動事件進不去 → 控制列不會自動隱藏、游標不會消失、進度條 hover 無效。
      // requestFullscreen 必須在使用者手勢裡同步呼叫,所以這裡只是「先發訊息、再照常呼叫」,
      // 訊息與全螢幕請求走同一條 IPC 通道,原生端一定先收到訊息。
      try {
        const notify = () => {
          try { window.webkit.messageHandlers.media.postMessage({ type: "willFullscreen" }); } catch (e) {}
        };
        for (const name of ["requestFullscreen", "webkitRequestFullscreen", "webkitRequestFullScreen"]) {
          const orig = Element.prototype[name];
          if (typeof orig !== "function") continue;
          Element.prototype[name] = function () { notify(); return orig.apply(this, arguments); };
        }
        if (window.HTMLVideoElement && HTMLVideoElement.prototype.webkitEnterFullscreen) {
          const orig = HTMLVideoElement.prototype.webkitEnterFullscreen;
          HTMLVideoElement.prototype.webkitEnterFullscreen = function () { notify(); return orig.apply(this, arguments); };
        }
      } catch (e) {}
    })();
    """

    // MARK: - JS bridge(事件驅動,零輪詢)
    // play/pause/ended → 播放狀態;durationchange → 換曲時補 metadata(標題/演出者/封面)

    nonisolated static let mediaBridgeJS = """
    (function () {
      if (window.__spBridge) return;
      window.__spBridge = true;
      const post = (payload) => {
        try { window.webkit.messageHandlers.media.postMessage(payload); } catch (e) {}
      };
      // 解除靜音:YT 播放器有自己的 mute 狀態機,直接改 video.muted 會被改回去,
      // 必須走 #movie_player 的 unMute()/setVolume() API,元素層再補一手。
      const unmute = () => {
        try {
          const player = document.querySelector("#movie_player");
          if (player && player.unMute) {
            player.unMute();
            if (player.setVolume && player.isMuted && !player.isMuted()) player.setVolume(100);
          }
        } catch (e) {}
        document.querySelectorAll("video, audio").forEach((v) => {
          v.muted = false;
          if (v.volume === 0) v.volume = 1;
        });
      };
      window.__spUnmute = unmute;
      // 畫質:YouTube 依播放器尺寸選串流,窄面板裡只會給 240/360p,
      // 放大後也不會自己升上去 → 用播放器 API 設定畫質範圍,並發一次 resize 讓它重新評估版面。
      // 面板 440pt @2x = 880px 寬,720p 已經是像素對齊的上限;
      // 之前不分狀態一律鎖 1080–highres,等於在小框裡解 1080/4K 串流,
      // WebContent 行程吃滿 CPU/GPU,面板裡點什麼都跟著鈍。只有全螢幕才拉高。
      // 桌布模式(html.__spDesktop)也是鋪滿整個螢幕,畫質比照全螢幕
      const isFullscreen = () =>
        !!(document.fullscreenElement || document.webkitFullscreenElement)
        || document.documentElement.classList.contains("__spDesktop");
      const quality = () => {
        try {
          const p = document.querySelector("#movie_player")
                 || document.querySelector(".html5-video-player");
          if (p) {
            const fs = isFullscreen();
            const lo = fs ? "hd1080" : "hd720";
            const hi = fs ? "highres" : "hd1080";
            if (p.setPlaybackQualityRange) p.setPlaybackQualityRange(lo, hi);
            if (p.setPlaybackQuality) p.setPlaybackQuality(lo);
          }
        } catch (e) {}
        try { window.dispatchEvent(new Event("resize")); } catch (e) {}
      };
      window.__spQuality = quality;
      const bump = () => { quality(); setTimeout(quality, 600); setTimeout(quality, 1800); };
      window.__spQualityBump = bump;
      const meta = () => {
        const m = navigator.mediaSession && navigator.mediaSession.metadata;
        const base = { url: location.href };
        if (!m) return base;
        const art = (m.artwork && m.artwork.length)
          ? m.artwork[m.artwork.length - 1].src : "";
        return Object.assign(base, { title: m.title || "", artist: m.artist || "", artwork: art });
      };
      // 「有沒有在播」看整個頁面,不看單一元素。桌面版 YouTube 同時存在好幾個
      // video 元素(主播放器、首頁縮圖的 hover 預覽、迷你播放器……),
      // 任何一個預覽片段結束都會發 pause——原本照單全收,主播放器明明在播,
      // 原生端卻以為停了,倒數一到就把 webview 拆掉:「純播放幾分鐘也被卸載」就是這樣。
      const anyPlaying = () => Array.from(document.querySelectorAll("video, audio"))
        .some((v) => !v.paused && !v.ended && v.readyState > 2);
      window.__spAnyPlaying = anyPlaying;
      let stateTimer = null;
      const reportState = () => {
        clearTimeout(stateTimer);
        // 250ms 防抖:換曲時 ended → 新曲 play 之間會短暫「沒有任何東西在播」
        stateTimer = setTimeout(() => {
          post(Object.assign({ type: anyPlaying() ? "play" : "pause" }, meta()));
          setTimeout(() => post(Object.assign({ type: "meta" }, meta())), 800);
        }, 250);
      };
      const hook = () => {
        document.querySelectorAll("video, audio").forEach((el) => {
          if (el.__spHooked) return;
          el.__spHooked = true;
          let lastProgress = 0;
          el.addEventListener("play", () => {
            unmute();
            setTimeout(unmute, 400);
            setTimeout(unmute, 1200);
            bump();
            reportState();
          });
          el.addEventListener("pause", reportState);
          el.addEventListener("ended", reportState);
          el.addEventListener("durationchange", () => { bump(); reportState(); });
          el.addEventListener("timeupdate", () => {
            if (el.paused) return;          // 暫停中拖進度條也會發 timeupdate
            const now = Date.now();
            if (now - lastProgress < 2000) return;
            lastProgress = now;
            // 播放中每 2 秒強制解除靜音(YT 的狀態機事後把它靜音也壓得回來)
            if (el.muted || el.volume === 0) unmute();
            if (isFinite(el.duration) && el.duration > 0) {
              post({ type: "progress", position: el.currentTime, duration: el.duration });
            }
          });
        });
      };
      hook();
      new MutationObserver(hook).observe(document.documentElement, { childList: true, subtree: true });
      const fsChanged = () => {
        bump();
        post({
          type: "fullscreen",
          on: !!(document.fullscreenElement || document.webkitFullscreenElement)
        });
      };
      document.addEventListener("fullscreenchange", fsChanged);
      document.addEventListener("webkitfullscreenchange", fsChanged);
    })();
    """

    // WKScriptMessageHandler 在新 SDK 是 MainActor 隔離的,直接以 MainActor 方法實作
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "media",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "play":  store.isPlaying = true
        case "pause": store.isPlaying = false
        case "progress":
            // 進度只會從正在播放的元素送來——這是最可靠的「還在播」證據
            if !store.isPlaying { store.isPlaying = true }
            if let position = body["position"] as? Double { store.position = position }
            if let duration = body["duration"] as? Double { store.duration = duration }
        case "willFullscreen":
            // 全螢幕視窗還沒建立,先把 App 與面板變成焦點,WebKit 接手時就會在活躍 App 裡開全螢幕
            NSApp.activate(ignoringOtherApps: true)
            webView?.window?.makeKey()
            return
        case "fullscreen":
            let on = (body["on"] as? Bool) ?? false
            store.isFullscreen = on
            PanelController.shared.setFullscreenMode(on)
            // 全螢幕用原尺寸版面,回到面板再縮回去
            webView?.pageZoom = on ? 1.0 : Self.panelZoom
            if on {
                // WebKit 的全螢幕視窗若不是 key window,播放器收不到滑鼠移動,
                // 控制列不會自動隱藏、縮小鍵也按不動 → 明確把它變成焦點視窗
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    MainActor.assumeIsolated {
                        self.webView?.window?.makeKeyAndOrderFront(nil)
                    }
                }
            } else {
                // 離開全螢幕:確保 webview 回到面板的容器裡
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    MainActor.assumeIsolated { self.attachIfPossible() }
                }
            }
            return
        default: break   // "meta" 只更新 metadata
        }
        if let title = body["title"] as? String, !title.isEmpty { store.title = title }
        if let artist = body["artist"] as? String, !artist.isEmpty { store.artist = artist }
        if let artwork = body["artwork"] as? String, !artwork.isEmpty { store.artworkURL = artwork }
        if let urlString = body["url"] as? String, urlString.contains("/watch") {
            UserDefaults.standard.set(urlString, forKey: Self.lastWatchKey)
        }
        evaluateTeardown()
    }
}


/// App 幾乎永遠非活躍(LSUIElement + 非活化面板),
/// WKWebView 預設會把「第一下」點擊吞掉拿去喚醒 App、不傳給網頁——
/// 這就是面板開啟後要多點一次才能點到影片的原因。
/// 這裡讓第一下就直接送進網頁,同時把面板變成焦點視窗(搜尋框才能打字)。
final class FirstMouseWebView: WKWebView {

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // 順序很重要:先把事件交給網頁,再處理焦點。
        // 反過來寫的話,啟用 App 是非同步的,AppKit 有機率在切換焦點的過程中
        // 把這一下點擊丟掉 —— 那就是「點 YT 內容有時候沒反應」的來源。
        super.mouseDown(with: event)
        guard window?.isKeyWindow == false else { return }
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKey()
        }
    }
}
