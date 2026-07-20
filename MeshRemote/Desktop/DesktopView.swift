import SwiftUI
import UIKit

/// Lets SwiftUI toolbar buttons reach the UIKit canvas (keyboard, modifiers).
@Observable
final class DesktopViewBridge {
    weak var canvas: DesktopCanvasView?
    weak var scrollView: UIScrollView?
    var keyboardVisible = false
    var modifierRevision = 0   // bumped so SwiftUI re-reads activeModifiers

    func toggleKeyboard() {
        guard let canvas else { return }
        if canvas.isFirstResponder {
            canvas.resignFirstResponder()
            keyboardVisible = false
        } else {
            canvas.becomeFirstResponder()
            keyboardVisible = true
        }
    }
}

/// UIScrollView + DesktopCanvasView wrapper with pinch-zoom and frame updates.
struct DesktopHostView: UIViewRepresentable {
    let session: DesktopSession
    let bridge: DesktopViewBridge

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = DesktopScrollView()
        scrollView.onBoundsSizeChange = { [weak coordinator = context.coordinator] in
            coordinator?.hostSizeChanged()
        }
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 4
        scrollView.minimumZoomScale = 0.05
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1)
        // Trackpad model: fingers move the cursor, never the viewport directly.
        // Pinch-zoom stays; the viewport auto-follows the cursor when zoomed in.
        scrollView.isScrollEnabled = false

        let canvas = DesktopCanvasView(frame: CGRect(origin: .zero, size: CGSize(width: 1, height: 1)))
        canvas.session = session
        canvas.onModifiersChanged = { [weak bridge] in
            bridge?.modifierRevision += 1
        }
        canvas.onCursorMoved = { [weak coordinator = context.coordinator] point in
            coordinator?.keepCursorVisible(point)
        }
        scrollView.addSubview(canvas)
        // Gestures live on the scroll view so they work across the whole screen,
        // not just where the canvas happens to be.
        canvas.attachGestures(to: scrollView)

        context.coordinator.canvas = canvas
        context.coordinator.scrollView = scrollView
        bridge.canvas = canvas
        bridge.scrollView = scrollView
        session.delegate = context.coordinator
        context.coordinator.startDisplayLink()

        if session.screenSize != .zero {
            context.coordinator.applyScreenSize(session.screenSize)
        }
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// UIScrollView that reports size changes (keyboard show/hide, rotation),
    /// so the remote screen can re-fit into the remaining visible area.
    final class DesktopScrollView: UIScrollView {
        var onBoundsSizeChange: (() -> Void)?
        private var lastSize: CGSize = .zero

        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != lastSize {
                lastSize = bounds.size
                onBoundsSizeChange?()
            }
        }
    }

    static func dismantleUIView(_ uiView: UIScrollView, coordinator: Coordinator) {
        coordinator.stopDisplayLink()
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate, DesktopSessionDelegate {
        weak var canvas: DesktopCanvasView?
        weak var scrollView: UIScrollView?
        private var displayLink: CADisplayLink?
        private var frameDirty = false
        private weak var dirtySession: DesktopSession?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent(scrollView)
            canvas?.updateCursorScale(1 / max(scrollView.zoomScale, 0.01))
        }

        /// Auto-pan so the cursor stays inside the visible area (with a margin).
        func keepCursorVisible(_ point: CGPoint) {
            guard let scrollView, let canvas else { return }
            guard scrollView.contentSize.width > scrollView.bounds.width ||
                  scrollView.contentSize.height > scrollView.bounds.height else { return }
            let margin: CGFloat = 60 / max(scrollView.zoomScale, 0.01)
            let rect = CGRect(x: point.x - margin, y: point.y - margin,
                              width: margin * 2, height: margin * 2)
            scrollView.scrollRectToVisible(canvas.convert(rect, to: scrollView), animated: false)
        }

        private func centerContent(_ scrollView: UIScrollView) {
            guard let canvas else { return }
            let offsetX = max((scrollView.bounds.width - canvas.frame.width) * 0.5, 0)
            let offsetY = max((scrollView.bounds.height - canvas.frame.height) * 0.5, 0)
            scrollView.contentInset = UIEdgeInsets(top: offsetY, left: offsetX, bottom: offsetY, right: offsetX)
        }

        func desktopFrameUpdated(_ session: DesktopSession) {
            frameDirty = true
            dirtySession = session
        }

        func desktopScreenSizeChanged(_ session: DesktopSession, size: CGSize) {
            applyScreenSize(size)
        }

        func applyScreenSize(_ size: CGSize) {
            guard let canvas, let scrollView, size.width > 0, size.height > 0 else { return }
            // Agents re-announce the screen size (e.g. right after our settings land);
            // don't disturb zoom/cursor when nothing changed.
            guard canvas.bounds.size != size else { return }
            // Setting `frame` on a zoomed (transformed) view rescales its bounds by
            // 1/zoomScale, inflating the coordinate space and desyncing mouse input
            // from the picture. Reset the zoom before sizing.
            scrollView.zoomScale = 1
            canvas.frame = CGRect(origin: .zero, size: size)
            scrollView.contentSize = size
            canvas.resetCursor(to: CGPoint(x: size.width / 2, y: size.height / 2))
            fitToScreen()
        }

        /// Zoom scale at which the whole framebuffer fits the current viewport.
        /// Uses canvas.bounds (untransformed size), so it's valid at any zoom.
        private func fitScale() -> CGFloat? {
            guard let canvas, let scrollView,
                  canvas.bounds.width > 0, canvas.bounds.height > 0 else { return nil }
            let fit = min(scrollView.bounds.width / canvas.bounds.width,
                          scrollView.bounds.height / canvas.bounds.height)
            return fit.isFinite && fit > 0 ? fit : nil
        }

        func fitToScreen() {
            guard let canvas, let scrollView, let fit = fitScale() else { return }
            scrollView.minimumZoomScale = min(fit, 1)
            scrollView.zoomScale = fit
            centerContent(scrollView)
            canvas.updateCursorScale(1 / max(fit, 0.01))
        }

        /// The viewport changed size (keyboard appeared/disappeared, rotation).
        /// Re-fit if the user was at fit zoom; otherwise keep their zoom and
        /// just re-center around the cursor in the remaining space.
        func hostSizeChanged() {
            guard let canvas, let scrollView, let fit = fitScale() else { return }
            let wasFitted = scrollView.zoomScale <= scrollView.minimumZoomScale + 0.0001
            scrollView.minimumZoomScale = min(fit, 1)
            if wasFitted || scrollView.zoomScale < scrollView.minimumZoomScale {
                scrollView.zoomScale = fit
                canvas.updateCursorScale(1 / max(fit, 0.01))
            }
            centerContent(scrollView)
            keepCursorVisible(canvas.cursorPosition)
        }

        func startDisplayLink() {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func tick() {
            guard frameDirty, let session = dirtySession, let canvas else { return }
            frameDirty = false
            if let image = session.currentImage() {
                canvas.updateFrame(image)
            }
        }
    }
}

