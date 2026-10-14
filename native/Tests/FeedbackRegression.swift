import Foundation
@main struct FeedbackRegression {
 static func check(_ ok:Bool,_ message:String)throws{if !ok{throw StudioError.message(message)};print("PASS \(message)")}
 static func wait(_ model:StudioModel)throws{let limit=Date().addingTimeInterval(20);while model.importing && Date()<limit{RunLoop.current.run(until:Date().addingTimeInterval(0.01))};try check(!model.importing,"Import finished")}
 static func main()throws {
  let root=FileManager.default.temporaryDirectory.appendingPathComponent("lumascore-feedback-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:root)}
  let midi=root.appendingPathComponent("Automatic tempo.mid")
  let tempo=434783
  let payload:[UInt8]=[0,255,3,3,32,0,32,0,255,81,3,UInt8(tempo>>16),UInt8((tempo>>8)&255),UInt8(tempo&255),0,144,60,100,131,96,128,60,0,0,255,47,0]
  let bytes:[UInt8]=[77,84,104,100,0,0,0,6,0,0,0,1,1,224,77,84,114,107,0,0,0,UInt8(payload.count)]+payload
  try Data(bytes).write(to:midi)
  let model=StudioModel();model.settings=StudioSettings();model.settings.bpm=99
  model.loadMIDI([midi]);try wait(model)
  try check(abs(model.effectiveBPM-138)<0.001 && model.settings.bpm==0 && model.snapshot.tempoScale==1,"MIDI import reads tempo and resets stale manual BPM without retiming notes")
  try check(!model.tracks[0].displayName.isEmpty && model.tracks[0].sourceLabel==midi.lastPathComponent && model.tracks[0].menuLabel.contains(midi.lastPathComponent),"Empty/control track names have visible labels with source filename")
  model.settings.exportStart=2;model.previewEntrance();try check(model.time==0 && model.playing,"Entrance preview starts at zero even with a later export locator");model.pause()
  var saved=StudioSettings();saved.bpm=165;saved.intro=1.2;saved.spectrumDepth=0.6;saved.spectrumTilt=55;saved.spectrumInFront=true
  let project=ProjectFile(audio:nil,midi:[midi.path],background:nil,settings:saved,styles:[:])
  let url=root.appendingPathComponent("tempo.lumascore");try JSONEncoder().encode(project).write(to:url);model.openProject(url);try wait(model)
  try check(model.settings.bpm==165 && model.effectiveBPM==165,"Opening saved project preserves intentional BPM override")
  let roundtrip=try JSONDecoder().decode(StudioSettings.self,from:JSONEncoder().encode(saved))
  try check(roundtrip.spectrumDepth==0.6 && roundtrip.spectrumTilt==55 && roundtrip.spectrumInFront,"Spectrum depth and tilt survive project serialization")
  saved.titleMotion = .fade;saved.titleMotionDuration=1
  try check(abs(TitleEntrance.state(settings:saved,time:0.6,text:"Title").alpha-0.6)<0.001,"Title animates during media lead-in")
  try check(abs(TitleEntrance.state(settings:saved,time:1.7,text:"Title").alpha-1)<0.001,"Title is visible before delayed music starts")
  try check(CanvasShortcutRouter.action(keyCode:49,characters:" ",editing:false,modified:false) == .play,"Space plays canvas")
  try check(CanvasShortcutRouter.action(keyCode:36,characters:"\r",editing:false,modified:false) == .beginning,"Return seeks to beginning")
  try check(CanvasShortcutRouter.action(keyCode:49,characters:" ",editing:true,modified:false) == nil,"Typing spaces in text fields never plays")
  try check(CanvasShortcutRouter.action(keyCode:36,characters:"\r",editing:true,modified:false) == nil,"Return in numeric editor stays with editor")
  try check(CanvasShortcutRouter.action(keyCode:1,characters:"s",editing:false,modified:true) == nil,"Command-S remains available for menu save")
  print("ALL FEEDBACK REGRESSIONS PASSED")
 }
}
