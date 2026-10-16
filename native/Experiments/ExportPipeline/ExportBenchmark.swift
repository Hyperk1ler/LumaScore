import AppKit
import AVFoundation
import Foundation

@main struct ExportBenchmark {
  static func option(_ key: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
    return args[index + 1]
  }
  static func main() throws {
    guard let output = option("--output") else { throw StudioError.message("--output is required") }
    let midi = try option("--midi").map { try MIDIParser.parse(url: URL(fileURLWithPath: $0)) }
      ?? MIDISequence(tracks: [], bpm: 120, duration: 0, minPitch: 48, maxPitch: 84)
    let audio = try option("--audio").map { try AudioAnalyzer.analyze(url: URL(fileURLWithPath: $0)) }
    var settings = StudioSettings()
    settings.resolution = Int(option("--resolution") ?? "1080") ?? 1080
    settings.fps = Int(option("--fps") ?? "60") ?? 60
    settings.bitrate = 24; settings.intro = Double(option("--intro") ?? "2") ?? 2
    settings.glow = Double(option("--glow") ?? "0.4") ?? 0.4
    settings.glowRadius = Double(option("--glow-radius") ?? "12") ?? 12
    settings.fisheye = Double(option("--fisheye") ?? "0") ?? 0
    settings.scene = option("--scene") == "audio" ? .audio : (option("--scene") == "hybrid" ? .hybrid : .midi)
    settings.codec = option("--codec") == "hevc" ? .hevc : .h264
    settings.applyAudioTemplate(AudioTemplate(rawValue: option("--template") ?? "Orbit") ?? .orbit)
    settings.title = option("--title") ?? ""; settings.bpm = midi.tracks.isEmpty ? 120 : 0
    settings.crtEnabled = CommandLine.arguments.contains("--crt")
    settings.metronomeEnabled = CommandLine.arguments.contains("--metronome")
    settings.exportStart = Double(option("--start") ?? "0") ?? 0
    settings.exportEnd = Double(option("--end") ?? "0") ?? 0
    let styles = Dictionary(uniqueKeysWithValues: midi.tracks.enumerated().map {
      ($0.element.id, TrackStyle(color: RGB.palette[$0.offset % RGB.palette.count]))
    })
    let snapshot = RenderSnapshot(tracks: midi.tracks, styles: styles, settings: settings,
      bpm: midi.bpm, duration: midi.duration, minPitch: midi.minPitch, maxPitch: midi.maxPitch,
      backgroundURL: nil, audioVisualization: audio, audioName: "Export performance test", tempoMap: midi.tempoMap)
    let done = DispatchSemaphore(value: 0)
    var result: Result<ExportStatistics, Error>?
    let operation = ExportOperation(snapshot: snapshot,
      audioURL: option("--audio").map { URL(fileURLWithPath: $0) }, destination: URL(fileURLWithPath: output),
      progress: { _ in }, completion: { result = $0; done.signal() })
    operation.startExport()
    if let cancel = option("--cancel-after").flatMap(Double.init) {
      DispatchQueue.global().asyncAfter(deadline: .now() + cancel) { operation.cancel() }
    }
    guard done.wait(timeout: .now() + 180) == .success else { operation.cancel(); throw StudioError.message("Export timeout") }
    let stats = try result!.get()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(stats)
    if let report = option("--report") { try data.write(to: URL(fileURLWithPath: report)) }
    print(String(data: data, encoding: .utf8)!)
    let asset = AVURLAsset(url: URL(fileURLWithPath: output))
    guard let track = asset.tracks(withMediaType: .video).first else { throw StudioError.message("Missing video") }
    let reader = try AVAssetReader(asset: asset)
    let video = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(video)
    guard reader.startReading() else { throw reader.error ?? StudioError.message("Readback failure") }
    var count = 0, timestamps: [Double] = []
    while let sample = video.copyNextSampleBuffer() {
      let samples = CMSampleBufferGetNumSamples(sample)
      if samples == 0 { continue } // Reader markers are not video frames.
      let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
      guard time.isFinite else { throw StudioError.message("Invalid presentation time") }
      timestamps.append(time); count += samples
    }
    // Compressed packets can arrive in decode order. Validate the complete
    // presentation grid, rather than assuming reader packet order is display order.
    for (index, time) in timestamps.sorted().enumerated() {
      guard abs(time - Double(index) / Double(stats.fps)) < 0.001 else { throw StudioError.message("Missing/duplicated presentation time") }
    }
    guard reader.status == .completed, count == stats.frames, Int(track.naturalSize.width) == stats.width,
      Int(track.naturalSize.height) == stats.height, abs(Double(track.nominalFrameRate) - Double(stats.fps)) < 0.01 else {
      throw StudioError.message("Invalid video frame count/dimensions/rate")
    }
    if stats.audioIncluded {
      guard let sound = asset.tracks(withMediaType: .audio).first else { throw StudioError.message("Missing audio") }
      let soundReader = try AVAssetReader(asset: asset)
      let soundOutput = AVAssetReaderTrackOutput(track: sound, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
        AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
      soundReader.add(soundOutput)
      guard soundReader.startReading() else { throw StudioError.message("Audio decode failed") }
      var first: Double?
      while let sample = soundOutput.copyNextSampleBuffer() {
        // Empty leading edits are decoded as real silent PCM. Locate the fixed
        // fixture's first audible sample; packet or track start is insufficient.
        if let block = CMSampleBufferGetDataBuffer(sample) {
          var length = 0; var pointer: UnsafeMutablePointer<Int8>?
          if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let pointer {
            let values = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
            for index in 0..<(length / MemoryLayout<Float>.stride) where abs(values[index]) > 0.001 {
              first = CMSampleBufferGetPresentationTimeStamp(sample).seconds + Double(index / 2) / 48000
              break
            }
          }
        }
        if first != nil { break }
      }
      soundReader.cancelReading()
      guard let first, abs(first - max(0, settings.intro - settings.exportStart)) < 0.05 else { throw StudioError.message("Audio lead-in mismatch") }
    }
    let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    let image = try generator.copyCGImage(at: CMTime(seconds: min(stats.duration - 1 / Double(stats.fps), 3), preferredTimescale: 600), actualTime: nil)
    if let frame = option("--frame") { try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: frame)) }
    print("VERIFIED \(count) frames, \(stats.width)x\(stats.height), \(stats.fps)fps, audio=\(stats.audioIncluded)")
  }
}
