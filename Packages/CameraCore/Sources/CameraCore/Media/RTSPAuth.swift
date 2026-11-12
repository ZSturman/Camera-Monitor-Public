import CryptoKit
import Foundation

/// RTSP (and HTTP) authentication challenge handling: Basic and MD5 Digest
/// (RFC 2617 / RFC 7616 with `qop=auth`), as used by IP cameras.
public enum RTSPAuthChallenge: Equatable, Sendable {
    case basic(realm: String?)
    case digest(realm: String, nonce: String, qop: String?, opaque: String?, algorithm: String?)

    /// Picks Digest over Basic when a server offers both.
    public static func parse(_ headers: [String]) -> RTSPAuthChallenge? {
        let parsed = headers.compactMap(parseOne)
        return parsed.first { if case .digest = $0 { true } else { false } } ?? parsed.first
    }

    static func parseOne(_ header: String) -> RTSPAuthChallenge? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else {
            return trimmed.lowercased() == "basic" ? .basic(realm: nil) : nil
        }
        let scheme = trimmed[..<space].lowercased()
        let params = parseParameters(String(trimmed[space...]))
        switch scheme {
        case "basic":
            return .basic(realm: params["realm"])
        case "digest":
            guard let realm = params["realm"], let nonce = params["nonce"] else { return nil }
            let algorithm = params["algorithm"]
            if let algorithm, algorithm.uppercased() != "MD5" { return nil }
            // Prefer "auth" when the server offers a qop list.
            let qop = params["qop"].flatMap { list in
                list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains("auth") ? "auth" : nil
            }
            return .digest(realm: realm, nonce: nonce, qop: qop, opaque: params["opaque"], algorithm: algorithm)
        default:
            return nil
        }
    }

    static func parseParameters(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var index = text.startIndex
        func skip(_ predicate: (Character) -> Bool) {
            while index < text.endIndex, predicate(text[index]) { index = text.index(after: index) }
        }
        while index < text.endIndex {
            skip { $0 == " " || $0 == "," }
            let keyStart = index
            skip { $0 != "=" && $0 != "," }
            let key = text[keyStart..<index].trimmingCharacters(in: .whitespaces).lowercased()
            guard index < text.endIndex, text[index] == "=" else { continue }
            index = text.index(after: index)
            var value = ""
            if index < text.endIndex, text[index] == "\"" {
                index = text.index(after: index)
                while index < text.endIndex, text[index] != "\"" {
                    if text[index] == "\\", text.index(after: index) < text.endIndex { index = text.index(after: index) }
                    value.append(text[index])
                    index = text.index(after: index)
                }
                if index < text.endIndex { index = text.index(after: index) }
            } else {
                let valueStart = index
                skip { $0 != "," }
                value = text[valueStart..<index].trimmingCharacters(in: .whitespaces)
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    public func authorization(method: String, uri: String, credential: ConnectionCredential, nonceCount: Int = 1, cnonce: String = RTSPAuthChallenge.makeCnonce()) -> String {
        let username = credential.username ?? ""
        switch self {
        case .basic:
            return "Basic " + Data("\(username):\(credential.password)".utf8).base64EncodedString()
        case let .digest(realm, nonce, qop, opaque, algorithm):
            let ha1 = Self.md5Hex("\(username):\(realm):\(credential.password)")
            let ha2 = Self.md5Hex("\(method):\(uri)")
            var fields = [
                "username=\"\(username)\"",
                "realm=\"\(realm)\"",
                "nonce=\"\(nonce)\"",
                "uri=\"\(uri)\"",
            ]
            let response: String
            if let qop {
                let nc = String(format: "%08x", nonceCount)
                response = Self.md5Hex("\(ha1):\(nonce):\(nc):\(cnonce):\(qop):\(ha2)")
                fields += ["qop=\(qop)", "nc=\(nc)", "cnonce=\"\(cnonce)\""]
            } else {
                response = Self.md5Hex("\(ha1):\(nonce):\(ha2)")
            }
            fields.append("response=\"\(response)\"")
            if let opaque { fields.append("opaque=\"\(opaque)\"") }
            if let algorithm { fields.append("algorithm=\(algorithm)") }
            return "Digest " + fields.joined(separator: ", ")
        }
    }

    public static func makeCnonce() -> String {
        (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
