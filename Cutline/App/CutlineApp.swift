import SwiftUI
import AVFoundation

@main
struct CutlineApp: App {
    @State private var store = ProjectStore()

    init() {
        // Playback-category session so preview audio plays even with the silent switch on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        ExportService.cleanExports()
        UIScrollView.appearance().keyboardDismissMode = .interactive
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
