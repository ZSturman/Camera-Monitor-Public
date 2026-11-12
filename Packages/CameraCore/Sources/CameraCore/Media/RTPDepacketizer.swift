import Foundation

/// One RTP packet header plus payload (RFC 3550).
struct RTPPacket: Equatable {
    var marker: Bool
    var payloadType: UInt8
    var sequence: UInt16
    var timestamp: UInt32
    var payload: Data

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0] >> 6 == 2 else { return nil }
        let padding = bytes[0] & 0x20 != 0
        let hasExtension = bytes[0] & 0x10 != 0
        let csrcCount = Int(bytes[0] & 0x0F)
        marker = bytes[1] & 0x80 != 0
        payloadType = bytes[1] & 0x7F
        sequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        timestamp = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        var offset = 12 + csrcCount * 4
        if hasExtension {
            guard bytes.count >= offset + 4 else { return nil }
            let words = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4 + words * 4
        }
        var end = bytes.count
        if padding, let last = bytes.last { end -= Int(last) }
        guard offset <= end else { return nil }
        payload = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end))
    }
}

/// A complete coded picture: NAL units without start codes or length
/// prefixes, sharing one RTP timestamp.
public struct VideoAccessUnit: Sendable, Equatable {
    public var nalUnits: [Data]
    public var timestamp: UInt32
    public var isKeyframe: Bool
}

/// Reassembles H.264 (RFC 6184: single NAL, STAP-A, FU-A) and H.265
/// (RFC 7798: single NAL, AP, FU) RTP payloads into access units.
struct RTPDepacketizer {
    let codec: VideoCodec
    /// Guards against a broken stream growing a frame without bound.
    static let maxAccessUnitBytes = 8 * 1024 * 1024

    private var pending: [Data] = []
    private var pendingBytes = 0
    private var pendingTimestamp: UInt32?
    private var fragment: Data?
    private var lastSequence: UInt16?
    private(set) var droppedPackets = 0

    init(codec: VideoCodec) {
        self.codec = codec
    }

    /// Feeds one RTP packet; returns any access units it completes.
    mutating func push(_ packet: RTPPacket) -> [VideoAccessUnit] {
        var completed: [VideoAccessUnit] = []
        if let last = lastSequence, packet.sequence != last &+ 1 {
            // Lost or reordered packet: a fragment in progress is unusable.
            droppedPackets += Int(packet.sequence &- last &- 1)
            fragment = nil
        }
        lastSequence = packet.sequence

        if let timestamp = pendingTimestamp, timestamp != packet.timestamp, let unit = flush() {
            completed.append(unit)
        }
        pendingTimestamp = packet.timestamp
        for nal in nalUnits(in: packet.payload) {
            pendingBytes += nal.count
            pending.append(nal)
        }
        if pendingBytes > Self.maxAccessUnitBytes {
            pending.removeAll()
            pendingBytes = 0
            fragment = nil
        }
        if packet.marker, let unit = flush() { completed.append(unit) }
        return completed
    }

    private mutating func flush() -> VideoAccessUnit? {
        defer {
            pending.removeAll(keepingCapacity: true)
            pendingBytes = 0
            pendingTimestamp = nil
        }
        guard !pending.isEmpty, let timestamp = pendingTimestamp else { return nil }
        return VideoAccessUnit(nalUnits: pending, timestamp: timestamp, isKeyframe: pending.contains { NALUnit.isKeyframe($0, codec: codec) })
    }

    private mutating func nalUnits(in payload: Data) -> [Data] {
        let bytes = [UInt8](payload)
        switch codec {
        case .h264: return h264(bytes, payload)
        case .h265: return h265(bytes, payload)
        }
    }

    private mutating func h264(_ bytes: [UInt8], _ payload: Data) -> [Data] {
        guard let first = bytes.first else { return [] }
        switch first & 0x1F {
        case 1...23:
            return [payload]
        case 24: // STAP-A
            return aggregated(bytes, headerLength: 1)
        case 28: // FU-A
            guard bytes.count > 2 else { return [] }
            let header = bytes[1]
            let start = header & 0x80 != 0, end = header & 0x40 != 0
            if start {
                fragment = Data([(first & 0xE0) | (header & 0x1F)]) + Data(bytes[2...])
            } else if fragment != nil {
                fragment?.append(contentsOf: bytes[2...])
            }
            guard end, let nal = fragment else { return [] }
            fragment = nil
            return [nal]
        default:
            return [] // STAP-B, MTAP, FU-B: not used by cameras over unicast
        }
    }

    private mutating func h265(_ bytes: [UInt8], _ payload: Data) -> [Data] {
        guard bytes.count >= 2 else { return [] }
        switch (bytes[0] >> 1) & 0x3F {
        case 48: // AP
            return aggregated(bytes, headerLength: 2)
        case 49: // FU
            guard bytes.count > 3 else { return [] }
            let header = bytes[2]
            let start = header & 0x80 != 0, end = header & 0x40 != 0
            if start {
                let type = header & 0x3F
                fragment = Data([(bytes[0] & 0x81) | (type << 1), bytes[1]]) + Data(bytes[3...])
            } else if fragment != nil {
                fragment?.append(contentsOf: bytes[3...])
            }
            guard end, let nal = fragment else { return [] }
            fragment = nil
            return [nal]
        case 50: // PACI
            return []
        default:
            return [payload]
        }
    }

    /// STAP-A / AP: 16-bit size-prefixed NAL units after the header.
    private func aggregated(_ bytes: [UInt8], headerLength: Int) -> [Data] {
        var result: [Data] = []
        var offset = headerLength
        while offset + 2 <= bytes.count {
            let size = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            guard size > 0, offset + size <= bytes.count else { break }
            result.append(Data(bytes[offset..<(offset + size)]))
            offset += size
        }
        return result
    }
}

enum NALUnit {
    static func type(_ nal: Data, codec: VideoCodec) -> UInt8? {
        guard let first = nal.first else { return nil }
        switch codec {
        case .h264: return first & 0x1F
        case .h265: return (first >> 1) & 0x3F
        }
    }

    static func isKeyframe(_ nal: Data, codec: VideoCodec) -> Bool {
        guard let type = type(nal, codec: codec) else { return false }
        switch codec {
        case .h264: return type == 5
        case .h265: return (16...21).contains(type)
        }
    }

    static func isParameterSet(_ nal: Data, codec: VideoCodec) -> Bool {
        guard let type = type(nal, codec: codec) else { return false }
        switch codec {
        case .h264: return type == 7 || type == 8
        case .h265: return (32...34).contains(type)
        }
    }

    /// Parameter sets, access unit delimiters and similar non-picture data
    /// that don't belong inside a sample buffer.
    static func isSampleData(_ nal: Data, codec: VideoCodec) -> Bool {
        guard let type = type(nal, codec: codec) else { return false }
        switch codec {
        case .h264: return !(7...9).contains(type)
        case .h265: return !(32...35).contains(type)
        }
    }
}
