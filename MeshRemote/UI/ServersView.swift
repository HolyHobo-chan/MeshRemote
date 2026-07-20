import SwiftUI

/// Landing screen: saved servers and the add/edit flow.
struct ServersView: View {
    @Environment(AppState.self) private var app

    @State private var editingProfile: ServerProfile?
    @State private var showAddSheet = false
    @State private var connectingProfile: ServerProfile?
    @State private var connectError: String?
    @State private var passwordPrompt: ServerProfile?
    @State private var promptedPassword = ""

    var body: some View {
        NavigationStack {
            Group {
                if app.profiles.isEmpty {
                    emptyState
                } else {
                    serverList
                }
            }
            .navigationTitle("Mesh Remote")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                ServerFormView { profile, password in
                    app.profiles.append(profile)
                    if profile.autoConnect { app.setAutoConnect(true, for: profile) }
                    app.saveProfiles()
                    // Empty password means "don't save" — clear any stored one.
                    profile.password = password.isEmpty ? nil : password
                }
            }
            .sheet(item: $editingProfile) { profile in
                ServerFormView(existing: profile) { updated, password in
                    if let index = app.profiles.firstIndex(where: { $0.id == updated.id }) {
                        app.profiles[index] = updated
                    }
                    if updated.autoConnect { app.setAutoConnect(true, for: updated) }
                    app.saveProfiles()
                    updated.password = password.isEmpty ? nil : password
                }
            }
            .task { autoConnectIfWanted() }
            .alert("Connection Failed", isPresented: Binding(
                get: { connectError != nil },
                set: { if !$0 { connectError = nil } }
            )) {
                Button("OK") { connectError = nil }
            } message: {
                Text(connectError ?? "")
            }
            .alert("Password for \(passwordPrompt?.username ?? "")", isPresented: Binding(
                get: { passwordPrompt != nil },
                set: { if !$0 { passwordPrompt = nil } }
            )) {
                SecureField("Password", text: $promptedPassword)
                Button("Connect") {
                    if let profile = passwordPrompt {
                        connect(profile, password: promptedPassword)
                    }
                    promptedPassword = ""
                    passwordPrompt = nil
                }
                Button("Cancel", role: .cancel) {
                    promptedPassword = ""
                    passwordPrompt = nil
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("No Servers")
            } icon: {
                Image("ServerGlyph")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
            }
        } description: {
            Text("Add your MeshCentral server to get started.")
        } actions: {
            Button("Add Server") { showAddSheet = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var serverList: some View {
        List {
            ForEach(app.profiles) { profile in
                Button {
                    if let password = profile.password, !password.isEmpty {
                        connect(profile, password: password)
                    } else {
                        passwordPrompt = profile
                    }
                } label: {
                    HStack(spacing: 14) {
                        Image("ServerGlyph")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(profile.displayName.isEmpty ? profile.host : profile.displayName)
                                    .font(.headline)
                                    .foregroundStyle(Color.primary)
                                if profile.autoConnect {
                                    Image(systemName: "bolt.fill")
                                        .font(.caption2)
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            Text("\(profile.username) · \(profile.host)")
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }
                        Spacer()
                        if connectingProfile?.id == profile.id {
                            ProgressView()
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .disabled(connectingProfile != nil)
                .swipeActions(edge: .trailing) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        ProfileStore.delete(profile)
                        app.profiles.removeAll { $0.id == profile.id }
                    }
                    Button("Edit", systemImage: "pencil") {
                        editingProfile = profile
                    }
                    .tint(.orange)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// Once per launch: if a server is marked auto-connect and has a stored
    /// password, sign in without a tap.
    private func autoConnectIfWanted() {
        guard !app.hasAttemptedAutoConnect else { return }
        app.hasAttemptedAutoConnect = true
        guard app.connection == nil,
              let profile = app.profiles.first(where: \.autoConnect),
              let password = profile.password, !password.isEmpty else { return }
        connect(profile, password: password)
    }

    private func connect(_ profile: ServerProfile, password: String) {
        connectingProfile = profile
        let connection = MeshServerConnection(profile: profile)
        Task {
            defer { connectingProfile = nil }
            do {
                try await connection.connect(password: password)
                app.connection = connection
            } catch MeshError.twoFactorRequired {
                connectError = "This account requires a two-factor code. Edit the server and enter a current code before connecting."
                editingProfile = profile
            } catch {
                if case .failed(let message) = connection.state {
                    connectError = message
                } else {
                    connectError = error.localizedDescription
                }
            }
        }
    }
}

/// Add / edit server form.
struct ServerFormView: View {
    var existing: ServerProfile?
    let onSave: (ServerProfile, String) -> Void

    @State private var displayName = ""
    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var twoFactorCode = ""
    @State private var allowSelfSigned = false
    @State private var savePassword = true
    @State private var autoConnect = false
    @State private var connecting = false
    @State private var connectError: String?

    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name (optional)", text: $displayName)
                    TextField("host.example.com[:port]", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                }
                Section("Account") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    TextField("Two-factor code (if required)", text: $twoFactorCode)
                        .keyboardType(.numberPad)
                }
                Section {
                    Toggle("Save password", isOn: $savePassword)
                        .onChange(of: savePassword) { _, saves in
                            if !saves { autoConnect = false }
                        }
                    Toggle("Connect automatically on launch", isOn: $autoConnect)
                        .disabled(!savePassword)
                    Toggle("Allow self-signed certificate", isOn: $allowSelfSigned)
                } footer: {
                    Text("Passwords are stored in the iOS Keychain. Automatic connection requires a saved password and applies to one server at a time. Enable the certificate option only for servers you trust — most self-hosted MeshCentral servers use a self-signed certificate.")
                }
                if let connectError {
                    Section {
                        Label(connectError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if connecting {
                        ProgressView()
                    } else {
                        Button("Connect") { connectAndSave() }
                            .disabled(host.isEmpty || username.isEmpty || password.isEmpty)
                    }
                }
            }
            .onAppear {
                if let existing {
                    displayName = existing.displayName
                    host = existing.host
                    username = existing.username
                    allowSelfSigned = existing.allowSelfSigned
                    autoConnect = existing.autoConnect
                    let stored = existing.password
                    password = stored ?? ""
                    // Reflect reality: "Save password" on only if one is stored.
                    savePassword = stored != nil
                }
            }
        }
    }

    private func connectAndSave() {
        var profile = existing ?? ServerProfile()
        profile.displayName = displayName
        profile.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.allowSelfSigned = allowSelfSigned
        profile.autoConnect = autoConnect && savePassword

        connecting = true
        connectError = nil
        let connection = MeshServerConnection(profile: profile)
        Task {
            defer { connecting = false }
            do {
                try await connection.connect(password: password,
                                             token: twoFactorCode.isEmpty ? nil : twoFactorCode)
                onSave(profile, savePassword ? password : "")
                app.connection = connection
                dismiss()
            } catch {
                if case .failed(let message) = connection.state {
                    connectError = message
                } else {
                    connectError = error.localizedDescription
                }
            }
        }
    }
}
