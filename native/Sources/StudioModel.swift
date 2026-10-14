import AVFoundation
import AppKit
import SwiftUI

final class PlaybackClock:ObservableObject {
  @Published var time=0.0
}
final class StudioModel: ObservableObject {
  @Published var tracks: [MIDITrack] = []
  @Published var styles: [String: TrackStyle] = [:]
  @Published var settings = StudioSettings() {
    didSet {
      if !loadingProject { saveDefaults() }
      player?.volume = Float(settings.volume)
      if settings.intro != oldValue.intro { syncAudio() }
    }
  }
  @Published var audioURL: URL?
  @Published var midiURLs: [URL] = []
  @Published var backgroundURL: URL?
  @Published var coverURL: URL?
  @Published var audioVisualization: AudioVisualizationData?
  @Published var analyzingAudio = false
  private var audioGeneration = 0
  @Published var audioDuration = 0.0
  @Published var midiDuration = 0.0
  @Published var sourceBPM = 120.0
  var sourceTempoMap: [MIDITempo] = []
  private var midiSourceIDs:[Int]=[]
  private struct MIDISourceMetadata {
    var duration:Double, bpm:Double
    var tempoMap:[MIDITempo]
  }
  private var midiSources:[Int:MIDISourceMetadata]=[:]
  @Published var minPitch = 48
  @Published var maxPitch = 84
  let playbackClock=PlaybackClock()
  var time:Double {get{playbackClock.time}set{playbackClock.time=newValue}}
  @Published var playing = false
  @Published private(set) var preparingPlayback = false
  @Published var importing = false
  @Published var exportProgress: Double?
  @Published var exportStatistics: ExportStatistics?
  @Published var lastExportURL: URL?
  @Published var errorMessage: String?
  @Published var revision = 0
  @Published var status = "导入音频和 MIDI，开始创作"
  private var loadingProject = false
  private var previewingEntrance = false
  private var importGeneration = 0
  private var importingProject = false
  private var audioSeekGeneration = 0
  private var player: AVPlayer?
  private var audioReadyObservation: NSKeyValueObservation?
  private var observer: Any?
  private var ticker: Timer?
  private var operation: ExportOperation?
  private var previewBaseTime = 0.0, previewBegan = 0.0
  init() {
    if let data = UserDefaults.standard.data(forKey: "lumascore.settings.v1"),
      let saved = try? JSONDecoder().decode(StudioSettings.self, from: data),
      (try? saved.validate()) != nil
    {
      settings = saved
    }
    ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      self?.tick()
    }
  }
  deinit {
    ticker?.invalidate()
    operation?.cancel()
    if let observer = observer { player?.removeTimeObserver(observer) }
  }
  var totalDuration: Double { snapshot.timelineDuration(audioDuration: audioDuration) }
  var currentTime: Double {
    if playing {
      // One continuous preview clock, including the media lead-in. Switching to
      // a paused/buffering AVPlayer at the boundary used to freeze the picture.
      return min(totalDuration, previewBaseTime + ProcessInfo.processInfo.systemUptime - previewBegan)
    }
    return time
  }
  var snapshot: RenderSnapshot {
    RenderSnapshot(
      tracks: tracks, styles: styles, settings: settings, bpm: sourceBPM, duration: midiDuration,
      minPitch: minPitch, maxPitch: maxPitch, backgroundURL: backgroundURL,
      audioVisualization: audioVisualization, audioName: audioURL?.deletingPathExtension().lastPathComponent ?? "", coverURL: coverURL, tempoMap: sourceTempoMap)
  }
  var effectiveBPM:Double { settings.bpm > 0 ? settings.bpm:sourceBPM }
  func selectAudioTemplate(_ template: AudioTemplate) {
    var value=settings
    value.applyAudioTemplate(template)
    settings=value
  }
  func setMetronomeEnabled(_ enabled:Bool) {
    var value=settings
    value.metronomeEnabled=enabled
    if enabled && tracks.isEmpty && value.bpm==0 {value.bpm=effectiveBPM}
    settings=value
  }
  func previewEntrance() { pause();previewingEntrance=true;seek(0);play() }
  var noteCount: Int { tracks.reduce(0) { $0 + $1.notes.count } }
  func saveDefaults() {
    if (try? settings.validate()) != nil, let encoded = try? JSONEncoder().encode(settings) {
      UserDefaults.standard.set(encoded, forKey: "lumascore.settings.v1")
    }
  }
  private func tick() {
    guard playing else { return }
    time = currentTime
    let playbackEnd = !previewingEntrance && settings.exportEnd > settings.exportStart ? min(totalDuration,settings.exportEnd):totalDuration
    if time >= playbackEnd {
      if settings.loop {
        seek(previewingEntrance ? 0:settings.exportStart)
      } else {
        pause()
        time = playbackEnd
        return
      }
    }
    if let player = player {
      let fadeIn = settings.audioFadeEnabled && settings.audioFadeIn > 0 ? min(1,max(0,(time-settings.intro)/settings.audioFadeIn)):1
      let fadeOut = settings.audioFadeEnabled && settings.audioFadeOut > 0 ? min(1,max(0,(audioDuration+settings.intro-time)/settings.audioFadeOut)):1
      player.volume = Float(settings.volume*min(fadeIn,fadeOut))
    }
  }
  func togglePlayback() { (playing || preparingPlayback) ? pause() : play() }
  func play() {
    guard totalDuration > 0 else { return }
    let playbackEnd = !previewingEntrance && settings.exportEnd > settings.exportStart ? min(totalDuration,settings.exportEnd):totalDuration
    let playbackStart=previewingEntrance ? 0:settings.exportStart
    if time >= playbackEnd || time < playbackStart { time = min(totalDuration,playbackStart) }
    previewBaseTime = time
    previewBegan = ProcessInfo.processInfo.systemUptime
    // Without a lead-in, prepare before starting the clock so decoder startup
    // does not discard the beginning of the audio to catch up with the picture.
    preparingPlayback = player != nil && time >= settings.intro && time < settings.intro + audioDuration
    playing = !preparingPlayback
    syncAudio()
    status = preparingPlayback ? "准备预览音频 / Preparing audio…":"正在预览"
  }
  func pause() {
    time = currentTime
    playing = false
    preparingPlayback = false
    previewingEntrance = false
    audioSeekGeneration += 1
    audioReadyObservation = nil
    player?.cancelPendingPrerolls()
    player?.pause()
    status = "预览已暂停"
  }
  func seek(_ value: Double) {
    time = max(0, min(totalDuration, value))
    previewBaseTime = time
    previewBegan = ProcessInfo.processInfo.systemUptime
    syncAudio()
  }
  private func syncAudio() {
    guard let player = player else { return }
    audioSeekGeneration += 1
    let seekGeneration = audioSeekGeneration
    audioReadyObservation = nil
    player.cancelPendingPrerolls()
    player.pause()
    let audioTime = max(0, currentTime - settings.intro)
    if preparingPlayback && audioTime >= audioDuration {
      beginPreparedPlayback()
      return
    }
    player.seek(
      to: CMTime(seconds: audioTime, preferredTimescale: 48000), toleranceBefore: .zero,
      toleranceAfter: .zero
    ) { [weak self, weak player] finished in
      DispatchQueue.main.async {
        guard let self = self, let player = player,
          self.audioSeekGeneration == seekGeneration, self.player === player,
          (self.playing || self.preparingPlayback), audioTime < self.audioDuration else { return }
        guard finished else {
          self.pause()
          self.errorMessage = player.error?.localizedDescription ?? "音频定位失败 / Audio seek failed"
          return
        }
        self.prerollAudio(player, generation: seekGeneration)
      }
    }
  }
  private func prerollAudio(_ player: AVPlayer, generation: Int) {
    guard audioSeekGeneration == generation, self.player === player, playing || preparingPlayback else { return }
    guard player.status == .readyToPlay else {
      // preroll(atRate:) requires readyToPlay. Observe readiness without blocking
      // the main thread or waiting until the 100 ms transport timer fires.
      audioReadyObservation = player.observe(\.status, options: [.initial, .new]) {
        [weak self, weak player] _, _ in
        DispatchQueue.main.async {
          guard let self = self, let player = player,
            self.audioSeekGeneration == generation, self.player === player else { return }
          if player.status == .readyToPlay {
            self.audioReadyObservation = nil
            self.prerollAudio(player, generation: generation)
          } else if player.status == .failed {
            self.audioReadyObservation = nil
            self.pause()
            self.errorMessage = player.error?.localizedDescription ?? "音频预览准备失败 / Audio preview failed"
          }
        }
      }
      return
    }
    player.preroll(atRate: 1) { [weak self, weak player] finished in
      DispatchQueue.main.async {
        guard let self = self, let player = player,
          self.audioSeekGeneration == generation, self.player === player,
          (self.playing || self.preparingPlayback) else { return }
        guard finished else {
          self.pause()
          self.errorMessage = player.error?.localizedDescription ?? "音频预览准备失败 / Audio preview failed"
          return
        }
        if self.preparingPlayback { self.beginPreparedPlayback() }
        let timeline = self.currentTime
        let audioTime = max(0, timeline - self.settings.intro)
        guard timeline < self.totalDuration, audioTime < self.audioDuration else { return }
        let delay = max(0, self.settings.intro - timeline)
        let hostTime = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()),
          CMTime(seconds: delay, preferredTimescale: 1_000_000_000))
        // Load the decoder during the lead-in, then align it with the same host
        // clock as the picture. Audio readiness never resets the preview clock.
        player.setRate(1, time: CMTime(seconds: audioTime, preferredTimescale: 48000),
          atHostTime: hostTime)
      }
    }
  }
  private func beginPreparedPlayback() {
    previewBaseTime = time
    previewBegan = ProcessInfo.processInfo.systemUptime
    preparingPlayback = false
    playing = true
    status = "正在预览"
  }
  private static func makePlayer(asset: AVAsset) -> AVPlayer {
    let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    // Host-time scheduling requires this to be false. Sources are local files.
    player.automaticallyWaitsToMinimizeStalling = false
    return player
  }
  func chooseAudio() {
    let panel = NSOpenPanel()
    panel.title = "导入音频"
    panel.allowedContentTypes = [.audio]
    if panel.runModal() == .OK, let url = panel.url { loadAudio(url) }
  }
  func chooseMIDI() {
    let panel = NSOpenPanel()
    panel.title = "追加 MIDI / Add MIDI（支持多文件）"
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [
      .init(filenameExtension: "mid")!, .init(filenameExtension: "midi")!,
    ]
    if panel.runModal() == .OK { loadMIDI(panel.urls) }
  }
  func chooseBackground() {
    let panel = NSOpenPanel()
    panel.title = "导入背景图"
    panel.allowedContentTypes = [.image]
    if panel.runModal() == .OK, let url = panel.url { loadBackground(url) }
  }
  private static func prepareAudio(_ url: URL) throws -> (AVURLAsset, Double) {
    let asset = AVURLAsset(url: url)
    let duration = CMTimeGetSeconds(asset.duration)
    guard duration.isFinite, duration > 0, let track = asset.tracks(withMediaType: .audio).first else {
      throw StudioError.message("该文件没有可读取的音频")
    }
    // AVAudioFile probes local audio without relying on the media decoder service.
    // Fall back to AVAssetReader for container formats AVAudioFile cannot open.
    if let file = try? AVAudioFile(forReading: url),
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048) {
      try file.read(into: buffer)
      guard buffer.frameLength > 0 else { throw StudioError.message("该文件音频无法解码") }
      return (asset, duration)
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track,
      outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
    guard reader.canAdd(output) else { throw StudioError.message("该文件音频格式无法解码") }
    reader.add(output)
    guard reader.startReading(), output.copyNextSampleBuffer() != nil else {
      throw reader.error ?? StudioError.message("该文件音频无法解码")
    }
    reader.cancelReading()
    return (asset, duration)
  }
  private static func validateImage(_ url: URL) throws {
    guard let image = NSImage(contentsOf: url), image.size.width > 0,
      image.size.height > 0, image.tiffRepresentation != nil else {
      throw StudioError.message("该文件不是可读取的图像：\(url.lastPathComponent)")
    }
  }
  private func cancelPendingProject() {
    guard importingProject else { return }
    importGeneration += 1
    importingProject = false
    importing = false
  }
  func loadBackground(_ url: URL) {
    cancelPendingProject()
    do {
      try Self.validateImage(url)
      backgroundURL = url
    } catch { errorMessage = error.localizedDescription }
  }
  func chooseCover() {
    let panel=NSOpenPanel();panel.title="封面 / Cover";panel.allowedContentTypes=[.image]
    if panel.runModal() == .OK, let url=panel.url {
      do { try Self.validateImage(url);coverURL=url } catch { errorMessage=error.localizedDescription }
    }
  }
  func loadAudio(_ url: URL) {
    cancelPendingProject()
    audioGeneration += 1
    let generation=audioGeneration
    analyzingAudio=true
    status="分析音频 / Analyzing audio…"
    DispatchQueue.global(qos:.userInitiated).async { [weak self] in
      let result=Result { () throws -> (AVURLAsset,Double,AudioVisualizationData) in
        let (asset,duration)=try Self.prepareAudio(url)
        return (asset,duration,try AudioAnalyzer.analyze(url:url))
      }
      DispatchQueue.main.async { [weak self] in
        guard let self=self,self.audioGeneration == generation else { return }
        self.analyzingAudio=false
        switch result {
        case .success(let prepared):
          self.pause();self.audioSeekGeneration += 1
          self.audioURL=url;self.audioDuration=prepared.1;self.audioVisualization=prepared.2
          self.player=Self.makePlayer(asset:prepared.0)
          self.player?.volume=Float(self.settings.volume)
          if self.tracks.isEmpty { self.settings.scene = .audio }
          self.time=0;self.errorMessage=nil;self.status="音频已就绪 / Audio ready · \(url.lastPathComponent)"
        case .failure(let error): self.errorMessage=error.localizedDescription
        }
      }
    }
  }
  private func beginImport(project: Bool) -> Int {
    pause()
    if project { audioGeneration += 1;analyzingAudio=false }
    importGeneration += 1
    importingProject = project
    importing = true
    errorMessage = nil
    return importGeneration
  }
  private func commitMIDI(_ sequences: [MIDISequence], urls: [URL], append:Bool=false, sourceIDs:[Int]?=nil, trackOrder:[String]?=nil) {
    let hadTracks = !tracks.isEmpty
    let existingIDs=midiSourceIDs+tracks.compactMap{Int($0.id.split(separator:":",maxSplits:1).first ?? "")}
    let nextID=(existingIDs.max() ?? -1)+1
    let ids=sourceIDs ?? Array((append ? nextID:0)..<(append ? nextID:0)+urls.count)
    let imported = sequences.enumerated().flatMap { file, seq in
      seq.tracks.enumerated().map { index,track in
        var t = track
        t.id = "\(ids[file]):\(track.id)"
        t.sourceFile = urls[file].lastPathComponent
        t.sourceTrackNumber = index+1
        return t
      }
    }
    if append {tracks += imported;midiURLs += urls;midiSourceIDs += ids}
    else {tracks=imported;midiURLs=urls;midiSourceIDs=ids;midiSources.removeAll()}
    for (file,seq) in sequences.enumerated() {midiSources[ids[file]]=MIDISourceMetadata(duration:seq.duration,bpm:seq.bpm,tempoMap:seq.tempoMap)}
    if let order=trackOrder {
      let byID=Dictionary(uniqueKeysWithValues:tracks.map{($0.id,$0)})
      tracks=order.compactMap{byID[$0]}
    }
    refreshMIDIMetadata()
    if !loadingProject && (!append || !hadTracks) { settings.bpm = 0 }
    if !tracks.contains(where:{$0.id == settings.cameraTrackID}) { settings.cameraTrackID = "" }
    for (i, track) in tracks.enumerated() where styles[track.id] == nil {
      styles[track.id] = TrackStyle(color: RGB.palette[i % RGB.palette.count])
    }
    let trackIDs = Set(tracks.map { $0.id })
    styles = styles.filter { trackIDs.contains($0.key) }
    settings.chordTrackIDs.removeAll{!trackIDs.contains($0)}
    if !append || !hadTracks {time=0}
    revision += 1
    importing = false
    importingProject = false
    status = "\(tracks.count) 条轨道 · \(noteCount.formatted()) 个音符"
  }
  private func refreshMIDIMetadata() {
    midiDuration=midiSourceIDs.compactMap{midiSources[$0]?.duration}.max() ?? tracks.flatMap{$0.notes}.map{$0.end}.max() ?? 0
    let source=midiSourceIDs.first.flatMap{midiSources[$0]}
    sourceBPM=source?.bpm ?? 120;sourceTempoMap=source?.tempoMap ?? []
    let notes=tracks.flatMap{$0.notes}
    minPitch=notes.map{$0.pitch}.min() ?? 48;maxPitch=notes.map{$0.pitch}.max() ?? 84
  }
  func updateTrackStyle(_ id:String,_ update:(inout TrackStyle)->Void) {
    guard let index=tracks.firstIndex(where:{$0.id==id}),exportProgress==nil else{return}
    var value=styles[id] ?? TrackStyle(color:RGB.palette[index%RGB.palette.count])
    update(&value)
    guard (try? value.validate()) != nil else{return}
    styles[id]=value
  }
  func deleteTrack(_ id:String) {
    guard exportProgress==nil,!importing,tracks.contains(where:{$0.id==id}) else{return}
    pause()
    tracks.removeAll{$0.id==id};styles.removeValue(forKey:id)
    settings.chordTrackIDs.removeAll{$0==id}
    if settings.cameraTrackID==id {settings.cameraTrackID=""}
    let active=Set(tracks.compactMap{Int($0.id.split(separator:":",maxSplits:1).first ?? "")})
    for i in midiSourceIDs.indices.reversed() where !active.contains(midiSourceIDs[i]) {
      midiSources.removeValue(forKey:midiSourceIDs[i]);midiSourceIDs.remove(at:i);midiURLs.remove(at:i)
    }
    refreshMIDIMetadata();time=min(time,totalDuration);revision+=1
    status="已删除轨道 / Track removed · \(tracks.count) tracks"
  }
  func resetProject() {
    guard exportProgress==nil else{return}
    pause();importGeneration+=1;audioGeneration+=1;audioSeekGeneration+=1
    importing=false;importingProject=false;analyzingAudio=false;loadingProject=false
    if let observer=observer {player?.removeTimeObserver(observer);self.observer=nil}
    player=nil;audioReadyObservation=nil
    tracks=[];styles=[:];midiURLs=[];midiSourceIDs=[];midiSources=[:]
    audioURL=nil;backgroundURL=nil;coverURL=nil;audioVisualization=nil
    audioDuration=0;midiDuration=0;sourceBPM=120;sourceTempoMap=[];minPitch=48;maxPitch=84
    settings=StudioSettings();time=0;revision+=1
    exportStatistics=nil;lastExportURL=nil;errorMessage=nil
    status="空白项目 / New empty project"
  }
  func projectFile()->ProjectFile {
    ProjectFile(audio:audioURL?.path,midi:midiURLs.map{$0.path},background:backgroundURL?.path,cover:coverURL?.path,settings:settings,styles:styles,midiSourceIDs:midiSourceIDs,trackOrder:tracks.map{$0.id})
  }
  func loadMIDI(_ urls: [URL], completion: (() -> Void)? = nil) {
    guard !urls.isEmpty,exportProgress==nil else{return}
    let generation = beginImport(project: false)
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = Result { try urls.map { try MIDIParser.parse(url: $0) } }
      DispatchQueue.main.async { [weak self] in
        guard let self = self, self.importGeneration == generation else { return }
        switch result {
        case .success(let sequences):
          self.commitMIDI(sequences, urls: urls,append:true)
          completion?()
        case .failure(let error):
          self.importing = false
          self.errorMessage = error.localizedDescription
        }
      }
    }
  }
  func acceptDrop(_ urls: [URL]) {
    let midi = urls.filter { ["mid", "midi"].contains($0.pathExtension.lowercased()) }
    if !midi.isEmpty { loadMIDI(midi) }
    for url in urls where !midi.contains(url) {
      if ["png", "jpg", "jpeg", "tiff", "webp", "heic"].contains(url.pathExtension.lowercased()) {
        loadBackground(url)
      } else if url.pathExtension.lowercased() == "lumascore" {
        openProject(url)
      } else {
        loadAudio(url)
      }
    }
  }
  func resetAppearance() {
    let saved = settings
    settings = StudioSettings()
    settings.codec = saved.codec
    settings.fps = saved.fps
    settings.resolution = saved.resolution
    settings.aspect = saved.aspect
    settings.bitrate = saved.bitrate
    for (i, track) in tracks.enumerated() {
      styles[track.id] = TrackStyle(color: RGB.palette[i % RGB.palette.count])
    }
  }
  func panViewport(horizontal: Double, pitch: Double) {
    settings.playheadPosition = min(0.95, max(0.05, settings.playheadPosition + horizontal))
    settings.pitchScroll = min(128, max(-128, settings.pitchScroll + pitch))
  }
  func zoomViewport(factor: Double, vertical: Bool) {
    if vertical {
      settings.pitchZoom = min(8, max(0.25, settings.pitchZoom * factor))
    } else {
      settings.horizontalZoom = min(8, max(0.25, settings.horizontalZoom * factor))
    }
  }
  func resetViewport() {
    settings.horizontalZoom = 1
    settings.pitchZoom = 1
    settings.pitchScroll = 0
    settings.playheadPosition = 0.34
  }
  func export() {
    guard exportProgress == nil, !analyzingAudio, !importing, (!tracks.isEmpty || audioURL != nil) else {
      errorMessage = "请先导入音频或 MIDI / Import audio or MIDI first"
      return
    }
    let panel = NSSavePanel()
    panel.title = "导出视频"
    panel.allowedContentTypes = settings.container == .mp4 ? [.mpeg4Movie]:[.init(filenameExtension:"webm") ?? .movie]
    panel.nameFieldStringValue =
      "\(audioURL?.deletingPathExtension().lastPathComponent ?? "LumaScore")-\(settings.resolution)p.\(settings.container.rawValue.lowercased())"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let temporary = url.deletingLastPathComponent().appendingPathComponent(
      ".LumaScore-\(UUID().uuidString).\(settings.container.rawValue.lowercased())")
    pause()
    exportProgress = 0
    exportStatistics = nil
    status = "正在导出视频…"
    operation = ExportOperation(
      snapshot: snapshot, audioURL: audioURL, destination: temporary,
      progress: { [weak self] p in DispatchQueue.main.async { self?.exportProgress = p } },
      completion: { [weak self] result in
        DispatchQueue.main.async {
          guard let self = self else { return }
          self.exportProgress = nil
          self.operation = nil
          switch result {
          case .success(let stats):
            do {
              if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
              } else {
                try FileManager.default.moveItem(at: temporary, to: url)
              }
              self.exportStatistics = stats
              self.lastExportURL = url
              self.status = String(
                format: "导出完成 · %.2f 秒 · %.1f× 实时速度", stats.elapsed, stats.realtimeMultiple)
            } catch {
              self.errorMessage = "保存失败，导出视频保留在 \(temporary.path)：\(error.localizedDescription)"
            }
          case .failure(let error):
            self.errorMessage = error.localizedDescription
            self.status = "导出已停止"
          }
        }
      })
    operation?.startExport()
  }
  func cancelExport() { operation?.cancel() }
  func revealExport() {
    if let url = lastExportURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
  }
  func saveProject() {
    let panel = NSSavePanel()
    panel.title = "保存项目"
    panel.nameFieldStringValue = "LumaScore-project.lumascore"
    panel.allowedContentTypes = [.init(filenameExtension: "lumascore")!]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let project = projectFile()
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(project).write(to: url, options: .atomic)
      status = "项目已保存（媒体使用原文件路径）"
    } catch { errorMessage = error.localizedDescription }
  }
  func chooseProject() {
    let panel = NSOpenPanel()
    panel.title = "打开项目"
    panel.allowedContentTypes = [.init(filenameExtension: "lumascore")!]
    if panel.runModal() == .OK, let url = panel.url { openProject(url) }
  }
  func openProject(_ url: URL) {
    guard url.pathExtension.lowercased() == "lumascore" else {
      errorMessage = "请选择 LumaScore 项目 / Choose a LumaScore project"
      return
    }
    let generation = beginImport(project: true)
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      // No published state changes until every referenced asset has been prepared.
      let result = Result { () throws -> (ProjectFile, [MIDISequence], AVURLAsset?, Double, AudioVisualizationData?) in
        let project = try JSONDecoder().decode(ProjectFile.self, from: Data(contentsOf: url))
        guard project.format == "lumascore", project.version == 1 else { throw StudioError.message("项目格式或版本不受支持 / Unsupported project format or version") }
        try project.settings.validate()
        for style in project.styles.values {
          try style.validate()
          guard [style.color.r, style.color.g, style.color.b].allSatisfy({ $0.isFinite && (0...1).contains($0) })
          else { throw StudioError.message("项目轨道颜色超出有效范围") }
        }
        let paths = project.midi + (project.audio.map { [$0] } ?? [])
          + (project.background.map { [$0] } ?? []) + (project.cover.map { [$0] } ?? [])
        if let missing = paths.first(where: { !FileManager.default.fileExists(atPath: $0) }) {
          throw StudioError.message("项目引用的媒体已移动：\(missing)")
        }
        let sequences = try project.midi.map { try MIDIParser.parse(url: URL(fileURLWithPath: $0)) }
        let sourceIDs=project.midiSourceIDs ?? Array(project.midi.indices)
        guard sourceIDs.count==sequences.count,sourceIDs.allSatisfy({$0>=0 && $0<Int.max/2}),Set(sourceIDs).count==sourceIDs.count else {throw StudioError.message("项目 MIDI 来源标识无效")}
        if let order=project.trackOrder {
          let available=Set(sequences.enumerated().flatMap{file,seq in seq.tracks.map{"\(sourceIDs[file]):\($0.id)"}})
          guard Set(order).count==order.count,order.allSatisfy({available.contains($0)}) else {throw StudioError.message("项目轨道顺序无效")}
        }
        if let background = project.background { try Self.validateImage(URL(fileURLWithPath: background)) }
        if let cover = project.cover { try Self.validateImage(URL(fileURLWithPath: cover)) }
        var audioAsset: AVURLAsset?, duration = 0.0
        var visualization:AudioVisualizationData?
        if let audio = project.audio {
          (audioAsset, duration) = try Self.prepareAudio(URL(fileURLWithPath: audio))
          visualization = try AudioAnalyzer.analyze(url:URL(fileURLWithPath:audio))
        }
        return (project, sequences, audioAsset, duration, visualization)
      }
      DispatchQueue.main.async { [weak self] in
        guard let self = self, self.importGeneration == generation else { return }
        switch result {
        case .success(let prepared):
          let (project, sequences, asset, duration, visualization) = prepared
          self.loadingProject = true
          self.settings = project.settings
          self.styles = project.styles
          self.backgroundURL = project.background.map { URL(fileURLWithPath: $0) }
          self.audioURL = project.audio.map { URL(fileURLWithPath: $0) }
          self.coverURL=project.cover.map { URL(fileURLWithPath:$0) }
          self.audioVisualization=visualization
          self.audioDuration = duration
          self.audioSeekGeneration += 1
          self.player = asset.map { Self.makePlayer(asset: $0) }
          self.player?.volume = Float(self.settings.volume)
          self.commitMIDI(sequences, urls: project.midi.map { URL(fileURLWithPath: $0) },sourceIDs:project.midiSourceIDs,trackOrder:project.trackOrder)
          self.loadingProject = false
          self.saveDefaults()
        case .failure(let error):
          self.importing = false
          self.importingProject = false
          self.errorMessage = error.localizedDescription
        }
      }
    }
  }
}
