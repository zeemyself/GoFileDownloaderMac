import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: DownloadStore
    @FocusState private var focusedField: Field?
    @State private var showLogPanel: Bool = false
    @State private var selectedItemIDs = Set<DownloadItem.ID>()

    private enum Field: Hashable {
        case url
        case password
    }

    var body: some View {
        VStack(spacing: 0) {
            headerControls
                .padding(16)
                .background(.bar)

            Divider()

            if !store.items.isEmpty || store.state.isActive {
                overallSummaryBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                Divider()
            }

            VSplitView {
                filesTableSection
                    .frame(minHeight: 220, idealHeight: 340)

                if showLogPanel {
                    logPanelSection
                        .frame(minHeight: 130, idealHeight: 180)
                }
            }

            Divider()
            footerBar
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.bar)
        }
        .frame(minWidth: 780, idealWidth: 900, minHeight: 520, idealHeight: 640)
        .onAppear {
            focusedField = .url
        }
        .onChange(of: store.needsPasswordPrompt) { _, needsPassword in
            if needsPassword {
                focusedField = .password
            }
        }
    }

    // MARK: - Header Controls

    private var headerControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                    TextField("https://gofile.io/d/...", text: $store.urlInput)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .url)
                        .onSubmit {
                            if store.canStart {
                                store.startDownload()
                            }
                        }
                    if !store.urlInput.isEmpty && !store.state.isActive {
                        Button {
                            store.urlInput = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear URL")
                    }
                    Button {
                        if let clip = NSPasteboard.general.string(forType: .string) {
                            store.urlInput = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Paste from Clipboard")
                    .disabled(store.state.isActive)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(urlBorderColor, lineWidth: 1)
                )
                .disabled(store.state.isActive)

                HStack(spacing: 6) {
                    Image(systemName: store.needsPasswordPrompt ? "lock.trianglebadge.exclamationmark.fill" : "lock")
                        .foregroundStyle(store.needsPasswordPrompt ? .orange : .secondary)
                    SecureField("Password (optional)", text: $store.passwordInput)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .password)
                        .onSubmit {
                            if store.canStart {
                                store.startDownload()
                            }
                        }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(width: 210)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(
                            store.needsPasswordPrompt ? Color.orange : Color.secondary.opacity(0.25),
                            lineWidth: store.needsPasswordPrompt ? 1.5 : 1
                        )
                )
                .disabled(store.state.isActive)

                if store.state.isActive {
                    Button(role: .destructive) {
                        store.cancelDownload()
                    } label: {
                        Label("Cancel", systemImage: "stop.fill")
                            .frame(minWidth: 96)
                    }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                } else {
                    Button {
                        store.startDownload()
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle.fill")
                            .frame(minWidth: 96)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!store.canStart)
                    .keyboardShortcut(.defaultAction)
                }
            }

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text("Save to:")
                        .foregroundStyle(.secondary)
                    Text(store.downloadFolder.path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button("Change…") {
                    store.chooseDownloadFolder()
                }
                .controlSize(.small)
                .disabled(store.state.isActive)

                Button {
                    store.revealDownloadFolder()
                } label: {
                    Label("Reveal in Finder", systemImage: "arrow.up.forward.app")
                }
                .controlSize(.small)

                Spacer()

                HStack(spacing: 10) {
                    Label("\(store.maxConcurrent) workers", systemImage: "cpu")
                    Text("•")
                    Label("\(store.maxRetries) retries", systemImage: "arrow.clockwise")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private var urlBorderColor: Color {
        let trimmed = store.urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return Color.secondary.opacity(0.25)
        }
        return store.parsedContentID != nil ? Color.accentColor.opacity(0.6) : Color.red.opacity(0.7)
    }

    // MARK: - Overall Summary Bar

    private var overallSummaryBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                statusBadge

                if let cid = store.contentID {
                    Text("Album \(cid)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !store.items.isEmpty {
                    HStack(spacing: 14) {
                        Text("\(store.completedFilesCount)/\(store.items.count) files")
                            .monospacedDigit()
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text("\(Formatters.bytes(store.totalBytesReceived)) / \(Formatters.bytes(store.totalBytesExpected))")
                            .monospacedDigit()
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Label(Formatters.speed(store.aggregateSpeed), systemImage: "speedometer")
                            .monospacedDigit()
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Label("ETA \(store.overallETAString)", systemImage: "hourglass")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if store.state == .resolving {
                ProgressView()
                    .progressViewStyle(.linear)
            } else {
                ProgressView(value: store.overallFraction, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(overallProgressTint)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch store.state {
        case .idle:
            Label("Ready", systemImage: "circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        case .resolving:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Fetching album contents…")
                    .font(.subheadline.weight(.semibold))
            }
        case .downloading:
            Label("Downloading", systemImage: "arrow.down.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        case .finished:
            Label("Completed", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
        case .cancelled:
            Label("Cancelled (Resumable)", systemImage: "pause.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    private var overallProgressTint: Color {
        switch store.state {
        case .finished: return .green
        case .cancelled: return .orange
        case .failed: return .red
        default: return .accentColor
        }
    }

    // MARK: - Files Table

    @ViewBuilder
    private var filesTableSection: some View {
        if store.items.isEmpty {
            ContentUnavailableView {
                Label("No Active Downloads", systemImage: "arrow.down.doc")
            } description: {
                Text("Enter a GoFile album link (e.g. https://gofile.io/d/xxxxxx) above and click Download.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(store.items, selection: $selectedItemIDs) {
                TableColumn("File") { item in
                    HStack(spacing: 8) {
                        itemStatusIcon(item.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.filename)
                                .fontWeight(.medium)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if item.relativePath != item.filename {
                                Text(item.relativePath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                    }
                }
                .width(min: 200, ideal: 280)

                TableColumn("Progress") { item in
                    VStack(alignment: .leading, spacing: 3) {
                        if let frac = item.fractionCompleted {
                            ProgressView(value: frac, total: 1.0)
                                .progressViewStyle(.linear)
                                .tint(rowTint(for: item.status))
                        } else if case .downloading = item.status {
                            ProgressView()
                                .progressViewStyle(.linear)
                        } else {
                            ProgressView(value: 0, total: 1.0)
                                .progressViewStyle(.linear)
                        }
                        HStack {
                            if let total = item.totalBytes, total > 0 {
                                Text("\(Formatters.bytes(item.bytesReceived)) / \(Formatters.bytes(total))")
                            } else {
                                Text(Formatters.bytes(item.bytesReceived))
                            }
                            Spacer()
                            if let frac = item.fractionCompleted {
                                Text(String(format: "%.0f%%", frac * 100))
                            }
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .width(min: 180, ideal: 240)

                TableColumn("Speed") { item in
                    Text(Formatters.speed(item.speedBytesPerSec))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 95)

                TableColumn("ETA") { item in
                    Text(item.etaString)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 85)

                TableColumn("Status") { item in
                    Text(item.status.label)
                        .font(.caption)
                        .foregroundStyle(statusTextColor(item.status))
                }
                .width(min: 100, ideal: 120)
            }
            .contextMenu(forSelectionType: DownloadItem.ID.self) { ids in
                rowContextMenu(for: ids)
            } primaryAction: { ids in
                if let firstID = ids.first,
                   let item = store.items.first(where: { $0.id == firstID }) {
                    store.revealItem(item)
                }
            }
        }
    }

    @ViewBuilder
    private func rowContextMenu(for ids: Set<DownloadItem.ID>) -> some View {
        let selectedItems = store.items.filter { ids.contains($0.id) }
        if let first = selectedItems.first {
            let canRetry = selectedItems.contains {
                switch $0.status {
                case .failed, .cancelled, .completed, .skipped, .queued:
                    return true
                case .downloading, .retrying:
                    return false
                }
            }

            Button {
                store.retryItems(withIDs: ids, forceRestart: false)
            } label: {
                Label(
                    selectedItems.count > 1 ? "Retry / Resume Selected (\(selectedItems.count))" : "Retry / Resume Download",
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(!canRetry)

            Button {
                store.retryItems(withIDs: ids, forceRestart: true)
            } label: {
                Label(
                    selectedItems.count > 1 ? "Re-download Selected from Scratch" : "Re-download from Scratch",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
            .disabled(!canRetry)

            Divider()

            Button {
                store.revealItem(first)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            if selectedItems.count == 1,
               FileManager.default.fileExists(atPath: first.destinationURL.path) {
                Button {
                    store.openDownloadedFile(first)
                } label: {
                    Label("Open File", systemImage: "arrow.up.forward.app")
                }
            }

            Divider()

            Button {
                let names = selectedItems.map(\.filename).joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(names, forType: .string)
            } label: {
                Label(
                    selectedItems.count > 1 ? "Copy Filenames" : "Copy Filename",
                    systemImage: "doc.on.doc"
                )
            }

            Button {
                let links = selectedItems.map(\.remoteFile.downloadLink).joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(links, forType: .string)
            } label: {
                Label(
                    selectedItems.count > 1 ? "Copy Download Links" : "Copy Download Link",
                    systemImage: "link"
                )
            }
        }
    }

    @ViewBuilder
    private func itemStatusIcon(_ status: DownloadItemStatus) -> some View {
        switch status {
        case .queued:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .downloading:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
        case .retrying:
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.orange)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .skipped:
            Image(systemName: "arrow.uturn.right.circle.fill")
                .foregroundStyle(.teal)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func rowTint(for status: DownloadItemStatus) -> Color {
        switch status {
        case .completed, .skipped: return .green
        case .retrying, .cancelled: return .orange
        case .failed: return .red
        default: return .accentColor
        }
    }

    private func statusTextColor(_ status: DownloadItemStatus) -> Color {
        switch status {
        case .completed: return .green
        case .skipped: return .teal
        case .retrying, .cancelled: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }

    // MARK: - Log Panel

    private var logPanelSection: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Event Log", systemImage: "terminal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    store.clearLog()
                }
                .controlSize(.mini)
                .disabled(store.logs.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollViewReader { proxy in
                List(store.logs) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Formatters.timeString(entry.timestamp))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .leading)

                        Text(entry.event)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(logEventColor(entry.event))
                            .frame(width: 145, alignment: .leading)

                        Text(entry.details)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    .id(entry.id)
                }
                .listStyle(.plain)
                .onChange(of: store.logs.count) { _, _ in
                    if let last = store.logs.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func logEventColor(_ event: String) -> Color {
        if event.contains("Failed") || event.contains("Invalid") || event.contains("Missing") {
            return .red
        } else if event.contains("Retry") || event.contains("Cancel") {
            return .orange
        } else if event.contains("Completed") {
            return .green
        } else if event.contains("Skipped") || event.contains("Resuming") {
            return .teal
        }
        return .accentColor
    }

    // MARK: - Footer Bar

    private var footerBar: some View {
        HStack {
            Toggle(isOn: $showLogPanel) {
                Label("Event Log (\(store.logs.count))", systemImage: "sidebar.bottom")
                    .font(.caption)
            }
            .toggleStyle(.button)
            .controlSize(.small)

            Spacer()

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .font(.caption)
            }
            .controlSize(.small)
        }
    }
}
