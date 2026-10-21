import SwiftUI

@main struct MyApp: App {
    // Owned by the app rather than the window, so a running stress test
    // survives the window being closed on macOS.
    @State private var chat = ChatModel()
    @State private var monitor = SystemMonitor()
    @State private var stressTest = StressTest()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(chat: chat, monitor: monitor, stressTest: stressTest)
        }
        .onChange(of: scenePhase) { _, phase in
            #if os(iOS)
            // iOS forbids GPU work in the background; stop cleanly instead of being killed.
            if phase == .background {
                stressTest.stop(reason: "Stopped: the app went to the background")
                chat.stop()
            }
            #endif
        }
    }
}
