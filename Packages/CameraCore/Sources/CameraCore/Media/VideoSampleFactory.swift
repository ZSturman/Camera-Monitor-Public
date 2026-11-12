import CoreMedia
import Foundation

/// Turns access units into CMSampleBuffers (AVCC, 4-byte lengths) that an
/// AVSampleBufferDisplayLayer decodes in hardware. Tracks parameter sets
/// from SDP and in-band, and holds frames back until the first keyframe so
/// the screen never shows a half-decoded picture.
public struct VideoSampleFactory {
    public let codec: VideoCodec
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var formatNeedsUpdate = true
    private var sawKeyframe = false

    public init(codec: VideoCodec, parameterSets: [Data] = []) {
        self.codec = codec
        parameterSets.forEach { remember($0) }
    }

    public var dimensions: CMVideoDimensions? {
        formatDescription.map(CMVideoFormatDescriptionGetDimensions)
    }

    /// Nil while waiting for parameter sets or the first keyframe.
    public mutating func sampleBuffer(for unit: VideoAccessUnit) throws -> CMSampleBuffer? {
        for nal in unit.nalUnits where NALUnit.isParameterSet(nal, codec: codec) { remember(nal) }
        if formatNeedsUpdate {
            guard let description = try makeFormatDescription() else { return nil }
            formatDescription = description
            formatNeedsUpdate = false
        }
        guard let formatDescription else { return nil }
        if !sawKeyframe {
            guard unit.isKeyframe else { return nil }
            sawKeyframe = true
        }

        let samples = unit.nalUnits.filter { NALUnit.isSampleData($0, codec: codec) }
        guard !samples.isEmpty else { return nil }
        let length = samples.reduce(0) { $0 + 4 + $1.count }
        var avcc = Data(capacity: length)
        for nal in samples {
            var size = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &size) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        guard status == noErr, let block else { throw VideoSampleError.coreMedia(status) }
        status = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) }
        guard status == noErr else { throw VideoSampleError.coreMedia(status) }

        var sample: CMSampleBuffer?
        var sampleSize = length
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { throw VideoSampleError.coreMedia(status) }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            // Live view: show each frame as soon as it's decoded.
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !unit.isKeyframe {
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }

    /// After a decoder failure, start again from the next keyframe.
    public mutating func resynchronize() {
        sawKeyframe = false
    }

    private mutating func remember(_ nal: Data) {
        guard let type = NALUnit.type(nal, codec: codec) else { return }
        switch (codec, type) {
        case (.h264, 7), (.h265, 33):
            if sps != nal { sps = nal; formatNeedsUpdate = true }
        case (.h264, 8), (.h265, 34):
            if pps != nal { pps = nal; formatNeedsUpdate = true }
        case (.h265, 32):
            if vps != nal { vps = nal; formatNeedsUpdate = true }
        default:
            break
        }
    }

    private func makeFormatDescription() throws -> CMVideoFormatDescription? {
        let sets: [Data]
        switch codec {
        case .h264:
            guard let sps, let pps else { return nil }
            sets = [sps, pps]
        case .h265:
            guard let vps, let sps, let pps else { return nil }
            sets = [vps, sps, pps]
        }
        var description: CMVideoFormatDescription?
        let status = withPointers(to: sets) { pointers, sizes in
            switch codec {
            case .h264:
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description
                )
            case .h265:
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else { throw VideoSampleError.badParameterSets(status) }
        return description
    }

    private func withPointers<R>(to sets: [Data], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
        let buffers = sets.map { data -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: pointer, count: data.count)
            return pointer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        return pointers.withUnsafeBufferPointer { p in sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!) } }
    }
}

public enum VideoSampleError: Error, LocalizedError, Equatable {
    case coreMedia(OSStatus)
    case badParameterSets(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .coreMedia(status): "Couldn't prepare a video frame (error \(status))."
        case let .badParameterSets(status): "The camera's video parameters couldn't be read (error \(status))."
        }
    }
}
