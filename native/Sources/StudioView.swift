import MetalKit
import SwiftUI
import UniformTypeIdentifiers

private let accent = Color(red: 0.40, green: 0.62, blue: 1.0)

struct NumberEditor: View {
  @Binding var value: Double
  var range: ClosedRange<Double> = -86400...86400
  var label = "数值"
  @State private var draft: String
  @FocusState private var focused: Bool
  init(value: Binding<Double>, range: ClosedRange<Double> = -86400...86400, label: String = "数值") {
    _value = value
    self.range = range
    self.label = label
    _draft = State(initialValue: NumberInput.format(value.wrappedValue))
  }
  var body: some View {
    TextField(label, text: $draft).textFieldStyle(.roundedBorder).focused($focused)
      .monospacedDigit().accessibilityLabel(label)
      .onChange(of: draft) { text in
        if focused, let parsed = NumberInput.parse(text, range: range) { value = parsed }
      }
      .onChange(of: value) { newValue in if !focused { draft = NumberInput.format(newValue) } }
      .onChange(of: focused) { isFocused in if !isFocused { commit() } }
      .onSubmit { commit();focused=false;NSApp.keyWindow?.makeFirstResponder(nil) }
      .onExitCommand { draft=NumberInput.format(value);focused=false;NSApp.keyWindow?.makeFirstResponder(nil) }
  }
  private func commit() {
    if let parsed = NumberInput.parse(draft, range: range) { value = parsed }
    draft = NumberInput.format(value)
  }
}

private final class CompactColorWell: NSColorWell {
  override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 24) }
}
struct TrackColorWell: NSViewRepresentable {
  @Binding var color: NSColor
  var label: String
  class Coordinator: NSObject {
    var parent: TrackColorWell
    init(_ parent: TrackColorWell) { self.parent = parent }
    @objc func changed(_ sender: NSColorWell) { parent.color = sender.color }
  }
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSColorWell {
    let well = CompactColorWell(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    well.colorWellStyle = .minimal
    well.isBordered = false
    well.target = context.coordinator
    well.action = #selector(Coordinator.changed(_:))
    well.setContentHuggingPriority(.required, for: .horizontal)
    well.setContentCompressionResistancePriority(.required, for: .horizontal)
    well.setAccessibilityLabel(label)
    well.toolTip = label
    return well
  }
  func updateNSView(_ view: NSColorWell, context: Context) {
    context.coordinator.parent = self
    view.color = color
    view.setAccessibilityLabel(label)
  }
}

final class InteractiveMetalView: MTKView {
  var onPan: ((Double, Double) -> Void)?
  var onZoom: ((Double, Bool) -> Void)?
  var onReset: (() -> Void)?
  private var dragPoint: NSPoint?
  override var acceptsFirstResponder: Bool { true }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    if event.clickCount == 2 {
      onReset?()
      dragPoint = nil
      return
    }
    dragPoint = convert(event.locationInWindow, from: nil)
  }
  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if let previous = dragPoint {
      onPan?(Double(point.x - previous.x), Double(point.y - previous.y))
    }
    dragPoint = point
  }
  override func mouseUp(with event: NSEvent) { dragPoint = nil }
  override func scrollWheel(with event: NSEvent) {
    let multiplier = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
    let dx = Double(event.scrollingDeltaX) * multiplier
    let dy = Double(event.scrollingDeltaY) * multiplier
    if event.modifierFlags.contains(.command) {
      onZoom?(dy, false)
    } else if event.modifierFlags.contains(.option) {
      onZoom?(dy, true)
    } else if event.modifierFlags.contains(.shift) {
      onPan?(abs(dx) > abs(dy) ? dx : dy, 0)
    } else {
      onPan?(dx, dy)
    }
  }
}

