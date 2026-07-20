import SwiftUI
import UIKit

struct FilesView: View {
    let connection: MeshServerConnection
    let node: MeshNode

    @State private var session: FilesSession?
    @State private var showNewFolderPrompt = false
    @State private var newFolderName = ""
    @State private var renameTarget: FileEntry?
    @State private var renameText = ""
    @State private var deleteTarget: FileEntry?
    @State private var showImporter = false
    @State private var shareURL: URL?
    @State private var transferError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let session {
                content(session)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(session?.displayPath ?? node.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            guard session == nil else { return }
            let newSession = FilesSession(connection: connection, node: node)
            session = newSession
            await newSession.start()
        }
        .onDisappear { session?.stop() }
        .alert("New Folder", isPresented: $showNewFolderPrompt) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task { await session?.makeDirectory(named: name) }
                newFolderName = ""
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget, !renameText.isEmpty {
                    Task { await session?.rename(target, to: renameText) }
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result, let session else { return }
            Task {
                do { try await session.upload(fileURL: url) }
                catch { transferError = error.localizedDescription }
            }
        }
        .sheet(item: Binding(
            get: { shareURL.map(ShareItem.init) },
            set: { if $0 == nil { shareURL = nil } }
        )) { item in
            ShareSheet(url: item.url)
        }
        .alert("Transfer Failed", isPresented: Binding(
            get: { transferError != nil },
            set: { if !$0 { transferError = nil } }
        )) {
            Button("OK") { transferError = nil }
        } message: {
            Text(transferError ?? "")
        }
    }

    @ViewBuilder
    private func content(_ session: FilesSession) -> some View {
        ZStack {
            switch session.state {
            case .connecting:
                ProgressView("Connecting to \(node.name)…")
            case .closed(let message):
                SessionEndedOverlay(message: message) { dismiss() }
            case .ready:
                listView(session)
            }

            if let transfer = session.transfer {
                TransferOverlay(progress: transfer) {
                    session.cancelTransfer()
                }
            }
        }
    }

    @ViewBuilder
    private func listView(_ session: FilesSession) -> some View {
        List {
            if !session.pathComponents.isEmpty {
                Button {
                    Task { await session.goUp() }
                } label: {
                    Label("Back", systemImage: "arrow.turn.left.up")
                        .foregroundStyle(Color.accentColor)
                }
            }

            if let error = session.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

            ForEach(session.entries) { entry in
                row(entry, session: session)
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if session.isLoading {
                ProgressView()
            } else if session.entries.isEmpty && session.lastError == nil {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            }
        }
        .refreshable {
            await session.list()
        }
    }

    @ViewBuilder
    private func row(_ entry: FileEntry, session: FilesSession) -> some View {
        Button {
            if entry.kind == .file {
                Task {
                    do { shareURL = try await session.download(entry) }
                    catch is CancellationError { }
                    catch { transferError = error.localizedDescription }
                }
            } else {
                Task { await session.enter(entry) }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon(for: entry))
                    .font(.title3)
                    .foregroundStyle(entry.kind == .file ? Color.secondary : Color.accentColor)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .lineLimit(1)
                        .foregroundStyle(Color.primary)
                    HStack(spacing: 6) {
                        if entry.kind == .file {
                            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        } else if entry.kind == .drive, let free = entry.freeBytes {
                            Text("\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free")
                        }
                        if let date = entry.modified {
                            Text(date, style: .date)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                }

                Spacer()

                if entry.kind != .file {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if entry.kind != .drive {
                // Deliberately NOT role: .destructive — that makes the List
                // pre-animate the row's removal before we've confirmed,
                // causing a visible flicker when the row snaps back.
                Button("Delete", systemImage: "trash") {
                    deleteTarget = entry
                }
                .tint(.red)
                Button("Rename", systemImage: "pencil") {
                    renameTarget = entry
                    renameText = entry.name
                }
                .tint(.orange)
            }
        }
        .popover(isPresented: Binding(
            get: { deleteTarget == entry },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            VStack(spacing: 16) {
                Text("Delete \(entry.name)?")
                    .font(.callout.weight(.semibold))
                    .multilineTextAlignment(.center)
                Button("Delete", role: .destructive) {
                    deleteTarget = nil
                    Task { await session.delete(entry, recursive: entry.kind == .directory) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Button("Cancel") { deleteTarget = nil }
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            .frame(minWidth: 240)
            .presentationCompactAdaptation(.popover)
        }
    }

    private func icon(for entry: FileEntry) -> String {
        switch entry.kind {
        case .drive:
            return entry.driveType == "REMOVABLE" ? "externaldrive" : "internaldrive"
        case .directory:
            return "folder.fill"
        case .file:
            let ext = (entry.name as NSString).pathExtension.lowercased()
            switch ext {
            case "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp": return "photo"
            case "mp4", "mov", "avi", "mkv": return "film"
            case "mp3", "wav", "flac", "m4a": return "music.note"
            case "pdf": return "doc.richtext"
            case "zip", "7z", "tar", "gz", "rar": return "doc.zipper"
            case "txt", "log", "md", "json", "xml", "conf", "ini": return "doc.text"
            case "exe", "msi", "app", "dmg", "pkg", "deb", "rpm": return "shippingbox"
            default: return "doc"
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button("Upload File", systemImage: "square.and.arrow.up") {
                    showImporter = true
                }
                Button("New Folder", systemImage: "folder.badge.plus") {
                    showNewFolderPrompt = true
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await session?.list() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}

struct TransferOverlay: View {
    let progress: FileTransferProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: progress.isUpload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
            Text(progress.fileName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            ProgressView(value: progress.fraction)
                .frame(width: 200)
            Text("\(ByteCountFormatter.string(fromByteCount: progress.transferred, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 20)
    }
}
