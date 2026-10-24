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
              }`;
            (document.head || document.documentElement).appendChild(s);
          }
          document.documentElement.classList.toggle("__spDesktop", \(on));
          if (window.__spQualityBump) window.__spQualityBump();
          else window.dispatchEvent(new Event("resize"));
        })()
        """
    }
}
