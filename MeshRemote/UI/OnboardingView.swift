import SwiftUI
import UIKit

/// One first-run card. `imageName` is an asset-catalog screenshot; until that
/// screenshot is added the card falls back to `symbol`, so the flow always looks
/// intentional rather than showing an empty frame.
struct OnboardingPage: Identifiable {
    let id: String
    let imageName: String
    let symbol: String
    let title: String
    let message: String

    init(imageName: String, symbol: String, title: String, message: String) {
        self.id = imageName
        self.imageName = imageName
        self.symbol = symbol
        self.title = title
        self.message = message
    }

    /// The walkthrough, in the order a new user actually does it.
    static let all: [OnboardingPage] = [
        OnboardingPage(
            imageName: "OnboardWelcome",
            symbol: "macbook.and.iphone",
            title: "Welcome to MeshRemote",
            message: "Manage the devices on your MeshCentral server — remote desktop, terminal, SSH, files and power control, all from your iPhone or iPad."
        ),
        OnboardingPage(
            imageName: "OnboardAddServer",
            symbol: "plus.circle",
            title: "Add Your Server",
            message: "MeshRemote connects to a MeshCentral server that you run. Tap + on the Servers screen, then enter its address, like mesh.example.com."
        ),
        OnboardingPage(
            imageName: "OnboardSignIn",
            symbol: "person.badge.key",
            title: "Choose How You Sign In",
            message: "Pick Password for a local MeshCentral account, or Single Sign-On if your account uses an external provider. Add a two-factor code if your server asks for one."
        ),
        OnboardingPage(
            imageName: "OnboardStaySignedIn",
            symbol: "checkmark.shield",
            title: "Stay Signed In",
            message: "Turn this on to skip the password and two-factor code next time. Credentials are kept in the iOS Keychain, and you can revoke access anytime from MeshCentral."
        ),
        OnboardingPage(
            imageName: "OnboardDevices",
            symbol: "display",
            title: "You're Ready",
            message: "Your devices appear as soon as you connect. Tap any device to open remote desktop, a terminal, SSH, its files, or to send a power command."
        )
    ]
}

/// Swipeable first-run walkthrough. Shown once, and re-openable from the
/// Servers screen and About.
struct OnboardingView: View {
    var pages: [OnboardingPage] = OnboardingPage.all
    let onFinish: () -> Void

    @State private var selection = 0
    @Environment(\.dismiss) private var dismiss

    private var isLastPage: Bool { selection >= pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            header

            TabView(selection: $selection) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    card(page)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            footer
        }
        .background(Color(.systemGroupedBackground))
    }

    private var header: some View {
        HStack {
            Spacer()
            Button("Skip") { finish() }
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private func card(_ page: OnboardingPage) -> some View {
        VStack(spacing: 26) {
            Spacer(minLength: 8)

            artwork(page)

            VStack(spacing: 10) {
                Text(page.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(page.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 34)
        }
    }

    /// The screenshot when present, otherwise a symbol placeholder.
    @ViewBuilder
    private func artwork(_ page: OnboardingPage) -> some View {
        if UIImage(named: page.imageName) != nil {
            Image(page.imageName)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 340, maxHeight: 400)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
                .accessibilityHidden(true)
        } else {
            Image(systemName: page.symbol)
                .font(.system(size: 74, weight: .light))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: 340, minHeight: 220, maxHeight: 260)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 20))
                .accessibilityHidden(true)
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Button {
                if isLastPage {
                    finish()
                } else {
                    withAnimation { selection += 1 }
                }
            } label: {
                Text(isLastPage ? "Get Started" : "Next")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
        .padding(.top, 8)
    }

    private func finish() {
        onFinish()
        dismiss()
    }
}
