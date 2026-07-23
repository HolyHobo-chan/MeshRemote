import SwiftUI

struct DeviceListView: View {
    let connection: MeshServerConnection

    @Environment(AppState.self) private var app
    @State private var searchText = ""
    @State private var showOfflineDevices = true
    @State private var showAbout = false

    var body: some View {
        NavigationStack {
            Group {
                if connection.meshes.isEmpty && connection.nodes.isEmpty {
                    ProgressView("Loading devices…")
                } else {
                    deviceList
                }
            }
            .navigationTitle("Devices")
            .toolbar { toolbarContent }
            .searchable(text: $searchText, prompt: "Search devices")
            .refreshable { await connection.refreshDeviceList() }
            .navigationDestination(for: MeshNode.self) { node in
                DeviceDetailView(connection: connection, nodeId: node.id)
            }
            .overlay(alignment: .bottom) {
                if case .failed(let message) = connection.state {
                    DisconnectedBanner(message: message) {
                        app.signOut()
                    }
                }
            }
            .sheet(isPresented: $showAbout) {
                AboutView()
            }
        }
    }

    private var filteredNodes: [MeshNode] {
        var nodes = Array(connection.nodes.values)
        if !showOfflineDevices {
            nodes = nodes.filter { $0.isOnline || connection.isLocalDevice($0) }
        }
        if !searchText.isEmpty {
            nodes = nodes.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                || ($0.host ?? "").localizedCaseInsensitiveContains(searchText)
                || ($0.ip ?? "").localizedCaseInsensitiveContains(searchText)
            }
        }
        return nodes
    }

    private var deviceList: some View {
        let nodes = filteredNodes
        let grouped = Dictionary(grouping: nodes, by: \.meshId)

        return List {
            summaryHeader

            ForEach(connection.meshes) { mesh in
                if let meshNodes = grouped[mesh.id], !meshNodes.isEmpty {
                    Section(mesh.name) {
                        ForEach(meshNodes.sorted {
                            if $0.isOnline != $1.isOnline { return $0.isOnline }
                            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                        }) { node in
                            NavigationLink(value: node) {
                                DeviceRow(node: node, isLocal: connection.isLocalDevice(node))
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if nodes.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private var summaryHeader: some View {
        let all = Array(connection.nodes.values)
        let online = all.filter(\.isOnline).count
        let relay = all.filter { !$0.isOnline && connection.isLocalDevice($0) }.count
        return Section {
            HStack(spacing: 16) {
                StatBadge(count: online, label: "Online", color: .green)
                if relay > 0 {
                    StatBadge(count: relay, label: "Relay", color: .teal)
                }
                StatBadge(count: all.count - online - relay, label: "Offline", color: .secondary)
                Spacer()
                Text(connection.profile.displayName.isEmpty
                     ? connection.profile.host
                     : connection.profile.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 2)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Toggle("Show Offline Devices", isOn: $showOfflineDevices)
                Divider()
                Button("About MeshRemote", systemImage: "info.circle") {
                    showAbout = true
                }
                Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    app.signOut()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

struct StatBadge: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(count) \(label)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

struct DeviceRow: View {
    let node: MeshNode
    var isLocal: Bool = false

    private var reachable: Bool { node.isOnline || isLocal }
    private var dotColor: Color {
        node.isOnline ? .green : (isLocal ? .teal : Color(.systemGray4))
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                DeviceGlyph(node: node, isLocal: isLocal, reachable: reachable, size: 28)
                    .frame(width: 40, height: 40)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9))
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    .offset(x: 3, y: 3)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if isLocal, !node.isOnline {
                        Text(node.host.flatMap { "\($0) · via relay" } ?? "via relay")
                    } else if let os = node.osDescription, !os.isEmpty {
                        Text(os)
                    } else if let host = node.host {
                        Text(host)
                    } else {
                        Text(node.isOnline ? "Online" : "Offline")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            if !node.users.isEmpty {
                Image(systemName: "person.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .opacity(reachable ? 1 : 0.55)
    }
}

struct DisconnectedBanner: View {
    let message: String
    let onSignOut: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
            Text(message)
                .font(.footnote)
                .lineLimit(2)
            Spacer()
            Button("Sign Out", action: onSignOut)
                .font(.footnote.weight(.semibold))
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}
