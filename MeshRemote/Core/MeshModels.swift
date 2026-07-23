import Foundation

/// A device group ("mesh").
struct Mesh: Identifiable, Hashable {
    let id: String          // "mesh/<domain>/<hash>"
    var name: String
    var desc: String?
    var mtype: Int          // 1=AMT-only, 2=agent, 3=local, 4=IP-KVM

    init?(json: [String: Any]) {
        guard let id = json["_id"] as? String, let name = json["name"] as? String else { return nil }
        self.id = id
        self.name = name
        self.desc = json["desc"] as? String
        self.mtype = json["mtype"] as? Int ?? 2
    }
}

/// A managed device ("node").
struct MeshNode: Identifiable, Hashable {
    let id: String          // "node/<domain>/<hash>"
    var meshId: String
    var name: String
    var realName: String?
    var host: String?
    var icon: Int
    var conn: Int           // bitmask: 1 agent, 2 CIRA, 4 AMT, 8 relay, 16 MQTT
    var pwr: Int
    var osDescription: String?
    var ip: String?
    var users: [String]
    var mtype: Int          // 3 = agent device, 1 = AMT
    var agentId: Int?       // agent.id: MeshCentral agent build/platform number (informational)
    var agentCaps: Int?
    var desc: String?
    var tags: [String]
    var sshPort: Int?
    var rdpPort: Int?

    var isOnline: Bool { conn & 1 != 0 || conn & 8 != 0 }
    var hasAgent: Bool { conn & 1 != 0 }

    /// The agent offers a shell terminal. Capability bit 2 = Terminal; a nil caps
    /// value means a legacy/unknown agent, which we optimistically treat as capable.
    var supportsTerminal: Bool { agentCaps == nil || (agentCaps! & 2) != 0 }

    init?(json: [String: Any], meshId: String) {
        guard let id = json["_id"] as? String else { return nil }
        self.id = id
        self.meshId = meshId
        self.name = json["name"] as? String ?? "Unknown"
        self.realName = json["rname"] as? String
        self.host = json["host"] as? String
        self.icon = json["icon"] as? Int ?? 1
        self.conn = json["conn"] as? Int ?? 0
        self.pwr = json["pwr"] as? Int ?? 0
        self.osDescription = json["osdesc"] as? String
        self.ip = json["ip"] as? String
        self.users = json["users"] as? [String] ?? []
        self.mtype = json["mtype"] as? Int ?? 3
        if let agent = json["agent"] as? [String: Any] {
            self.agentId = agent["id"] as? Int
            self.agentCaps = agent["caps"] as? Int
        }
        self.desc = json["desc"] as? String
        self.tags = json["tags"] as? [String] ?? []
        self.sshPort = json["sshport"] as? Int
        self.rdpPort = json["rdpport"] as? Int
    }

    /// Merge a partial node object from a changenode event.
    mutating func merge(json: [String: Any]) {
        if let v = json["name"] as? String { name = v }
        if let v = json["rname"] as? String { realName = v }
        if let v = json["host"] as? String { host = v }
        if let v = json["icon"] as? Int { icon = v }
        if let v = json["conn"] as? Int { conn = v }
        if let v = json["pwr"] as? Int { pwr = v }
        if let v = json["osdesc"] as? String { osDescription = v }
        if let v = json["ip"] as? String { ip = v }
        if let v = json["users"] as? [String] { users = v }
        if let v = json["desc"] as? String { desc = v }
        if let v = json["tags"] as? [String] { tags = v }
        if let v = json["sshport"] as? Int { sshPort = v }
        if let agent = json["agent"] as? [String: Any] {
            if let v = agent["id"] as? Int { agentId = v }
            if let v = agent["caps"] as? Int { agentCaps = v }
        }
    }

    /// Human OS family, classified from the server-reported OS description
    /// (osdesc), which the agent keeps current. When there's no usable
    /// description (common for mobile devices, which often report none), fall
    /// back to matching the device name. Only affects the icon and the file
    /// browser's starting path, so a name-based guess is low-risk.
    var osFamily: OSFamily {
        if let os = osDescription?.lowercased(), !os.isEmpty {
            if os.contains("windows") { return .windows }
            if os.contains("macos") || os.contains("mac os") || os.contains("os x") || os.contains("darwin") { return .macos }
            if os.contains("android") || os.contains("ios") || os.contains("iphone") || os.contains("ipad") { return .mobile }
            if os.contains("linux") || os.contains("ubuntu") || os.contains("debian") || os.contains("fedora")
                || os.contains("centos") || os.contains("raspbian") || os.contains("alpine") || os.contains("bsd") {
                return .linux
            }
        }
        // Fallback: the OS description was missing or unrecognized. Apple mobile
        // devices report model names like "iPhone14,2" / "iPad13,1".
        let hint = (osDescription.map { $0.isEmpty ? name : $0 } ?? name).lowercased()
        if hint.contains("iphone") || hint.contains("ipad") || hint.contains("ipod") || hint.contains("android") {
            return .mobile
        }
        return .other
    }
}

enum OSFamily {
    case windows, linux, macos, mobile, other
}

struct ServerInfo {
    var name: String?
    var domain: String?
    var features: Int
    var features2: Int

    init(json: [String: Any]) {
        name = json["name"] as? String
        domain = json["domain"] as? String
        features = json["features"] as? Int ?? 0
        features2 = json["features2"] as? Int ?? 0
    }
}

struct UserInfo {
    var id: String
    var name: String
    var realName: String?
    var email: String?
    var siteAdmin: Int

    init?(json: [String: Any]) {
        guard let id = json["_id"] as? String, let name = json["name"] as? String else { return nil }
        self.id = id
        self.name = name
        self.realName = json["realname"] as? String
        self.email = json["email"] as? String
        self.siteAdmin = json["siteadmin"] as? Int ?? 0
    }
}

/// Relay usage numbers (the p= query param). SSH uses a separate endpoint,
/// so only the two agent-relay protocols this app opens are listed.
enum RelayProtocol: Int {
    case terminal = 1   // agent shell (cmd on Windows, bash on Unix)
    case desktop = 2
    case files = 5
}

enum PowerActionType: Int {
    case powerOff = 2
    case reboot = 3
    case sleep = 4
}
