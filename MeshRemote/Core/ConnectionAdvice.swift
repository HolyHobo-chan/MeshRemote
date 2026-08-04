import Foundation

/// Turns a connection failure into something the user can act on.
/// The raw URLError text ("The operation couldn't be completed") says nothing
/// about which setup field is wrong, which is exactly where a first-time user
/// gives up. Each case here names the likely cause and the fix.
enum ConnectionAdvice {
    static func message(for error: Error, profile: ServerProfile) -> String {
        if let mesh = error as? MeshError {
            switch mesh {
            case .authFailed(let message):
                return message
            case .twoFactorRequired:
                return "This account requires a two-factor code. Edit the server and enter a current code before connecting."
            case .badServerAddress:
                return "That server address isn't valid. Use the form host.example.com or host.example.com:8443."
            case .timeout(let what):
                return "Timed out waiting for \(what). The server may be busy or unreachable from this network."
            case .relayFailed(let message):
                return message
            case .notConnected:
                return "The connection dropped before it finished. Please try again."
            }
        }

        let host = profile.host.isEmpty ? "the server" : profile.host
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return error.localizedDescription }

        switch nsError.code {
        case NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorSecureConnectionFailed:
            return profile.allowSelfSigned
                ? "The server's certificate was rejected. Check that the address you entered matches the one on the certificate."
                : "The server's certificate isn't trusted. If this is your own server using a self-signed certificate, edit the server and turn on “Allow self-signed certificate.”"
        case NSURLErrorCannotFindHost:
            return "Couldn't find \(host). Check the address for typos."
        case NSURLErrorCannotConnectToHost:
            return "Couldn't reach \(host). Check the port, and that the server is running and reachable from this network."
        case NSURLErrorTimedOut:
            return "\(host) didn't respond. If the server is only reachable on your home network, join that network or connect to your VPN first."
        case NSURLErrorNotConnectedToInternet:
            return "This device isn't connected to the internet."
        case NSURLErrorNetworkConnectionLost:
            return "The network connection was lost. Please try again."
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL:
            return "That server address isn't valid. Use the form host.example.com or host.example.com:8443."
        default:
            return error.localizedDescription
        }
    }
}
