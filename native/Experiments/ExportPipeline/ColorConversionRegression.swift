import Foundation
import AVFoundation
import CoreVideo
import Metal

@main struct ColorConversionRegression {
  static let width = 704, height = 128
  static let colors: [[Int]] = [[0,0,0],[255,255,255],[255,0,0],[0,255,0],[0,0,255],
    [0,255,255],[255,0,255],[255,255,0],[64,64,64],[128,128,128],[192,192,192]]
  static func check(_ ok: Bool, _ message: String) throws {
    guard ok else { throw StudioError.message(message) }; print("PASS \(message)")
  }
  static func makePixel(_ format: OSType) throws -> CVPixelBuffer {
    var p: CVPixelBuffer?
    let attributes = [kCVPixelBufferMetalCompatibilityKey as String:true,
      kCVPixelBufferIOSurfacePropertiesKey as String:[:]] as CFDictionary
    guard CVPixelBufferCreate(nil,width,height,format,attributes,&p) == kCVReturnSuccess, let p else {
      throw StudioError.message("Pixel buffer allocation failed")
    }
    for (key,value) in [(kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2),
      (kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2),
      (kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2),
      (kCVImageBufferChromaLocationTopFieldKey,kCVImageBufferChromaLocation_Center),
      (kCVImageBufferChromaLocationBottomFieldKey,kCVImageBufferChromaLocation_Center)] {
      CVBufferSetAttachment(p,key,value,.shouldPropagate)
    }
    return p
  }
  static func encode(_ p: CVPixelBuffer, name: String) throws -> [UInt8] {
    let url=URL(fileURLWithPath:name); try? FileManager.default.removeItem(at:url)
    let writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
    let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,
      AVVideoWidthKey:width,AVVideoHeightKey:height,
      AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:24_000_000,AVVideoAllowFrameReorderingKey:false],
      AVVideoColorPropertiesKey:[AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey:AVVideoTransferFunction_ITU_R_709_2,AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2]])
    let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:nil)
    writer.add(input); guard writer.startWriting() else { throw writer.error! }; writer.startSession(atSourceTime:.zero)
    for i in 0..<20 {
      while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval:0.001) }
      guard adaptor.append(p,withPresentationTime:CMTime(value:Int64(i),timescale:60)) else { throw writer.error! }
    }
    input.markAsFinished(); let done=DispatchSemaphore(value:0)
    writer.finishWriting { done.signal() }; guard done.wait(timeout:.now()+30) == .success else { throw StudioError.message("Encode timeout") }
    guard writer.status == .completed else { throw writer.error! }
    let asset=AVURLAsset(url:url)
    let reader=try AVAssetReader(asset:asset)
    let output=AVAssetReaderTrackOutput(track:asset.tracks(withMediaType:.video).first!,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
    reader.add(output); guard reader.startReading(),let sample=output.copyNextSampleBuffer(),let decoded=CMSampleBufferGetImageBuffer(sample) else { throw StudioError.message("Decode failed") }
    CVPixelBufferLockBaseAddress(decoded,.readOnly); defer { CVPixelBufferUnlockBaseAddress(decoded,.readOnly) }
    let ptr=CVPixelBufferGetBaseAddress(decoded)!.assumingMemoryBound(to:UInt8.self), stride=CVPixelBufferGetBytesPerRow(decoded)
    return (0..<height).flatMap { Array(UnsafeBufferPointer(start:ptr+$0*stride,count:width*4)) }
  }
  static func main() throws {
    let snapshot=RenderSnapshot(tracks:[],styles:[:],settings:StudioSettings(),bpm:120,duration:1,minPitch:48,maxPitch:84,backgroundURL:nil)
    let renderer=try MetalSceneRenderer(snapshot:snapshot,backend:.legacy)
    var cache: CVMetalTextureCache?; CVMetalTextureCacheCreate(nil,nil,renderer.device,nil,&cache)
    let bgra=try makePixel(kCVPixelFormatType_32BGRA), nv12=try makePixel(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    CVPixelBufferLockBaseAddress(bgra,[])
    let ptr=CVPixelBufferGetBaseAddress(bgra)!.assumingMemoryBound(to:UInt8.self), stride=CVPixelBufferGetBytesPerRow(bgra)
    for y in 0..<height { for x in 0..<width {
      let c=colors[x/64], offset=y*stride+x*4
      ptr[offset]=UInt8(c[2]); ptr[offset+1]=UInt8(c[1]); ptr[offset+2]=UInt8(c[0]); ptr[offset+3]=255
    }}
    CVPixelBufferUnlockBaseAddress(bgra,[])
    var wrappers:[CVMetalTexture]=[]
    func texture(_ p: CVPixelBuffer,_ format: MTLPixelFormat,_ plane:Int,_ w:Int,_ h:Int,_ usage:MTLTextureUsage) throws -> MTLTexture {
      var cv:CVMetalTexture?
      guard CVMetalTextureCacheCreateTextureFromImage(nil,cache!,p,[kCVMetalTextureUsage as String:usage.rawValue] as CFDictionary,format,w,h,plane,&cv)==kCVReturnSuccess,
        let cv,let t=CVMetalTextureGetTexture(cv) else { throw StudioError.message("Texture creation failed") }
      wrappers.append(cv);return t
    }
    let source=try texture(bgra,.bgra8Unorm,0,width,height,.shaderRead)
    let y=try texture(nv12,.r8Unorm,0,width,height,.shaderWrite), uv=try texture(nv12,.rg8Unorm,1,width/2,height/2,.shaderWrite)
    let cb=renderer.queue.makeCommandBuffer()!, e=cb.makeComputeCommandEncoder()!
    e.setComputePipelineState(renderer.conversionPipeline);e.setTexture(source,index:0);e.setTexture(y,index:1);e.setTexture(uv,index:2)
    e.dispatchThreads(MTLSize(width:width/2,height:height/2,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:8,depth:1));e.endEncoding();cb.commit();cb.waitUntilCompleted()
    if let error=cb.error { throw error }
    CVPixelBufferLockBaseAddress(nv12,.readOnly)
    let yp=CVPixelBufferGetBaseAddressOfPlane(nv12,0)!.assumingMemoryBound(to:UInt8.self), up=CVPixelBufferGetBaseAddressOfPlane(nv12,1)!.assumingMemoryBound(to:UInt8.self)
    let ys=CVPixelBufferGetBytesPerRowOfPlane(nv12,0), us=CVPixelBufferGetBytesPerRowOfPlane(nv12,1)
    for (i,c) in colors.enumerated() {
      let r=Double(c[0])/255,g=Double(c[1])/255,b=Double(c[2])/255, l=0.2126*r+0.7152*g+0.0722*b
      let expected=[16+219*l,128+224*(b-l)/1.8556,128+224*(r-l)/1.5748]
      let x=i*64+32, actual=[Int(yp[64*ys+x]),Int(up[32*us+x]),Int(up[32*us+x+1])]
      try check(zip(actual,expected).allSatisfy { abs(Double($0.0)-$0.1)<=1 },"color \(c) BT.709 video-range Y/Cb/Cr \(actual)")
    }
    CVPixelBufferUnlockBaseAddress(nv12,.readOnly)
    let a=try encode(bgra,name:"colorbars-bgra.mp4"),b=try encode(nv12,name:"colorbars-nv12.mp4")
    var total=0, maximum=0, n=0
    for y in 8..<(height-8) { for x in 0..<width where x%64>8 && x%64<56 { for channel in 0..<3 {
      let p=(y*width+x)*4+channel,d=abs(Int(a[p])-Int(b[p]));total+=d;maximum=max(maximum,d);n+=1
    }}}
    let mean=Double(total)/Double(n);print("ROUNDTRIP BGRA/NV12 mean=\(mean) max=\(maximum)")
    try check(mean<=3 && maximum<=8,"H.264 roundtrip preserves flat color bars and grayscale")
    withExtendedLifetime(wrappers) {}; print("ALL COLOR CONVERSION REGRESSIONS PASSED")
  }
}
