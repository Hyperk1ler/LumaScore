import Foundation

enum MIDIParser {
  private struct RawNote {
    var start: Int
    var end: Int
    var pitch: Int
    var velocity: Float
    var channel: Int
    var port: Int
  }
  private struct RawTrack {
    var name: String
    var notes: [RawNote]

  }
  private struct Tempo {
    var tick: Int
    var micros: Int
    var seconds: Double = 0
  }
  private struct Cursor {
    let bytes: [UInt8]
    var position = 0
    var limit: Int
    mutating func byte() throws -> UInt8 {
      guard position < limit else { throw StudioError.message("MIDI 文件提前结束") }
      defer { position += 1 }
      return bytes[position]
    }
    mutating func integer(_ count: Int) throws -> Int {
      var value = 0
      for _ in 0..<count { value = (value << 8) | Int(try byte()) }
      return value
    }
    mutating func vlq() throws -> Int {
      var value = 0
      for _ in 0..<4 {
        let b = try byte()
        value = (value << 7) | Int(b & 127)
        if b & 128 == 0 { return value }
      }
      throw StudioError.message("MIDI 时间增量超出标准范围")
    }
    mutating func data(_ count: Int) throws -> [UInt8] {
      guard count >= 0, position + count <= limit else { throw StudioError.message("MIDI 事件长度不正确") }
      defer { position += count }
      return Array(bytes[position..<position + count])
    }
    mutating func tag() throws -> String { String(bytes: try data(4), encoding: .ascii) ?? "" }
  }
  static func parse(url: URL) throws -> MIDISequence {
    let bytes = Array(try Data(contentsOf: url))
    var c = Cursor(bytes: bytes, limit: bytes.count)
    guard try c.tag() == "MThd" else { throw StudioError.message("这不是标准 MIDI 文件") }
    let header = try c.integer(4)
    guard header >= 6, header <= bytes.count - 8 else { throw StudioError.message("MIDI 头信息损坏") }
    let format = try c.integer(2)
    let count = try c.integer(2)
    let division = try c.integer(2)
    guard format <= 1 else { throw StudioError.message("暂不支持独立时间线的 MIDI 格式 2") }
    guard division != 0 else { throw StudioError.message("MIDI 时钟分辨率为零") }
    _ = try c.data(header - 6)
    var tempos: [Tempo] = [Tempo(tick: 0, micros: 500000)]
    var rawTracks: [RawTrack] = []
    // Channel controls belong to the MIDI stream, not to the containing SMF track.
    // Merge absolute ticks first, keeping the note-on track as the rendered owner.
    struct Event {
      var tick: Int, track: Int, order: Int, port: Int, channel: Int
      var kind: UInt8
      var a: Int, b: Int
      var bus: Int { port * 16 + channel }
    }
    var events: [Event] = []
    var songTick = 0
    for ti in 0..<count {
      guard try c.tag() == "MTrk" else { throw StudioError.message("找不到 MIDI 轨道") }
      let length = try c.integer(4)
      let end = c.position + length
      guard end <= bytes.count else { throw StudioError.message("MIDI 轨道长度超出文件") }
      c.limit = end
      var tick = 0, port = 0, order = 0
      var running: UInt8 = 0
      var name = "轨道 \(ti + 1)"
      while c.position < end {
        tick += try c.vlq()
        var status = try c.byte()
        if status < 128 {
          guard running >= 128 else { throw StudioError.message("MIDI running status 不正确") }
          c.position -= 1
          status = running
        }
        if status == 255 {
          let type = try c.byte()
          let length = try c.vlq()
          let payload = try c.data(length)
          if type == 3 {
            name = String(bytes: payload, encoding: .utf8)
              ?? String(bytes: payload, encoding: .isoLatin1) ?? name
          }
          if type == 33, payload.count == 1 { port = Int(payload[0]) }
          if type == 81, payload.count == 3 {
            let micros = (Int(payload[0]) << 16) | (Int(payload[1]) << 8) | Int(payload[2])
            if micros > 0 { tempos.append(Tempo(tick: tick, micros: micros)) }
          }
          if type == 47 { break }
          continue
        }
        if status == 240 || status == 247 {
          running = 0
          _ = try c.data(c.vlq())
          continue
        }
        guard status < 240 else { throw StudioError.message("不支持的 MIDI 系统事件") }
        running = status
        let kind = status & 240
        let channel = Int(status & 15)
        let a = Int(try c.byte())
        let b = (kind == 192 || kind == 208) ? 0 : Int(try c.byte())
        guard a < 128, b < 128 else { throw StudioError.message("MIDI 数据字节不正确") }
        events.append(Event(tick: tick, track: ti, order: order, port: port,
          channel: channel, kind: kind, a: a, b: b))
        order += 1
      }
      rawTracks.append(RawTrack(name: name, notes: []))
      songTick = max(songTick, tick)
      c.position = end
      c.limit = bytes.count
    }
    events.sort {
      if $0.tick != $1.tick { return $0.tick < $1.tick }
      if $0.track != $1.track { return $0.track < $1.track }
      return $0.order < $1.order
    }
    struct Started {
      var tick: Int, track: Int, port: Int, channel: Int, pitch: Int
      var velocity: Float
    }
    var open: [Int: [Started]] = [:]
    var held: [Int: [Started]] = [:]
    var pedal: [Int: Bool] = [:]
    var bendSemitones: [Int: Int] = [:], bendCents: [Int: Int] = [:]
    var wheel: [Int: Float] = [:]
    var rpnMSB: [Int: Int] = [:], rpnLSB: [Int: Int] = [:]
    var bends: [Int: [(Int, Float)]] = [:], mods: [Int: [(Int, Float)]] = [:]
    func finish(_ note: Started, at tick: Int) {
      rawTracks[note.track].notes.append(RawNote(start: note.tick,
        end: max(tick, note.tick + 1), pitch: note.pitch, velocity: note.velocity,
        channel: note.channel, port: note.port))
    }
    func release(_ event: Event) {
      let key = event.bus * 128 + event.a
      guard var stack = open[key], !stack.isEmpty else { return }
      let owner = stack.firstIndex { $0.track == event.track } ?? 0
      let note = stack.remove(at: owner)
      open[key] = stack
      if pedal[event.bus] == true { held[event.bus, default: []].append(note) }
      else { finish(note, at: event.tick) }
    }
    func releaseHeld(_ bus: Int, at tick: Int) {
      for note in held[bus] ?? [] { finish(note, at: tick) }
      held[bus] = []
    }
    func recordBend(_ bus: Int, at tick: Int) {
      let range = Float(bendSemitones[bus] ?? 2) + Float(bendCents[bus] ?? 0) / 100
      bends[bus, default: []].append((tick, (wheel[bus] ?? 0) * range))
    }
    for event in events {
      let bus = event.bus
      switch event.kind {
      case 144 where event.b > 0:
        open[bus * 128 + event.a, default: []].append(Started(tick: event.tick,
          track: event.track, port: event.port, channel: event.channel, pitch: event.a,
          velocity: Float(event.b) / 127))
      case 128, 144: release(event)
      case 224:
        wheel[bus] = (Float(event.a | (event.b << 7)) - 8192) / 8192
        recordBend(bus, at: event.tick)
      case 176:
        switch event.a {
        case 1: mods[bus, default: []].append((event.tick, Float(event.b) / 127))
        case 101: rpnMSB[bus] = event.b
        case 100: rpnLSB[bus] = event.b
        case 98, 99:
          // NRPN selection replaces RPN selection on this same channel.
          rpnMSB[bus] = 127; rpnLSB[bus] = 127
        case 6, 38:
          if rpnMSB[bus] == 0, rpnLSB[bus] == 0 {
            if event.a == 6 { bendSemitones[bus] = event.b }
            else { bendCents[bus] = min(99, event.b) }
            // A sensitivity change affects an already displaced wheel as well.
            if wheel[bus] != nil { recordBend(bus, at: event.tick) }
          }
        case 64:
          if pedal[bus] == true, event.b < 64 { releaseHeld(bus, at: event.tick) }
          pedal[bus] = event.b >= 64
        case 120, 123:
          for key in open.keys.filter({ $0 / 128 == bus }) {
            for note in open[key] ?? [] {
              if event.a == 123, pedal[bus] == true { held[bus, default: []].append(note) }
              else { finish(note, at: event.tick) }
            }
            open[key] = []
          }
          if event.a == 120 { releaseHeld(bus, at: event.tick) }
        case 121:
          releaseHeld(bus, at: event.tick)
          pedal[bus] = false
          rpnMSB[bus] = 127; rpnLSB[bus] = 127
          wheel[bus] = 0
          recordBend(bus, at: event.tick)
          mods[bus, default: []].append((event.tick, 0))
        default: break
        }
      default: break
      }
    }
    for stack in open.values { for note in stack { finish(note, at: songTick) } }
    for stack in held.values { for note in stack { finish(note, at: songTick) } }
    tempos = tempos.enumerated().sorted { a, b in
      a.element.tick == b.element.tick ? a.offset < b.offset : a.element.tick < b.element.tick
    }.map { $0.element }
    var unique: [Tempo] = []
    for tempo in tempos {
      if unique.last?.tick == tempo.tick {
        unique[unique.count - 1] = tempo
      } else {
        unique.append(tempo)
      }
    }
    tempos = unique
    let smpte = division & 32768 != 0
    let secondsPerTick: Double
    if smpte {
      let signed = Int(Int8(bitPattern: UInt8(division >> 8)))
      let fps = signed == -29 ? 29.97 : Double(-signed)
      guard [24, 25, 29, 30].contains(-signed), division & 255 > 0 else {
        throw StudioError.message("MIDI SMPTE 时钟不正确")
      }
      secondsPerTick = 1 / (fps * Double(division & 255))
    } else {
      secondsPerTick = 0
    }
    if !smpte, tempos.count > 1 {
      for i in 1..<tempos.count {
        tempos[i].seconds =
          tempos[i - 1].seconds + Double(tempos[i].tick - tempos[i - 1].tick)
          * Double(tempos[i - 1].micros) / 1_000_000 / Double(division)
      }
    }
    func seconds(_ tick: Int) -> Double {
      if smpte { return Double(tick) * secondsPerTick }
      var lo = 0
      var hi = tempos.count
      while lo < hi {
        let m = (lo + hi) / 2
        if tempos[m].tick <= tick { lo = m + 1 } else { hi = m }
      }
      let t = tempos[max(0, lo - 1)]
      return t.seconds + Double(tick - t.tick) * Double(t.micros) / 1_000_000 / Double(division)
    }
    var tracks: [MIDITrack] = []
    for (i, track) in rawTracks.enumerated() {
      let buses = Set(track.notes.map { $0.port * 16 + $0.channel }).sorted()
      let ports = Set(track.notes.map { $0.port })
      for bus in buses {
        let channel = bus % 16, port = bus / 16
        let ns = track.notes.filter { $0.port * 16 + $0.channel == bus }.map {
          MIDINote(start: seconds($0.start), duration: seconds($0.end) - seconds($0.start),
            pitch: $0.pitch, velocity: $0.velocity)
        }.sorted { $0.start < $1.start }
        tracks.append(MIDITrack(
          id: "\(url.lastPathComponent):\(i):\(channel)" + (ports.count > 1 ? ":P\(port)" : ""),
          name: track.name + (buses.count > 1 ? " · CH\(channel + 1)" : "")
            + (ports.count > 1 ? " · Port \(port + 1)" : ""),
          channel: channel, notes: ns,
          bends: (bends[bus] ?? []).map { MIDIControl(time: seconds($0.0), value: $0.1) },
          modulation: (mods[bus] ?? []).map { MIDIControl(time: seconds($0.0), value: $0.1) },endTime:ns.map{$0.end}.max()))
      }
    }
    let all = tracks.flatMap { $0.notes }
    guard !all.isEmpty else { throw StudioError.message("MIDI 文件没有音符事件") }
    var tempoMap: [MIDITempo] = []
    for tempo in tempos {
      let time = seconds(tempo.tick)
      let bpm = 60_000_000 / Double(tempo.micros)
      let previous = tempoMap.last
      let beat = smpte
        ? (previous.map { $0.beat + (time-$0.time)*$0.bpm/60 } ?? 0)
        : Double(tempo.tick)/Double(division)
      tempoMap.append(MIDITempo(time: time, bpm: bpm, beat: beat))
    }
    return MIDISequence(
      tracks: tracks, bpm: 60_000_000 / Double(tempos.first?.micros ?? 500000),
      duration: max(seconds(songTick), all.map { $0.end }.max() ?? 0),
      minPitch: all.map { $0.pitch }.min() ?? 48, maxPitch: all.map { $0.pitch }.max() ?? 84,
      tempoMap: tempoMap)
  }
}
