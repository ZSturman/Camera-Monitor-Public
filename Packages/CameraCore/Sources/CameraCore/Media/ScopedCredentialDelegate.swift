import Foundation

/// Answers HTTP auth challenges only for the stream's own origin, at most
/// once, and refuses redirects to another origin so credentials and
/// bearer tokens never follow a redirect elsewhere.
final class ScopedCredentialDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: URL
    let credential: ConnectionCredential?
    private(set) var rejectedRedirect = false
    private(set) var authenticationRejected = false

    init(origin: URL, credential: ConnectionCredential?) {
        self.origin = origin
        self.credential = credential
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased()
            && effectivePort(a) == effectivePort(b)
    }

    static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        case "rtsp": return 554
        case "rtsps": return 322
        default: return nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let target = request.url, Self.sameOrigin(origin, target) {
            completionHandler(request)
        } else {
            rejectedRedirect = true
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let space = challenge.protectionSpace
        let challengeMatchesOrigin = space.host.lowercased() == origin.host?.lowercased()
            && space.port == (Self.effectivePort(origin) ?? space.port)
        guard let credential, challengeMatchesOrigin, challenge.previousFailureCount == 0 else {
            authenticationRejected = true
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(user: credential.username ?? "", password: credential.password, persistence: .none))
    }
}
