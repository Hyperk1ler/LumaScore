import Foundation
import AppKit
import Metal

@main struct AudioTemplateRegression {
  static func check(_ ok:Bool,_ message:String)throws {
    guard ok else {throw StudioError.message(message)}
    print("PASS \(message)")
  }
  static func near(_ a:Double,_ b:Double)->Bool {abs(a-b)<0.00001}
  static func main()throws {
    let output=URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "build/tests/scenes")
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    let defaults=try JSONDecoder().decode(StudioSettings.self,from:Data("{}".utf8))
    try check(defaults.audioTemplate == .orbit && !defaults.metronomeEnabled,"Empty settings document uses default template with metronome disabled")
    let model=StudioModel()
    let saved=UserDefaults.standard.data(forKey:"lumascore.settings.v1")
    defer {if let saved=saved{UserDefaults.standard.set(saved,forKey:"lumascore.settings.v1")}else{UserDefaults.standard.removeObject(forKey:"lumascore.settings.v1")}}
    model.settings=StudioSettings();model.settings.title="Night Signal";model.settings.titleFont="Helvetica"
    model.settings.chordEnabled=true;model.settings.metronomeEnabled=true;model.settings.intro=3
    for template in AudioTemplate.allCases {
      model.selectAudioTemplate(template)
      try check(model.settings.title == "Night Signal" && model.settings.titleFont == "Helvetica" && model.settings.chordEnabled && model.settings.metronomeEnabled && model.settings.intro==3,"\(template.rawValue) preserves content, typography and media timing")
      let restored=try JSONDecoder().decode(StudioSettings.self,from:JSONEncoder().encode(model.settings))
      try check(restored == model.settings,"\(template.rawValue) round trips project settings")
      for aspect in Aspect.allCases {
        var s=model.settings;s.aspect=aspect
        let (w,h)=s.dimensions, layout=AudioSceneLayout(settings:s,width:Float(w),height:Float(h))
        let canvas=CGRect(x:0,y:0,width:w,height:h)
        try check(canvas.contains(layout.cover) && canvas.contains(layout.spectrum) && layout.noteY<Float(h),"\(template.rawValue) \(aspect.rawValue) cover and spectrum remain within video canvas")
      }
    }
    var s=StudioSettings();s.scene = .audio;s.audioTemplate = .recordSleeve
    let sleeve=AudioSceneLayout(settings:s,width:1280,height:720)
    try check(abs((Float(sleeve.cover.minY)+Float(sleeve.cover.maxY)+93)/2-360)<0.001 && abs((sleeve.seriesY-6.5+sleeve.noteY+6)/2-360)<0.001,"Sleeve preserves original 380px cover and centers both content groups")
    let payload:[UInt8]=[0,255,81,3,7,161,32,0,144,60,100,131,96,255,81,3,15,66,64,131,96,128,60,0,0,255,47,0]
    let bytes:[UInt8]=[77,84,104,100,0,0,0,6,0,0,0,1,1,224,77,84,114,107,0,0,0,UInt8(payload.count)]+payload
    let midi=output.appendingPathComponent("variable-tempo.mid");try Data(bytes).write(to:midi)
    let sequence=try MIDIParser.parse(url:midi)
    try check(sequence.tempoMap.count==2 && near(sequence.tempoMap[1].time,0.5) && near(sequence.tempoMap[1].beat,1) && near(sequence.tempoMap[1].bpm,60),"Parser exposes beat-continuous variable tempo map")
    s.intro=3;s.metronomeEnabled=true
    var snap=RenderSnapshot(tracks:sequence.tracks,styles:[:],settings:s,bpm:sequence.bpm,duration:sequence.duration,minPitch:60,maxPitch:60,backgroundURL:nil,tempoMap:sequence.tempoMap)
    try check(snap.musicalBeat(at:2.99)==nil && near(snap.metronomePosition(at:2.99),0.5),"Lead-in renders with metronome idle at center")
    try check(near(snap.metronomePosition(at:3),0.07) && near(snap.metronomePosition(at:3.5),0.93) && near(snap.metronomePosition(at:4.5),0.07),"Cursor reaches alternate endpoints each MIDI beat, including tempo change")
    try check(near(snap.musicalBeat(at:3.5-0.000001)!,snap.musicalBeat(at:3.5+0.000001)!),"Tempo boundary has no phase jump")
    snap.settings.bpm=240
    try check(near(snap.musicalBPM(at:3)!,240) && near(snap.musicalBPM(at:3.3)!,120) && near(snap.musicalBeat(at:3.75)!,2),"Manual BPM scales tempo map and beat timing together")
    snap.settings.bpm=0;snap.settings.offset = -1
    try check(snap.musicalBeat(at:3.5)==nil && near(snap.metronomePosition(at:4),0.07),"Negative MIDI offset delays metronome phase")
    var audioOnly=snap;audioOnly.tracks=[];audioOnly.settings.bpm=90
    try check(near(audioOnly.musicalBeat(at:4)!,1.5) && near(audioOnly.musicalBPM(at:4)!,90),"Audio-only beat follows manual BPM and ignores stale MIDI offset and tempo map")
    let audio=try AudioAnalyzer.analyze(url:URL(fileURLWithPath:"Fixtures/representative-5s.wav"))
    snap.settings=model.settings;snap.settings.scene = .audio;snap.settings.intro=0;snap.audioVisualization=audio;snap.audioName="Night Signal";snap.settings.artist="LumaScore Sessions";snap.settings.genre="Electronic"
    snap.tracks[0].notes=[57,60,64,67,71].map{MIDINote(start:0,duration:1.5,pitch:$0,velocity:0.8)}
    model.settings.chordTrackIDs=snap.tracks.map{$0.id}
    let renderer=try MetalSceneRenderer(snapshot:snap)
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:1280,height:720,mipmapped:false)
    descriptor.storageMode = .shared;descriptor.usage = [.renderTarget,.shaderRead]
    let target=renderer.device.makeTexture(descriptor:descriptor)!
    func draw(_ name:String)throws {
      let done=DispatchSemaphore(value:0);var error:Error?
      try renderer.encode(target:target,time:0.8,slot:0){e in error=e;done.signal()}
      try check(done.wait(timeout:.now()+10) == .success && error==nil,"\(name) GPU frame completes")
      var pixels=[UInt8](repeating:0,count:1280*720*4)
      target.getBytes(&pixels,bytesPerRow:1280*4,from:MTLRegionMake2D(0,0,1280,720),mipmapLevel:0)
      let provider=CGDataProvider(data:Data(pixels) as CFData)!
      let image=CGImage(width:1280,height:720,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:1280*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
      try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+".png"))
    }
    for template in AudioTemplate.allCases {
      model.selectAudioTemplate(template);snap.settings=model.settings;snap.settings.scene = .audio;snap.settings.intro=0
      snap.settings.metronomeEnabled=false;try renderer.update(snap);try draw(template.rawValue)
      let without=renderer.instances.count
      snap.settings.metronomeEnabled=true;try renderer.update(snap);try draw(template.rawValue+"-beat")
      try check(renderer.instances.count==without+11,"\(template.rawValue) metronome is an independent optional overlay")
      snap.settings.crtEnabled=true;snap.settings.fisheye=0.4;snap.settings.spectrumDepth=0.3;snap.settings.spectrumTilt=25
      try renderer.update(snap);try draw(template.rawValue+"-effects")
    }
    print("ALL AUDIO TEMPLATE REGRESSIONS PASSED")
  }
}
