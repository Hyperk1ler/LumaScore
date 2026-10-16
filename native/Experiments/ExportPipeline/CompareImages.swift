import AppKit
import Foundation
func rgba(_ path: String) throws -> (Int, Int, [UInt8]) {
  let bitmap = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath:path)))!
  let cg = bitmap.cgImage!, width = cg.width, height = cg.height
  var bytes = [UInt8](repeating: 0, count: width*height*4)
  bytes.withUnsafeMutableBytes { data in
    let context = CGContext(data:data.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
      space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(cg,in:CGRect(x:0,y:0,width:width,height:height))
  }
  return (width,height,bytes)
}
let a = try rgba(CommandLine.arguments[1]), b = try rgba(CommandLine.arguments[2])
guard a.0==b.0,a.1==b.1 else {fatalError("Different dimensions")}
var differences=[Int](repeating:0,count:256),sum=0,square=0,maximum=0
for i in a.2.indices where i%4 != 3 {
  let delta=abs(Int(a.2[i])-Int(b.2[i]));sum+=delta;square+=delta*delta;maximum=max(maximum,delta);differences[delta]+=1
}
let total=a.0*a.1*3, mse=Double(square)/Double(total), psnr=mse==0 ? 100:10*log10(255*255/mse)
var accumulated=0,p99=0
for i in 0..<256 {accumulated+=differences[i];if accumulated>=Int(Double(total)*0.99){p99=i;break}}
let result:[String:Any]=["width":a.0,"height":a.1,"meanAbs":Double(sum)/Double(total),"max":maximum,"p99":p99,"psnr":psnr,"over8Fraction":Double(differences.dropFirst(9).reduce(0,+))/Double(total)]
let data=try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])
print(String(data:data,encoding:.utf8)!)
