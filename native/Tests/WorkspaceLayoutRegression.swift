import AppKit
import SwiftUI

/// Render only this test's hosting views; no desktop capture or app automation.
@main struct WorkspaceLayoutRegression {
  static func main()throws {
    let app=NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let output=URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "build/tests/workspace-frames")
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    let model=StudioModel()
    model.settings=StudioSettings();model.selectAudioTemplate(.orbit);model.settings.scene = .audio
    model.settings.title="Night Signal";model.settings.artist="LumaScore Sessions";model.settings.genre="Electronic"
    model.settings.metronomeEnabled=true
    let sequence=try MIDIParser.parse(url:URL(fileURLWithPath:"Fixtures/representative-5s.mid"))
    model.tracks=sequence.tracks;model.sourceBPM=sequence.bpm;model.sourceTempoMap=sequence.tempoMap
    model.midiDuration=sequence.duration;model.midiURLs=[URL(fileURLWithPath:"Fixtures/representative-5s.mid")]
    model.audioURL=URL(fileURLWithPath:"Fixtures/representative-5s.wav")
    model.audioVisualization=try AudioAnalyzer.analyze(url:model.audioURL!);model.audioDuration=5;model.time=0.8
    let defaults=UserDefaults(suiteName:"lumascore-workspace-test-\(UUID().uuidString)")!
    for (name,left,right) in [("expanded",false,false),("media-rail",true,false),("collapsed",true,true),("inspector-rail",false,true)] {
      defaults.set(left,forKey:"lumascore.workspace.libraryCollapsed")
      defaults.set(right,forKey:"lumascore.workspace.inspectorCollapsed")
      let root=StudioView().environmentObject(model).defaultAppStorage(defaults)
      let host=NSHostingView(rootView:root)
      let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:760),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
      window.appearance=NSAppearance(named:.darkAqua)
      window.contentView=host
      host.frame=NSRect(x:0,y:0,width:1280,height:760)
      window.layoutIfNeeded();host.layoutSubtreeIfNeeded()
      RunLoop.current.run(until:Date().addingTimeInterval(0.8))
      guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw StudioError.message("Workspace bitmap unavailable")}
      host.cacheDisplay(in:host.bounds,to:bitmap)
      try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+".png"))
      func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap{descendants($0)}}
      let metal=descendants(host).compactMap{$0 as? InteractiveMetalView}.first
      guard let metal=metal,metal.bounds.width>300,metal.bounds.height>200 else {throw StudioError.message("Preview squeezed below usable size in \(name)")}
      guard model.errorMessage==nil else {throw StudioError.message(model.errorMessage!)}
      print("PASS \(name): preview \(Int(metal.bounds.width))×\(Int(metal.bounds.height)), settings remain editable")
      window.orderOut(nil)
      window.contentView=nil
    }
    print("ALL WORKSPACE LAYOUT REGRESSIONS PASSED")
  }
}
