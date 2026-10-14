import Foundation

@main
struct WebMTranscoderSelfTest {
  static func main() throws {
    precondition(WebMTranscoder.available, "Test app must bundle WebMRuntime on a supported OS")
    let input = URL(fileURLWithPath: CommandLine.arguments[1])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("output with spaces.webm")
    var updates = [Double]()
    try WebMTranscoder.transcode(input: input, output: output, cancelled: { false }, progress: { updates.append($0) }, bitrateMbps: 8)
    precondition(updates.first == 0 && updates.last == 1, "Progress endpoints")
    precondition(zip(updates, updates.dropFirst()).allSatisfy { $0 <= $1 }, "Progress is monotonic")
    let ffprobe = WebMTranscoder.runtimeURL!.deletingLastPathComponent().appendingPathComponent("ffprobe")
    let probe = Process()
    let pipe = Pipe()
    probe.executableURL = ffprobe
    probe.arguments = ["-v", "error", "-show_entries", "stream=codec_name,width,height,sample_rate", "-show_entries", "format=duration", "-of", "json", output.path]
    probe.standardOutput = pipe
    try probe.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    probe.waitUntilExit()
    precondition(probe.terminationStatus == 0, "Output can be independently demuxed")
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let streams = json["streams"] as! [[String: Any]]
    precondition(streams.contains { $0["codec_name"] as? String == "vp9" && $0["width"] as? Int == 1280 && $0["height"] as? Int == 720 }, "True VP9 video")
    precondition(streams.contains { $0["codec_name"] as? String == "opus" && $0["sample_rate"] as? String == "48000" }, "True Opus audio")
    let info = json["format"] as! [String: Any]
    precondition(abs(Double(info["duration"] as! String)! - 2) < 0.05, "Duration preserved")
    let successful = try Data(contentsOf: output)
    var cancel = false
    do {
      try WebMTranscoder.transcode(input: input, output: output, cancelled: { cancel }, progress: { _ in cancel = true })
      preconditionFailure("Running cancellation did not throw")
    } catch WebMTranscodeError.cancelled { }
    precondition(try Data(contentsOf: output) == successful, "Cancellation preserves existing output")
    let invalid = directory.appendingPathComponent("invalid.mp4")
    try Data("invalid movie".utf8).write(to: invalid)
    do {
      try WebMTranscoder.transcode(input: invalid, output: output, cancelled: { false })
      preconditionFailure("Invalid input did not fail")
    } catch WebMTranscodeError.failed(let message) {
      precondition(!message.isEmpty, "Failure diagnostics are actionable")
    }
    precondition(try Data(contentsOf: output) == successful, "Failure preserves existing output")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    precondition(!leftovers.contains { $0.hasPrefix(".lumascore-webm-") }, "No partial output remains")
    print("WebM export passed: VP9 + Opus, dimensions, duration, progress, running cancellation, actionable failure, atomic preservation, staging cleanup")
  }
}
