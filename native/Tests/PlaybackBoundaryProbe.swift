import Foundation
import AVFoundation

@main struct PlaybackBoundaryProbe {
  static func main() throws {
    let output = CommandLine.arguments[1]
    let audio = CommandLine.arguments.contains("--audio")
    let intro = 2.2
    let fixtureIndex=CommandLine.arguments.firstIndex(of:"--fixture")
    let fixture=fixtureIndex.map{CommandLine.arguments[$0+1]} ?? "Fixtures/representative-5s.wav"
    var trials = [[String: Any]]()
    for trial in 0..<3 {
      let model = StudioModel()
      model.settings = StudioSettings()
      model.settings.volume = 0
      model.settings.intro = intro
      model.midiDuration = 5
      model.tracks = [MIDITrack(id:"probe",name:"Probe",channel:0,
        notes:[MIDINote(start:0.15,duration:1,pitch:60,velocity:1)],bends:[],modulation:[])]
      if audio {
        model.loadAudio(URL(fileURLWithPath:fixture))
        let deadline = Date().addingTimeInterval(15)
        while model.analyzingAudio && Date()<deadline {
          RunLoop.current.run(until:Date().addingTimeInterval(0.002))
        }
        guard model.audioURL != nil else {throw StudioError.message(model.errorMessage ?? "Audio import failed")}
      }
      model.play()
      let origin = ProcessInfo.processInfo.systemUptime
      // Read-only inspection of the private player for this diagnostic harness.
      let wrappedPlayer=Mirror(reflecting:model).children.first{$0.label == "player"}?.value
      let player=wrappedPlayer.flatMap{Mirror(reflecting:$0).children.first?.value as? AVPlayer}
      if audio && player == nil {throw StudioError.message("Diagnostic player not found")}
      var samples = [[String:Double]]()
      var next = 0.0
      while ProcessInfo.processInfo.systemUptime-origin < intro+0.7 {
        let wall = ProcessInfo.processInfo.systemUptime-origin
        if wall >= next {
          var sample=["wall":wall,"timeline":model.currentTime]
          if let player=player {
            let position=player.currentTime().seconds
            if position.isFinite {sample["audioTime"]=position}
            sample["audioRate"]=Double(player.rate)
          }
          samples.append(sample)
          next += 1.0/120
        }
        RunLoop.current.run(until:Date().addingTimeInterval(0.001))
      }
      model.pause()
      let boundary = samples.filter{abs($0["wall"]!-intro)<0.5}
      var longestPlateau = 0.0, plateauStart: Double?, backwards = 0.0
      for i in 1..<boundary.count {
        let a=boundary[i-1],b=boundary[i]
        let delta=b["timeline"]!-a["timeline"]!
        backwards=max(backwards,-delta)
        if abs(delta)<0.0005 {
          if plateauStart == nil {plateauStart=a["wall"]!}
          longestPlateau=max(longestPlateau,b["wall"]!-plateauStart!)
        } else {plateauStart=nil}
      }
      let lag=boundary.map{$0["wall"]!-$0["timeline"]!}.max() ?? 0
      let audioSamples=samples.filter{$0["wall"]! > intro+0.1 && ($0["audioTime"] ?? 0)>0.01}
      let audioSkew=audioSamples.map{abs($0["timeline"]!-intro-$0["audioTime"]!)}.max() ?? 0
      let audioOnset=samples.first{($0["audioTime"] ?? 0)>0.001}?["wall"] ?? -1
      if CommandLine.arguments.contains("--verify") {
        guard longestPlateau < 0.016, backwards < 0.001, lag < 0.025 else {
          throw StudioError.message("Timeline stalled or jumped at media onset")
        }
        if audio {
          guard audioOnset >= intro-0.01 && audioOnset < intro+0.05,
            audioSamples.count > 30, audioSkew < 0.03 else {
            throw StudioError.message("Audio was not synchronized with media onset")
          }
        }
      }
      trials.append(["trial":trial,"maxPlateauMS":longestPlateau*1000,
        "maxBackwardMS":backwards*1000,"maxTimelineLagMS":lag*1000,
        "maxAudioSkewMS":audioSkew*1000,"audioOnsetWall":audioOnset,"samples":samples])
      print("trial \(trial) audio=\(audio) plateau=\(longestPlateau*1000)ms backwards=\(backwards*1000)ms lag=\(lag*1000)ms audioSkew=\(audioSkew*1000)ms onset=\(audioOnset)", terminator:"\n")
    }
    let result:[String:Any]=["intro":intro,"audio":audio,"trials":trials]
    try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output))
  }
}
