import Accelerate
import AVFoundation
import Foundation

/// Immutable, deterministic analysis shared by the preview and offline renderer.
/// Spectrum values map -90...0 dBFS to 0...1. Waveform values are 1,200 RMS
/// bins over the whole file (channel energy averaged, never peak-normalized).
/// Meter values are sample RMS, not a LUFS/EBU R128 loudness measurement.
final class AudioVisualizationData {
  let duration: Double
  let sampleRate: Double
  let channels: Int
  let bitDepth: Int?
  let fileBytes: Int64
  let waveform: [Float]
  let frequencyCenters: [Double]
  let frameInterval: Double
  let overallRMSDB: Double
  /// Difference between the 95th and 10th percentiles of non-silent short-window RMS.
  let estimatedDynamicRangeDB: Double
  var spectrumFrameCount: Int { frameRMS.count }

  private let spectralFrames: [Float]
  private let frameRMS: [Float]
  private let framePeaks: [Float]
  fileprivate init(
    duration: Double, sampleRate: Double, channels: Int, bitDepth: Int?, fileBytes: Int64,
    waveform: [Float], frequencyCenters: [Double], frameInterval: Double,
    spectralFrames: [Float], frameRMS: [Float], framePeaks: [Float], overallRMSDB: Double
  ) {
    self.duration = duration
    self.sampleRate = sampleRate
    self.channels = channels
    self.bitDepth = bitDepth
    self.fileBytes = fileBytes
    self.waveform = waveform
    self.frequencyCenters = frequencyCenters
    self.frameInterval = frameInterval
    self.spectralFrames = spectralFrames
    self.frameRMS = frameRMS
    self.framePeaks = framePeaks
    self.overallRMSDB = overallRMSDB
    let levels = frameRMS.filter { $0 > 0.00001 }.map { 20 * log10(Double($0)) }.sorted()
    if levels.count > 1 {
      estimatedDynamicRangeDB = max(
        0, levels[Int(Double(levels.count - 1) * 0.95)]
          - levels[Int(Double(levels.count - 1) * 0.10)])
    } else {
      estimatedDynamicRangeDB = 0
    }
  }

  /// Logarithmic bands from 20 Hz to Nyquist. Frequencies below FFT resolution
  /// share their nearest FFT bin; this is frequency resolution, not invented data.
  func spectrum(at time: Double) -> [Float] {
    var result=Array(repeating:Float(0),count:64)
    spectrum(at:time,into:&result)
    return result
  }
  /// Caller-owned storage avoids two new band arrays on every rendered frame.
  func spectrum(at time:Double,into result:inout [Float]) {
    if result.count != 64 {result=Array(repeating:0,count:64)}
    guard let position=position(at:time) else {
      for i in result.indices {result[i]=0};return
    }
    result.withUnsafeMutableBufferPointer { destination in
      spectralFrames.withUnsafeBufferPointer { source in
        let a=source.baseAddress!.advanced(by:position.lower*64)
        let b=source.baseAddress!.advanced(by:position.upper*64)
        let output=destination.baseAddress!
        for band in 0..<64 {output[band]=a[band]+(b[band]-a[band])*position.fraction}
      }
    }
  }

  func rms(at time: Double) -> Float { value(frameRMS, at: time) }
  func peak(at time: Double) -> Float { value(framePeaks, at: time) }
  func rmsDB(at time: Double) -> Double { 20 * log10(max(0.000001, Double(rms(at: time)))) }

  private func value(_ frames: [Float], at time: Double) -> Float {
    guard let p = position(at: time) else { return 0 }
    return frames[p.lower] + (frames[p.upper] - frames[p.lower]) * p.fraction
  }

  private func position(at time: Double) -> (lower: Int, upper: Int, fraction: Float)? {
    guard time.isFinite, time >= 0, time < duration, !frameRMS.isEmpty else { return nil }
    let position = min(Double(frameRMS.count - 1), time / frameInterval)
    let lower = Int(position)
    return (lower, min(lower + 1, frameRMS.count - 1), Float(position - Double(lower)))
  }
}

