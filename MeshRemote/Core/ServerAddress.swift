import Foundation

/// Normalizes whatever the user types or pastes into the server field.
/// MeshCentral admins usually hand out a full URL — often with a path and a
/// `?key=` access key attached — so accept that shape and split it into the
/// pieces the form needs, rather than letting the connection fail on it.
enum ServerAddress {
    struct Parsed: Equatable {
        var host: String     // host[:port] plus any domain path ("/domain1"), no scheme
        var key: String?     // the ?key= login key, when the URL carried one
    }

    static func parse(_ raw: String) -> Parsed? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // URLComponents only finds a host when there's a scheme; ws/wss/http
        // all parse the same way, so any placeholder works.
        if !text.contains("://") { text = "https://" + text }
        guard let comps = URLComponents(string: text),
              let host = comps.host, !host.isEmpty else { return nil }

        // IPv6 literals must stay bracketed to be usable in a URL. Some
        // platforms hand back the brackets already, so only add them if missing.
        var result = (host.contains(":") && !host.hasPrefix("[")) ? "[\(host)]" : host
        if let port = comps.port, port != 443 { result += ":\(port)" }

        // MeshCentral serves each non-default domain under a path
        // (https://server/domain1/), so keep it. A trailing page or endpoint
        // (".../login.htm", ".../control.ashx") isn't part of the domain.
        var segments = comps.path.split(separator: "/")
        if segments.last?.contains(".") == true { segments.removeLast() }
        if !segments.isEmpty { result += "/" + segments.joined(separator: "/") }

        let key = comps.queryItems?.first { $0.name == "key" }?.value
        return Parsed(host: result, key: (key?.isEmpty == false) ? key : nil)
    }
}
