import SwiftUI

struct DeviceDetailView: View {
    let connection: MeshServerConnection
    let nodeId: String

    @State private var actionFeedback: String?
    @State private var actionFailed = false

    /// Live node state — updates as events arrive.
    private var node: MeshNode? { connection.nodes[nodeId] }

    var body: some View {
        Group {
            if let node {
                content(node)
            } else {
                ContentUnavailableView("Device Removed", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle(node?.name ?? "Device")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(_ node: MeshNode) -> some View {
        let isLocal = connection.isLocalDevice(node)
        List {
            Section {
                headerCard(node)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section("Remote Control") {
                // Remote desktop and files need an agent on the device. Relay
                // (agentless) devices can only do SSH, so those rows are hidden
                // for them rather than shown permanently disabled.
                if !isLocal {
                    NavigationLink {
                        DesktopView(connection: connection, node: node)
                    } label: {
                        ActionRow(icon: "ActionDesktop", title: "Remote Desktop",
                                  subtitle: "View and control the screen")
                    }
                    .disabled(!node.hasAgent)
                }

                // Agent terminal — a shell run by the agent (works on Windows
                // without SSH). Only for agent devices that advertise the capability.
                if !isLocal && node.supportsTerminal {
                    NavigationLink {
                        AgentTerminalView(connection: connection, node: node)
                    } label: {
                        ActionRow(icon: "ActionTerminal", title: "Terminal",
                                  subtitle: "Command shell via the agent")
                    }
                    .disabled(!node.hasAgent)
                }

                NavigationLink {
                    SSHView(connection: connection, node: node)
                } label: {
                    ActionRow(icon: "ActionSSH", title: "SSH",
                              subtitle: "Terminal over SSH (port \(node.sshPort ?? 22))")
                }
                .disabled(!node.isOnline && !isLocal)

                if !isLocal {
                    NavigationLink {
                        FilesView(connection: connection, node: node)
                    } label: {
                        ActionRow(icon: "ActionFiles", title: "Files",
                                  subtitle: "Browse, upload and download")
                    }
                    .disabled(!node.hasAgent)
                }
            }

            // Power actions require an agent: the server routes reboot/sleep/off
            // to the connected agent, and Wake-on-LAN needs MAC addresses only an
            // agent reports. Relay (agentless) devices support none of it, so the
            // whole section is hidden for them.
            if !isLocal {
                Section("Power") {
                    PowerActionButton(icon: "ActionWake", title: "Wake", subtitle: "Send Wake-on-LAN",
                                      requiresConfirm: false) {
                        await run("Wake-on-LAN packet sent.") {
                            try await connection.wake(nodeId: node.id)
                        }
                    }

                    PowerActionButton(icon: "ActionRestart", title: "Restart",
                                      confirmTitle: "Restart \(node.name)?", confirmLabel: "Restart") {
                        await run("Restart command sent to \(node.name).") {
                            try await connection.powerAction(nodeId: node.id, action: .reboot)
                        }
                    }
                    .disabled(!node.hasAgent)

                    PowerActionButton(icon: "ActionSleep", title: "Sleep",
                                      confirmTitle: "Put \(node.name) to sleep?", confirmLabel: "Sleep") {
                        await run("Sleep command sent to \(node.name).") {
                            try await connection.powerAction(nodeId: node.id, action: .sleep)
                        }
                    }
                    .disabled(!node.hasAgent)

                    PowerActionButton(icon: "ActionPower", title: "Power Off", destructive: true,
                                      confirmTitle: "Power off \(node.name)?", confirmLabel: "Power Off") {
                        await run("Power-off command sent to \(node.name).") {
                            try await connection.powerAction(nodeId: node.id, action: .powerOff)
                        }
                    }
                    .disabled(!node.hasAgent)
                }
            }

            detailsSection(node)
        }
        .listStyle(.insetGrouped)
        .alert(actionFailed ? "Command Failed" : "Done", isPresented: Binding(
            get: { actionFeedback != nil },
            set: { if !$0 { actionFeedback = nil } }
        )) {
            Button("OK") { actionFeedback = nil }
        } message: {
            Text(actionFeedback ?? "")
        }
    }

    /// Runs a power/wake command, reporting the real outcome — the old code used
    /// `try?` and always claimed success even when the send failed.
    private func run(_ successMessage: String, _ command: @escaping () async throws -> Void) async {
        do {
            try await command()
            actionFailed = false
            actionFeedback = successMessage
        } catch {
            actionFailed = true
            actionFeedback = "The command couldn't be sent — the connection may have dropped. Pull to refresh the device list and try again."
        }
    }

    private func headerCard(_ node: MeshNode) -> some View {
        let isLocal = connection.isLocalDevice(node)
        let statusText = node.isOnline ? "Online" : (isLocal ? "Via Relay" : "Offline")
        let statusColor: Color = node.isOnline ? .green : (isLocal ? .teal : .secondary)
        return VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                DeviceGlyph(node: node, isLocal: isLocal, reachable: node.isOnline || isLocal, size: 50)
                    .frame(width: 84, height: 84)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                Circle()
                    .fill(node.isOnline ? Color.green : (isLocal ? Color.teal : Color(.systemGray4)))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color(.systemGroupedBackground), lineWidth: 3))
                    .offset(x: 4, y: 4)
            }

            Text(node.name)
                .font(.title3.weight(.semibold))

            Text(statusText)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(statusColor.opacity(0.15), in: Capsule())
                .foregroundStyle(statusColor)

            if let os = node.osDescription, !os.isEmpty {
                Text(os)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func detailsSection(_ node: MeshNode) -> some View {
        Section("Details") {
            if let group = connection.meshes.first(where: { $0.id == node.meshId }) {
                DetailRow(label: "Group", value: group.name)
            }
            let host = node.host?.trimmingCharacters(in: .whitespaces) ?? ""
            let ip = node.ip?.trimmingCharacters(in: .whitespaces) ?? ""
            if !host.isEmpty {
                DetailRow(label: "Address", value: host)
            }
            // Only show IP separately when it adds information beyond the address.
            if !ip.isEmpty, ip != host {
                DetailRow(label: "IP Address", value: ip)
            }
            if !node.users.isEmpty {
                DetailRow(label: "Signed In", value: node.users.joined(separator: ", "))
            }
            if let desc = node.desc, !desc.isEmpty {
                DetailRow(label: "Notes", value: desc)
            }
            if !node.tags.isEmpty {
                DetailRow(label: "Tags", value: node.tags.joined(separator: ", "))
            }
        }
    }
}

/// A power button that confirms with a popover anchored to the button itself,
/// so the bubble points at the tapped row. Wake skips the confirmation.
struct PowerActionButton: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var destructive: Bool = false
    var requiresConfirm: Bool = true
    var confirmTitle: String = ""
    var confirmLabel: String = ""
    let action: () async -> Void

    @State private var showConfirm = false

    var body: some View {
        Button(role: destructive ? .destructive : nil) {
            if requiresConfirm {
                showConfirm = true
            } else {
                Task { await action() }
            }
        } label: {
            ActionRow(icon: icon, title: title, subtitle: subtitle,
                      tint: destructive ? .red : .accentColor)
        }
        .popover(isPresented: $showConfirm) {
            VStack(spacing: 16) {
                Text(confirmTitle)
                    .font(.callout.weight(.semibold))
                    .multilineTextAlignment(.center)
                Button(confirmLabel, role: destructive ? .destructive : nil) {
                    showConfirm = false
                    Task { await action() }
                }
                .buttonStyle(.borderedProminent)
                .tint(destructive ? .red : .accentColor)
                Button("Cancel") { showConfirm = false }
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            .frame(minWidth: 240)
            .presentationCompactAdaptation(.popover)
        }
    }
}

struct ActionRow: View {
    /// Name of a custom template image asset in the catalog.
    let icon: String
    let title: String
    let subtitle: String?
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 12) {
            Image(icon)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .padding(5)
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .foregroundStyle(tint == .red ? Color.red : Color.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}
