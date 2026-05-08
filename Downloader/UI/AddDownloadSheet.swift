import SwiftUI

struct AddDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var downloadManager: DownloadManager
    @State private var urlText = ""
    @State private var destination = FolderBookmarkStore.lastFolder()

    private var canAdd: Bool {
        URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Download")
                .font(.title2.bold())

            TextField("URL or magnet link", text: $urlText)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text(destination.path(percentEncoded: false))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    chooseDestination()
                } label: {
                    Label("Choose Folder", systemImage: "folder")
                }
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    addDownload()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination

        if panel.runModal() == .OK {
            guard let url = panel.url else { return }
            destination = url
            FolderBookmarkStore.save(folder: url)
        }
    }

    private func addDownload() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        FolderBookmarkStore.save(folder: destination)
        downloadManager.add(url: url, destination: destination)
        dismiss()
    }
}
