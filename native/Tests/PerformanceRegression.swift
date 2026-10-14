import Foundation
import Combine
import Metal
@main struct PerformanceRegression {
 static func check(_ condition:Bool,_ text:String)throws{if !condition{throw StudioError.message(text)};print("PASS \(text)")}
 static func main()throws {
  let model=StudioModel()
  var configurationChanges=0,clockChanges=0
  let configToken=model.objectWillChange.sink{configurationChanges+=1}
  let clockToken=model.playbackClock.objectWillChange.sink{clockChanges+=1}
  for i in 0..<100 {model.time=Double(i)/10}
  try check(configurationChanges==0 && clockChanges==100,"100 playback ticks notify clock, not whole studio")
  model.settings.volume=0.5
  try check(configurationChanges==1,"Configuration edits still notify studio")
  withExtendedLifetime((configToken,clockToken)){}
  let fixture=CommandLine.arguments.dropFirst().first ?? "Fixtures/representative-5s.wav"
  let audio=try AudioAnalyzer.analyze(url:URL(fileURLWithPath:fixture))
  var reused=[Float]()
  for t in [-1.0,0,0.017,1.2,4.99,5,Double.nan] {
   audio.spectrum(at:t,into:&reused)
   try check(reused==audio.spectrum(at:t),"Reused spectrum matches immutable lookup at \(t)")
  }
  var s=StudioSettings();s.chordEnabled=false;s.chordTrackIDs=["a"]
  let a=MIDITrack(id:"a",name:"a",channel:0,notes:[MIDINote(start:0,duration:1,pitch:60,velocity:1)],bends:[],modulation:[])
  var snapshot=RenderSnapshot(tracks:[a],styles:[:],settings:s,bpm:120,duration:1,minPitch:60,maxPitch:60,backgroundURL:nil)
  let renderer=try MetalSceneRenderer(snapshot:snapshot)
  try check(renderer.chordTimeline==nil,"Disabled chords skip analysis")
  let atlas=renderer.atlas!
  try renderer.update(snapshot,rebuild:true)
  try check(renderer.atlas===atlas,"Track rebuild reuses glyph atlas")
  snapshot.settings.chordEnabled=true
  try renderer.update(snapshot)
  try check(renderer.chordTimeline != nil,"Enabling chords builds timeline")
  let old=renderer.chordTimeline
  snapshot.tracks[0].notes.append(MIDINote(start:0,duration:1,pitch:64,velocity:1))
  snapshot.tracks[0].notes.append(MIDINote(start:0,duration:1,pitch:67,velocity:1))
  try renderer.update(snapshot,rebuild:true)
  try check(renderer.chordTimeline?.chord(at:0.5)?.name=="C","Same-ID notes rebuild updates chord analysis")
  _=old
  var plain=StudioSettings();plain.glow=0;plain.chordEnabled=false
  let plainSnapshot=RenderSnapshot(tracks:[],styles:[:],settings:plain,bpm:120,duration:1,minPitch:48,maxPitch:84,backgroundURL:nil)
  let fast=try MetalSceneRenderer(snapshot:plainSnapshot)
  let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:320,height:180,mipmapped:false)
  descriptor.storageMode = .shared;descriptor.usage = [.renderTarget,.shaderRead]
  let target=fast.device.makeTexture(descriptor:descriptor)!
  func draw(_ renderer:MetalSceneRenderer,fade:Float=1)throws {
    let done=DispatchSemaphore(value:0);var failure:Error?
    try renderer.encode(target:target,time:0,slot:0,fade:fade){error in failure=error;done.signal()}
    try check(done.wait(timeout:.now()+10) == .success && failure == nil,"GPU completes frame")
  }
  try draw(fast)
  try check(fast.intermediates[0] == nil,"Neutral scene skips intermediate texture")
  try draw(fast,fade:0.5)
  try check(fast.intermediates[0] != nil,"Screen fade retains post-processing")
  let effectCases:[(String,(inout StudioSettings)->Void)]=[
    ("CRT",{$0.crtEnabled=true}),("Lens",{$0.fisheye=0.2}),
    ("Bloom",{$0.bloomEnabled=true;$0.glow=0.2}),
    ("Grade",{$0.colorFilterEnabled=true;$0.brightness=0.1}),
    ("Camera punch",{$0.cameraPunch=0.1}),("Camera shake",{$0.cameraShake=0.1})]
  for (name,change) in effectCases {
    var changed=plainSnapshot;change(&changed.settings)
    let effect=try MetalSceneRenderer(snapshot:changed)
    try draw(effect)
    try check(effect.intermediates[0] != nil,"\(name) retains post-processing")
  }
  print("ALL PERFORMANCE REGRESSIONS PASSED")
 }
}
