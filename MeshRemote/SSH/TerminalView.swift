import SwiftUI
import SwiftTerm
import UIKit

/// SwiftTerm terminal wired to a MeshCentral agent TerminalSession (no SSH).
struct AgentTerminalHostView: UIViewRepresentable {
    let session: TerminalSession

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
        let session: TerminalSession
        weak var terminal: TerminalView?

        init(session: TerminalSession) { self.session = session }

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

struct AgentTerminalView: View {
    let connection: MeshServerConnection
    let node: MeshNode

    @State private var session: TerminalSession?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.07, blue: 0.09).ignoresSafeArea()

            if let session {
                AgentTerminalHostView(session: session)
                    .padding(.horizontal, 2)

                switch session.state {
                case .connecting:
                    ConnectingOverlay(label: "Opening terminal on \(node.name)…")
                case .closed(let message):
                    SessionEndedOverlay(message: message) { dismiss() }
                case .connected:
                    if let banner = session.consoleMessage {
                        VStack {
                            Text(banner)
                                .font(.footnote)
                                .padding(10)
                                .background(.regularMaterial, in: Capsule())
                                .padding(.top, 8)
                            Spacer()
                        }
                    }
                }
            }
        }
        .navigationTitle("Terminal — \(node.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            guard session == nil else { return }
            let newSession = TerminalSession(connection: connection, node: node)
            session = newSession
            await newSession.start()
        }
        .onDisappear { session?.stop() }
    }
}
