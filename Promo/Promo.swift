import AppKit
import CoreText
import AVFoundation
import VideoToolbox
import ImageIO
import UniformTypeIdentifiers

let W = 1920, H = 1080
let duration = 44.0, fps = 60
let root = URL(fileURLWithPath:CommandLine.arguments[1])
let out = URL(fileURLWithPath:CommandLine.arguments[2])
_ = NSApplication.shared
func clamp01(_ x:Double)->Double { max(0,min(1,x)) }
func ease(_ x:Double)->Double { let v=clamp01(x);return 1-pow(1-v,3) }
func smooth(_ x:Double)->Double { let v=clamp01(x);return v*v*(3-2*v) }
func mix(_ a:Double,_ b:Double,_ u:Double)->Double { a+(b-a)*u }
func color(_ hex:Int,_ a:Double=1)->CGColor { CGColor(red:Double((hex>>16)&255)/255,green:Double((hex>>8)&255)/255,blue:Double(hex&255)/255,alpha:a) }
let ink=0x191A1E, gray=0x7D7F88, accent=0x795BF2, pale=0xEFEBFE
func cg(_ path:String)->CGImage { CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil)!,0,nil)! }
func savePNG(_ img:CGImage,_ path:URL) { let d=CGImageDestinationCreateWithURL(path as CFURL,UTType.png.identifier as CFString,1,nil)!; CGImageDestinationAddImage(d,img,nil); CGImageDestinationFinalize(d) }
func bitmap(_ width:Int,_ height:Int)->CGContext { CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue)! }

