import CoreImage
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Small JPEG stills taken from live playback, for tiles and widgets when
/// the provider has no snapshot endpoint (e.g. Home Services, bare streams).
enum FrameThumbnail {
    static let maxPixels = 640
    /// At most one stored still per camera per interval.
    static let interval: TimeInterval = 60

    static func jpeg(from pixelBuffer: CVPixelBuffer) -> Data? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        return image.flatMap(jpeg(from:))
    }

    static func jpeg(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let scale = min(1, Double(maxPixels) / Double(max(image.width, image.height)))
        var output = image
        if scale < 1, let context = CGContext(data: nil, width: Int(Double(image.width) * scale), height: Int(Double(image.height) * scale), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
            output = context.makeImage() ?? image
        }
        CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Decodes one keyframe sample (RTSP) into a still.
    static func jpeg(fromKeyframe sample: CMSampleBuffer) -> Data? {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session) == noErr, let session else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }
        var result: Data?
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr, let image { result = jpeg(from: image) }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return result
    }
}
