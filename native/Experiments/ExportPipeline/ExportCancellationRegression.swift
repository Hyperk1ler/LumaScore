import Foundation

/// Pre-start cancellation must avoid renderer/encoder creation and preserve any
/// existing user file. The default run needs no GPU; --active also checks
/// cancellation during a real export while the process survives late callbacks.
@main struct ExportCancellationRegression {
  static func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw StudioError.message(message) }
    print("PASS \(message)")
  }
  static func runActive(destination: URL, backend: RendererBackend) throws {
    let lock = NSLock(), completed = DispatchSemaphore(value: 0)
    var completionCount = 0, progressCount = 0, requestedCancellation = false
    var errorMessage: String?
    var settings = StudioSettings()
    settings.resolution = 2160
    settings.fps = 60
    settings.glow = 0
    let snapshot = RenderSnapshot(tracks: [], styles: [:], settings: settings,
      bpm: 120, duration: 30, minPitch: 48, maxPitch: 84, backgroundURL: nil)
    var operation: ExportOperation!
    operation = ExportOperation(snapshot: snapshot, audioURL: nil, destination: destination,
      progress: { value in
        lock.lock()
        progressCount += 1
        let cancelNow = !requestedCancellation && value > 0
        if cancelNow { requestedCancellation = true }
        lock.unlock()
        if cancelNow { operation.cancel() }
      },
      completion: { result in
        lock.lock()
        completionCount += 1
        if case .failure(let error) = result { errorMessage = error.localizedDescription }
        lock.unlock()
        completed.signal()
      }, rendererBackend: backend)
    operation.startExport()
    try check(completed.wait(timeout: .now() + 15) == .success,
      "\(backend.rawValue) active cancellation completes promptly")
    operation.cancel()
    // Stay alive so GPU completion callbacks can run after the export fails.
    try check(completed.wait(timeout: .now() + 0.5) == .timedOut,
      "\(backend.rawValue) late GPU callbacks do not complete the export again")
    lock.lock()
    let counts = (completionCount, progressCount), requested = requestedCancellation, error = errorMessage
    lock.unlock()
    try check(counts.0 == 1 && counts.1 > 0 && requested && error == "已取消导出",
      "\(backend.rawValue) cancellation begins after frames were appended")
    try check(!FileManager.default.fileExists(atPath: destination.path),
      "\(backend.rawValue) active cancellation leaves no residual output")
    operation = nil
  }
  static func run(destination: URL, expectedContents: Data?) throws {
    let lock = NSLock(), completed = DispatchSemaphore(value: 0)
    var completionCount = 0, progressCount = 0, errorMessage: String?
    let snapshot = RenderSnapshot(tracks: [], styles: [:], settings: StudioSettings(),
      bpm: 120, duration: 1, minPitch: 48, maxPitch: 84, backgroundURL: nil)
    let operation = ExportOperation(snapshot: snapshot, audioURL: nil, destination: destination,
      progress: { _ in lock.lock(); progressCount += 1; lock.unlock() },
      completion: { result in
        lock.lock()
        completionCount += 1
        if case .failure(let error) = result { errorMessage = error.localizedDescription }
        lock.unlock()
        completed.signal()
      })
    operation.cancel()
    operation.cancel()
    operation.startExport()
    try check(completed.wait(timeout: .now() + 2) == .success, "Pre-start cancellation completes promptly")
    operation.cancel()
    // Another callback would signal again; leave the asynchronous failure path
    // enough time to reveal duplicate completion without spinning the main loop.
    try check(completed.wait(timeout: .now() + 0.1) == .timedOut, "Cancellation completion is delivered once")
    lock.lock()
    let counts = (completionCount, progressCount), error = errorMessage
    lock.unlock()
    try check(counts.0 == 1 && counts.1 == 0 && error == "已取消导出",
      "Cancellation reports the intended error without export progress")
    if let expectedContents {
      try check(try Data(contentsOf: destination) == expectedContents,
        "Pre-start cancellation preserves an existing destination byte for byte")
    } else {
      try check(!FileManager.default.fileExists(atPath: destination.path),
        "Pre-start cancellation creates no destination")
    }
  }
  static func main() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumascore-cancel-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try run(destination: directory.appendingPathComponent("new.mp4"), expectedContents: nil)
    let existing = directory.appendingPathComponent("existing.mp4")
    let sentinel = Data("Existing user document: never overwrite or delete".utf8)
    try sentinel.write(to: existing)
    try run(destination: existing, expectedContents: sentinel)
    if CommandLine.arguments.contains("--active") {
      try runActive(destination: directory.appendingPathComponent("active-automatic.mp4"), backend: .automatic)
      try runActive(destination: directory.appendingPathComponent("active-legacy.mp4"), backend: .legacy)
    }
    print("All selected export cancellation regressions passed")
  }
}
