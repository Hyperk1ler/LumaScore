import Foundation
import Metal

/// Compare actual GPU output, including delayed media and three concurrent frame slots.
/// --benchmark excludes API validation and video encoding from renderer measurements.
@main struct Metal4Regression {
  static func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw StudioError.message(message) }
    print("PASS \(message)")
  }
  static func main() throws {
    guard #available(macOS 26.0, *), let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else {
      print("SKIP Metal 4: unsupported OS/GPU; legacy regressions cover fallback")
      return
    }
    let sequence = try MIDIParser.parse(url: URL(fileURLWithPath: "Fixtures/representative-5s.mid"))
    let audio = try AudioAnalyzer.analyze(url: URL(fileURLWithPath: "Fixtures/representative-5s.wav"))
    let styles = Dictionary(uniqueKeysWithValues: sequence.tracks.enumerated().map {
      ($0.element.id, TrackStyle(color: RGB.palette[$0.offset % RGB.palette.count]))
    })
    var settings = StudioSettings(); settings.intro = 2; settings.chordEnabled = true
    settings.chordTrackIDs = sequence.tracks.map { $0.id }; settings.title = "Metal 4 · 渲染校验"
    let base = RenderSnapshot(tracks: sequence.tracks, styles: styles, settings: settings,
      bpm: sequence.bpm, duration: sequence.duration, minPitch: sequence.minPitch,
      maxPitch: sequence.maxPitch, backgroundURL: nil, audioVisualization: audio, audioName: "GPU regression")
    let cases: [(String, Int, (inout StudioSettings) -> Void)] = [
      ("direct", 720, { $0.glow = 0; $0.cameraShake = 0; $0.cameraPunch = 0 }),
      ("CRT+grade", 720, { $0.glow = 0; $0.crtEnabled = true; $0.colorFilterEnabled = true; $0.saturation = 0.7; $0.fisheye = 0.5 }),
      ("hybrid+bloom", 1080, { $0.scene = .hybrid; $0.glow = 0.4; $0.crtEnabled = true }),
      ("audio+bloom", 1080, { $0.scene = .audio; $0.applyAudioTemplate(.recordSleeve); $0.glow = 0.4; $0.metronomeEnabled = true }),
      ("4K+wide bloom", 2160, { $0.glow = 0.4; $0.glowRadius = 40; $0.fisheye = 0.6 })
    ]
    let benchmark = CommandLine.arguments.contains("--benchmark")
    for (name, height, configure) in cases {
      var snapshot = base; configure(&snapshot.settings)
      let legacy = try MetalSceneRenderer(snapshot: snapshot, backend: .legacy)
      let modern = try MetalSceneRenderer(snapshot: snapshot, backend: .metal4)
      try check(modern.backend == .metal4 && legacy.backend == .legacy, "\(name) creates adaptive and reference renderers")
      let width = height * 16 / 9
      func targets(_ renderer: MetalSceneRenderer) -> [MTLTexture] {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.storageMode = .shared; d.usage = [.renderTarget, .shaderRead]
        return (0..<3).map { _ in renderer.device.makeTexture(descriptor: d)! }
      }
      let a = targets(legacy), b = targets(modern)
      func draw(_ renderer: MetalSceneRenderer, _ textures: [MTLTexture], times: [Double], fade: Float = 1) throws {
        let group = DispatchGroup(), lock = NSLock(); var errors: [Error] = []
        for (slot, time) in times.enumerated() {
          group.enter()
          try renderer.encode(target: textures[slot], time: time, slot: slot, fade: fade) { error in
            lock.lock(); if let error { errors.append(error) }; lock.unlock(); group.leave()
          }
        }
        guard group.wait(timeout: .now() + 30) == .success else { throw StudioError.message("GPU timeout") }
        if let error = errors.first { throw error }
      }
      if benchmark {
        // Exclude first-use allocations, fonts and pipeline warmup from the measured samples.
        try draw(legacy, a, times: [2.2, 2.3, 2.4]); try draw(modern, b, times: [2.2, 2.3, 2.4])
        for round in 0..<3 {
          let pair = [("legacy", legacy, a), ("adaptive", modern, b)]
          for (label, renderer, textures) in (round % 2 == 0 ? pair : Array(pair.reversed())) {
            let before = (renderer.metrics.build, renderer.metrics.gpu, renderer.metrics.count)
            let began = ProcessInfo.processInfo.systemUptime
            for batch in 0..<200 {
              try draw(renderer, textures, times: (0..<3).map { 2 + Double((batch * 3 + $0) % 300) / 60 })
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            let samples = Double(renderer.metrics.count - before.2)
            let cpu = (renderer.metrics.build - before.0) * 1000 / samples
            let gpu = (renderer.metrics.gpu - before.1) * 1000 / samples
            print("BENCH \(name) round=\(round + 1) \(label) path=\(renderer.metrics.backendSummary): \(600 / elapsed) fps, CPU \(cpu) ms, GPU \(gpu) ms")
          }
        }
      } else {
        for (times, fade) in [([1.99, 2.0, 2.00001], Float(1)), ([2.125, 2.5, 3.1], Float(0.5))] {
          try draw(legacy, a, times: times, fade: fade); try draw(modern, b, times: times, fade: fade)
          var total = 0, maximum = 0, changed = 0
          for slot in 0..<3 {
            var x = [UInt8](repeating: 0, count: width * height * 4), y = x
            a[slot].getBytes(&x, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            b[slot].getBytes(&y, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            for i in x.indices where i % 4 != 3 {
              let delta = abs(Int(x[i]) - Int(y[i])); total += delta; maximum = max(maximum, delta)
              if delta > 8 { changed += 1 }
            }
          }
          let samples = Double(width * height * 9), mean = Double(total) / samples
          print("PIXELS \(name) fade=\(fade): mean=\(mean), max=\(maximum), >8=\(Double(changed) / samples)")
          try check(mean < 0.1 && maximum <= 3 && changed == 0, "\(name) preserves rendered output at delayed media boundary and fades")
        }
        // Reallocation, stale argument bindings, and resource residency after an edit.
        snapshot.settings.glowRadius = 2; snapshot.settings.scene = .audio
        try modern.update(snapshot, rebuild: true)
        try draw(modern, b, times: [2.1, 2.2, 2.3])
        try check(modern.metrics.means.1 > 0, "\(name) completes GPU work after configuration update")
        if name.contains("bloom") && name != "audio+bloom" {
          try check(modern.metrics.backendSummary == "legacy+metal4", "\(name) switches from MPS to Metal 4 when emission disappears")
        } else {
          try check(modern.metrics.backendSummary == "metal4", "\(name) uses Metal 4 for non-emissive frames")
        }
      }
    }
    // A live edit can change backend while older frames remain in flight.
    // Verify event ordering and allocator reuse rather than serializing each frame.
    var live = base; live.settings.glow = 0.4
    let adaptive = try MetalSceneRenderer(snapshot: live)
    let reference = try MetalSceneRenderer(snapshot: live, backend: .legacy)
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 640, height: 360, mipmapped: false)
    d.storageMode = .shared; d.usage = [.renderTarget, .shaderRead]
    let output = (0..<3).map { _ in adaptive.device.makeTexture(descriptor: d)! }
    let expected = reference.device.makeTexture(descriptor: d)!
    for round in 0..<10 {
      let group = DispatchGroup(), lock = NSLock(); var failure: Error?
      for slot in 0..<3 {
        live.settings.glow = slot % 2 == 0 ? 0 : 0.4
        try adaptive.update(live)
        group.enter()
        try adaptive.encode(target: output[slot], time: 2.3, slot: slot) { error in
          lock.lock(); if let error { failure = error }; lock.unlock(); group.leave()
        }
      }
      guard group.wait(timeout: .now() + 30) == .success else { throw StudioError.message("Backend switch timeout") }
      if let error = failure { throw error }
      try reference.update(live)
      let done = DispatchSemaphore(value: 0)
      try reference.encode(target: expected, time: 2.3, slot: 0) { error in failure = error; done.signal() }
      guard done.wait(timeout: .now() + 30) == .success else { throw StudioError.message("Reference timeout") }
      if let error = failure { throw error }
      var a = [UInt8](repeating: 0, count: 640 * 360 * 4), b = a
      output[2].getBytes(&a, bytesPerRow: 640 * 4, from: MTLRegionMake2D(0, 0, 640, 360), mipmapLevel: 0)
      expected.getBytes(&b, bytesPerRow: 640 * 4, from: MTLRegionMake2D(0, 0, 640, 360), mipmapLevel: 0)
      try check(a == b, "In-flight backend switch \(round) preserves the newest frame")
    }
    try check(adaptive.metrics.backendSummary == "legacy+metal4", "Both queues execute and synchronize live edits")
    print("ALL METAL 4 REGRESSIONS PASSED")
  }
}