struct MetalPreview: NSViewRepresentable {
  @ObservedObject var model: StudioModel
  @ObservedObject var clock:PlaybackClock
  init(model:StudioModel){self.model=model;self.clock=model.playbackClock}
  class Coordinator: NSObject, MTKViewDelegate {
    weak var model: StudioModel?
    var renderer: MetalSceneRenderer?
    var revision = -1
    var slot = 0
    let semaphore = DispatchSemaphore(value: 3)
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
      guard let model = model, let renderer = renderer, let drawable = view.currentDrawable,
        semaphore.wait(timeout: .now()) == .success
      else { return }
      let index = slot
      slot = (slot + 1) % 3
      do {
        try renderer.encode(
          target: drawable.texture, time: model.currentTime, slot: index, drawable: drawable
        ) { [semaphore] _ in semaphore.signal() }
      } catch {
        semaphore.signal()
        DispatchQueue.main.async { model.errorMessage = error.localizedDescription }
      }
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> MTKView {
    let view = InteractiveMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
    view.colorPixelFormat = .bgra8Unorm
    view.framebufferOnly = true
    view.clearColor = MTLClearColorMake(0.02, 0.03, 0.05, 1)
    view.preferredFramesPerSecond = 60
    view.enableSetNeedsDisplay = true
    view.isPaused = true
    view.delegate = context.coordinator
    context.coordinator.model = model
    view.onPan = { [weak view, weak model] dx, dy in
      guard let view = view, let model = model, model.exportProgress == nil else { return }
      let camera = SceneViewport(
        snapshot: model.snapshot, width: Double(max(1, view.bounds.width)),
        height: Double(max(1, view.bounds.height)))
      model.panViewport(horizontal: dx / camera.width, pitch: -dy / camera.pixelsPerPitch)
    }
    view.onZoom = { [weak model] delta, vertical in
      guard let model = model, model.exportProgress == nil else { return }
      model.zoomViewport(factor: exp(delta * 0.008), vertical: vertical)
    }
    view.onReset = { [weak model] in if model?.exportProgress == nil { model?.resetViewport() } }
    return view
  }
  func updateNSView(_ view: MTKView, context: Context) {
    let c = context.coordinator
    c.model = model
    do {
      if c.renderer == nil {
        c.renderer = try MetalSceneRenderer(snapshot: model.snapshot)
      } else {
        try c.renderer?.update(model.snapshot, rebuild: c.revision != model.revision)
      }
      c.revision = model.revision
      view.isPaused = !model.playing
      view.enableSetNeedsDisplay = !model.playing
      if !model.playing { view.setNeedsDisplay(view.bounds) }
    } catch {
      if model.errorMessage == nil {
        DispatchQueue.main.async { model.errorMessage = error.localizedDescription }
      }
    }
  }
}

struct StudioView: View {
  @EnvironmentObject var model:StudioModel
  @ObservedObject var library=PresetLibrary.shared
  @AppStorage("lumascore.inspector") var inspector=0
  @AppStorage("lumascore.workspace.libraryCollapsed") var libraryCollapsed=false
  @AppStorage("lumascore.workspace.inspectorCollapsed") var inspectorCollapsed=false
  @State var selectedTrack:String?
  @State var dropping=false
  @State var expanded=false
  @State var presetName=""
  @State var draggedTrack:String?
  @State var libraryPopover=false
  @State var inspectorPopover=false
  @State var resetConfirmation=false
  var leftCollapsed:Bool { expanded || libraryCollapsed }
  var rightCollapsed:Bool { expanded || inspectorCollapsed }
  var busy:Bool { model.exportProgress != nil || model.importing || model.analyzingAudio }
  var body:some View {
    VStack(spacing:0) {
      HStack(spacing:0) {
        if leftCollapsed { mediaRail.frame(width:56) }
        else { libraryPanel.frame(width:220) }
        Divider()
        VStack(spacing:0) {
          HStack {
            Text(model.settings.scene == .audio ? model.settings.audioTemplate.label:sceneLabel(model.settings.scene)).font(.system(size:12,weight:.semibold))
            Spacer()
            Text("\(model.settings.dimensions.0) × \(model.settings.dimensions.1)").font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
            Button { expanded.toggle() } label: { Image(systemName:expanded ? "arrow.down.right.and.arrow.up.left":"arrow.up.left.and.arrow.down.right") }.help("最大化 / Maximize (F)")
          }.padding(16)
          ZStack {
            Color.black
            MetalPreview(model:model).aspectRatio(model.settings.aspect.ratio,contentMode:.fit)
            if model.tracks.isEmpty && model.audioURL == nil {
              VStack(spacing:14) {
                Image(systemName:"waveform.path").font(.system(size:44,weight:.ultraLight)).foregroundStyle(accent)
                Text("从声音开始 / Start with sound").font(.system(size:24,weight:.light))
                Text("音频频谱 · MIDI 动画 · 混合场景\nAudio spectrum · MIDI motion · Hybrid canvas").font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                HStack { Button("音频 / Audio"){model.chooseAudio()};Button("MIDI"){model.chooseMIDI()} }.buttonStyle(.bordered)
              }.padding(32).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:16))
            }
          }.onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }.frame(maxWidth:.infinity,maxHeight:.infinity).padding(.horizontal,16).padding(.bottom,16)
          TimelineRefresh(clock:model.playbackClock){transport}
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
        Divider()
        if rightCollapsed { inspectorRail.frame(width:84) }
        else { inspectorPanel.frame(width:300) }
      }
      Divider()
      HStack {
        Circle().fill(busy ? Color.orange:accent).frame(width:5,height:5)
        Text(model.status).lineLimit(1)
        if let progress=model.exportProgress {
          ProgressView(value:progress).frame(width:80)
          Button("取消 / Cancel"){model.cancelExport()}.buttonStyle(.borderless)
        }
        Spacer()
        Text("\(model.tracks.count) TRACKS · \(model.noteCount) NOTES · METAL").font(.system(size:9,design:.monospaced))
      }.font(.system(size:10)).foregroundStyle(.secondary).padding(.horizontal,18).padding(.vertical,8)
    }.frame(minWidth:1000,minHeight:700).background(Color(nsColor:.windowBackgroundColor)).preferredColorScheme(.dark).tint(accent)
      .toolbar { nativeToolbar }
      .background(WindowChrome().frame(width:0,height:0))
      .onAppear{if selectedTrack==nil {selectedTrack=model.tracks.first?.id}}
      .onChange(of:model.tracks.map{$0.id}) {ids in
        if selectedTrack == nil || !ids.contains(selectedTrack!) {selectedTrack=ids.first}
      }
      .confirmationDialog("重置当前项目？ / Reset current project?",isPresented:$resetConfirmation,titleVisibility:.visible) {
        Button("清空媒体并重置设置 / Reset workspace",role:.destructive){
          model.resetProject();selectedTrack=nil;inspector=0;presetName="";libraryPopover=false;inspectorPopover=false
        }
        Button("取消 / Cancel",role:.cancel){}
      } message:{Text("清空 MIDI、音频、封面与背景，并恢复默认视觉设置。已保存的项目文件和预设保留。 / Clear media and restore default visuals; saved projects and presets remain available.")}
      .onDrop(of:[UTType.fileURL],isTargeted:$dropping) { providers in
        guard !busy else{return false}
        let group=DispatchGroup(),lock=NSLock();var urls:[URL]=[]
        for provider in providers { group.enter();provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil) { item,_ in
          defer{group.leave()};if let data=item as? Data,let url=URL(dataRepresentation:data,relativeTo:nil){lock.lock();urls.append(url);lock.unlock()}
        }}
        group.notify(queue:.main){model.acceptDrop(urls)};return true
      }
      .overlay { if dropping { RoundedRectangle(cornerRadius:10).stroke(accent,lineWidth:2).padding(5).allowsHitTesting(false) } }
      .alert("操作未完成 / Action incomplete",isPresented:Binding(get:{model.errorMessage != nil},set:{if !$0{model.errorMessage=nil}})) { Button("好 / OK"){model.errorMessage=nil} } message:{Text(model.errorMessage ?? "")}
      .background(shortcuts)

  }
  @ToolbarContentBuilder var nativeToolbar:some ToolbarContent {
    separateToolbarItem("library",placement:.navigation){toolbarButton("sidebar.left","媒体库 / Toggle library",action:toggleLibrary)}
    separateToolbarItem("brand",placement:.navigation){Text("LumaScore").font(.system(size:14,weight:.semibold,design:.rounded)).foregroundStyle(.secondary)}
    ToolbarItem(placement:.principal) {
      Picker("场景 / Scene",selection:$model.settings.scene) { ForEach(SceneKind.allCases,id:\.self){Text(sceneLabel($0)).tag($0)} }.pickerStyle(.segmented).labelsHidden().frame(width:300).disabled(busy)
    }
    separateToolbarItem("presets") {
      ZStack {
        toolbarGlyph("square.stack").allowsHitTesting(false)
        Menu {
          ForEach(library.builtins){preset in Button("\(preset.labelZH) / \(preset.label)"){model.applyPreset(preset.key)}}
          Divider()
          ForEach(library.customPresets){preset in Button(preset.name){model.applyPreset(preset.key)}}
        } label:{Image(systemName:"square.stack").font(.system(size:14)).frame(width:32,height:32)}.menuStyle(.borderlessButton).menuIndicator(.hidden).help("预设 / Presets").accessibilityLabel("预设 / Presets")
      }.frame(width:32,height:32).disabled(busy)
    }
    separateToolbarItem("open"){toolbarButton("folder","打开项目 / Open project",action:model.chooseProject).disabled(busy)}
    separateToolbarItem("save"){toolbarButton("square.and.arrow.down","保存项目 / Save project",action:model.saveProject).disabled(busy)}
    separateToolbarItem("reset"){toolbarButton("arrow.counterclockwise","清空项目 / Reset project"){resetConfirmation=true}.disabled(model.exportProgress != nil)}
    separateToolbarItem("export"){toolbarButton("arrow.up.right.square","导出 / Export",action:model.export).disabled(busy || (model.tracks.isEmpty && model.audioURL == nil))}
    separateToolbarItem("inspector"){toolbarButton("sidebar.right","检查器 / Toggle inspector",action:toggleInspector)}
  }
  @ToolbarContentBuilder func separateToolbarItem<Content:View>(_ id:String,placement:ToolbarItemPlacement = .primaryAction,@ViewBuilder content:()->Content)->some ToolbarContent {
    if #available(macOS 26.0,*) {ToolbarItem(id:id,placement:placement,content:content).sharedBackgroundVisibility(.hidden)}
    else {ToolbarItem(id:id,placement:placement,content:content)}
  }
  func toolbarGlyph(_ symbol:String)->some View {
    Image(systemName:symbol).font(.system(size:14)).frame(width:32,height:32)
      .background(Color.white.opacity(0.065),in:Circle()).overlay(Circle().stroke(Color.white.opacity(0.10),lineWidth:0.5)).contentShape(Circle())
  }
  func toolbarButton(_ symbol:String,_ title:String,action:@escaping ()->Void)->some View {
    Button(action:action){toolbarGlyph(symbol)}.buttonStyle(.plain).help(title).accessibilityLabel(title)
  }
  func toggleLibrary() {
    if expanded { expanded=false;libraryCollapsed=false;inspectorCollapsed=true }
    else { libraryCollapsed.toggle() }
    libraryPopover=false
  }
  func toggleInspector() {
    if expanded { expanded=false;libraryCollapsed=true;inspectorCollapsed=false }
    else { inspectorCollapsed.toggle() }
    inspectorPopover=false
  }
  var mediaRail:some View {
    VStack(spacing:22) {
      Button {libraryPopover.toggle()} label:{Image(systemName:"square.stack.3d.up")}.help("媒体与轨道 / Media and tracks")
        .popover(isPresented:$libraryPopover,arrowEdge:.trailing){libraryPanel.frame(width:300,height:680).environmentObject(model).preferredColorScheme(.dark)}
      Divider()
      Button {model.chooseAudio()} label:{Image(systemName:"waveform")}.help("导入音频 / Import audio").disabled(busy)
      Button {model.chooseMIDI()} label:{Image(systemName:"pianokeys")}.help("导入 MIDI / Import MIDI").disabled(busy)
      Button {model.chooseCover()} label:{Image(systemName:"photo")}.help("导入封面 / Import artwork").disabled(busy)
      Spacer()
      Text("\(model.tracks.count)").font(.caption.monospacedDigit())
      Image(systemName:"music.note.list").foregroundStyle(.secondary)
    }.font(.system(size:16)).buttonStyle(.borderless).padding(.vertical,20).padding(.horizontal,12).frame(maxHeight:.infinity)
  }
  var inspectorRail:some View {
    VStack(spacing:14) {
      VStack(spacing:12) {
        ForEach(0..<4,id:\.self){index in
          Button {inspector=index;inspectorPopover=true} label:{
            VStack(spacing:4){Image(systemName:["slider.horizontal.3","sparkles","textformat","square.and.arrow.up"][index]).font(.system(size:16));Text(["场景","特效","文字","导出"][index]).font(.system(size:10))}.frame(width:58,height:42)
          }.background(inspector == index ? accent.opacity(0.12):.clear,in:RoundedRectangle(cornerRadius:7))
        }
      }.popover(isPresented:$inspectorPopover,arrowEdge:.leading){
        VStack(spacing:0){HStack{Text("检查器 / Inspector").font(.caption);Spacer();Button{inspectorPopover=false}label:{Image(systemName:"xmark")}.buttonStyle(.borderless)}.padding(12);inspectorPanel}.frame(width:340,height:680).environmentObject(model).preferredColorScheme(.dark)
      }
      Divider()
      if model.settings.scene != .midi {
        Menu {ForEach(AudioTemplate.allCases,id:\.self){template in Button(template.label){model.selectAudioTemplate(template)}}} label:{Text("\(model.settings.audioTemplate == .orbit ? "01":model.settings.audioTemplate == .spectralField ? "02":"03")").font(.caption.monospacedDigit())}.help("频谱模板 / Audio template")
        Toggle("节拍 / Beat",isOn:metronomeBinding).toggleStyle(.checkbox).font(.system(size:9))
        railNumber("高度 / Gain",$model.settings.spectrumGain,0.1...5)
        railNumber("网格 / Grid",$model.settings.audioTextureOpacity,0...1)
        railNumber("Z 深度",$model.settings.spectrumDepth,-1...1)
        railNumber("倾斜 / Tilt",$model.settings.spectrumTilt,0...70)
      }
      Toggle("CRT",isOn:$model.settings.crtEnabled).toggleStyle(.checkbox).font(.system(size:10))
      Spacer(minLength:0)
      if let track=model.tracks.first(where:{$0.id==selectedTrack}) {
        Button{inspector=0;inspectorPopover=true}label:{Image(systemName:"slider.horizontal.3")}.help("调整选中轨道 / Edit selected track")
        Circle().fill(Color(nsColor:(model.styles[track.id]?.color ?? RGB.palette[0]).nsColor)).frame(width:16,height:16)
        Text(track.displayName).font(.system(size:9)).lineLimit(2).help(track.menuLabel)
      }
    }.buttonStyle(.borderless).padding(.vertical,16).padding(.horizontal,8).frame(maxHeight:.infinity).disabled(busy)
  }
  func railNumber(_ label:String,_ value:Binding<Double>,_ range:ClosedRange<Double>)->some View {
    VStack(spacing:4){Text(label).font(.system(size:9)).foregroundStyle(.secondary);NumberEditor(value:value,range:range,label:label).font(.system(size:11)).frame(width:62)}
  }
  var libraryPanel:some View {
    VStack(alignment:.leading,spacing:16) {
      caption("媒体库 / MEDIA LIBRARY")
      Button {model.chooseAudio()} label:{Label("导入音频 / Audio",systemImage:"waveform").frame(maxWidth:.infinity,alignment:.leading)}
      Text(model.audioURL?.lastPathComponent ?? "WAV · MP3 · M4A").font(.system(size:10)).foregroundStyle(.secondary).lineLimit(2)
      if model.analyzingAudio { ProgressView("FFT analysis…").font(.caption) }
      Button {model.chooseMIDI()} label:{Label("追加 MIDI / Add MIDI",systemImage:"pianokeys").frame(maxWidth:.infinity,alignment:.leading)}
      if !model.midiURLs.isEmpty {
        ScrollView{VStack(alignment:.leading,spacing:3){ForEach(model.midiURLs.indices,id:\.self){i in Text(model.midiURLs[i].lastPathComponent).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1).help(model.midiURLs[i].lastPathComponent)}}.frame(maxWidth:.infinity,alignment:.leading)}.frame(height:min(84,CGFloat(model.midiURLs.count)*16))
      }
      Button {model.chooseCover()} label:{Label("导入封面 / Cover",systemImage:"photo").frame(maxWidth:.infinity,alignment:.leading)}
      Text(model.coverURL?.lastPathComponent ?? "封面用于音频场景 / Audio artwork").font(.system(size:10)).foregroundStyle(.secondary)
      Divider();caption("轨道 / TRACKS")
      ScrollView {
        LazyVStack(spacing:6) { ForEach(model.tracks) { track in
          let style=model.styles[track.id] ?? TrackStyle(color:RGB.palette[0])
          HStack(spacing:8) {
            TrackColorWell(color:Binding(get:{style.color.nsColor},set:{color in model.updateTrackStyle(track.id){$0.color=RGB(color)}}),label:"Color").frame(width:24,height:24)
            VStack(alignment:.leading,spacing:3) {
              Text(track.displayName).font(.system(size:11,weight:.medium)).lineLimit(1).help(track.menuLabel)
              Text(track.sourceLabel).font(.system(size:9)).foregroundStyle(.secondary).lineLimit(1).help(track.sourceLabel)
              HStack(spacing:8) {
                Text("\(track.notes.count) notes").font(.system(size:9)).foregroundStyle(.secondary)
                Spacer(minLength:0)
                Button("M"){model.updateTrackStyle(track.id){$0.muted.toggle()}}.foregroundStyle(style.muted ? accent:.secondary).help("静音 / Mute")
                Button("S"){model.updateTrackStyle(track.id){$0.solo.toggle()}}.foregroundStyle(style.solo ? accent:.secondary).help("独奏 / Solo")
                Button{model.deleteTrack(track.id)}label:{Image(systemName:"trash")}.help("删除轨道 / Delete track").accessibilityLabel("删除 \(track.menuLabel)")
              }
            }.frame(maxWidth:.infinity,alignment:.leading)
          }.font(.system(size:10,weight:.bold,design:.monospaced)).buttonStyle(.borderless).padding(9).background(selectedTrack == track.id ? accent.opacity(0.13):Color.white.opacity(0.025),in:RoundedRectangle(cornerRadius:8)).contentShape(Rectangle()).onTapGesture{selectedTrack=track.id;inspector=0}
            .contextMenu {
              Button("调整流速与位置 / Edit flow and position"){selectedTrack=track.id;inspector=0;if rightCollapsed {inspectorPopover=true}}
              Button("删除轨道 / Delete track",role:.destructive){model.deleteTrack(track.id)}
            }
            .onDrag { draggedTrack=track.id;return NSItemProvider(object:track.id as NSString) }
            .onDrop(of:[UTType.text],isTargeted:nil) { _ in
              guard let source=draggedTrack,let a=model.tracks.firstIndex(where:{$0.id==source}),let b=model.tracks.firstIndex(where:{$0.id==track.id}) else{return false}
              model.tracks.move(fromOffsets:IndexSet(integer:a),toOffset:b>a ? b+1:b);model.revision+=1;draggedTrack=nil;return true
            }
        }}
      }
      Divider()
      TextField("预设名称 / Preset name",text:$presetName).textFieldStyle(.roundedBorder)
      HStack {
        Button("保存 / Save") { do { _=try library.save(name:presetName,settings:model.settings,palette:currentPalette);presetName="" } catch {model.errorMessage=error.localizedDescription} }.disabled(presetName.isEmpty)
        Menu("管理 / Manage") { ForEach(library.customPresets){p in Menu(p.name){Button("更新 / Update"){do{try library.update(id:p.id,name:p.name,settings:model.settings,palette:currentPalette)}catch{model.errorMessage=error.localizedDescription}};Button("删除 / Delete"){library.delete(id:p.id)}}} }
      }.font(.caption)
      Button("清除设置 / Reset saved settings") {model.resetSavedSettings()}.font(.system(size:10)).foregroundStyle(.secondary)
    }.padding(16).buttonStyle(.bordered).disabled(busy)
  }
  var transport:some View {
    VStack(spacing:10) {
      if model.settings.scene != .audio {
        HStack {
          miniSlider("横向 / X",$model.settings.horizontalZoom,0.25...8)
          miniSlider("纵向 / Y",$model.settings.pitchZoom,0.25...8)
          miniSlider("音高 / Pitch",$model.settings.pitchScroll,-128...128)
          miniSlider("触发线 / Playhead",$model.settings.playheadPosition,0.05...0.95)
          Button {model.resetViewport()} label:{Image(systemName:"arrow.counterclockwise")}
        }
      }
      Slider(value:Binding(get:{model.time},set:{model.seek($0)}),in:0...max(0.01,model.totalDuration))
      HStack(spacing:16) {
        Button {model.settings.loop.toggle()} label:{Image(systemName:"repeat").foregroundStyle(model.settings.loop ? accent:.secondary)}
        Button {NSApp.keyWindow?.makeFirstResponder(nil);model.seek(0)} label:{Image(systemName:"backward.end.fill")}.help("回到开头 / Beginning (Return)")
        Button {NSApp.keyWindow?.makeFirstResponder(nil);model.togglePlayback()} label:{Image(systemName:(model.playing || model.preparingPlayback) ? "pause.fill":"play.fill").font(.title3)}.help("播放/暂停 / Play/Pause (Space)")
        Text("\(clock(model.time)) / \(clock(model.totalDuration))").font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary)
        Spacer();Image(systemName:"speaker.wave.2");Slider(value:$model.settings.volume,in:0...1).frame(width:65)
        Text("BPM").font(.caption);NumberEditor(value:Binding(get:{model.effectiveBPM},set:{model.settings.bpm=$0}),range:1...1000,label:"BPM").frame(width:54)
      }.buttonStyle(.borderless)
    }.padding(16).background(Color.white.opacity(0.025)).disabled(busy)
  }
  var inspectorPanel:some View {
    VStack(spacing:0) {
      Picker("Inspector",selection:$inspector){Text("场景").tag(0);Text("特效").tag(1);Text("文字").tag(2);Text("导出").tag(3)}.pickerStyle(.segmented).labelsHidden().padding(14)
      Text(["SCENE","EFFECTS","OVERLAYS","OUTPUT"][min(3,max(0,inspector))]).font(.system(size:8,weight:.semibold)).tracking(2).foregroundStyle(.secondary)
      ScrollView { VStack(alignment:.leading,spacing:18) {
        if inspector==0 { sceneControls }
        else if inspector==1 { effectControls }
        else if inspector==2 { textControls }
        else { outputControls }
      }.padding(16) }.disabled(busy)
      Divider()
      VStack(spacing:10) {
        if let p=model.exportProgress { ProgressView(value:p);HStack{Text("Export \(Int(p*100))%");Spacer();Button("取消 / Cancel"){model.cancelExport()}}.font(.caption) }
        else { Button{model.export()}label:{Label("导出 / Export \(model.settings.container.rawValue)",systemImage:"arrow.up.right.square").frame(maxWidth:.infinity).padding(.vertical,8)}.buttonStyle(.borderedProminent).disabled(busy || (model.tracks.isEmpty && model.audioURL==nil));if model.lastExportURL != nil {Button("Finder 中显示 / Reveal"){model.revealExport()}.font(.caption)} }
      }.padding(16)
    }
  }
  var shortcuts:some View {
    CanvasShortcuts { action in
      guard !busy else{return}
      switch action {
      case .play:model.togglePlayback()
      case .beginning:model.seek(0)
      case .back:model.seek(model.time-5)
      case .forward:model.seek(model.time+5)
      case .louder:model.settings.volume=min(1,model.settings.volume+0.05)
      case .quieter:model.settings.volume=max(0,model.settings.volume-0.05)
      case .loop:model.settings.loop.toggle()
      case .maximize:expanded.toggle()
      case .escape:expanded=false;libraryPopover=false;inspectorPopover=false
      case .mute:if let id=selectedTrack{model.styles[id]?.muted.toggle();if model.styles[id]?.muted==true{model.styles[id]?.solo=false}}
      case .solo:if let id=selectedTrack{model.styles[id]?.solo.toggle();if model.styles[id]?.solo==true{model.styles[id]?.muted=false}}
      }
    }.frame(width:0,height:0)
  }
  func sceneLabel(_ scene:SceneKind)->String { scene == .midi ? "音符 / MIDI":(scene == .audio ? "频谱 / Audio":"混合 / Hybrid") }
  func caption(_ label:String)->some View { Text(label).font(.system(size:10,weight:.semibold)).tracking(1).foregroundStyle(accent) }
  func clock(_ t:Double)->String {String(format:"%02d:%02d",Int(max(0,t))/60,Int(max(0,t))%60)}
  func miniSlider(_ label:String,_ value:Binding<Double>,_ range:ClosedRange<Double>)->some View { VStack{Text(label).font(.system(size:9)).foregroundStyle(.secondary);Slider(value:value,in:range)} }
  func slider(_ label:String,_ value:Binding<Double>,_ range:ClosedRange<Double>)->some View { VStack(alignment:.leading,spacing:5){HStack{Text(label).font(.caption);Spacer();Text(String(format:"%.2f",value.wrappedValue)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)};Slider(value:value,in:range)} }
  func number(_ label:String,_ value:Binding<Double>,_ range:ClosedRange<Double>)->some View {HStack{Text(label).font(.caption);Spacer();NumberEditor(value:value,range:range,label:label).frame(width:75)}}
  func choose<T>(_ label:String,_ value:Binding<T>)->some View where T:RawRepresentable & CaseIterable & Hashable,T.RawValue==String,T.AllCases:RandomAccessCollection {Picker(label,selection:value){ForEach(Array(T.allCases),id:\.self){Text($0.rawValue).tag($0)}}.font(.caption)}
  func color(_ label:String,_ value:Binding<RGB>)->some View {ColorPicker(label,selection:Binding(get:{Color(nsColor:value.wrappedValue.nsColor)},set:{value.wrappedValue=RGB(NSColor($0))}),supportsOpacity:false).font(.caption)}
}

/// Playback ticks invalidate the transport, while inspectors observe configuration only.
struct TimelineRefresh<Content:View>:View {
  @ObservedObject var clock:PlaybackClock
  @ViewBuilder var content:()->Content
  var body:some View { content() }
}

/// Configure only the window owned by this hosting view.
struct WindowChrome:NSViewRepresentable {
  final class ChromeView:NSView {
    override func viewDidMoveToWindow(){
      super.viewDidMoveToWindow()
      window?.titleVisibility = .hidden
      window?.titlebarAppearsTransparent = true
      window?.toolbarStyle = .unified
      window?.appearance = NSAppearance(named:.darkAqua)
    }
  }
  func makeNSView(context:Context)->NSView {ChromeView()}
  func updateNSView(_ view:NSView,context:Context) {}
}
