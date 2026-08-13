import SwiftUI

struct DeviceListView: View {
    let connection: MeshServerConnection

    @Environment(AppState.self) private var app
    @State private var searchText = ""
    @State private var showOfflineDevices = true
    @State private var showAbout = false
    @State private var prefs: DeviceListPreferences

    init(connection: MeshServerConnection) {
        self.connection = connection
        _prefs = State(initialValue: DeviceListPreferences(profileId: connection.profile.id))
    }

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
        let searching = !searchText.isEmpty

        // Favourites are hoisted into their own pinned section and removed from
        // their group, so a device never appears twice in the list.
        let favorites = nodes.filter { prefs.isFavorite($0.id) }
        let favoriteIds = Set(favorites.map(\.id))
        let rest = nodes.filter { !favoriteIds.contains($0.id) }

        let grouped = Dictionary(grouping: rest, by: \.meshId)
        let knownMeshIds = Set(connection.meshes.map(\.id))
        // Devices shared directly with the user (not via a device-group membership)
        // arrive under a mesh the user has no group rights to, so that mesh never
        // appears in `connection.meshes`. Collect them into their own section so
        // they aren't dropped from the list even though the summary counts them.
        let ungroupedNodes = rest.filter { !knownMeshIds.contains($0.meshId) }

        return List {
            summaryHeader

            if !favorites.isEmpty {
                groupSection(id: "favorites", title: "Favorites",
                             icon: "star.fill", nodes: favorites, searching: searching)
            }

            ForEach(connection.meshes) { mesh in
                if let meshNodes = grouped[mesh.id], !meshNodes.isEmpty {
                    groupSection(id: mesh.id, title: mesh.name,
                                 nodes: meshNodes, searching: searching)
                }
            }

            if !ungroupedNodes.isEmpty {
                groupSection(id: "other", title: "Other Devices",
                             nodes: ungroupedNodes, searching: searching)
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if nodes.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    /// A section whose header collapses the group. Collapsing is ignored while
    /// searching — a match must never stay hidden behind a collapsed header.
    @ViewBuilder
    private func groupSection(id: String, title: String, icon: String? = nil,
                              nodes: [MeshNode], searching: Bool) -> some View {
        let collapsed = !searching && prefs.isCollapsed(id)
        Section {
            if !collapsed { deviceRows(nodes) }
        } header: {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { prefs.toggleCollapsed(id) }
            } label: {
                HStack(spacing: 6) {
                    if let icon {
                        Image(systemName: icon)
                            .foregroundStyle(.yellow)
                    }
                    Text(title)
                    Text("\(nodes.count)")
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(searching)
        }
    }

    @ViewBuilder
    private func deviceRows(_ nodes: [MeshNode]) -> some View {
        ForEach(nodes.sorted {
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }) { node in
            NavigationLink(value: node) {
                DeviceRow(node: node, isLocal: connection.isLocalDevice(node))
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                favoriteButton(node)
            }
            .contextMenu {
                favoriteButton(node)
            }
        }
    }

    private func favoriteButton(_ node: MeshNode) -> some View {
        let isFavorite = prefs.isFavorite(node.id)
        return Button {
            withAnimation { prefs.toggleFavorite(node.id) }
        } label: {
            Label(isFavorite ? "Remove Favorite" : "Add to Favorites",
                  systemImage: isFavorite ? "star.slash" : "star")
        }
        .tint(.yellow)
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
                if !prefs.collapsedGroups.isEmpty {
                    Button("Expand All Groups", systemImage: "chevron.down") {
                        withAnimation { prefs.expandAll() }
                    }
                }
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
