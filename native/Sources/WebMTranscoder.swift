import AVFoundation
import Darwin
import Foundation

enum WebMTranscodeError: LocalizedError {
  case unavailable
  case incompatibleOS
  case cancelled
  case failed(String)
  var errorDescription: String? {
    switch self {
    case .unavailable:
      return "WebM 编码器资源缺失，请重新安装完整应用 / Bundled WebM encoder is missing; reinstall the complete application"
    case .incompatibleOS:
      return "此版内置 WebM 编码器需要 macOS 27 或更新版本 / This bundled WebM encoder requires macOS 27 or later"
    case .cancelled: return "导出已取消 / Export cancelled"
    case .failed(let detail): return "WebM 导出失败 / WebM export failed: \(detail)"
    }
  }
}

/// Runs the app's separately bundled FFmpeg runtime (licenses retained); never resolves executables
/// from PATH, Homebrew, user settings, or an installed third-party application.
enum WebMTranscoder {
  static let minimumMacOSMajorVersion = 27
  static var available: Bool {
    #if arch(arm64)
    return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= minimumMacOSMajorVersion && runtimeURL != nil
    #else
    return false
    #endif
  }
  static var runtimeURL: URL? {
    guard let resources = Bundle.main.resourceURL else { return nil }
    let candidates = [
      resources.appendingPathComponent("WebMRuntime/ffmpeg"),
      resources.appendingPathComponent("ffmpeg"),
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  /// Synchronous background operation. The progress callback receives 0...1
  /// and is invoked on this operation's background thread. Existing destination
  /// files survive failures and cancellation; successful output replaces them atomically.
  static func transcode(
    input: URL, output: URL, cancelled: () -> Bool,
    progress: ((Double) -> Void)? = nil, bitrateMbps: Int = 24
  ) throws {
    guard let executable = runtimeURL else { throw WebMTranscodeError.unavailable }
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= minimumMacOSMajorVersion else {
      throw WebMTranscodeError.incompatibleOS
    }
    guard input.isFileURL, output.isFileURL,
      input.standardizedFileURL != output.standardizedFileURL,
      (1...200).contains(bitrateMbps)
    else { throw WebMTranscodeError.failed("输入、输出或码率无效 / Invalid input, output, or bitrate") }
    if cancelled() { throw WebMTranscodeError.cancelled }
    let temporary = output.deletingLastPathComponent()
      .appendingPathComponent(".lumascore-webm-\(UUID().uuidString).webm")
    defer { try? FileManager.default.removeItem(at: temporary) }
    let process = Process()
    let stderr = Pipe()
    let stdout = Pipe()
    let diagnostics = WebMProcessOutput()
    let rawDuration = AVURLAsset(url: input).duration.seconds
    let duration = rawDuration.isFinite && rawDuration > 0 ? rawDuration : 0
    process.executableURL = executable
    process.arguments = [
      "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
      "-i", input.path, "-map", "0:v:0", "-map", "0:a:0?",
      "-c:v", "libvpx-vp9", "-b:v", "\(bitrateMbps)M", "-crf", "18",
      "-row-mt", "1", "-deadline", "good", "-cpu-used", "4",
      "-pix_fmt", "yuv420p", "-c:a", "libopus", "-b:a", "192k", "-ar", "48000",
      "-progress", "pipe:1", "-nostats", "-f", "webm", temporary.path,
    ]
    // Do not pass loader overrides from the launching environment to the encoder.
    process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
    process.standardInput = FileHandle.nullDevice
    process.standardError = stderr
    process.standardOutput = stdout
    stderr.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      diagnostics.appendError(data)
      if data.isEmpty { handle.readabilityHandler = nil }
    }
    stdout.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      diagnostics.appendProgress(data)
      if data.isEmpty { handle.readabilityHandler = nil }
    }
    defer {
      stderr.fileHandleForReading.readabilityHandler = nil
      stdout.fileHandleForReading.readabilityHandler = nil
      try? stderr.fileHandleForReading.close()
      try? stdout.fileHandleForReading.close()
    }
    do { try process.run() }
    catch {
      throw WebMTranscodeError.failed("无法启动内置编码器 / Cannot start bundled encoder: \(error.localizedDescription)")
    }
    progress?(0)
    var lastProgress = 0.0
    var interrupted = false
    while process.isRunning {
      if cancelled() {
        interrupted = true
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        break
      }
      if duration > 0 {
        let value = min(0.999, diagnostics.seconds / duration)
        if value > lastProgress {
          lastProgress = value
          progress?(value)
        }
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    process.waitUntilExit()
    stderr.fileHandleForReading.readabilityHandler = nil
    stdout.fileHandleForReading.readabilityHandler = nil
    diagnostics.appendError(stderr.fileHandleForReading.readDataToEndOfFile())
    diagnostics.appendProgress(stdout.fileHandleForReading.readDataToEndOfFile())
    if interrupted || cancelled() { throw WebMTranscodeError.cancelled }
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      let text = diagnostics.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
      throw WebMTranscodeError.failed(text.isEmpty ? "Encoder exited with code \(process.terminationStatus)" : text)
    }
    let attributes = try? FileManager.default.attributesOfItem(atPath: temporary.path)
    guard (attributes?[.size] as? NSNumber)?.int64Value ?? 0 > 4 else {
      throw WebMTranscodeError.failed("编码器没有生成视频 / Encoder produced no video")
    }
    let header = try FileHandle(forReadingFrom: temporary)
    defer { try? header.close() }
    guard try header.read(upToCount: 4) == Data([0x1A, 0x45, 0xDF, 0xA3]) else {
      throw WebMTranscodeError.failed("输出不是有效的 WebM 容器 / Output is not a WebM container")
    }
    // rename(2) atomically replaces a same-volume destination, including existing files.
    guard rename(temporary.path, output.path) == 0 else {
      let message = String(cString: strerror(errno))
      throw WebMTranscodeError.failed("无法保存输出 / Cannot save output: \(message)")
    }
    progress?(1)
  }
}

/// Pipe callbacks retain at most 16 KiB stderr and 4 KiB of incomplete stdout.
/// Both pipes are continuously drained so a verbose failure cannot deadlock Process.
private final class WebMProcessOutput {
  private let lock = NSLock()
  private var errors = Data()
  private var pending = Data()
  private var outputSeconds = 0.0
  var seconds: Double { lock.lock(); defer { lock.unlock() }; return outputSeconds }
  var errorText: String { lock.lock(); defer { lock.unlock() }; return String(decoding: errors, as: UTF8.self) }
  func appendError(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    errors.append(data)
    if errors.count > 16_384 { errors.removeFirst(errors.count - 16_384) }
  }
  func appendProgress(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    pending.append(data)
    while let newline = pending.firstIndex(of: 10) {
      let line = String(decoding: pending[..<newline], as: UTF8.self)
      pending.removeSubrange(...newline)
      if line.hasPrefix("out_time_us="), let microseconds = Double(line.dropFirst(12)), microseconds.isFinite {
        outputSeconds = max(outputSeconds, microseconds / 1_000_000)
      }
    }
    if pending.count > 4096 { pending.removeAll(keepingCapacity: true) }
  }
}
