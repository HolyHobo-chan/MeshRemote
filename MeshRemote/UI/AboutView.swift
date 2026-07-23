import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    /// The app icon, pulled from the compiled bundle so it always matches
    /// whatever icon the app actually shipped with.
    private var appIcon: UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last else { return nil }
        return UIImage(named: name)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        if let appIcon {
                            Image(uiImage: appIcon)
                                .resizable()
                                .frame(width: 84, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                        } else {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.system(size: 40))
                                .foregroundStyle(Color.accentColor)
                        }
                        Text("MeshRemote")
                            .font(.title2.weight(.semibold))
                        Text("Version \(version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                }

                Section("What this app is for") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("MeshRemote is a companion app for your MeshCentral server. It was built for the essentials: check which devices are online, open a remote desktop or SSH session, move a file, or wake and restart a machine.")
                        Text("This is intentionally a very simple management app. For anything more advanced such as adding devices and device groups, user accounts and permissions, changing server settings, using Intel AMT, or scripting. You should just use the MeshCentral web interface in your browser.")
                    }
                    .font(.callout)
                }

                Section("Acknowledgements") {
                    DisclosureGroup("MeshCentral") {
                        Text("MeshRemote is an independent client for MeshCentral and is not affiliated with or endorsed by the MeshCentral project. MeshCentral is © Intel Corporation, created by Ylian Saint-Hilaire, and licensed under the Apache License 2.0 (apache.org/licenses/LICENSE-2.0). This app contains no MeshCentral code. It communicates with MeshCentral servers over their published interfaces.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)

                    DisclosureGroup("SwiftTerm") {
                        Text(Self.swiftTermLicense)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)

                    DisclosureGroup("Trademarks") {
                        Text(Self.trademarkNotice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }

                Section {
                    if let url = URL(string: "https://paypal.me/HolyHoboDev") {
                        Link(destination: url) {
                            Label("Buy me a soda", systemImage: "soda.cup")
                        }
                    }
                } footer: {
                    Text("MeshRemote is free. If it saved you a trip to the server, a soda is always appreciated.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

extension AboutView {
    /// SwiftTerm's MIT license — shipped verbatim as required for distribution.
    static let swiftTermLicense = """
    Copyright (c) 2019-2022 Miguel de Icaza (https://github.com/migueldeicaza)
    Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
    Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
    Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """

    /// Trademark notice for the platform logos used as device-type icons.
    static let trademarkNotice = """
    Device-type icons depict third-party logos used only to identify the operating system of a device. MeshRemote is not affiliated with, endorsed by, or sponsored by these companies.

    Apple and the Apple logo are trademarks of Apple Inc., registered in the U.S. and other countries.

    Microsoft, Windows, and the Windows logo are trademarks of the Microsoft group of companies.

    Linux® is the registered trademark of Linus Torvalds in the U.S. and other countries. The Tux penguin logo was created by Larry Ewing.

    All other trademarks are the property of their respective owners.
    """
}
