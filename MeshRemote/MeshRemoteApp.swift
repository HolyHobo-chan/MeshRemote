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
    @State private var backgroundGrace = BackgroundGrace()

    var body: some View {
        Group {
            // Stay on the device list for the whole life of a connection, not
            // just while it's healthy. A dropped socket is shown as a banner
            // over the list; unmounting here would throw away the navigation
            // stack every time iOS suspends the app for a few seconds.
            if let connection = app.connection {
                DeviceListView(connection: connection)
            } else {
                ServersView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // Hold the app awake for the grace period iOS allows, so a quick
                // switch to a password manager or authenticator leaves the control
                // socket and any open tunnels connected.
                if app.connection != nil { backgroundGrace.begin() }
            case .active:
                backgroundGrace.end()
                // If the grace window ran out, iOS suspended us and severed the
                // socket. Re-mint relay cookies, or redial, so we never show stale
                // "online" devices or hand expired cookies to a new session.
                Task { await app.connection?.refreshAfterForeground() }
            default:
                break
            }
        }
    }
}
