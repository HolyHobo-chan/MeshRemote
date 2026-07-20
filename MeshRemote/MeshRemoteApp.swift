import SwiftUI

@main
struct MeshRemoteApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(Color("AccentColor"))
        }
    }
}

/// Root app state: saved servers and the active connection.
@Observable
@MainActor
final class AppState {
    var profiles: [ServerProfile] = ProfileStore.load()
    var connection: MeshServerConnection?
    /// Auto-connect fires once per app launch, so signing out doesn't loop back in.
    var hasAttemptedAutoConnect = false

    func saveProfiles() {
        ProfileStore.save(profiles)
    }

    /// Marks `profile` as the (only) auto-connect server, or clears it.
    func setAutoConnect(_ enabled: Bool, for profile: ServerProfile) {
        for index in profiles.indices {
            profiles[index].autoConnect = enabled && profiles[index].id == profile.id
        }
        saveProfiles()
    }

    func signOut() {
        connection?.disconnect()
        connection = nil
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let connection = app.connection, connection.state == .connected {
                DeviceListView(connection: connection)
            } else {
                ServersView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS may have severed the control socket while suspended. On return,
            // re-mint relay cookies and probe the connection so we don't show
            // stale "online" devices or hand expired cookies to new sessions.
            if phase == .active {
                Task { await app.connection?.refreshAfterForeground() }
            }
        }
    }
}
