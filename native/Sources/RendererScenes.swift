import AppKit
import MetalKit
import simd

extension MetalSceneRenderer {
  func resetAtlas() {
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:4096,height:4096,mipmapped:false)
    descriptor.storageMode = .shared
    descriptor.usage = .shaderRead
    atlas=device.makeTexture(descriptor:descriptor)
    textCache.removeAll(keepingCapacity:true)
    atlasX=2;atlasY=2;atlasRow=0
  }
  func text(_ value:String, at point:SIMD2<Float>, size:Float, color:SIMD4<Float>, font:String="System", maxWidth:Float=Float.greatestFiniteMagnitude, alignedLeft:Bool=false) {
    guard !value.isEmpty, let atlas=atlas else { return }
    let key="\(value)|\(font)|\(Int(size.rounded()))"
    let cached:(SIMD4<Float>,SIMD2<Float>)
    if let old=textCache[key] { cached=old }
    else {
      let typeface=FontCatalog.font(family:font,size:CGFloat(size))
      let string=NSAttributedString(string:value,attributes:[.font:typeface,.foregroundColor:NSColor.white])
      let dimensions=string.size()
      let width=min(4000,max(1,Int(ceil(dimensions.width))+8)),height=min(512,max(1,Int(ceil(dimensions.height))+8))
      if atlasX+width+2>4096 { atlasX=2;atlasY+=atlasRow+2;atlasRow=0 }
      guard atlasY+height+2<4096,
        let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let bytes=context.data else { return }
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:false)
      string.draw(at:NSPoint(x:4,y:4));NSGraphicsContext.restoreGraphicsState()
      atlas.replace(region:MTLRegionMake2D(atlasX,atlasY,width,height),mipmapLevel:0,withBytes:bytes,bytesPerRow:width*4)
      cached=(SIMD4(Float(atlasX)/4096,Float(atlasY)/4096,Float(width)/4096,Float(height)/4096),SIMD2(Float(width),Float(height)))
      textCache[key]=cached;atlasX+=width+2;atlasRow=max(atlasRow,height)
    }
    let fit=min(1,maxWidth/max(1,cached.1.x))
    guard instances.count<capacity else { return }
    instances.append(GPUInstance(rect:SIMD4(point.x+(alignedLeft ? cached.1.x*fit/2:0),point.y,cached.1.x*fit,cached.1.y*fit),color:color,params:SIMD4(8,0,0,0),extra:cached.0))
  }
  func cameraReaction(time:Double) -> SIMD4<Float> {
    let s=snapshot.settings
    guard time >= s.intro,(s.cameraShake > 0 || s.cameraPunch > 0) else{return .zero}
    var reaction:Float=0
    for track in snapshot.tracks where s.cameraTrackID.isEmpty || track.id == s.cameraTrackID {
      let t=snapshot.trackTime(track.id,at:time)
      let i=lowerBound(track.notes,t.nextUp,key:{$0.start})
      if i>0 {
        let age=Float(max(0,t-track.notes[i-1].start))
        reaction=max(reaction,track.notes[i-1].velocity*exp(-age*7))
      }
    }
    return SIMD4(sin(Float(time)*43)*reaction*Float(s.cameraShake)*0.01,cos(Float(time)*37)*reaction*Float(s.cameraShake)*0.01,reaction*Float(s.cameraPunch)*0.08,0)
  }
  func buildAmbientParticles(time:Double,width:Float,height:Float) {
    let s=snapshot.settings
    let count=Int(s.particles*s.particleAmount)
    guard count>0 else { return }
    let scale=height/720
    for i in 0..<count {
      let seed=Float((i*719+37)%997)/997
      let other=Float((i*373+131)%991)/991
      let phase=Float(time)*Float(s.particleSpeed)*(0.02+seed*0.04)
      let x=s.particleDirection == .left ? width*(1-(other+phase).truncatingRemainder(dividingBy:1)) : seed*width
      let y=s.particleDirection == .down ? height*((other+phase).truncatingRemainder(dividingBy:1)) : seed*height
      var color=s.particleColor.vector
      color.w=Float(s.particleOpacity)*(1-Float(s.particleTwinkle)*0.45+Float(s.particleTwinkle)*sin(Float(time)*3+seed*31)*0.45)
      let size=Float(s.particleSize)*scale
      if s.particleStyle == .comets {
        add(x,y,s.particleDirection == .left ? size*12:size,s.particleDirection == .down ? size*12:size,color,radius:size,glow:Float(s.glow)*0.4)
      } else { add(x,y,size*(s.particleStyle == .sparkles ? 3:1),size*(s.particleStyle == .sparkles ? 3:1),color,kind:s.particleStyle == .sparkles ? 2:1,glow:s.bloomEnabled ? Float(s.glow)*0.5:0) }
    }
  }
  func buildAudio(time:Double,width:Float,height:Float,compact:Bool) {
    let s=snapshot.settings, audio=snapshot.audioVisualization
    let audioTime=time-s.intro, scale=height/720
    let blue=s.spectrumColor.vector
    let secondary=SIMD4<Float>(0.57,0.67,0.74,0.9)
    let faint=SIMD4<Float>(blue.x,blue.y,blue.z,0.12)
    if compact {
      if let audio=audio {audio.spectrum(at:audioTime,into:&spectrumBands)}else{for i in spectrumBands.indices{spectrumBands[i]=0}}
      for (i,v) in spectrumBands.enumerated() {
        let x=width*0.06+Float(i)/64*width*0.88
        let h=max(1,v*height*0.18*Float(s.spectrumGain))
        var c=blue;c.w=0.35
        spectrumBar(x,height*0.9-h/2,width*0.88/64-2*scale,h,c,originY:height*0.9,radius:scale)
      }
      if s.metronomeEnabled {buildMetronome(at:SIMD2(width*0.5,height*0.96),width:120*scale,time:time,scale:scale,color:blue)}
      return
    }
    let layout=AudioSceneLayout(settings:s,width:width,height:height)
    let coverSize=Float(layout.cover.width), center=SIMD2(Float(layout.cover.midX),Float(layout.cover.midY))
    if s.audioTextureOpacity>0 || s.audioTextureGrain>0 {
      let i=instances.count
      add(width/2,height/2,width,height,SIMD4(blue.x,blue.y,blue.z,Float(s.audioTextureOpacity)),kind:15,radius:64*scale,aux:Float(s.audioTextureGrain))
      if instances.count>i {instances[i].extra=SIMD4(center.x,center.y,coverSize,s.audioTemplate == .orbit ? 1:0)}
    }
    if coverTexture !== dummy {
      let ratio=Float(coverTexture.width)/Float(coverTexture.height)
      add(center.x,center.y,coverSize,coverSize,SIMD4(1,1,1,1),kind:12,aux:s.coverRotation ? Float(time)*0.08:0,uv:ratio>1 ? SIMD2(1/ratio,1):SIMD2(1,ratio))
    } else {
      add(center.x,center.y,coverSize,coverSize,SIMD4(blue.x*0.30,blue.y*0.30,blue.z*0.30,1),kind:s.audioTemplate == .recordSleeve ? 16:10,radius:0)
      let title=s.title.isEmpty ? (snapshot.audioName.isEmpty ? "UNTITLED":snapshot.audioName):s.title
      let words=title.split(separator:" ",maxSplits:1).map(String.init)
      let x=Float(layout.cover.minX)+coverSize*0.10
      text("LUMASCORE / 01",at:SIMD2(x,Float(layout.cover.minY)+coverSize*0.13),size:coverSize*0.034,color:secondary,maxWidth:coverSize*0.8,alignedLeft:true)
      text(words.first ?? title,at:SIMD2(x,center.y+coverSize*0.08),size:coverSize*0.11,color:s.titleColor.vector,font:s.titleFont,maxWidth:coverSize*0.8,alignedLeft:true)
      if words.count>1 {text(words[1],at:SIMD2(x,center.y+coverSize*0.25),size:coverSize*0.11,color:s.titleColor.vector,font:s.titleFont,maxWidth:coverSize*0.8,alignedLeft:true)}
      text(s.genre.isEmpty ? "AUDIO / 音频":s.genre,at:SIMD2(x,Float(layout.cover.maxY)-coverSize*0.12),size:coverSize*0.036,color:secondary,maxWidth:coverSize*0.8,alignedLeft:true)
    }
    if s.audioTemplate == .orbit {
      for sign:Float in [-1,1] {
        let corner=center+SIMD2(sign*coverSize/2,sign*coverSize/2)
        add(corner.x-sign*12*scale,corner.y,24*scale,2*scale,blue,radius:0)
        add(corner.x,corner.y-sign*12*scale,2*scale,24*scale,blue,radius:0)
      }
    }
    let px=layout.panelX,pw=layout.panelWidth
    let title=s.title.isEmpty ? (snapshot.audioName.isEmpty ? "Untitled / 未命名":snapshot.audioName):s.title
    text(s.audioTemplate == .orbit ? "AUDIO OBSERVATORY / 音频观测":"LUMASCORE SESSIONS / 音频场景",at:SIMD2(px,layout.seriesY),size:9*scale,color:secondary,maxWidth:pw,alignedLeft:true)
    if s.titleEnabled {
      let entrance=TitleEntrance.state(settings:s,time:time,text:title)
      var tint=s.titleColor.vector;tint.w*=entrance.alpha
      text(entrance.text,at:SIMD2(px,layout.titleY+entrance.shift*scale),size:layout.titleFont*entrance.scale,color:tint,font:s.titleFont,maxWidth:pw,alignedLeft:true)
    }
    let artist=s.artist.isEmpty ? "ARTIST / 作者":s.artist
    text(s.audioTemplate == .spectralField && !s.genre.isEmpty ? "\(artist) · \(s.genre)":artist,at:SIMD2(px,layout.artistY),size:14*scale,color:secondary,maxWidth:pw,alignedLeft:true)
    let bpm=snapshot.musicalBPM(at:time).map{String(format:"%.2f",$0)} ?? "—"
    if s.audioTemplate == .spectralField && !layout.portrait {
      let x=width*0.81
      text(bpm+" BPM",at:SIMD2(x,layout.infoY),size:20*scale,color:blue,maxWidth:width*0.14,alignedLeft:true)
      if s.metronomeEnabled {buildMetronome(at:SIMD2(x+87*scale,layout.infoY+35*scale),width:174*scale,time:time,scale:scale,color:blue)}
    } else if s.audioTemplate == .recordSleeve && !layout.portrait {
      text(bpm+" BPM",at:SIMD2(px,layout.infoY),size:19*scale,color:blue,maxWidth:pw*0.32,alignedLeft:true)
      if s.metronomeEnabled {buildMetronome(at:SIMD2(px+205*scale,layout.infoY),width:148*scale,time:time,scale:scale,color:blue)}
    } else {
      text("BPM",at:SIMD2(px,layout.infoY-18*scale),size:8*scale,color:secondary,alignedLeft:true)
      text(bpm,at:SIMD2(px,layout.infoY+6*scale),size:19*scale,color:blue,maxWidth:90*scale,alignedLeft:true)
      if s.metronomeEnabled {buildMetronome(at:SIMD2(px+165*scale,layout.infoY),width:130*scale,time:time,scale:scale,color:blue)}
      text("GENRE / 风格",at:SIMD2(px+pw*0.54,layout.infoY-18*scale),size:8*scale,color:secondary,alignedLeft:true)
      text(s.genre.isEmpty ? "—":s.genre,at:SIMD2(px+pw*0.54,layout.infoY+6*scale),size:14*scale,color:blue,maxWidth:pw*0.28,alignedLeft:true)
      text("DURATION / 时长",at:SIMD2(px+pw*0.88,layout.infoY-18*scale),size:8*scale,color:secondary,maxWidth:pw*0.18)
      text(clock(audio?.duration ?? 0),at:SIMD2(px+pw*0.88,layout.infoY+6*scale),size:17*scale,color:blue)
    }
    let sx=Float(layout.spectrum.minX),sw=Float(layout.spectrum.width),top=Float(layout.spectrum.minY),sh=Float(layout.spectrum.height),baseline=top+sh
    for i in 0...4 {
      let y=baseline-Float(i)/4*sh
      add(sx+sw/2,y,sw,0.6*scale,faint,radius:0)
      text("\(-80+i*20)",at:SIMD2(sx-24*scale,y),size:8*scale,color:secondary)
    }
    if let audio=audio {
      audio.spectrum(at:audioTime,into:&spectrumBands);audio.spectrum(at:audioTime-0.05,into:&previousSpectrumBands)
    }else{for i in spectrumBands.indices{spectrumBands[i]=0;previousSpectrumBands[i]=0}}
    for i in 0..<64 {
      let v=spectrumBands[i]*(1-Float(s.spectrumSmoothing)*0.5)+previousSpectrumBands[i]*Float(s.spectrumSmoothing)*0.5
      let value=max(0,(v*90-10)/80)
      let h=min(sh,max(scale,value*sh*Float(s.spectrumGain))),bw=sw/64
      spectrumBar(sx+(Float(i)+0.5)*bw,baseline-h/2,max(scale,bw-1.5*scale),h,blue,originY:baseline,radius:0)
    }
    let maximum=max(40,(audio?.sampleRate ?? 40000) / 2)
    for frequency in [20.0,200,1000,2000,5000,10000,20000] where frequency<=maximum {
      let x=sx+Float(log(frequency/20)/log(maximum/20))*sw
      let label=frequency>=1000 ? String(format:"%.0fk",frequency/1000):String(format:"%.0f",frequency)
      text(label,at:SIMD2(x,baseline+14*scale),size:8*scale,color:secondary)
    }
    if s.waveformVisible,let wave=audio?.waveform,!wave.isEmpty {
      let full=s.audioTemplate == .spectralField && !layout.portrait
      let x=full ? width*0.05:px,w=full ? width*0.90:pw
      let bins=min(wave.count,max(1,Int(w/(3*scale))))
      let progress=Float(max(0,min(1,audioTime/max(0.01,audio?.duration ?? 0))))
      for i in 0..<bins {
        let value=wave[min(wave.count-1,i*wave.count/bins)]
        let h=max(scale,min((s.audioTemplate == .recordSleeve ? 28:40)*scale,value*160*scale))
        var c=blue;c.w=Float(i)/Float(bins)<=progress ? 0.92:0.32
        add(x+(Float(i)+0.5)/Float(bins)*w,layout.waveformY,max(scale,w/Float(bins)-scale),h,c,radius:0)
      }
      add(x+progress*w,layout.waveformY,1.5*scale,34*scale,blue,radius:0)
    }
    if s.audioMetadataVisible,let audio=audio {
      let full=s.audioTemplate == .spectralField && !layout.portrait
      let session=full || s.audioTemplate == .recordSleeve
      let xs:[Float]=full ? [width*0.38,width*0.61,width*0.84]:[px+pw*0.16,px+pw*0.50,px+pw*0.84]
      let labels=session ? ["POSITION / 位置","RMS ESTIMATE / 均方根","SOURCE / 音源"]:["RMS / 均方根","DYNAMIC / 动态估计","QUALITY / 音质"]
      let quality=String(format:"%.1f kHz · %d CH",audio.sampleRate/1000,audio.channels)
      let values=session ? [clock(max(0,audioTime))+" / "+clock(audio.duration),String(format:"%.1f dBFS",audio.rmsDB(at:audioTime)),quality]:[String(format:"%.1f dBFS",audio.rmsDB(at:audioTime)),String(format:"%.1f dB",audio.estimatedDynamicRangeDB),quality]
      for i in 0..<3 {
        text(labels[i],at:SIMD2(xs[i],layout.metricsY),size:8*scale,color:secondary,maxWidth:full ? width*0.2:pw*0.30)
        text(values[i],at:SIMD2(xs[i],layout.metricsY+23*scale),size:full ? 15*scale:14*scale,color:blue,maxWidth:full ? width*0.21:pw*0.30)
      }
      text("SHORT-WINDOW RMS ESTIMATE · 非 LUFS 测量",at:SIMD2(px+pw/2,layout.noteY),size:7*scale,color:secondary,maxWidth:pw)
    }
  }
  func buildMetronome(at center:SIMD2<Float>,width:Float,time:Double,scale:Float,color:SIMD4<Float>) {
    let h=18*scale
    add(center.x,center.y,width,h,SIMD4(color.x,color.y,color.z,0.13),radius:0)
    for i in 0...8 {add(center.x-width/2+Float(i)/8*width,center.y,0.7*scale,h,SIMD4(color.x,color.y,color.z,0.25),radius:0)}
    var cursor=color;cursor.w=snapshot.musicalBeat(at:time) == nil ? 0.5:0.95
    let x=center.x-width/2+Float(snapshot.metronomePosition(at:time))*width
    add(x,center.y,3*scale,h,cursor,radius:0)
  }
  func spectrumBar(_ x:Float,_ y:Float,_ width:Float,_ height:Float,_ color:SIMD4<Float>,originY:Float,radius:Float) {
    let before=instances.count
    add(x,y,width,height,color,kind:14,radius:radius)
    if instances.count>before {
      instances[before].extra.y=Float(snapshot.settings.spectrumDepth)
      instances[before].extra.z=Float(snapshot.settings.spectrumTilt * .pi/180)
      instances[before].extra.w=originY
    }
  }
  func clock(_ seconds:Double) -> String {
    let t=Int(max(0,seconds));return String(format:"%d:%02d",t/60,t%60)
  }
}
