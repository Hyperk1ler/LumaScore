import Foundation

@main struct WebMExportCancellationRegression {
  static func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw StudioError.message(message) }
    print("PASS \(message)")
  }
  static func main() throws {
    try check(WebMTranscoder.available, "Isolated test bundle resolves the bundled WebM runtime")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumascore-webm-cancel-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("cancel.webm")
    let preserved = directory.appendingPathComponent("existing-user-file.webm")
    let sentinel = Data("Unrelated existing user file must survive WebM cleanup".utf8)
    try sentinel.write(to: preserved)
    let lock = NSLock(), completed = DispatchSemaphore(value: 0), monitorDone = DispatchSemaphore(value: 0)
    var completions = 0, errorMessage: String?, sawTranscodeTemporary = false
    var settings = StudioSettings()
    settings.container = .webm; settings.resolution = 720; settings.fps = 30
    settings.glow = 0; settings.crtEnabled = true
    let snapshot = RenderSnapshot(tracks: [], styles: [:], settings: settings,
      bpm: 120, duration: 5, minPitch: 48, maxPitch: 84, backgroundURL: nil)
    let operation = ExportOperation(snapshot: snapshot, audioURL: nil, destination: destination,
      progress: { _ in }, completion: { result in
        lock.lock()
        completions += 1
        if case .failure(let error) = result { errorMessage = error.localizedDescription }
        lock.unlock()
        completed.signal()
      })
    operation.startExport()
    DispatchQueue.global(qos: .userInitiated).async {
      defer { monitorDone.signal() }
      let deadline = ProcessInfo.processInfo.systemUptime + 20
      while ProcessInfo.processInfo.systemUptime < deadline {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        if names.contains(where: { $0.hasPrefix(".lumascore-webm-") }) {
          lock.lock(); sawTranscodeTemporary = true; lock.unlock()
          operation.cancel()
          return
        }
        lock.lock(); let ended = completions > 0; lock.unlock()
        if ended { return }
        Thread.sleep(forTimeInterval: 0.002)
      }
      operation.cancel()
    }
    try check(completed.wait(timeout: .now() + 25) == .success, "WebM transcode cancellation completes promptly")
    try check(monitorDone.wait(timeout: .now() + 2) == .success, "Transcode observer finishes")
    try check(completed.wait(timeout: .now() + 0.5) == .timedOut, "WebM late callbacks do not complete again")
    lock.lock(); let count = completions, error = errorMessage, observed = sawTranscodeTemporary; lock.unlock()
    try check(observed, "Cancellation happens after FFmpeg creates its actual WebM temporary output")
    try check(count == 1 && error == "已取消导出", "WebM cancellation wins terminal state exactly once")
    let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    try check(remaining == [preserved.lastPathComponent], "WebM output and both intermediate files stay removed after callbacks")
    try check(try Data(contentsOf: preserved) == sentinel, "WebM cancellation preserves an existing unrelated user file")
    print("All WebM transcode cancellation regressions passed")
  }
}
