import SwiftUI
import AppKit
import WebKit

/// M2 播放器視圖:完整播放 UI 由 YouTube Music 網頁提供,
/// 原生層只負責圓角卡片外框與「未載入」時的輕量佔位(避免每次開面板就吃 200MB)。
struct YouTubePlayerView: View {

    let store: PlayerStore
    let controller: WebViewController

    /// 載入後的播放區高度(手機版 YouTube 在 440pt 寬下的合理比例)
    static let playerHeight: CGFloat = 520
    /// 未載入時的佔位高度
    static let idleHeight: CGFloat = 140

    var body: some View {
        Group {
            if store.webViewAlive {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        toolbarButton("house.fill") { controller.goHome() }
                        toolbarButton("arrow.clockwise") { controller.reload() }
                        Spacer()
                        toolbarButton(store.isDesktopMode ? "rectangle.righthalf.inset.filled" : "desktopcomputer",
                                      help: store.isDesktopMode ? "影片收回側面板" : "影片當桌布") {
                            controller.toggleDesktopMode()
                        }
                    }
                    if store.isDesktopMode {
                        desktopModeCard
                    } else {
                        WebViewContainer(controller: controller)
                    }
                }
            } else {
                placeholder
            }
        }
        // 固定高度:面板改成可捲動後,這塊要有明確的位置與大小,
        // 否則它會把剩下的空間全部吃掉,其他卡片被擠到看不見。
        // 註:frame(maxWidth:height:) 這個組合不存在,要拆成兩次
        .frame(maxWidth: .infinity)
        .frame(height: store.webViewAlive ? Self.playerHeight : Self.idleHeight)
        // 圓角(rounding.normal,design_reference §1)不在這裡用 clipShape:
        // 對 NSViewRepresentable 套 clipShape 會變成 mask layer,整個 webview
        // 每一格都得先離屏繪製再套遮罩,影片播放中就是持續的 GPU 開銷。
        // 改在 WKWebView 自己的 layer 設 cornerRadius(見 WebViewController.ensureWebView),
        // 合成器對圓角矩形有快速路徑。
    }

    private func toolbarButton(_ symbol: String, help: String = "",
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// 桌布模式中 webview 在桌面上,這格改顯示說明與收回鍵
    private var desktopModeCard: some View {
        Button {
            controller.exitDesktopMode()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(.tint)
                Text("影片正在桌面播放")
                    .font(.system(size: 13, weight: .medium))
                Text("點這裡收回側面板")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    /// webview 未存活時的佔位卡:點了才真正載入
    private var placeholder: some View {
        Button {
            controller.ensureWebView()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.tint)
                Text("載入 YouTube")
                    .font(.system(size: 13, weight: .medium))
                Text("暫停 5 分鐘後會自動卸載以釋放記憶體")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

/// 承載 webview 的容器。webview 由 WebViewController 持有並掛進來——
/// 這樣面板收合(視窗 orderOut)時 webview 仍在視圖樹裡,音訊續播;
/// 銷毀與否由 controller 決定,View 不管生命週期。
private struct WebViewContainer: NSViewRepresentable {
    let controller: WebViewController

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        controller.attach(to: v)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        controller.attach(to: nsView)
    }
}
