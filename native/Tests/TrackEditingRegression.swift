import Foundation
import Metal
import AVFoundation
import AppKit

@main struct TrackEditingRegression {
  static func check(_ ok:Bool,_ message:String)throws {guard ok else{throw StudioError.message(message)};print("PASS \(message)")}
  static func near(_ a:Double,_ b:Double)->Bool {abs(a-b)<0.001}
  static func wait(_ model:StudioModel)throws {
    let deadline=Date().addingTimeInterval(20)
    while (model.importing || model.analyzingAudio) && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
    try check(!model.importing && !model.analyzingAudio,"Import completes")
  }
  static func main()throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("lumascore-tracks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer{try? FileManager.default.removeItem(at:root)}
    let a=root.appendingPathComponent("A.mid"),b=root.appendingPathComponent("B.mid")
    let fixture=URL(fileURLWithPath:"Fixtures/representative-5s.mid")
    try FileManager.default.copyItem(at:fixture,to:a);try FileManager.default.copyItem(at:fixture,to:b)
    let model=StudioModel();model.resetProject();model.loadMIDI([a]);try wait(model)
    let first=model.tracks[0].id,count=model.tracks.count
    model.styles[first]?.muted=true;model.styles[first]?.flowSpeed=1.7
    model.settings.chordTrackIDs=[first];model.settings.cameraTrackID=first;model.settings.bpm=155;model.time=1
    model.loadMIDI([b]);try wait(model)
    try check(model.tracks.count==count*2 && model.tracks[0].id==first && model.styles[first]?.muted==true && model.styles[first]?.flowSpeed==1.7,"Second import appends without replacing existing tracks or styles")
    try check(model.settings.bpm==155 && model.settings.chordTrackIDs==[first] && model.settings.cameraTrackID==first && model.time==1,"Append preserves manual BPM, source selections and playhead")
    let bTracks=model.tracks.filter{$0.sourceFile=="B.mid"},deletedB=bTracks[0].id,keptB=bTracks[1].id
    model.styles[keptB]?.flowSpeed=2.4;model.styles[keptB]?.horizontalOffset=0.15;model.styles[keptB]?.verticalOffset = -0.3;model.styles[keptB]?.timeOffset=0.45
    model.deleteTrack(first)
    model.updateTrackStyle(first){$0.solo=true}
    try check(model.styles[first]==nil && model.settings.cameraTrackID.isEmpty && model.settings.chordTrackIDs.isEmpty,"Delete cleans styles, camera and chord source references")
    model.deleteTrack(deletedB)
    for track in model.tracks.filter({$0.sourceFile=="A.mid"}) {model.deleteTrack(track.id)}
    try check(model.midiURLs==[b] && model.tracks.allSatisfy{$0.id.hasPrefix("1:")},"Deleting a source's last track removes its file reference without renumbering other tracks")
    model.tracks.reverse()
    let order=model.tracks.map{$0.id},style=model.styles[keptB]!
    let saved=root.appendingPathComponent("edited.lumascore")
    try JSONEncoder().encode(model.projectFile()).write(to:saved)
    try FileManager.default.removeItem(at:a)
    let reopened=StudioModel();reopened.openProject(saved);try wait(reopened)
    try check(reopened.errorMessage==nil && reopened.tracks.map{$0.id}==order && !reopened.tracks.contains(where:{$0.id==deletedB}),"Project reopen preserves ordering and deleted tracks; removed source files are no longer required")
    try check(reopened.styles[keptB]==style && reopened.settings.bpm==155,"Per-track flow, positions and timing survive project round trip")
    try check(reopened.projectFile().format=="lumascore" && reopened.projectFile().version==1,"Project uses the LumaScore document identifier and schema")
    var invalidDocument=model.projectFile();invalidDocument.format="other-app"
    let invalidURL=root.appendingPathComponent("invalid.lumascore");try JSONEncoder().encode(invalidDocument).write(to:invalidURL)
    let rejected=StudioModel();rejected.openProject(invalidURL);try wait(rejected)
    try check(rejected.errorMessage != nil && rejected.tracks.isEmpty,"Foreign document formats are rejected")
    var missingIdentifier=try JSONSerialization.jsonObject(with:JSONEncoder().encode(model.projectFile())) as! [String:Any]
    missingIdentifier.removeValue(forKey:"format")
    try JSONSerialization.data(withJSONObject:missingIdentifier).write(to:invalidURL)
    rejected.errorMessage=nil;rejected.openProject(invalidURL);try wait(rejected)
    try check(rejected.errorMessage != nil && rejected.tracks.isEmpty,"Documents without a LumaScore identifier are rejected")
    invalidDocument=model.projectFile();invalidDocument.version=99
    try JSONEncoder().encode(invalidDocument).write(to:invalidURL)
    rejected.errorMessage=nil;rejected.openProject(invalidURL);try wait(rejected)
    try check(rejected.errorMessage != nil && rejected.tracks.isEmpty,"Unsupported schema versions are rejected")
    let wrongExtension=root.appendingPathComponent("project.json")
    try JSONEncoder().encode(model.projectFile()).write(to:wrongExtension)
    rejected.errorMessage=nil;rejected.openProject(wrongExtension)
    try check(rejected.errorMessage != nil && rejected.tracks.isEmpty,"Project opening accepts only the LumaScore extension")
    reopened.loadMIDI([b]);try wait(reopened)
    try check(reopened.tracks.count==order.count+count && Set(reopened.tracks.map{$0.id}).count==reopened.tracks.count && reopened.styles[keptB]==style,"Importing the same file again creates independent IDs and retains earlier edits")
    let before=reopened.tracks.map{$0.id}
    let bad=root.appendingPathComponent("broken.mid");try Data([0,1,2]).write(to:bad)
    reopened.loadMIDI([bad]);try wait(reopened)
    try check(reopened.tracks.map{$0.id}==before && reopened.errorMessage != nil,"Invalid appended MIDI leaves the current project intact")
    let minimalStyle=try JSONDecoder().decode(TrackStyle.self,from:Data("{\"color\":{\"r\":0.2,\"g\":0.3,\"b\":0.4}}".utf8))
    try check(minimalStyle.flowSpeed==1 && minimalStyle.horizontalOffset==0 && minimalStyle.verticalOffset==0 && minimalStyle.timeOffset==0,"Omitted optional style fields use neutral transforms")
    var invalid=minimalStyle;invalid.flowSpeed=0
    do {try invalid.validate();throw StudioError.message("Invalid flow accepted")}catch {try check((try? invalid.validate())==nil,"Invalid track flow is rejected")}

    var settings=StudioSettings();settings.grid=false;settings.titleEnabled=false;settings.playheadVisible=false;settings.marker = .none;settings.rippleStyle = .none;settings.particles=0;settings.depth=0;settings.window=4;settings.glow=0
    let note=MIDINote(start:4,duration:1,pitch:60,velocity:1)
    let one=MIDITrack(id:"one",name:"One",channel:0,notes:[note],bends:[],modulation:[],endTime:5)
    let two=MIDITrack(id:"two",name:"Two",channel:1,notes:[note],bends:[],modulation:[],endTime:5)
    var aStyle=TrackStyle(color:RGB.palette[0]),bStyle=TrackStyle(color:RGB.palette[1]);bStyle.flowSpeed=2;bStyle.horizontalOffset=0.1;bStyle.verticalOffset=0.2
    var snapshot=RenderSnapshot(tracks:[one,two],styles:["one":aStyle,"two":bStyle],settings:settings,bpm:120,duration:5,minPitch:60,maxPitch:60,backgroundURL:nil)
    let renderer=try MetalSceneRenderer(snapshot:snapshot)
    renderer.build(time:2.5,width:1280,height:720)
    let aBar=renderer.instances.first{$0.color.x==aStyle.color.r}!,bBar=renderer.instances.first{$0.color.x==bStyle.color.r}!
    let camera=SceneViewport(snapshot:snapshot,width:1280,height:720)
    try check(near(Double(aBar.rect.x-aBar.rect.z/2),camera.playheadX+1.5*camera.pixelsPerSecond) && near(Double(bBar.rect.x-bBar.rect.z/2),camera.playheadX+128+1.5*camera.pixelsPerSecond*2),"Each track receives independent flow and horizontal positioning")
    try check(near(Double(bBar.rect.y-aBar.rect.y),72) && snapshot.tracks[1].notes[0].pitch==60,"Vertical position moves the drawing while preserving MIDI pitch")
    snapshot.tracks=[MIDITrack(id:"one",name:"Slow",channel:0,notes:[MIDINote(start:10,duration:1,pitch:60,velocity:1)],bends:[],modulation:[],endTime:11)]
    snapshot.duration=11;snapshot.styles["one"]?.flowSpeed=0.25
    try renderer.update(snapshot,rebuild:true);renderer.build(time:0,width:1280,height:720)
    try check(renderer.instances.contains{$0.color.x==aStyle.color.r},"Slow flow expands visibility lookup so distant visible notes are not culled")
    snapshot.tracks=[MIDITrack(id:"one",name:"Harmony",channel:0,notes:[57,60,64,67,71].map{MIDINote(start:0,duration:0.4,pitch:$0,velocity:1)},bends:[],modulation:[],endTime:0.4)]
    snapshot.duration=0.4;snapshot.settings.intro=2;snapshot.settings.bpm=240;snapshot.settings.cameraPunch=0.2;snapshot.settings.cameraTrackID="one";snapshot.settings.chordEnabled=true;snapshot.settings.chordTrackIDs=["one"]
    aStyle.timeOffset=1;snapshot.styles=["one":aStyle]
    try renderer.update(snapshot,rebuild:true)
    try check(near(snapshot.trackTime("one",at:3.1),0.2) && near(snapshot.timelineDuration(audioDuration:0),3.2),"Per-track timing uses real seconds and extends the export timeline")
    try check(renderer.cameraReaction(time:2.9).z==0 && renderer.cameraReaction(time:3.1).z>0,"Camera reaction follows delayed track triggers")
    let sourceTime=(3.1-snapshot.settings.intro)/snapshot.tempoScale
    try check(renderer.chordTimeline?.chord(at:sourceTime)?.name=="Am9","Chord analysis follows delayed track timing with original note pitches")
    snapshot.styles["one"]?.timeOffset=2;try renderer.update(snapshot)
    try check(renderer.chordTimeline?.chord(at:sourceTime)?.name=="N.C.","Editing a track delay invalidates cached chord timing")
    let texture=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:640,height:360,mipmapped:false);texture.storageMode = .shared;texture.usage = [.renderTarget,.shaderRead]
    let target=renderer.device.makeTexture(descriptor:texture)!,done=DispatchSemaphore(value:0);var failure:Error?
    try renderer.encode(target:target,time:4.1,slot:0){failure=$0;done.signal()}
    try check(done.wait(timeout:.now()+10) == .success && failure==nil,"Modified track renders through the preview/export GPU pipeline")
    snapshot.settings.resolution=480;snapshot.settings.aspect = .portrait;snapshot.settings.fps=30;snapshot.settings.exportEnd=4.5;snapshot.settings.crtEnabled=true;snapshot.settings.fisheye=0.3;snapshot.settings.glow=0.2
    snapshot.styles["one"]?.flowSpeed=1.5;snapshot.styles["one"]?.horizontalOffset=0.1;snapshot.styles["one"]?.verticalOffset=0.1
    let audio=URL(fileURLWithPath:"Fixtures/representative-5s.wav")
    snapshot.audioVisualization=try AudioAnalyzer.analyze(url:audio)
    let movie=URL(fileURLWithPath:"build/tests/track-edit.mp4"),exportDone=DispatchSemaphore(value:0)
    try? FileManager.default.removeItem(at:movie)
    var result:Result<ExportStatistics,Error>?
    let operation=ExportOperation(snapshot:snapshot,audioURL:audio,destination:movie,progress:{_ in},completion:{result=$0;exportDone.signal()})
    operation.startExport()
    try check(exportDone.wait(timeout:.now()+30) == .success,"Portrait track export completes")
    let stats=try result!.get(),asset=AVURLAsset(url:movie)
    let video=asset.tracks(withMediaType:.video).first!
    let reader=try AVAssetReader(asset:asset),encoded=AVAssetReaderTrackOutput(track:video,outputSettings:nil)
    reader.add(encoded);try check(reader.startReading(),"Exported portrait MP4 opens")
    var frames=0;while let sample=encoded.copyNextSampleBuffer(){frames+=CMSampleBufferGetNumSamples(sample)}
    try check(frames==135 && stats.width==480 && stats.height==854 && stats.audioIncluded && !asset.tracks(withMediaType:.audio).isEmpty,"Track layout exports 135 portrait frames with delayed audio")
    let generator=AVAssetImageGenerator(asset:asset);generator.appliesPreferredTrackTransform=true
    let image=try generator.copyCGImage(at:CMTime(seconds:4.1,preferredTimescale:600),actualTime:nil)
    try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"build/tests/track-edit.png"))
    reopened.loadAudio(URL(fileURLWithPath:"Fixtures/representative-5s.wav"));reopened.resetProject()
    RunLoop.current.run(until:Date().addingTimeInterval(1))
    try check(reopened.tracks.isEmpty && reopened.midiURLs.isEmpty && reopened.audioURL==nil && reopened.audioVisualization==nil && reopened.backgroundURL==nil && reopened.coverURL==nil && reopened.settings==StudioSettings() && reopened.time==0 && !reopened.playing,"Whole-project reset clears media and effects; pending audio cannot repopulate it")
    reopened.loadMIDI([b]);reopened.resetProject();RunLoop.current.run(until:Date().addingTimeInterval(0.5))
    try check(reopened.tracks.isEmpty && !reopened.importing,"Whole-project reset invalidates pending MIDI imports")
    reopened.updateTrackStyle(keptB){$0.timeOffset=3}
    try check(reopened.styles.isEmpty,"Stale editor callbacks cannot recreate deleted or reset track styles")
    print("ALL TRACK EDITING REGRESSIONS PASSED")
  }
}
