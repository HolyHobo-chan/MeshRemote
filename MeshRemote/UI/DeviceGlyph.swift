import SwiftUI

/// The platform/type icon for a device: a brand asset for known platforms, the
/// proxy glyph for agentless relay devices, tinted to match reachability.
/// Assets are template-rendered so a single tint covers online/offline states.
struct DeviceGlyph: View {
    let node: MeshNode
    let isLocal: Bool
    var reachable: Bool = true
    var size: CGFloat = 22

    var body: some View {
        glyph
            .frame(width: size, height: size)
            .foregroundStyle(reachable ? Color.accentColor : Color.secondary)
    }

    @ViewBuilder
    private var glyph: some View {
        Image(assetName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
    }

    private var assetName: String {
        if isLocal { return "DeviceProxy" }
        switch node.osFamily {
        case .windows: return "DeviceWindows"
        case .linux: return "DeviceLinux"
        case .macos: return "DeviceMac"
        case .mobile: return "DevicePhone"
        case .other: return "DeviceDefault"
        }
    }
}
