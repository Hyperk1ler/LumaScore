import Foundation

/// A detected name plus the ordered, enharmonically spelled pitch classes.
struct ChordLabel: Equatable {
  var name: String
  var components: String
}

struct ChordTimeline {
  fileprivate struct Segment {
    var start: Double
    var end: Double
    var label: ChordLabel
  }
  fileprivate var segments: [Segment]
  fileprivate var hasSelection: Bool

  /// MIDI/source time, independent of playback direction or render frame rate.
  /// A silent gap holds the previous name for 0.75 seconds; component notes disappear.
  func chord(at time: Double) -> ChordLabel? {
    guard hasSelection, time.isFinite else { return nil }
    var low = 0
    var high = segments.count
    while low < high {
      let middle = (low + high) / 2
      if segments[middle].start <= time { low = middle + 1 } else { high = middle }
    }
    guard low > 0 else { return ChordLabel(name: "N.C.", components: "") }
    let segment = segments[low - 1]
    if time < segment.end { return segment.label }
    if time - segment.end <= 0.75 {
      return ChordLabel(name: segment.label.name, components: "")
    }
    return ChordLabel(name: "N.C.", components: "")
  }
}

enum ChordAnalyzer {
  private struct Pattern {
    let suffix: String
    let intervals: [Int]
  }
  // Musical interval sets, ordered from extended harmonies to simpler chords.
  private static let patterns: [Pattern] = [
    Pattern(suffix: "maj13", intervals: [0, 2, 4, 5, 7, 9, 11]),
    Pattern(suffix: "13", intervals: [0, 2, 4, 5, 7, 9, 10]),
    Pattern(suffix: "m13", intervals: [0, 2, 3, 5, 7, 9, 10]),
    Pattern(suffix: "maj11", intervals: [0, 2, 4, 5, 7, 11]),
    Pattern(suffix: "11", intervals: [0, 2, 4, 5, 7, 10]),
    Pattern(suffix: "m11", intervals: [0, 2, 3, 5, 7, 10]),
    Pattern(suffix: "9(♯11)", intervals: [0, 2, 4, 6, 7, 10]),
    Pattern(suffix: "maj9", intervals: [0, 2, 4, 7, 11]),
    Pattern(suffix: "m9", intervals: [0, 2, 3, 7, 10]),
    Pattern(suffix: "9", intervals: [0, 2, 4, 7, 10]),
    Pattern(suffix: "7(♯9)", intervals: [0, 3, 4, 7, 10]),
    Pattern(suffix: "7(♭9)", intervals: [0, 1, 4, 7, 10]),
    Pattern(suffix: "7(♯11)", intervals: [0, 4, 6, 7, 10]),
    Pattern(suffix: "7♭5", intervals: [0, 4, 6, 10]),
    Pattern(suffix: "7(no3)", intervals: [0, 7, 10]),
    Pattern(suffix: "maj7", intervals: [0, 4, 7, 11]),
    Pattern(suffix: "m(maj7)", intervals: [0, 3, 7, 11]),
    Pattern(suffix: "m7", intervals: [0, 3, 7, 10]),
    Pattern(suffix: "m7♭5", intervals: [0, 3, 6, 10]),
    Pattern(suffix: "7sus4", intervals: [0, 5, 7, 10]),
    Pattern(suffix: "7", intervals: [0, 4, 7, 10]),
    Pattern(suffix: "6", intervals: [0, 4, 7, 9]),
    Pattern(suffix: "m6", intervals: [0, 3, 7, 9]),
    Pattern(suffix: "add9", intervals: [0, 2, 4, 7]),
    Pattern(suffix: "m(add9)", intervals: [0, 2, 3, 7]),
    Pattern(suffix: "aug", intervals: [0, 4, 8]),
    Pattern(suffix: "dim7", intervals: [0, 3, 6, 9]),
    Pattern(suffix: "sus2", intervals: [0, 2, 7]),
    Pattern(suffix: "", intervals: [0, 4, 7]),
    Pattern(suffix: "m", intervals: [0, 3, 7]),
    Pattern(suffix: "dim", intervals: [0, 3, 6]),
    Pattern(suffix: "sus4", intervals: [0, 5, 7]),
  ]
  private static let pitchNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
  private static let naturals = [0, 2, 4, 5, 7, 9, 11]
  private static let letters = ["C", "D", "E", "F", "G", "A", "B"]
  private static let degrees = [0, 1, 1, 2, 2, 3, 4, 4, 4, 5, 6, 6]