struct DesktopView: View {
    let connection: MeshServerConnection
    let node: MeshNode

    @State private var session: DesktopSession?
    @State private var bridge = DesktopViewBridge()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.07, blue: 0.09).ignoresSafeArea()

            if let session {
                DesktopHostView(session: session, bridge: bridge)
                    .ignoresSafeArea(.container, edges: .bottom)

                switch session.state {
                case .connecting:
                    ConnectingOverlay(label: "Connecting to \(node.name)…")
                case .closed(let message):
                    SessionEndedOverlay(message: message) { dismiss() }
                case .connected:
                    EmptyView()
                }
            }
        }
        .navigationTitle(node.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if bridge.keyboardVisible {
                SpecialKeysBar(bridge: bridge)
            }
        }
        .task {
            guard session == nil else { return }
            let newSession = DesktopSession(connection: connection, node: node)
            session = newSession
            await newSession.start()
        }
        .onDisappear {
            session?.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            guard let session, session.state == .connected else { return }
            switch phase {
            case .background: session.setPaused(true)
            case .active: session.setPaused(false)
            default: break
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                bridge.toggleKeyboard()
            } label: {
                Image(systemName: bridge.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
            }

            Menu {
                if let session {
                    Picker("Quality", selection: Binding(
                        get: { session.quality },
                        set: { session.quality = $0 }
                    )) {
                        ForEach(DesktopQuality.allCases) { q in
                            Text(q.rawValue).tag(q)
                        }
                    }

                    if session.displays.count > 1 {
                        Menu("Display") {
                            ForEach(session.displays, id: \.self) { display in
                                Button {
                                    session.selectDisplay(display)
                                } label: {
                                    if display == session.selectedDisplay {
                                        Label(displayName(display), systemImage: "checkmark")
                                    } else {
                                        Text(displayName(display))
                                    }
                                }
                            }
                        }
                    }

                    Button("Refresh", systemImage: "arrow.clockwise") {
                        session.requestRefresh()
                    }
                    Button("Fit to Screen", systemImage: "arrow.down.right.and.arrow.up.left") {
                        // canvas.bounds is the framebuffer size regardless of zoom.
                        if let scrollView = bridge.scrollView, let canvas = bridge.canvas, canvas.bounds.width > 0 {
                            let fit = min(scrollView.bounds.width / canvas.bounds.width,
                                          scrollView.bounds.height / canvas.bounds.height)
                            scrollView.setZoomScale(fit, animated: true)
                        }
                    }
                    Button("Ctrl + Alt + Del", systemImage: "exclamationmark.triangle") {
                        session.sendCtrlAltDel()
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func displayName(_ display: Int) -> String {
        display == 0xFFFF ? "All Displays" : "Display \(display)"
    }
}

/// Modifier toggles and special keys shown above the on-screen keyboard.
struct SpecialKeysBar: View {
    let bridge: DesktopViewBridge

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                modifierKey("ctrl", vk: VirtualKey.control.rawValue)
                modifierKey("alt", vk: VirtualKey.alt.rawValue)
                modifierKey("shift", vk: VirtualKey.shift.rawValue)
                modifierKey("win", vk: VirtualKey.windows.rawValue)
                Divider().frame(height: 22)
                specialKey("esc", .escape)
                specialKey("tab", .tab)
                specialKey("del", .delete)
                Divider().frame(height: 22)
                specialKey(nil, .arrowLeft, symbol: "arrow.left")
                specialKey(nil, .arrowUp, symbol: "arrow.up")
                specialKey(nil, .arrowDown, symbol: "arrow.down")
                specialKey(nil, .arrowRight, symbol: "arrow.right")
                Divider().frame(height: 22)
                ForEach(1...12, id: \.self) { n in
                    specialKey("F\(n)", VirtualKey(rawValue: 111 + UInt8(n)) ?? .f1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func modifierKey(_ label: String, vk: UInt8) -> some View {
        // Reading modifierRevision makes this row refresh when toggles change.
        let isActive = bridge.modifierRevision >= 0 && (bridge.canvas?.activeModifiers.contains(vk) ?? false)
        return Button {
            bridge.canvas?.toggleModifier(vk)
        } label: {
            Text(label)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(isActive ? Color.accentColor : Color(.tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(isActive ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func specialKey(_ label: String?, _ key: VirtualKey, symbol: String? = nil) -> some View {
        Button {
            bridge.canvas?.sendSpecialKey(key)
        } label: {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.footnote.weight(.semibold))
                } else {
                    Text(label ?? "").font(.footnote.weight(.semibold))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
    }
}

struct ConnectingOverlay: View {
    let label: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(label)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct SessionEndedOverlay: View {
    let message: String?
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.slash.fill")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(message ?? "Session ended.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
            Button("Close", action: onDismiss)
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}
