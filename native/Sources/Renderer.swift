import AppKit
import MetalKit
import MetalPerformanceShaders
import simd

private let shaderSource = """
  #include <metal_stdlib>
  using namespace metal;
  struct Instance { float4 rect; float4 color; float4 params; float4 extra; };
  struct Uniforms { float4 viewport; float4 effects; float4 crt; float4 crt2; float4 grade; float4 grade2; float4 camera; };
  struct Raster { float4 position [[position]];float2 local;float2 uv;float2 halfSize;float4 color;float4 params;float4 extra; };
  vertex Raster sceneVertex(uint v [[vertex_id]],uint i [[instance_id]],const device Instance *instances [[buffer(0)]],constant Uniforms &u [[buffer(1)]]) {
      const float2 corners[6]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
      Instance a=instances[i];float2 q=corners[v];float2 p=a.rect.xy+q*a.rect.zw*0.5;
      if(int(a.params.x+0.1)==14) {
        float dy=p.y-a.extra.w;float z=dy*sin(a.extra.z)+a.extra.y*u.viewport.y*0.35;
        float perspective=(u.viewport.y*1.5)/max(u.viewport.y*0.4,u.viewport.y*1.5+z);
        p=float2(u.viewport.x*0.5+(p.x-u.viewport.x*0.5)*perspective,a.extra.w+dy*cos(a.extra.z)*perspective);
      }
      Raster out;out.position=float4(p.x/u.viewport.x*2-1,1-p.y/u.viewport.y*2,0,1);out.local=q*a.rect.zw*0.5;out.halfSize=a.rect.zw*0.5;out.uv=(q+1)*0.5;out.color=a.color;out.params=a.params;out.extra=a.extra;return out;
  }
  float roundedBox(float2 p,float2 b,float radius) {float2 q=abs(p)-b+radius;return length(max(q,0.0))+min(max(q.x,q.y),0.0)-radius;}
  struct SceneOutput { float4 color [[color(0)]]; float4 emission [[color(1)]]; };
  SceneOutput shadeScene(Raster in,texture2d<float> background,texture2d<float> title,texture2d<float> emoji,texture2d<float> atlas,texture2d<float> cover) {
      constexpr sampler linearSampler(filter::linear,address::clamp_to_edge);
      int kind=int(in.params.x+0.1);
      if(kind==16) {
        float3 tint=mix(float3(.055,.075,.12),float3(.14,.18,.25),in.uv.y);
        tint=mix(tint,float3(.52,.51,.43),smoothstep(.75,1.0,in.uv.y));
        return {float4(tint*in.color.a,in.color.a),float4(0)};
      }
      if(kind==15) {
        float2 p=in.uv*in.halfSize*2;
        float spacing=max(8.0,in.params.y);
        float2 cell=fmod(p,spacing), fineCell=fmod(p,spacing*0.25);
        float grid=1-smoothstep(0.35,1.1,min(min(cell.x,spacing-cell.x),min(cell.y,spacing-cell.y)));
        float fine=1-smoothstep(0.35,1.1,min(min(fineCell.x,spacing*0.25-fineCell.x),min(fineCell.y,spacing*0.25-fineCell.y)));
        float2 q=p-in.extra.xy;float r=length(q);float rings=0;
        for(int i=0;i<5;i++)rings=max(rings,1-smoothstep(0.4,1.2,abs(r-in.extra.z*(0.7+i*0.18))));
        float angle=atan2(q.y,q.x)+3.14159265, period=0.13089969;
        float d=fmod(angle,period);float tick=1-smoothstep(0.006,0.013,min(d,period-d));
        tick*=step(in.extra.z*1.01,r)*step(r,in.extra.z*1.04);
        float lines=in.color.a*(grid*0.08+fine*0.035+in.extra.w*(rings*0.12+tick*0.18));
        float noise=fract(sin(dot(floor(p),float2(127.1,311.7)))*43758.5453)-0.5;
        float grain=abs(noise)*in.params.w*0.13;
        return {float4(in.color.rgb*lines+float3(noise>0 ? grain:0),clamp(lines+grain,0.0,1.0)),float4(0)};
      }
      if(kind==8) {float2 uv=in.extra.xy+in.uv*in.extra.zw;float a=atlas.sample(linearSampler,uv).a*in.color.a;return {float4(in.color.rgb*a,a),float4(0)};}
      if(kind==12) {float2 q=in.uv-0.5;float angle=in.params.w;float2 uv=float2(q.x*cos(angle)-q.y*sin(angle),q.x*sin(angle)+q.y*cos(angle))*in.params.yz+0.5;float4 c=cover.sample(linearSampler,uv);return {float4(c.rgb*in.color.a,c.a*in.color.a),float4(0)};}
      if(kind==6) {float2 uv=(in.uv-0.5)*in.params.yz+0.5;float4 c=background.sample(linearSampler,uv);return {float4(c.rgb*c.a*in.color.a,c.a*in.color.a),float4(0)};}
      if(kind==7) {float4 c=in.params.w>0.5 ? emoji.sample(linearSampler,in.uv) : title.sample(linearSampler,in.uv);float4 color=float4(c.rgb*c.a,c.a);return {color,in.params.w>0.5 ? color:float4(0)};}
      float2 halfSize=max(in.halfSize-in.extra.x,float2(0.5));float2 p=in.local;float d;
      if(kind==1) d=length(p)-min(halfSize.x,halfSize.y);
      else if(kind==2) d=(abs(p.x)+abs(p.y)-min(halfSize.x,halfSize.y))*0.707;
      else if(kind==3) {float2 q=p/max(halfSize.x,halfSize.y);q.y=-q.y;q.x=abs(q.x);d=(q.x+q.y>1 ? length(q-float2(0.25,0.75))-0.353553 : length(q-float2(0,1))-1)*halfSize.x;}
      else if(kind==4) d=abs(length(p)-min(halfSize.x,halfSize.y))+1.0-in.params.y;
      else d=roundedBox(p,halfSize,min(in.params.y,min(halfSize.x,halfSize.y)));
      float aa=max(fwidth(d),0.65);float coverage=1-smoothstep(-aa,aa,d);
      if(kind==9) coverage=1-smoothstep(-aa,aa,abs(d)-max(0.8,in.params.w));
      if(kind==11) {float hash=fract(sin(dot(floor(in.local*1.1),float2(12.9898,78.233)))*43758.5453);coverage*=0.6+hash*0.4;}
      float3 tint=in.color.rgb;if(kind==10)tint*=0.45+0.55*in.uv.x;
      float halo=in.params.z*exp(-max(d,0.0)*0.14)*0.42;float alpha=clamp((coverage+halo)*in.color.a,0.0,1.0);
      float emissive=coverage*in.color.a*(in.params.z>0 ? 1.0:0.0);
      return {float4(tint*alpha,alpha),float4(tint*emissive,emissive)};
  }
  fragment float4 sceneFragment(Raster in [[stage_in]],texture2d<float> background [[texture(0)]],texture2d<float> title [[texture(1)]],texture2d<float> emoji [[texture(2)]],texture2d<float> atlas [[texture(3)]],texture2d<float> cover [[texture(4)]]) {return shadeScene(in,background,title,emoji,atlas,cover).color;}
  fragment SceneOutput glowSceneFragment(Raster in [[stage_in]],texture2d<float> background [[texture(0)]],texture2d<float> title [[texture(1)]],texture2d<float> emoji [[texture(2)]],texture2d<float> atlas [[texture(3)]],texture2d<float> cover [[texture(4)]]) {return shadeScene(in,background,title,emoji,atlas,cover);}
  struct PostRaster {float4 position [[position]];float2 uv;};
  vertex PostRaster postVertex(uint v [[vertex_id]]) {const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};PostRaster out;out.position=float4(p[v],0,1);out.uv=float2((p[v].x+1)*0.5,1-(p[v].y+1)*0.5);return out;}
  fragment float4 bloomExtract(PostRaster in [[stage_in]],texture2d<float> emission [[texture(0)]]) {
      constexpr sampler s(filter::linear,address::clamp_to_zero);
      float2 texel=1.0/float2(emission.get_width(),emission.get_height());
      float3 c=(emission.sample(s,in.uv+texel*float2(-1,-1)).rgb+emission.sample(s,in.uv+texel*float2(1,-1)).rgb+emission.sample(s,in.uv+texel*float2(-1,1)).rgb+emission.sample(s,in.uv+texel*float2(1,1)).rgb)*0.25;
      return float4(c,1);
  }
  float hashNoise(float2 p) {return fract(sin(dot(p,float2(127.1,311.7)))*43758.5453123);}
  fragment float4 postFragment(PostRaster in [[stage_in]],texture2d<float> scene [[texture(0)]],texture2d<float> bloom [[texture(1)]],constant Uniforms &u [[buffer(0)]]) {
      constexpr sampler s(filter::linear,address::clamp_to_zero);
      float time=u.viewport.z;float2 p=(in.uv-0.5)*2;
      float2 uv=0.5+p*(1.0+u.effects.x*u.effects.w*dot(p,p)*0.24)*0.5;
      uv=(uv-0.5)/(1+u.camera.z)+0.5+u.camera.xy;
      bool crt=u.crt2.z>0.5;
      if(crt){float band=floor(uv.y*240);float roll=exp(-pow((fract(uv.y-time*0.13)-0.5)*32,2));uv.x+=(hashNoise(float2(band,floor(time*24)))-0.5)*0.009*u.crt.z+sin(time*18)*roll*0.018*u.crt.z;}
      if(any(uv<float2(0))||any(uv>float2(1)))return float4(0,0,0,1);
      float shift=crt ? u.crt.w*0.004:0;
      float3 c=float3(scene.sample(s,uv+float2(shift,0)).r,scene.sample(s,uv).g,scene.sample(s,uv-float2(shift,0)).b);
      c+=u.effects.y>0 ? bloom.sample(s,uv).rgb*u.effects.y*4.5:float3(0);
      if(u.grade2.y>0.5){float grey=dot(c,float3(0.2126,0.7152,0.0722));c=mix(float3(grey),c,u.grade.z);c=(c-0.5)*u.grade.y+0.5+u.grade.x;float angle=u.grade.w;float3 axis=normalize(float3(1));c=c*cos(angle)+cross(axis,c)*sin(angle)+axis*dot(axis,c)*(1-cos(angle));float3 sep=float3(dot(c,float3(.393,.769,.189)),dot(c,float3(.349,.686,.168)),dot(c,float3(.272,.534,.131)));c=mix(c,sep,u.grade2.x);}
      if(crt){float scan=0.5+0.5*sin(uv.y*u.viewport.y*3.14159265);c*=1-u.crt.x*scan*0.42;float noise=hashNoise(floor(uv*u.viewport.xy)+floor(time*60)*17)-0.5;c+=noise*u.crt.y*0.3;c*=1+sin(time*47)*u.crt2.x*0.08;c*=1-u.crt2.y*pow(clamp(dot(p,p)*0.5,0.0,1.0),1.4)*0.65;}
      return float4(clamp(c,0.0,1.0)*u.effects.z,1);
  }
  """

