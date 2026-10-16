import AVFoundation
import CoreVideo
import Darwin
import Foundation
import Metal
import VideoToolbox

final class ExportOperation {
  private let snapshot: RenderSnapshot, audioURL: URL?, destination: URL,
    progress: (Double) -> Void, completion: (Result<ExportStatistics, Error>) -> Void
  private let videoQueue = DispatchQueue(label: "lumascore.export.video", qos: .userInitiated),
    audioQueue = DispatchQueue(label: "lumascore.export.audio", qos: .userInitiated)
  private let lock = NSLock()
  private var cancelled = false, finished = false
  private var writer: AVAssetWriter!, videoInput: AVAssetWriterInput!,
    audioInput: AVAssetWriterInput?, adaptor: AVAssetWriterInputPixelBufferAdaptor!,
    reader: AVAssetReader?, audioOutput: AVAssetReaderTrackOutput?
  private var intermediateURL: URL?
  private let rendererBackend: RendererBackend
  private var renderer: MetalSceneRenderer!, cache: CVMetalTextureCache?
  private let group = DispatchGroup()
  private var videoEntered = false, audioEntered = false
  private var ready: [Int: CVPixelBuffer] = [:], submitted = 0, appended = 0, inFlight = 0,
    maximumInFlight = 0, frameCount = 0
  private var start = 0.0, duration = 0.0, began = 0.0, lastProgress = 0.0, videoDone = false,
    audioDone = false, retryScheduled = false, ownsDestination = false
  init(
    snapshot: RenderSnapshot, audioURL: URL?, destination: URL,
    progress: @escaping (Double) -> Void,
    completion: @escaping (Result<ExportStatistics, Error>) -> Void,
    rendererBackend: RendererBackend = .automatic
  ) {
    self.snapshot = snapshot
    self.audioURL = audioURL
    self.destination = destination
    self.progress = progress
    self.completion = completion
    self.rendererBackend = rendererBackend
  }
  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
  private var stopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled || finished
  }
  func startExport() {
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      do { try prepare() } catch { fail(error) }
    }
  }
  private func prepare() throws {
    began = ProcessInfo.processInfo.systemUptime
    let settings = snapshot.settings
    try settings.validate()
    let (width, height) = settings.dimensions
    let fps = settings.fps
    guard width > 0, height > 0, [30, 60].contains(fps) else {
      throw StudioError.message("导出尺寸或帧率不正确")
    }
    let audioAsset = audioURL.map { AVURLAsset(url: $0) }
    let audioDuration = audioAsset.map { CMTimeGetSeconds($0.duration) } ?? 0
    let total = snapshot.timelineDuration(audioDuration:audioDuration)
    start = max(0, min(settings.exportStart, total))
    let end = settings.exportEnd > 0 ? min(settings.exportEnd, total) : total
    guard end > start, end - start < 86400 else {
      throw StudioError.message("请选择有效的导出区间（最长 24 小时）")
    }
    frameCount = Int(ceil((end - start) * Double(fps)))
    duration = Double(frameCount) / Double(fps)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw StudioError.message("输出文件已存在，请选择新的文件名")
    }
    renderer = try MetalSceneRenderer(snapshot: snapshot, backend: rendererBackend)
    guard
      CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, renderer.device, nil, &cache)
        == kCVReturnSuccess
    else { throw StudioError.message("无法建立 GPU 视频纹理缓存") }
    if settings.container == .webm {
      guard WebMTranscoder.available else { throw WebMTranscodeError.unavailable }
      intermediateURL=destination.deletingLastPathComponent().appendingPathComponent(".lumascore-transcode-\(UUID().uuidString).mp4")
    }
    writer = try AVAssetWriter(outputURL: intermediateURL ?? destination, fileType: .mp4)
    ownsDestination = true
    let codec: AVVideoCodecType = settings.codec == .h264 ? .h264 : .hevc
    var compression: [String: Any] = [
      AVVideoAverageBitRateKey: settings.bitrate * 1_000_000,
      AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: fps * 2,
      AVVideoAllowFrameReorderingKey: false,
    ]
    if settings.codec == .h264 {
      compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
    }
    let spec: [String: Any] = [
      kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
    ]
    let output: [String: Any] = [
      AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: compression, AVVideoEncoderSpecificationKey: spec,
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
    ]
    guard writer.canApply(outputSettings: output, forMediaType: .video) else {
      throw StudioError.message("系统不支持当前硬件编码设置，请尝试 H.264")
    }
    videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: output)
    videoInput.expectsMediaDataInRealTime = false
    adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: videoInput,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
      ])
    guard writer.canAdd(videoInput) else { throw StudioError.message("无法创建视频轨道") }
    writer.add(videoInput)
    if let asset = audioAsset, let track = asset.tracks(withMediaType: .audio).first {
      let audioStart = max(0, start - settings.intro)
      let audioEnd = min(audioDuration, start + duration - settings.intro)
      if audioEnd > audioStart {
        reader = try AVAssetReader(asset: asset)
        reader!.timeRange = CMTimeRange(
          start: CMTime(seconds: audioStart, preferredTimescale: 48000),
          duration: CMTime(seconds: audioEnd - audioStart, preferredTimescale: 48000))
        audioOutput = AVAssetReaderTrackOutput(
          track: track,
          outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
          ])
        audioOutput!.alwaysCopiesSampleData = settings.audioFadeEnabled && (settings.audioFadeIn > 0 || settings.audioFadeOut > 0)
        guard reader!.canAdd(audioOutput!) else { throw StudioError.message("无法读取音频") }
        reader!.add(audioOutput!)
        audioInput = AVAssetWriterInput(
          mediaType: .audio,
          outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192000,
          ])
        audioInput!.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput!) else { throw StudioError.message("无法创建音频轨道") }
        writer.add(audioInput!)
      }
    }
    guard writer.startWriting() else { throw writer.error ?? StudioError.message("无法启动硬件编码器") }
    writer.startSession(atSourceTime: .zero)
    if let reader = reader, !reader.startReading() {
      throw reader.error ?? StudioError.message("音频读取失败")
    }
    lock.lock()
    group.enter()
    videoEntered = true
    if audioInput != nil {
      group.enter()
      audioEntered = true
    }
    lock.unlock()
    videoInput.requestMediaDataWhenReady(on: videoQueue) { [weak self] in self?.pumpVideo() }
    if let audioInput = audioInput {
      audioInput.requestMediaDataWhenReady(on: audioQueue) { [weak self] in self?.pumpAudio() }
    }
    group.notify(queue: DispatchQueue.global(qos: .userInitiated)) { [self] in
      if stopped { return }
      writer.endSession(atSourceTime: CMTime(value: Int64(frameCount), timescale: Int32(fps)))
      writer.finishWriting { [self] in
        guard writer.status == .completed else {
          fail(writer.error ?? StudioError.message("视频保存失败"))
          return
        }
        if let intermediate=intermediateURL {
          do {
            try WebMTranscoder.transcode(input:intermediate,output:destination,cancelled:{self.stopped},progress:{p in self.progress(0.8+p*0.19)},bitrateMbps:settings.bitrate)
            try? FileManager.default.removeItem(at:intermediate)
          } catch { fail(error);return }
        }
        lock.lock()
        if finished {
          lock.unlock()
          return
        }
        finished = true
        lock.unlock()
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let means = renderer.metrics.means
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let bytes =
          (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?
          .int64Value ?? 0
        let stats = ExportStatistics(
          width: width, height: height, fps: fps, frames: frameCount, duration: duration,
          elapsed: elapsed, framesPerSecond: Double(frameCount) / elapsed,
          realtimeMultiple: duration / elapsed, codec: settings.container == .webm ? "VP9":settings.codec.rawValue,
          hardwareRequired: settings.container == .mp4, gpuName: renderer.device.name,
          peakResidentMB: Double(usage.ru_maxrss) / 1_048_576, outputBytes: bytes,
          maxFramesInFlight: maximumInFlight, cpuBuildMeanMS: means.0, gpuMeanMS: means.1,
          audioIncluded: self.audioInput != nil, rendererBackend: renderer.metrics.backendSummary)
        progress(1)
        completion(.success(stats))
      }
    }
  }
  private func fail(_ error: Error) {
    lock.lock()
    if finished {
      lock.unlock()
      return
    }
    finished = true
    lock.unlock()
    reader?.cancelReading()
    writer?.cancelWriting()
    leaveVideo()
    leaveAudio()
    if ownsDestination { try? FileManager.default.removeItem(at: destination) }
    if let intermediate=intermediateURL { try? FileManager.default.removeItem(at:intermediate) }
    completion(.failure(error))
  }
  private func leaveVideo() {
    lock.lock()
    let entered = videoEntered
    videoEntered = false
    lock.unlock()
    if entered { group.leave() }
  }
  private func leaveAudio() {
    lock.lock()
    let entered = audioEntered
    audioEntered = false
    lock.unlock()
    if entered { group.leave() }
  }
  private func pumpVideo() {
    if stopped {
      if !finished { fail(StudioError.message("已取消导出")) }
      return
    }
    if videoDone { return }
    if writer.status == .failed {
      fail(writer.error ?? StudioError.message("编码器出错"))
      return
    }
    while videoInput.isReadyForMoreMediaData, let pixel = ready[appended] {
      guard
        adaptor.append(
          pixel,
          withPresentationTime: CMTime(
            value: Int64(appended), timescale: Int32(snapshot.settings.fps)))
      else {
        fail(writer.error ?? StudioError.message("无法写入视频帧"))
        return
      }
      ready.removeValue(forKey: appended)
      appended += 1
      inFlight -= 1
      let now = ProcessInfo.processInfo.systemUptime
      if now - lastProgress > 0.1 {
        progress(Double(appended) / Double(frameCount) * (snapshot.settings.container == .webm ? 0.8:0.98))
        lastProgress = now
      }
    }
    if appended == frameCount {
      videoDone = true
      videoInput.markAsFinished()
      leaveVideo()
      return
    }
    while videoInput.isReadyForMoreMediaData, inFlight < 3, submitted < frameCount {
      var pixel: CVPixelBuffer?
      guard let pool = adaptor.pixelBufferPool else {
        fail(StudioError.message("编码器未建立像素缓冲池"))
        return
      }
      let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
        kCFAllocatorDefault, pool,
        [kCVPixelBufferPoolAllocationThresholdKey as String: 12] as CFDictionary, &pixel)
      if status == kCVReturnWouldExceedAllocationThreshold {
        if !retryScheduled {
          retryScheduled = true
          videoQueue.asyncAfter(deadline: .now() + 0.002) { [weak self] in
            self?.retryScheduled = false
            self?.pumpVideo()
          }
        }
        return
      }
      guard status == kCVReturnSuccess, let pixel = pixel else {
        fail(StudioError.message("无法分配视频帧（\(status)）"))
        return
      }
      var cvTexture: CVMetalTexture?
      guard
        CVMetalTextureCacheCreateTextureFromImage(
          kCFAllocatorDefault, cache!, pixel, nil, .bgra8Unorm, CVPixelBufferGetWidth(pixel),
          CVPixelBufferGetHeight(pixel), 0, &cvTexture) == kCVReturnSuccess,
        let cvTexture = cvTexture, let texture = CVMetalTextureGetTexture(cvTexture)
      else {
        fail(StudioError.message("无法共享 GPU 视频缓冲"))
        return
      }
      let frame = submitted
      let localTime = Double(frame) / Double(snapshot.settings.fps)
      let time = start + localTime
      let fadeIn = snapshot.settings.screenFadeEnabled && snapshot.settings.fadeIn > 0 ? min(1, localTime / snapshot.settings.fadeIn) : 1
      let fadeOut =
        snapshot.settings.screenFadeEnabled && snapshot.settings.fadeOut > 0
        ? min(1, (duration - localTime) / snapshot.settings.fadeOut) : 1
      submitted += 1
      inFlight += 1
      maximumInFlight = max(maximumInFlight, inFlight)
      do {
        try renderer.encode(
          target: texture, time: time, slot: frame % 3, fade: Float(max(0, min(fadeIn, fadeOut)))
        ) { [self, pixel, cvTexture] error in
          _ = cvTexture
          videoQueue.async { [self, pixel] in
            if let error = error {
              fail(error)
              return
            }
            if stopped { return }
            ready[frame] = pixel
            pumpVideo()
          }
        }
      } catch {
        fail(error)
        return
      }
    }
  }
  private func pumpAudio() {
    if stopped {
      if !finished { fail(StudioError.message("已取消导出")) }
      return
    }
    guard let input = audioInput, let output = audioOutput, !audioDone else { return }
    while input.isReadyForMoreMediaData {
      guard let sample = output.copyNextSampleBuffer() else {
        if reader?.status == .failed {
          fail(reader?.error ?? StudioError.message("音频解码失败"))
          return
        }
        audioDone = true
        input.markAsFinished()
        leaveAudio()
        return
      }
      if snapshot.settings.audioFadeEnabled, snapshot.settings.audioFadeIn > 0 || snapshot.settings.audioFadeOut > 0,
        let block=CMSampleBufferGetDataBuffer(sample) {
        var length=0;var pointer:UnsafeMutablePointer<Int8>?
        if CMBlockBufferGetDataPointer(block,atOffset:0,lengthAtOffsetOut:nil,totalLengthOut:&length,dataPointerOut:&pointer)==noErr,let pointer=pointer {
          let samples=UnsafeMutableRawPointer(pointer).assumingMemoryBound(to:Float.self)
          let baseTime=CMSampleBufferGetPresentationTimeStamp(sample).seconds+snapshot.settings.intro-start
          for i in 0..<(length/MemoryLayout<Float>.stride) {
            let time=baseTime+Double(i/2)/48000
            let a=snapshot.settings.audioFadeIn > 0 ? min(1,max(0,time/snapshot.settings.audioFadeIn)):1
            let b=snapshot.settings.audioFadeOut > 0 ? min(1,max(0,(duration-time)/snapshot.settings.audioFadeOut)):1
            samples[i] *= Float(min(a,b))
          }
        }
      }
      var count = 0
      CMSampleBufferGetSampleTimingInfoArray(
        sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
      var timing = Array(
        repeating: CMSampleTimingInfo(
          duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid),
        count: count)
      let status = timing.withUnsafeMutableBufferPointer { ptr in
        CMSampleBufferGetSampleTimingInfoArray(
          sample, entryCount: count, arrayToFill: ptr.baseAddress, entriesNeededOut: nil)
      }
      guard status == noErr else {
        fail(StudioError.message("音频时间戳读取失败"))
        return
      }
      let delta = CMTime(seconds: snapshot.settings.intro - start, preferredTimescale: 48000)
      for i in timing.indices {
        timing[i].presentationTimeStamp = CMTimeAdd(timing[i].presentationTimeStamp, delta)
        if timing[i].decodeTimeStamp.isValid {
          timing[i].decodeTimeStamp = CMTimeAdd(timing[i].decodeTimeStamp, delta)
        }
      }
      var retimed: CMSampleBuffer?
      let result = timing.withUnsafeBufferPointer { ptr in
        CMSampleBufferCreateCopyWithNewTiming(
          allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: count,
          sampleTimingArray: ptr.baseAddress!, sampleBufferOut: &retimed)
      }
      guard result == noErr, let retimed = retimed, input.append(retimed) else {
        fail(writer.error ?? StudioError.message("音频写入失败"))
        return
      }
    }
  }
}
