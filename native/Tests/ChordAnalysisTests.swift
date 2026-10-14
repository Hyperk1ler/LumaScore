import Foundation

#if CHORD_TEST_AUDIO_STUB
// RenderSnapshot references this separate subsystem; chord tests do not use audio rendering.
struct AudioVisualizationData {}
#endif

@main
struct ChordAnalysisTests {
  struct Fixture { var pitches: [Int]; var name: String; var components: String }
  static func track(_ id: String, pitches: [Int], start: Double = 0, duration: Double = 1) -> MIDITrack {
    MIDITrack(id: id, name: id, channel: 0, notes: pitches.map {
      MIDINote(start: start, duration: duration, pitch: $0, velocity: 1)
    }, bends: [], modulation: [])
  }
  static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
  }
  static func main() throws {
    // Explicit musical examples keep the expected labels independent of the detector.
    let fixtures: [Fixture] = [
      Fixture(pitches: [60], name: "N.C.", components: "C"),
      Fixture(pitches: [60,61], name: "N.C.", components: "C,C♯"),
      Fixture(pitches: [60,67], name: "C5", components: "C,G"),
      Fixture(pitches: [60,64,67], name: "C", components: "C,E,G"),
      Fixture(pitches: [60,63,67], name: "Cm", components: "C,E♭,G"),
      Fixture(pitches: [60,63,66], name: "Cdim", components: "C,E♭,G♭"),
      Fixture(pitches: [60,64,68], name: "Caug", components: "C,E,G♯"),
      Fixture(pitches: [60,62,67], name: "Csus2", components: "C,D,G"),
      Fixture(pitches: [60,65,67], name: "Csus4", components: "C,F,G"),
      Fixture(pitches: [60,64,67,70], name: "C7", components: "C,E,G,B♭"),
      Fixture(pitches: [60,64,67,71], name: "Cmaj7", components: "C,E,G,B"),
      Fixture(pitches: [60,63,67,70], name: "Cm7", components: "C,E♭,G,B♭"),
      Fixture(pitches: [60,63,66,70], name: "Cm7♭5", components: "C,E♭,G♭,B♭"),
      Fixture(pitches: [60,63,66,69], name: "Cdim7", components: "C,E♭,G♭,B𝄫"),
      Fixture(pitches: [60,64,67,69], name: "C6", components: "C,E,G,A"),
      Fixture(pitches: [60,62,64,67], name: "Cadd9", components: "C,D,E,G"),
      Fixture(pitches: [60,62,64,67,70], name: "C9", components: "C,D,E,G,B♭"),
      Fixture(pitches: [60,62,64,67,71], name: "Cmaj9", components: "C,D,E,G,B"),
      Fixture(pitches: [57,60,64,67,71], name: "Am9", components: "A,C,E,G,B"),
      Fixture(pitches: [52,55,60], name: "C/E", components: "E,G,C"),
      Fixture(pitches: [50,60,64,67], name: "Cadd9/D", components: "D,C,E,G"),
      Fixture(pitches: [53,60,64,67], name: "C/F", components: "F,C,E,G")
    ]
    for fixture in fixtures {
      let timeline = ChordAnalyzer.timeline(tracks: [track("a", pitches: fixture.pitches)], selectedIDs: ["a"])
      require(timeline.chord(at: 0.5) == ChordLabel(name: fixture.name, components: fixture.components),
        "Chord mismatch for \(fixture.pitches): \(String(describing: timeline.chord(at: 0.5))) expected \(fixture.name) [\(fixture.components)]")
    }
    let a = track("a", pitches: [60, 64, 67], start: 1, duration: 1)
    let b = track("b", pitches: [57, 60, 64], start: 3, duration: 1)
    let c = track("ignored", pitches: [61, 63, 68], start: 0, duration: 10)
    let timeline = ChordAnalyzer.timeline(tracks: [a, b, c], selectedIDs: ["a", "b"])
    require(timeline.chord(at: 0.5)?.name == "N.C.", "Before first note")
    require(timeline.chord(at: 1) == ChordLabel(name: "C", components: "C,E,G"), "Start inclusive")
    require(timeline.chord(at: 2) == ChordLabel(name: "C", components: ""), "End exclusive; name held")
    require(timeline.chord(at: 2.75)?.name == "C", "Hold duration inclusive")
    require(timeline.chord(at: 2.75001)?.name == "N.C.", "Hold expiration")
    require(timeline.chord(at: 3.5)?.name == "Am", "Later chord")
    require(timeline.chord(at: 1.5)?.name == "C", "Backward seeking independent of prior query")
    require(timeline.chord(at: .nan) == nil, "Nonfinite query")
    require(ChordAnalyzer.timeline(tracks: [a], selectedIDs: []).chord(at: 1.5) == nil, "No selected sources")
    let split = ChordAnalyzer.timeline(tracks: [track("a", pitches: [60]), track("b", pitches: [64,67])], selectedIDs: ["a","b"])
    require(split.chord(at: 0.5)?.name == "C", "Combine selected tracks")
    let overlapping = MIDITrack(id: "a", name: "a", channel: 0, notes: [
      MIDINote(start: 0, duration: 3, pitch: 60, velocity: 1),
      MIDINote(start: 1, duration: 1, pitch: 60, velocity: 1),
      MIDINote(start: 0, duration: 3, pitch: 64, velocity: 1),
      MIDINote(start: 0, duration: 3, pitch: 67, velocity: 1)
    ], bends: [], modulation: [])
    require(ChordAnalyzer.timeline(tracks: [overlapping], selectedIDs: ["a"]).chord(at: 2.5)?.name == "C", "Overlapping unisons use counts")
    let transition = ChordAnalyzer.timeline(tracks: [track("a", pitches: [60,64,67]), track("a", pitches: [62,65,69], start: 1)], selectedIDs: ["a"])
    require(transition.chord(at: 1)?.name == "Dm", "Simultaneous end/start transition")
    let roots=["C","C♯","D","E♭","E","F","F♯","G","A♭","A","B♭","B"]
    for root in 0..<12 {
      let pitches=[60+root,64+root,67+root]
      let major=ChordAnalyzer.timeline(tracks:[track("a",pitches:pitches)],selectedIDs:["a"]).chord(at:0.5)
      require(major?.name==roots[root],"Major triad transposition")
    }
    for mask in 1..<4096 {
      let pitches=(0..<12).filter{mask & (1 << $0) != 0}.map{60+$0}
      let base=ChordAnalyzer.timeline(tracks:[track("a",pitches:pitches)],selectedIDs:["a"]).chord(at:0.5)
      let octaves=ChordAnalyzer.timeline(tracks:[track("a",pitches:pitches.map{$0+12}+pitches)],selectedIDs:["a"]).chord(at:0.5)
      require(base==octaves,"Octave doubling preserves chord identity")
    }
    print("PASS: \(fixtures.count) musical examples, 12 transpositions, 4095 octave-doubling cases + timeline/source/seek boundaries")
  }
}
