import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
let base=URL(fileURLWithPath:CommandLine.arguments[1]),dest=URL(fileURLWithPath:CommandLine.arguments[2])
func export(_ asset:AVAsset,_ preset:String,_ url:URL,_ type:AVFileType) {
    try? FileManager.default.removeItem(at:url)
    let e=AVAssetExportSession(asset:asset,presetName:preset)!;e.outputURL=url;e.outputFileType=type;e.shouldOptimizeForNetworkUse=true
    let sem=DispatchSemaphore(value:0);e.exportAsynchronously{sem.signal()};sem.wait()
    guard e.status == .completed else {fatalError(e.error?.localizedDescription ?? "Export failed")}
}
if !CommandLine.arguments.contains("--check") {
    let a=AVURLAsset(url:base.appendingPathComponent("score.wav"));export(a,AVAssetExportPresetAppleM4A,base.appendingPathComponent("score.m4a"),.m4a)
    let video=AVURLAsset(url:base.appendingPathComponent("film-silent.mp4")),audio=AVURLAsset(url:base.appendingPathComponent("score.m4a")),comp=AVMutableComposition()
    let v=comp.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid)!,at=comp.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid)!
    try v.insertTimeRange(CMTimeRange(start:.zero,duration:video.duration),of:video.tracks(withMediaType:.video)[0],at:.zero)
    try at.insertTimeRange(CMTimeRange(start:.zero,duration:video.duration),of:audio.tracks(withMediaType:.audio)[0],at:.zero)
    export(comp,AVAssetExportPresetPassthrough,dest,.mp4)
}
let final=AVURLAsset(url:dest),track=final.tracks(withMediaType:.video)[0]
print("Video",track.naturalSize,"fps",track.nominalFrameRate,"duration",final.duration.seconds,"audio",final.tracks(withMediaType:.audio).count)
let reader=try AVAssetReader(asset:final),output=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
reader.add(output);reader.startReading();var count=0,last = -1.0,first=0.0
while let sample=output.copyNextSampleBuffer(){let t=CMSampleBufferGetPresentationTimeStamp(sample).seconds;guard t>last else {fatalError("Nonmonotonic frame timestamps")};if count==0{first=t};last=t;count+=1}
guard reader.status == .completed && count==2640 && abs(final.duration.seconds-44)<0.05 && final.tracks(withMediaType:.audio).count==1 else {fatalError("Final media validation failed")}
print("PASS: decoded sample table",count,"frames; first",first,"last",last)
let generator=AVAssetImageGenerator(asset:final);generator.appliesPreferredTrackTransform=true;generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
let frames=base.appendingPathComponent("verified-frames");try FileManager.default.createDirectory(at:frames,withIntermediateDirectories:true)
for t in [2.8,7.7,14.8,20.9,23.8,28.8,35.9,42.0] {let img=try generator.copyCGImage(at:CMTime(seconds:t,preferredTimescale:600),actualTime:nil);let url=frames.appendingPathComponent(String(format:"%04.1f.png",t));let d=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!;CGImageDestinationAddImage(d,img,nil);CGImageDestinationFinalize(d)}
print("PASS: final MP4 representative frames extracted")
