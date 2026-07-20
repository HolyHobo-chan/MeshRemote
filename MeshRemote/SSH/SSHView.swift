import SwiftUI
import SwiftTerm
import UIKit

/// SwiftTerm terminal wired to an SSHSession.
struct SSHTerminalHostView: UIViewRepresentable {
    let session: SSHSession

    func makeUIView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        terminal.backgroundColor = UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1)
        terminal.nativeBackgroundColor = UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1)
        terminal.nativeForegroundColor = UIColor(red: 0.92, green: 0.94, blue: 0.96, alpha: 1)
        context.coordinator.terminal = terminal

        session.onOutput = { [weak terminal] data in
            terminal?.feed(byteArray: ArraySlice(data))
        }
        let size = terminal.getTerminal().getDims()
        session.resize(cols: size.cols, rows: size.rows)
        return terminal
    }

    func updateUIView(_ uiView: TerminalView, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: SSHSession
        weak var terminal: TerminalView?

        init(session: SSHSession) {
            self.session = session
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            Task { @MainActor in self.session.sendInput(data) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in self.session.resize(cols: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) { }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { }
        func scrolled(source: TerminalView, position: Double) { }
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { UIApplication.shared.open(url) }
        }
        func bell(source: TerminalView) { }
        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
            }
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) { }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) { }
    }
}

struct SSHView: View {
    let connection: MeshServerConnection
    let node: MeshNode

    @State private var session: SSHSession?
    @State private var username = ""
    @State private var password = ""
    @State private var keyPassphrase = ""
    @State private var rememberCredentials = false
    @State private var showCredentialSheet = false
    @Environment(\.dismiss) private var dismiss

    /// True when the device has a stored SSH key and the server only wants its passphrase.
    private var keyPassOnly: Bool {
        if case .needsCredentials(let keyPassOnly, _) = session?.state { return keyPassOnly }
        return false
    }

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.07, blue: 0.09).ignoresSafeArea()

            if let session {
                SSHTerminalHostView(session: session)
                    .padding(.horizontal, 2)

                switch session.state {
                case .connecting, .authenticating:
                    ConnectingOverlay(label: session.state == .connecting
                                      ? "Connecting to \(node.name)…" : "Signing in…")
                case .closed(let message):
                    SessionEndedOverlay(message: message) { dismiss() }
                case .needsCredentials, .connected:
                    EmptyView()
                }
            }
        }
        .navigationTitle("SSH — \(node.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            guard session == nil else { return }
            let newSession = SSHSession(connection: connection, node: node)
            session = newSession
            await newSession.start()
        }
        .onDisappear {
            session?.stop()
        }
        .onChange(of: session?.state) { _, newState in
            if case .needsCredentials = newState {
                showCredentialSheet = true
            } else {
                showCredentialSheet = false
            }
        }
        .sheet(isPresented: $showCredentialSheet) {
            credentialSheet
                .presentationDetents([.medium])
                .interactiveDismissDisabled()
        }
    }

    @ViewBuilder
    private var credentialSheet: some View {
        NavigationStack {
            Form {
                if case .needsCredentials(_, let error) = session?.state, let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
                if keyPassOnly {
                    Section {
                        SecureField("Key passphrase", text: $keyPassphrase)
                            .textContentType(.password)
                    } header: {
                        Text("SSH Key for \(node.name)")
                    } footer: {
                        Text("This device has a stored SSH private key. Enter its passphrase to unlock it.")
                    }
                } else {
                    Section("SSH Login for \(node.name)") {
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                    }
                    Section {
                        Toggle("Remember on server", isOn: $rememberCredentials)
                    } footer: {
                        Text("Stores these credentials on the MeshCentral server for future sessions.")
                    }
                }
            }
            .navigationTitle("SSH Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        if keyPassOnly {
                            session?.submitKeyPassphrase(keyPassphrase)
                        } else {
                            session?.submitCredentials(username: username,
                                                       password: password,
                                                       remember: rememberCredentials)
                        }
                    }
                    .disabled(keyPassOnly ? keyPassphrase.isEmpty : (username.isEmpty || password.isEmpty))
                }
            }
        }
    }
}
