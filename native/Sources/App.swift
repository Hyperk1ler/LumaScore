import AVFoundation
import AppKit
import SwiftUI

@main
struct LumaScoreApp: App {
  @StateObject private var studio:StudioModel
  init() {
    let model=StudioModel()
    _studio=StateObject(wrappedValue:model)
    if CommandLine.arguments.contains("--benchmark")
      || CommandLine.arguments.contains("--self-test")
    {
      NativeCLI.run()
      exit(0)
    }
    if CommandLine.arguments.contains("--preview") {
      model.settings=StudioSettings()
      model.settings.scene=NativeCLI.option("--scene") == "audio" ? .audio:.midi
      model.settings.title=NativeCLI.option("--title") ?? ""
      model.settings.artist=NativeCLI.option("--artist") ?? ""
      model.settings.genre=NativeCLI.option("--genre") ?? ""
      model.settings.crtEnabled=CommandLine.arguments.contains("--crt")
      if let template=AudioTemplate(rawValue:NativeCLI.option("--template") ?? "Orbit"){model.selectAudioTemplate(template)}
      model.settings.metronomeEnabled=CommandLine.arguments.contains("--metronome")
      if let audio=NativeCLI.option("--audio"){model.loadAudio(URL(fileURLWithPath:audio))}
      if let midi=NativeCLI.option("--midi"){model.loadMIDI([URL(fileURLWithPath:midi)])}
      DispatchQueue.main.asyncAfter(deadline:.now()+2){model.seek(1)}
    }
  }
  var body: some Scene {
    WindowGroup("LumaScore") {
      StudioView().environmentObject(studio).onOpenURL { studio.acceptDrop([$0]) }
    }.defaultSize(width: 1280, height: 800).windowToolbarStyle(.unified)
      .commands {
        CommandGroup(replacing: .newItem) {
          Button("导入音频…") { studio.chooseAudio() }.keyboardShortcut("o")
          Button("导入 MIDI…") { studio.chooseMIDI() }.keyboardShortcut(
            "o", modifiers: [.command, .shift])
          Divider()
          Button("打开项目…") { studio.chooseProject() }.keyboardShortcut(
            "o", modifiers: [.command, .option])
          Button("保存项目…") { studio.saveProject() }.keyboardShortcut("s")
          Divider()
          Button("导出 MP4…") { studio.export() }.keyboardShortcut("e").disabled(
            (studio.tracks.isEmpty && studio.audioURL == nil) || studio.exportProgress != nil || studio.importing || studio.analyzingAudio)
        }
        CommandGroup(replacing: .help) {
          Button("关于 LumaScore / About") {
            let alert = NSAlert()
            alert.messageText = "LumaScore \(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "2.6.0")"
            alert.informativeText =
              "SwiftUI + Metal + AVFoundation 视觉工作室。\nMIDI、音频频谱和混合场景；媒体在本机处理。\n本地字体、GPU 特效和视频导出。"
            alert.runModal()
          }
        }
      }
  }
}
enum NativeCLI {
  static func option(_ key: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: key), i + 1 < a.count else { return nil }
    return a[i + 1]
  }
  static func run() {
    do {
      if CommandLine.arguments.contains("--self-test") {
        try selfTest()
        return
      }
      guard let output = option("--output"), option("--midi") != nil || option("--audio") != nil else {
        throw StudioError.message(
          "Required: --benchmark --midi path --output path [--audio path] [--report path]")
      }
      let sequence = try option("--midi").map{try MIDIParser.parse(url:URL(fileURLWithPath:$0))} ?? MIDISequence(tracks:[],bpm:120,duration:0,minPitch:48,maxPitch:84)
      var settings = StudioSettings()
      settings.resolution = Int(option("--resolution") ?? "1080") ?? 1080
      settings.fps = Int(option("--fps") ?? "60") ?? 60
      settings.bitrate = 24
      settings.glow = Double(option("--glow") ?? "0") ?? 0
      settings.glowRadius = Double(option("--glow-radius") ?? "12") ?? 12
      settings.horizontalZoom = Double(option("--horizontal-zoom") ?? "1") ?? 1
      settings.pitchZoom = Double(option("--pitch-zoom") ?? "1") ?? 1
      settings.pitchScroll = Double(option("--pitch-scroll") ?? "0") ?? 0
      settings.playheadPosition = Double(option("--playhead-position") ?? "0.34") ?? 0.34
      settings.bpm = Double(option("--bpm") ?? "0") ?? 0
      settings.fisheye = Double(option("--fisheye") ?? "0") ?? 0
      settings.title = option("--title") ?? ""
      settings.codec = option("--codec") == "hevc" ? .hevc : .h264
      settings.intro = Double(option("--intro") ?? "0") ?? 0
      settings.offset = Double(option("--offset") ?? "0") ?? 0
      settings.exportStart = Double(option("--start") ?? "0") ?? 0
      settings.exportEnd = Double(option("--end") ?? "0") ?? 0
      settings.fadeIn = Double(option("--fade-in") ?? "0") ?? 0
      settings.fadeOut = Double(option("--fade-out") ?? "0") ?? 0
      settings.crtEnabled=CommandLine.arguments.contains("--crt")
      settings.chordEnabled=CommandLine.arguments.contains("--chords")
      settings.chordTrackIDs=sequence.tracks.map{$0.id}
      settings.artist=option("--artist") ?? ""
      settings.genre=option("--genre") ?? ""
      settings.scene=option("--scene") == "audio" ? .audio:(option("--scene") == "hybrid" ? .hybrid:.midi)
      settings.applyAudioTemplate(AudioTemplate(rawValue:option("--template") ?? "Orbit") ?? .orbit)
      settings.metronomeEnabled=CommandLine.arguments.contains("--metronome")
      if settings.metronomeEnabled && sequence.tracks.isEmpty && settings.bpm==0 {settings.bpm=120}
      settings.titleMotion=TextMotion(rawValue:option("--entrance") ?? "None") ?? .none
      settings.spectrumDepth=Double(option("--spectrum-depth") ?? "0") ?? 0
      settings.spectrumTilt=Double(option("--spectrum-tilt") ?? "0") ?? 0
      settings.spectrumInFront=CommandLine.arguments.contains("--spectrum-front")
      settings.container=option("--format") == "webm" ? .webm:.mp4
      settings.audioFadeIn=Double(option("--audio-fade-in") ?? "0") ?? 0
      settings.audioFadeOut=Double(option("--audio-fade-out") ?? "0") ?? 0
      let visualization=try option("--audio").map{try AudioAnalyzer.analyze(url:URL(fileURLWithPath:$0))}
      let styles = Dictionary(
        uniqueKeysWithValues: sequence.tracks.enumerated().map {
          ($0.element.id, TrackStyle(color: RGB.palette[$0.offset % RGB.palette.count]))
        })
      let snapshot = RenderSnapshot(
        tracks: sequence.tracks, styles: styles, settings: settings, bpm: sequence.bpm,
        duration: sequence.duration, minPitch: sequence.minPitch, maxPitch: sequence.maxPitch,
        backgroundURL: option("--background").map { URL(fileURLWithPath: $0) },audioVisualization:visualization,audioName:option("--audio").map{URL(fileURLWithPath:$0).deletingPathExtension().lastPathComponent} ?? "",coverURL:option("--cover").map{URL(fileURLWithPath:$0)},tempoMap:sequence.tempoMap)
      let semaphore = DispatchSemaphore(value: 0)
      var result: Result<ExportStatistics, Error>?
      let operation = ExportOperation(
        snapshot: snapshot, audioURL: option("--audio").map { URL(fileURLWithPath: $0) },
        destination: URL(fileURLWithPath: output), progress: { _ in },
        completion: { r in
          result = r
          semaphore.signal()
        })
      operation.startExport()
      if let delay = option("--cancel-after").flatMap(Double.init) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { operation.cancel() }
      }
      guard semaphore.wait(timeout: .now() + 600) == .success else {
        operation.cancel()
        throw StudioError.message("Export timed out")
      }
      let stats = try result!.get()
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(stats)
      print(String(data: data, encoding: .utf8)!)
      if let report = option("--report") { try data.write(to: URL(fileURLWithPath: report)) }
      if settings.container == .mp4 { try verifyVideo(URL(fileURLWithPath: output), expected: stats) }
    } catch {
      fputs("ERROR: \(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }
  private static func verifyVideo(_ url: URL, expected: ExportStatistics) throws {
    let asset = AVURLAsset(url: url)
    guard let video = asset.tracks(withMediaType: .video).first else {
      throw StudioError.message("Export contains no video")
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
    reader.add(output)
    guard reader.startReading() else {
      throw reader.error ?? StudioError.message("Cannot decode container")
    }
    var frames = 0
    while let sample = output.copyNextSampleBuffer() {
      frames += CMSampleBufferGetNumSamples(sample)
    }
    guard frames == expected.frames, Int(video.naturalSize.width) == expected.width,
      Int(video.naturalSize.height) == expected.height
    else { throw StudioError.message("Export frame count or dimensions mismatch: \(frames)") }
    if expected.audioIncluded && asset.tracks(withMediaType: .audio).isEmpty {
      throw StudioError.message("Export contains no audio")
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let image = try generator.copyCGImage(
      at: CMTime(seconds: max(0,min(option("--frame-time").flatMap(Double.init) ?? min(1,expected.duration/2),expected.duration-1/Double(expected.fps))), preferredTimescale: 600), actualTime: nil)
    if let frame = option("--frame") {
      let bitmap = NSBitmapImageRep(cgImage: image)
      try bitmap.representation(using: .png, properties: [:])!.write(
        to: URL(fileURLWithPath: frame))
    }
    print(
      "VERIFIED \(frames) frames, \(Int(video.naturalSize.width))x\(Int(video.naturalSize.height)), \(video.nominalFrameRate)fps, audio=\(expected.audioIncluded)"
    )
  }
  private static func selfTest() throws {
    var seed: UInt64 = 19
    func random() -> Double {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1
      return Double(seed >> 32) / Double(UInt32.max)
    }
    var notes: [MIDINote] = []
    for _ in 0..<10000 {
      notes.append(
        MIDINote(start: random() * 600, duration: random() * 60 + 0.02, pitch: 60, velocity: 1))
    }
    let index = NoteIndex(notes)
    for _ in 0..<150 {
      let from = random() * 600
      let to = from + 10
      var found: [Int] = []
      index.forEach(from: from, to: to) { i, _ in found.append(i) }
      let brute = index.notes.enumerated().filter {
        $0.element.start < to && $0.element.end >= from
      }.map { $0.offset }
      guard found == brute else { throw StudioError.message("Interval index mismatch") }
    }
    var s = StudioSettings()
    guard s.dimensions == (1920, 1080) else { throw StudioError.message("Aspect ratio mismatch") }
    s.aspect = .portrait
    guard s.dimensions == (1080, 1920) else { throw StudioError.message("Portrait mismatch") }
    print(
      "PASS: 150 randomized visible-window comparisons, 10,000 sustained notes, landscape and portrait dimensions"
    )
    if let midi = option("--midi") {
      let parsed = try MIDIParser.parse(url: URL(fileURLWithPath: midi))
      var settings = StudioSettings()
      settings.fps = 30
      settings.bpm = 138
      settings.glow = 0.28
      let encoded = try JSONEncoder().encode(settings)
      let restored = try JSONDecoder().decode(StudioSettings.self, from: encoded)
      guard restored.fps == 30, restored.bpm == 138, restored.glow == 0.28,
        restored.horizontalZoom == 1, restored.playheadPosition == 0.34
      else { throw StudioError.message("Settings round trip failed") }
      guard NumberInput.parse("148", range: 20...1000) == 148,
        NumberInput.parse("148,5", range: 20...1000) == 148.5,
        NumberInput.parse("", range: 20...1000) == nil,
        NumberInput.parse("nan", range: 20...1000) == nil, NumberInput.format(120) == "120"
      else { throw StudioError.message("Numeric editor parse failed") }
      var snap = RenderSnapshot(
        tracks: parsed.tracks, styles: [:], settings: StudioSettings(), bpm: parsed.bpm,
        duration: parsed.duration, minPitch: parsed.minPitch, maxPitch: parsed.maxPitch,
        backgroundURL: nil)
      let base = SceneViewport(snapshot: snap, width: 1920, height: 1080)
      snap.settings.horizontalZoom = 2
      snap.settings.pitchZoom = 2
      snap.settings.pitchScroll = 12
      snap.settings.playheadPosition = 0.7
      let moved = SceneViewport(snapshot: snap, width: 1920, height: 1080)
      guard abs(moved.pixelsPerSecond / base.pixelsPerSecond - 2) < 0.0001,
        abs(moved.pixelsPerPitch / base.pixelsPerPitch - 2) < 0.0001,
        abs(moved.x(noteTime: 3, timelineTime: 3) - 1344) < 0.001,
        abs(moved.y(pitch: base.pitchCenter + 12) - 540) < 0.001
      else { throw StudioError.message("Viewport transforms failed") }
      snap.settings.bpm = parsed.bpm * 2
      guard abs(snap.visualDuration - parsed.duration / 2) < 0.0001 else {
        throw StudioError.message("BPM scaling failed")
      }
      print(
        "PASS: settings round trip, numeric BPM edits, horizontal/vertical camera transforms, trigger-line placement and BPM timing"
      )
      print(
        "PARSED \(parsed.tracks.count) tracks, \(parsed.tracks.reduce(0){$0+$1.notes.count}) notes, \(parsed.duration)s, \(parsed.bpm) BPM"
      )
    }
  }
}
