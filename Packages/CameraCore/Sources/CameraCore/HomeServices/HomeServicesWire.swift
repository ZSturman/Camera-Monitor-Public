import Foundation

/// Camera Monitor's client-side model of the Home Services `/api/v1`
/// contract (contract 1.0, published in the Home Services repository as
/// `contracts/v1/openapi.json` with recorded examples). Home Services owns
/// the contract; these types decode only what this app uses and tolerate
/// unknown fields. See docs/HOME_SERVICES_CONTRACT.md.
enum HomeServicesWire {
    static let contractHeader = "Home-Services-Contract"
    static let clientMajor = 1

    struct Bootstrap: Decodable {
        var server_id: String
        var product: String?
        var version: String?
        var environment: String?
        var contract: Contract
        var token: Token?
        var cameras: [CameraSummary]?

        struct Contract: Decodable {
            var version: String
            var supported_majors: [Int]
        }

        struct Token: Decodable {
            var name: String?
            var scopes: [String]
        }

        struct CameraSummary: Decodable {
            var id: String
            var name: String
        }
    }

    /// `available` or `unavailable` with a machine reason and a message.
    struct Capability: Decodable {
        var state: String
        var reason: String?
        var message: String?
        /// Extra fields some capabilities carry.
        var `protocol`: String?
        var granularity: String?
        var transport: String?
        var read_only: Bool?
        var effect: String?

        var isAvailable: Bool { state == "available" }
    }

    struct Capabilities: Decodable {
        var capabilities: Groups

        struct Groups: Decodable {
            var media: [String: Capability]?
            var notifications: [String: Capability]?
            var cameras: CameraGroup?
        }

        struct CameraGroup: Decodable {
            var engine: String?
        }
    }

    struct CameraList: Decodable {
        var cameras: [Camera]
        var engine: String?
    }

    struct Camera: Decodable {
        var id: String
        var name: String
        var kind: String?
        var engine: String?
        var armed: Bool?
        var armed_updated_at: Date?
        var status: Status?
        var capabilities: [String: Capability]
    }

    struct Status: Decodable {
        var state: String
        var reason: String?
        var detail: String?
        var observed_at: Date?
        var last_video_at: Date?
        var recording: Bool?
    }

    /// A media or live session: an opaque, expiring URL that needs no token.
    struct Session: Decodable {
        var url: String
        var kind: String?
        var `protocol`: String?
        var expires_at: Date?
    }

    struct LegacyEvents: Decodable {
        var events: [LegacyEvent]
    }

    struct LegacyEvent: Decodable {
        var id: String
        var started_at: Date?
        var ended_at: Date?
        var last_motion_at: Date?
        var camera_name: String?
        var media: [String]?
        var read_only: Bool?
    }

    struct RecordingList: Decodable {
        var recordings: [Recording]
        var next_cursor: String?
    }

    struct Recording: Decodable {
        var id: String
        var started_at: Date
        var ended_at: Date?
        var kind: String?
        var size_bytes: Int64?
        var protected: Bool?
        var active: Bool?
        var playable: Bool?
    }

    struct Protection: Encodable {
        var protected: Bool
    }

    struct Export: Decodable {
        var download_url: String?
        var url: String?
        var filename: String?
        var content_type: String?
        var expires_at: Date?
    }

    struct MediaSessionRequest: Encodable {
        var kind = "legacy_event_media"
        var event_id: String
        var name: String
    }

    struct Arming: Codable {
        var armed: Bool
    }

    struct ErrorEnvelope: Decodable {
        struct Body: Decodable {
            var code: String
            var message: String?
            var details: Details?
        }

        struct Details: Decodable {
            var supported_majors: [Int]?
            var required_scope: String?
            var message: String?
            var reason: String?
        }

        var error: Body
    }

    static var decoder: JSONDecoder { FlexibleDate.decoder }
}
