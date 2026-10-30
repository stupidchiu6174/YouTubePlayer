import AppKit
import WebKit

/// 「影片當桌布」模式:把側面板正在播的同一個 WKWebView 搬到桌面層視窗,
/// 影片從原本的秒數接著播、不重新載入;關掉時再搬回面板。
/// 版面靠注入的 CSS 讓 #movie_player 鋪滿整個視窗,其餘 YouTube 介面全部隱藏。
final class DesktopVideoWindow: NSWindow {

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered, defer: false)
        // 比動態壁紙高一層、仍在桌面圖示之下:蓋住壁紙,圖示照常可點。
        // 不透明 → WindowServer 會把底下的壁紙視窗判定為被遮住,壁紙引擎自己就會暫停解碼。
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        setFrame(screen.frame, display: true)
    }
}

extension WebViewController {

    /// 主螢幕(有選單列的那一塊)。webview 一次只能在一個地方,多螢幕時只放這裡。
    private static var desktopScreen: NSScreen? { NSScreen.screens.first }

    func toggleDesktopMode() {
        if PlayerStore.shared.isDesktopMode {
            exitDesktopMode()
        } else {
            enterDesktopMode()
        }
    }

    func enterDesktopMode() {
        guard !PlayerStore.shared.isDesktopMode, !PlayerStore.shared.isFullscreen,
              let screen = Self.desktopScreen else { return }
        // 從選單列開、webview 還沒建:直接接續上次看的影片
        if webView == nil { resumePlayback() }
        guard let webView else { return }

        let window = DesktopVideoWindow(screen: screen)
        PlayerStore.shared.isDesktopMode = true   // 先設旗標,面板容器就不會把 webview 搶回去
        webView.removeFromSuperview()
        webView.frame = window.contentView?.bounds ?? screen.frame
        webView.autoresizingMask = [.width, .height]
        webView.layer?.cornerRadius = 0
        webView.pageZoom = 1.0
        window.contentView?.addSubview(webView)
        window.orderFrontRegardless()
        desktopWindow = window
        // 影片就是桌面本體了,小工具只會擋畫面
        YouTubePlayerModule.onDesktopModeChange(true)
        applyDesktopLayout()

        desktopScreenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let screen = Self.desktopScreen else { return }
                self.desktopWindow?.setFrame(screen.frame, display: true)
                self.applyDesktopLayout()
            }
        }
    }

    func exitDesktopMode() {
        guard PlayerStore.shared.isDesktopMode else { return }
        if let desktopScreenObserver {
            NotificationCenter.default.removeObserver(desktopScreenObserver)
        }
        desktopScreenObserver = nil
        PlayerStore.shared.isDesktopMode = false
        if let webView {
            webView.evaluateJavaScript(Self.desktopLayoutJS(on: false))
            webView.removeFromSuperview()
            webView.layer?.cornerRadius = 17
            webView.pageZoom = Self.panelZoom
        }
        desktopWindow?.orderOut(nil)
        desktopWindow = nil
        YouTubePlayerModule.onDesktopModeChange(false)
        // 面板的 SwiftUI 會重新建容器並 attach;容器若還在就先直接掛回去
        reattachToPanel()
    }

    /// 套用桌布版面(頁面重新載入、換螢幕後都要再套一次)
    func applyDesktopLayout() {
        guard PlayerStore.shared.isDesktopMode else { return }
        webView?.evaluateJavaScript(Self.desktopLayoutJS(on: true))
    }

    /// 以 html 上的 class 切換版面:visibility 讓整頁隱形、只留播放器,
    /// 播放器改成 fixed 鋪滿視窗,控制列與片尾卡片一併藏起來(反正也點不到)。
    ///
    /// 畫質:YouTube 的自動畫質看的是播放器「內部記錄的尺寸」(由隱形的版面算出),
    /// CSS 撐大它不會知道,setPlaybackQualityRange 也已經被忽略 → 桌布上只給 360p。
    /// 唯一可靠的辦法是照使用者的操作走一遍:齒輪 → 畫質 → 選 1080p 以下最高的一檔;
    /// 收回面板時同樣方式切回「自動」,避免小框裡繼續解 1080p。選單在桌布模式下透明,不會閃。
    private static func desktopLayoutJS(on: Bool) -> String {
        """
        (function(){
          const id = "__spDesktopStyle";
          if (!document.getElementById(id)) {
            const s = document.createElement("style");
            s.id = id;
            s.textContent = `
              html.__spDesktop, html.__spDesktop body { overflow: hidden !important; background: #000 !important; }
              html.__spDesktop body { visibility: hidden !important; }
              html.__spDesktop #movie_player {
                visibility: visible !important;
                position: fixed !important; inset: 0 !important;
                width: 100vw !important; height: 100vh !important;
                z-index: 2147483647 !important; background: #000 !important;
              }
              html.__spDesktop #movie_player video {
                left: 0 !important; top: 0 !important;
                width: 100vw !important; height: 100vh !important;
                object-fit: cover !important;
              }
              html.__spDesktop .ytp-chrome-top, html.__spDesktop .ytp-chrome-bottom,
              html.__spDesktop .ytp-gradient-top, html.__spDesktop .ytp-gradient-bottom,
              html.__spDesktop .ytp-ce-element, html.__spDesktop .ytp-pause-overlay,
              html.__spDesktop .ytp-endscreen-content, html.__spDesktop .ytp-autonav-endscreen,
              html.__spDesktop .ytp-paid-content-overlay, html.__spDesktop .iv-branding,
              html.__spDesktop .ytp-cards-teaser, html.__spDesktop .ytp-tooltip,
              html.__spDesktop .ytp-chapter-container, html.__spDesktop .ytp-overlay-top-right {
                display: none !important;
              }
              html.__spDesktop .ytp-settings-menu { opacity: 0 !important; }`;
            (document.head || document.documentElement).appendChild(s);

            // mode: "hd" 選 1080p 以下最高一檔;"auto" 切回自動。done 在選單關掉後呼叫。
            window.__spPickQuality = (mode, done) => {
              const finish = () => { if (done) done(); };
              const p = document.querySelector("#movie_player");
              const btn = p && p.querySelector(".ytp-settings-button");
              if (!btn) return finish();
              const menu = () => p.querySelector(".ytp-settings-menu");
              const close = () => {
                const m = menu();
                if (m && m.style.display !== "none") btn.click();
                finish();
              };
              const height = (el) => {
                const label = el.querySelector(".ytp-menuitem-label") || el;
                return parseInt(label.textContent.trim(), 10);   // 「自動 (360p)」→ NaN
              };
              btn.click();
              setTimeout(() => {
                const m = menu();
                const entry = m && Array.from(m.querySelectorAll(".ytp-panel-menu .ytp-menuitem"))
                  .find((i) => /\\d{3,4}p/.test(i.textContent));
                if (!entry) return close();
                entry.click();
                setTimeout(() => {
                  const opts = Array.from(m.querySelectorAll(".ytp-quality-menu .ytp-menuitem"));
                  const pick = mode === "hd"
                    ? opts.find((o) => height(o) > 0 && height(o) <= 1080)
                    : opts.find((o) => isNaN(height(o)));
                  if (pick && pick.getAttribute("aria-checked") !== "true") pick.click();
                  setTimeout(close, 150);
                }, 350);
              }, 350);
            };
            // 桌布模式中換影片(連播、佇列下一首)要再選一次
            let lastPicked = "";
            document.addEventListener("loadedmetadata", (e) => {
              if (!document.documentElement.classList.contains("__spDesktop")) return;
              if (!(e.target && e.target.closest && e.target.closest("#movie_player"))) return;
              if (lastPicked === location.href) return;
              lastPicked = location.href;
              setTimeout(() => window.__spPickQuality("hd"), 800);
            }, true);
            window.__spResetPicked = () => { lastPicked = ""; };
          }
          const root = document.documentElement;
          const bump = () => {
            if (window.__spQualityBump) window.__spQualityBump();
            else window.dispatchEvent(new Event("resize"));
          };
          window.__spResetPicked();
          if (\(on)) {
            root.classList.add("__spDesktop");
            bump();
            setTimeout(() => window.__spPickQuality("hd"), 400);
          } else {
            // 先在透明狀態下切回自動,再還原版面
            window.__spPickQuality("auto", () => { root.classList.remove("__spDesktop"); bump(); });
          }
        })()
        """
    }
}
