import SwiftUI
import YouTubePlayer

/// 單獨執行:一個放播放器的小視窗
@main
struct YouTubePlayerApp: App {
    @State private var player = YouTubePlayerModule()

    var body: some Scene {
        Window("YouTube", id: "player") {
            player.moduleView
                .frame(width: 440)
                .padding(10)
                .onAppear { player.setActive(true) }
                .onDisappear { player.setActive(false) }
        }
        .windowResizability(.contentSize)
    }
}