enum AudioAnalysisError: LocalizedError {
  case unsupported
  case cancelled
  case fftUnavailable
  var errorDescription: String? {
    switch self {
    case .unsupported: return "无法分析此音频格式 / Unsupported audio format"
    case .cancelled: return "音频分析已取消 / Audio analysis cancelled"
    case .fftUnavailable: return "无法创建频谱分析器 / Cannot create spectrum analyzer"
    }
  }
}

enum AudioAnalyzer {
  /// Streams decoded Float32 PCM. Analysis memory is bounded to 21,600 x 64
  /// spectrum samples (about 5.3 MiB) plus small read/FFT buffers, independent
  /// of song duration. Long files use a larger time hop, reported in frameInterval.
  /// Run on a background queue; cancellation is checked on every read buffer.
  static func analyze(url: URL, cancelled: (() -> Bool)? = nil) throws -> AudioVisualizationData {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = file.processingFormat
    let sampleRate = format.sampleRate
    let channelCount = Int(format.channelCount)
    guard sampleRate.isFinite, sampleRate > 40, channelCount > 0, channelCount <= 32,
      file.length > 0
    else { throw AudioAnalysisError.unsupported }
    let frameLength = file.length
    let windowSize = 2048
    let halfSize = windowSize / 2
    let maximumFrames = 21_600
    let hop = max(1, Int(ceil(sampleRate / 30)), Int(ceil(Double(frameLength) / Double(maximumFrames))))
    let expectedFrames = Int((frameLength - 1) / Int64(hop)) + 1
    let nyquist = sampleRate / 2
    let edges = (0...64).map { 20 * pow(nyquist / 20, Double($0) / 64) }
    let centers = (0..<64).map { sqrt(edges[$0] * edges[$0 + 1]) }
    let ranges: [ClosedRange<Int>] = (0..<64).map { band in
      let low = max(1, min(halfSize, Int(ceil(edges[band] * Double(windowSize) / sampleRate))))
      let high = max(1, min(halfSize, Int(floor(edges[band + 1] * Double(windowSize) / sampleRate))))
      if high >= low { return low...high }
      let nearest = max(1, min(halfSize, Int((centers[band] * Double(windowSize) / sampleRate).rounded())))
      return nearest...nearest
    }
    guard let fft = vDSP_create_fftsetup(vDSP_Length(11), FFTRadix(kFFTRadix2)) else {
      throw AudioAnalysisError.fftUnavailable
    }
    defer { vDSP_destroy_fftsetup(fft) }
    guard let readBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
      throw AudioAnalysisError.unsupported
    }
    // Periodic Hann window and its coherent-gain correction.
    let window = (0..<windowSize).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(windowSize))) }
    let gain = window.reduce(0, +)
    var rings = Array(repeating: Array(repeating: Float(0), count: windowSize), count: channelCount)
    var real = Array(repeating: Float(0), count: halfSize)
    var imaginary = real
    var power = Array(repeating: Float(0), count: halfSize + 1)
    var spectralFrames = [Float]()
    spectralFrames.reserveCapacity(expectedFrames * 64)
    var rmsFrames = [Float]()
    var peakFrames = [Float]()
    rmsFrames.reserveCapacity(expectedFrames)
    peakFrames.reserveCapacity(expectedFrames)
    var waveformEnergy = Array(repeating: 0.0, count: 1200)
    var waveformCounts = Array(repeating: Int64(0), count: 1200)
    var totalEnergy = 0.0
    var samplesRead: Int64 = 0
    var writePosition = halfSize
    var nextFrameAt = Int64(halfSize)

    func captureFrame() {
      for i in power.indices { power[i] = 0 }
      var energy = 0.0
      var peak: Float = 0
      for channel in 0..<channelCount {
        for i in 0..<halfSize {
          let first = rings[channel][(writePosition + i * 2) % windowSize]
          let second = rings[channel][(writePosition + i * 2 + 1) % windowSize]
          real[i] = first * window[i * 2]
          imaginary[i] = second * window[i * 2 + 1]
          energy += Double(first) * Double(first) + Double(second) * Double(second)
          peak = max(peak, abs(first), abs(second))
        }
        real.withUnsafeMutableBufferPointer { r in
          imaginary.withUnsafeMutableBufferPointer { i in
            var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
            vDSP_fft_zrip(fft, &split, 1, 11, FFTDirection(FFT_FORWARD))
          }
        }
        // Average channel power instead of summing samples, so anti-phase stereo
        // remains visible and the spectrum reflects the audible channel energy.
        for bin in 1..<halfSize {
          power[bin] += (real[bin] * real[bin] + imaginary[bin] * imaginary[bin])
            / (gain * gain * Float(channelCount))
        }
        // The packed transform stores the Nyquist coefficient in imaginary[0].
        power[halfSize] += imaginary[0] * imaginary[0]
          / (4 * gain * gain * Float(channelCount))
      }
      for range in ranges {
        var maximum: Float = 0
        for bin in range { maximum = max(maximum, power[bin]) }
        let db = 10 * log10(max(0.000000001, maximum))
        spectralFrames.append(min(1, max(0, (db + 90) / 90)))
      }
      rmsFrames.append(Float(sqrt(energy / Double(windowSize * channelCount))))
      peakFrames.append(peak)
    }

    while samplesRead < frameLength {
      if cancelled?() == true { throw AudioAnalysisError.cancelled }
      try file.read(into: readBuffer, frameCount: AVAudioFrameCount(min(16_384, frameLength - samplesRead)))
      guard readBuffer.frameLength > 0, let channelData = readBuffer.floatChannelData else { break }
      for sample in 0..<Int(readBuffer.frameLength) {
        var energy = 0.0
        for channel in 0..<channelCount {
          let raw = channelData[channel][sample]
          let value: Float = raw.isFinite ? raw : 0
          rings[channel][writePosition] = value
          energy += Double(value) * Double(value)
        }
        energy /= Double(channelCount)
        let bin = min(1199, Int(Double(samplesRead) / Double(frameLength) * 1200))
        waveformEnergy[bin] += energy
        waveformCounts[bin] += 1
        totalEnergy += energy
        samplesRead += 1
        writePosition = (writePosition + 1) % windowSize
        if samplesRead == nextFrameAt {
          captureFrame()
          nextFrameAt += Int64(hop)
        }
      }
    }
    guard samplesRead > 0 else { throw AudioAnalysisError.unsupported }
    // Zero-pad the end to keep the final half window and very short files visible.
    let actualFrames = Int((max(1, samplesRead) - 1) / Int64(hop)) + 1
    var paddedPosition = samplesRead
    while rmsFrames.count < actualFrames {
      for channel in 0..<channelCount { rings[channel][writePosition] = 0 }
      writePosition = (writePosition + 1) % windowSize
      paddedPosition += 1
      if paddedPosition == nextFrameAt {
        captureFrame()
        nextFrameAt += Int64(hop)
      }
    }
    if cancelled?() == true { throw AudioAnalysisError.cancelled }
    let waveform = waveformEnergy.indices.map { index in
      Float(sqrt(waveformEnergy[index] / Double(max(1, waveformCounts[index]))))
    }
    let description = file.fileFormat.streamDescription.pointee
    let bitDepth = description.mFormatID == kAudioFormatLinearPCM && description.mBitsPerChannel > 0
      ? Int(description.mBitsPerChannel) : nil
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    return AudioVisualizationData(
      duration: Double(samplesRead) / sampleRate, sampleRate: sampleRate, channels: channelCount,
      bitDepth: bitDepth, fileBytes: bytes, waveform: waveform, frequencyCenters: centers,
      frameInterval: Double(hop) / sampleRate, spectralFrames: spectralFrames,
      frameRMS: rmsFrames, framePeaks: peakFrames,
      overallRMSDB: 10 * log10(max(0.000000000001, totalEnergy / Double(max(1, samplesRead))))
    )
  }
}
