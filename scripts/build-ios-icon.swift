// Export the existing Notebook icon as an opaque, full-size iOS asset.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: build-ios-icon.swift source.png output.png")
}
let sourceURL = URL(fileURLWithPath:CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath:CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL,nil),
      let image = CGImageSourceCreateImageAtIndex(source,0,nil),
      let space = CGColorSpace(name:CGColorSpace.sRGB),
      let context = CGContext(data:nil,width:1024,height:1024,bitsPerComponent:8,bytesPerRow:0,
                              space:space,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Could not load the Notebook icon or create its export context.")
}
let bounds = CGRect(x:0,y:0,width:1024,height:1024)
context.setFillColor(CGColor(red:0.961,green:0.961,blue:0.953,alpha:1))
context.fill(bounds)
context.draw(image,in:bounds)
try FileManager.default.createDirectory(at:outputURL.deletingLastPathComponent(),withIntermediateDirectories:true)
guard let result = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL,UTType.png.identifier as CFString,1,nil) else {
    fatalError("Could not create the iOS icon file.")
}
CGImageDestinationAddImage(destination,result,nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write the iOS icon file.") }
