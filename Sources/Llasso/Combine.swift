import AVFoundation
import AppKit

/// Joins a clip or a still picture with a sound into one clip, on this Mac. A plan's combine
/// step uses it, so a clip and the jingle made for it come back as one file.
enum Combine {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// The clip with the sound as its soundtrack, cut to the clip's length.
    static func clip(_ video: Data, with sound: Data, soundExt: String = "mp3") async throws -> Data {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let videoURL = dir.appendingPathComponent("clip.mp4")
        let soundURL = dir.appendingPathComponent("sound.\(soundExt)")
        try video.write(to: videoURL)
        try sound.write(to: soundURL)
        return try await mux(video: AVURLAsset(url: videoURL), sound: AVURLAsset(url: soundURL), in: dir, length: nil)
    }

    /// The picture held on screen for as long as the sound plays.
    static func still(_ image: Data, with sound: Data, soundExt: String = "mp3") async throws -> Data {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let soundURL = dir.appendingPathComponent("sound.\(soundExt)")
        try sound.write(to: soundURL)
        let soundAsset = AVURLAsset(url: soundURL)
        let length = try await soundAsset.load(.duration)
        guard length.seconds > 0 else { throw Failure(message: "The sound has no length.") }
        let stillURL = dir.appendingPathComponent("still.mp4")
        try await writeStill(image, length: length, to: stillURL)
        return try await mux(video: AVURLAsset(url: stillURL), sound: soundAsset, in: dir, length: length)
    }

    private static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("llasso-combine-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func mux(video: AVURLAsset, sound: AVURLAsset, in dir: URL, length: CMTime?) async throws -> Data {
        guard let v = try await video.loadTracks(withMediaType: .video).first else { throw Failure(message: "The clip has no picture.") }
        guard let a = try await sound.loadTracks(withMediaType: .audio).first else { throw Failure(message: "The sound has no audio.") }
        let videoLength = try await video.load(.duration)
        let soundLength = try await sound.load(.duration)
        let total = length ?? videoLength
        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw Failure(message: "Llasso couldn't set up the clip.") }
        try cv.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(videoLength, total)), of: v, at: .zero)
        cv.preferredTransform = try await v.load(.preferredTransform)
        try ca.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(soundLength, total)), of: a, at: .zero)
        let out = dir.appendingPathComponent("combined.mp4")
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure(message: "Llasso couldn't export the clip.")
        }
        try await export.export(to: out, as: .mp4)
        return try Data(contentsOf: out)
    }

    /// A clip of one picture, written with two frames: one at the start and one at the end.
    private static func writeStill(_ image: Data, length: CMTime, to url: URL) async throws {
        guard let cg = NSImage(data: image)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure(message: "The picture couldn't be read.")
        }
        // H.264 wants even sides; keep the picture under 1920 on its long side.
        let scale = min(1, 1920 / Double(max(cg.width, cg.height)))
        let w = Int(Double(cg.width) * scale) / 2 * 2, h = Int(Double(cg.height) * scale) / 2 * 2
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure(message: "Llasso couldn't write the clip.") }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32ARGB, nil, &buffer)
        guard let buffer else { throw Failure(message: "Llasso couldn't draw the picture.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for time in [CMTime.zero, length] {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 10_000_000) }
            adaptor.append(buffer, withPresentationTime: time)
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? Failure(message: "Llasso couldn't finish the clip.") }
    }
}
