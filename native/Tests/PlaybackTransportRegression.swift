import AVFoundation
import Foundation

@main struct PlaybackTransportRegression {
  static func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw StudioError.message(message) }
    print("PASS \(message)")
  }
  static func run(_ seconds: Double, sample: (() throws -> Void)? = nil) throws {
    let end = ProcessInfo.processInfo.systemUptime + seconds
    while ProcessInfo.processInfo.systemUptime < end {
      RunLoop.current.run(until: Date().addingTimeInterval(0.002))
      try sample?()
    }
  }
  static func main() throws {
    let model = StudioModel()
    model.settings = StudioSettings()
    model.settings.volume = 0
    model.settings.intro = 0.7
    model.midiDuration = 5
    let fixture = CommandLine.arguments.dropFirst().first ?? "Fixtures/representative-5s.wav"
    model.loadAudio(URL(fileURLWithPath: fixture))
    let end = ProcessInfo.processInfo.systemUptime + 15
    while model.analyzingAudio && ProcessInfo.processInfo.systemUptime < end { try run(0.005) }
    try check(model.audioURL != nil, "Local audio imported")
    // Inspect the real private transport without adding production test hooks.
    let wrapped = Mirror(reflecting: model).children.first { $0.label == "player" }!.value
    let player = Mirror(reflecting: wrapped).children.first!.value as! AVPlayer
    try check(!player.automaticallyWaitsToMinimizeStalling, "Local player supports host-time scheduling")

    model.settings.intro = 0
    model.seek(0)
    model.play()
    try check(model.preparingPlayback && model.currentTime == 0, "Cold start holds media origin until decoder is ready")
    let readyDeadline = ProcessInfo.processInfo.systemUptime + 5
    while model.preparingPlayback && ProcessInfo.processInfo.systemUptime < readyDeadline { try run(0.002) }
    try check(model.playing && model.currentTime < 0.025, "Prepared cold start begins at audio origin")
    try run(0.1)
    try check(abs(player.currentTime().seconds - model.currentTime) < 0.03, "Cold start stays synchronized without skipping the opening")
    model.pause()
    model.seek(0)
    model.play()
    model.togglePlayback()
    try run(0.1)
    try check(!model.playing && !model.preparingPlayback && player.rate == 0, "Toggle cancels pending preparation")
    model.settings.intro = 0.7
    model.seek(0)

    model.play()
    try run(0.2)
    model.pause()
    let paused = model.time
    try run(0.8)
    try check(model.currentTime == paused && player.rate == 0 && player.currentTime().seconds < 0.01,
      "Pause cancels pending lead-in audio")

    model.seek(0.5)
    model.play()
    var last = model.currentTime, plateau = 0.0
    let began = ProcessInfo.processInfo.systemUptime
    try run(0.4) {
      let time = model.currentTime
      if time - last < 0.0001 { plateau += 0.002 }
      try checkSilently(time >= last, "Timeline went backwards at audio onset")
      last = time
    }
    try check(plateau < 0.01 && abs(model.currentTime - (0.5 + ProcessInfo.processInfo.systemUptime - began)) < 0.01,
      "Resume through lead-in stays continuous")
    try check(abs(player.currentTime().seconds - (model.currentTime - 0.7)) < 0.03 && player.rate > 0,
      "Scheduled audio and picture remain synchronized")

    model.seek(2)
    model.seek(0.1)
    model.pause()
    try run(0.3)
    try check(!model.playing && player.rate == 0, "Rapid seeks followed by pause never restart audio")
    model.play()
    try run(0.9)
    try check(player.rate > 0 && abs(player.currentTime().seconds - (model.currentTime - 0.7)) < 0.03,
      "Resume ignores stale seek and preroll completions")

    model.seek(1.4)
    try run(0.25)
    try check(abs(player.currentTime().seconds - (model.currentTime - 0.7)) < 0.03,
      "Seeking beyond lead-in aligns with running timeline")
    model.pause()
    let stopped = model.time
    try run(0.1)
    try check(model.currentTime == stopped && player.rate == 0, "Pause after onset holds time")

    model.seek(0)
    model.play()
    try run(0.15)
    model.settings.intro = 1.2
    try run(0.65)
    try check(model.currentTime > 0.75 && player.currentTime().seconds < 0.01,
      "Editing lead-in cancels the previous audio start without stopping the picture")
    try run(0.5)
    try check(player.rate > 0 && abs(player.currentTime().seconds - (model.currentTime - 1.2)) < 0.03,
      "Edited lead-in uses the new host-time start")
    model.pause()
    model.settings.intro = 0.7

    model.settings.loop = true
    model.settings.exportStart = 0
    model.settings.exportEnd = 1
    model.seek(0)
    model.play()
    var wraps = 0, previous = model.currentTime
    try run(3.3) {
      let time = model.currentTime
      if time < previous - 0.3 { wraps += 1 }
      if time > 0.15 && time < 0.6 {
        try checkSilently(player.currentTime().seconds < 0.02, "Old audio continued in loop lead-in")
      }
      previous = time
    }
    model.pause()
    try check(wraps >= 2, "Repeated loops reset audio and render lead-in")
    print("ALL PLAYBACK TRANSPORT REGRESSIONS PASSED")
  }
  static func checkSilently(_ condition: Bool, _ message: String) throws {
    if !condition { throw StudioError.message(message) }
  }
}