  static func timeline(tracks: [MIDITrack], selectedIDs: Set<String>) -> ChordTimeline {
    struct Event {
      let time: Double
      let pitch: Int
      let delta: Int
    }
    var events: [Event] = []
    for track in tracks where selectedIDs.contains(track.id) {
      for note in track.notes where note.start.isFinite && note.duration.isFinite
        && note.duration > 0 && (0...127).contains(note.pitch)
      {
        guard note.end.isFinite else { continue }
        events.append(Event(time: note.start, pitch: note.pitch, delta: 1))
        events.append(Event(time: note.end, pitch: note.pitch, delta: -1))
      }
    }
    events.sort {
      if $0.time != $1.time { return $0.time < $1.time }
      if $0.pitch != $1.pitch { return $0.pitch < $1.pitch }
      return $0.delta < $1.delta
    }
    var active: [Int: Int] = [:]
    var segments: [ChordTimeline.Segment] = []
    var index = 0
    while index < events.count {
      let start = events[index].time
      // Process note offs and ons together: [start, end) MIDI semantics.
      while index < events.count && events[index].time == start {
        let event = events[index]
        let count = (active[event.pitch] ?? 0) + event.delta
        if count > 0 { active[event.pitch] = count } else { active.removeValue(forKey: event.pitch) }
        index += 1
      }
      guard index < events.count, !active.isEmpty else { continue }
      let end = events[index].time
      let label = detect(pitches: active.keys.sorted())
      if let last = segments.last, last.end == start && last.label == label {
        segments[segments.count - 1].end = end
      } else {
        segments.append(ChordTimeline.Segment(start: start, end: end, label: label))
      }
    }
    return ChordTimeline(segments: segments, hasSelection: !selectedIDs.isEmpty)
  }

  private static func pitchClass(_ pitch: Int) -> Int { (pitch % 12 + 12) % 12 }
  private static func uniqueClasses(_ pitches: [Int]) -> [Int] {
    var seen = Set<Int>()
    return pitches.map(pitchClass).filter { seen.insert($0).inserted }
  }
  private static func intervals(_ classes: [Int], root: Int) -> [Int] {
    classes.map { ($0 - root + 12) % 12 }.sorted()
  }
  private static func match(_ classes: [Int], roots: [Int]) -> (Int, Pattern)? {
    for root in roots {
      let relative = intervals(classes, root: root)
      for pattern in patterns where relative == pattern.intervals { return (root, pattern) }
    }
    return nil
  }
  private static func spell(root: Int, pitch: Int, diminishedSeventh: Bool = false) -> String {
    let interval = (pitch - root + 12) % 12
    if interval == 0 { return pitchNames[root] }
    let rootLetter = String(pitchNames[root].prefix(1))
    let letterIndex = ((letters.firstIndex(of: rootLetter) ?? 0)
      + (diminishedSeventh && interval == 9 ? 6 : degrees[interval])) % 7
    // Express the accidental relative to the chosen natural note.
    let accidental = (pitch - naturals[letterIndex] + 6) % 12 - 6
    let suffix: String
    switch accidental {
    case 2: suffix = "𝄪"
    case 1: suffix = "♯"
    case -1: suffix = "♭"
    case -2: suffix = "𝄫"
    default: suffix = ""
    }
    return letters[letterIndex] + suffix
  }
  private static func label(classes: [Int], root: Int?, suffix: String = "", bass: Int?) -> ChordLabel {
    guard let root else {
      return ChordLabel(name: "N.C.", components: classes.map { pitchNames[$0] }.joined(separator: ","))
    }
    var name = pitchNames[root] + suffix
    if let bass, bass != root { name += "/" + spell(root: root, pitch: bass, diminishedSeventh: suffix == "dim7") }
    return ChordLabel(name: name, components: classes.map {
      spell(root: root, pitch: $0, diminishedSeventh: suffix == "dim7")
    }.joined(separator: ","))
  }
  private static func detect(pitches: [Int]) -> ChordLabel {
    let classes = uniqueClasses(pitches)
    guard classes.count > 1, let bass = pitches.first.map(pitchClass) else {
      return label(classes: classes, root: nil, bass: nil)
    }
    if classes.count == 2 {
      for root in classes where intervals(classes, root: root) == [0, 7] {
        return label(classes: classes, root: root, suffix: "5", bass: bass)
      }
    }
    if let (root, pattern) = match(classes, roots: classes) {
      return label(classes: classes, root: root, suffix: pattern.suffix, bass: bass)
    }
    // A nonchord bass can accompany a complete upper-voice chord (C/D, etc.).
    let upper = classes.filter { $0 != bass }
    if let (root, pattern) = match(upper, roots: upper) {
      return label(classes: classes, root: root, suffix: pattern.suffix, bass: bass)
    }
    return label(classes: classes, root: nil, bass: nil)
  }
}
