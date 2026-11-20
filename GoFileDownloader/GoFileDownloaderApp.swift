import SwiftUI

@main
struct GoFileDownloaderApp: App {
    @State private var store: DownloadStore

    init() {
        let initialStore = DownloadStore()
        let args = CommandLine.arguments
        if let urlIdx = args.firstIndex(of: "--url"), urlIdx + 1 < args.count {
            initialStore.urlInput = args[urlIdx + 1]
        }
        if let pwIdx = args.firstIndex(of: "--password"), pwIdx + 1 < args.count {
            initialStore.passwordInput = args[pwIdx + 1]
        }
        if let outIdx = args.firstIndex(of: "--output"), outIdx + 1 < args.count {
            initialStore.downloadFolder = URL(fileURLWithPath: args[outIdx + 1], isDirectory: true)
        }
        let autoStart = args.contains("--autostart")
        _store = State(initialValue: initialStore)
        if autoStart {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                initialStore.startDownload()
            }
        }
    }

    var body: some Scene {
        WindowGroup("GoFile Downloader") {
            ContentView(store: store)
        }
        .defaultSize(width: 900, height: 640)

        Settings {
            SettingsView(store: store)
        }
    }
}

