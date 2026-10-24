import Foundation
import AVFoundation
import AppKit

// Local video inspection and editing. No network access or AI generation.
enum VideoError: Error { case invalid(String) }
func fail(_ message: String) throws -> Never { throw VideoError.invalid(message) }
func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
func stamp(_ seconds: Double) -> String {
    String(format: "%02d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
}
func asset(_ path: String) -> AVURLAsset { AVURLAsset(url: URL(fileURLWithPath: path)) }

struct Cut: Codable {
    let index: Int
    let source_start: Double
    let duration: Double
    let purpose: String
}
struct Edit: Codable {
    let source: String
    let sample_index: Int
    let cuts: [Cut]
}

func contact(_ path: String, _ output: String, _ start: Double, _ end: Double, _ step: Double) throws {
    guard end > start, step > 0 else { try fail("Invalid contact sheet interval") }
    let generator = AVAssetImageGenerator(asset: asset(path))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 384, height: 216)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let times = Array(stride(from: start, to: end, by: step))
    let columns = 4, cellWidth = 384, cellHeight = 244
    let rows = (times.count + columns - 1) / columns
    let width = columns * cellWidth, height = rows * cellHeight
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { try fail("Cannot create contact sheet") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSColor.black.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    for (i, seconds) in times.enumerated() {
        let cg = try generator.copyCGImage(at: time(seconds), actualTime: nil)
        let x = (i % columns) * cellWidth, y = height - (i / columns + 1) * cellHeight
        NSImage(cgImage: cg, size: NSSize(width: cellWidth, height: 216))
            .draw(in: NSRect(x: x, y: y + 28, width: cellWidth, height: 216))
        (stamp(seconds) as NSString).draw(at: NSPoint(x: x + 8, y: y + 4),
            withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 17)])
    }
    guard let png = bitmap.representation(using: .png, properties: [:]) else { try fail("Cannot encode contact sheet") }
    try png.write(to: URL(fileURLWithPath: output), options: .atomic)
    print("Contact sheet: \(output) (\(times.count) frames)")
}

func export(_ source: AVAsset, cuts: [Cut], output: URL, includeAudio: Bool) throws {
    guard !FileManager.default.fileExists(atPath: output.path) else { try fail("Refusing to overwrite \(output.path)") }
    guard let sourceVideo = source.tracks(withMediaType: .video).first else { try fail("No source video") }
    let sourceAudio = source.tracks(withMediaType: .audio).first
    if includeAudio && sourceAudio == nil { try fail("No source audio") }
    let composition = AVMutableComposition()
    guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { try fail("Cannot create video track") }
    let audio = includeAudio ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
    var cursor = CMTime.zero
    for cut in cuts {
        guard cut.source_start >= 1920, cut.source_start + cut.duration <= 2040, cut.duration > 0
            else { try fail("Cut outside the requested 32:00–34:00 range") }
        let range = CMTimeRange(start: time(cut.source_start), duration: time(cut.duration))
        try video.insertTimeRange(range, of: sourceVideo, at: cursor)
        if let a = audio, let s = sourceAudio { try a.insertTimeRange(range, of: s, at: cursor) }
        cursor = CMTimeAdd(cursor, range.duration)
    }
    let renderSize = CGSize(width: 1280, height: 720)
    let rect = CGRect(origin: .zero, size: sourceVideo.naturalSize).applying(sourceVideo.preferredTransform)
    let scale = min(renderSize.width / abs(rect.width), renderSize.height / abs(rect.height))
    let transform = sourceVideo.preferredTransform
        .concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        .concatenating(CGAffineTransform(translationX: (renderSize.width - abs(rect.width) * scale) / 2,
                                        y: (renderSize.height - abs(rect.height) * scale) / 2))
    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
    layer.setTransform(transform, at: .zero)
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
    instruction.layerInstructions = [layer]
    let videoComposition = AVMutableVideoComposition()
    videoComposition.renderSize = renderSize
    videoComposition.frameDuration = CMTime(value: 1, timescale: 25)
    videoComposition.instructions = [instruction]
    guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1280x720)
        else { try fail("Cannot create export session") }
    session.videoComposition = videoComposition
    if let a = audio {
        // Short fades prevent clicks at hard cuts without stretching original dialogue.
        let mix = AVMutableAudioMix()
        let parameters = AVMutableAudioMixInputParameters(track: a)
        var start = 0.0
        for cut in cuts {
            parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                timeRange: CMTimeRange(start: time(start), duration: time(0.02)))
            parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                timeRange: CMTimeRange(start: time(start + cut.duration - 0.02), duration: time(0.02)))
            start += cut.duration
        }
        mix.inputParameters = [parameters]
        session.audioMix = mix
    }
    session.outputURL = output
    session.outputFileType = .mp4
    session.shouldOptimizeForNetworkUse = true
    let done = DispatchSemaphore(value: 0)
    session.exportAsynchronously { done.signal() }
    done.wait()
    guard session.status == .completed else { try fail("Export failed: \(String(describing: session.error))") }
    print("Exported: \(output.lastPathComponent), \(CMTimeGetSeconds(cursor)) s, audio=\(includeAudio)")
}