struct GPUInstance {
  var rect: SIMD4<Float>
  var color: SIMD4<Float>
  var params: SIMD4<Float>
  var extra: SIMD4<Float>
}
struct GPUUniforms {
  var viewport: SIMD4<Float>
  var effects: SIMD4<Float>
  var crt: SIMD4<Float>
  var crt2: SIMD4<Float>
  var grade: SIMD4<Float>
  var grade2: SIMD4<Float>
  var camera: SIMD4<Float>
}
final class RendererMetrics {
  let lock = NSLock()
  var build = 0.0, gpu = 0.0, count = 0
  func record(cpu: Double, gpuTime: Double) {
    lock.lock()
    build += cpu
    gpu += gpuTime
    count += 1
    lock.unlock()
  }
  var means: (Double, Double) {
    lock.lock()
    defer { lock.unlock() }
    return count == 0 ? (0, 0) : (build / Double(count) * 1000, gpu / Double(count) * 1000)
  }
}

final class MetalSceneRenderer {
  let device: MTLDevice
  let queue: MTLCommandQueue
  let metrics = RendererMetrics()
  let scenePipeline: MTLRenderPipelineState, postPipeline: MTLRenderPipelineState
  let glowPipeline: MTLRenderPipelineState, extractPipeline: MTLRenderPipelineState
  var buffers: [MTLBuffer] = [], uniformBuffers: [MTLBuffer] = [],
    intermediates: [MTLTexture?] = [nil, nil, nil]
  struct BloomTargets {
    let emission: MTLTexture, input: MTLTexture, blurred: MTLTexture
    let blur: MPSImageGaussianBlur
    let radius: Float
  }
  var bloomTargets: [BloomTargets?] = [nil, nil, nil]
  let capacity = 65536
  var instances: [GPUInstance] = []
  var overlayStart=0
  var spectrumBands=Array(repeating:Float(0),count:64)
  var previousSpectrumBands=Array(repeating:Float(0),count:64)
  var snapshot: RenderSnapshot
  var indices: [NoteIndex] = []
  var backgroundTexture: MTLTexture, titleTexture: MTLTexture, emojiTexture: MTLTexture
  var coverTexture: MTLTexture
  var loadedCover: URL?
  var atlas: MTLTexture!
  var atlasX = 2, atlasY = 2, atlasRow = 0
  var textCache: [String: (SIMD4<Float>, SIMD2<Float>)] = [:]
  var chordTimeline: ChordTimeline?
  var trackIDs:[String]=[]
  var chordTrackIDs:[String]=[]
  let dummy: MTLTexture
  var titleDimensions = SIMD2<Float>(0, 0)
  var loadedBackground: URL?, loadedEmoji = ""
  init(snapshot: RenderSnapshot) throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw StudioError.message("此 Mac 无法使用 Metal 渲染")
    }
    self.device = device
    self.queue = queue
    self.snapshot = snapshot
    let library = try device.makeLibrary(source: shaderSource, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "sceneVertex")
    descriptor.fragmentFunction = library.makeFunction(name: "sceneFragment")
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    let blend = descriptor.colorAttachments[0]!
    blend.isBlendingEnabled = true
    blend.sourceRGBBlendFactor = .one
    blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
    blend.sourceAlphaBlendFactor = .one
    blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    scenePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    descriptor.fragmentFunction = library.makeFunction(name: "glowSceneFragment")
    descriptor.colorAttachments[1].pixelFormat = .bgra8Unorm
    let emissionBlend = descriptor.colorAttachments[1]!
    emissionBlend.isBlendingEnabled = true
    emissionBlend.sourceRGBBlendFactor = .one
    emissionBlend.destinationRGBBlendFactor = .one
    emissionBlend.sourceAlphaBlendFactor = .one
    emissionBlend.destinationAlphaBlendFactor = .one
    glowPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    let post = MTLRenderPipelineDescriptor()
    post.vertexFunction = library.makeFunction(name: "postVertex")
    post.fragmentFunction = library.makeFunction(name: "postFragment")
    post.colorAttachments[0].pixelFormat = .bgra8Unorm
    postPipeline = try device.makeRenderPipelineState(descriptor: post)
    post.fragmentFunction = library.makeFunction(name: "bloomExtract")
    extractPipeline = try device.makeRenderPipelineState(descriptor: post)
    let td = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
    td.storageMode = .shared
    guard let pixel = device.makeTexture(descriptor: td) else {
      throw StudioError.message("无法建立渲染纹理")
    }
    var blank: UInt32 = 0
    pixel.replace(
      region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &blank, bytesPerRow: 4)
    dummy = pixel
    backgroundTexture = pixel
    titleTexture = pixel
    emojiTexture = pixel
    coverTexture = pixel
    for _ in 0..<3 {
      guard
        let buffer = device.makeBuffer(
          length: capacity * MemoryLayout<GPUInstance>.stride, options: .storageModeShared),
        let uniform = device.makeBuffer(
          length: MemoryLayout<GPUUniforms>.stride, options: .storageModeShared)
      else { throw StudioError.message("无法建立帧缓冲") }
      buffers.append(buffer)
      uniformBuffers.append(uniform)
    }
    instances.reserveCapacity(8192)
    try update(snapshot, rebuild: true)
  }
  func update(_ value: RenderSnapshot, rebuild: Bool = false) throws {
    let ids=value.tracks.map{$0.id}
    let tracksChanged=rebuild || ids != trackIDs
    if tracksChanged {
      indices=value.tracks.map{NoteIndex($0.notes)}
      trackIDs=ids
    }
    if atlas == nil {resetAtlas()}
    if value.settings.chordEnabled {
      let timingChanged=value.settings.chordTrackIDs.contains { id in
        let offset=value.styles[id]?.timeOffset ?? 0
        return offset != (snapshot.styles[id]?.timeOffset ?? 0) || (offset != 0 && value.tempoScale != snapshot.tempoScale)
      }
      if tracksChanged || chordTimeline == nil || chordTrackIDs != value.settings.chordTrackIDs || timingChanged {
        chordTimeline=ChordAnalyzer.timeline(tracks:value.chordTracks,selectedIDs:Set(value.settings.chordTrackIDs))
        chordTrackIDs=value.settings.chordTrackIDs
      }
    } else {chordTimeline=nil}
    snapshot = value
    if value.coverURL != loadedCover {
      coverTexture = dummy
      if let url = value.coverURL { coverTexture = try MTKTextureLoader(device: device).newTexture(URL: url, options: [.SRGB:false,.generateMipmaps:false]) }
      loadedCover = value.coverURL
    }
    if value.backgroundURL != loadedBackground {
      backgroundTexture = dummy
      if let url = value.backgroundURL {
        backgroundTexture = try MTKTextureLoader(device: device).newTexture(
          URL: url, options: [.SRGB: false, .generateMipmaps: false])
      }
      loadedBackground = value.backgroundURL
    }
    if value.settings.emoji != loadedEmoji {
      emojiTexture = try makeText(value.settings.emoji, fontSize: 96, color: .white).0
      loadedEmoji = value.settings.emoji
    }
  }
  func makeText(_ text: String, fontSize: Double, color: NSColor) throws -> (
    MTLTexture, SIMD2<Float>
  ) {
    if text.isEmpty { return (dummy, .zero) }
    let string = NSAttributedString(
      string: text,
      attributes: [
        .font: FontCatalog.font(family:snapshot.settings.titleFont,size:CGFloat(fontSize),weight:.semibold), .foregroundColor: color,
      ])
    let size = string.size()
    let width = min(4096, max(1, Int(ceil(size.width)) + 8))
    let height = min(1024, max(1, Int(ceil(size.height)) + 8))
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw StudioError.message("无法生成标题纹理") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    string.draw(at: NSPoint(x: 4, y: 4))
    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage() else { throw StudioError.message("标题图像生成失败") }
    return (
      try MTKTextureLoader(device: device).newTexture(cgImage: image, options: [.SRGB: false]),
      SIMD2(Float(width), Float(height))
    )
  }
  func add(
    _ x: Float, _ y: Float, _ width: Float, _ height: Float, _ color: SIMD4<Float>, kind: Float = 0,
    radius: Float = 2, glow: Float = 0, aux: Float = 0, uv: SIMD2<Float> = SIMD2(1, 1)
  ) {
    guard instances.count < capacity else { return }
    let pad = glow > 0 ? Float(14) : 0
    instances.append(
      GPUInstance(
        rect: SIMD4(x, y, max(0.1, width) + pad * 2, max(0.1, height) + pad * 2), color: color,
        params: SIMD4(kind, (kind == 6 || kind == 12) ? uv.x : radius, (kind == 6 || kind == 12) ? uv.y : glow, aux),
        extra: SIMD4(pad, 0, 0, 0)))
  }
  func valueAt(_ list: [MIDIControl], _ time: Double) -> Float {
    let i = lowerBound(list, time.nextUp, key: { $0.time })
    return i > 0 ? list[i - 1].value : 0
  }
  func build(time: Double, width: Float, height: Float) {
    instances.removeAll(keepingCapacity: true)
    if atlasY > 3000 || textCache.count > 1800 { resetAtlas() }
    let settings = snapshot.settings
    let scale = height / 720
    let t = (time - settings.intro + settings.offset) / snapshot.tempoScale
    let camera = SceneViewport(snapshot: snapshot, width: Double(width), height: Double(height))
    let playhead = Float(camera.playheadX)
    let pps = Float(camera.pixelsPerSecond)
    let from = t - Double(playhead / pps) - 0.7
    let to = t + Double((width - playhead) / pps) + 0.1
    let low = min(snapshot.minPitch - 3, 48)
    let high = max(snapshot.maxPitch + 3, 84)
    func yFor(_ pitch: Float) -> Float { Float(camera.y(pitch: Double(pitch))) }
    if backgroundTexture !== dummy {
      let imageRatio = Float(backgroundTexture.width) / Float(backgroundTexture.height)
      let canvasRatio = width / height
      let uv =
        imageRatio > canvasRatio
        ? SIMD2(canvasRatio / imageRatio, 1) : SIMD2(1, imageRatio / canvasRatio)
      add(width / 2, height / 2, width, height, SIMD4(1, 1, 1, Float(settings.backgroundOpacity)), kind: 6, uv: uv)
    }
    if settings.scene == .audio || (settings.scene == .hybrid && !settings.spectrumInFront) { buildAudio(time: time, width: width, height: height, compact: settings.scene == .hybrid) }
    if settings.grid && settings.scene != .audio {
      for pitch in stride(from: low, through: high, by: 12) {
        add(width / 2, yFor(Float(pitch)), width, scale, SIMD4(0.55, 0.68, 0.82, 0.10), radius: 0)
      }
      let beat = 60 / max(1, snapshot.bpm)
      let first = Int(floor(from / beat))
      for i in first...max(first, Int(ceil(to / beat))) {
        let x = playhead + Float(Double(i) * beat - t) * pps
        add(
          x, height / 2, scale, height, SIMD4(0.55, 0.68, 0.82, i % 4 == 0 ? 0.13 : 0.045),
          radius: 0)
      }
    }
    let hasSolo = snapshot.tracks.contains { snapshot.styles[$0.id]?.solo == true }
    for (trackIndex, track) in snapshot.tracks.enumerated() where settings.scene != .audio {
      let style =
        snapshot.styles[track.id] ?? TrackStyle(color: RGB.palette[trackIndex % RGB.palette.count])
      if style.muted || (hasSolo && !style.solo) { continue }
      let t=snapshot.trackTime(track.id,at:time)
      let playhead=playhead+Float(style.horizontalOffset)*width
      let bend = valueAt(track.bends, t) * Float(settings.bendDepth)
      let mod = valueAt(track.modulation, t) * Float(settings.modulationDepth)
      let vibrato = mod * sin(Float(t) * 12 * .pi) * 0.2
      let layerScale=1-Float(settings.depth*2)*(1-exp(-Float(trackIndex)*0.25))*0.28
      let trackPPS=pps*(1-Float(settings.depth*2)*(1-exp(-Float(trackIndex)*0.25))*0.45)*Float(style.flowSpeed)
      let color = style.color.vector
      let glow = settings.bloomEnabled ? Float(style.glow ?? settings.glow) : 0
      let thickness = Float(style.thickness ?? settings.thickness) * scale
      let line = style.line ?? settings.lineStyle
      let marker = style.marker ?? settings.marker
      let ripple = style.ripple ?? settings.rippleStyle
      let motion = style.motion ?? settings.noteMotion
      let trackFrom=t-Double(playhead/trackPPS)-0.7
      let trackTo=t+Double((width-playhead)/trackPPS)+0.1
      indices[trackIndex].forEach(from: trackFrom, to: trackTo) { noteIndex, note in
        let x1 = playhead + Float(note.start - t) * trackPPS
        let x2 = playhead + Float(note.end - t) * trackPPS
        let active = time >= settings.intro && note.start <= t && note.end > t
        let age = max(0, Float(t - note.start))
        let y = height/2+(yFor(Float(note.pitch) + (active ? bend + vibrato : 0))-height/2)*layerScale+Float(style.verticalOffset)*height*0.5
        if y < -100 * scale || y > height + 100 * scale { return }
        let alpha: Float = active ? 1 : 0.68
        let start = max(-20, active && motion == .sink ? min(x2, playhead - (playhead-x1)*(1-Float(settings.reactionPosition))) : x1)
        let end = min(width + 20, x2)
        let barColor = SIMD4(color.x, color.y, color.z, alpha * (0.45 + note.velocity * 0.55))
        let kind: Float = line == .outline ? 9 : (line == .gradient ? 10 : (line == .brush ? 11 : 0))
        let radius: Float = settings.noteRoundness > 0 && line != .brush ? thickness / 2 * Float(settings.noteRoundness) : 0
        if active && motion == .pluck {
          let length = max(2,end-start)
          for segment in 0..<16 {
            let q = (Float(segment)+0.5)/16
            let delta = sin(q * .pi)*sin(age*24)*exp(-age*4)*20*scale*Float(settings.animationDepth)
            add(start+length*q,y+delta,length/16+1,thickness,barColor,kind:kind,radius:radius,glow:glow,aux:max(1,thickness*0.18))
          }
        } else {
          add((start+end)/2,y,max(2,end-start),thickness,barColor,kind:kind,radius:radius,glow:active ? glow:glow*0.25,aux:max(1,thickness*0.18))
        }
        if active {
          let size = Float(settings.markerSize) * scale
          if marker != .none {
            add(
              playhead, y, size * 2, size * 2, color, kind: marker.shape, radius: 2,
              glow: marker == .emoji ? 0 : glow, aux: 1)
          }
          if age < Float(settings.rippleDuration) && ripple != .none {
            let r = (size + age * 45 * scale) * Float(settings.rippleSize)
            add(
              playhead, y, r * 2, r * 2, SIMD4(color.x, color.y, color.z, (1 - age / Float(settings.rippleDuration)) * 0.35),
              kind: ripple == .ring ? 4 : (ripple == .flare ? 1 : 2), radius: 1.5 * scale, glow: glow * 0.3)
          }
          let count = Int(settings.particles * 8)
          if count > 0 {
            for p in 0..<count {
              let seed = Float((noteIndex * 719 + p * 131 + trackIndex * 17) % 997) / 997
              let phase = fmod(age + seed, 0.7)
              let angle = seed * Float.pi * 2
              let r = phase * 85 * scale
              add(
                playhead + cos(angle) * r, y + sin(angle) * r, 4 * scale, 4 * scale,
                SIMD4(color.x, color.y, color.z, (1 - phase / 0.7) * 0.65), kind: 1, glow: glow)
            }
          }
        }
      }
    }
    if settings.scene == .hybrid && settings.spectrumInFront {buildAudio(time:time,width:width,height:height,compact:true)}
    if settings.scene != .audio && settings.playheadVisible { var c=settings.playheadColor.vector;c.w=0.2;add(playhead,height/2,1.1*scale,height*0.83,c,radius:0) }
    buildAmbientParticles(time: time, width: width, height: height)
    if time >= settings.intro && settings.chordEnabled, let chord = chordTimeline?.chord(at:t) {
      var position=settings.chordPosition.point(width:width,height:height)
      position.y=max(height*0.17,min(height*0.82,position.y))
      if settings.scene == .audio && [.bottomLeft,.bottomCenter].contains(settings.chordPosition) {
        position=AudioSceneLayout(settings:settings,width:width,height:height).chordPoint
      }
      let cardWidth=min(width*0.38,Float(settings.chordSize)*scale*7)
      if settings.scene != .audio {add(position.x,position.y+Float(settings.chordSize)*scale*0.3,cardWidth,Float(settings.chordSize)*scale*1.8,SIMD4(0.02,0.04,0.08,0.72),radius:8*scale)}
      if settings.scene == .audio && settings.audioTemplate == .recordSleeve && width >= height && [.bottomLeft,.bottomCenter].contains(settings.chordPosition) {
        let layout=AudioSceneLayout(settings:settings,width:width,height:height)
        let x=Float(layout.cover.minX)
        text(chord.name,at:SIMD2(x,position.y),size:Float(settings.chordSize)*scale,color:settings.chordColor.vector,font:settings.chordFont,maxWidth:Float(layout.cover.width)*0.44,alignedLeft:true)
        text("HARMONY / 和弦",at:SIMD2(x+Float(layout.cover.width)*0.48,position.y-10*scale),size:8*scale,color:SIMD4(0.57,0.67,0.74,0.9),alignedLeft:true)
        text(chord.components,at:SIMD2(x+Float(layout.cover.width)*0.48,position.y+10*scale),size:Float(settings.chordSize)*scale*0.35,color:settings.chordColor.vector,font:settings.chordFont,maxWidth:Float(layout.cover.width)*0.52,alignedLeft:true)
      } else {
        text(chord.name,at:position,size:Float(settings.chordSize)*scale,color:settings.chordColor.vector,font:settings.chordFont)
        text(chord.components,at:position+SIMD2(0,Float(settings.chordSize)*scale*0.85),size:Float(settings.chordSize)*scale*0.42,color:settings.chordColor.vector,font:settings.chordFont)
      }
    }
    if settings.titleEnabled && !settings.title.isEmpty && settings.scene != .audio {
      let pos=settings.titlePosition.point(width:width,height:height)
      let phase=Float(min(1,max(0,time/settings.titleMotionDuration)))
      let out=Float(min(1,max(0,(snapshot.timelineDuration(audioDuration:snapshot.audioVisualization?.duration ?? 0)-time)/0.75)))
      var color=settings.titleColor.vector
      if settings.titleMotion != .none { color.w=min(phase,out) }
      let shift: Float = settings.titleMotion == .slide ? (1-phase)*30*scale:0
      let fontScale: Float = settings.titleMotion == .scale ? 0.7+phase*0.3:1
      let title=settings.titleMotion == .typewriter ? String(settings.title.prefix(Int(Float(settings.title.count)*phase))) : settings.title
      text(title,at:pos+SIMD2(0,shift),size:Float(settings.titleSize)*scale*fontScale,color:color,font:settings.titleFont,maxWidth:width*0.86)
    }
    overlayStart=instances.count
  }

  /// Preview and export share the scene, optional quarter-resolution bloom, and compositing.
  func encode(
    target: MTLTexture, time: Double, slot: Int, fade: Float = 1, drawable: CAMetalDrawable? = nil,
    completion: @escaping (Error?) -> Void
  ) throws {
    let began = ProcessInfo.processInfo.systemUptime
    let width = target.width
    let height = target.height
    build(time: time, width: Float(width), height: Float(height))
    let buffer = buffers[slot]
    for i in overlayStart..<instances.count { instances[i].color.w *= fade }
    instances.withUnsafeBytes { raw in
      if let base = raw.baseAddress { memcpy(buffer.contents(), base, raw.count) }
    }
    var uniform = GPUUniforms(
      viewport: SIMD4(Float(width), Float(height), Float(time), 1),
      effects: SIMD4(Float(snapshot.settings.fisheye), snapshot.settings.bloomEnabled ? Float(snapshot.settings.glow):0, fade, snapshot.settings.lensMode == .pincushion ? 1:-1),
      crt: SIMD4(Float(snapshot.settings.crtScanlines),Float(snapshot.settings.crtNoise),Float(snapshot.settings.crtJitter),Float(snapshot.settings.crtChromatic)),
      crt2: SIMD4(Float(snapshot.settings.crtFlicker),Float(snapshot.settings.crtVignette),snapshot.settings.crtEnabled ? 1:0,Float(snapshot.settings.intro)),
      grade: SIMD4(Float(snapshot.settings.brightness),Float(snapshot.settings.contrast),Float(snapshot.settings.saturation),Float(snapshot.settings.hue * .pi/180)),
      grade2: SIMD4(Float(snapshot.settings.sepia),snapshot.settings.colorFilterEnabled ? 1:0,0,0),
      camera: cameraReaction(time:time))
    memcpy(uniformBuffers[slot].contents(), &uniform, MemoryLayout<GPUUniforms>.stride)
    let settings=snapshot.settings
    let glowEnabled=settings.bloomEnabled && settings.glow > 0
    let graded=settings.colorFilterEnabled && (settings.brightness != 0 || settings.contrast != 1 || settings.saturation != 1 || settings.hue != 0 || settings.sepia != 0)
    let direct = !glowEnabled && !graded && !settings.crtEnabled && settings.fisheye == 0 && settings.cameraShake == 0 && settings.cameraPunch == 0 && fade == 1
    if !direct && (intermediates[slot]?.width != width || intermediates[slot]?.height != height) {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
      descriptor.usage = [.renderTarget, .shaderRead]
      descriptor.storageMode = .private
      intermediates[slot] = device.makeTexture(descriptor: descriptor)
    }
    if glowEnabled {
      let radius = Float(snapshot.settings.glowRadius) * Float(height) / 720 / 4
      if bloomTargets[slot]?.emission.width != width
        || bloomTargets[slot]?.emission.height != height || bloomTargets[slot]?.radius != radius
      {
        func texture(_ w: Int, _ h: Int) -> MTLTexture? {
          let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
          d.usage = [.renderTarget, .shaderRead, .shaderWrite]
          d.storageMode = .private
          return device.makeTexture(descriptor: d)
        }
        guard let emission = texture(width, height),
          let input = texture(max(1, width / 4), max(1, height / 4)),
          let blurred = texture(max(1, width / 4), max(1, height / 4))
        else { throw StudioError.message("无法分配光晕缓冲") }
        let blur = MPSImageGaussianBlur(device: device, sigma: max(0.5, radius))
        blur.edgeMode = .clamp
        bloomTargets[slot] = BloomTargets(
          emission: emission, input: input, blurred: blurred, blur: blur, radius: radius)
      }
    }
    guard let scene = direct ? target:intermediates[slot], let command = queue.makeCommandBuffer() else {
      throw StudioError.message("无法提交 GPU 帧")
    }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = scene
    let bg = snapshot.settings.background
    pass.colorAttachments[0].clearColor = MTLClearColor(
      red: Double(bg.r), green: Double(bg.g), blue: Double(bg.b), alpha: 1)
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    if glowEnabled, let bloom = bloomTargets[slot] {
      pass.colorAttachments[1].texture = bloom.emission
      pass.colorAttachments[1].loadAction = .clear
      pass.colorAttachments[1].storeAction = .store
      pass.colorAttachments[1].clearColor = MTLClearColorMake(0, 0, 0, 0)
    }
    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
      throw StudioError.message("无法开始场景渲染")
    }
    encoder.setRenderPipelineState(glowEnabled ? glowPipeline : scenePipeline)
    encoder.setVertexBuffer(buffer, offset: 0, index: 0)
    encoder.setVertexBuffer(uniformBuffers[slot], offset: 0, index: 1)
    encoder.setFragmentTexture(backgroundTexture, index: 0)
    encoder.setFragmentTexture(titleTexture, index: 1)
    encoder.setFragmentTexture(emojiTexture, index: 2)
    encoder.setFragmentTexture(atlas, index: 3)
    encoder.setFragmentTexture(coverTexture, index: 4)
    if !instances.isEmpty {
      encoder.drawPrimitives(
        type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: overlayStart)
    }
    encoder.endEncoding()
    if glowEnabled, let bloom = bloomTargets[slot] {
      let extractPass = MTLRenderPassDescriptor()
      extractPass.colorAttachments[0].texture = bloom.input
      extractPass.colorAttachments[0].loadAction = .dontCare
      extractPass.colorAttachments[0].storeAction = .store
      guard let extraction = command.makeRenderCommandEncoder(descriptor: extractPass) else {
        throw StudioError.message("无法提取光晕画面")
      }
      extraction.setRenderPipelineState(extractPipeline)
      extraction.setFragmentTexture(bloom.emission, index: 0)
      extraction.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      extraction.endEncoding()
      bloom.blur.encode(
        commandBuffer: command, sourceTexture: bloom.input, destinationTexture: bloom.blurred)
    }
    if !direct {
    let postPass = MTLRenderPassDescriptor()
    postPass.colorAttachments[0].texture = target
    postPass.colorAttachments[0].loadAction = .dontCare
    postPass.colorAttachments[0].storeAction = .store
    guard let postEncoder = command.makeRenderCommandEncoder(descriptor: postPass) else {
      throw StudioError.message("无法开始画面处理")
    }
    postEncoder.setRenderPipelineState(postPipeline)
    postEncoder.setFragmentTexture(scene, index: 0)
    postEncoder.setFragmentTexture(glowEnabled ? bloomTargets[slot]!.blurred : dummy, index: 1)
    postEncoder.setFragmentBuffer(uniformBuffers[slot], offset: 0, index: 0)
    postEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    postEncoder.endEncoding()
    }
    if instances.count > overlayStart {
      let overlayPass=MTLRenderPassDescriptor()
      overlayPass.colorAttachments[0].texture=target
      overlayPass.colorAttachments[0].loadAction = .load
      overlayPass.colorAttachments[0].storeAction = .store
      if let overlay=command.makeRenderCommandEncoder(descriptor:overlayPass) {
        overlay.setRenderPipelineState(scenePipeline)
        overlay.setVertexBuffer(buffer,offset:0,index:0)
        overlay.setVertexBuffer(uniformBuffers[slot],offset:0,index:1)
        overlay.setFragmentTexture(backgroundTexture,index:0)
        overlay.setFragmentTexture(titleTexture,index:1)
        overlay.setFragmentTexture(emojiTexture,index:2)
        overlay.setFragmentTexture(atlas,index:3)
        overlay.setFragmentTexture(coverTexture,index:4)
        overlay.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:6,instanceCount:instances.count-overlayStart,baseInstance:overlayStart)
        overlay.endEncoding()
      }
    }
    if let drawable = drawable { command.present(drawable) }
    let cpu = ProcessInfo.processInfo.systemUptime - began
    command.addCompletedHandler { [metrics] completed in
      metrics.record(cpu: cpu, gpuTime: max(0, completed.gpuEndTime - completed.gpuStartTime))
      completion(completed.error)
    }
    command.commit()
  }
}
