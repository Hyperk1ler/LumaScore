import AVFoundation
import Foundation

@main
struct AudioAnalysisSelfTest {
  static func main() throws {
    let fixture = CommandLine.arguments.count > 1
      ? URL(fileURLWithPath: CommandLine.arguments[1])
      : URL(fileURLWithPath: "Fixtures/representative-5s.wav")
    let data = try AudioAnalyzer.analyze(url: fixture)
    precondition(abs(data.duration - 5) < 0.001, "Fixture duration")
    precondition(data.sampleRate == 48_000 && data.channels == 2, "Source format")
    precondition(data.bitDepth == 16 && data.fileBytes == 960_044, "Source PCM metadata")
    precondition(data.waveform.count == 1200 && data.waveform.max()! > 0.01, "Real waveform")
    precondition(data.spectrumFrameCount == 150 && data.spectrum(at: 1).count == 64, "Analysis cadence")
    precondition(data.spectrum(at: -1).allSatisfy { $0 == 0 }, "Before source")
    precondition(data.spectrum(at: data.duration).allSatisfy { $0 == 0 }, "After source")
    precondition(data.spectrum(at: .nan).allSatisfy { $0 == 0 }, "Non-finite seek")
    let fixtureSpectrum = data.spectrum(at: 1)
    let dominant = fixtureSpectrum.indices.max { fixtureSpectrum[$0] < fixtureSpectrum[$1] }!
    precondition((150...400).contains(data.frequencyCenters[dominant]), "Fixture 220/330 Hz tone")
    precondition(fixtureSpectrum.max()! - fixtureSpectrum.min()! > 0.5, "Spectrum must not be flat")
    precondition(data.rms(at: 1) > 0 && data.rmsDB(at: 1) < 0, "RMS dBFS")
    precondition(data.spectrum(at: 1.234) == data.spectrum(at: 1.234), "Deterministic seeks")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let synthetic = directory.appendingPathComponent("two-tones-and-silence.wav")
    try writeTone(url: synthetic, frames: 120_000)
    let tones = try AudioAnalyzer.analyze(url: synthetic)
    precondition(abs(tones.duration - 2.5) < 0.0001, "Generated duration")
    let low = tones.spectrum(at: 0.5)
    let high = tones.spectrum(at: 1.5)
    let lowBin = low.indices.max { low[$0] < low[$1] }!
    let highBin = high.indices.max { high[$0] < high[$1] }!
    precondition((170...300).contains(tones.frequencyCenters[lowBin]), "220 Hz section")
    precondition((530...780).contains(tones.frequencyCenters[highBin]), "660 Hz section")
    precondition(highBin > lowBin, "Spectrum changes with source audio")
    precondition(abs(tones.rmsDB(at: 0.5) - 20 * log10(0.5 / sqrt(2))) < 0.2, "Calibrated RMS")
    precondition(tones.rms(at: 0.5) > 0.3, "Anti-phase stereo preserves energy")
    precondition(tones.spectrum(at: 2.3).allSatisfy { $0 == 0 }, "Silence stays silent")
    precondition(tones.waveform.suffix(100).allSatisfy { $0 == 0 }, "Silent waveform tail")
    let short = directory.appendingPathComponent("short.wav")
    try writeTone(url: short, frames: 100)
    let shortData = try AudioAnalyzer.analyze(url: short)
    precondition(shortData.spectrumFrameCount == 1 && shortData.rms(at: 0) > 0, "Short-file padding")
    do {
      _ = try AudioAnalyzer.analyze(url: fixture, cancelled: { true })
      preconditionFailure("Cancellation did not throw")
    } catch AudioAnalysisError.cancelled { }
    print("Audio analysis passed: real 5s fixture, 220/660 Hz, anti-phase stereo, RMS dBFS, silence, short files, cancellation, deterministic seeks")
    print("Fixture: \(data.spectrumFrameCount) frames, \(data.waveform.count) RMS waveform bins, \(data.overallRMSDB) dBFS")
  }

  static func writeTone(url: URL, frames: Int) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
      AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let output = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for index in 0..<frames {
      let time = Double(index) / 48_000
      let frequency = time < 1 ? 220.0 : 660.0
      let amplitude = time < 1 ? 0.5 : time < 2 ? 0.25 : 0
      let sample = Float(amplitude * sin(2 * .pi * frequency * time))
      buffer.floatChannelData![0][index] = sample
      buffer.floatChannelData![1][index] = -sample
    }
    try output.write(from: buffer)
  }
}