func inspect(_ path: String) throws {
    let a = asset(path)
    guard let video = a.tracks(withMediaType: .video).first else { try fail("No video in \(path)") }
    let duration = CMTimeGetSeconds(a.duration)
    let generator = AVAssetImageGenerator(asset: a)
    generator.appliesPreferredTrackTransform = true
    for seconds in [0.0, duration / 2, max(0, duration - 0.08)] {
        _ = try generator.copyCGImage(at: time(seconds), actualTime: nil)
    }
    if let audio = a.tracks(withMediaType: .audio).first {
        let reader = try AVAssetReader(asset: a)
        let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        guard reader.startReading() else { try fail("Cannot decode audio") }
        var peak: Float = 0
        var count = 0
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let length = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = floats.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            guard status == noErr else { try fail("Cannot read audio PCM") }
            for value in floats { peak = max(peak, abs(value)) }
            count += floats.count
        }
        guard reader.status == .completed, count > 0, peak > 0 else { try fail("Audio decode failed or silent") }
        print("Audio decoded: \(count) samples, peak=\(peak)")
    }
    print("\(URL(fileURLWithPath: path).lastPathComponent): duration=\(duration), size=\(video.naturalSize), fps=\(video.nominalFrameRate), audio_tracks=\(a.tracks(withMediaType: .audio).count), decode=OK")
}

func mux(_ videoPath: String, _ soundPath: String, _ outputPath: String) throws {
    let generated = asset(videoPath), original = asset(soundPath)
    let outputURL = URL(fileURLWithPath: outputPath)
    guard !FileManager.default.fileExists(atPath: outputPath) else { try fail("Refusing to overwrite \(outputPath)") }
    guard let sourceVideo = generated.tracks(withMediaType: .video).first,
          let sourceAudio = original.tracks(withMediaType: .audio).first else { try fail("Missing video or original audio") }
    let duration = original.duration
    guard abs(CMTimeGetSeconds(duration) - 5) < 0.05,
          CMTimeGetSeconds(generated.duration) >= CMTimeGetSeconds(duration) - 0.02 else {
        try fail("Generated sample shorter than its five-second original")
    }
    let composition = AVMutableComposition()
    guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
          let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { try fail("Cannot create sample composition") }
    let range = CMTimeRange(start: .zero, duration: duration)
    try video.insertTimeRange(range, of: sourceVideo, at: .zero)
    try audio.insertTimeRange(range, of: sourceAudio, at: .zero)
    let renderSize = CGSize(width: 1280, height: 720)
    let rect = CGRect(origin: .zero, size: sourceVideo.naturalSize).applying(sourceVideo.preferredTransform)
    let scale = min(renderSize.width / abs(rect.width), renderSize.height / abs(rect.height))
    let transform = sourceVideo.preferredTransform
        .concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        .concatenating(CGAffineTransform(translationX: (renderSize.width - abs(rect.width) * scale) / 2,
                                        y: (renderSize.height - abs(rect.height) * scale) / 2))
    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
    layer.setTransform(transform, at: .zero)
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = range
    instruction.layerInstructions = [layer]
    let vc = AVMutableVideoComposition()
    vc.renderSize = renderSize
    vc.frameDuration = CMTime(value: 1, timescale: 25)
    vc.instructions = [instruction]
    guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1280x720)
        else { try fail("Cannot create mux export session") }
    session.videoComposition = vc
    session.outputURL = outputURL
    session.outputFileType = .mp4
    session.shouldOptimizeForNetworkUse = true
    let done = DispatchSemaphore(value: 0)
    session.exportAsynchronously { done.signal() }
    done.wait()
    guard session.status == .completed else { try fail("Mux failed: \(String(describing: session.error))") }
    print("Sample muxed with original audio only: \(outputPath)")
}

do {
    let args = CommandLine.arguments
    guard args.count >= 2 else { try fail("Usage: fight_video contact|prepare|inspect ...") }
    switch args[1] {
    case "contact":
        guard args.count == 7, let start = Double(args[4]), let end = Double(args[5]), let step = Double(args[6])
            else { try fail("contact SOURCE OUTPUT START END STEP") }
        try contact(args[2], args[3], start, end, step)
    case "prepare":
        guard args.count == 4 else { try fail("prepare EDIT_JSON OUTPUT_DIR") }
        let edit = try JSONDecoder().decode(Edit.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        guard edit.cuts.count == 9, edit.cuts.allSatisfy({ abs($0.duration - 5) < 0.001 }),
              Set(edit.cuts.map(\.index)).count == edit.cuts.count,
              edit.cuts.contains(where: { $0.index == edit.sample_index }) else { try fail("Expected nine unique five-second cuts and a valid sample index") }
        let out = URL(fileURLWithPath: args[3], isDirectory: true)
        let references = out.appendingPathComponent("参考片段", isDirectory: true)
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        let a = asset(edit.source)
        try export(a, cuts: edit.cuts, output: out.appendingPathComponent("原片精剪预览-45秒.mp4"), includeAudio: true)
        for cut in edit.cuts {
            try export(a, cuts: [cut], output: references.appendingPathComponent(String(format: "%02d-reference.mp4", cut.index)), includeAudio: false)
        }
        let sample = edit.cuts.first(where: { $0.index == edit.sample_index })!
        try export(a, cuts: [sample], output: out.appendingPathComponent("样片对应原片-5秒.mp4"), includeAudio: true)
    case "inspect":
        guard args.count >= 3 else { try fail("inspect VIDEO [VIDEO ...]") }
        for path in args.dropFirst(2) { try inspect(path) }
    case "mux":
        guard args.count == 5 else { try fail("mux GENERATED_VIDEO ORIGINAL_AUDIO_VIDEO OUTPUT") }
        try mux(args[2], args[3], args[4])
    default: try fail("Unknown command")
    }
} catch {
    fputs("ERROR: \(error)\n", stderr)
    exit(1)
}