final class Canvas {
    let c:CGContext
    private var opacity=1.0
    init(_ c:CGContext) { self.c=c; c.translateBy(x:0,y:CGFloat(H)); c.scaleBy(x:1,y:-1); c.setAllowsAntialiasing(true); c.interpolationQuality = .high }
    func group(_ alpha:Double=1,_ body:()->Void) { c.saveGState();let old=opacity;opacity *= alpha;c.setAlpha(opacity);body();opacity=old;c.restoreGState() }
    func rrect(_ x:Double,_ y:Double,_ w:Double,_ h:Double,_ r:Double,_ fill:Int,_ alpha:Double=1) { c.setFillColor(color(fill,alpha)); c.addPath(CGPath(roundedRect:CGRect(x:x,y:y,width:w,height:h),cornerWidth:r,cornerHeight:r,transform:nil));c.fillPath() }
    func strokeRect(_ x:Double,_ y:Double,_ w:Double,_ h:Double,_ r:Double,_ col:Int,_ width:Double=1,_ alpha:Double=1) { c.setStrokeColor(color(col,alpha));c.setLineWidth(width);c.addPath(CGPath(roundedRect:CGRect(x:x,y:y,width:w,height:h),cornerWidth:r,cornerHeight:r,transform:nil));c.strokePath() }
    func circle(_ x:Double,_ y:Double,_ radius:Double,_ fill:Int,_ alpha:Double=1) { c.setFillColor(color(fill,alpha));c.fillEllipse(in:CGRect(x:x-radius,y:y-radius,width:radius*2,height:radius*2)) }
    func line(_ x:Double,_ y:Double,_ xx:Double,_ yy:Double,_ col:Int,_ width:Double=1,_ alpha:Double=1) { c.setStrokeColor(color(col,alpha));c.setLineWidth(width);c.setLineCap(.round);c.move(to:CGPoint(x:x,y:y));c.addLine(to:CGPoint(x:xx,y:yy));c.strokePath() }
    func arc(_ x:Double,_ y:Double,_ radius:Double,_ progress:Double,_ col:Int,_ width:Double,_ alpha:Double=1,_ start:Double = -Double.pi/2) { c.setStrokeColor(color(col,alpha));c.setLineWidth(width);c.setLineCap(.round);c.addArc(center:CGPoint(x:x,y:y),radius:radius,startAngle:start,endAngle:start+Double.pi*2*progress,clockwise:false);c.strokePath() }
    func image(_ image:CGImage,_ x:Double,_ y:Double,_ w:Double,_ h:Double,_ alpha:Double=1) { c.saveGState();c.setAlpha(opacity*alpha);c.translateBy(x:x,y:y+h);c.scaleBy(x:1,y:-1);c.draw(image,in:CGRect(x:0,y:0,width:w,height:h));c.restoreGState() }
    func shadow(_ x:Double,_ y:Double,_ w:Double,_ h:Double,_ radius:Double=30) { c.saveGState();c.setShadow(offset:CGSize(width:0,height:16),blur:34,color:color(0x242336,0.09));rrect(x,y,w,h,radius,0xFFFFFF);c.restoreGState() }
    @discardableResult func text(_ s:String,_ x:Double,_ y:Double,_ size:Double,_ weight:NSFont.Weight = .regular,_ col:Int=ink,_ align:String="left",_ alpha:Double=1)->Double {
        let img=Assets.shared.text(s,size,weight,col);let w=Double(img.width)/2,h=Double(img.height)/2
        let left=align == "center" ? x-w/2 : align == "right" ? x-w:x
        image(img,left,y,w,h,alpha);return w
    }
    func icon(_ name:String,_ x:Double,_ y:Double,_ size:Double,_ col:Int=ink,_ alpha:Double=1) {
        let img=Assets.shared.symbol(name)
        let f=size/max(Double(img.width),Double(img.height)),w=Double(img.width)*f,h=Double(img.height)*f
        c.saveGState();c.setAlpha(opacity*alpha);c.translateBy(x:x-w/2,y:y+h/2);c.scaleBy(x:1,y:-1);c.clip(to:CGRect(x:0,y:0,width:w,height:h),mask:img);c.setFillColor(color(col));c.fill(CGRect(x:0,y:0,width:w,height:h));c.restoreGState()
    }
    func mouse(_ x:Double,_ y:Double,_ h:Double,_ angle:Bool=true,_ alpha:Double=1) {
        let img=angle ? Assets.shared.mouse:Assets.shared.top
        let w=h*Double(img.width)/Double(img.height)
        image(img,x,y,w,h,alpha)
    }
    func pointer(_ x:Double,_ y:Double,_ scale:Double=1,_ alpha:Double=1) {
        group(alpha) { c.saveGState();c.translateBy(x:x,y:y);c.scaleBy(x:scale,y:scale);c.setShadow(offset:CGSize(width:0,height:2),blur:4,color:color(0,0.16));let p=CGMutablePath();p.move(to:.zero);p.addLine(to:CGPoint(x:0,y:34));p.addLine(to:CGPoint(x:9,y:25));p.addLine(to:CGPoint(x:15,y:39));p.addLine(to:CGPoint(x:22,y:36));p.addLine(to:CGPoint(x:16,y:22));p.addLine(to:CGPoint(x:30,y:22));p.closeSubpath();c.addPath(p);c.setFillColor(color(ink));c.setStrokeColor(color(0xFFFFFF));c.setLineWidth(2);c.drawPath(using:.fillStroke);c.restoreGState() }
    }
}
final class Assets {
    static let shared=Assets()
    var texts:[String:CGImage]=[:],symbols:[String:CGImage]=[:]
    let mouse:CGImage,top:CGImage,side:CGImage
    lazy var background:CGImage=makeBackground()
    lazy var mac:CGImage=makeMac()
    init() {
        mouse=Self.makeMouse(tilt:0.075); top=Self.makeMouse(tilt:0); side=Self.makeMouse(tilt:-0.14)
    }
    // Original vector illustration of an ergonomic multi-button mouse.
    // No manufacturer render, photograph, traced path or brand logo is embedded.
    static func makeMouse(tilt:Double)->CGImage {
        let c=bitmap(800,1080),v=Canvas(c)
        c.saveGState();c.translateBy(x:400,y:550);c.rotate(by:tilt);c.translateBy(x:-400,y:-550)
        func shape(_ body:(CGMutablePath)->Void,_ top:Int,_ bottom:Int) {
            let p=CGMutablePath();body(p);p.closeSubpath()
            c.saveGState();c.addPath(p);c.clip()
            let gradient=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:[color(top),color(bottom)] as CFArray,locations:[0,1])!
            c.drawLinearGradient(gradient,start:CGPoint(x:170,y:110),end:CGPoint(x:660,y:900),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation]);c.restoreGState()
            c.addPath(p);c.setStrokeColor(color(0x15161A,0.7));c.setLineWidth(1.5);c.strokePath()
        }
        c.saveGState();c.setShadow(offset:CGSize(width:15,height:25),blur:32,color:color(0,0.2))
        shape({p in p.move(to:CGPoint(x:411,y:80));p.addCurve(to:CGPoint(x:684,y:704),control1:CGPoint(x:592,y:77),control2:CGPoint(x:671,y:406));p.addCurve(to:CGPoint(x:417,y:986),control1:CGPoint(x:710,y:905),control2:CGPoint(x:601,y:995));p.addCurve(to:CGPoint(x:55,y:822),control1:CGPoint(x:231,y:1004),control2:CGPoint(x:85,y:951));p.addCurve(to:CGPoint(x:174,y:320),control1:CGPoint(x:8,y:680),control2:CGPoint(x:55,y:384));p.addCurve(to:CGPoint(x:411,y:80),control1:CGPoint(x:253,y:282),control2:CGPoint(x:245,y:73))},0x65666B,0x25262B)
        c.restoreGState()
        // Raised palm shell and two independent primary buttons.
        shape({p in p.move(to:CGPoint(x:357,y:102));p.addCurve(to:CGPoint(x:654,y:667),control1:CGPoint(x:500,y:65),control2:CGPoint(x:643,y:390));p.addCurve(to:CGPoint(x:442,y:939),control1:CGPoint(x:677,y:858),control2:CGPoint(x:578,y:950));p.addCurve(to:CGPoint(x:212,y:805),control1:CGPoint(x:310,y:942),control2:CGPoint(x:209,y:922));p.addCurve(to:CGPoint(x:245,y:329),control1:CGPoint(x:204,y:625),control2:CGPoint(x:221,y:413));p.addCurve(to:CGPoint(x:357,y:102),control1:CGPoint(x:264,y:213),control2:CGPoint(x:275,y:127))},0x77787D,0x34353A)
        shape({p in p.move(to:CGPoint(x:357,y:103));p.addCurve(to:CGPoint(x:418,y:121),control1:CGPoint(x:379,y:94),control2:CGPoint(x:402,y:106));p.addCurve(to:CGPoint(x:452,y:458),control1:CGPoint(x:437,y:236),control2:CGPoint(x:443,y:348));p.addLine(to:CGPoint(x:247,y:492));p.addCurve(to:CGPoint(x:276,y:225),control1:CGPoint(x:245,y:382),control2:CGPoint(x:250,y:287));p.addCurve(to:CGPoint(x:357,y:103),control1:CGPoint(x:293,y:160),control2:CGPoint(x:316,y:112))},0x919298,0x53545A)
        shape({p in p.move(to:CGPoint(x:434,y:127));p.addCurve(to:CGPoint(x:620,y:440),control1:CGPoint(x:512,y:159),control2:CGPoint(x:583,y:296));p.addLine(to:CGPoint(x:473,y:456));p.addCurve(to:CGPoint(x:434,y:127),control1:CGPoint(x:465,y:331),control2:CGPoint(x:453,y:213))},0x66676D,0x424349)
        v.line(248,506,623,458,0x1D1E23,6)
        // Metallic main wheel, with a dark centre and fine machined ribs.
        v.rrect(383,236,77,159,32,0x202126);v.rrect(394,244,54,140,23,0xC1C2C7);v.rrect(405,248,29,132,12,0x777A82)
        for i in 0..<20 {v.line(397,253+Double(i)*6.3,445,253+Double(i)*6.3,0x3B3E44,1.6,0.85)}
        v.line(399,257,399,367,0xF8F8FA,2,0.65)
        v.rrect(413,420,33,54,13,0x36373D);v.line(422,428,436,426,0x919298,1)
        // Thumb wheel and two physical side buttons.
        c.saveGState();c.translateBy(x:221,y:499);c.rotate(by:0.15)
        v.rrect(-29,-84,58,166,24,0x24252A);v.rrect(-23,-75,46,147,20,0xA5A6AD)
        for i in 0..<24 {v.line(-20,-66+Double(i)*5.5,20,-66+Double(i)*5.5,0x3A3C42,1.4)}
        c.restoreGState()
        v.rrect(174,598,36,96,17,0x24252A);v.rrect(140,637,29,87,14,0x292A2F)
        v.line(181,608,181,676,0x74757B,1.5,0.7)
        // Broad thumb rest and subtle tactile panel.
        shape({p in p.move(to:CGPoint(x:133,y:556));p.addCurve(to:CGPoint(x:219,y:804),control1:CGPoint(x:155,y:576),control2:CGPoint(x:231,y:700));p.addCurve(to:CGPoint(x:99,y:818),control1:CGPoint(x:224,y:867),control2:CGPoint(x:153,y:875));p.addCurve(to:CGPoint(x:133,y:556),control1:CGPoint(x:51,y:757),control2:CGPoint(x:81,y:603))},0x42434A,0x292A30)
        for row in 0..<16 {for col in 0..<4 {v.circle(106+Double(col)*14+Double(row)*1.8,639+Double(row)*9,1,0x7F8087,0.28)}}
        v.circle(501,506,3,0xA5C293)
        v.line(346,891,458,913,0x62636A,1,0.5)
        c.restoreGState()
        return c.makeImage()!
    }
    func text(_ s:String,_ size:Double,_ weight:NSFont.Weight,_ col:Int)->CGImage {
        let key="\(s)|\(size)|\(weight.rawValue)|\(col)";if let v=texts[key] { return v }
        let font=NSFont.systemFont(ofSize:size*2,weight:weight)
        let attrs:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:NSColor(cgColor:color(col))!,.kern:size>40 ? -size*0.04:0]
        let line=CTLineCreateWithAttributedString(NSAttributedString(string:s,attributes:attrs))
        var a:CGFloat=0,d:CGFloat=0,l:CGFloat=0;let width=CTLineGetTypographicBounds(line,&a,&d,&l)
        let c=bitmap(Int(ceil(width))+20,Int(ceil(a+d+l))+20);c.textPosition=CGPoint(x:10,y:d+10);CTLineDraw(line,c)
        let img=c.makeImage()!;texts[key]=img;return img
    }
    func symbol(_ name:String)->CGImage {
        if let v=symbols[name] { return v }
        let im=NSImage(systemSymbolName:name,accessibilityDescription:nil)!.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:100,weight:.regular))!
        let img=im.cgImage(forProposedRect:nil,context:nil,hints:nil)!;symbols[name]=img;return img
    }
    func makeBackground()->CGImage {
        let c=bitmap(W,H);c.setFillColor(color(0xFAFAFC));c.fill(CGRect(x:0,y:0,width:W,height:H))
        let colors=[color(0xE8E3FA,0.5),color(0xF8F7FC,0)] as CFArray
        let g=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:colors,locations:[0,1])!
        c.drawRadialGradient(g,startCenter:CGPoint(x:1580,y:0),startRadius:0,endCenter:CGPoint(x:1580,y:0),endRadius:1050,options:[])
        return c.makeImage()!
    }
    func makeMac()->CGImage {
        let c=bitmap(W,H),v=Canvas(c)
        // Thin silver MacBook, front view. Interface drawn as editable vector artwork.
        c.saveGState();c.setShadow(offset:CGSize(width:0,height:25),blur:35,color:color(0,0.18));v.rrect(240,180,1440,770,32,0xBFC0C4);c.restoreGState()
        v.rrect(245,185,1430,760,28,0x15161A);v.rrect(259,199,1402,718,19,0xF0EEFA)
        c.saveGState();c.addPath(CGPath(roundedRect:CGRect(x:259,y:199,width:1402,height:718),cornerWidth:19,cornerHeight:19,transform:nil));c.clip()
        let grad=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:[color(0xECEAFB),color(0xAC9BE5),color(0xDBDDF7)] as CFArray,locations:[0,0.6,1])!
        c.drawLinearGradient(grad,start:CGPoint(x:300,y:220),end:CGPoint(x:1600,y:950),options:[])
        for (i,a) in [0.35,0.25,0.18].enumerated() { c.setFillColor(color(0xFFFFFF,a));let p=CGMutablePath();p.move(to:CGPoint(x:240,y:820+i*70));p.addCurve(to:CGPoint(x:1700,y:350+i*80),control1:CGPoint(x:650,y:800-i*90),control2:CGPoint(x:900,y:150+i*180));p.addLine(to:CGPoint(x:1700,y:950));p.addLine(to:CGPoint(x:240,y:950));p.closeSubpath();c.addPath(p);c.fillPath() }
        v.rrect(840,199,240,28,0,0x15161A);v.rrect(848,199,224,34,12,0x15161A)
        v.rrect(310,290,1300,530,18,0xFFFFFF,0.8);v.circle(338,317,6,0xFF6059);v.circle(362,317,6,0xFFBD2E);v.circle(386,317,6,0x28CA42)
        v.text("鼠环",960,400,90,.semibold,ink,"center");v.text("顺手，由你定义。",960,525,35,.regular,gray,"center")
        drawRing(v,960,690,0.52,0,0,false)
        c.restoreGState()
        let p=CGMutablePath();p.move(to:CGPoint(x:240,y:944));p.addLine(to:CGPoint(x:1680,y:944));p.addLine(to:CGPoint(x:1845,y:1000));p.addQuadCurve(to:CGPoint(x:1785,y:1030),control:CGPoint(x:1850,y:1030));p.addLine(to:CGPoint(x:135,y:1030));p.addQuadCurve(to:CGPoint(x:75,y:1000),control:CGPoint(x:70,y:1030));p.closeSubpath();c.addPath(p);c.setFillColor(color(0xD0D1D5));c.fillPath()
        v.line(100,1002,1820,1002,0xF7F7F8,2);v.rrect(835,944,250,12,6,0xA9AAAE);v.line(150,1027,1770,1027,0x9A9BA0,3)
        return c.makeImage()!
    }
}
func orbitLogo(_ v:Canvas,_ x:Double,_ y:Double,_ size:Double,_ time:Double,_ col:Int=ink) {
    v.arc(x,y,size*0.25,1,col,size*0.105)
    for i in 0..<8 { let a=Double(i)*Double.pi/4-Double.pi/2+time;v.circle(x+cos(a)*size*0.6,y+sin(a)*size*0.6,size*0.067,i==1 ? accent:col) }
}
let ringSymbols=["lock","sun.max","playpause","clipboard","scissors","doc.on.doc","speaker.slash","speaker.wave.2"]
func drawRing(_ v:Canvas,_ x:Double,_ y:Double,_ scale:Double,_ active:Int,_ progress:Double,_ children:Bool) {
    let radius=190.0*scale,button=47.0*scale
    if progress>0 { let a=Double(active)*Double.pi/4-Double.pi/2
        let p=CGMutablePath();p.move(to:CGPoint(x:x,y:y));p.addArc(center:CGPoint(x:x,y:y),radius:radius+button+18*scale,startAngle:a-Double.pi/8,endAngle:a+Double.pi/8,clockwise:false);p.closeSubpath();v.c.addPath(p);v.c.setFillColor(color(accent,0.05));v.c.fillPath()
    }
    for i in 0..<8 { let a=Double(i)*Double.pi/4-Double.pi/2,xx=x+cos(a)*radius,yy=y+sin(a)*radius
        v.circle(xx,yy,button,i==active ? accent:ink)
        v.icon(ringSymbols[i],xx,yy,37*scale,0xFFFFFF)
        if i==active && progress>0 { v.arc(xx,yy,button+9*scale,1,0xDCD6F7,3*scale);v.arc(xx,yy,button+9*scale,progress,accent,4*scale) }
    }
    v.circle(x,y,27*scale,0xEEEFF2);v.icon("xmark",x,y,14*scale,gray)
    if children { for (i,name) in ["backward.end","play.fill","forward.end"].enumerated() { let xx=x+radius+180*scale,yy=y+Double(i-1)*128*scale;v.circle(xx,yy,41*scale,i==1 ? accent:ink);v.icon(name,xx,yy,29*scale,0xFFFFFF) } }
}
func tag(_ v:Canvas,_ text:String,_ x:Double,_ y:Double,_ width:Double) { v.rrect(x,y,width,42,21,0xEEEAFB);v.text(text,x+width/2,y+6,19,.medium,accent,"center") }
func headline(_ v:Canvas,_ first:String,_ second:String,_ x:Double,_ y:Double,_ size:Double,_ t:Double) {
    let a=ease(t/0.9),b=ease((t-0.15)/0.9)
    v.text(first,x,y+(1-a)*35,size,.semibold,ink,"left",a)
    v.text(second,x,y+size*1.2+(1-b)*35,size,.semibold,ink,"left",b)
}
func document(_ v:Canvas,_ x:Double,_ y:Double,_ width:Double,_ offset:Double) {
    v.shadow(x,y,width,560,25);v.rrect(x,y,width,60,25,0xF0F0F3);v.rrect(x,y+30,width,30,0,0xF0F0F3)
    for (i,col) in [0xFF6059,0xFFBD2E,0x28CA42].enumerated() {v.circle(x+28+Double(i)*23,y+30,6,col)}
    v.rrect(x+width*0.3,y+14,width*0.4,32,8,0xFFFFFF);v.text("灵感空间",x+width/2,y+17,17,.regular,gray,"center")
    v.c.saveGState();v.c.addRect(CGRect(x:x+1,y:y+60,width:width-2,height:499));v.c.clip()
    let yy=y+110-offset
    tag(v,"专注每一次创作",x+70,yy,190)
    v.text("灵感，顺势而来。",x+65,yy+72,57,.semibold)
    v.text("把专注留给内容，把顺手交给鼠环。",x+70,yy+158,24,.regular,gray)
    for row in 0..<4 {v.rrect(x+74,yy+225+Double(row)*30,width-180-Double(row%2)*90,8,4,0xE9E9EE)}
    let yy2=yy+395
    for i in 0..<3 { let xx=x+70+Double(i)*(width-140)/3
        v.rrect(xx,yy2,(width-180)/3,170,18,[0xECE7FB,0xE4EAF4,0xE8ECE9][i])
        v.icon(["text.alignleft","pencil.tip","sparkles"][i],xx+(width-180)/6,yy2+68,38,[accent,0x6988B2,0x6F947B][i])
        v.text(["阅读","写作","创作"][i],xx+(width-180)/6,yy2+115,23,.medium,ink,"center")
    }
    v.text("连贯，让思路不被打断。",x+70,yy2+238,40,.semibold)
    for row in 0..<10 {v.rrect(x+74,yy2+320+Double(row)*29,width-180-Double(row%3)*60,7,3.5,0xE6E7EB)}
    v.c.restoreGState()
    v.rrect(x+width-12,y+76,4,465,2,0xF0F0F2);v.rrect(x+width-12,y+90+offset*0.34,4,105,2,0xBDBCC5)
}
func scene(_ v:Canvas,_ n:Int,_ t:Double) {
    switch n {
    case 0:
        let a=ease(t/1.1)
        v.group(a) { orbitLogo(v,960,315+(1-a)*25,140,mix(-0.16,0,smooth(t/2.6))) }
        v.text("鼠环",960,463+(1-a)*35,112,.semibold,ink,"center",a)
        let b=ease((t-0.45)/1.0)
        v.text("让每一次滚动，都刚刚好。",960,635+(1-b)*25,35,.regular,gray,"center",b)
        v.text("M O U S E R I N G",960,851,17,.medium,0xA2A1AA,"center",ease((t-1.1)/1.1))
    case 1:
        let a=ease(t/1.2)
        v.text("为 Mac，释放更多可能。",960,125+(1-a)*30,74,.semibold,ink,"center",a)
        v.text("MX Master 4  ×  鼠环 Preview",960,234,28,.regular,gray,"center",ease((t-0.25)/1.1))
        v.group(a) {v.image(Assets.shared.mac,70+(1-a)*(-60),270,1250,703)}
        let b=ease((t-0.25)/1.2),float=sin(t*0.8)*5
        v.mouse(1310+(1-b)*90,350+float,540,true,b)
        v.text("鼠标为原创示意绘图",1590,934,14,.regular,0xA2A1AA,"center",a)
        v.line(780,969,1560,969,0xD7D4E3,1,0.5)
        v.text("Mac 上的原生鼠标体验",960,1004,22,.regular,gray,"center",ease((t-0.65)/1.0))
    case 2:
        headline(v,"你的滚轮，","你的节奏。",140,215,80,t)
        v.text("滚轮学习",145,145,25,.medium,accent,"left",ease(t/0.8))
        v.text("让每一格，找到合适的分寸。",145,460,30,.regular,gray,"left",ease((t-0.4)/1))
        let a=ease((t-0.25)/1)
        v.group(a) {
            v.shadow(1000,196+(1-a)*40,740,650,35)
            v.text("滚轮学习",1050,238,30,.semibold)
            let q=clamp01((t-1.1)/4.7),round=q<0.5 ? 0:1,count=min(10,Int((q*2-Double(round))*10)+1)
            v.text(q>=1 ? "已适配":"\(round==0 ? "向上":"向下")滚动 10 格",1370,338,28,.medium,gray,"center")
            v.text(q>=1 ? "✓":"\(count)",1370,401,134,.medium,q>=1 ? accent:ink,"center")
            for i in 0..<10 {v.rrect(1100+Double(i)*54,598,36,9,4.5,i<count ? accent:0xE7E4F0)}
            v.text(q>=1 ? "已记住你的滚轮节奏":"每滚动一格，学习一次。",1370,677,25,.regular,gray,"center")
            tag(v,"独立保存两种手感",1235,752,270)
        }
        for (i,title) in ["音量与亮度","原生捏合缩放"].enumerated() {
            let a=ease((t-0.65-Double(i)*0.15)/0.8),x=145+Double(i)*370
            v.group(a) {v.rrect(x,635+(1-a)*25,335,178,24,0xFFFFFF);v.icon(i==0 ? "speaker.wave.2":"plus.magnifyingglass",x+48,683,33,accent);v.text(title,x+28,729,24,.medium);v.text("独立学习 · 独立生效",x+28,773,18,.regular,gray)}
        }
        v.text("滚轮学习",145,945,20,.medium,gray,"left",ease((t-0.9)/0.8))
    case 3:
        v.text("圆环",145,145,25,.medium,accent,"left",ease(t/0.8))
        headline(v,"常用操作。","随手即达。",140,235,80,t)
        v.text("轻轻唤出，指向你要的操作。",145,480,29,.regular,gray,"left",ease((t-0.4)/0.9))
        let a=ease((t-0.25)/1),x=1240.0,y=574.0
        v.group(a) {
            v.rrect(800,175+(1-a)*40,1010,710,36,0xF2F1F8)
            v.rrect(850,230,900,620,25,0xFFFFFF,0.65)
            for i in 0..<7 {v.rrect(920,310+Double(i)*67,400+Double(i%3)*110,8,4,0xDFDDE8,0.5)}
            let u=max(0,t-1),selected=u<1.7 ? 7:u<3.8 ? 1:2,progress=u<1.7 ? 0.5:u<3.8 ? mix(0.25,0.75,ease((u-1.7)/1.6)):0.0
            let open=u>=3.8
            drawRing(v,x,y,0.91,selected,progress,open)
            if selected==1 {v.text("\(Int(progress*100))%",x+134,y-70,24,.medium,accent,"center")}
            let angle=Double(selected)*Double.pi/4-Double.pi/2,px=open ? x+330:x+cos(angle)*154,py=open ? y:y+sin(angle)*154
            v.pointer(px+10,py+10,0.78)
            if open {tag(v,"播放 / 暂停",1450,794,220)}
        }
        for (i,title) in ["二级菜单","音量与亮度","自定义图标"].enumerated() {tag(v,title,145+Double(i)*198,675,180)}
    case 4:
        v.text("自定义按键",145,126,25,.medium,accent,"left",ease(t/0.8))
        v.text("每一键，都由你定义。",140,205+(1-ease(t))*30,76,.semibold,ink,"left",ease(t))
        let a=ease((t-0.25)/1),float=sin(t*0.75)*6
        v.image(Assets.shared.side,240-(1-a)*100,360+float,395,533,a)
        v.text("点按 · 按住 · 滚动",450,920,23,.regular,gray,"center",a)
        let labels=["按键 4","按键 5","按住＋滚轮"],actions=["复制","呼出圆环","原生缩放"]
        for i in 0..<3 {let b=ease((t-0.5-Double(i)*0.23)/0.85),y=382+Double(i)*157
            v.group(b) {v.shadow(1000+(1-b)*90,y,740,126,25);v.text(labels[i],1032,y+39,25,.medium)
                if i==0 {for (j,s) in ["⌘","C"].enumerated() {v.rrect(1240+Double(j)*70,y+29,58,58,12,0xF1EFF8);v.text(s,1269+Double(j)*70,y+40,30,.medium,accent,"center")}}
                else {v.icon(i==1 ? "circle.grid.3x3":"plus.magnifyingglass",1310,y+61,34,accent)}
                v.text(actions[i],1674,y+41,26,.regular,gray,"right")
            }
        }
        if t>1.2 {let b=ease((t-1.2)/1);v.c.saveGState();v.c.setStrokeColor(color(accent,b*0.4));v.c.setLineWidth(1.5);let p=CGMutablePath();p.move(to:CGPoint(x:348,y:688));p.addCurve(to:CGPoint(x:990,y:445),control1:CGPoint(x:760,y:585),control2:CGPoint(x:720,y:445));v.c.addPath(p);v.c.strokePath();v.c.restoreGState();v.circle(348,688,7,accent,b);v.circle(990,445,4,accent,b)}
    case 5:
        v.text("平滑滚动",960,105,25,.medium,accent,"center",ease(t/0.8))
        v.text("滚动，行云流水。",960,175+(1-ease(t))*25,76,.semibold,ink,"center",ease(t))
        v.text("让页面跟随手指，让思路保持连贯。",960,280,28,.regular,gray,"center",ease((t-0.3)/1))
        let a=ease((t-0.35)/1),q=smooth((t-1.2)/5.0),offset=440*q
        v.group(a) { document(v,330,370+(1-a)*40,1260,offset) }
        let alpha=ease((t-0.9)/0.8)
        v.group(alpha) {v.rrect(752,974,416,46,23,0xEEEAFB);v.text("平滑滚动  ·  按应用独立设置",960,982,20,.medium,accent,"center")}
        for i in 0..<14 {let yy=400+Double(i)*36,phase=sin(t*3-Double(i)*0.24),w=15+20*(phase+1)/2;v.rrect(1680,yy,w,4,2,accent,alpha*0.25)}
        v.pointer(1496,700,0.8,a)
    default:
        let a=ease(t/1.0)
        v.group(a) {orbitLogo(v,960,284,115,mix(-0.12,0,smooth(t/2)))}
        v.text("把顺手，变成习惯。",960,473+(1-a)*30,84,.semibold,ink,"center",a)
        v.text("Mac  ×  MX Master 4",960,622,29,.regular,gray,"center",ease((t-0.25)/1))
        v.text("滚轮学习  ·  圆环  ·  自定义按键  ·  平滑滚动",960,715,25,.regular,gray,"center",ease((t-0.5)/1))
        v.text("鼠环  1.0 Preview",960,891,34,.semibold,ink,"center",ease((t-0.9)/1))
    }
}
let starts:[Double]=[0,4.5,10,17.5,25,31.5,39]
let ends:[Double]=[4.5,10,17.5,25,31.5,39,44]
func drawFrame(_ ctx:CGContext,_ t:Double) {
    let v=Canvas(ctx);v.image(Assets.shared.background,0,0,Double(W),Double(H))
    // Gentle overlap on a shared light stage; no static-slide cuts.
    let overlap=0.42
    for n in 0..<7 {
        if t>=starts[n]-overlap && t<ends[n]+overlap {
            let local=t-starts[n],alpha=min(n==0 ? 1:smooth((local+overlap)/(overlap*2)),n==6 ? 1:1-smooth((t-(ends[n]-overlap))/(overlap*2)))
            if alpha>0.001 { v.group(alpha) {scene(v,n,max(0,local))} }
        }
    }
}
if CommandLine.arguments.contains("--stills") {
    try! FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    for t in [2.8,7.7,14.8,20.9,23.8,28.8,35.9,42.0] {autoreleasepool {let c=bitmap(W,H);drawFrame(c,t);savePNG(c.makeImage()!,out.appendingPathComponent(String(format:"%04.1f.png",t)))}}
    print("Rendered storyboard frames");exit(0)
}
try? FileManager.default.removeItem(at:out)
let writer=try AVAssetWriter(outputURL:out,fileType:.mp4)
let compression:[String:Any]=[AVVideoAverageBitRateKey:14_000_000,AVVideoProfileLevelKey:AVVideoProfileLevelH264HighAutoLevel,AVVideoExpectedSourceFrameRateKey:fps,AVVideoMaxKeyFrameIntervalKey:fps*2,AVVideoAllowFrameReorderingKey:false]
let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:W,AVVideoHeightKey:H,AVVideoCompressionPropertiesKey:compression,AVVideoColorPropertiesKey:[AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,AVVideoTransferFunctionKey:AVVideoTransferFunction_ITU_R_709_2,AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2]])
input.expectsMediaDataInRealTime=false
let adapter=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:W,kCVPixelBufferHeightKey as String:H,kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true])
writer.add(input);guard writer.startWriting() else {fatalError(writer.error!.localizedDescription)};writer.startSession(atSourceTime:.zero)
for frame in 0..<Int(duration*Double(fps)) {
    autoreleasepool {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval:0.001) }
        var pixel:CVPixelBuffer?;CVPixelBufferPoolCreatePixelBuffer(nil,adapter.pixelBufferPool!,&pixel)
        let p=pixel!;CVPixelBufferLockBaseAddress(p,[])
        let ctx=CGContext(data:CVPixelBufferGetBaseAddress(p),width:W,height:H,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(p),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue)!
        drawFrame(ctx,Double(frame)/Double(fps));CVPixelBufferUnlockBaseAddress(p,[])
        guard adapter.append(p,withPresentationTime:CMTime(value:Int64(frame),timescale:Int32(fps))) else {fatalError(writer.error?.localizedDescription ?? "Video append failed")}
        if frame%300==0 {print("Frame \(frame)/\(Int(duration*Double(fps)))");fflush(stdout)}
    }
}
input.markAsFinished();let done=DispatchSemaphore(value:0);writer.finishWriting {done.signal()};done.wait()
guard writer.status == .completed else {fatalError(writer.error?.localizedDescription ?? "Encoding failed")}
print("Complete: \(out.path)")
