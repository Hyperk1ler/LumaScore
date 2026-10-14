import SwiftUI
import AppKit
extension StudioView {
  @ViewBuilder var sceneControls:some View {
    if model.settings.scene != .audio,let id=selectedTrack,let track=model.tracks.first(where:{$0.id==id}),let style=model.styles[id] {
      caption("轨道布局 / TRACK LAYOUT")
      Text(track.menuLabel).font(.system(size:11,weight:.medium)).textSelection(.enabled)
      slider("流速（×）/ Flow speed",trackValue(id,\.flowSpeed),0.25...4)
      slider("横向位置（%）/ X",trackPercent(id,\.horizontalOffset,multiplier:100),-50...50)
      slider("纵向位置（%）/ Y",trackPercent(id,\.verticalOffset,multiplier:50),-50...50)
      number("延后（秒）/ Time offset",trackValue(id,\.timeOffset),-3600...3600)
      Text("流速与位置只调整视觉布局；延后改变此轨道的触发时间。 / Flow and position affect layout; time offset shifts this track's triggers.").font(.system(size:10)).foregroundStyle(.secondary)
      Button("重置轨道布局 / Reset track layout") {model.updateTrackStyle(id){value in value.flowSpeed=1;value.horizontalOffset=0;value.verticalOffset=0;value.timeOffset=0}}
      Divider()
    }
    if model.settings.scene != .midi {
      if model.settings.scene == .audio {
        caption("频谱模板 / AUDIO TEMPLATE")
        templatePicker
        slider("网格纹理 / Grid opacity",$model.settings.audioTextureOpacity,0...1)
        slider("细微颗粒 / Fine grain",$model.settings.audioTextureGrain,0...1)
      }
      Toggle("节拍器 / Metronome",isOn:metronomeBinding)
      caption("曲目信息 / TRACK INFORMATION")
      TextField("标题 / Title",text:$model.settings.title).textFieldStyle(.roundedBorder)
      TextField("作者 / Artist",text:$model.settings.artist).textFieldStyle(.roundedBorder)
      TextField("风格 / Genre",text:$model.settings.genre).textFieldStyle(.roundedBorder)
      color("频谱颜色 / Spectrum",$model.settings.spectrumColor)
      slider("增益 / Gain",$model.settings.spectrumGain,0.1...5)
      slider("平滑 / Smoothing",$model.settings.spectrumSmoothing,0...1)
      slider("前后深度 / Spectrum Z",$model.settings.spectrumDepth,-1...1)
      slider("透视倾斜 / Spectrum tilt",$model.settings.spectrumTilt,0...70)
      if model.settings.scene == .hybrid {Toggle("频谱置前 / Spectrum in front",isOn:$model.settings.spectrumInFront)}
      Toggle("波形 / Waveform",isOn:$model.settings.waveformVisible)
      Toggle("技术信息 / Audio metrics",isOn:$model.settings.audioMetadataVisible)
      Toggle("封面旋转 / Artwork rotation",isOn:$model.settings.coverRotation)
      Button("清除封面 / Remove artwork"){model.coverURL=nil}
    }
    if model.settings.scene != .audio {
      caption("音符 / NOTES")
      choose("标记 / Marker",$model.settings.marker)
      if model.settings.marker == .emoji {TextField("Emoji",text:$model.settings.emoji).textFieldStyle(.roundedBorder)}
      choose("线条 / Line",$model.settings.lineStyle)
      choose("击打 / Ripple",$model.settings.rippleStyle)
      choose("动画 / Motion",$model.settings.noteMotion)
      slider("线宽 / Thickness",$model.settings.thickness,1...128)
      slider("圆角 / Roundness",$model.settings.noteRoundness,0...1)
      slider("标记尺寸 / Marker size",$model.settings.markerSize,1...128)
      slider("可见窗口 / Window",$model.settings.window,1...240)
      slider("反应位置 / Reaction",$model.settings.reactionPosition,0...1)
      slider("动画深度 / Animation",$model.settings.animationDepth,0...2)
      slider("颤音 / Vibrato",$model.settings.modulationDepth,0...5)
      slider("弯音 / Pitch bend",$model.settings.bendDepth,0...5)
      slider("击打尺寸 / Ripple size",$model.settings.rippleSize,0.1...5)
      slider("击打时长 / Ripple duration",$model.settings.rippleDuration,0.05...5)
      Toggle("网格 / Grid",isOn:$model.settings.grid)
      Toggle("触发线 / Playhead",isOn:$model.settings.playheadVisible)
      color("触发线颜色 / Playhead color",$model.settings.playheadColor)
      if let id=selectedTrack,let style=model.styles[id] {
        Divider();caption("选中轨道 / SELECTED TRACK")
        Picker("线条 / Line",selection:Binding(get:{style.line ?? model.settings.lineStyle},set:{model.styles[id]?.line=$0})){ForEach(NoteLine.allCases,id:\.self){Text($0.rawValue).tag($0)}}
        Picker("标记 / Marker",selection:Binding(get:{style.marker ?? model.settings.marker},set:{model.styles[id]?.marker=$0})){ForEach(Marker.allCases,id:\.self){Text($0.rawValue).tag($0)}}
        Button("恢复全局样式 / Inherit global"){model.updateTrackStyle(id){value in value.line=nil;value.marker=nil;value.ripple=nil;value.motion=nil;value.thickness=nil;value.glow=nil}}
      }
    }
    Divider();caption("背景 / BACKGROUND")
    color("颜色 / Color",$model.settings.background)
    Button("背景图片 / Background image"){model.chooseBackground()}
    if model.backgroundURL != nil {Button("移除背景 / Remove background"){model.backgroundURL=nil}}
    slider("图片透明度 / Image opacity",$model.settings.backgroundOpacity,0...1)
    slider("纵深 / Perspective",$model.settings.depth,0...1)
    Divider();caption("色组 / COLOR SETS")
    Menu("选择色组 / Choose palette"){ForEach(library.builtinColorSets){p in Button("\(p.labelZH) / \(p.label)"){model.applyPalette(p.colors)}};ForEach(library.customColorSets){p in Menu(p.name){Button("应用 / Apply"){model.applyPalette(p.colors)};Button("更新 / Update"){do{try library.updateColorSet(id:p.id,name:p.name,colors:currentPalette)}catch{model.errorMessage=error.localizedDescription}};Button("删除 / Delete"){library.deleteColorSet(id:p.id)}}}}
    TextField("色组名称 / Palette name",text:$presetName).textFieldStyle(.roundedBorder)
    Button("保存色组 / Save palette"){do{_=try library.saveColorSet(name:presetName,colors:currentPalette)}catch{model.errorMessage=error.localizedDescription}}.disabled(presetName.isEmpty)
    Button("全部轨道颜色 / Color all tracks"){model.applyPalette([model.settings.spectrumColor])}
  }
  func trackValue(_ id:String,_ key:WritableKeyPath<TrackStyle,Double>)->Binding<Double> {
    Binding(get:{(model.styles[id] ?? TrackStyle(color:RGB.palette[0]))[keyPath:key]},set:{value in model.updateTrackStyle(id){$0[keyPath:key]=value}})
  }
  func trackPercent(_ id:String,_ key:WritableKeyPath<TrackStyle,Double>,multiplier:Double)->Binding<Double> {
    let value=trackValue(id,key)
    return Binding(get:{value.wrappedValue*multiplier},set:{value.wrappedValue=$0/multiplier})
  }
  var templatePicker:some View {
    Picker("模板 / Template",selection:Binding(get:{model.settings.audioTemplate},set:{model.selectAudioTemplate($0)})) {
      ForEach(AudioTemplate.allCases,id:\.self){Text($0.label).tag($0)}
    }.font(.caption)
  }
  var metronomeBinding:Binding<Bool> {Binding(get:{model.settings.metronomeEnabled},set:{model.setMetronomeEnabled($0)})}
  var currentPalette:[RGB] {let colors=model.tracks.isEmpty ? RGB.palette:model.tracks.map{model.styles[$0.id]?.color ?? RGB.palette[0]};return (0..<8).map{colors[$0%colors.count]}}
  @ViewBuilder var effectControls:some View {
    caption("显像管 / CRT SIGNAL")
    Toggle("启用 CRT / Enable CRT",isOn:$model.settings.crtEnabled)
    Group {
      slider("扫描线 / Scanlines",$model.settings.crtScanlines,0...1)
      slider("信号噪点 / Signal noise",$model.settings.crtNoise,0...1)
      slider("水平干扰 / Tracking jitter",$model.settings.crtJitter,0...1)
      slider("RGB 色偏 / Chromatic split",$model.settings.crtChromatic,0...1)
      slider("闪烁 / Flicker",$model.settings.crtFlicker,0...1)
      slider("暗角 / Vignette",$model.settings.crtVignette,0...1)
    }.disabled(!model.settings.crtEnabled)
    Text("鱼眼黑边会保留；所有效果进入导出。\nBlack lens borders remain; effects are rendered into exports.").font(.system(size:10)).foregroundStyle(.secondary)
    Divider();caption("镜头与光晕 / LENS & BLOOM")
    choose("镜头模式 / Lens",$model.settings.lensMode)
    slider("鱼眼强度 / Distortion",$model.settings.fisheye,0...1)
    Toggle("GPU Bloom",isOn:$model.settings.bloomEnabled)
    slider("光晕强度 / Intensity",$model.settings.glow,0...1)
    slider("扩散 / Radius",$model.settings.glowRadius,2...40)
    Picker("反应轨道 / Camera source",selection:$model.settings.cameraTrackID){Text("所有轨道 / All").tag("");ForEach(model.tracks){Text($0.menuLabel).tag($0.id)}}
    slider("冲击 / Punch",$model.settings.cameraPunch,0...1)
    slider("镜头震动 / Shake",$model.settings.cameraShake,0...1)
    Divider();caption("粒子 / PARTICLES")
    slider("启用强度 / Amount mix",$model.settings.particles,0...1)
    choose("样式 / Style",$model.settings.particleStyle);choose("方向 / Direction",$model.settings.particleDirection)
    slider("数量 / Count",$model.settings.particleAmount,0...500)
    slider("尺寸 / Size",$model.settings.particleSize,0.5...3)
    slider("速度 / Speed",$model.settings.particleSpeed,0...2)
    slider("透明度 / Opacity",$model.settings.particleOpacity,0...1)
    slider("闪烁 / Twinkle",$model.settings.particleTwinkle,0...1)
    color("粒子颜色 / Color",$model.settings.particleColor)
    Divider();caption("调色 / COLOR GRADE")
    Toggle("启用调色 / Color grade",isOn:$model.settings.colorFilterEnabled)
    slider("亮度 / Brightness",$model.settings.brightness,-1...1)
    slider("对比度 / Contrast",$model.settings.contrast,0...3)
    slider("饱和度 / Saturation",$model.settings.saturation,0...3)
    slider("色相 / Hue",$model.settings.hue,-180...180)
    slider("复古棕 / Sepia",$model.settings.sepia,0...1)
  }
  @ViewBuilder var textControls:some View {
    caption("标题 / TITLE")
    Toggle("显示标题 / Show title",isOn:$model.settings.titleEnabled)
    TextField("标题 / Title",text:$model.settings.title).textFieldStyle(.roundedBorder)
    choose("位置 / Position",$model.settings.titlePosition)
    color("颜色 / Color",$model.settings.titleColor)
    slider("字号 / Size",$model.settings.titleSize,8...200)
    fontPicker("标题字体 / Title font",$model.settings.titleFont)
    choose("入场 / Entrance",$model.settings.titleMotion)
    number("动画时长 / Duration",$model.settings.titleMotionDuration,0.05...10)
    number("音频/MIDI 延后（秒）/ Media lead-in",$model.settings.intro,0...60)
    Button("从头预览入场 / Preview entrance"){NSApp.keyWindow?.makeFirstResponder(nil);model.previewEntrance()}
    Text("画面与入场从零开始，音频及 MIDI 延后。/ Scene and entrance start now; audio and MIDI start later.").font(.system(size:10)).foregroundStyle(.secondary)
    Divider();caption("和弦分析 / CHORD ANALYSIS")
    Toggle("显示和弦 / Show chords",isOn:$model.settings.chordEnabled)
    Text("选择参与分析的轨道 / Choose source tracks").font(.caption).foregroundStyle(.secondary)
    ForEach(model.tracks){track in Toggle(track.menuLabel,isOn:Binding(get:{model.settings.chordTrackIDs.contains(track.id)},set:{enabled in if enabled {model.settings.chordTrackIDs.append(track.id)}else{model.settings.chordTrackIDs.removeAll{$0==track.id}}})).font(.caption)}
    choose("位置 / Position",$model.settings.chordPosition)
    color("颜色 / Color",$model.settings.chordColor)
    slider("字号 / Size",$model.settings.chordSize,8...200)
    fontPicker("和弦字体 / Chord font",$model.settings.chordFont)
    Text("包含扩展、转位和斜线和弦；按选中 MIDI 轨道分析。\nExtended and slash chords from selected MIDI tracks.").font(.system(size:10)).foregroundStyle(.secondary)
  }
  func fontPicker(_ label:String,_ value:Binding<String>)->some View {
    Picker(label,selection:Binding(get:{FontCatalog.families.contains(value.wrappedValue) ? value.wrappedValue:"System"},set:{value.wrappedValue=$0})){
      Text("System").tag("System")
      ForEach(FontCatalog.families,id:\.self){Text($0).tag($0)}
    }.font(.caption)
  }
  @ViewBuilder var outputControls:some View {
    caption("输出 / OUTPUT")
    choose("容器 / Container",$model.settings.container)
    if model.settings.container == .webm {Text("VP9 + Opus · macOS 27+ · Apple Silicon").font(.system(size:10)).foregroundStyle(.secondary)}else{choose("编码 / Codec",$model.settings.codec)}
    choose("画幅 / Aspect",$model.settings.aspect)
    Picker("短边 / Resolution",selection:$model.settings.resolution){ForEach([480,720,1080,2160],id:\.self){Text("\($0)p").tag($0)}}
    Picker("帧率 / FPS",selection:$model.settings.fps){Text("30").tag(30);Text("60").tag(60)}
    Picker("码率 / Bitrate",selection:$model.settings.bitrate){ForEach([8,16,24,40],id:\.self){Text("\($0) Mbps").tag($0)}}
    Divider();caption("时间与同步 / TIMELINE")
    number("前奏 / Intro",$model.settings.intro,0...60)
    number("MIDI 偏移 / Offset",$model.settings.offset,-3600...3600)
    number("BPM",Binding(get:{model.effectiveBPM},set:{model.settings.bpm=$0}),1...1000)
    Button("使用 MIDI 原速 / Original tempo"){model.settings.bpm=0}
    number("起点 / Start",$model.settings.exportStart,0...86400)
    number("终点 / End (0 = Full)",$model.settings.exportEnd,0...86400)
    HStack{Button("设为起点 / In"){model.settings.exportStart=model.time};Button("设为终点 / Out"){model.settings.exportEnd=model.time}}.font(.caption)
    Toggle("画面过渡 / Screen fade",isOn:$model.settings.screenFadeEnabled)
    number("画面淡入 / Fade in",$model.settings.fadeIn,0...600)
    number("画面淡出 / Fade out",$model.settings.fadeOut,0...600)
    Toggle("音频过渡 / Audio fade",isOn:$model.settings.audioFadeEnabled)
    number("音频淡入 / Audio in",$model.settings.audioFadeIn,0...600)
    number("音频淡出 / Audio out",$model.settings.audioFadeOut,0...600)
    if let stats=model.exportStatistics {Text(String(format:"%.2fs · %.1f× realtime · %.1f MB",stats.elapsed,stats.realtimeMultiple,Double(stats.outputBytes)/1e6)).font(.caption.monospacedDigit())}
  }
}
