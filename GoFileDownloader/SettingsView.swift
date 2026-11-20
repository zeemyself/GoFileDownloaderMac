import SwiftUI

struct SettingsView: View {
    @Bindable var store: DownloadStore

    var body: some View {
        Form {
            Section("Downloads") {
                LabeledContent("Download Folder") {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                        Text(store.downloadFolder.path)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 260, alignment: .leading)
                        Button("Choose…") {
                            store.chooseDownloadFolder()
                        }
                    }
                }

                Stepper(
                    value: $store.maxConcurrent,
                    in: 1...8
                ) {
                    LabeledContent("Concurrent Downloads") {
                        Text("\(store.maxConcurrent)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Stepper(
                    value: $store.maxRetries,
                    in: 0...10
                ) {
                    LabeledContent("Max Retries per File") {
                        Text("\(store.maxRetries)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Behavior") {
                Text("Partially downloaded files are saved with a .part extension and automatically resumed via HTTP Range requests on retry or subsequent runs.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 260)
    }
}
