import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var downloadManager: DownloadManager
    @State private var selection: DownloadFilter = .all
    @State private var showingAddDownload = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            DownloadsListView(filter: selection)
                .toolbar {
                    ToolbarItemGroup {
                        Button {
                            showingAddDownload = true
                        } label: {
                            Label("Add Download", systemImage: "plus")
                        }

                        Button {
                            downloadManager.resumeSelected()
                        } label: {
                            Label("Resume", systemImage: "play.fill")
                        }

                        Button {
                            downloadManager.pauseSelected()
                        } label: {
                            Label("Pause", systemImage: "pause.fill")
                        }
                    }
                }
        }
        .sheet(isPresented: $showingAddDownload) {
            AddDownloadSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAddDownload)) { _ in
            showingAddDownload = true
        }
    }
}
