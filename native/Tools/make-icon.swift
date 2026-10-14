import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
let directory=root.appendingPathComponent("build/LumaScore.iconset")
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
func color(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat)->CGColor {CGColor(red:r,green:g,blue:b,alpha:1)}
func draw(_ size:Int,_ name:String)throws {
  let space=CGColorSpaceCreateDeviceRGB()
  let c=CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  c.scaleBy(x:CGFloat(size)/1024,y:CGFloat(size)/1024)
  c.addPath(CGPath(roundedRect:CGRect(x:40,y:40,width:944,height:944),cornerWidth:210,cornerHeight:210,transform:nil))
  c.clip()
  let gradient=CGGradient(colorsSpace:space,colors:[color(0.035,0.065,0.14),color(0.08,0.17,0.25)] as CFArray,locations:[0,1])!
  c.drawLinearGradient(gradient,start:CGPoint(x:0,y:1024),end:CGPoint(x:1024,y:0),options:[])
  c.setLineCap(.round);c.setLineWidth(38)
  for (i,h) in [150,270,410,300,180].enumerated() {
    c.setStrokeColor(color(0.26+CGFloat(i)*0.035,0.88-CGFloat(i)*0.035,1))
    c.move(to:CGPoint(x:440+i*90,y:470));c.addLine(to:CGPoint(x:440+i*90,y:470+h));c.strokePath()
  }
  c.setStrokeColor(color(0.91,0.97,1));c.setLineWidth(82)
  c.move(to:CGPoint(x:270,y:770));c.addLine(to:CGPoint(x:270,y:260));c.addLine(to:CGPoint(x:755,y:260));c.strokePath()
  let image=c.makeImage()!
  let url=directory.appendingPathComponent(name)
  let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
  CGImageDestinationAddImage(destination,image,nil)
  guard CGImageDestinationFinalize(destination) else {throw NSError(domain:"Icon",code:1)}
}
for size in [16,32,128,256,512] {
 try draw(size,"icon_\(size)x\(size).png")
 try draw(size*2,"icon_\(size)x\(size)@2x.png")
}
let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/iconutil")
process.arguments=["-c","icns",directory.path,"-o",root.appendingPathComponent("icon.icns").path]
try process.run();process.waitUntilExit()
if process.terminationStatus != 0 {throw NSError(domain:"Icon",code:Int(process.terminationStatus),userInfo:[NSLocalizedDescriptionKey:"iconutil failed; PNG iconset was retained in build/LumaScore.iconset"])}
print("Created LumaScore icon.icns")
